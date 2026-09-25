#!/bin/bash
# Makes the dev server a pool runs on: one DigitalOcean droplet with the
# coordinator, the ricochet server and PostgreSQL, and a cloud firewall in
# front of it. docs/DEPLOYING.md has what comes after.
#
#   SSH_KEY=<fingerprint or id> ADMIN_CIDR=203.0.113.7/32 deploy/digitalocean/provision.sh
#
# Settings, from the environment:
#   SSH_KEY      the key on the DigitalOcean account (`doctl compute ssh-key list`); required
#   ADMIN_CIDR   the only address SSH is open to; required (0.0.0.0/0 is refused)
#   NAME         the droplet, its tag and its firewall (default pool-dev)
#   REGION       (default sgp1)
#   SIZE         (default s-2vcpu-2gb; see "Sizing" in docs/DEPLOYING.md)
#   WEB=1        also open 80 and 443, for the public page
#
# It refuses to touch a droplet or firewall that already has the name, so it
# is safe to run twice: the second run only prints what is there.
set -euo pipefail

: "${SSH_KEY:?set SSH_KEY to the fingerprint or id of your key (doctl compute ssh-key list)}"
: "${ADMIN_CIDR:?set ADMIN_CIDR to the address SSH is open to, e.g. 203.0.113.7/32}"
NAME="${NAME:-pool-dev}"
REGION="${REGION:-sgp1}"
SIZE="${SIZE:-s-2vcpu-2gb}"
WEB="${WEB:-0}"

case "$ADMIN_CIDR" in
    0.0.0.0/0|::/0) echo "refusing to open SSH to everyone; name your own address" >&2; exit 64 ;;
esac

command -v doctl >/dev/null || { echo "doctl is not installed (brew install doctl; doctl auth init)" >&2; exit 69; }
doctl account get >/dev/null || { echo "doctl is not signed in (doctl auth init)" >&2; exit 69; }

ANY4=address:0.0.0.0/0
ANY6=address:::/0

# The firewall follows the tag, so a rebuilt droplet with the tag is covered
# from its first boot.
if doctl compute firewall list --format Name --no-header | grep -qx "$NAME"; then
    echo "firewall $NAME exists; leaving it as it is"
else
    INBOUND="protocol:tcp,ports:22,address:${ADMIN_CIDR}"
    # ricochet speaks UDX, which is UDP: wallets reach the server here.
    INBOUND+=" protocol:udp,ports:55223,${ANY4},${ANY6}"
    if [ "$WEB" = 1 ]; then
        INBOUND+=" protocol:tcp,ports:80,${ANY4},${ANY6} protocol:tcp,ports:443,${ANY4},${ANY6}"
    fi
    OUTBOUND="protocol:tcp,ports:all,${ANY4},${ANY6} protocol:udp,ports:all,${ANY4},${ANY6} protocol:icmp,${ANY4},${ANY6}"
    doctl compute firewall create --name "$NAME" --tag-names "$NAME" \
        --inbound-rules "$INBOUND" --outbound-rules "$OUTBOUND" >/dev/null
    echo "firewall $NAME created: SSH from $ADMIN_CIDR, UDP 55223$([ "$WEB" = 1 ] && echo ', TCP 80 and 443')"
fi

if doctl compute droplet list --format Name --no-header | grep -qx "$NAME"; then
    echo "droplet $NAME exists; leaving it as it is"
else
    USER_DATA="$(mktemp)"
    trap 'rm -f "$USER_DATA"' EXIT
    # First boot: an `ops` user with the account's key, no root or password
    # logins, 2 GB of swap, security updates, and what both packages need.
    cat >"$USER_DATA" <<'CLOUD'
#cloud-config
package_update: true
package_upgrade: true
packages:
  - supervisor
  - postgresql
  - unattended-upgrades
  - tmux
  - jq
  - curl
users:
  # Kept, or the account's key never reaches root for the copy below.
  - default
  - name: ops
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
write_files:
  # Named to sort before cloud-init's own drop-in, since sshd takes the first.
  - path: /etc/ssh/sshd_config.d/10-pool.conf
    content: |
      PermitRootLogin no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
  - path: /etc/sysctl.d/60-swap.conf
    content: |
      vm.swappiness=10
runcmd:
  - install -d -m 700 -o ops -g ops /home/ops/.ssh
  - install -m 600 -o ops -g ops /root/.ssh/authorized_keys /home/ops/.ssh/authorized_keys
  - fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  - echo '/swapfile none swap sw 0 0' >> /etc/fstab
  - sysctl --system
  - timedatectl set-timezone UTC
  - systemctl enable --now supervisor
  - systemctl restart ssh
CLOUD
    doctl compute droplet create "$NAME" \
        --region "$REGION" --size "$SIZE" --image ubuntu-22-04-x64 \
        --ssh-keys "$SSH_KEY" --tag-names "$NAME" --enable-monitoring \
        --user-data-file "$USER_DATA" --wait >/dev/null
    echo "droplet $NAME created ($SIZE in $REGION)"
fi

IP="$(doctl compute droplet list --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1 == n { print $2 }')"
echo
echo "public IPv4: $IP"
echo "wait for first boot:  ssh ops@$IP cloud-init status --wait"
echo "then follow docs/DEPLOYING.md from \"PostgreSQL\"; EXTERNAL_IP=$IP"
