# Deploying a dev pool on testnet

This runbook sets up one DigitalOcean droplet that runs a pool on BSV testnet. The droplet has the coordinator, the ricochet server and PostgreSQL. It broadcasts through ARC and reads the chain through WhatsOnChain.

| On the droplet | Package | Listens on |
|---|---|---|
| pool-coordinator | `pool-coordinator_X.Y.Z_amd64.deb` (GitHub release) | nothing public; the API on 127.0.0.1:8787 |
| ricochet server | `ricochet-server_X.Y.Z_amd64.deb` (GitHub release of go-ricochet) | UDP 55223 (UDX), ops on 127.0.0.1:9090 |
| PostgreSQL | Ubuntu's (14 on 22.04, 16 on 24.04) | 127.0.0.1:5432 |
| cloudflared (for the public page) | Cloudflare's | nothing: it connects out to Cloudflare |
| Caddy (the alternative) | built with xcaddy | TCP 80 and 443 |

Both packages run under supervisor, each as its own system user. The coordinator reaches ricochet over loopback. Wallets reach ricochet on the droplet's public address, by a DNS-only name such as `relay.testnet.shieldpool.net`.

## Sizing and cost

Testnet runs the `test` plan: production witnesses are over ARC's parse limit (see DESIGN.md, "Testnet"). A test round held the prover for 3.7 to 5.1 s on an M3 Pro. Each round waits for a block for each of its three fundings, so a round takes about half an hour, and the droplet is idle for nearly all of it. For this load:

- **Start with `s-2vcpu-2gb`** (2 vCPU, 2 GB, 60 GB disk, 3 TB transfer): $18 a month. The price includes the public IPv4 address, the disk and the transfer. On AWS and GCP each of those is billed separately, and the same machine comes to $21 to $34 a month there.
- **Memory and proving time on this size are unmeasured.** Measure them in the first days (see "Operations"). If 2 GB is not enough, resize to `s-2vcpu-4gb` ($24) with **CPU and RAM only**. That resize keeps the 60 GB disk, so it can be undone. A resize that grows the disk cannot be undone.
- **Don't pay for DigitalOcean backups or managed PostgreSQL.** The only files you cannot rebuild are the wallet, its passphrase and the identity. They are backed up by hand in step 7.

The production plan needs a GPU or a large CPU machine and a node to publish through. It is not in scope for this runbook.

**No reserved IP.** A reserved IP receives traffic through the droplet's anchor address, but the droplet sends traffic from its own public address. ricochet listens on `0.0.0.0` over UDP, so its replies would come from an address the wallet never dialled. The runbook uses the droplet's own public IPv4 address instead. That address stays the same for as long as the droplet exists, including across resizes and power cycles. It changes only if you destroy the droplet and create a new one.

## What you need

- `doctl`, signed in: `brew install doctl`, then `doctl auth init` with an API token from the DigitalOcean control panel (API, Generate New Token, read and write).
- An SSH key on the account: `doctl compute ssh-key list`. To add one: `doctl compute ssh-key import mac --public-key-file ~/.ssh/id_ed25519.pub`.
- Testnet coins: at least 1,003,061 sat for genesis, since the issuance is funded from a 1,000,000 sat output and its change comes back. Send about 0.02 tBSV: what genesis does not spend pays for rounds, at about 1,500 to 1,600 sat each at test parameters (DESIGN.md).
- Optionally, a DNS name for the public page.

## 1. Provision the droplet

```sh
doctl compute ssh-key list                      # note the fingerprint
curl -s https://ifconfig.me                     # your address, for SSH
SSH_KEY=<fingerprint> ADMIN_CIDR=<your address>/32 deploy/digitalocean/provision.sh
```

Add `WEB=1` to open ports 80 and 443 for the public page. `NAME`, `REGION` and `SIZE` override `pool-dev`, `sgp1` and `s-2vcpu-2gb`. The script creates:

- **A cloud firewall named `pool-dev`, attached by tag.** Inbound it allows SSH from `ADMIN_CIDR` only, UDP 55223 from anywhere, and 80/443 if `WEB=1`. Outbound is open. Port 8787 (the coordinator's API) and 9090 (ricochet's ops) stay closed, and they bind to loopback anyway.
- **An Ubuntu 22.04 droplet.** Its first boot (cloud-init):
  - adds an `ops` sudo user with your key;
  - turns off root and password logins;
  - adds 2 GB of swap and sets the clock to UTC;
  - turns on unattended security updates;
  - installs supervisor, PostgreSQL, tmux and jq.

