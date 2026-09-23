# The public page's proxy

The pool's landing page is static files (`web/dist/`) and the coordinator's
read-only API, which binds to loopback only. [Caddy](https://caddyserver.com)
on the coordinator's host puts both behind one public name: it terminates
TLS (certificates are automatic), serves the files, forwards only GET and
HEAD under `/api/` to the coordinator, rate limits `/api/` per client
address, keeps the event stream unbuffered, and sends the content security
policy. `Caddyfile` here is the whole configuration.

## Build Caddy with the rate limit

The rate limit is the `caddy-ratelimit` module, which the standard Caddy
build (and Homebrew's) does not include; the standard build refuses the
`Caddyfile` with "rate_limit is not a registered directive". Build one that
has it with [xcaddy](https://github.com/caddyserver/xcaddy) (Go 1.22 or
newer):

```sh
go install github.com/caddyserver/xcaddy/cmd/xcaddy@latest
xcaddy build v2.11.4 --with github.com/mholt/caddy-ratelimit --output build/caddy
build/caddy list-modules | grep rate_limit   # http.handlers.rate_limit
```

## Configure and run

1. Enable the API in the coordinator's configuration (it stays on
   loopback; a public `api.bind` is refused at load):

   ```yaml
   api:
     enabled: true
     port: 8787
   ```

2. Build the site: `cd web && npm ci && npm run build` (Node 20, at build
   time only). Copy `web/dist/` to the host.

3. Run Caddy with the site's settings in its environment:

   ```sh
   POOL_DOMAIN=pool.example.org \
   POOL_SITE=/srv/pool-dashboard/dist \
   POOL_API=127.0.0.1:8787 \
   build/caddy run --config deploy/Caddyfile --adapter caddyfile
   ```

   `build/caddy validate` with the same environment checks the
   configuration without running it. The name must resolve to the host,
   and ports 80 and 443 must be open to it, for the certificate.

Keep the coordinator's port closed to the outside at the firewall as well:
the API binds to loopback, and the proxy is the only way in.

## Try it locally

`tool/dashboard_e2e.sh` runs the whole thing on localnet: the coordinator
with the API, Caddy on `https://localhost:8443` with a certificate from
its own CA (`POOL_DOMAIN=localhost`, `POOL_HTTPS_PORT=8443`,
`POOL_HTTP_PORT=8080`; nothing is added to the system's trust store), and a
browser test through it.
