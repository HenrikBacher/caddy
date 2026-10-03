#!/usr/bin/env bash
# Resolves everything that ends up in the image to exact versions/digests and
# prints them as key=value lines (for $GITHUB_OUTPUT):
#
#   ref                Caddy ref to build ($1, or the newest vX.Y.Z tag)
#   go_image           golang:alpine pinned by digest (builder)
#   base_image         distroless static pinned by digest (runtime base)
#   base_digest        digest of base_image
#   cloudflare_version caddy-dns/cloudflare latest version
#   bunny_version      caddy-dns/bunny latest version
#   libdns_bunny_version
#                      libdns/bunny latest version; caddy-dns/bunny pins an
#                      older one without HTTPS records, which ECH needs
#   ratelimit_version  mholt/caddy-ratelimit latest version
#   inputs             one-line summary of the above that affects the output
#                      binary/image; stored as an image label and compared on
#                      scheduled runs to decide whether to rebuild
#   published_inputs   the inputs label of $IMAGE:latest ("" if none)
#
# Usage: IMAGE=ghcr.io/owner/caddy scripts/resolve-inputs.sh [caddy-ref]
set -euo pipefail

GO_REPO=library/golang GO_TAG=alpine
BASE_REPO=distroless/static-debian13 BASE_TAG=latest
INPUTS_LABEL=io.github.henrikbacher.caddy.inputs
ACCEPT='application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json'

# Anonymous bearer token for a public repository, following the registry's
# WWW-Authenticate challenge.
token() {
  local registry=$1 repo=$2 challenge realm service
  challenge=$(curl -sSI "https://$registry/v2/$repo/manifests/latest" | tr -d '\r' \
    | sed -n 's/^[Ww][Ww][Ww]-[Aa]uthenticate: *Bearer *//p')
  [ -n "$challenge" ] || return 0
  realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$challenge")
  service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$challenge")
  curl -fsS -G "$realm" --data-urlencode "service=$service" --data-urlencode "scope=repository:$repo:pull" \
    | jq -r '.token // .access_token'
}

# get REGISTRY REPO TOKEN PATH: GET /v2/REPO/PATH, following blob redirects.
get() {
  curl -fsSL -H "Accept: $ACCEPT" ${3:+-H "Authorization: Bearer $3"} "https://$1/v2/$2/$4"
}

# Digest of a tag's manifest (index for multi-arch images).
digest() {
  local t; t=$(token "$1" "$2")
  echo "sha256:$(get "$1" "$2" "$t" "manifests/$3" | sha256sum | cut -d' ' -f1)"
}

# Image config (JSON) of the linux/amd64 variant of REGISTRY/REPO:TAG; fails if
# the tag does not exist.
amd64_config() {
  local t manifest
  t=$(token "$1" "$2")
  manifest=$(get "$1" "$2" "$t" "manifests/$3")
  if jq -e '.manifests' >/dev/null <<<"$manifest"; then
    manifest=$(get "$1" "$2" "$t" "manifests/$(jq -r \
      '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest' \
      <<<"$manifest" | head -1)")
  fi
  get "$1" "$2" "$t" "blobs/$(jq -r .config.digest <<<"$manifest")"
}

latest_module() { curl -fsS "https://proxy.golang.org/$1/@latest" | jq -r .Version; }

ref=${1:-}
if [ -z "$ref" ]; then
  # Newest stable tag. Uses git tags rather than GitHub releases, so a version
  # is picked up even if upstream's release publishing lags.
  ref=$(git ls-remote --tags --refs https://github.com/caddyserver/caddy.git 'v2.*' \
    | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
fi
[[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "invalid ref: $ref" >&2; exit 1; }

go_digest=$(digest registry-1.docker.io "$GO_REPO" "$GO_TAG")
go_version=$(amd64_config registry-1.docker.io "$GO_REPO" "$GO_TAG" \
  | jq -r '.config.Env[] | select(startswith("GOLANG_VERSION=")) | sub("GOLANG_VERSION="; "")')
base_digest=$(digest gcr.io "$BASE_REPO" "$BASE_TAG")
cloudflare=$(latest_module github.com/caddy-dns/cloudflare)
bunny=$(latest_module github.com/caddy-dns/bunny)
libdns_bunny=$(latest_module github.com/libdns/bunny)
ratelimit=$(latest_module github.com/mholt/caddy-ratelimit)

published=""
if [ -n "${IMAGE:-}" ]; then
  registry=${IMAGE%%/*} repo=${IMAGE#*/}
  published=$(amd64_config "$registry" "$repo" latest 2>/dev/null \
    | jq -r --arg k "$INPUTS_LABEL" '.config.Labels[$k] // empty') || published=""
fi

# The builder's Alpine layers don't reach the static binary, so only the Go
# version (not the golang:alpine digest) counts as an input.
cat <<OUT
ref=$ref
go_image=golang:$GO_TAG@$go_digest
base_image=gcr.io/$BASE_REPO@$base_digest
base_digest=$base_digest
cloudflare_version=$cloudflare
bunny_version=$bunny
libdns_bunny_version=$libdns_bunny
ratelimit_version=$ratelimit
inputs=caddy=$ref go=$go_version base=$base_digest cloudflare=$cloudflare bunny=$bunny libdns_bunny=$libdns_bunny ratelimit=$ratelimit
published_inputs=$published
OUT
