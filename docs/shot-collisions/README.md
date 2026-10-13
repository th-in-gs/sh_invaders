# When shots meet

What happens in the arcade Space Invaders when the player's shot meets an
invader shot, and how often? `ShotSim.swift` here answers that by
simulating the arcade pixel by pixel, and this note explains the reasoning
and what it means for "#!/bin/sh Invaders".

Run the simulator with `./ShotSim.swift` (or `swift ShotSim.swift`).

## The question

The game used to follow a claim from a play guide: "When an invader's
missile collides with a player's laser shot, the player's shot is always
destroyed but the invader's missile occasionally survives, almost certainly
if it is a wiggly missile" ([ClassicGaming.cc][cgc]; [BrentRadio][brent]
has the same text). So meeting an invader shot always ended your shot, and
only the squiggly shot ever survived, always.

That text is the only source for the squiggly claim. Its other details are
loose: it describes the shots as "slow straight ones, fast straight ones
and wiggly ones", but all three move at the same speed. Other accounts:

- [PrimeTime Amusements][prime]: invader shots "will frequently survive
  your own and keep hurdling towards you, especially if they're the
  stronger version of enemy fire: the wiggly-line missile" (apparently a
  paraphrase of the guide above).
- [StrategyWiki][sw]: "it can be either your bullet or the alien's that
  continues on."
- [Shmups Wiki][shmups]: "Always assume alien shots will pierce through
  cannon shots", and "Aim for the sides of aliens rather than their
  centers. This decreases the chance of shots being canceled by enemy
  fire."
- A [MobyGames][moby] review: the invaders block your shots and "both
  lasers disappear".

None is a measurement. The arcade's code has no special case for any shot
type, so the only way to get the rates is to simulate what its code does.

## How the arcade handles it

All from the [commented disassembly][code]. Coordinates are pixels, x
across and y up the screen, as the arcade's video memory lays them out: one
32-byte line per x, pixel y at bit `y & 7` of byte `y >> 3`.

**Collisions are pixel collisions.** Sprites are drawn through a hardware
shift register by three routines:

| Routine | Address | Effect |
|---|---|---|
| DrawShiftedSprite | `1400` | ORs the sprite onto the screen |
| EraseShifted | `1452` | ANDs the screen with the inverted sprite: it clears those pixels whichever object lit them |
| DrawSprCollision | `1491` | ORs the sprite on, setting a flag (`2061`) if any of its pixels were already lit |

A moving object erases itself, moves, and redraws with collision detection.
It has collided if it lands on lit pixels. Nothing records *what* it hit.

**The player's shot** (object 1, sprite `1C90`: 1 × 4 pixels) starts at
y `0x28` (`1B29`) and moves 4 px a frame (`1B2C`, `MovePlyShot` at `040A`).

When its draw collides, the main loop's `PlayerShotHit` (`14D8`, called
from `0822` via `190A`) marks it as blowing up (status 3, `1530`). It does
this before the shot's next run.

That next run (`03D7`–`03F7`) erases the shot and draws its explosion
(`1C91`, 8 × 8) 3 px left and 2 px down. The explosion stays for 15 more
runs, and is then erased (`0436`).

Your shot always dies once it touches anything. Inside the invader
formation, the touch is instead treated as hitting the invader at that
spot, if there is one alive there (`1504`–`152F`).

**Invader shots** are objects 2–4: rolling, plunger and squiggly. Each is
3 × 8 pixels with four pictures, at `1CEE`, `1CE2` and `1CD0`.

The object list runs from both interrupts, twice a frame. Even so, the
timer and `shotSync` logic gives each invader shot exactly one run every
third frame (`0476`–`04C1`, `1A06`).

A run (`05C1`–`0617`) erases the shot, advances its picture, moves it by
`207E`, and draws it with collision. `207E` is `FC` (−4) normally, from
`1B7E`; the disassembly's "Normally FF" comment is wrong. With 8 or fewer
invaders it is `FB` (−5), set at `08D8`. If the draw collides, the shot is
destroyed. It blows up on its later runs (`0644`): the next one erases it
and draws its explosion (`1CDC`, 6 × 8) 2 px left and 2 px down; two runs
after that, the explosion is erased.

So an invader shot survives only by never landing on lit pixels: neither
your shot, nor the explosion it leaves behind.

## Things that matter for the simulation

**Order within a frame doesn't matter.** Objects run in list order, so your
shot moves before an invader shot in the same interrupt. Shots in
different halves of the screen run in different interrupts. Either way,
over a full cycle, one order is just the other one started a frame later,
and the results are identical.

**Vertical alignment is fixed, not random.**

- Your shot is always at `0x28` + 4k, a multiple of 4.
- Invader heights are always multiples of 8:
  - the wave start heights are `78 60 50 48 48 48 40 40 40` (`07EA`,
    `1DA3`);
  - rows are 16 px apart;
  - the rack drops 8 px at a time.
- An invader shot starts 10 px below its invader (`05B1`), so at 2 mod 4.
- Its first draw is one step later, with picture 1. Pictures advance one
  per step.

So:

- **Normal speed:** (invader shot y − your shot y) mod 4 is always 2.
- **Fast speed:** each 5 px step changes that offset by −1 (mod 4) and the
  picture by +1. So picture + offset is always 2 mod 4.

The last table below shows that the conclusions hold for any offset, so
this isn't critical.

**The relative motion repeats every 3 frames.** In that time your shot
rises 12 px and the invader shot falls one step, so the shots close by
12 + step px. The simulator runs every alignment over whole periods, each
counted once.

## Results

Each meeting is followed until neither shot can affect the other. There are
four outcomes, because your shot can survive too: when the invader shot
runs into your shot, it is destroyed, while your shot carries on 4 px a
frame and is clear before the invader shot's explosion is drawn.

