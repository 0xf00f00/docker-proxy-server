# shellcheck shell=sh
# Shared WARP / WireGuard helpers

WARP_EGRESS="${WARP_EGRESS:-true}"

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