The script prints the droplet's public address. Everything below uses it as `$IP`.

```sh
ssh ops@$IP cloud-init status --wait            # "status: done"
ssh ops@$IP 'free -h; sudo supervisorctl status; psql --version'
```

If your address changes, update the SSH rule:

```sh
doctl compute firewall list                     # the firewall's id
doctl compute firewall remove-rules <id> --inbound-rules "protocol:tcp,ports:22,address:<old>/32"
doctl compute firewall add-rules <id> --inbound-rules "protocol:tcp,ports:22,address:<new>/32"
```

**On a droplet you already have.** Skip this step, but check four things. The OS must be Ubuntu 22.04 or later. UDP 55223 must be free (`ss -lnup`). The host firewall (`ufw status`) and any cloud firewall on the droplet must allow UDP 55223. And add swap if the droplet has none (the cloud-init lines in `provision.sh` show how). If another service shares the droplet's PostgreSQL, keep ricochet's connection pool small (step 3).

## 2. Download the ricochet package

On the droplet, from go-ricochet's GitHub release:

```sh
RVER=1.0.0
B=https://github.com/stephanfeb/go-ricochet/releases/download/v$RVER
curl -fLO $B/ricochet-server_${RVER}_amd64.deb
curl -fL $B/SHA256SUMS -o ricochet.SHA256SUMS
sha256sum --ignore-missing -c ricochet.SHA256SUMS              # ...amd64.deb: OK
```

## 3. PostgreSQL and the ricochet server

On the droplet:

```sh
sudo apt install ./ricochet-server_${RVER}_amd64.deb
```

supervisor starts ricochet as soon as the package is installed. That first start fails, because the database password is not set yet, and supervisor shows it as `FATAL`. That is expected.

Next, create the database and its role. The password is generated on the droplet, so it never appears on a command line:

```sh
DB_PASSWORD="$(openssl rand -hex 24)"
echo "CREATE ROLE ricochet LOGIN PASSWORD :'pw';" | sudo -u postgres psql -v pw="$DB_PASSWORD"
sudo -u postgres createdb -O ricochet ricochet
PGPASSWORD="$DB_PASSWORD" psql -h localhost -U ricochet -d ricochet -f /opt/ricochet/schema.sql
```

Then set the password and the public address in `/etc/ricochet/env`:

```sh
sudo sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=$DB_PASSWORD/; s/^EXTERNAL_IP=.*/EXTERNAL_IP=$(curl -s https://ifconfig.me)/" /etc/ricochet/env
unset DB_PASSWORD
```

Without `EXTERNAL_IP`, the server tells wallets only its private addresses, and a wallet loses the server after its first exchange. `DB_SSLMODE` can stay at `require`: Ubuntu's PostgreSQL has SSL on, with its self-signed certificate.

`/etc/ricochet/config.yaml` is installed with every key commented out, so the server runs on the production preset. Append the few keys that differ here. The server refuses to start on a key it does not know.

```yaml
server:
  region: sgp1             # where the droplet is
storage:
  max_storage_gb: 20       # the preset's 50 is most of a 60 GB disk
database:
  pool_size: 10            # the preset's 50 is half of PostgreSQL's 100 connections
```

Then start it:

```sh
sudo supervisorctl start ricochet
/opt/ricochet/health_check.sh                                  # OK: Ricochet is healthy
grep 'Peer ID' /var/log/ricochet/stdout.log | tail -1          # the server's peer id
```

The server keeps its identity in `/var/lib/ricochet/sf_storage`, so the peer id survives restarts and upgrades. Write it down; the coordinator's configuration needs it.

## 4. Install the coordinator

On the droplet, from the GitHub release:

```sh
VER=0.1.0
BASE=https://github.com/twostack/pool-coordinator/releases/download/v$VER
curl -fLO $BASE/pool-coordinator_${VER}_amd64.deb -fLO $BASE/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS                       # ...amd64.deb: OK
sudo apt install ./pool-coordinator_${VER}_amd64.deb
pool-coordinator check                                         # kernels and sqlite found
```

The package creates the `pool-coordinator` user, the directories `/var/lib/pool-coordinator` and `/etc/pool-coordinator`, and a supervisor program. The program stays stopped until there is a pool.

## 5. Configure for testnet

Edit `/etc/pool-coordinator/config.yaml` with `sudoedit`. Leave `plan: test` and `network: test` as they are, and change three sections:

