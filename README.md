# caddy

Weekly rebuild of [hotio/caddy](https://github.com/hotio/caddy) with the newest
Caddy tag, for when hotio's image lags behind upstream.

The image is `ghcr.io/hotio/caddy:release` with only `/app/caddy` replaced by a
fresh `xcaddy` build with the same plugins (`caddy-dns/cloudflare`,
`mholt/caddy-ratelimit`). Env vars, volumes, ports and s6 services are
identical, so it is a drop-in replacement: change the Unraid template's
Repository to `ghcr.io/<owner>/caddy:latest`.

## Tags

| Tag | Meaning |
|---|---|
| `latest`, `2.11.6` | newest `vX.Y.Z` Caddy tag, rebuilt weekly |
| `2.11.6-20261001` | immutable build of that version on that date |
| `master`, `master-20261001` | manual run with `ref: master` |

Builds run Mondays 04:17 UTC, on every push to `main`, and on demand from the
Actions tab (`ref` input takes any Caddy tag, branch or commit). Each build is
tested (plugins present, test Caddyfile adapts, s6 stack serves HTTP) before
anything is pushed.

GitHub disables scheduled workflows in public repos after 60 days without
commits; re-enable from the Actions tab if that happens.
