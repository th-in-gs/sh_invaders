# The public server

Everything installed on `invaders.now`, apart from the game itself
(`/usr/local/games/sh_invaders.sh`) and the session report
(`tools/session-report.py`).

- **SSH:** `ssh play@invaders.now` (and `ascii@`, `9600@`, `game@`) plays the
  game. No password.
- **Web:** `https://invaders.now/` serves the game to `curl` and a small page
  to browsers, from the same URL.

## SSH

The four game accounts have no password and `invaders-login` as their
shell. `sshd-invaders.conf` lets them log in with an empty password,
forces every session into the wrapper whatever the client asks for, and
turns off forwarding, tunnels and `~/.ssh/rc`.

The wrapper runs the game under ksh, logs each session to the journal,
and turns new players away while the CPU is 90% busy or more. The game
accounts' sessions run at a lower CPU weight than everything else, so the
server stays reachable for maintenance however many people play. See
[docs/server-sessions.md](../docs/server-sessions.md).

| File | Installed as |
|---|---|
| `invaders-login` | `/usr/local/bin/invaders-login` |
| `sshd-invaders.conf` | `/etc/ssh/sshd_config.d/50-invaders.conf` |
| `cpu-weight.conf` | `/etc/systemd/system/user-<uid>.slice.d/50-invaders.conf`, for each game account |

## Web

BusyBox httpd runs once per connection, started by a systemd socket on port
80 and on `127.0.0.1:8080`. stunnel terminates TLS on 443 and passes the
plain request to `127.0.0.1:8080`, so both ports share one handler.

The docroot has no `index.html`, so BusyBox runs `cgi-bin/index.cgi` for `/`.
It sends the page when the request's `Accept` header contains `text/html`,
and the game otherwise. Browsers send `text/html`; `curl` sends `*/*`. Both
files are read in place, so there is one copy of the game on the server.
Every response carries `Vary: Accept`.

Any other path is a static file or a 404. certbot's HTTP-01 challenges are
served this way.

| File | Installed as |
|---|---|
| `index.cgi` | `/srv/www/cgi-bin/index.cgi` |
| `index.html` | `/usr/local/share/sh-invaders/index.html` |
| `httpd.conf` | `/etc/busybox-httpd.conf` |
| `invaders-web.socket` | `/etc/systemd/system/` |
| `invaders-web@.service` | `/etc/systemd/system/` |
| `stunnel.conf` | `/etc/stunnel/invaders.conf` |
| `invaders-tls.service` | `/etc/systemd/system/` |

The game itself is `/usr/local/games/sh_invaders.sh`.

## Sandbox

Each httpd process gets a fresh UID (`DynamicUser`), no capabilities, a
read-only filesystem, and no network access of its own. It can read
world-readable files and write to the socket systemd hands it. stunnel
reads the private key as root and then drops to `stunnel4`.

## Installing

Copy the files into a private directory on the server, then run the
scripts from there. From the repository root:

```sh
dir=$(ssh admin@your-server mktemp -d)
scp server/* admin@your-server:"$dir"/
ssh admin@your-server "sudo sh $dir/install-ssh.sh"
ssh admin@your-server "sudo sh $dir/install-web.sh"
ssh admin@your-server "sudo sh $dir/install-tls.sh you@example.com"
ssh admin@your-server "rm -rf $dir"
```

`install-ssh.sh` needs the game accounts to exist. It checks the sshd
settings with `sshd -t` before reloading, and puts the previous ones back
if they fail.

`install-tls.sh` takes the address Let's Encrypt sends expiry notices to.
Run it once. After that, `install-web.sh` alone updates the page, the CGI
and the httpd units. Each new connection reads the new files, so nothing
needs restarting.

All three scripts refuse to run if their directory, or a file in it, is group-
or world-writable. The server has public SSH logins. Installing as root
from a shared directory such as `/tmp` would let another account swap a
file between the copy and the install.

`install-web.sh` and `install-tls.sh` finish by fetching `/` locally and
comparing it with the installed files.

## Checking it

```sh
curl -fsS https://invaders.now/ | cmp - sh_invaders.sh
curl -fsS -H 'Accept: text/html' https://invaders.now/ | cmp - server/index.html
curl -sSI https://invaders.now/
```
