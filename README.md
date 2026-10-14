# #!/bin/sh Invaders

Space Invaders in a terminal, written in plain POSIX shell, and as faithful
to the 1978 arcade game as a grid of characters allows.

```
                 SCORE              HI-SCORE               WAVE
                 0120                 1000                    1
           │                                                        │
           │         👾  👾  👾  👾  👾  👾  👾  👾  👾  👾  👾     │
           │                                                        │
           │         🦀  🦀  🦀  🦀 ›**‹ 🦀  🦀  🦀  🦀  🦀  🦀     │
           │                         ¡                              │
           │         🐙  🐙  🐙  🐙  🐙  🐙  🐙  🐙  🐙  🐙  🐙     │
           │                                    ┼                   │
           │        ▟████▙     ▟████▙      ▟████▙     ▟████▙        │
           │        ██  ██     ██  ██      ██  ██     ██  ██        │
           │                         ╱▲╲                            │
            ───────╌╌───────────────────────────────────────────────
```

## Playing

```
sh space_invaders.sh
```

It runs in `sh`, `dash` and `bash`, including the bash 3.2 that comes with
macOS. In zsh, use `zsh --emulate sh space_invaders.sh`.

| Key | Action |
|---|---|
| `←` `→`, `H` `L` or `A` `D` | Move |
| Space or `↑` | Fire |
| `R` | Start (and play again after game over) |
| `Q` | Quit |

The high score is kept in `~/.space_invaders_hiscore`.

## Terminal

- **Size:** at least 58 × 24 to play.

  **For arcade-accurate play, use at least 58 × 32.** The playfield is
  always 56 columns wide, and as tall as the terminal up to 32 rows. Only at
  32 rows does each row match 8 of the arcade's pixels, the distance the
  invaders drop each time they reach an edge. On shorter terminals each
  drop covers more ground, so the invaders reach the shields and the
  cannon sooner, and the game is harder. (macOS Terminal's default window
  is 120 × 30, so make it a little taller.)

  You can resize the window while playing.
- **Characters:** a UTF-8 locale and a font with emoji. The other
  characters are all in SF Mono, Terminal.app's default font, so nothing
  needs to come from a fallback font.
- **Commands:** just `stty`, `sleep` and `date`. The game asks the terminal
  itself for its size (as xterm's `resize` does), so needs no `tput`. The
  only programs started during play are `sleep`, once a frame, and `date`,
  every few frames, to keep the game at 60 frames a second.

  The script is plain POSIX shell, and uses these commands as POSIX
  defines them, with one exception: it needs `sleep` to accept fractions of
  a second (`sleep 0.016`), which POSIX doesn't require. macOS, Linux (GNU
  and BusyBox) and the BSDs all do.

The screen isn't cleared between frames, so it doesn't flicker even in
terminals without synchronized output (such as Terminal.app). A typical
frame is about 100 bytes.

## How faithful is it?

The rules and timings come from the arcade's code, via the commented
disassembly at [computerarcheology.com][code]. The game runs at the
arcade's 60 frames a second and works in the arcade's own coordinates (its
224 × 256-pixel screen), converting to rows and columns only to draw. One
column is 4 of the arcade's pixels.

As in the arcade:

- The invaders move one at a time, rippling through the formation from the
  bottom left, and turn where the arcade's do. They speed up as their
  numbers fall.
- Later waves start lower, at the arcade's heights.
- The three kinds of invader shot (rolling, plunger and squiggly) move, aim
  and reload as the arcade's do, and fire from the same table of columns.
  Their characters animate like the arcade's pictures, and they speed up
  when 8 or fewer invaders are left.
- Shots meeting each other can pass, or either or both can be destroyed,
  with the frequencies the arcade's pixel collisions give (see
  [docs/shot-collisions](docs/shot-collisions/README.md)).
- The shields wear away, and invaders passing through them erase them.
- Invader shots landing wear away the green line at the bottom, pixel by
  pixel.
- The flying saucer appears every 1536 frames once the invaders are low
  enough, and its score depends on how many shots you've fired.
- An extra cannon is awarded at 1500 points.
- Explosions last as long as the arcade's, and as in the arcade you can't
  fire until yours has cleared.

The main differences:

- Invaders are emoji, so they don't switch between two pictures as they
  move.
- Positions are only as fine as a terminal cell. Where the arcade's
  outcome depends on pixels the game doesn't have (shots meeting, which
  parts of the ground erode), it's chosen with the arcade's frequencies.
- One player only, and no sound apart from the terminal bell when you're
  hit or win a cannon.

[code]: https://computerarcheology.com/Arcade/SpaceInvaders/Code.html
