#!/usr/bin/env python3
"""Times shell constructs the game might use to store a list.

The game keeps lists as strings (no arrays in POSIX sh). The cost of finding,
replacing and appending an entry depends on the construct, and on the shell.
Each case below does one of those to a 47-invader list many times, so the
results guide storage changes. Times are per operation, best of a few runs.

    tools/bench-constructs.py                 # dash, 20000 operations
    tools/bench-constructs.py --shell bash
"""
import argparse
import subprocess
import time

LIST = '''
list=""
i=0
while [ $i -lt 47 ]; do
  list="$list 4:$i:$(($i % 3))"
  i=$((i + 1))
done
old="4:23:1" new="4:24:2"
'''

CASES = [
    ('split', 'set -- $list', 'split into positional parameters'),
    ('lookup', 'case "$list " in *" 4:23:"*|*" 4:22:"*) : ;; *) : ;; esac',
     'pattern lookup in the list'),
    ('replace', 'pre=${list%%" $old"*}; x="$pre $new${list#"$pre $old"}"',
     'replace one entry by pattern'),
    ('append', 'list="$list 4:0:0"', 'add one entry at the end'),
]


def run(shell, body, count):
    script = LIST + '''
n=0
while [ $n -lt %d ]; do
  %s
  n=$((n + 1))
done
''' % (count, body)
    started = time.monotonic()
    subprocess.run(shell + ['-c', script], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return time.monotonic() - started


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--shell', default='dash',
                        help="shell to use (default dash), e.g. "
                             "'zsh --emulate sh'")
    parser.add_argument('--count', type=int, default=20000,
                        help='operations a run (default 20000)')
    parser.add_argument('--runs', type=int, default=3,
                        help='runs to take the best of (default 3)')
    args = parser.parse_args()
    shell = args.shell.split()

    print('%s, %d operations, best of %d' % (args.shell, args.count,
                                             args.runs))
    for name, body, what in CASES:
        best = min(run(shell, body, args.count) for _ in range(args.runs))
        each = best / args.count
        print('%-8s %8.2f us   %s' % (name, 1e6 * each, what))


if __name__ == '__main__':
    main()
