# Tools

Harnesses used while working on the game. They are kept so that measurements
can be repeated, not because the game needs them. None is part of the game.

The main screen checker is `docs/screen-updates/check.py`, which checks the
game's drawing and measures what it sends. These tools complement it.

They need Python 3. The screen checks also need pyte (`pip install pyte`).
Nothing needs installing into the game's own directory.

| Tool | What it does |
|---|---|
| `cpu.py` | Runs the game at its normal pace and reports the CPU it uses |
| `make-variants.py` | Builds copies of the game with parts removed, for `check.py --bench` |
| `probe-read.py` | Reports whether each shell's `read` returns or blocks on a terminal |
| `bench-constructs.py` | Times shell constructs for storing a list |
| `test-shields.sh` | Checks shield capacity and the damage each hit does |
| `test-title-f.py` | Checks that F redraws the HUD on the idle title screen |

## CPU use

```
tools/cpu.py                          # dash, 10 s of play, 24x80
tools/cpu.py --seconds 30 --shell bash
```

This is the figure to watch for a server: the CPU a session costs per second
of real time, as a share of one core. It includes the processes the pacing
starts, which `check.py --bench` leaves out.

## Profiling

`check.py --bench --frames N` reports CPU time and (on macOS) instructions per
frame, running the game flat out. To see where a frame goes, build variants
with one part removed and measure them alongside the original:

```
tools/make-variants.py /tmp/variants
docs/screen-updates/check.py --bench --frames 900 \
    --game /tmp/variants/nodraw.sh
```

Variants are `nodraw`, `p2` to `p6` (the draw returning after a later and
later stage), and `stub_NAME` for each game function. Differences
between consecutive `p` variants give each phase's cost. Run variants and the
original alternately: other work on the machine shows up in the times.

The variants depend on the shape of the game's code, and refuse to build if a
marker has moved. `p1` from an earlier round is not included: it measured a
conditional return, so its figure was wrong.

## Shell `read`

```
tools/probe-read.py
tools/probe-read.py dash bash 'busybox sh'
```

Sends each probe under a pseudo-terminal and reports whether it returns or
blocks. BusyBox's `sh` is known to block even with `min 0 time 0`, which is
why the README suggests another shell.

## List storage

```
tools/bench-constructs.py --shell dash
```

Times splitting, looking up, replacing and appending an entry in a 47-item
string list, best of three runs. The figures are per operation.

## Shield damage

```
tools/test-shields.sh
```

Extracts `reset_shields`, `damage_shield` and `damage_cell` from the game
itself, so the test can't drift from them, and checks the shield's total
capacity and the damage of representative hits. Exits 1 on a mismatch.

## The title screen

```
tools/test-title-f.py
```

Runs the game in a pseudo-terminal, waits for the title to type out, and
checks that F shows the frame rate in the HUD and turns it off again. This is
the invalidation path for the skip in `draw`. The game runs with `-a`, as
pyte mishandles the emoji.
