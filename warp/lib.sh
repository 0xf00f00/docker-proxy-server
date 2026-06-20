# shellcheck shell=sh
# Shared WARP / WireGuard helpers

WARP_EGRESS="${WARP_EGRESS:-true}"
WARP_PROFILE="${WARP_PROFILE:-/warp/wgcf-profile.conf}"
LOG_TAG="${LOG_TAG:-warp}"

warp_on() {
  case "$(printf '%s' "$WARP_EGRESS" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

# Read one "Key = value" field from the wgcf profile at $1.
wg_field() {
  sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$1" | tr -d '\r'
}

# Split a WireGuard "host:port" / "[ipv6]:port" endpoint ($1) into the globals
# _ep_host (brackets stripped) and _ep_port. IPv6 literals must be bracketed --
# that is WireGuard's own Endpoint format, and a bare v6 address is ambiguous to
# split on ":". Returns non-zero unless both a host and a numeric port are found.
parse_endpoint() {
  case "$1" in
    \[*\]:*)                       # [ipv6]:port
      _ep_host="${1#\[}"; _ep_host="${_ep_host%%]*}"
      _ep_port="${1##*]:}"
      ;;
    *:*)                           # host:port (IPv4 / hostname)
      _ep_host="${1%:*}"
      _ep_port="${1##*:}"
      ;;
    *) return 1 ;;
  esac
  [ -n "$_ep_host" ] || return 1
  case "$_ep_port" in ''|*[!0-9]*) return 1 ;; esac
  return 0
}

warp_profile_valid() {
  [ -r "$1" ] || return 1
  [ -n "$(wg_field "$1" PrivateKey)" ] || return 1
  [ -n "$(wg_field "$1" PublicKey)" ]  || return 1
  [ -n "$(wg_field "$1" Address)" ]    || return 1
  parse_endpoint "$(wg_field "$1" Endpoint)" || return 1
}

load_warp_profile() {
  if [ ! -r "$WARP_PROFILE" ]; then
    echo "[$LOG_TAG] FATAL: WARP_EGRESS requested but WARP profile $WARP_PROFILE is missing/unreadable." >&2
    echo "[$LOG_TAG] Refusing to start with direct egress (would leak real IP). Is the warp-reg init container healthy?" >&2
    exit 1
  fi
  if ! warp_profile_valid "$WARP_PROFILE"; then
    echo "[$LOG_TAG] FATAL: WARP profile $WARP_PROFILE is incomplete (missing key/address/peer/endpoint)." >&2
    exit 1
  fi

  WG_KEY=$(wg_field "$WARP_PROFILE" PrivateKey)
  WG_PEER=$(wg_field "$WARP_PROFILE" PublicKey)
  WG_ENDPOINT=$(wg_field "$WARP_PROFILE" Endpoint)
  parse_endpoint "$WG_ENDPOINT"
  WG_HOST="$_ep_host"
  WG_PORT="$_ep_port"

  WG_ADDRS=""
  for _a in $(wg_field "$WARP_PROFILE" Address | tr ',\n' '  '); do
    [ -n "$_a" ] || continue
    WG_ADDRS="${WG_ADDRS:+$WG_ADDRS, }\"$_a\""
  done
}
