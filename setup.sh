#!/bin/sh

set -eu

ENTUNA_MARKER="# entuna-managed: do not edit by hand"

STUBBY_PORT="5453"
STUBBY_BIN="/opt/sbin/stubby"
STUBBY_PIDFILE="/opt/var/run/stubby.pid"
STUBBY_CONF="/opt/etc/stubby/stubby.yml"
STUBBY_CONFIG="/opt/etc/config/stubby.conf"
STUBBY_INIT_PATH="/opt/etc/init.d/S51stubby"

DNSMASQ_PORT="5353"
DNSMASQ_CONF="/opt/etc/dnsmasq.conf"
DNSMASQ_DIR="/opt/etc/dnsmasq.d"
DNSMASQ_LIST_PATH="${DNSMASQ_DIR}/tun.dnsmasq"
DNSMASQ_INIT_PATH="/opt/etc/init.d/S56dnsmasq"

IPTABLES_SCRIPT="/opt/etc/iptun.sh"
IPTABLES_RELOAD_HOOK="/opt/etc/ndm/netfilter.d/101-iptun.sh"
ENTUNA_CHAIN="ENTUNA_PROXY"
LEGACY_CHAIN="PROXY"
TUN_IPSET_NAME="wgrd"

STATE_DIR="/opt/etc/entuna"
STATE_FILE="${STATE_DIR}/state"

MARK_CODE=${MARK_CODE:-}
DOMAIN_LIST=${DOMAIN_LIST:-}

log() {
    echo "> ${*}"
}

die() {
    log "$*"
    exit 1
}

cmd() {
    echo "# ${*}"
    "$@"
}

usage() {
    cat <<EOF
Usage:
  $0 install [--mark CODE] [--domains FILE]
  $0 uninstall
  $0 --help

Commands:
  install      Install or update Entuna managed config
  uninstall    Remove Entuna managed config and runtime state

Use "$0 install --help" or "$0 uninstall --help" for command details.
EOF
}

install_usage() {
    cat <<EOF
Usage: $0 install [--mark CODE] [--domains FILE]

Options:
  --mark CODE       WireGuard routing mark code, for example 0xffffaaa
  --domains FILE    Path to the domain list file
  -h, --help        Show this help

MARK_CODE and DOMAIN_LIST environment variables are also supported.
Missing values are prompted when a TTY is available.
EOF
}

uninstall_usage() {
    cat <<EOF
Usage: $0 uninstall

Remove Entuna managed config, hooks, iptables rules, and ipset state.
Installed packages and the original domain list are preserved.
EOF
}

read_input() {
    prompt=$1
    var_name=$2

    printf '%s' "${prompt}"
    if [ -t 0 ]; then
        if read -r "${var_name?}"; then
            return 0
        fi
    elif ( : </dev/tty ) 2>/dev/null; then
        if read -r "${var_name?}" </dev/tty; then
            return 0
        fi
    fi

    echo
    die "No TTY available. Set MARK_CODE and DOMAIN_LIST or pass --mark and --domains."
}

is_package_installed() {
    command -v opkg >/dev/null 2>&1 || return 1
    opkg list-installed | awk '{print $1}' | grep -qx "$1"
}

install_package() {
    package=$1

    if ! command -v opkg >/dev/null 2>&1; then
        log "opkg not found; install ${package} manually."
        return 0
    fi

    if is_package_installed "${package}"; then
        log "${package} already installed"
    else
        cmd opkg install "${package}"
    fi
}

is_managed_file() {
    [ -f "$1" ] && grep -Fqx "${ENTUNA_MARKER}" "$1"
}

backup_existing_file() {
    path=$1
    backup="${path}.entuna.bak"

    [ -e "${path}" ] || return 0
    is_managed_file "${path}" && return 0

    if [ -e "${backup}" ]; then
        log "Backup already exists: ${backup}"
    else
        log "Backing up existing file to ${backup}"
        cmd cp -p "${path}" "${backup}"
    fi
}

write_managed_file() {
    path=$1
    dir=$(dirname "${path}")
    tmp="${path}.entuna.tmp.$$"

    cmd mkdir -p "${dir}"
    backup_existing_file "${path}"

    {
        printf '%s\n' "${ENTUNA_MARKER}"
        cat
    } >"${tmp}"
    cmd mv "${tmp}" "${path}"
}

