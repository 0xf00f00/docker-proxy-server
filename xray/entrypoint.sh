#!/bin/sh
# Renders the xray config.
set -e

LOG_TAG=xray
# shellcheck source=warp/lib.sh
. /wg-lib.sh

# xray uses the first outbound as the default route.
WARP_OUTBOUND=""
if warp_on; then
  WARP_OUTBOUND='{ "tag": "warp", "protocol": "socks", "settings": { "servers": [ { "address": "warp-wg", "port": 1080 } ] } },'
  echo "[xray] WARP egress ON -> socks5 warp-wg:1080 (load-balanced kernel WARP)"
else
  echo "[xray] WARP egress OFF -> direct (freedom)"
fi

mkdir -p /tmp/xray
cat > /tmp/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "dns": {
    "servers": [ "1.1.1.1", "8.8.8.8" ],
    "queryStrategy": "UseIPv4"
  },
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
        "wsSettings": { "path": "$XRAY_PATH" },
        "sockopt": { "trustedXForwardedFor": [ "X-Forwarded-For" ] }
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
        "xhttpSettings": { "path": "$XRAY_PATH", "mode": "auto" },
        "sockopt": { "trustedXForwardedFor": [ "X-Forwarded-For" ] }
      }
    }
  ],
  "outbounds": [
    $WARP_OUTBOUND
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "blackhole", "tag": "blocked" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "blocked",
        "domain": [ "domain:ir", "geosite:category-ir" ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [ "geoip:ir" ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [
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
        ]
      }
    ]
  }
}
EOF

exec xray run -c /tmp/xray/config.json
