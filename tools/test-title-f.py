#!/usr/bin/env python3
"""Checks that F on the idle title screen redraws the HUD.

The title screen is skipped once typed out (see draw and draw_title), so F
must clear that skip: it toggles the debug frame-rate display, which lives
in the HUD drawn on the title screen. Needs Python 3 and pyte.
"""
import argparse
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

import pyte

HERE = os.path.dirname(os.path.abspath(__file__))
GAME = os.path.normpath(os.path.join(HERE, '..', 'sh_invaders.sh'))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--shell', default='dash',
                        help='shell to run the game with (default dash)')
    parser.add_argument('--size', type=int, nargs=2, default=(24, 80),
                        metavar=('ROWS', 'COLS'),
                        help='terminal size (default 24 80)')
    args = parser.parse_args()
    rows, cols = args.size

    pid, fd = pty.fork()
    if pid == 0:
        os.environ.update(TERM='xterm-256color', LANG='en_US.UTF-8')
        shell = args.shell.split()
        # (-a keeps pyte away from the emoji, which it renders badly)
        os.execvp(shell[0], shell + [GAME, '-a'])
    fcntl.ioctl(fd, termios.TIOCSWINSZ,
                struct.pack('HHHH', rows, cols, 0, 0))
    screen = pyte.Screen(cols, rows)
    stream = pyte.Stream(screen)

    def pump(secs):
        end = time.time() + secs
        while time.time() < end:
            ready, _, _ = select.select([fd], [], [], 0.01)
            if ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return
                for _ in range(data.count(b'\x1b[6n')):
                    os.write(fd, f'\x1b[{rows};{cols}R'.encode())
                stream.feed(data.decode('utf-8', 'replace'))

    def text():
        return '\n'.join(screen.display)

    fail = 0

    def check(what, ok):
        nonlocal fail
        print(('ok   ' if ok else 'FAIL ') + what)
        if not ok:
            fail = 1

    pump(4.5)
    idle = text()
    check('title screen has typed out', 'P R E S S' in idle)

    os.write(fd, b'f')
    pump(3.0)
    on = text()
    # ("~" between the rate and its spread: the game is in ASCII, see -a)
    check('F shows the frame rate', '~' in on and on != idle)

    os.write(fd, b'f')
    pump(1.5)
    off = text()
    check('F off clears it again', '~' not in off)
    check('F off leaves the title as it was', off == idle)

    os.write(fd, b'r')
    pump(2.0)
    check('R starts a game', 'P R E S S' not in text())

    os.write(fd, b'q')
    pump(0.5)
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    return fail


if __name__ == '__main__':
    sys.exit(main())
