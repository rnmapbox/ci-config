# ci-config

Holds the rotating public Mapbox access tokens used by `rnmapbox/maps` CI for
fork PRs, where GitHub Actions provides no secrets, and by the web/Expo Snack
examples.

## Security model

The token here is **public by design** — anyone can fetch and decode it, and any
fork PR could print whatever token CI uses anyway. Defense is not secrecy but:

- a dedicated `pk.` token with minimal read scopes (`styles:tiles`, `styles:read`,
  `fonts:read`, `datasets:read`)
- automatic rotation twice a week ([rotate.yml](.github/workflows/rotate.yml)),
  which also deletes rotated tokens older than 3 days
- no credit card on the Mapbox account: abuse can only exhaust the free tier
  (map tiles 403 until the month resets), never generate charges. A dedicated
  CI-only account would additionally isolate quota, but Mapbox signups now
  require a card, so the tokens live on the existing no-card account.
- kill switch: deleting `mapbox-ci-token.*.enc` and disabling the rotate cron
  instantly reverts fork CI to the no-token world, with no change to the maps repo

The AES layer is **obfuscation only**: it keeps the raw `pk.` string out of
GitHub secret scanning and token-scraper bots. The obfuscation key is public
(`keys/v1.key`, mirrored in `scripts/ci/fetch-mapbox-token.sh` in the maps repo).

URL restrictions (`allowedUrls`) were considered and rejected for the CI token:
they rely on the browser Referer header and don't work with the native Maps SDK,
which the iOS Detox CI job uses — a restricted token would break the only job
that renders maps.

The Snack token is a separate token (note prefix `rnmapbox-snack-rotated`) so
Snack traffic can be traced and revoked without touching CI. It only runs in
browsers, so it is restricted to `https://snack-runtime.eascdn.net` (Snack's web
player), `https://snack.expo.dev` and `https://rnmapbox.github.io`. It is
base64-encoded rather than AES-obfuscated so browser JS can decode it with
`atob`; that still keeps the raw `pk.` string out of scrapers.

## Files

- `mapbox-ci-token.v1.enc` — the current token, AES-256-CBC (`-md sha256`, base64,
  keyed with `keys/v1.key`). Written by the rotate workflow.
- `mapbox-snack-token.txt` — the current Snack token, base64. Written by the
  rotate workflow.
- `keys/v1.key` — obfuscation key, versioned.
- `scripts/rotate-mapbox-token.sh ci|snack` — creates a fresh token of that kind
  via the Mapbox Tokens API, publishes it, deletes expired tokens of that kind.

Decode manually:

```sh
curl -fsSL https://raw.githubusercontent.com/rnmapbox/ci-config/main/mapbox-ci-token.v1.enc \
  | openssl enc -d -aes-256-cbc -base64 -A -md sha256 -k "$(cat keys/v1.key)"
```

Fetch the Snack token from JS:

```js
const token = atob((await (await fetch('https://raw.githubusercontent.com/rnmapbox/ci-config/main/mapbox-snack-token.txt')).text()).trim());
```

## Setup

1. Repo secret `MAPBOX_ADMIN_TOKEN`: an `sk.` token with `tokens:read` +
   `tokens:write` scopes (create at https://account.mapbox.com/access-tokens/).
2. Repo variable `MAPBOX_USERNAME`: the Mapbox account username the tokens
   belong to.
3. Run the "Rotate Mapbox tokens" workflow manually once to seed
   `mapbox-ci-token.v1.enc` and `mapbox-snack-token.txt`.

## Rotating the obfuscation key

1. `openssl rand -hex 16 > keys/v2.key`, bump `KEY_VERSION` in
   `scripts/rotate-mapbox-token.sh`, run the rotate workflow (publishes
   `mapbox-ci-token.v2.enc`).
2. Update `URL` and `OBFUSCATION_KEY` in `scripts/ci/fetch-mapbox-token.sh` in
   the maps repo.
3. Keep the old `.enc` file until release branches referencing it are gone.
