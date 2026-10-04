# lxc-portfwd

A small Bash tool to forward ports from a host's **single public IP** to containers (LXC, VMs) living on a **private NAT bridge**: the classic Proxmox-on-one-IP setup.

```console
# lxc-portfwd add 443 10.10.10.100 443 tcp "reverse proxy https"
Added: tcp 443 -> 10.10.10.100:443 (reverse proxy https)

# lxc-portfwd add 2222 10.10.10.101 22 tcp "ssh to a container"
# lxc-portfwd list
PROTO  PUB_PORT   CT_IP            CT_PORT  COMMENT
tcp    443        10.10.10.100     443      reverse proxy https
tcp    2222       10.10.10.101     22       ssh to a container
```

Instead of piling up `iptables` commands that vanish at the next reboot, you keep **one small config file** and the tool rebuilds the rules from it, on demand and at boot.

## Features

- **One rule per line** in a plain text file (`proto:port:ct_ip:ct_port:comment`), easy to read, diff and back up.
- **Own iptables chains only** (`LXC_PORTFWD*`): `apply` flushes and rebuilds just those, so your other firewall rules are never touched. `flush` removes everything the tool created.
- **TCP, UDP or both** for each rule.
- **Hairpin NAT included**: a container that calls your public hostname (resolved to the public IP from inside) still reaches the right container. Without it, the reply bypasses the NAT and the connection times out.
- **Persistent**: a systemd unit reapplies the rules at boot.
- **Validated input** (ports, IPv4 addresses, protocol). Adding a rule on a port that already has one replaces it.
- **Idempotent**: running `apply` twice never duplicates rules.
- Tested in a throw-away network namespace (`sudo ./test.sh`), so the tests never touch your real firewall.

## Install

```sh
sudo install -m 755 lxc-portfwd /usr/local/bin/lxc-portfwd
sudo install -m 644 lxc-portfwd.service /etc/systemd/system/lxc-portfwd.service
sudo systemctl daemon-reload
sudo systemctl enable --now lxc-portfwd.service
```

Requirements: Bash, `iptables` (legacy or the nft shim), `iproute2`, root.

## Configuration

Environment variables, all optional (put them in the systemd unit with `Environment=` if you change them):

| Variable | Default | Meaning |
|---|---|---|
| `CONF` | `/etc/lxc-portfwd.conf` | rules file |
| `WAN_IF` | `vmbr0` | public interface (its IPv4 address is used for hairpin NAT) |
| `LAN_NET` | `10.10.10.0/24` | private network of your containers |

The config file looks like [`lxc-portfwd.conf.example`](lxc-portfwd.conf.example). You can edit it by hand and run `lxc-portfwd apply`.

## Commands

```
lxc-portfwd add <public_port> <ct_ip> [ct_port] [tcp|udp|both] [comment]
lxc-portfwd del <public_port> [tcp|udp|both]
lxc-portfwd list
lxc-portfwd apply     # rebuild iptables rules from the config file
lxc-portfwd flush     # remove all rules and chains created by the tool
```

## Prerequisite: the private bridge with NAT

This tool handles **inbound** traffic. Your containers also need to get **out**. On Proxmox, a typical `/etc/network/interfaces` stanza for the private bridge is:

```
auto vmbr1
iface vmbr1 inet static
	address 10.10.10.1/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
	post-up   iptables -t nat -A POSTROUTING -s '10.10.10.0/24' -o vmbr0 -j MASQUERADE
	post-down iptables -t nat -D POSTROUTING -s '10.10.10.0/24' -o vmbr0 -j MASQUERADE
	post-up   iptables -A FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
	post-down iptables -D FORWARD -i vmbr1 -o vmbr0 -j ACCEPT
	post-up   iptables -A FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
	post-down iptables -D FORWARD -i vmbr0 -o vmbr1 -m state --state RELATED,ESTABLISHED -j ACCEPT
```

Containers then use `10.10.10.1` as gateway.

## Things worth knowing

- **Only forward what you need.** Every rule exposes a port of a container to the internet. A reverse proxy (80/443) in front of everything is usually enough.
- **`ifreload -a` replays `post-up` lines**, so the NAT/FORWARD rules *above* get duplicated (harmless, but untidy). The tool's own chains are not affected: `apply` rebuilds them from scratch.
- **`FORWARD` policy.** Proxmox defaults to `ACCEPT`. If yours is `DROP`, you need a rule accepting `RELATED,ESTABLISHED` replies from the containers, as in the stanza above.
- **IPv4 only.** There is no IPv6 handling (containers usually get public IPv6 routed rather than NATed).
- **Hairpin** uses `CONNMARK` (mark `0x2a`) and the public address of `WAN_IF`. If that interface has no IPv4 address, hairpin rules are skipped.
- Debug with `iptables -t nat -S LXC_PORTFWD` and `iptables -S LXC_PORTFWD_FWD`.

## Why not just `iptables` by hand?

You can. But a rule typed by hand is gone after a reboot, nobody remembers why it exists, and the `FORWARD` rule is easy to forget. A single config file with comments, rebuilt by one command, fixes all three.

## License

MIT