write_managed_script() {
    path=$1
    dir=$(dirname "${path}")
    tmp="${path}.entuna.tmp.$$"

    cmd mkdir -p "${dir}"
    backup_existing_file "${path}"

    {
        printf '%s\n' "#!/bin/sh"
        printf '%s\n' "${ENTUNA_MARKER}"
        cat
    } >"${tmp}"
    cmd mv "${tmp}" "${path}"
}

restore_or_remove_managed_file() {
    path=$1
    backup="${path}.entuna.bak"

    if [ -e "${backup}" ]; then
        log "Restoring backup for ${path}"
        cmd mv "${backup}" "${path}"
    elif is_managed_file "${path}"; then
        log "Removing managed file ${path}"
        cmd rm -f "${path}"
    else
        log "Leaving unmanaged file untouched: ${path}"
    fi
}

restore_or_remove_generated_file() {
    path=$1
    backup="${path}.entuna.bak"

    if [ -e "${backup}" ]; then
        log "Restoring backup for ${path}"
        cmd mv "${backup}" "${path}"
    elif [ -e "${path}" ]; then
        log "Removing generated file ${path}"
        cmd rm -f "${path}"
    else
        log "Generated file already absent: ${path}"
    fi
}

validate_install_inputs() {
    [ -n "${MARK_CODE}" ] || die "MARK_CODE is required."
    [ -n "${DOMAIN_LIST}" ] || die "DOMAIN_LIST is required."
    [ -r "${DOMAIN_LIST}" ] || die "Domain list file is not readable: ${DOMAIN_LIST}"

    case "${MARK_CODE}" in
    0x*[!0-9a-fA-F]* | 0x)
        die "MARK_CODE should be hex, for example 0xffffaaa; got: ${MARK_CODE}"
        ;;
    0x[0-9a-fA-F]*)
        ;;
    *)
        die "MARK_CODE should be hex, for example 0xffffaaa; got: ${MARK_CODE}"
        ;;
    esac
}

iptables_mangle_rules() {
    if command -v iptables-save >/dev/null 2>&1; then
        iptables-save -t mangle 2>/dev/null && return 0
    fi

    iptables -t mangle -S 2>/dev/null && return 0
    iptables -t mangle -L -n -v 2>/dev/null
}

validate_mark_code_is_configured() {
    if ! command -v iptables >/dev/null 2>&1; then
        die "iptables not found; cannot validate MARK_CODE."
    fi

    if iptables_mangle_rules | awk -v mark="${MARK_CODE}" -v entuna_chain="${ENTUNA_CHAIN}" -v legacy_chain="${LEGACY_CHAIN}" '
        /^Chain / {
            current_chain = $2
            next
        }
        index($0, mark) && current_chain != entuna_chain && current_chain != legacy_chain && $0 !~ ("^-A " entuna_chain " ") && $0 !~ ("^-A " legacy_chain " ") {
            found = 1
        }
        END {
            exit found ? 0 : 1
        }
    '; then
        log "Validated MARK_CODE ${MARK_CODE} in existing mangle rules."
    else
        die "MARK_CODE ${MARK_CODE} was not found in existing non-Entuna mangle rules. Configure the WireGuard policy first, then use its mark code."
    fi
}

prompt_install_inputs() {
    if [ -z "${MARK_CODE}" ]; then
        read_input "Enter mark code: " MARK_CODE
    fi

    if [ -z "${DOMAIN_LIST}" ]; then
        read_input "Enter domain list file path: " DOMAIN_LIST
    fi
}

parse_install_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        -h | --help)
            install_usage
            exit 0
            ;;
        --mark)
            [ -n "${2:-}" ] || die "--mark requires a value"
            MARK_CODE=$2
            shift 2
            ;;
        --domains)
            [ -n "${2:-}" ] || die "--domains requires a value"
            DOMAIN_LIST=$2
            shift 2
            ;;
        *)
            install_usage
            die "Unknown install option: $1"
            ;;
        esac
    done
}

parse_uninstall_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        -h | --help)
            uninstall_usage
            exit 0
            ;;
        *)
            uninstall_usage
            die "Unknown uninstall option: $1"
            ;;
        esac
    done
}

