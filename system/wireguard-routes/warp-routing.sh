#!/bin/bash
#
# Routing for full-tunnel WARP (AllowedIPs = 0.0.0.0/0, ::/0).
# Keeps incoming client connections alive by routing their replies out the WAN
# instead of the tunnel, while all other traffic goes through WARP.
#
# Called from the WireGuard config:
#   PostUp   = /usr/local/bin/warp-routing.sh up   %i
#   PostDown = /usr/local/bin/warp-routing.sh down %i

set -u

ACTION="${1:-}"
WG_IFACE="${2:-wgcf}"   # WireGuard interface (wg-quick passes %i)
MARK="0x1"
PREF="100"

# Real WAN interface = the default route in the main table.
WAN_IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"
if [ -z "${WAN_IFACE}" ]; then
    echo "warp-routing: no default route / WAN interface found" >&2
    exit 1
fi

up() {
    # Loose reverse-path filtering on the WAN only, else inbound packets get
    # dropped (asymmetric: in on WAN, default route on the tunnel).
    sysctl -w "net.ipv4.conf.${WAN_IFACE}.rp_filter=2" >/dev/null

    # Forward + NAT.
    iptables  -A FORWARD -i "${WG_IFACE}" -j ACCEPT
    iptables  -t nat -A POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE
    ip6tables -A FORWARD -i "${WG_IFACE}" -j ACCEPT
    ip6tables -t nat -A POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE

    # Mark inbound connections, restore the mark on their replies.
    for ipt in iptables ip6tables; do
        "${ipt}" -t mangle -A PREROUTING -i "${WAN_IFACE}" -m conntrack --ctstate NEW -j CONNMARK --set-mark "${MARK}"
        "${ipt}" -t mangle -A PREROUTING -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark
        "${ipt}" -t mangle -A OUTPUT     -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark
    done

    # Route marked replies via the real gateway.
    ip    rule add fwmark "${MARK}" lookup main pref "${PREF}"
    ip -6 rule add fwmark "${MARK}" lookup main pref "${PREF}"
}

down() {
    ip    rule del fwmark "${MARK}" lookup main pref "${PREF}" 2>/dev/null || true
    ip -6 rule del fwmark "${MARK}" lookup main pref "${PREF}" 2>/dev/null || true

    for ipt in iptables ip6tables; do
        "${ipt}" -t mangle -D OUTPUT     -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark 2>/dev/null || true
        "${ipt}" -t mangle -D PREROUTING -m conntrack --ctstate ESTABLISHED,RELATED -j CONNMARK --restore-mark 2>/dev/null || true
        "${ipt}" -t mangle -D PREROUTING -i "${WAN_IFACE}" -m conntrack --ctstate NEW -j CONNMARK --set-mark "${MARK}" 2>/dev/null || true
    done

    iptables  -D FORWARD -i "${WG_IFACE}" -j ACCEPT 2>/dev/null || true
    iptables  -t nat -D POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null || true
    ip6tables -D FORWARD -i "${WG_IFACE}" -j ACCEPT 2>/dev/null || true
    ip6tables -t nat -D POSTROUTING -o "${WAN_IFACE}" -j MASQUERADE 2>/dev/null || true
}

case "${ACTION}" in
    up)   up ;;
    down) down ;;
    *) echo "usage: $0 {up|down} [wg-interface]" >&2; exit 1 ;;
esac
