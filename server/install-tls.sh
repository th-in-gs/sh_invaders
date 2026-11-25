#!/bin/sh
# Add a TLS front end to invaders.now. Run after install-web.sh. From the
# repository root:
#
#   dir=$(ssh admin@your-server mktemp -d)
#   scp server/* admin@your-server:"$dir"/
#   ssh admin@your-server "sudo sh $dir/install-tls.sh you@example.com"
#
# The address is given to Let's Encrypt for expiry notices.
#
# stunnel terminates TLS on 443 and passes the plain request to the same
# sandboxed BusyBox handler on 127.0.0.1:8080 that serves port 80, so
# there is still exactly one copy of the script and one thing that reads it.
set -eu

email=${1:?usage: install-tls.sh EMAIL}

# Files are installed from this script's own directory, as root. Refuse
# a directory anyone else can write to (such as /tmp itself): another
# user could swap a file between the copy and the install.
src=$(cd "$(dirname "$0")" && pwd -P)
if [ -n "$(find "$src" "$src"/* -prune \( -perm -020 -o -perm -002 \) -print)" ]; then
  echo "install-tls.sh: $src or a file in it is group- or world-writable" >&2
  echo "Copy the files into a private directory (mktemp -d) first." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends certbot stunnel4

install -m 644 -o root -g root "$src/httpd.conf" /etc/busybox-httpd.conf
install -m 644 -o root -g root "$src/stunnel.conf" /etc/stunnel/invaders.conf
install -m 644 -o root -g root "$src/invaders-web.socket" \
    /etc/systemd/system/invaders-web.socket
install -m 644 -o root -g root "$src/invaders-tls.service" \
    /etc/systemd/system/invaders-tls.service

# The distro unit is not used; ours has its own config and sandbox.
systemctl disable --now stunnel4.service 2>/dev/null || :

systemctl daemon-reload
systemctl restart invaders-web.socket

# HTTP-01 through the same handler: certbot writes the challenge under
# the docroot, BusyBox serves it, certbot removes it again. No downtime,
# so renewals need no hooks beyond restarting stunnel with the new cert.
certbot certonly --webroot -w /srv/www -d invaders.now \
    --cert-name invaders.now \
    --non-interactive --agree-tos --no-eff-email \
    -m "$email" \
    --deploy-hook 'systemctl restart invaders-tls.service'

# invaders-tls.service has an [Install] section, so this starts it at
# boot too. Without one, enable does nothing and a reboot leaves 443 down.
systemctl enable --now invaders-tls.service
systemctl enable --now certbot.timer

# Same file over TLS, locally, without trusting the public DNS path.
curl -fsS --resolve invaders.now:443:127.0.0.1 https://invaders.now/ \
    | cmp - /usr/local/games/sh_invaders.sh

ss -lnt | grep -E ':(80|443|8080)\b'
certbot certificates | sed -n '/Certificate Name/,/^$/p'
echo "TLS OK: https://invaders.now/ is the installed script"
