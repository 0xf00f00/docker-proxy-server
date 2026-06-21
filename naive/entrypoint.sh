#!/bin/sh
# Renders the sing-box naive config.
set -e

LOG_TAG=naive
# shellcheck source=warp/lib.sh
. /wg-lib.sh

WARP_OUTBOUND=""
ROUTE_FINAL=""
if warp_on; then
  WARP_OUTBOUND='{ "type": "socks", "tag": "warp-out", "server": "warp-wg", "server_port": 1080, "version": "5" },'
  ROUTE_FINAL='"final": "warp-out",'
  echo "[naive] WARP egress ON -> socks5 warp-wg:1080 (load-balanced WARP)"
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
    $WARP_OUTBOUND
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

echo "[naive] validating rendered config ..."
sing-box check -C /tmp/sing-box/

exec sing-box -C /tmp/sing-box/ run
