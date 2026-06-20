#!/bin/sh
# One-shot: register N Cloudflare WARP accounts and render warp1..N.conf into the shared /confs volume.
set -e

# shellcheck source=warp/lib.sh
. /wg-lib.sh
LOG_TAG=warp-reg

MAX_ATTEMPTS="${WARP_REG_MAX_ATTEMPTS:-5}"
N="${WARP_ACCOUNTS:-4}"
CONFS=/confs

# WARP edge endpoints, cycled across warp1..N. Comma or space separated
EPS="${WARP_ENDPOINTS:-engage.cloudflareclient.com:2408}"
EPS=$(printf '%s' "$EPS" | tr ',' ' ')

# ep_for <1-based-index> <endpoint...>  -- cycles through the endpoint list.
ep_for() {
  idx=$1
  shift
  cnt=$#
  while [ "$idx" -gt "$cnt" ]; do idx=$((idx - cnt)); done
  shift $((idx - 1))
  printf '%s' "$1"
}

# Force a clean re-registration (e.g. to change accounts or rotate IPs).
FORCE=0
case "$(printf '%s' "${WARP_FORCE_REGEN:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) FORCE=1 ;;
esac

retry() {
  attempt=1
  delay=3
  until "$@"; do
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      echo "[warp-reg] '$*' failed after $MAX_ATTEMPTS attempts; giving up" >&2
      return 1
    fi
    echo "[warp-reg] '$*' failed (attempt $attempt/$MAX_ATTEMPTS); retry in ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

# render_conf <path> <privkey> <address> <pubkey> <endpoint>
render_conf() {
  cat > "$1" <<EOF
[Interface]
PrivateKey = $2
Address = $3
MTU = 1280
Table = off
PostUp = ip -6 route add default dev %i metric \$((2048 + \$(echo %i | tr -dc 0-9))) || true
PostDown = ip -6 route flush default dev %i 2>/dev/null || true
[Peer]
PublicKey = $4
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $5
PersistentKeepalive = 25
EOF
}

warp_on || { echo "[warp-reg] WARP egress OFF -> skipping registration"; exit 0; }

mkdir -p "$CONFS"
[ "$FORCE" = 1 ] && { echo "[warp-reg] WARP_FORCE_REGEN set -> discarding existing profiles"; rm -f "$CONFS"/warp*.conf; }

n=1
while [ "$n" -le "$N" ]; do
  conf="$CONFS/warp$n.conf"
  ep=$(ep_for "$n" $EPS)

  if [ -f "$conf" ] && grep -q '^PrivateKey' "$conf"; then
    # Reuse the account but re-render so template changes (endpoint, PostUp) apply.
    pk=$(wg_field "$conf" PrivateKey)
    addr=$(wg_field "$conf" Address)
    pub=$(wg_field "$conf" PublicKey)
    render_conf "$conf" "$pk" "$addr" "$pub" "$ep"
    echo "[warp-reg] warp$n reused (endpoint=$ep)."
    n=$((n + 1))
    continue
  fi

  d="/tmp/acct$n"
  rm -rf "$d"
  mkdir -p "$d"
  cd "$d"

  retry /wgcf register --accept-tos
  if [ -n "$WARP_LICENSE_KEY" ]; then
    echo "[warp-reg] applying WARP+ license key to warp$n"
    sed -i "s/^license_key.*/license_key = \"$WARP_LICENSE_KEY\"/" wgcf-account.toml
    retry /wgcf update || echo "[warp-reg] WARN: license update failed; continuing on free tier"
  fi
  retry /wgcf generate

  pk=$(wg_field wgcf-profile.conf PrivateKey)
  pub=$(wg_field wgcf-profile.conf PublicKey)
  addr=$(wg_field wgcf-profile.conf Address)
  if [ -z "$pk" ] || [ -z "$pub" ] || [ -z "$addr" ]; then
    echo "[warp-reg] generated profile for warp$n is incomplete; aborting" >&2
    exit 1
  fi
  render_conf "$conf" "$pk" "$addr" "$pub" "$ep"
  echo "[warp-reg] warp$n generated (endpoint=$ep)."
  n=$((n + 1))
done

echo "[warp-reg] $N WARP profile(s) ready in $CONFS."
