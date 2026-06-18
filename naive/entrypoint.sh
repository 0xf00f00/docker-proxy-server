#!/bin/sh
# Renders a sing-box config at runtime (PROXY_USER/PROXY_PASSWORD from .env)
# and runs sing-box as the naive INBOUND (server side).
#
# Listens on :1080 plain HTTP/2 (h2c). Caddy in front terminates TLS and
# reverse_proxies CONNECT requests with `Tunnel-Mode: udp` to this service.
# Pairs with the matching client-side `naive` container in docker-proxy-client.
set -e

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
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rule_set": [
      {
        "type": "remote",
        "tag": "geosite-ir",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geosite-ir.srs",
        "update_interval": "24h"
      },
      {
        "type": "remote",
        "tag": "geoip-ir",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/Chocolate4U/Iran-sing-box-rules/rule-set/geoip-ir.srs",
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
