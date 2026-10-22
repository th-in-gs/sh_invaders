#!/usr/bin/env python3
"""Builds profiling variants of the game, for `check.py --bench`.

Each variant is a copy of sh_invaders.sh with one part taken out, so its cost
can be measured by difference. Run the original and the variants alternately,
as other work on the machine shows up in the times:

    tools/make-variants.py /tmp/variants
    docs/screen-updates/check.py --bench --frames 900 \\
        --game /tmp/variants/nodraw.sh

Variants:

    nodraw          no drawing at all (the dirty flags it would clear are
                    reset anyway, so the game stays the same)
    p2 .. p6        draw returns after a later and later stage: p2 after
                    the HUD and scenery, p3 after the formation
                    bookkeeping, p4 after the ground is drawn, p5 after the
                    ground is blanked, p6 after the shields. Each stage's
                    cost is the difference from the one before.
    stub_NAME       game function NAME replaced with a stub
"""
import argparse
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.normpath(os.path.join(HERE, '..', 'sh_invaders.sh'))

CLEANUP = (
    '  inv_events="" shield_changed="" shields_dirty=0 ground_dirty=0\n'
    '  inv_touched=0 inv_rebuild=0 redraw_all=0 shields_whole=0 bell=0\n'
    '  prev_items="" prev_pieces="" pieces="" items="" cov="" lay_cov=""\n'
    '  return\n')

# (name, line to return after). Each must appear exactly once. Comments are
# given whole, with their newline, so the inserted code isn't commented out.
PHASES = [
    ('p2', "  # The title screen's text is drawn like the things that move, "
           "so only\n"),
    ('p3', '  inv_events=""\n\n'),
    ('p4', '  [ -n "$sp" ] && put_grow $go_row $gx ${#sp} "$sp"\n'),
    ('p5', '  # Shields: all of them on a cleared screen or for a new wave; '
           'otherwise\n'),
    ('p6', '  # Invaders: all of them when need be; otherwise just those '
           'that moved\n'),
]

# (function, body). move_invaders returns 1 as it always does after a move.
STUBS = [
    ('move_invaders', '  return 1\n'),
    ('check_collisions', '  return 0\n'),
    ('check_shields', '  return 0\n'),
    ('move_bombs', '  return 0\n'),
    ('drop_bomb', '  return 0\n'),
    ('check_bombs', '  return 0\n'),
    ('check_saucer', '  return 0\n'),
    ('update_saucer', '  return 0\n'),
    ('check_bonus', '  return 0\n'),
    ('move_bullets', '  return 0\n'),
    ('parse_input', None),
]


def replace_once(src, mark, add):
    if src.count(mark) != 1:
        raise SystemExit('make-variants.py: expected one %r, found %d'
                         % (mark, src.count(mark)))
    return src.replace(mark, mark + add, 1)


def build(name, src):
    """Returns the source of variant NAME."""
    if name == 'nodraw':
        return replace_once(src, 'draw() {\n', CLEANUP)
    for phase, mark in PHASES:
        if name == phase:
            return replace_once(src, mark, CLEANUP)
    for function, body in STUBS:
        if name != 'stub_' + function:
            continue
        if body is None:   # parse_input's key loop
            body = '  while false; do\n'
            mark = '  while [ ${#keys} -gt 0 ]; do\n'
            if src.count(mark) != 1:
                raise SystemExit('make-variants.py: cannot find %s' % function)
            return src.replace(mark, body, 1)
        return replace_once(src, function + '() {\n', body)
    raise SystemExit('make-variants.py: unknown variant %s' % name)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('outdir', help='directory to write the variants to')
    parser.add_argument('--source', default=SOURCE,
                        help='the game to copy (default sh_invaders.sh)')
    parser.add_argument('variants', nargs='*',
                        help='variants to build (default all)')
    args = parser.parse_args()

    src = open(args.source).read()
    names = args.variants or (
        ['nodraw'] + [p for p, _ in PHASES]
        + ['stub_' + f for f, _ in STUBS])
    os.makedirs(args.outdir, exist_ok=True)
    for name in names:
        path = os.path.join(args.outdir, name + '.sh')
        open(path, 'w').write(build(name, src))
        print(path)


if __name__ == '__main__':
    main()
