#!/bin/sh
# Install the SSH side of the public game server: the login wrapper, the
# sshd settings for the game accounts, and their CPU weight. The accounts
# themselves (game, play, ascii, 9600, each with invaders-login as its
# shell and no password) and the game at /usr/local/games/sh_invaders.sh
# must exist already. From the repository root:
#
#   dir=$(ssh admin@your-server mktemp -d)
#   scp server/* admin@your-server:"$dir"/
#   ssh admin@your-server "sudo sh $dir/install-ssh.sh"
set -eu

accounts="game play ascii 9600"

# Files are installed from this script's own directory, as root. Refuse
# a directory anyone else can write to (such as /tmp itself): another
# user could swap a file between the copy and the install.
src=$(cd "$(dirname "$0")" && pwd -P)
if [ -n "$(find "$src" "$src"/* -prune \( -perm -020 -o -perm -002 \) -print)" ]; then
  echo "install-ssh.sh: $src or a file in it is group- or world-writable" >&2
  echo "Copy the files into a private directory (mktemp -d) first." >&2
  exit 1
fi

install -m 755 -o root -g root "$src/invaders-login" \
    /usr/local/bin/invaders-login
grep -qx /usr/local/bin/invaders-login /etc/shells ||
    echo /usr/local/bin/invaders-login >> /etc/shells

# Check the new sshd settings before reloading, so a mistake can't lock
# anyone out. sshd -t reads the installed copy, so put the old one back
# if it fails.
conf=/etc/ssh/sshd_config.d/50-invaders.conf
[ -f "$conf" ] && cp -p "$conf" "$conf.previous"
install -m 644 -o root -g root "$src/sshd-invaders.conf" "$conf"
if ! sshd -t; then
  if [ -f "$conf.previous" ]; then
    mv "$conf.previous" "$conf"
  else
    rm -f "$conf"
  fi
  echo "install-ssh.sh: sshd -t failed; previous settings kept" >&2
  exit 1
fi
rm -f "$conf.previous"
systemctl reload ssh

# Each account's sessions run in user-<uid>.slice. The weight applies to
# new and running sessions alike.
for account in $accounts; do
  uid=$(id -u "$account")
  install -d -m 755 -o root -g root "/etc/systemd/system/user-$uid.slice.d"
  install -m 644 -o root -g root "$src/cpu-weight.conf" \
      "/etc/systemd/system/user-$uid.slice.d/50-invaders.conf"
done
systemctl daemon-reload

for account in $accounts; do
  uid=$(id -u "$account")
  printf '%s (uid %s): ' "$account" "$uid"
  systemctl show "user-$uid.slice" -p CPUWeight
done
echo "SSH OK: wrapper, sshd settings and CPU weights installed"
