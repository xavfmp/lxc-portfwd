#!/usr/bin/env bash
# Runs lxc-portfwd inside a throw-away network namespace (needs root + iptables):
# your real firewall is never touched.   Usage: sudo ./test.sh
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${INSIDE_NETNS:-}" != 1 ]]; then
  exec env INSIDE_NETNS=1 unshare -n bash "$0"
fi

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok   - $*"; }

ip link set lo up
ip link add vmbr0 type dummy; ip addr add 203.0.113.5/24 dev vmbr0; ip link set vmbr0 up
export CONF; CONF="$(mktemp)"
export LAN_NET=10.10.10.0/24
P=./lxc-portfwd

$P add 80 10.10.10.100 80 tcp "web" >/dev/null
$P add 53 10.10.10.2 53 both "dns" >/dev/null
$P add 2222 10.10.10.101 22 >/dev/null
iptables -t nat -S LXC_PORTFWD | grep -q -- "-i vmbr0 -p tcp -m tcp --dport 80 -j DNAT --to-destination 10.10.10.100:80" || fail "DNAT rule missing"
ok "add creates the DNAT rule"
iptables -S LXC_PORTFWD_FWD | grep -q -- "-d 10.10.10.2/32 -p udp -m udp --dport 53 -j ACCEPT" || fail "udp half of 'both' missing"
ok "'both' expands to tcp and udp"
iptables -t nat -S LXC_PORTFWD | grep -q -- "-s 10.10.10.0/24 -d 203.0.113.5/32 -p tcp -m tcp --dport 80 -j DNAT" || fail "hairpin rule missing"
ok "hairpin rule uses the public IP of vmbr0"

$P add 80 10.10.10.200 8080 tcp "replaced" >/dev/null
[[ "$(grep -c '^tcp:80:' "$CONF")" == 1 ]] || fail "duplicate rule on same port"
ok "adding the same port replaces the old rule"

for bad in "99999 10.0.0.1" "80 10.0.0" "80 10.0.0.256" "80 10.0.0.1 80 sctp"; do
  # shellcheck disable=SC2086
  if $P add $bad >/dev/null 2>&1; then fail "accepted invalid input: $bad"; fi
done
ok "invalid ports / IPs / protocols are rejected"

$P apply >/dev/null; $P apply >/dev/null
[[ "$(iptables -t nat -S PREROUTING | grep -c LXC_PORTFWD)" == 1 ]] || fail "apply is not idempotent"
ok "apply is idempotent"

$P del 53 >/dev/null; $P del 80 tcp >/dev/null
[[ "$($P list | tail -n +2 | wc -l)" == 1 ]] || fail "del did not remove rules"
ok "del removes rules"

$P flush >/dev/null
[[ "$(iptables-save | grep -c LXC_PORTFWD)" == 0 ]] || fail "flush left rules behind"
ok "flush removes every rule and chain"
echo "All tests passed."
