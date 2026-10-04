// Caddy entrypoint with hotio's plugins, bunny.net in place of Cloudflare.
// Equivalent to the main.go xcaddy generates; built by the Dockerfile without
// xcaddy.
package main

import (
	_ "time/tzdata"

	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddy-dns/bunny"
	_ "github.com/caddyserver/caddy/v2/modules/standard"
	_ "github.com/mholt/caddy-ratelimit"
)

func main() {
	caddycmd.Main()
}
