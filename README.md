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
# Using environment variables
DOMAIN_LIST=proxy.lst MARK_CODE=0xffffaaa ./entuna.sh

# Using command-line flags
./entuna.sh --mark 0xffffaaa --domains proxy.lst

# Interactive (prompts for mark code and domain list when run without args)
./entuna.sh
```

Run `./entuna.sh --help` for usage.

## Configure DNS

- Go to <http://192.168.1.1/wired/GigabitEthernet1> and ensure **Ignore DNSv4 from ISP** is enabled.
- Go to <http://192.168.1.1/internet-filter/dns-configuration> and configure `192.168.1.1:5353` as the only DNS server.

## Verify

- From your local machine, run: `nslookup chatgpt.com`
- Run `ipset list wgrd` to verify the IP address from above is in the list.
