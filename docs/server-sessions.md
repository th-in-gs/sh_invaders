# Counting play sessions

The public game server logs one record when a session starts and one when
it ends. The records go to the journal under the tag `sh-invaders`.
`tools/session-report.py` turns them into counts, durations and peak
concurrency.

A session is one SSH connection. The accounts are shared, so this counts
sessions, not people. Duration includes time on the title screen.

## What is recorded

```
START sid=146281 start=1793152678 account=game cols=80 rows=24
END   sid=146281 end=1793152683 status=0
```

A login turned away because the server is busy (see below) writes one
record instead:

```
BUSY  sid=146290 time=1793152700 account=play cpu=94
```

| Field | Meaning |
|---|---|
| `sid` | Wrapper process ID. Paired with the journal's boot ID, unique across reboots |
| `start`, `end` | Seconds since the epoch, UTC |
| `account` | `game`, `play`, `ascii` or `9600` |
| `cols`, `rows` | Terminal size from `stty size`, or `0 0` without a terminal |
| `status` | Game's exit status; 129, 130 or 143 after HUP, INT or TERM |
| `time` | When a login was turned away, seconds since the epoch, UTC |
| `cpu` | CPU use measured at that login, percent |

Not recorded: source address, username, keystrokes, scores, waves.

An IP address is personal data under GDPR. The server already keeps
addresses in the sshd security log. These events do not add another copy,
and do not reuse that log for analytics.

## The wrapper

`/usr/local/bin/invaders-login` is the login shell for all four
accounts. The game runs in the background with stdin reopened on
`/dev/tty`: a non-interactive shell redirects a background command's
stdin to `/dev/null`, and the game refuses to run without a terminal.

Running it in the background gives a child PID. The signals can then end
the game as well as the wrapper, and `wait` is interrupted, so the `END`
record is written promptly.

A watchdog ends the session if sshd goes away without signalling the
wrapper. This happens: after a client dies, sshd can close the pty and
exit, leaving the game running with no terminal. The watchdog watches its
parent PID. When sshd is gone, it sends TERM to the wrapper, which kills
the game and logs `END`.

### When the server is busy

There is no fixed limit on sessions. Before starting the game, the
wrapper measures CPU use over one second from `/proc/stat`. At 90% or
more it prints "The server is busy right now - please try again in a
minute.", logs `BUSY`, and exits. Games already running keep the CPU, so
they stay smooth. A session costs about 7% of a core under ksh (see
[shell-performance.md](shell-performance.md)), so on one core this
happens at about 13 players.

Each game account's sessions also run at a lower CPU weight than the
admin's and the system's (`server/cpu-weight.conf`). That is a priority,
not a cap: games can use the whole CPU while nothing else wants it, and
the server stays reachable for maintenance however many people play.

The wrapper is `server/invaders-login`:

