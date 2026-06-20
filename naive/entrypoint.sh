#!/bin/sh
# Renders the sing-box config
set -e

LOG_TAG=naive
# shellcheck source=warp/lib.sh
. /wg-lib.sh

ENDPOINTS_JSON=""
ROUTE_FINAL=""
if warp_on; then
  load_warp_profile

  ENDPOINTS_JSON=$(cat <<JSON
  "endpoints": [
    {
      "type": "wireguard",
      "tag": "warp-ep",
      "system": false,
      "mtu": 1280,
      "address": [ $WG_ADDRS ],
      "private_key": "$WG_KEY",
      "peers": [
        {
          "address": "$WG_HOST",
          "port": $WG_PORT,
          "public_key": "$WG_PEER",
          "allowed_ips": [ "0.0.0.0/0", "::/0" ],
          "persistent_keepalive_interval": 25
        }
      ]
    }
  ],
JSON
)
  ROUTE_FINAL='"final": "warp-ep",'
  echo "[naive] WARP egress ON -> WireGuard endpoint via $WG_HOST:$WG_PORT"
else
  echo "[naive] WARP egress OFF -> direct"
fi

mkdir -p /tmp/sing-box
cat > /tmp/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "dns": {
    "servers": [{ "tag": "local", "type": "local" }],
    "strategy": "ipv4_only"
  },
$ENDPOINTS_JSON
  "inbounds": [
    {
      "type": "naive",
      "tag": "naive-in",
      "network": "tcp",
      "listen": "0.0.0.0",
      "listen_port": 1080,
      "users": [
        { "username": "$PROXY_USER", "password": "$PROXY_PASSWORD" }
      ]
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    $ROUTE_FINAL
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-ir",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs",
        "download_detour": "direct",
        "update_interval": "24h"
      },
      {
        "type": "remote",
        "tag": "geoip-ir",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geoip-ir.srs",
        "download_detour": "direct",
        "update_interval": "24h"
      }
    ],
    "rules": [
      { "domain_suffix": [".ir"], "action": "reject" },
      { "rule_set": "geosite-ir", "action": "reject" },
      { "action": "resolve", "strategy": "ipv4_only" },
      { "rule_set": "geoip-ir", "action": "reject" },
      {
        "ip_cidr": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ],
        "action": "reject"
      }
    ]
  },
  "experimental": {
    "cache_file": { "enabled": true, "path": "/tmp/sing-box/cache.db" }
  }
}
EOF

exec sing-box -C /tmp/sing-box/ run
