#!/bin/sh
# Creates the SNI DNS records in Cloudflare so you don't have to add them by hand.
# Runs only when CF_DNS_MANAGE=true. Existing records are left untouched unless
# CF_DNS_FORCE=true. Reuses CLOUDFLARE_API_TOKEN.
set -e

API="https://api.cloudflare.com/client/v4"
FAIL=0

truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ---- master switch -----------------------------------------------------------
if ! truthy "${CF_DNS_MANAGE:-false}"; then
  echo "[cf-dns] CF_DNS_MANAGE not enabled -> skipping DNS provisioning (set CF_DNS_MANAGE=true to enable)."
  exit 0
fi

# ---- required inputs ---------------------------------------------------------
: "${CLOUDFLARE_API_TOKEN:?set CLOUDFLARE_API_TOKEN}"
: "${BASE_DOMAIN:?set BASE_DOMAIN}"
: "${VISION_SNI:?set VISION_SNI}"
: "${XHTTP_SNI:?set XHTTP_SNI}"
: "${WS_SNI:?set WS_SNI}"
: "${NAIVE_SNI:?set NAIVE_SNI}"

FORCE=0; truthy "${CF_DNS_FORCE:-false}" && FORCE=1

# Every host must be a subdomain of BASE_DOMAIN.
for _sni in "$VISION_SNI" "$XHTTP_SNI" "$WS_SNI" "$NAIVE_SNI"; do
  case "$_sni" in
    *".$BASE_DOMAIN") ;;
    *) echo "[cf-dns] FATAL: '$_sni' is not a subdomain of $BASE_DOMAIN" >&2; exit 1 ;;
  esac
done

# ---- toolchain --------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "[cf-dns] installing curl + jq..."
  apk add --no-cache --quiet curl jq ca-certificates >/dev/null 2>&1 \
    || { echo "[cf-dns] FATAL: failed to install curl/jq" >&2; exit 1; }
fi

# ---- Cloudflare API call ----------------------------------------------------
cf_raw() { # method path [json-body]
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" "$API$2" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" --data "$3"
  else
    curl -sS -X "$1" "$API$2" \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json"
  fi
}

cf() { # method path [json-body] -- returns the response body, retries on failure
  _try=1
  while :; do
    resp=$(cf_raw "$1" "$2" "${3:-}" 2>/dev/null) || resp=""
    [ -n "$resp" ] && break
    if [ "$_try" -ge 4 ]; then
      echo "[cf-dns] no response from API for $1 $2 after retries" >&2
      return 1
    fi
    echo "[cf-dns] no response ($1 $2), retry $_try/3 in 2s..." >&2
    _try=$((_try + 1)); sleep 2
  done
  if [ "$(printf '%s' "$resp" | jq -r '.success // false')" != "true" ]; then
    echo "[cf-dns] API error ($1 $2): $(printf '%s' "$resp" | jq -rc '.errors // .messages // .')" >&2
    return 1
  fi
  printf '%s' "$resp"
}

# ---- verify token -----------------------------------------------------------
cf GET /user/tokens/verify >/dev/null \
  || { echo "[cf-dns] FATAL: token verification failed (check CLOUDFLARE_API_TOKEN; needs Zone:Read + DNS:Edit)" >&2; exit 1; }

# ---- find the zone for BASE_DOMAIN ------------------------------------------
_d="$BASE_DOMAIN"
ZID=""
while [ -n "$_d" ]; do
  _r=$(cf GET "/zones?name=$_d&status=active") || { echo "[cf-dns] FATAL: zone lookup failed" >&2; exit 1; }
  ZID=$(printf '%s' "$_r" | jq -r '.result[0].id // empty')
  [ -n "$ZID" ] && break
  case "$_d" in
    *.*.*) _d=${_d#*.} ;;   # try the parent domain
    *) break ;;
  esac
done
[ -n "$ZID" ] || { echo "[cf-dns] FATAL: no Cloudflare zone found for $BASE_DOMAIN" >&2; exit 1; }
echo "[cf-dns] zone $BASE_DOMAIN -> $ZID"

# ---- auto-detect the server's public IPv4 -----------------------------------
IPV4=$(curl -4 -sS --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p')
[ -n "$IPV4" ] || IPV4=$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null)
case "$IPV4" in
  *.*.*.*) ;;
  *) echo "[cf-dns] FATAL: could not auto-detect the server's public IPv4" >&2; exit 1 ;;
esac
echo "[cf-dns] target IPv4=$IPV4"

# ---- create or update one A record ------------------------------------------
# record <name> <proxied:true|false>
record() {
  _name=$1; _proxied=$2

  _r=$(cf GET "/zones/$ZID/dns_records?type=A&name=$_name") \
    || { echo "[cf-dns] lookup FAILED for $_name"; FAIL=1; return; }
  _cnt=$(printf '%s' "$_r" | jq -r '.result | length')

  if [ "$_cnt" -gt 1 ]; then
    echo "[cf-dns] WARN: $_cnt A records named $_name already exist -> ambiguous, leaving untouched."
    return
  fi

  _body=$(jq -nc --arg n "$_name" --arg c "$IPV4" --argjson p "$_proxied" \
               '{type:"A",name:$n,content:$c,proxied:$p,ttl:1}')

  if [ "$_cnt" -eq 0 ]; then
    if cf POST "/zones/$ZID/dns_records" "$_body" >/dev/null; then
      echo "[cf-dns] created $_name -> $IPV4 (proxied=$_proxied)"
    else
      echo "[cf-dns] create FAILED for $_name"; FAIL=1
    fi
    return
  fi

  # one exists -- only change it if CF_DNS_FORCE is set
  _id=$(printf '%s' "$_r" | jq -r '.result[0].id')
  _cc=$(printf '%s' "$_r" | jq -r '.result[0].content')
  _cp=$(printf '%s' "$_r" | jq -r '.result[0].proxied')
  if [ "$_cc" = "$IPV4" ] && [ "$_cp" = "$_proxied" ]; then
    echo "[cf-dns] $_name already correct ($IPV4, proxied=$_proxied) -> no-op"
    return
  fi
  if [ "$FORCE" != 1 ]; then
    echo "[cf-dns] SKIP $_name: exists with different value (content=$_cc proxied=$_cp; want content=$IPV4 proxied=$_proxied). Set CF_DNS_FORCE=true to overwrite."
    return
  fi
  if cf PUT "/zones/$ZID/dns_records/$_id" "$_body" >/dev/null; then
    echo "[cf-dns] updated $_name -> $IPV4 (proxied=$_proxied) [forced]"
  else
    echo "[cf-dns] update FAILED for $_name"; FAIL=1
  fi
}

# ---- the records ------------------------------------------------------------
record "$VISION_SNI" false   # grey
record "$XHTTP_SNI"  true    # orange
record "$WS_SNI"     true    # orange
record "$NAIVE_SNI"  false   # grey

if [ "$FAIL" = 0 ]; then
  echo "[cf-dns] done."
else
  echo "[cf-dns] completed WITH ERRORS (see above)." >&2
fi
exit "$FAIL"
