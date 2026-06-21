#!/bin/sh
# Renders the HAProxy config and runs it.
set -e

: "${VISION_SNI:?set VISION_SNI}"
: "${XHTTP_SNI:?set XHTTP_SNI}"
: "${WS_SNI:?set WS_SNI}"
: "${BASE_DOMAIN:?set BASE_DOMAIN}"

# Vision/XHTTP/WS terminate TLS with the *.BASE_DOMAIN wildcard, so they MUST be subdomains of it.
for _sni in "$VISION_SNI" "$XHTTP_SNI" "$WS_SNI"; do
	case "$_sni" in
		*".$BASE_DOMAIN") ;;
		*) echo "[haproxy] FATAL: '$_sni' is not a subdomain of $BASE_DOMAIN (not covered by the wildcard cert)" >&2; exit 1 ;;
	esac
done

cat > /tmp/haproxy.cfg <<EOF
global
	log stdout format raw local0 notice

defaults
	mode tcp
	log global
	# Kernel zero-copy for the raw passthrough (lower CPU on bulk transfers).
	option splice-auto
	timeout connect    5s
	timeout client     1h
	timeout server     1h
	timeout tunnel     1h
	timeout client-fin 30s
	timeout server-fin 30s

# Resolve backend container names at runtime via Docker's embedded DNS, so
# HAProxy starts even if a backend is briefly down and re-resolves on restart.
resolvers docker
	nameserver dns 127.0.0.11:53
	resolve_retries 3
	timeout resolve 1s
	timeout retry   1s
	hold valid      10s

# Plain HTTP -> Caddy (handles HTTP->HTTPS redirect; DNS-01 means no HTTP ACME).
frontend http_in
	bind :80
	default_backend caddy_http

# TLS on :443 routed by SNI, no termination (kernel-spliced passthrough).
frontend https_in
	bind :443
	tcp-request inspect-delay 5s
	tcp-request content accept if { req_ssl_hello_type 1 }
	use_backend xray_vision if { req_ssl_sni -i ${VISION_SNI} }
	use_backend xray_xhttp  if { req_ssl_sni -i ${XHTTP_SNI} }
	use_backend xray_ws     if { req_ssl_sni -i ${WS_SNI} }
	default_backend caddy_tls

backend xray_vision
	server s xray:8443 check resolvers docker init-addr none

backend xray_xhttp
	server s xray:8444 check resolvers docker init-addr none

backend xray_ws
	server s xray:8445 check resolvers docker init-addr none

backend caddy_tls
	server s caddy:443 check resolvers docker init-addr none

backend caddy_http
	server s caddy:80 check resolvers docker init-addr none
EOF

echo "[haproxy] SNI routes: ${VISION_SNI}->xray:8443 (vision/reality), ${XHTTP_SNI}->xray:8444 (xhttp), ${WS_SNI}->xray:8445 (ws), *->caddy"

haproxy -c -f /tmp/haproxy.cfg
exec haproxy -f /tmp/haproxy.cfg
