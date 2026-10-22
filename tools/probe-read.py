#!/usr/bin/env python3
"""Probes how each shell's `read` behaves on a terminal.

The game sets `min 0 time 0` and expects `read` to return at once when no
key has been pressed, so a frame can be drawn between key reads. It also
needs `read -t` to work the same way where a shell has it. This runs both
under a pseudo-terminal and reports whether each returns or blocks.

BusyBox's sh is known to block even with `min 0 time 0`; the rest are
checked here. Shells that aren't installed are skipped.
"""
import argparse
import os
import pty
import select
import time

DEFAULT_SHELLS = ['sh', 'dash', 'bash', 'ksh', 'zsh', 'busybox sh']
TAIL = '; echo "rc=$?"; echo READ-RETURNED'
PROBES = [
    ('stty time 0', 'stty -icanon -echo min 0 time 0; IFS= read -r x' + TAIL),
    ('stty time 1', 'stty -icanon -echo min 0 time 1; IFS= read -r x' + TAIL),
    ('read -t 1', 'IFS= read -r -t 1 x' + TAIL),
    ('read -t 0.1', 'IFS= read -r -t 0.1 x' + TAIL),
    ('read -t 0.00001', 'IFS= read -r -t 0.00001 x' + TAIL),
]


def probe(argv, script, wait):
    """Runs SCRIPT in a pty. Returns (returned, seconds, message)."""
    started = time.time()
    try:
        pid, fd = pty.fork()
    except OSError:
        return None, 0, ''
    if pid == 0:
        try:
            os.execvp(argv[0], argv + ['-c', script])
        except OSError:
            os._exit(127)
    out = b''
    end = started + wait
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], 0.01)
        if ready:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            out += data
            if b'READ-RETURNED' in out:
                break
    elapsed = time.time() - started
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    text = out.decode('utf-8', 'replace')
    said = ' '.join(ln.strip() for ln in text.splitlines()
                    if ln.strip() and 'READ-RETURNED' not in ln
                    and not ln.startswith('rc='))
    return 'READ-RETURNED' in text, elapsed, said


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('shells', nargs='*', default=DEFAULT_SHELLS,
                        help='shells to probe (default: %s)'
                             % ', '.join(DEFAULT_SHELLS))
    parser.add_argument('--wait', type=float, default=2.5,
                        help='seconds before calling a read blocked '
                             '(default 2.5)')
    args = parser.parse_args()

    width = max(len(label) for label, _ in PROBES)
    for shell in args.shells:
        argv = shell.split()
        print('== %s' % shell)
        if not any(os.path.exists(p) for p in
                   ([argv[0]] if '/' in argv[0]
                    else [os.path.join(d, argv[0])
                          for d in os.environ.get('PATH', '').split(':')])):
            print('   not installed')
            continue
        for label, script in PROBES:
            returned, elapsed, said = probe(argv, script, args.wait)
            if returned is None:
                print('   %-*s  cannot start' % (width, label))
                continue
            print('   %-*s  %-8s %5.2fs  %s'
                  % (width, label, 'returned' if returned else 'BLOCKED',
                     elapsed, said))


if __name__ == '__main__':
    main()
