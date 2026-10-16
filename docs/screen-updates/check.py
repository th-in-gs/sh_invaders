#!/usr/bin/env python3
"""Checks that "#!/bin/sh Invaders" keeps the screen right, and measures
what it sends.

It plays the game in a pseudo-terminal for a while, with scripted keys, and
has the game log two things every frame (in a copy of the script, with a few
lines added): what it actually sent, and a full redraw of its state at that
frame (clear the screen, then draw the scenery, scores, ground, shields,
formation and every moving thing in place). Both streams are then replayed
in a terminal emulator (pyte), and the screens compared after every frame
the game sent. Sending only the changes is right if they always match.

It also reports the bytes sent in play, a second at a time (a second is
taken to be 60 frames).

Needs Python 3 and pyte (pip install pyte). Run from anywhere:

    docs/screen-updates/check.py                    # dash, 60 s of play
    docs/screen-updates/check.py --shell bash -- -b 9600
    docs/screen-updates/check.py --shell 'zsh --emulate sh' --sync

Arguments after -- go to the game. The exit status is 1 if any screen
didn't match.
"""

import argparse
import os
import pty
import re
import select
import statistics
import struct
import sys
import tempfile
import time

GAME = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    '..', '..', 'sh_invaders.sh')

# Logged on file descriptor 3, a record a frame: the kind of frame, the full
# redraw, then what was sent, separated by RS and ended by US. Kinds:
#   S  sent (or nothing to send): compared
#   P  sent while the scenery was still being drawn in: not compared, as the
#      screen is meant to differ then
#   K  skipped to keep to a line speed (-b): not compared
ORACLE = r'''
# --- added by docs/screen-updates/check.py ---
oracle_log() {
  allp=""
  IFS=$NL
  for p in $pieces; do
    unset IFS
    k=${p%% *}
    r=${k%%";"*}; c=${k#*";"}; c=${c%";"*}
    allp="$allp${ESC}[$r;${c}H${p#* }"
  done
  unset IFS
  o="${ESC}[0m${ESC}[H${ESC}[2J$scenery${ESC}[0m$hud$ground_frame"
  [ $mode = title ] || o="$o$shield_frame$inv_frame"
  o="$o$allp"
  k=$1
  [ -n "${scenery_todo-}" ] && [ "$k" = S ] && k=P
  printf '%s\036%s\036%s\036\037' "$k" "$o" "${out_now-}" >&3
  out_now=""
}
'''

SKIP = ("    if [ $credit -lt 0 ] && [ $redraw_all -eq 0 ]; then\n"
        "      return\n")


def instrument(src):
    """Returns the game's script with the logging added. Fails if the code
    it hooks into has changed shape."""
    m = re.search(r"\nsend_frame\(\) \{\n(.*?)\n\}\n", src, re.S)
    if not m or m.group(1).count("printf '%s' ") != 1:
        sys.exit("check.py: can't find send_frame's one printf to hook into")
    body = re.sub(r"printf '%s' (\"[^\n]*\")",
                  r'out_now=\1; printf %s "$out_now"', m.group(1))
    src = src[:m.start(1)] + body + "\n  oracle_log S" + src[m.end(1):]
    if src.count(SKIP) != 1:
        sys.exit("check.py: can't find draw's line-speed skip to hook into")
    src = src.replace(SKIP, SKIP.replace(
        "      return\n",
        "      out_now=''; printf 'K\\036\\036\\036\\037' >&3\n      return\n"))
    i = src.rindex('\nmain "$@"')
    return src[:i] + ORACLE + src[i:]


def play(script, log, args):
    """Runs the game in a pseudo-terminal, as a terminal would: answering
    its size query (and, with --sync, its synchronized-output query), and
    typing the keys. Returns the start of what it printed."""
    rows, cols = args.size
    pid, fd = pty.fork()
    if pid == 0:
        f3 = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
        os.dup2(f3, 3)
        os.set_inheritable(3, True)
        os.environ.update(TERM='xterm-256color', LANG='en_US.UTF-8')
        shell = args.shell.split()
        os.execvp(shell[0], shell + [script] + args.game_args)
    import fcntl
    import termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    printed = []

    def pump(secs):
        end = time.time() + secs
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.01)
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if len(printed) < 4:
                    printed.append(data)
                if args.sync and b'\x1b[?2026$p' in data:
                    os.write(fd, b'\x1b[?2026;2$y')
                for _ in range(data.count(b'\x1b[6n')):
                    os.write(fd, f'\x1b[{rows};{cols}R'.encode())
        return True

    def type_(keys):
        try:
            os.write(fd, keys.encode())
            return True
        except OSError:
            return False

    pump(args.title_wait)
    type_('r' + args.first_keys)
    start, i = time.time(), 0
    while time.time() - start < args.seconds:
        if not pump(0.15) or not type_(args.keys[i % len(args.keys)]):
            break
        i += 1
    type_('q')
    end = time.time() + 3
    while time.time() < end:
        pump(0.2)
        if os.waitpid(pid, os.WNOHANG)[0]:
            break
    return b''.join(printed).decode('utf-8', 'replace')


