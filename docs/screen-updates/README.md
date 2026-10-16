# How the screen is drawn

How "#!/bin/sh Invaders" keeps the terminal up to date while sending as
little as possible. (The code is `draw` in `sh_invaders.sh`, and the
functions around it.)

The game keeps a record of what the terminal is showing, so it can work
out what has changed. Each frame it builds just those changes into one
string, and writes it in one go. It never reads anything back from the
terminal.

## What gets written

The string is a run of terminal control sequences mixed with the
characters to show. Each control sequence starts with `ESC` (byte `0x1B`)
and `[`:

| Sequence | Bytes | Effect |
|---|---|---|
| `ESC[?2026h` | 8 | Start a synchronized update: the terminal holds its display until the end marker (only sent if the terminal does them: see below) |
| `ESC[?2026l` | 8 | End the update: the terminal shows the changes all at once |
| `ESC[row;colH` | 6–8 | Move the cursor to row, column (counting from 1) |
| `ESC[nA`, `B`, `C`, `D` | 3–5 | Move the cursor up, down, right or left n places (n left out if 1) |
| `BS` (`0x08`) | 1 | Move the cursor left one place |
| `ESC[32m`, `ESC[31;4m`, `ESC[2m` … | 4–7 | Set colors and attributes: green, red, underline, dim, reverse video |
| `ESC[0m` | 4 | Reset the colors and attributes |
| `ESC[H`, `ESC[2J` | 3, 4 | Move the cursor to the top left, and clear the screen (only for a full redraw, or the "too small" message) |
| `BEL` (`0x07`) | 1 | Ring the bell |

Every change starts with a cursor move. The text after it overwrites only
the cells it lands on, so most of the screen is never sent.

For example, when the player's shot climbs a row (on a terminal without
synchronized updates):

```
ESC[14;31H      cursor to row 14, column 31    8 bytes
␠               a space: blank the old shot    1 byte
ESC[A BS        cursor up one, and back one    4 bytes
¡               the shot (2 bytes in UTF-8)    2 bytes
                                              ─────────
                                              15 bytes
```

Only 3 of those 15 bytes are the characters themselves (the space, and
the shot's 2). The rest are cursor moves: most of a frame is the overhead
around a few characters. Where the terminal does synchronized updates,
the markers add 16 bytes to every frame sent.

### Moving the cursor

The game keeps track of where the cursor is, from where the last text it
wrote ended, and moves it to the next change the shortest way: not at all
if it's already there, up, down, left or right if that's shorter, and to
the row and column otherwise. It uses only moves the VT100 had, so it
works on old terminals too.

Where the cursor is isn't known after a whole layer is sent (the moves are
in the layer's text), after a full redraw, or after text that reaches the
terminal's last column (where terminals differ over what the cursor does
next). The next move is then always to the row and column.

### Synchronized updates

At startup, along with asking the terminal's size, the game asks whether
it does synchronized updates (`ESC[?2026$p`). A terminal that does answers
before it gives the size; one that doesn't know the question ignores it.
So there's no waiting for an answer that won't come. The markers are sent
only to a terminal that says it does them.

## Two kinds of content

**Layers** are the parts of the screen that change only now and then: the
scores and wave, the ground line, the shields and the invader formation.
The game remembers what it last sent of each, and sends a layer again
only when it has changed.

The shields and the formation change a little at a time, so they're
updated cell by cell: a shield cell that's hit is redrawn on its own, and
an invader that moves is blanked where it was and drawn where it is.

**Pieces** are the things that move: the cannon, the row of spare
cannons, shots, explosions, the saucer, "GAME OVER", and the title
screen's text. Each frame, the game lists every piece afresh (its place,
its width and how to draw it), whether it moved or not, and compares the
list with the last frame's.

## How it's stored

POSIX sh has no arrays, sets or maps: only strings, and numbers held as
strings. So everything above is kept in strings, in a few shapes:

- **Ready-to-send strings.** Each layer is kept as the exact text that
  draws it, cursor moves and all. For the scores and the ground, a copy of
  what was last sent is kept too, and "has it changed?" is a string
  comparison. The formation's string is edited in place instead: an
  invader that moves is cut out of it by pattern, and added again at the
  end.
- **Sets of cells.** A set of screen cells (those the pieces cover, those
  the formation covers, those drawn this frame) is a string of
  `␠row;col␠` entries. The spaces each side make a lookup exact: a cell is
  in the set if the string matches the pattern `*" 14;31 "*`, with no
  chance of `4;31` matching part of `14;31`.
- **Lists of pieces.** One piece a line, as its place and width, then the
  text that draws it. Newlines separate them because the text can contain
  spaces. Whether a piece was in the last frame is the same kind of
  pattern match, of the whole line against the last frame's list.
- **"Arrays" of numbers.** Where every cell needs its own number, each has
  its own variable, named after its place and read and written with
  `eval`: a shield cell's remaining strength, or which of a ground
  column's 4 pixels are left.

Pattern matching (`case`) and cutting by pattern (`${var%...}`,
`${var#...}`) are built into the shell, so none of this starts another
program.

