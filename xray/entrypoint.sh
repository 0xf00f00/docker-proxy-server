#!/bin/sh
# Renders the xray config
set -e

LOG_TAG=xray
# shellcheck source=warp/lib.sh
. /wg-lib.sh

# Prepended to outbounds; xray uses the first outbound as the default.
WG_OUTBOUND=""
if warp_on; then
  load_warp_profile

  WG_OUTBOUND=$(cat <<JSON
    {
      "protocol": "wireguard",
      "tag": "warp",
      "settings": {
        "secretKey": "$WG_KEY",
        "address": [ $WG_ADDRS ],
        "peers": [
          {
            "publicKey": "$WG_PEER",
            "endpoint": "$WG_ENDPOINT",
            "allowedIPs": [ "0.0.0.0/0", "::/0" ],
            "keepAlive": 25
          }
        ],
        "mtu": 1280
      }
    },
JSON
)
  echo "[xray] WARP egress ON -> WireGuard outbound via $WG_ENDPOINT"
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
$WG_OUTBOUND
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