install_stubby() {
    log "Checking stubby installation"
    install_package stubby

    log "Writing stubby init script to ${STUBBY_INIT_PATH}"
    write_managed_script "${STUBBY_INIT_PATH}" <<EOF
PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin

PIDFILE="${STUBBY_PIDFILE}"
STUBBY="${STUBBY_BIN}"
STUBBY_ARGS="-C ${STUBBY_CONF}"

[ -f "${STUBBY_CONFIG}" ] && . "${STUBBY_CONFIG}"

stubby_status()
{
        [ -f "\$PIDFILE" ] && [ -d "/proc/\$(cat "\$PIDFILE")" ]
}

start()
{
        mkdir -p "\$(dirname "\$PIDFILE")"
        "\$STUBBY" \$STUBBY_ARGS &
        echo \$! > "\$PIDFILE"
}

stop()
{
        [ -f "\$PIDFILE" ] || return 0
        kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
        rm -f "\$PIDFILE"
}

case "\${1:-}" in
        start)
                if stubby_status
                then
                        echo stubby already running
                else
                        start
                fi
                ;;
        stop)
                if stubby_status
                then
                        stop
                else
                        echo stubby is not running
                fi
                ;;
        status)
                if stubby_status
                then
                        echo stubby already running
                else
                        echo stubby is not running
                fi
                ;;
        restart)
                stop
                sleep 3
                start
                ;;
        *)
                echo "Usage: \$0 {start|stop|restart|status}"
                exit 1
                ;;
esac
EOF
    cmd chmod +x "${STUBBY_INIT_PATH}"

    if [ -x "${STUBBY_BIN}" ]; then
        log "Starting stubby"
        cmd "${STUBBY_INIT_PATH}" restart
    else
        log "stubby binary not found; skip start."
    fi
}

install_dnsmasq() {
    log "Checking dnsmasq packages"
    install_package ipset
    install_package dnsmasq-full

    log "Creating dnsmasq domain list at ${DNSMASQ_LIST_PATH}"
    write_managed_file "${DNSMASQ_LIST_PATH}" <<EOF
$(tr -d '\r' <"${DOMAIN_LIST}" | awk -v ipset="${TUN_IPSET_NAME}" 'NF && $1 !~ /^#/ {printf "ipset=/%s/%s\n", $1, ipset}')
EOF

    log "Writing dnsmasq config to ${DNSMASQ_CONF}"
    write_managed_file "${DNSMASQ_CONF}" <<EOF
user=root
group=root

port=${DNSMASQ_PORT}

listen-address=127.0.0.1
listen-address=192.168.1.1

server=127.0.0.1#${STUBBY_PORT}

conf-dir=${DNSMASQ_DIR}
EOF

    if [ -x "${DNSMASQ_INIT_PATH}" ]; then
        log "Restarting dnsmasq"
        cmd "${DNSMASQ_INIT_PATH}" restart
    else
        log "dnsmasq init script not found; skip restart."
    fi
}

install_iptables() {
    log "Writing iptables script to ${IPTABLES_SCRIPT}"
    write_managed_script "${IPTABLES_SCRIPT}" <<EOF
set -eu

ENTUNA_CHAIN="${ENTUNA_CHAIN}"
TUN_IPSET_NAME="${TUN_IPSET_NAME}"
MARK_CODE="${MARK_CODE}"

echo "Create ipset to be used by dnsmasq"
ipset create "\${TUN_IPSET_NAME}" hash:net -exist

echo "Create Entuna chain to mark packets for policy routing"
iptables -t mangle -L "\${ENTUNA_CHAIN}" >/dev/null 2>&1 || iptables -t mangle -N "\${ENTUNA_CHAIN}"
iptables -t mangle -C "\${ENTUNA_CHAIN}" -j MARK --set-mark "\${MARK_CODE}" 2>/dev/null || iptables -t mangle -A "\${ENTUNA_CHAIN}" -j MARK --set-mark "\${MARK_CODE}"
iptables -t mangle -C "\${ENTUNA_CHAIN}" -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null || iptables -t mangle -A "\${ENTUNA_CHAIN}" -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff

echo "Route matching ipset destinations through Entuna chain"
iptables -t mangle -C PREROUTING -m set --match-set "\${TUN_IPSET_NAME}" dst -j "\${ENTUNA_CHAIN}" 2>/dev/null || iptables -t mangle -A PREROUTING -m set --match-set "\${TUN_IPSET_NAME}" dst -j "\${ENTUNA_CHAIN}"
EOF
    cmd chmod +x "${IPTABLES_SCRIPT}"

    log "Writing iptables reload hook to ${IPTABLES_RELOAD_HOOK}"
    write_managed_script "${IPTABLES_RELOAD_HOOK}" <<EOF
[ "\${type:-}" = "ip6tables" ] && exit 0
[ "\${table:-}" = "mangle" ] || exit 0

logger "Entuna reload: \${type:-unknown} \${table:-unknown}"

sh "${IPTABLES_SCRIPT}"
EOF
    cmd chmod +x "${IPTABLES_RELOAD_HOOK}"

    log "Applying iptables rules"
    cmd sh "${IPTABLES_SCRIPT}"
}

