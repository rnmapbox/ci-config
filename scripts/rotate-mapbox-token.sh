#!/usr/bin/env bash
# Creates a fresh scoped public (pk.) Mapbox token via the Tokens API, publishes it
# obfuscated as mapbox-ci-token.v1.enc, and deletes rotated tokens older than 3 days.
# The grace period keeps in-flight CI runs (and raw.githubusercontent caching) working
# through a rotation. Obfuscation only defeats token scrapers — the token is public
# by design; rotation is the actual defense.
set -euo pipefail

: "${MAPBOX_ADMIN_TOKEN:?sk. token with tokens:read + tokens:write scopes}"
: "${MAPBOX_USERNAME:?Mapbox account username}"

KEY_VERSION=v1
NOTE_PREFIX="rnmapbox-ci-rotated"
SCOPES='["styles:tiles","styles:read","fonts:read","datasets:read"]'
API="https://api.mapbox.com/tokens/v2/${MAPBOX_USERNAME}"

resp=$(curl -fsS -X POST "${API}?access_token=${MAPBOX_ADMIN_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"note\":\"${NOTE_PREFIX} $(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"scopes\":${SCOPES}}")
token=$(jq -er .token <<< "$resp")

# -md sha256 instead of -pbkdf2 for LibreSSL compat on the consumer side (macOS runners)
printf '%s' "$token" \
  | openssl enc -aes-256-cbc -base64 -A -md sha256 -k "$(cat "keys/${KEY_VERSION}.key")" \
  > "mapbox-ci-token.${KEY_VERSION}.enc"
echo "published new token (note: ${NOTE_PREFIX}, key: ${KEY_VERSION})"

cutoff=$(date -u -d '3 days ago' +%s)
curl -fsS "${API}?access_token=${MAPBOX_ADMIN_TOKEN}&limit=100" \
  | jq -r --arg p "$NOTE_PREFIX" \
      '.[] | select(.note // "" | startswith($p)) | [.id, .created] | @tsv' \
  | while IFS=$'\t' read -r id created; do
      if [ "$(date -u -d "$created" +%s)" -lt "$cutoff" ]; then
        curl -fsS -X DELETE "${API}/${id}?access_token=${MAPBOX_ADMIN_TOKEN}" > /dev/null
        echo "deleted expired rotated token ${id} (created ${created})"
      fi
    done
