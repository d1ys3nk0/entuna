# Entware Tunnel Advance

## Prerequisites

Entware should already be installed.

- Go to <http://192.168.1.1/system> and open **Component options** to ensure the following components are installed:
  - `WireGuard VPN`
  - `Open Package support`
  - `Kernel modules for Netfilter`
  - `Extension package Xtables-addons for Netfilter`

## Configure WireGuard

- Go to <http://192.168.1.1/otherConnections> to configure and enable the WireGuard connection.
- Go to <http://192.168.1.1/policies/interface-priorities> to create a `WG` policy.
- Ensure the WireGuard connection has the highest priority in the `WG` policy.

## Get the WireGuard mark code

- Go to <http://192.168.1.1/policies/policy-consumers>.
- Move one of your devices to the `WG` group.
- Run: `ssh -p 65022 root@192.168.1.1 iptables -t mangle -L | grep 0xffff` to get the mark code.
- Move the device back to `Default policy`.
- Alternatively, run the installer interactively and let it list discovered `fwmark` values and tunnel interfaces.

## Prepare the domain list for tunneling

Prepare your list of domains:

```sh
curl -fsSL https://raw.githubusercontent.com/itdoginfo/allow-domains/refs/heads/main/Russia/inside-raw.lst -o proxy.lst
```

**Note:** Edit the list to remove `youtube.com` and `googlevideo.com` if you're using `nfqws`.

## Install script

SSH into your Entware device and run:

```sh
curl -fsSL https://raw.githubusercontent.com/d1ys3nk0/entuna/main/setup.sh -o entuna.sh && chmod +x entuna.sh
```

```sh
# Interactive discovery (lists mark codes and tunnel interfaces, then asks what to use)
./entuna.sh install --domains proxy.lst

# If you already know the mark code, Entuna still scans interfaces and asks which one to monitor
./entuna.sh install --mark 0xffffaaa --domains proxy.lst

# Non-interactive install, for scripts only
DOMAIN_LIST=proxy.lst MARK_CODE=0xffffaaa ENTUNA_TUNNEL_IFACES=nwg0 ./entuna.sh install
```

In interactive mode, omit the tunnel interface. Entuna scans interfaces and asks which one to use. Without a TTY, pass `--tunnel-ifaces` or set `ENTUNA_TUNNEL_IFACES`.

Entuna installs a watchdog that checks the selected tunnel interface every 10 seconds by default. When the tunnel is alive, matching traffic is marked for Keenetic policy routing. When the tunnel is down, Entuna removes its mark rule so clients fall back to direct WAN routing instead of hanging or leaking through a stale tunnel rule.

Watchdog settings are configurable:

```sh
./entuna.sh install --mark 0xffffaaa --domains proxy.lst --check-interval 10 --check-timeout 2 --check-target 1.1.1.1
```

Run `./entuna.sh --help` for usage.

To remove Entuna managed config, watchdog, hooks, iptables rules, and ipset state without removing packages or your domain list, run:

```sh
./entuna.sh uninstall
```

## Configure DNS

- Go to <http://192.168.1.1/wired/GigabitEthernet1> and ensure **Ignore DNSv4 from ISP** is enabled.
- Go to <http://192.168.1.1/internet-filter/dns-configuration> and configure `192.168.1.1:5353` as the only DNS server.

## Verify

- From your local machine, run: `nslookup chatgpt.com`
- Run `ipset list wgrd` to verify the IP address from above is in the list.
