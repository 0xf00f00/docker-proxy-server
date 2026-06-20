#!/bin/sh
# Derives PROXY_AUTH_B64 so the Caddyfile can gate CONNECT on the EXACT Basic credential
set -e
export PROXY_AUTH_B64="$(printf '%s:%s' "$PROXY_USER" "$PROXY_PASSWORD" | base64 | tr -d '\n')"
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
