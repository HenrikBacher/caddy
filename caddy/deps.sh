#!/bin/sh
# Creates go.mod/go.sum in the current directory: Caddy and the plugins at the
# given versions, and every dependency raised to its newest patch release.
# Plain go get keeps the oldest version anything requires, so a security fix
# in e.g. golang.org/x/net would otherwise wait for upstream to bump it.
# Used by the Dockerfile and by scripts/resolve-inputs.sh, which hashes the
# result so a new patch release triggers a rebuild.
set -eu
go mod init caddy 2>/dev/null
go get -u=patch \
  "github.com/caddyserver/caddy/v2@${CADDY_REF:?CADDY_REF is required}" \
  "github.com/mholt/caddy-ratelimit@${RATELIMIT_VERSION:-latest}" \
  "github.com/caddy-dns/bunny@${BUNNY_VERSION:-latest}" \
  "github.com/libdns/bunny@${LIBDNS_BUNNY_VERSION:-latest}"
