#!/bin/sh

set -eu

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
TUN_IPSET_NAME="wgrd"
MARK_CODE=${MARK_CODE:-}
DOMAIN_LIST=${DOMAIN_LIST:-}

log() {
    echo "> ${*}"
}

cmd() {
    echo "# ${*}"
    "$@"
}

usage() {
    echo "Usage: $0 [--mark CODE] [--domains FILE]"
    echo "  --mark CODE    Mark code for iptables (default: 0xffffaaa)"
    echo "  --domains FILE Path to domain list file"
    echo "  Or set MARK_CODE and DOMAIN_LIST environment variables"
}

is_package_installed() {
    command -v opkg >/dev/null 2>&1 || return 1
    opkg list-installed | awk '{print $1}' | grep -qx "$1"
}

validate_inputs() {
    [ -f "${DOMAIN_LIST}" ] || { log "DOMAIN_LIST file not found: ${DOMAIN_LIST}"; exit 1; }
    case "${MARK_CODE}" in
        0x[0-9a-fA-F]*)
            ;;
        *)
            log "MARK_CODE should be hex (e.g. 0xffffaaa), got: ${MARK_CODE}"
            exit 1
            ;;
    esac
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            --mark)
                [ -n "${2:-}" ] || { log "--mark requires a value"; exit 1; }
                MARK_CODE="$2"
                shift 2
                ;;
            --domains)
                [ -n "${2:-}" ] || { log "--domains requires a value"; exit 1; }
                DOMAIN_LIST="$2"
                shift 2
                ;;
            *)
                log "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

prompt_user_inputs() {
    _read_input() {
        printf '%s' "$1"
        if [ -t 0 ]; then
            read -r "$2"
        elif [ -r /dev/tty ]; then
            read -r "$2" </dev/tty
        else
            echo
            log "No TTY available. Set MARK_CODE and DOMAIN_LIST as environment variables."
            exit 1
        fi
    }

    if [ -z "${MARK_CODE}" ]; then
        _read_input "Enter mark code (default 0xffffaaa): " MARK_CODE
        if [ -z "${MARK_CODE}" ]; then
            MARK_CODE=0xffffaaa
        fi
    fi

    if [ -z "${DOMAIN_LIST}" ]; then
        _read_input "Enter domain list file path: " DOMAIN_LIST
        if [ -z "${DOMAIN_LIST}" ]; then
            log "DOMAIN_LIST is required."
            exit 1
        fi
    fi
}

install_stubby() {
    log "Checking stubby installation"
    if command -v opkg >/dev/null 2>&1; then
        if is_package_installed stubby; then
            log "stubby already installed"
        else
            cmd opkg install stubby
        fi
    else
        log "opkg not found; install stubby manually."
    fi

    log "Writing stubby init script to ${STUBBY_INIT_PATH}"
    cat <<EOF >"${STUBBY_INIT_PATH}"
#!/bin/sh

PATH=/opt/bin:/opt/sbin:/sbin:/bin:/usr/sbin:/usr/bin

PIDFILE="${STUBBY_PIDFILE}"
STUBBY="${STUBBY_BIN}"
STUBBY_ARGS="-C ${STUBBY_CONF}"

[ -f "${STUBBY_CONFIG}" ] && . "${STUBBY_CONFIG}"

stubby_status ()
{
        [ -f "\$PIDFILE" ] && [ -d "/proc/\$(cat "\$PIDFILE")" ]
}

start()
{
        mkdir -p "\$(dirname "\$PIDFILE")"
        \$STUBBY \$STUBBY_ARGS &
        echo \$! > "\$PIDFILE"
}

stop()
{
        [ -f "\$PIDFILE" ] || return 0
        kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
        rm -f "\$PIDFILE"
}
case "\$1" in
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
                ;;
esac
EOF
    cmd chmod +x "${STUBBY_INIT_PATH}"

    log "Starting stubby"
    if [ -x "${STUBBY_BIN}" ]; then
        cmd "${STUBBY_INIT_PATH}" start
    else
        log "stubby not found; skip start."
    fi
}

install_dnsmasq() {
    log "Checking dnsmasq-full installation"
    if command -v opkg >/dev/null 2>&1; then
        if is_package_installed dnsmasq-full; then
            log "dnsmasq-full already installed"
        else
            cmd opkg install ipset dnsmasq-full
        fi
        cmd mkdir -p "${DNSMASQ_DIR}"
    else
        log "opkg not found; install dnsmasq-full manually."
    fi

    log "Creating dnsmasq domain list at ${DNSMASQ_LIST_PATH}"
    tr -d '\r' <"${DOMAIN_LIST}" | awk 'NF && $1 !~ /^#/' | awk -v ipset="${TUN_IPSET_NAME}" '{printf "ipset=/%s/%s\n", $1, ipset}' >"${DNSMASQ_LIST_PATH}"

    log "Writing dnsmasq config to ${DNSMASQ_CONF}"
    cat <<EOF >"${DNSMASQ_CONF}"
user=root
group=root

port=${DNSMASQ_PORT}

listen-address=127.0.0.1
listen-address=192.168.1.1

server=127.0.0.1#${STUBBY_PORT}

conf-dir=${DNSMASQ_DIR}
EOF

    log "Reloading dnsmasq"
    cmd "${DNSMASQ_INIT_PATH}" restart
}

install_iptables() {
    log "Writing iptables script to ${IPTABLES_SCRIPT}"
    cat <<EOF >"${IPTABLES_SCRIPT}"
#!/bin/sh

set -eu

echo "Create ipset to be used by dnsmasq"
ipset create ${TUN_IPSET_NAME} hash:net -exist

echo "Create PROXY chain to mark packages for further routing"
iptables -t mangle -L PROXY >/dev/null 2>&1 || iptables -t mangle -N PROXY
iptables -t mangle -C PROXY -j MARK --set-mark ${MARK_CODE} 2>/dev/null || iptables -t mangle -A PROXY -j MARK --set-mark ${MARK_CODE}
iptables -t mangle -C PROXY -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff 2>/dev/null || iptables -t mangle -A PROXY -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff

echo "Configure redirect ipset packages to PROXY chain"
iptables -t mangle -C PREROUTING -m set --match-set ${TUN_IPSET_NAME} dst -j PROXY 2>/dev/null || iptables -t mangle -A PREROUTING -m set --match-set ${TUN_IPSET_NAME} dst -j PROXY
EOF

    log "Writing iptables reload hook to ${IPTABLES_RELOAD_HOOK}"
    cat <<EOF >"${IPTABLES_RELOAD_HOOK}"
#!/bin/sh

[ "\$type" = "ip6tables" ] && exit 0
[ "\$table" = "mangle" ] || exit 0

logger "Reload: \$type \$table"

sh ${IPTABLES_SCRIPT}
EOF
    cmd chmod +x "${IPTABLES_RELOAD_HOOK}"

    log "Applying iptables rules"
    cmd sh "${IPTABLES_SCRIPT}"
}

main() {
    parse_args "$@"
    prompt_user_inputs
    validate_inputs
    install_stubby
    install_dnsmasq
    install_iptables
}

main "$@"
