// Caddy entrypoint with the same plugins as hotio's image, plus deSEC.
// Equivalent to the main.go xcaddy generates; built by the Dockerfile without
// xcaddy.
package main

import (
	_ "time/tzdata"

	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddy-dns/cloudflare"
	_ "github.com/caddy-dns/desec"
	_ "github.com/caddyserver/caddy/v2/modules/standard"
	_ "github.com/mholt/caddy-ratelimit"
)

func main() {
	caddycmd.Main()
}