```yaml
chain:
  kind: testnet
  arc_url: https://testnet.arc.gorillapool.io/v1
  woc_url: https://api.whatsonchain.com/v1/bsv/test
  arc_scriptsig_limit: 1636802
  timeout_seconds: 30
  retries: 3

ricochet:
  server: /ip4/127.0.0.1/udp/55223/udx/p2p/<the peer id from step 3>
  identity_file: /var/lib/pool-coordinator/identity.seed
  send_retries: 3

server:
  poll_ms: 2000
  status_file: /var/lib/pool-coordinator/status.json
  mined_poll_ms: 2000
  # testnet blocks are irregular; the default hour fails a round on a slow block
  funding_timeout_seconds: 7200
```

Delete `rpc_url` and `rpc_user`; testnet does not use them.

`arc_url` is GorillaPool's testnet ARC. It takes broadcasts without a token, and its policy allows scripts up to 100 MB. TAAL's testnet ARC (`arc-test.taal.com`) answers a broadcast without a token with 401 (checked 2026-09-25), and the chain access sends none. TAAL's policy also caps scripts at 500,000 bytes (`maxscriptsizepolicy`).

Set the wallet passphrase in `/etc/pool-coordinator/env`:

```sh
openssl rand -base64 30                         # save it in your password manager first
sudoedit /etc/pool-coordinator/env              # POOL_WALLET_PASSPHRASE=<it>
```

Leave `POOL_RPC_PASSWORD` empty.

`mined_poll_ms` sets how often the coordinator polls WhatsOnChain while it waits for a transaction to be mined. WhatsOnChain's rate limits at this volume are unmeasured. If the log shows 429 answers, raise it (to 10000, for example).

## 6. Create the pool

`create` waits for your funding. Then it mines six transactions, one after another: Y_0, the issuance and witness 0, each after its own funding transaction. Every one waits for a block, so on testnet this takes about an hour. Run it in tmux so that a dropped SSH session does not kill it:

```sh
tmux new -s create
sudo -u pool-coordinator /opt/pool-coordinator/run.sh create
```

It prints `fund <address> with at least <n> satoshis`. Send more than that, for example 0.02 tBSV. What genesis does not spend stays in the wallet and pays for rounds. Then leave it running. Detach with `Ctrl-b d` and reattach with `tmux attach -t create`.

It is done when it prints `descriptor appended as feed entry ... under peer id <coordinator peer id>` and the three genesis txids. It has also written the genesis into `config.yaml`. Look up the txids on a testnet explorer to confirm them.

## 7. Back up what cannot be rebuilt

Copy these off the droplet now, and keep them encrypted (in a password manager or an encrypted volume):

- `/var/lib/pool-coordinator/wallet.enc`, with the passphrase from step 5. It holds the pool's owner key. Losing it after a round is published freezes the pool.
- `/var/lib/pool-coordinator/identity.seed`. It is the coordinator's peer id, which wallets know the pool by.
- `/etc/pool-coordinator/config.yaml`. It holds the genesis.

```sh
ssh ops@$IP 'sudo tar -C / -czf - var/lib/pool-coordinator/wallet.enc var/lib/pool-coordinator/identity.seed etc/pool-coordinator/config.yaml' > pool-dev-secrets.tgz
```

You don't need to back up anything else:

- **The store** is recovered from the chain and the feed.
- **`metrics.sqlite`** is rebuilt from the store.
- **ricochet's data** holds only messages in transit.

`apt purge pool-coordinator` deletes the wallet. Use `apt remove`, which keeps it.

## 8. Start and smoke-test

```sh
sudo supervisorctl start pool-coordinator
# the package leaves it off until there is a pool; now there is, so it comes
# back after a reboot or a supervisor restart (unattended-upgrades restarts
# supervisor when it upgrades a library supervisor uses, as libexpat1 did on
# 2026-09-25, and a program left at autostart=false stays down)
sudo sed -i 's/^autostart=false$/autostart=true/' /etc/supervisor/conf.d/pool-coordinator.conf
sudo supervisorctl status                                     # both RUNNING
jq . /var/lib/pool-coordinator/status.json                    # peerId, balance, roundsLeft
```

From the Mac, send one round through the public address. The simulator's `--deposits 0` sends padding only and needs no chain access of its own. It needs the pool's configuration with the genesis, and the kernels (the `native` symlink in this checkout):

