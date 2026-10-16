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
| `ESC[?2026h` | 8 | Start a synchronized update: the terminal holds its display until the end marker (terminals without it ignore both markers) |
| `ESC[?2026l` | 8 | End the update: the terminal shows the changes all at once |
| `ESC[row;colH` | 6–8 | Move the cursor to row, column (counting from 1) |
| `ESC[32m`, `ESC[31;4m`, `ESC[7m` … | 4–7 | Set colors and attributes: green, red, underline, reverse video |
| `ESC[0m` | 4 | Reset the colors and attributes |
| `ESC[H`, `ESC[2J` | 3, 4 | Move the cursor to the top left, and clear the screen (only for a full redraw, or the "too small" message) |
| `BEL` (`0x07`) | 1 | Ring the bell |

Every change starts with its own cursor move. The text after it overwrites
only the cells it lands on, so most of the screen is never sent.

For example, when the player's shot climbs a row:

```
ESC[?2026h      start the update               8 bytes
ESC[14;31H      cursor to row 14, column 31    8 bytes
␠               a space: blank the old shot    1 byte
ESC[13;31H      cursor to row 13, column 31    8 bytes
¡               the shot (2 bytes in UTF-8)    2 bytes
ESC[?2026l      end the update                 8 bytes
                                              ─────────
                                              35 bytes
```

Only 3 of those 35 bytes are the characters themselves (the space, and
the shot's 2). The other 32 are the markers and cursor moves. That's why
a frame is tens of bytes even when a single character changes: most of it
is the overhead around a few characters.

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
   has gone. Pieces are sent in a
   fixed order, so one that overlaps another still covers it. If the whole
   formation or all the shields are redrawn, every piece is sent.
4. **Sending.** The frame is wrapped in the synchronized-update markers,
   with the bell if it's due. If there's nothing in it and no bell,
   nothing at all is sent, not even the markers.

Because blanks and layers come before pieces, the things that move always
end up on top.

## Full redraws

At startup, on a resize, for a new game, back at the title screen, and
when the T key switches the characters used, the screen is cleared and
everything is drawn afresh. The game forgets what it had sent, so
everything is sent.

## Special screens

- **The title screen.** Its text is handled as pieces, so as it types out
  each frame sends only the line that grew. Once it has finished, nothing
  is sent.
- **Window too small.** The game pauses, and the message is sent once.
  It's sent again after each resize, in case the terminal has redrawn the
  screen.

## Typical traffic

| | Bytes sent |
|---|---|
| A frame with nothing changed | 0 |
| The player's shot climbing a row | about 35 |
| The median frame sent in play | about 37 |
| On average in play | about 1.6 KB a second |
| A frame as the title types out | about 37 |
| A full redraw | 1 KB or more |

These were measured from the game's output, in about a minute of play.
The same runs checked the scheme: every frame was replayed in a terminal
emulator (pyte), alongside a stream that sent every piece every frame, and
the screens matched after every frame, under dash, bash, ksh and zsh.
