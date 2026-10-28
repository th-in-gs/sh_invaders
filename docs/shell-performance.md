# What each shell costs

“#!/bin/sh Invaders” runs at a fixed 60 frames a second, so a session’s
CPU cost is set by how fast the shell runs the game and by the processes
its pacing starts. These are the figures for the shells available on a
Debian 13 server, measured 2026-10-27.

The harness is `tools/cpu.py`. It runs the game at its normal pace and
reports the CPU used as a share of one core, including the `date` and
`sleep` processes the pacing starts. See `tools/README.md`.

## Results

Median of four runs of 20 seconds of play each, interleaved. Terminal
24 × 80, one second on the title screen first, the same scripted keys
each time.

| Shell | Version | CPU ms a second | Share of one core | Range |
|---|---|---:|---:|---|
| **ksh93u+m** (package `ksh`) | 1.0.10 | **68.5** | **6.9%** | 68–69 |
| dash (Debian’s `sh`) | 0.5.12 | 91 | 9.1% | 90–91 |
| zsh-static, `--emulate sh` | 5.9 | 211.5 | 21.2% | 211–213 |
| zsh, `--emulate sh` | 5.9 | 220.5 | 22.1% | 218–221 |
| posh | 0.14.1 | 274 | 27.4% | 273–288 |
| bash | 5.2.37 | 286 | 28.6% | 283–291 |
| mksh | 59c | 306.5 | 30.7% | 295–315 |

zsh must run with `--emulate sh`: the game is a POSIX `sh` script.

BusyBox’s `sh` was not measured. Its `read` waits for a newline even
with `min 0 time 0`, so the game’s animation and input stall.

## Why ksh93u+m wins

ksh93u+m has a builtin `sleep` (`ksh -c 'type sleep'` says so). The
other shells, and ksh itself when the builtin is shadowed, fork
`/usr/bin/sleep` once a frame in the game’s normal “fine” pacing mode.
`date` is external in every shell, and is called every fourth frame to
check the frame rate.

Run the same ksh with `sleep` forced to the external program and it
costs 116–117 ms a second, 28% more than dash. So the win comes from
avoiding a fork and exec every frame, not from faster execution of the
game’s shell code.

The shells did the same amount of work. With a counter written at exit,
20 seconds of play ran 1405 frames under dash and 1409 under ksh93u+m.

Flat out, without the pacing, the order is different: dash is the
cheapest per frame, and ksh more expensive. Single runs of
`check.py --bench --frames 300` gave:

| Shell | µs a frame |
|---|---:|
| dash | 417 |
| ksh93u+m | 736 |
| zsh | 1635 |
| bash | 1865 |
| mksh | 2033 |

The game’s paced cost is dominated by starting `sleep` each frame, so
removing that start matters more than the per-frame difference.

## Things that can mislead

- **Locale.** ksh93 clears `LANG` if it names a locale the system does
  not have. The game then thinks the locale is not UTF-8, prints its
  warning, and waits for Enter before starting. A measurement then
  shows almost no CPU, because the game is blocked. Generate
  `en_US.UTF-8` (or use another UTF-8 locale) before measuring ksh.
- **`cpu.py` divides by wall time.** A shell that exits at once, such
  as an unsupported one, can still print a large percentage from a
  tiny wall time. Check the `wall` line, not just the last line.
- **Pacing starts processes.** A shell with a builtin `sleep` is
  cheap here for a reason that has nothing to do with its parser or
  arithmetic. Compare like with like.

## posh

posh 0.14.1 used to stop before the game started. With `set -u` it
treats `"$@"` with no arguments as an unset parameter, though POSIX
says it expands to nothing, so the game failed at its last line,
`main "$@"`. Commit `0000086` calls `main ${1+"$@"}` instead, which is
empty-safe and still passes `-a`, `-r` and `-b` through. The screen
checker’s two markers were updated to match.

With that fix posh plays, at 274 ms a second. It is supported, but not
the shell to choose for a busy server.

## Reproducing

On Debian 13, as root or with sudo:

```
apt-get install -y locales python3 bash dash zsh zsh-static ksh93u+m \
    mksh posh busybox
localedef -i en_US -f UTF-8 en_US.UTF-8
```

Then, from the repository:

```
tools/cpu.py --seconds 20 --shell dash
tools/cpu.py --seconds 20 --shell ksh
tools/cpu.py --seconds 20 --shell bash
tools/cpu.py --seconds 20 --shell mksh
tools/cpu.py --seconds 20 --shell 'zsh --emulate sh'
tools/cpu.py --seconds 20 --shell 'zsh-static --emulate sh'
tools/cpu.py --seconds 20 --shell posh
```

Run the shells in rotation, not all the runs of one shell together, so
other work on the machine does not land on one shell. The figures above
come from four rotations.

For the ksh counterfactual, put this in a file, make it executable, and
pass it to `--shell`:

```sh
#!/bin/ksh
sleep() { command /usr/bin/sleep "$@"; }
script=$1
shift
. "$script" "$@"
```

Measured on Debian 13 (trixie), aarch64, one vCPU, kernel 6.12.113,
with the game at commit `0000086`.