def frames(log):
    raw = open(log, 'rb').read().decode('utf-8', 'replace')
    recs = (r.split('\x1e') for r in raw.split('\x1f') if r)
    return [tuple(r[:3]) for r in recs if len(r) >= 3]


def in_play(redraw):
    # (the title and game-over screens' letter-spaced text)
    return not any(t in redraw for t in ('P R E S S', 'I N V A D', 'G A M E'))


def report_traffic(recs):
    play_ = [(k, o, a) for k, o, a in recs
             if in_play(o) and '\x1b[2J' not in a]
    sent = [len(a.encode()) for k, o, a in play_ if a]
    if not play_ or not sent:
        print('traffic: no play recorded')
        return
    total = sum(sent)
    # Bytes in each run of 60 frames (a second) of play, without a full
    # redraw (they're sent whole, so swamp the rest)
    sizes = [(len(a.encode()), in_play(o), '\x1b[2J' in a) for k, o, a in recs]
    windows = sorted(sum(b for b, _, _ in sizes[i:i + 60])
                     for i in range(0, len(sizes) - 60, 10)
                     if all(p and not c for _, p, c in sizes[i:i + 60]))
    print(f'traffic in play: {len(play_)} frames (~{len(play_) / 60:.0f} s), '
          f'{len(sent)} sent, {60 * total / len(play_):.0f} bytes a second')
    if windows:
        q = lambda f: windows[min(len(windows) - 1, int(f * len(windows)))]
        print(f'  a second at a time: median {q(.5)}, 95th percentile '
              f'{q(.95)}, most {windows[-1]} bytes')
    print(f'  frames sent: median {statistics.median(sent):.0f} bytes, '
          f'mean {statistics.mean(sent):.1f}')


def check_screens(recs, size):
    import pyte
    rows, cols = size
    sent, state = pyte.Screen(cols, rows), pyte.Screen(cols, rows)
    sent_in, state_in = pyte.Stream(sent), pyte.Stream(state)

    def cells(screen):
        return [[(c.data, c.fg, c.bg, c.reverse, c.underscore, c.bold)
                 for c in (screen.buffer[y][x] for x in range(cols))]
                for y in range(rows)]

    compared = bad = 0
    for n, (kind, redraw, out) in enumerate(recs):
        sent_in.feed(out)
        if kind != 'S':
            continue
        state_in.feed(redraw)
        compared += 1
        if cells(sent) != cells(state):
            bad += 1
            if bad <= 3:
                print(f'MISMATCH at frame {n}:')
                for y, (a, b) in enumerate(zip(sent.display, state.display)):
                    if a != b:
                        print(f'  row {y + 1}\n    shown: {a!r}\n'
                              f'    state: {b!r}')
    print(f'screen check: {compared} frames compared, {bad} mismatched')
    return bad == 0


def main():
    p = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--shell', default='dash',
                   help="shell to run the game with (default dash), e.g. "
                        "'zsh --emulate sh'")
    p.add_argument('--seconds', type=float, default=60,
                   help='seconds of play (default 60)')
    p.add_argument('--title-wait', type=float, default=3,
                   help='seconds on the title screen first (default 3)')
    p.add_argument('--sync', action='store_true',
                   help='say the terminal does synchronized output')
    p.add_argument('--keys', default='  h  l ll hh  rr  hhh  lll    ',
                   help='keys to type, one every 0.15 s, round and round '
                        '(default moves, fires and restarts)')
    p.add_argument('--first-keys', default='',
                   help="keys to type just after starting, e.g. 't' to "
                        'switch to ASCII or back')
    p.add_argument('--size', type=int, nargs=2, default=(32, 100),
                   metavar=('ROWS', 'COLS'), help='terminal size (32 100)')
    p.add_argument('--game', default=GAME, help='the script to check')
    p.add_argument('game_args', nargs='*', help='arguments for the game')
    args = p.parse_args()

    try:
        import pyte  # noqa: F401  (checked now, rather than after playing)
    except ImportError:
        sys.exit('check.py needs pyte: pip install pyte')

    with tempfile.TemporaryDirectory() as tmp:
        script = os.path.join(tmp, 'sh_invaders.sh')
        log = os.path.join(tmp, 'frames.log')
        with open(script, 'w') as f:
            f.write(instrument(open(args.game).read()))
        printed = play(script, log, args)
        recs = frames(log)
    if not recs:
        sys.exit('check.py: the game logged no frames. It printed:\n'
                 + printed[:500])
    report_traffic(recs)
    sys.exit(0 if check_screens(recs, args.size) else 1)


if __name__ == '__main__':
    main()
