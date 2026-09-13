# ci-config

Holds the rotating public Mapbox access token used by `rnmapbox/maps` CI for
fork PRs, where GitHub Actions provides no secrets.

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

URL restrictions (`allowedUrls`) were considered and rejected: they rely on the
browser Referer header and don't work with the native Maps SDK, which the iOS
Detox CI job uses — a restricted token would break the only job that renders maps.

## Files

- `mapbox-ci-token.v1.enc` — the current token, AES-256-CBC (`-md sha256`, base64,
  keyed with `keys/v1.key`). Written by the rotate workflow.
- `keys/v1.key` — obfuscation key, versioned.
- `scripts/rotate-mapbox-token.sh` — creates a fresh token via the Mapbox Tokens
  API, publishes it, deletes expired rotated tokens.

Decode manually:

```sh
curl -fsSL https://raw.githubusercontent.com/rnmapbox/ci-config/main/mapbox-ci-token.v1.enc \
  | openssl enc -d -aes-256-cbc -base64 -A -md sha256 -k "$(cat keys/v1.key)"
```

## Setup

1. Repo secret `MAPBOX_ADMIN_TOKEN`: an `sk.` token with `tokens:read` +
   `tokens:write` scopes (create at https://account.mapbox.com/access-tokens/).
2. Repo variable `MAPBOX_USERNAME`: the Mapbox account username the tokens
   belong to.
3. Run the "Rotate CI Mapbox token" workflow manually once to seed
   `mapbox-ci-token.v1.enc`.

## Rotating the obfuscation key

1. `openssl rand -hex 16 > keys/v2.key`, bump `KEY_VERSION` in
   `scripts/rotate-mapbox-token.sh`, run the rotate workflow (publishes
   `mapbox-ci-token.v2.enc`).
2. Update `URL` and `OBFUSCATION_KEY` in `scripts/ci/fetch-mapbox-token.sh` in
   the maps repo.
3. Keep the old `.enc` file until release branches referencing it are gone.