```sh
#!/bin/sh
# Login shell for the public game accounts: runs the game under ksh.
# The account name picks the options: ascii draws plain ASCII, 9600
# paces for a 9,600-baud line (which also draws ASCII).
account=$(/usr/bin/id -un)
case $account in
  ascii) set -- -a ;;
  9600) set -- -b 9600 ;;
  *) set -- ;;
esac
# sshd passes TERM and a few locale variables. Pin the locale: ksh93
# drops one that isn't installed, and the game then waits at its warning.
# C.UTF-8 is built into glibc, so it is always there; en_US.UTF-8 is only
# there if generated.
PATH=/usr/bin:/bin
LANG=C.UTF-8
LC_ALL=C.UTF-8
export PATH LANG LC_ALL

# Session log for capacity planning, kept in the journal under the
# sh-invaders tag. One session is one SSH connection. No address, no
# keystrokes. See journalctl -t sh-invaders.
session=$$
log_event() {
  /usr/bin/logger -t sh-invaders -- "$*" 2>/dev/null || :
}

# Turn new players away while the server is busy, so the games already
# running stay smooth. There is no fixed limit on sessions: CPU use is
# measured over one second from /proc/stat (busy is everything but idle
# and iowait), and a session starts unless it is at busy_limit or more.
busy_limit=90
cpu_sample() {
  read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
  total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  idle=$((idle + iowait))
}
cpu=0
if [ -r /proc/stat ]; then
  cpu_sample
  total0=$total idle0=$idle
  /usr/bin/sleep 1
  cpu_sample
  if [ $((total - total0)) -gt 0 ]; then
    cpu=$((100 * (total - total0 - (idle - idle0)) / (total - total0)))
  fi
fi
if [ $cpu -ge $busy_limit ]; then
  log_event "BUSY sid=$session time=$(/usr/bin/date +%s) account=$account cpu=$cpu"
  echo "The server is busy right now - please try again in a minute."
  exit 0
fi

if size=$(/usr/bin/stty size 2>/dev/null); then
  rows=${size%% *}
  cols=${size##* }
else
  rows=0
  cols=0
fi
log_event "START sid=$session start=$(/usr/bin/date +%s) account=$account cols=$cols rows=$rows"

child=
log_end() {
  status=$?
  [ -n "${watchdog-}" ] && kill "$watchdog" 2>/dev/null
  log_event "END sid=$session end=$(/usr/bin/date +%s) status=$status"
}
trap log_end EXIT
trap 'kill -TERM "$child" 2>/dev/null; exit 129' HUP
trap 'kill -TERM "$child" 2>/dev/null; exit 130' INT
trap 'kill -TERM "$child" 2>/dev/null; exit 143' TERM

# If sshd closes the pty and exits, this shell is reparented and would
# otherwise keep the game running forever. End the session instead.
parent=$PPID
(
  exec </dev/null >/dev/null 2>&1
  while kill -0 "$parent" 2>/dev/null && kill -0 "$session" 2>/dev/null; do
    /usr/bin/sleep 2
  done
  if kill -0 "$session" 2>/dev/null && ! kill -0 "$parent" 2>/dev/null; then
    kill -TERM "$session" 2>/dev/null
  fi
) &
watchdog=$!

if [ -t 0 ]; then
  /usr/bin/ksh /usr/local/games/sh_invaders.sh "$@" </dev/tty >&1 2>&2 &
  child=$!
  wait "$child"
else
  # No terminal: let the game print its own message and exit.
  /usr/bin/ksh /usr/local/games/sh_invaders.sh "$@"
fi
```

A SIGKILL or power loss still leaves `START` with no `END`. The report
counts these as unfinished.

## The report

`tools/session-report.py` reads the journal and prints a summary.

```
invaders-report                    # last 30 days
invaders-report --days 7
invaders-report --since 2026-10-01 --until 2026-10-08
invaders-report --min-duration 5   # ignore probes
invaders-report --per-day
invaders-report --json
invaders-report --csv              # one row a session
invaders-report --active           # sessions with no END
```

Output:

```
Window: 2026-09-28 01:58 UTC to 2026-10-28 01:58 UTC
Sessions: 5
Finished: 5
Unfinished (no END): 0
Total play time: 19s
Median session: 5s
Mean session: 4s
90th percentile: 5s
Longest: 5s
Peak concurrent: 3, at 2026-10-28 01:58 UTC
By account: 9600 1, ascii 1, game 3
```

When logins were turned away for a busy server, a line
`Turned away, server busy: N` follows `Unfinished`. `--json` always has
it, as `turned_away_busy`.

Peak concurrency is calculated by sweeping the start and end times of
finished sessions, not by sampling. An end at the same second as a start
does not count as overlap.

Sessions are attributed to their start time. `--until` filters the
summary, but the journal is read past it, so an `END` after the window
still closes its session.

`--input FILE` reads captured journal JSON instead of running
`journalctl`. `--json` and `--csv` are for graphing.

Reading the journal needs membership of `adm` or `systemd-journal`. The
`debian` account has `adm`. Game accounts do not.

## Installing

The wrapper, the sshd settings for the game accounts and their CPU
weights are installed by `server/install-ssh.sh`. See
[server/README.md](../server/README.md).

The report is installed by hand. From the repository root, with the file
copied to the server:

```sh
install -m 755 -o root -g root tools/session-report.py \
    /usr/local/bin/invaders-report
```

`ClientAliveInterval 30` and `ClientAliveCountMax 3` in
`server/sshd-invaders.conf` make sshd notice a client that stops
answering.

## Retention

Journald keeps the events. The whole journal was 50.7 MB when this was
set up. An event is about 100 bytes; 10,000 sessions add about 1 MB.
Journald's default size limit applies, so old entries can be discarded
under pressure. The report prints the window it actually covered.

## Checking it

The report was run against a fixture with known overlaps, and against
live sessions on the server:

- one session, quit with `q`: `START` and `END`, status 0, 4 seconds
- three sessions, one per account, staggered: peak concurrent 3
- report totals matched the journal entries

The watchdog logic was tested separately by simulating sshd's exit:
`END`, status 143, within two seconds.
