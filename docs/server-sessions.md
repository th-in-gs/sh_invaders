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

| Field | Meaning |
|---|---|
| `sid` | Wrapper process ID. Paired with the journal's boot ID, unique across reboots |
| `start`, `end` | Seconds since the epoch, UTC |
| `account` | `game`, `play`, `ascii` or `9600` |
| `cols`, `rows` | Terminal size from `stty size`, or `0 0` without a terminal |
| `status` | Game's exit status; 129, 130 or 143 after HUP, INT or TERM |

Not recorded: source address, username, keystrokes, scores, waves.

An IP address is personal data under GDPR. The server already keeps
addresses in the sshd security log. These events do not add another copy,
and do not reuse that log for analytics.

## The wrapper

`/usr/local/bin/invaders-login` is the login shell for all three
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
# drops an invalid one, and the game then waits at its warning.
PATH=/usr/bin:/bin
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
export PATH LANG LC_ALL

# Session log for capacity planning, kept in the journal under the
# sh-invaders tag. One session is one SSH connection. No address, no
# keystrokes. See journalctl -t sh-invaders.
session=$$
log_event() {
  /usr/bin/logger -t sh-invaders -- "$*" 2>/dev/null || :
}

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

As root on the server:

From the repository root:

```sh
install -m 755 -o root -g root tools/session-report.py \
    /usr/local/bin/invaders-report
install -m 755 -o root -g root tools/invaders-login \
    /usr/local/bin/invaders-login
```

The wrapper is listed in `/etc/shells` already.

To make sshd notice a client that stops answering, add to the match block
in `/etc/ssh/sshd_config.d/50-invaders.conf`:

```
    ClientAliveInterval 30
    ClientAliveCountMax 3
```

Then `sshd -t` and `systemctl reload ssh`.

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