## Each frame

1. **Blanks.** A cell a piece covered last frame, and none covers now, is
   cleared. If an invader or a shield is there, that's redrawn instead of
   a space.
2. **Layers.** Each layer that changed is added, whole or cell by cell.
3. **Pieces.** A cell is *dirty* if a layer was drawn on it this frame, or
   if it belongs to a piece that's new, changed or gone since the last
   frame. (Only the shields and the formation can be under a piece: no
   piece is ever on the scores' or the ground's rows.) Only the pieces
   with a dirty cell are sent: so a piece is sent when it changes, when
   something has been drawn over it, or when a piece that overlapped it
   has gone. Pieces are sent in a fixed order, so one that overlaps
   another still covers it. If the whole formation or all the shields are
   redrawn, every piece is sent.
4. **Sending.** The frame is sent with the bell if it's due, and wrapped
   in the synchronized-update markers if the terminal does them. If
   there's nothing in it and no bell, nothing at all is sent.

Blanks are never where a layer is drawn, so the two can go in either
order. Pieces go last, so the things that move always end up on top.

## Keeping to a line speed

On a real terminal on a serial line, the game can be told the line's speed
(`-b 9600`, say). It draws in ASCII then, as its characters take 1 byte
each, not 2 or 3. And it keeps a credit of bytes: each frame adds what
the line carries in a frame's time (9,600 baud is 960 bytes a second, at
10 bits a byte), and each frame sent takes off its size. While the credit
is below zero, frames aren't sent. A frame's time isn't taken to be
exactly a sixtieth of a second: it's as last measured against the clock
(every couple of seconds; see `pace` in `sh_invaders.sh`), so the budget
keeps to real seconds even if the frame rate drifts.

Nothing is lost by not sending a frame: everything is compared with what
was last sent, so the next frame sent carries all the changes since. The
screen just updates less often when there's a lot to send.

A full redraw is always sent. To get the game itself on screen sooner,
the scenery (the playfield's sides, the headings and the controls line)
is then left out of it, and sent a part a frame afterwards: the headings,
the controls, then the sides 4 rows at a time. Nothing else is ever drawn
there, so it can come in any order. At 9,600 baud the title screen starts
typing out after a quarter of a second, rather than after nearly a second,
and its scenery is all there a second later. A new game, with the whole
formation and shields to send, still takes the line about a second.

Up to a tenth of a second's credit can be saved up, so short bursts go
straight out. As a frame's size isn't known until it's built, one can
overrun the credit, so the line can briefly hold a little more than a
second's worth.

## Full redraws

At startup, on a resize, for a new game, back at the title screen, and
when the T key switches the characters used, the screen is cleared and
everything is drawn afresh. The game forgets what it had sent, so
everything is sent (with a line speed set, the scenery over the next few
frames: see above).

## Special screens

- **The title screen.** Its text is handled as pieces, so as it types out
  each frame sends only the line that grew. Once it has finished, nothing
  is sent.
- **Window too small.** The game pauses, and the message is sent once.
  It's sent again after each resize, in case the terminal has redrawn the
  screen.

## Typical traffic

| | Without synchronized updates | With them |
|---|---|---|
| A frame with nothing changed | 0 | 0 |
| The player's shot climbing a row | about 15 bytes | about 31 bytes |
| The median frame sent in play | about 14–17 bytes | about 32 bytes |
| On average in play | about 0.7–1 KB a second | about 1.5 KB a second |
| A full redraw (in ASCII) | about 0.8 KB for the title, 1.6 KB for a new game | the same, plus 16 bytes |

With `-b 9600`, play averaged about 600–700 bytes a second, with about
2 frames in 5 sent: the screen updated every frame or two
usually, and within 5 frames 9 times in 10.

These were measured with `check.py` (below), in about a minute of play.

## Checking changes

`check.py` here checks that the screen is right, and measures what's sent.
It plays the game in a pseudo-terminal for a while, typing scripted keys,
with a few lines added to a copy of the script so that every frame it logs
two things: what it sent, and a full redraw of its state at that frame.
Both are replayed in a terminal emulator (pyte), and the screens compared
after every frame sent (except while the scenery is still to come, when
they're meant to differ). Sending only the changes is right if they always
match.

It needs Python 3 and pyte (`pip install pyte`):

```
docs/screen-updates/check.py                     # dash, 60 s of play
docs/screen-updates/check.py --shell bash -- -b 9600
docs/screen-updates/check.py --shell 'zsh --emulate sh' --sync
```

Arguments after `--` go to the game. `--sync` has the pretend terminal say
it does synchronized updates, and `--first-keys t` switches characters
just after starting (so with `-b`, to emoji). The exit status is 1 if any
screen didn't match. With every change to drawing so far, the screens have
matched every time, under dash, bash, ksh and zsh, in ASCII and emoji,
with and without synchronized updates and a line speed. (Breaking the
blanking of cells left behind, as a test of the test, gives mismatches
within a few seconds.)

It hooks into `send_frame`, and into where `draw` skips frames to keep to a
line speed. If they change shape, it says so rather than checking nothing.
