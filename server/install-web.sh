#!/bin/sh
# Install the invaders.now download server. From the repository root:
#
#   dir=$(ssh admin@your-server mktemp -d)
#   scp server/* admin@your-server:"$dir"/
#   ssh admin@your-server "sudo sh $dir/install-web.sh"
#
# / is cgi-bin/index.cgi: browsers (Accept: text/html) get a small page,
# everything else gets the installed game at
# /usr/local/games/sh_invaders.sh, read in place so only one copy
# exists. Any other path is a static file or a 404. BusyBox httpd, one
# process per connection, unprivileged and sandboxed by systemd.
set -eu

# Files are installed from this script's own directory, as root. Refuse
# a directory anyone else can write to (such as /tmp itself): another
# user could swap a file between the copy and the install.
src=$(cd "$(dirname "$0")" && pwd -P)
if [ -n "$(find "$src" "$src"/* -prune \( -perm -020 -o -perm -002 \) -print)" ]; then
  echo "install-web.sh: $src or a file in it is group- or world-writable" >&2
  echo "Copy the files into a private directory (mktemp -d) first." >&2
  exit 1
fi

install -d -m 755 -o root -g root /srv/www /srv/www/cgi-bin
install -m 755 -o root -g root "$src/index.cgi" /srv/www/cgi-bin/index.cgi
# An index.html in the docroot would be served instead of the CGI.
# index.txt was the old index, a symlink to the game. Now unused.
rm -f /srv/www/index.html /srv/www/index.txt

install -d -m 755 -o root -g root /usr/local/share/sh-invaders
install -m 644 -o root -g root "$src/index.html" \
    /usr/local/share/sh-invaders/index.html

install -m 644 -o root -g root "$src/httpd.conf" /etc/busybox-httpd.conf
install -m 644 -o root -g root "$src/invaders-web.socket" \
    /etc/systemd/system/invaders-web.socket
install -m 644 -o root -g root "$src/invaders-web@.service" \
    /etc/systemd/system/invaders-web@.service

systemctl daemon-reload
systemctl enable --now invaders-web.socket

# One process per connection reads the new config, so no restart is
# needed. Check both answers locally.
curl -fsS http://127.0.0.1:8080/ | cmp - /usr/local/games/sh_invaders.sh
curl -fsS -H 'Accept: text/html' http://127.0.0.1:8080/ \
    | cmp - /usr/local/share/sh-invaders/index.html

ls -lR /srv/www
systemctl status --no-pager --lines=0 invaders-web.socket
echo "Web OK: / is the game for curl, the page for browsers"
