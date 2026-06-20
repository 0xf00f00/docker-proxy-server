#!/bin/sh
# One-shot wgcf registration -> writes wgcf-profile.conf to the shared /profile volume.
set -e

# shellcheck source=warp/lib.sh
. /wg-lib.sh

MAX_ATTEMPTS="${WARP_REG_MAX_ATTEMPTS:-5}"
PROFILE=wgcf-profile.conf

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

warp_on || { echo "[warp-reg] WARP egress OFF -> skipping registration"; exit 0; }

cd /profile

if [ -f "$PROFILE" ]; then
  if warp_profile_valid "$PROFILE"; then
    echo "[warp-reg] WARP profile already present; reusing."
    exit 0
  fi
  echo "[warp-reg] existing profile is invalid; regenerating." >&2
  rm -f "$PROFILE"
fi

[ -f wgcf-account.toml ] || retry /wgcf register --accept-tos

if [ -n "$WARP_LICENSE_KEY" ]; then
  echo "[warp-reg] applying WARP+ license key"
  sed -i "s/^license_key.*/license_key = \"$WARP_LICENSE_KEY\"/" wgcf-account.toml
  retry /wgcf update || echo "[warp-reg] WARN: license update failed; continuing on free tier"
fi

retry /wgcf generate

if ! warp_profile_valid "$PROFILE"; then
  echo "[warp-reg] generated profile failed validation; removing it" >&2
  rm -f "$PROFILE"
  exit 1
fi
echo "[warp-reg] WARP profile generated."