write_state() {
    log "Writing Entuna state to ${STATE_FILE}"
    write_managed_file "${STATE_FILE}" <<EOF
mark_code=${MARK_CODE}
domain_list=${DOMAIN_LIST}
ipset=${TUN_IPSET_NAME}
chain=${ENTUNA_CHAIN}
EOF
}

remove_iptables_rule() {
    table=$1
    chain=$2
    shift 2

    while iptables -t "${table}" -D "${chain}" "$@" 2>/dev/null; do
        :
    done
}

uninstall_iptables() {
    if ! command -v iptables >/dev/null 2>&1; then
        log "iptables not found; skip runtime rule cleanup."
        return 0
    fi

    log "Removing Entuna iptables rules"
    remove_iptables_rule mangle PREROUTING -m set --match-set "${TUN_IPSET_NAME}" dst -j "${ENTUNA_CHAIN}"
    remove_iptables_rule mangle PREROUTING -m set --match-set "${TUN_IPSET_NAME}" dst -j "${LEGACY_CHAIN}"

    if iptables -t mangle -L "${ENTUNA_CHAIN}" >/dev/null 2>&1; then
        if cmd iptables -t mangle -F "${ENTUNA_CHAIN}"; then
            :
        else
            log "Could not flush chain ${ENTUNA_CHAIN}."
        fi

        if cmd iptables -t mangle -X "${ENTUNA_CHAIN}"; then
            :
        else
            log "Could not delete chain ${ENTUNA_CHAIN}; it may still be referenced."
        fi
    else
        log "Entuna chain already absent: ${ENTUNA_CHAIN}"
    fi

    if command -v ipset >/dev/null 2>&1; then
        if ipset list "${TUN_IPSET_NAME}" >/dev/null 2>&1; then
            if cmd ipset destroy "${TUN_IPSET_NAME}"; then
                :
            else
                log "Could not destroy ipset ${TUN_IPSET_NAME}; it may still be referenced."
            fi
        else
            log "ipset already absent: ${TUN_IPSET_NAME}"
        fi
    else
        log "ipset command not found; skip ipset cleanup."
    fi
}

stop_managed_stubby() {
    if is_managed_file "${STUBBY_INIT_PATH}" && [ -x "${STUBBY_INIT_PATH}" ]; then
        log "Stopping managed stubby"
        cmd "${STUBBY_INIT_PATH}" stop || true
    else
        log "No managed stubby init script to stop."
    fi
}

restart_dnsmasq_after_uninstall() {
    if [ -x "${DNSMASQ_INIT_PATH}" ]; then
        log "Restarting dnsmasq"
        cmd "${DNSMASQ_INIT_PATH}" restart
    else
        log "dnsmasq init script not found; skip restart."
    fi
}

install_command() {
    parse_install_args "$@"
    prompt_install_inputs
    validate_install_inputs
    validate_mark_code_is_configured
    install_stubby
    install_dnsmasq
    install_iptables
    write_state
}

uninstall_command() {
    parse_uninstall_args "$@"
    stop_managed_stubby
    uninstall_iptables
    restore_or_remove_generated_file "${IPTABLES_RELOAD_HOOK}"
    restore_or_remove_generated_file "${IPTABLES_SCRIPT}"
    restore_or_remove_generated_file "${DNSMASQ_LIST_PATH}"
    restore_or_remove_managed_file "${DNSMASQ_CONF}"
    restore_or_remove_managed_file "${STUBBY_INIT_PATH}"
    restore_or_remove_generated_file "${STATE_FILE}"
    restart_dnsmasq_after_uninstall
}

main() {
    case "${1:-}" in
    -h | --help)
        usage
        ;;
    install)
        shift
        install_command "$@"
        ;;
    uninstall)
        shift
        uninstall_command "$@"
        ;;
    "")
        usage
        exit 1
        ;;
    *)
        usage
        die "Unknown command: $1"
        ;;
    esac
}

main "$@"
