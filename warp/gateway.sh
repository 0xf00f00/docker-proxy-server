#!/bin/sh
# warp-lb egress. Runs in warp-wg's network namespace (network_mode: service)
# so it sees the kernel WARP interfaces warp1..N. Exposes a SOCKS inbound on
# :1080 and round-robin balances it across one freedom outbound per interface,
# each pinned to its interface via sockopt.interface. naive + xray route here.
set -e

N="${WARP_ACCOUNTS:-4}"

# Wait for warp-wg to finish bringing the interfaces up in the shared netns.
i=0
while [ ! -e "/sys/class/net/warp$N" ] && [ "$i" -lt 60 ]; do
  i=$((i + 1))
  sleep 1
done
[ -e "/sys/class/net/warp$N" ] || echo "[warp-lb] WARN: warp$N not present after ${i}s; starting anyway"

OUT=""
n=1
while [ "$n" -le "$N" ]; do
  OUT="$OUT
    { \"tag\": \"warp$n\", \"protocol\": \"freedom\", \"settings\": { \"domainStrategy\": \"UseIPv4\" }, \"streamSettings\": { \"sockopt\": { \"interface\": \"warp$n\" } } },"
  n=$((n + 1))
done
OUT="${OUT%,}"

mkdir -p /tmp/xray
cat > /tmp/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "0.0.0.0", "port": 1080, "protocol": "socks", "settings": { "udp": true, "auth": "noauth" } }
  ],
  "outbounds": [
$OUT
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "balancers": [
      { "tag": "warplb", "selector": ["warp"], "strategy": { "type": "roundRobin" } }
    ],
    "rules": [
      { "type": "field", "network": "tcp,udp", "balancerTag": "warplb" }
    ]
  }
}
EOF

echo "[warp-lb] SOCKS :1080 round-robin across warp1..warp$N"
exec xray run -c /tmp/xray/config.json