```sh
scp ops@$IP:/etc/pool-coordinator/config.yaml /tmp/pool-dev.yaml
sed -i '' "s#/ip4/127.0.0.1/#/ip4/$IP/#" /tmp/pool-dev.yaml
dart run tool/wallet_sim.dart -c /tmp/pool-dev.yaml --deposits 0 --rounds 1 --coordinator <coordinator peer id>
```

It passes when:

- every submission gets a reply;
- the round's announcement arrives on the feed. On testnet this is about half an hour later, after three block waits;
- the witness is mined.

A padding round costs the wallet a round like any other.

## 9. The public page (optional)

There are two ways to publish the pool's page. shieldpool.net uses the first.

### Through Cloudflare, with no web port on the droplet

The page and its API go through Cloudflare. The pages are static files on Cloudflare Pages, in the site's own repository, `twostack/shieldpool.net`. The API is reached by a Pages Function through a Cloudflare Tunnel, locked with Cloudflare Access. The droplet runs only `cloudflared`, which connects out, so ports 80 and 443 stay closed. The site repository's `docs/DNS.md` has every dashboard step.

1. **The tunnel.** In Zero Trust → Networks → Tunnels, create a tunnel (cloudflared type) and copy its install command. On the droplet:

   ```sh
   sudo cloudflared service install <the tunnel's token>
   systemctl is-active cloudflared        # active
   ```

   `deploy/cloudflared/config.example.yml` is the same ingress for a locally managed tunnel.
2. **Access first.**
   - Create a service token (for example `shieldpool-pages`).
   - Create a Self-hosted application on the origin hostname (for example `pool-origin.shieldpool.net`) with one policy: action **Service Auth**, include that token.
   - Put the Client ID and the Client Secret into the Pages project's Production secrets, `CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`. Use only the values, not the `CF-Access-Client-Id:` header lines Cloudflare shows them in.
