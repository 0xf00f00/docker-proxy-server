#!/bin/sh
# Renders the xray config.
set -e

LOG_TAG=xray
# shellcheck source=warp/lib.sh
. /wg-lib.sh

: "${VISION_SNI:?set VISION_SNI}"

# xray uses the first outbound as the default route.
WARP_OUTBOUND=""
if warp_on; then
  WARP_OUTBOUND='{ "tag": "warp", "protocol": "socks", "settings": { "servers": [ { "address": "warp-wg", "port": 1080 } ] } },'
  echo "[xray] WARP egress ON -> socks5 warp-wg:1080 (load-balanced kernel WARP)"
else
  echo "[xray] WARP egress OFF -> direct (freedom)"
fi

echo "[xray] waiting for wildcard cert for ${BASE_DOMAIN} (Vision/XHTTP/WS TLS) ..."
CERT_CRT=""
CERT_KEY=""
i=0
while [ "$i" -lt 150 ]; do
  CERT_DIR=$(ls -d /caddy-data/caddy/certificates/*/wildcard_.${BASE_DOMAIN} 2>/dev/null | head -1)
  if [ -n "$CERT_DIR" ] \
     && [ -s "${CERT_DIR}/wildcard_.${BASE_DOMAIN}.crt" ] \
     && [ -s "${CERT_DIR}/wildcard_.${BASE_DOMAIN}.key" ]; then
    CERT_CRT="${CERT_DIR}/wildcard_.${BASE_DOMAIN}.crt"
    CERT_KEY="${CERT_DIR}/wildcard_.${BASE_DOMAIN}.key"
    break
  fi
  i=$((i + 1))
  sleep 2
done
if [ -z "$CERT_CRT" ]; then
  echo "[xray] FATAL: wildcard cert for ${BASE_DOMAIN} not found under /caddy-data after ~5min." >&2
  echo "[xray]   Is Caddy issuing *.${BASE_DOMAIN}? Did acme_ca / BASE_DOMAIN change?" >&2
  exit 1
fi
echo "[xray] wildcard cert: ${CERT_CRT} (hot-reloaded on renewal; oneTimeLoading default false)"

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
      "tag": "vision-in",
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$VISION_SNI",
          "alpn": [ "h2", "http/1.1" ],
          "certificates": [ { "certificateFile": "$CERT_CRT", "keyFile": "$CERT_KEY" } ]
        }
      }
    },
    {
      "tag": "xhttp-in",
      "listen": "0.0.0.0",
      "port": 8444,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "tls",
        "sockopt": { "trustedXForwardedFor": [ "CF-Connecting-IP", "X-Forwarded-For" ] },
        "tlsSettings": {
          "alpn": [ "h2", "http/1.1" ],
          "certificates": [ { "certificateFile": "$CERT_CRT", "keyFile": "$CERT_KEY" } ]
        },
        "xhttpSettings": { "path": "$XRAY_PATH", "mode": "auto" }
      }
    },
    {
      "tag": "ws-in",
      "listen": "0.0.0.0",
      "port": 8445,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "$XRAY_UUID" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "sockopt": { "trustedXForwardedFor": [ "CF-Connecting-IP", "X-Forwarded-For" ] },
        "tlsSettings": {
          "alpn": [ "http/1.1" ],
          "certificates": [ { "certificateFile": "$CERT_CRT", "keyFile": "$CERT_KEY" } ]
        },
        "wsSettings": { "path": "$XRAY_PATH" }
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

echo "[xray] validating rendered config ..."
xray run -test -c /tmp/xray/config.json

exec xray run -c /tmp/xray/config.json
