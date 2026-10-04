# syntax=docker/dockerfile:1
# Hardened drop-in replacement for ghcr.io/hotio/caddy: same paths, ports,
# env vars and /config layout, but a distroless base with no shell, package
# manager or s6, and Caddy built fresh from source with the same plugins.

# CI passes digest-pinned images and exact plugin versions from
# scripts/resolve-inputs.sh; the defaults are for local builds.
ARG GO_IMAGE=golang:alpine
ARG BASE_IMAGE=gcr.io/distroless/static-debian13
ARG HOTIO_IMAGE=ghcr.io/hotio/caddy:release

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS builder
ARG CADDY_REF
ARG BUNNY_VERSION=latest
ARG LIBDNS_BUNNY_VERSION=latest
ARG RATELIMIT_VERSION=latest
ARG TARGETOS
ARG TARGETARCH
ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH
# What xcaddy does, without installing it. Resolving Caddy and the plugins in
# one go get makes a plugin that needs a different Caddy fail the build
# instead of silently changing the Caddy version. -mod=mod records checksums
# for exactly the packages compiled; the tags match xcaddy's.
COPY caddy/main.go /src/caddy/
RUN cd /src/caddy && go mod init caddy \
 && go get "github.com/caddyserver/caddy/v2@${CADDY_REF:?CADDY_REF is required}" \
        "github.com/mholt/caddy-ratelimit@${RATELIMIT_VERSION}" \
        "github.com/caddy-dns/bunny@${BUNNY_VERSION}" \
        "github.com/libdns/bunny@${LIBDNS_BUNNY_VERSION}" \
 && go build -mod=mod -trimpath -ldflags="-s -w" -tags nobadger,nomysql,nopgx -o /rootfs/app/caddy .
COPY init/ /src/init/
RUN cd /src/init && go build -trimpath -ldflags="-s -w" -o /rootfs/init . \
 && mkdir -p /rootfs/usr/local/bin /rootfs/config \
 && ln -s /app/caddy /rootfs/usr/local/bin/caddy

# Default Caddyfile and landing page, taken verbatim from hotio's image.
FROM ${HOTIO_IMAGE} AS hotio

FROM ${BASE_IMAGE}
COPY --from=builder /rootfs/ /
COPY --from=hotio /app/Caddyfile /app/Caddyfile
COPY --from=hotio /app/www/ /app/www/
ENV APP_DIR=/app \
    CONFIG_DIR=/config \
    XDG_CONFIG_HOME=/config/.config \
    XDG_CACHE_HOME=/config/.cache \
    XDG_DATA_HOME=/config/.local/share \
    PUID=1000 \
    PGID=1000 \
    UMASK=002 \
    TZ=Etc/UTC \
    WEBUI_PORTS=8080/tcp,8443/tcp
EXPOSE 8080/tcp 8443/tcp 8443/udp
VOLUME /config
STOPSIGNAL SIGTERM
ENTRYPOINT ["/init"]
