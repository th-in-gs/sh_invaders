#!/usr/bin/env python3
"""Runs the game at its normal pace and reports the CPU it uses.

Unlike `check.py --bench`, which runs frames flat out, this measures what a
real session costs: drawing, the processes the pacing starts, and anything
else the game runs. The result is the CPU as a share of one core, which is
what matters when many people play at once on a server.
"""
import argparse
import importlib.util
import os
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.normpath(os.path.join(HERE, '..', 'sh_invaders.sh'))
CHECK = os.path.normpath(
    os.path.join(HERE, '..', 'docs', 'screen-updates', 'check.py'))


def load_check():
    spec = importlib.util.spec_from_file_location('check', CHECK)
    if spec is None:
        raise SystemExit('cpu.py: cannot load check.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--seconds', type=float, default=10,
                        help='seconds of play (default 10)')
    parser.add_argument('--title-wait', type=float, default=1,
                        help='seconds on the title screen first (default 1)')
    parser.add_argument('--shell', default='dash',
                        help="shell to run the game with (default dash), "
                             "e.g. 'zsh --emulate sh'")
    parser.add_argument('--size', type=int, nargs=2, default=(24, 80),
                        metavar=('ROWS', 'COLS'),
                        help='terminal size (default 24 80)')
    parser.add_argument('--game', default=GAME,
                        help='the script to measure')
    args = parser.parse_args()

    check = load_check()
    play_args = types.SimpleNamespace(
        title_wait=args.title_wait, frames=0,
        keys='  h  l ll hh  rr  hhh  lll    ', first_keys='',
        game=args.game, size=tuple(args.size), sync=False, bench=False,
        game_args=[], shell=args.shell, seconds=args.seconds)
    started = time.monotonic()
    with tempfile.TemporaryDirectory() as tmp:
        _, usage = check.play(args.game, os.path.join(tmp, 'play.log'),
                              play_args)
    wall = time.monotonic() - started
    if usage is None:
        raise SystemExit('cpu.py: the game did not exit')
    cpu = usage.ru_utime + usage.ru_stime
    print('wall %.1fs  user %.2fs  sys %.2fs  cpu %.2fs  '
          '%.1f%% of a core' % (wall, usage.ru_utime, usage.ru_stime, cpu,
                                100 * cpu / wall))
    if wall > 0:
        print('%.0f ms of CPU a second' % (1000 * cpu / wall))


if __name__ == '__main__':
    main()
