#!/bin/sh
# Renders an xray config at runtime from .env values and runs xray as the
# INBOUND (server side) with two plaintext VLESS inbounds:
#
#   - ws    on :2080 (network=ws,    security=none)
#   - xhttp on :2081 (network=xhttp, security=none)
#
# Both share the SAME path ($XRAY_PATH) and accept ANY Host -- Caddy routes a
# request to the ws inbound when it carries the WebSocket Upgrade header and to
# the xhttp inbound otherwise, so a single domain (any host in WEB_DOMAINS)
# serves both transports. See caddy/Caddyfile.
#
# Both are plaintext on purpose: Caddy in front terminates TLS with valid certs
# (Cloudflare DNS-01). Nothing here is exposed directly; the only published
# ports on the host are Caddy's :80/:443.
set -e

mkdir -p /tmp/xray
cat > /tmp/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "ws-in",
      "listen": "0.0.0.0",
      "port": 2080,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID", "flow": "" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": { "path": "$XRAY_PATH" }
      }
    },
    {
      "tag": "xhttp-in",
      "listen": "0.0.0.0",
      "port": 2081,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID", "flow": "" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": { "path": "$XRAY_PATH", "mode": "auto" }
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" }
  ]
}
EOF

exec xray run -c /tmp/xray/config.json
