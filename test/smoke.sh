#!/usr/bin/env bash
# Smoke-tests an image built from this repo: plugins, the hotio-compatible
# startup path (PUID/PGID, default Caddyfile, FILE__ secrets, /config layout)
# and the hardened non-root mode. Usage: test/smoke.sh IMAGE
set -euo pipefail

IMAGE=${1:?usage: $0 IMAGE}
DOCKER=${DOCKER:-$(command -v docker || command -v podman)}
HELPER=${HELPER:-docker.io/library/busybox:stable}
CURL=${CURL:-docker.io/curlimages/curl:latest}
cd "$(dirname "$0")"

id=$$
vol=caddy-smoke-$id
tmp=$(mktemp -d)
containers=()
cleanup() {
  for c in "${containers[@]}"; do $DOCKER rm -f "$c" >/dev/null 2>&1 || true; done
  $DOCKER volume rm -f "$vol" >/dev/null 2>&1 || true
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; for c in "${containers[@]}"; do echo "--- $c" >&2; $DOCKER logs "$c" >&2 || true; done; exit 1; }
ok() { echo "ok: $*"; }

caddy() { $DOCKER run --rm -v "$PWD:/test:ro" --entrypoint /app/caddy "$IMAGE" "$@"; }
in_vol() { $DOCKER run --rm -v "$vol:/config" "$HELPER" "$@"; }
# curl from inside the container's network namespace: the default Caddyfile
# aborts requests from non-private addresses.
get() { $DOCKER run --rm --network "container:$1" "$CURL" -fsS --retry 15 --retry-delay 1 --retry-all-errors "http://localhost:8080${2:-/}"; }

caddy version
caddy list-modules >modules.txt
grep -qx dns.providers.cloudflare modules.txt || fail "cloudflare DNS module missing"
grep -qx dns.providers.desec modules.txt || fail "desec DNS module missing"
grep -qx http.handlers.rate_limit modules.txt || fail "rate_limit module missing"
rm -f modules.txt
caddy adapt --config /test/Caddyfile --adapter caddyfile >/dev/null
ok "plugins present, test Caddyfile adapts"

if $DOCKER run --rm --entrypoint /bin/sh "$IMAGE" -c true >/dev/null 2>&1; then
  fail "image has a shell"
fi
ok "no shell in image"

# hotio-compatible mode: start as root, drop to PUID:PGID (Unraid defaults).
$DOCKER volume create "$vol" >/dev/null
printf 'secret-value\n' >"$tmp/secret"
chmod 644 "$tmp/secret"
c=caddy-smoke-root-$id; containers+=("$c")
$DOCKER run -d --name "$c" -v "$vol:/config" -v "$tmp/secret:/run/secret:ro" \
  -e PUID=99 -e PGID=100 -e UMASK=002 -e FILE__CF_TOKEN=/run/secret "$IMAGE" >/dev/null
get "$c" | grep -qi caddy || fail "default page not served"
ok "default Caddyfile serves /app/www"

[ "$(in_vol stat -c %u:%g /config /config/Caddyfile | sort -u)" = 99:100 ] || fail "/config not owned by 99:100"
in_vol test -d /config/caddy || fail "Caddy data dir not at /config/caddy"
in_vol test -f /config/caddy/autosave.json || fail "autosave.json not at /config/caddy"
ok "/config layout and ownership match hotio"

# Inspect PID 1 (caddy) from a helper sharing the container's PID namespace.
pid1() { $DOCKER run --rm --pid "container:$c" --user 99:100 "$HELPER" "$@"; }
uids=$(pid1 awk '/^Uid:/{print $2, $3, $4, $5}' /proc/1/status)
[ "$uids" = "99 99 99 99" ] || fail "caddy uids are '$uids', want 99"
[ "$(pid1 awk '/^Groups:/{print $2}' /proc/1/status)" = 100 ] || fail "unexpected supplementary groups"
pid1 sh -c 'tr "\0" "\n" </proc/1/environ' | grep -qx CF_TOKEN=secret-value || fail "FILE__CF_TOKEN not loaded"
ok "caddy runs as 99 with FILE__ secret loaded"

$DOCKER exec "$c" caddy reload --config /config/Caddyfile --adapter caddyfile
ok "docker exec caddy reload works"
$DOCKER stop "$c" >/dev/null

# Hardened mode: fixed non-root user, read-only rootfs, no capabilities.
c=caddy-smoke-user-$id; containers+=("$c")
$DOCKER run -d --name "$c" -v "$vol:/config" --user 99:100 --read-only \
  --cap-drop ALL --security-opt no-new-privileges "$IMAGE" >/dev/null
get "$c" | grep -qi caddy || fail "hardened mode not serving"
ok "--user 99:100 --read-only --cap-drop ALL works"

# Unsupported hotio features fail loudly.
if $DOCKER run --rm -e VPN_ENABLED=true "$IMAGE" >/dev/null 2>&1; then
  fail "VPN_ENABLED=true did not fail"
fi
ok "VPN_ENABLED=true is rejected"
echo "all smoke tests passed"
