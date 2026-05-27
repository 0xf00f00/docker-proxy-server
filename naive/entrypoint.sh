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
  ]
}
EOF

exec sing-box -C /tmp/sing-box/ run
