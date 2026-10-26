#!/usr/bin/env bash
# Usage: rotate-mapbox-token.sh [ci|snack]
# Creates a fresh scoped public (pk.) Mapbox token via the Tokens API, publishes it,
# and deletes tokens of the same kind older than 3 days.
#   ci:    obfuscated as mapbox-ci-token.v1.enc, for rnmapbox/maps fork-PR CI
#   snack: base64 as mapbox-snack-token.txt, URL-restricted, for web/Expo Snack examples
# The grace period keeps in-flight CI runs (and raw.githubusercontent caching) working
# through a rotation. Obfuscation only defeats token scrapers — the token is public
# by design; rotation is the actual defense.
set -euo pipefail

: "${MAPBOX_ADMIN_TOKEN:?sk. token with tokens:read + tokens:write scopes}"
: "${MAPBOX_USERNAME:?Mapbox account username}"

KIND=${1:-ci}
KEY_VERSION=v1
# Cleanup matches "<prefix> " so neither kind can delete the other's tokens.
case "$KIND" in
  ci)
    NOTE_PREFIX="rnmapbox-ci-rotated"
    ALLOWED_URLS=""
    ;;
  snack)
    NOTE_PREFIX="rnmapbox-snack-rotated"
    # Snack's web preview runs in an iframe served from snack-runtime.eascdn.net
    # (SNACK_WEBPLAYER_URL in expo/snack's production config).
    ALLOWED_URLS='["https://snack-runtime.eascdn.net","https://snack.expo.dev","https://rnmapbox.github.io"]'
    ;;
  *)
    echo "unknown token kind: $KIND (expected ci or snack)" >&2
    exit 1
    ;;
esac
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

body="{\"note\":\"${NOTE_PREFIX} $(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"scopes\":${SCOPES}"
[ -n "$ALLOWED_URLS" ] && body+=",\"allowedUrls\":${ALLOWED_URLS}"
resp=$(api_call POST "${API}?access_token=${MAPBOX_ADMIN_TOKEN}" "${body}}")
token=$(jq -er .token <<< "$resp")

if [ "$KIND" = ci ]; then
  # -md sha256 instead of -pbkdf2 for LibreSSL compat on the consumer side (macOS runners)
  printf '%s' "$token" \
    | openssl enc -aes-256-cbc -base64 -A -md sha256 -k "$(cat "keys/${KEY_VERSION}.key")" \
    > "mapbox-ci-token.${KEY_VERSION}.enc"
  echo "published new token (note: ${NOTE_PREFIX}, key: ${KEY_VERSION})"
else
  # base64 so browser JS can atob() it without crypto while keeping the raw pk. out of scrapers
  printf '%s' "$token" | base64 | tr -d '\n' > mapbox-snack-token.txt
  echo "published new token (note: ${NOTE_PREFIX})"
fi

cutoff=$(date -u -d '3 days ago' +%s)
api_call GET "${API}?access_token=${MAPBOX_ADMIN_TOKEN}&limit=100" \
  | jq -r --arg p "$NOTE_PREFIX" \
      '.[] | select(.note // "" | startswith($p + " ")) | [.id, .created] | @tsv' \
  | while IFS=$'\t' read -r id created; do
      if [ "$(date -u -d "$created" +%s)" -lt "$cutoff" ]; then
        api_call DELETE "${API}/${id}?access_token=${MAPBOX_ADMIN_TOKEN}" > /dev/null
        echo "deleted expired ${KIND} token ${id} (created ${created})"
      fi
    done