**With your shot on one of the invader shot's three columns, at the
arcade's alignments:**

| | Both carry on | Invader shot survives | Your shot survives | Both destroyed |
|---|---|---|---|---|
| Squiggly | 0% | 8% | 8% | 83% |
| Plunger | 4% | 29% | 13% | 54% |
| Rolling | 27% | 19% | 8% | 46% |
| *Fast (8 or fewer invaders):* | | | | |
| Squiggly | 0% | 39% | 8% | 53% |
| Plunger | 4% | 37% | 16% | 43% |
| Rolling | 28% | 12% | 8% | 53% |

Meetings where both carry on are the ones where your shot slips through
the gaps in the invader shot's pattern. The squiggly has lit pixels at
every height in all three of its columns, so it can't be slipped through.

**Invader shot survival by vertical offset** (normal speed, out of meetings
where the shots touched):

| | 0 | 1 | 2 (the arcade's) | 3 |
|---|---|---|---|---|
| Squiggly | 8% | 8% | 8% | 4% |
| Plunger | 35% | 18% | 30% | 22% |
| Rolling | 14% | 17% | 26% | 31% |

The play guide has it backwards for normal speed. The squiggly is the
*easiest* shot to shoot down, at every alignment. Its pattern is dense, so
it almost always runs into your shot's explosion.

At fast speed it survives about as often as the others: it jumps far
enough to clear the explosion. Fast speed comes at the end of every wave,
which is when meetings are most dangerous and memorable. That, and the
squiggly being the most eye-catching shot, may be where the folklore comes
from. This is speculation.

## Applying this to the game

"#!/bin/sh Invaders" only knows shot positions to the terminal cell. A
column is 4 arcade pixels wide (224 px / 56 columns). `check_bombs` (in
`space_invaders.sh`) sees a
meeting when both shots are in the same column and your shot is in the
invader shot's row or the one above.

The rows need no extra accounting. Shots move in arcade pixels and close
by at most 9 px a frame, about a row, so they can't skip past each other.
The arcade's fixed vertical alignment is already inside the rates.

The columns do. In the arcade, consider your shot anywhere along a stretch
w px wide. It is on one of the invader shot's 3 columns with chance 3/w,
and in the same 4 px column with chance 4/w. So for each same-column
meeting in the game:

- each of the invader shot's columns has weight ¼;
- "horizontally clear, both carry on" has weight ¼.

The cannon moves 1 px at a time and the invaders 2, so the position within
the cell is effectively uniform.

**Rates for a same-column meeting in the game:**

| | Both carry on | Invader shot survives | Your shot survives | Both destroyed |
|---|---|---|---|---|
| Squiggly | 25% | 6% | 6% | 63% |
| Plunger | 28% | 22% | 9% | 41% |
| Rolling | 45% | 14% | 6% | 34% |
| *Fast (8 or fewer invaders):* | | | | |
| Squiggly | 25% | 29% | 6% | 40% |
| Plunger | 28% | 28% | 12% | 32% |
| Rolling | 46% | 9% | 6% | 40% |

The game (`meet_outcome` in `space_invaders.sh`) chooses among the four
outcomes with these frequencies, rounded to whole percentages, using a
count of frames since startup: `frame % 100`. Which frame two shots meet
on depends on the player's timing, to the 1/60 s, much as the arcade's
pixel positions do. So there's no random number generator, and nothing
beyond POSIX sh (`/dev/urandom` and `$RANDOM` aren't POSIX). Invader shots
move every third frame, but 100 has no factor of 3, so that doesn't skew
the choice.

A pair of shots that pass each other may still be level on the next
frame. So each invader shot type remembers which player shot passed it,
and isn't rolled for again until a new shot comes along.

What the cell-level version can't show is *where* things happen. In the
arcade, a destroyed invader shot usually dies a frame or three later, a few
pixels lower, running into the explosion. A surviving player shot carries
on from just above the meeting. At terminal resolution, applying the
outcome at the meeting looks the same.

## Not modelled

All of these are rare:

- **A shot fired right beside an invader shot.** Your shot's first
  appearance is drawn without collision detection (`InitPlyShot`, `03FA`).
- **Invader shots already falling when the speed changes** don't follow
  the fast-speed picture rule.
- **Meetings inside the invader formation** may kill an invader instead.
- **Shields and other lit pixels** next to the meeting.

## How we got here

The first simulation (Python) used random alignments drawn from a narrow,
unevenly weighted range, which skewed it by a few points. A Ruby rewrite
emulated video memory byte by byte and ran every alignment instead. That
found the bias, and with it fixed the two agreed.

The Swift version is a fresh rewrite. It adds both shots' fates, the
invader shot's explosion, the arcade's fixed alignments, and the cell-level
weighting. Under the old assumptions it reproduces the Ruby figures
exactly; that's the first table `ShotSim.swift` prints.

**Still to do:** check against real footage. Step through 60 fps
recordings of the arcade frame by frame (on YouTube, pause, then `.` and
`,`), and watch:

- whether shots often pass through each other;
- whether your shot ever survives an invader shot blowing up;
- how often each type gets through.

[cgc]: https://classicgaming.cc/classics/space-invaders/play-guide
[brent]: https://www.brentradio.com/SpaceInvaders2.htm
[prime]: https://primetimeamusements.com/getting-good-space-invaders/
[sw]: https://strategywiki.org/wiki/Space_Invaders/Walkthrough
[shmups]: https://shmups.wiki/library/Space_Invaders
[moby]: https://www.mobygames.com/game/8806/space-invaders/
[code]: https://computerarcheology.com/Arcade/SpaceInvaders/Code.html
