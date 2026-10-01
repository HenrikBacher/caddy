# syntax=docker/dockerfile:1
# ghcr.io/hotio/caddy with a newer Caddy binary swapped in. Everything else
# (s6 services, PUID/PGID/UMASK, /config layout, default Caddyfile, ports
# 8080/8443) comes unchanged from hotio's image, so this is a drop-in.

ARG BASE_IMAGE=ghcr.io/hotio/caddy:release

FROM --platform=$BUILDPLATFORM golang:alpine AS builder
ARG CADDY_REF
ARG TARGETOS
ARG TARGETARCH
RUN go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
# Same plugin set as hotio's image.
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    xcaddy build "${CADDY_REF:?CADDY_REF is required}" --output /caddy \
        --with github.com/mholt/caddy-ratelimit \
        --with github.com/caddy-dns/cloudflare

FROM ${BASE_IMAGE}
COPY --from=builder --chmod=755 /caddy ${APP_DIR}/caddy
