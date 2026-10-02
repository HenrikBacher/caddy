# caddy

Hardened drop-in replacement for [hotio/caddy](https://github.com/hotio/caddy),
rebuilt within a day of any new Caddy, Go, base image or plugin release.

Change the Unraid template's (or compose file's) image from
`ghcr.io/hotio/caddy:release` to `ghcr.io/henrikbacher/caddy:latest`. Nothing else
needs to change, and the existing `/config` is used as-is.

## What stays the same

| | |
|---|---|
| Plugins | `caddy-dns/cloudflare`, `mholt/caddy-ratelimit` |
| Ports | `8080` (HTTP), `8443` (HTTPS, plus `8443/udp` for HTTP/3) |
| Volume | `/config`: `Caddyfile`, certificates and autosave in `/config/caddy` |
| Env | `PUID`, `PGID`, `UMASK`, `TZ`, `FILE__<VAR>` secrets |
| Startup | default `Caddyfile` installed if missing, `caddy fmt --overwrite`, `caddy run` |
| Paths | `/app/caddy`, `/app/www`, `caddy` on `PATH` (`docker exec caddy caddy reload ...` works) |

## What's different

- **Base image**: `gcr.io/distroless/static-debian13` instead of Alpine + s6.
  No shell, no package manager, no `curl`/`bash`/`jq`; 57 MB instead of 139 MB.
- **Entrypoint**: a ~200-line static Go program ([`init/main.go`](init/main.go))
  replaces the s6 scripts. It applies `UMASK`, resolves `FILE__` secrets,
  chowns `/config` and `/config/Caddyfile` to `PUID:PGID`, drops to that user
  with `PGID` as its only group, and execs Caddy as PID 1.
- **Extra plugin**: [`caddy-dns/hetzner/v2`](https://github.com/caddy-dns/hetzner)
  for ACME DNS challenges against [Hetzner Console](https://console.hetzner.com)
  DNS (`dns hetzner {env.HETZNER_API_TOKEN}`, plus `propagation_delay 30s`).
- **Unsupported**: `VPN_ENABLED`, `PRIVOXY_ENABLED`, `UNBOUND_ENABLED` and
  `CUSTOM_BUILD`. Setting any of them stops the container instead of quietly
  running without a VPN.
- **Supply chain**: Caddy is built from source with plain `go build` (no xcaddy), images
  are amd64 only, and every push carries an SBOM, SLSA
  provenance and a keyless cosign signature. Workflow actions are pinned by
  commit SHA and kept current by Dependabot.

## Running it locked down

The default mode starts as root only long enough to chown `/config` and drop
privileges, like hotio. If `/config` is already owned by the right user, skip
that entirely:

```sh
docker run -d --name caddy \
  --user 99:100 --read-only --cap-drop ALL --security-opt no-new-privileges \
  -p 80:8080 -p 443:8443 -p 443:8443/udp \
  -v /mnt/user/appdata/caddy:/config \
  ghcr.io/henrikbacher/caddy:latest
```

On Unraid, put `--user 99:100 --read-only --cap-drop ALL --security-opt no-new-privileges`
in the template's *Extra Parameters*. `PUID`/`PGID` are ignored in this mode.

## Verifying an image

```sh
cosign verify ghcr.io/henrikbacher/caddy:latest \
  --certificate-identity-regexp '^https://github.com/HenrikBacher/caddy/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Tags

| Tag | Meaning |
|---|---|
| `latest`, `2.11.6` | newest `vX.Y.Z` Caddy tag, rebuilt when any input changes |
| `2.11.6-20261001` | immutable build of that version on that date |
| `master`, `master-20261001` | manual run with `ref: master` |

A scheduled check runs hourly at :07 past the hour (UTC).
[`scripts/resolve-inputs.sh`](scripts/resolve-inputs.sh) resolves the newest
Caddy tag, the Go version in `golang:alpine`, the `distroless/static-debian13`
digest and the latest plugin versions, and compares them with the
`io.github.henrikbacher.caddy.inputs` label on the published `:latest` image.
The build runs only when something changed, and uses exactly those resolved
versions (base images pinned by digest). Pushes to `main` and manual runs from
the Actions tab always build (`ref` input takes any Caddy tag, branch or
commit). Each build runs [`test/smoke.sh`](test/smoke.sh)
before anything is pushed: plugins load, the test Caddyfile adapts, there is no
shell, the hotio startup path (PUID 99/PGID 100, default Caddyfile, `FILE__`
secret, `/config/caddy` layout) works, and the locked-down mode serves HTTP.

Run the tests locally with:

```sh
docker build --build-arg CADDY_REF=v2.11.6 -t caddy:test .
test/smoke.sh caddy:test   # DOCKER=podman works too
```

GitHub disables scheduled workflows in public repos after 60 days without
commits; re-enable from the Actions tab if that happens.
