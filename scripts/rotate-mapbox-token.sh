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
SCOPES='["styles:tiles","styles:read","fonts:read"]'
API="https://api.mapbox.com/tokens/v2/${MAPBOX_USERNAME}"

# Prints the response body on stdout; on a non-2xx status prints method/URL/body
# to stderr and returns non-zero, since -f alone hides the reason for a failure.
api_call() {
  local method=$1 url=$2 data=${3:-} resp code body
  if [ -n "$data" ]; then
    resp=$(curl -sS -X "$method" "$url" -H 'Content-Type: application/json' -d "$data" -w $'\n%{http_code}')
  else
    resp=$(curl -sS -X "$method" "$url" -w $'\n%{http_code}')
  fi
  code=$(tail -n1 <<< "$resp")
  body=$(sed '$d' <<< "$resp")
  if [ "$code" -lt 200 ] || [ "$code" -ge 300 ]; then
    echo "Mapbox API ${method} ${url%%\?*} -> HTTP ${code}" >&2
    echo "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

resp=$(api_call POST "${API}?access_token=${MAPBOX_ADMIN_TOKEN}" \
  "{\"note\":\"${NOTE_PREFIX} $(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"scopes\":${SCOPES}}")
token=$(jq -er .token <<< "$resp")

# -md sha256 instead of -pbkdf2 for LibreSSL compat on the consumer side (macOS runners)
printf '%s' "$token" \
  | openssl enc -aes-256-cbc -base64 -A -md sha256 -k "$(cat "keys/${KEY_VERSION}.key")" \
  > "mapbox-ci-token.${KEY_VERSION}.enc"
echo "published new token (note: ${NOTE_PREFIX}, key: ${KEY_VERSION})"

cutoff=$(date -u -d '3 days ago' +%s)
api_call GET "${API}?access_token=${MAPBOX_ADMIN_TOKEN}&limit=100" \
  | jq -r --arg p "$NOTE_PREFIX" \
      '.[] | select(.note // "" | startswith($p)) | [.id, .created] | @tsv' \
  | while IFS=$'\t' read -r id created; do
      if [ "$(date -u -d "$created" +%s)" -lt "$cutoff" ]; then
        api_call DELETE "${API}/${id}?access_token=${MAPBOX_ADMIN_TOKEN}" > /dev/null
        echo "deleted expired rotated token ${id} (created ${created})"
      fi
    done