3. **The tunnel's route.** Add a published application route: the origin hostname → HTTP `127.0.0.1:8787`, the coordinator's API.
4. **The site.** From the site repository: `npx wrangler pages deploy dist --project-name shieldpool --branch main`. `POOL_ORIGIN` in its `wrangler.toml` names the origin hostname.
5. **Check:**

   ```sh
   curl -s https://<site>/api/testnet/pool                    # the pool's summary, through the tunnel
   curl -s -o /dev/null -w '%{http_code}\n' https://pool-origin.<domain>/api/pool   # 403: Access refuses anyone without the token
   ```

   The API needs `api.enabled: true` (the package's default) and no public bind. It never needs a port of its own.

### Telling wallets how to join

The page can show a **Connect a wallet** section: the `cloak init` command and a whole `config.yaml` for a new wallet, each with a copy button, at `#connect` (`https://shieldpool.net/testnet/#connect`). It appears only when the config names what wallets use, under `api.wallet`:

```yaml
api:
  enabled: true
  wallet:
    server: /ip4/$IP/udp/55223/udx/p2p/<ricochet peer id>
    peers:
      - 198.154.93.206:18333
      - 51.79.25.225:18333
      - 3.123.101.88:18333
    arc_url: https://testnet.arc.gorillapool.io/v1
```

- **`server`** is the ricochet server as wallets reach it. It is not `ricochet.server`, which is loopback when ricochet runs on the same droplet. It must be an IP address: the wallets' UDX transport dials only `/ip4` or `/ip6`, not `/dns4`, so `relay.testnet.shieldpool.net` cannot stand in for it. If the droplet's address changes, change this line too. Its peer id must be `ricochet.server`'s, or the config is refused.
- **`peers`** are chain peers a wallet's header sync can use, at most 8. cloak 0.1.0's testnet default, `testnet-seed.bitcoinsv.io:18333`, did not connect on 2026-09-25, and a wallet that cannot sync headers stops before it reads the pool. These three did. A first testnet sync from them takes about 50 minutes.
- **`arc_url`** is an ARC endpoint a wallet can broadcast to without a key. cloak's testnet default is TAAL's, which answers 401 without one.

Restart the coordinator after changing it, then check the summary carries it: `curl -s https://<site>/api/testnet/pool | jq .wallet`. The page shows nothing if any value fails its checks, which are stricter than the config's, because what it shows gets pasted into a shell.

### Colocated, with Caddy on the droplet

This path needs `WEB=1` in step 1, and a DNS A record from your name to `$IP`. The package ships the built site at `/opt/pool-coordinator/web` and the Caddyfile at `/opt/pool-coordinator/share/Caddyfile`. The API is already on in the package's configuration.

First build Caddy with the rate-limit module on the Mac, for Linux, and copy it over:

```sh
GOTOOLCHAIN=auto GOOS=linux GOARCH=amd64 CGO_ENABLED=0 xcaddy build v2.11.4 --with github.com/mholt/caddy-ratelimit --output build/caddy-linux-amd64
scp build/caddy-linux-amd64 ops@$IP:caddy
```

On the droplet, install it for a `caddy` user that may bind 80 and 443:

```sh
sudo install -m 755 caddy /usr/local/bin/caddy
sudo setcap cap_net_bind_service=+ep /usr/local/bin/caddy
sudo useradd --system --user-group --shell /usr/sbin/nologin --home-dir /var/lib/caddy --create-home caddy
sudo tee /etc/supervisor/conf.d/caddy.conf >/dev/null <<'CONF'
[program:caddy]
command=/usr/local/bin/caddy run --config /opt/pool-coordinator/share/Caddyfile --adapter caddyfile
directory=/var/lib/caddy
user=caddy
environment=HOME="/var/lib/caddy",POOL_DOMAIN="pool.example.org",POOL_SITE="/opt/pool-coordinator/web",POOL_API="127.0.0.1:8787"
autostart=true
autorestart=true
stopsignal=TERM
stdout_logfile=/var/log/caddy.log
redirect_stderr=true
CONF
sudo sed -i 's/pool.example.org/<your name>/' /etc/supervisor/conf.d/caddy.conf
sudo supervisorctl reread && sudo supervisorctl update
```

Caddy obtains its certificate from Let's Encrypt on the first start (the TLS-ALPN challenge, on 443) and renews it itself; `/var/log/caddy.log` says `certificate obtained successfully`. Until the coordinator runs, `/api/` answers 502. Check `https://<your name>/` and `https://<your name>/api/pool`.

## Operations

| | |
|---|---|
| Status | `sudo supervisorctl status`; `jq . /var/lib/pool-coordinator/status.json` |
| Logs | `/var/log/pool-coordinator/stderr.log`, `/var/log/ricochet/stderr.log`, or `sudo supervisorctl tail -f <program> stderr`; the tunnel: `journalctl -u cloudflared` |
| Restart | `sudo supervisorctl restart pool-coordinator`. A stop waits for a publish in progress, but abandons a round being proved; the next start picks it up. |
| Upgrade | Install the new `.deb` with `apt install`. A running program is stopped and started again on the new version. `config.yaml` and `env` are kept. |
| Top up | Send coins to the wallet's address. The wallet picks them up on its next scan. `status.json` says when a top-up is needed, and the log warns below `warn_rounds_left`. |
| Ricochet | `/opt/ricochet/health_check.sh`; `curl -s 127.0.0.1:9090/ops/mailboxes/top?n=20` |

**Measure in the first days.** These numbers decide the size and are not known yet. Add them to DESIGN.md under a dated section:

- **Memory:** `ps -o rss,cmd -C pool-coordinator,ricochet_server,postgres` at rest and during a round, and whether swap is used (`free -h`). If swap is used steadily, resize.
- **Proving time on 2 vCPU:** `status.json` and the log give each round's build time. Submissions that arrive during proving wait until it ends, because the library proves in the server's isolate.
- **Testnet:** the block wait for each funding, whether WhatsOnChain answers 429, and whether ARC accepts the test plan's witness.

**Resizing.** Power off, resize CPU and RAM only (no `--resize-disk`), then power on. It takes a few minutes, and the public address stays the same.

```sh
ID=$(doctl compute droplet list --format ID,Name --no-header | awk '$2 == "pool-dev" { print $1 }')
doctl compute droplet-action power-off $ID --wait
doctl compute droplet-action resize $ID --size s-2vcpu-4gb --wait
doctl compute droplet-action power-on $ID --wait
```

**Tearing down.** Back up first (step 7). Then:

```sh
doctl compute droplet delete pool-dev
doctl compute firewall delete <id>
```

A droplet that is powered off is still billed, so delete it to stop the charges.

## Known gaps

- **ARC authentication.** The testnet chain access sends no API key, so it can use only an ARC that takes anonymous broadcasts, such as GorillaPool's. To use TAAL, add a token to `chain`: a code change in `testnet_chain.dart` and `config.dart`.
- **Testnet never run live.** Block waits, WhatsOnChain's rate limits and TAAL's real scriptSig limit are unmeasured (DESIGN.md, "Testnet"). The first run of this runbook is also that measurement.
