#!/usr/bin/env sh
# Space Invaders clone in POSIX shell
# Emoji invaders, '!' for bullets, Unicode ship.
#
# Geometry and timings follow the 1978 arcade game (224x256 pixel screen),
# scaled so that one terminal column is ~4 pixels: the playfield is a fixed
# 56 columns wide, centred in the terminal, and up to 32 rows tall.

set -u
set -f  # no globbing when splitting state strings

ESC=$(printf '\033')
BEL=$(printf '\007')

field_w=56  # 224 arcade pixels at ~4 pixels per column

# ---------------------------------------------------------------------------
# Terminal setup / teardown
# ---------------------------------------------------------------------------

cleanup() {
  trap - INT TERM HUP
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  if [ -n "${old_stty:-}" ]; then
    stty "$old_stty" 2>/dev/null || stty sane 2>/dev/null || true
  fi
  exit 0
}

# Sets $row to the terminal row for arcade height $1 (pixels from the bottom
# of the 256-pixel-tall arcade screen).
y2row() {
  row=$((y0 + field_h - ($1 * field_h + 128) / 256))
}

init() {
  rows=$(tput lines)
  cols=$(tput cols)
  if [ $cols -lt $((field_w + 2)) ] || [ $rows -lt 24 ]; then
    echo "Terminal is ${cols}x${rows}; at least $((field_w + 2))x24 is needed." >&2
    exit 1
  fi

  trap cleanup INT TERM HUP

  # Playfield: field_w columns (plus a border each side) by field_h rows,
  # centred. The arcade screen's aspect would be 32 rows; 24 is the minimum.
  field_h=$rows
  [ $field_h -gt 32 ] && field_h=32
  x0=$(( (cols - field_w - 2) / 2 + 1 ))  # left border column
  y0=$(( (rows - field_h) / 2 ))          # rows above the playfield
  left=$((x0 + 1))
  right=$((x0 + field_w))
  hud_row=$((y0 + 1))
  top_row=$((y0 + 2))                     # shots vanish above this

  y2row 16; ground_row=$row               # the arcade's green line
  ship_row=$((ground_row - 1))
  # The arcade ends the game when the formation reaches Y=40 (just above
  # the cannon's top)
  y2row 40; land_row=$row
  [ $land_row -gt $((ship_row - 1)) ] && land_row=$((ship_row - 1))

  # Shields: four 22x16-pixel arches with a notch underneath, bases at Y=48,
  # left edges at x=34, 79, 124, 169. At this scale, 6 columns x 2 rows:
  #   ▟████▙
  #   ██  ██
  # Cells are listed as "row:col:kind" (L/R = rounded top corners).
  y2row 48; shield_bot=$row
  shield_top=$((shield_bot - 1))
  shield_cells=""
  for x in 34 79 124 169; do
    sx=$((left + x / 4))
    dc=0
    while [ $dc -lt 6 ]; do
      kind=B
      [ $dc -eq 0 ] && kind=L
      [ $dc -eq 5 ] && kind=R
      shield_cells="$shield_cells $shield_top:$((sx + dc)):$kind"
      [ $dc -lt 2 ] || [ $dc -gt 3 ] &&
        shield_cells="$shield_cells $shield_bot:$((sx + dc)):B"
      dc=$((dc + 1))
    done
  done

  # Arcade timings (60 Hz) converted to frames at this game's ~52 fps and to
  # rows at this playfield height (256 / field_h pixels per row).
  #   player shot:   4 px/frame (240 px/s)
  #   invader shots: 80 px/s, or 100 px/s with 8 or fewer invaders left
  shot_period=$(( (55 + field_h / 2) / field_h ))
  [ $shot_period -lt 1 ] && shot_period=1
  bomb_period_slow=$(( (166 + field_h / 2) / field_h ))
  bomb_period_fast=$(( (133 + field_h / 2) / field_h ))

  # Invader formation: 11 x 5, rows 16 arcade pixels apart, columns 4 apart
  inv_rows=5
  inv_cols=11
  inv_spacing=$(( (16 * field_h + 128) / 256 ))
  [ $inv_spacing -lt 1 ] && inv_spacing=1
  inv_start_col=$((left + (field_w - (inv_cols - 1) * 4 - 2) / 2))

  # Static scenery, built once: side borders, ground line, controls
  scenery="${ESC}[2m"
  r=$top_row
  while [ $r -lt $ground_row ]; do
    scenery="$scenery${ESC}[$r;${x0}H│${ESC}[$r;$((right + 1))H│"
    r=$((r + 1))
  done
  line=""
  c=0
  # Braces matter: bash 3.2 can read a multibyte character as part of a name
  while [ $c -lt $field_w ]; do line="${line}─"; c=$((c + 1)); done
  scenery="$scenery${ESC}[0m${ESC}[32m${ESC}[$ground_row;${left}H$line${ESC}[0m"
  scenery="$scenery${ESC}[$((ground_row + 1));$((left + 7))HMove: h/l or arrows  Fire: SPACE  Quit: q"

  quit=0
  seed=$$  # random number generator state (see rand)
  new_game

  # Non-blocking, unechoed, unbuffered input: reads return immediately
  old_stty=$(stty -g)
  stty -icanon -echo min 0 time 0
  tput civis 2>/dev/null || true
  tput smcup 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Game state
#   invaders: space-separated "row:col:sprite"
#   bullets:  the player's shot, "row:col" (at most one, as in the arcade)
#   bombs:    space-separated "row:col" invader shots (at most three)
#   sh_ROW_COL: hit points left in each shield cell (2 full, 1 damaged,
#             unset or 0 gone). POSIX sh has no arrays, hence one variable
#             per cell, accessed with eval.
# ---------------------------------------------------------------------------

# Restores all shields to full strength (at the start of each wave).
reset_shields() {
  for s in $shield_cells; do
    IFS=:
    set -- $s
    unset IFS
    eval "sh_$1_$2=2"
  done
  shields_dirty=1
}

# Damages the shield cell at row $1, column $2. Returns 1 if there is no
# shield there.
hit_shield() {
  [ $1 -lt $shield_top ] || [ $1 -gt $shield_bot ] && return 1
  eval "hp=\${sh_$1_$2:-0}"
  [ $hp -eq 0 ] && return 1
  eval "sh_$1_$2=$((hp - 1))"
  shields_dirty=1
  return 0
}

# Shots that hit a shield damage it and are destroyed.
check_shields() {
  for b in $bullets; do
    hit_shield ${b%:*} ${b#*:} && bullets=""
  done
  remaining=""
  for m in $bombs; do
    hit_shield ${m%:*} ${m#*:} && continue
    remaining="$remaining $m"
  done
  bombs=$remaining
}

# Sets $rnd to a pseudo-random number in 0..$1-1 without a subprocess
# (POSIX sh has no $RANDOM). Linear congruential generator.
rand() {
  seed=$(( (seed * 1103515245 + 12345) % 2147483648 ))
  rnd=$(( (seed / 65536) % $1 ))
}

# Frames before the invaders may fire again. The arcade's table, by score:
# 48/16/11/8/7 shot steps of 3 frames at 60 Hz, converted to ~52 fps.
reload_bombs() {
  if [ $score -lt 200 ]; then bomb_wait=125
  elif [ $score -lt 1000 ]; then bomb_wait=42
  elif [ $score -lt 2000 ]; then bomb_wait=29
  elif [ $score -lt 3000 ]; then bomb_wait=21
  else bomb_wait=18
  fi
}

# Points by invader type, as in the arcade (top row 30, middle 20, bottom 10)
points() {
  case $1 in
    👾) pts=30 ;;
    🦀) pts=20 ;;
    *) pts=10 ;;
  esac
}

spawn_wave() {
  # The arcade starts the first wave's bottom row at Y=120, and later waves
  # lower: 96, 80, 72, 72, 72, 64, 64, 64, then back to 96.
  if [ $wave -eq 1 ]; then
    y=120
  else
    case $(( (wave - 2) % 8 )) in
      0) y=96 ;;
      1) y=80 ;;
      2|3|4) y=72 ;;
      *) y=64 ;;
    esac
  fi
  y2row $y
  bottom=$row
  # At low heights the arcade starts the formation just above the shields;
  # rounding to rows can put it on them, so keep it one row clear.
  [ $bottom -ge $shield_top ] && bottom=$((shield_top - 1))

  invaders=""
  r=0
  while [ $r -lt $inv_rows ]; do
    case $r in
      0) sprite="👾" ;;     # the arcade's "squid"
      1|2) sprite="🦀" ;;   # "crab"
      *) sprite="🐙" ;;     # "octopus"
    esac
    ir=$((bottom - (inv_rows - 1 - r) * inv_spacing))
    c=0
    while [ $c -lt $inv_cols ]; do
      invaders="$invaders $ir:$((inv_start_col + c * 4)):$sprite"
      c=$((c + 1))
    done
    r=$((r + 1))
  done
  inv_count=$((inv_rows * inv_cols))
  reset_shields
  bullets=""
  bombs=""
  shot_tick=0
  bomb_tick=0
  bomb_turn=0
  reload_bombs
  inv_dir=1
  inv_tick=0
}

# Starts a new game (at launch, and on 'r' after game over).
new_game() {
  score=0
  lives=3
  wave=1
  game_over=0
  boom=0   # frames left of the ship's explosion (game is paused meanwhile)
  bell=0   # ring the terminal bell on the next draw
  ship_col=$((left + field_w / 2 - 2))
  spawn_wave
}

# The ship was hit: lose a life, ring the bell and play the explosion. As in
# the arcade, the game pauses while the ship explodes and the screen is
# cleared of shots.
player_hit() {
  lives=$((lives - 1))
  bell=1
  boom=30
  bullets=""
  bombs=""
  reload_bombs
  [ $lives -le 0 ] && game_over=1
}

# Invaders reached the bottom: as in the arcade, the ship is destroyed and
# the game ends, however many lives are left.
invaded() {
  player_hit
  lives=0
  game_over=1
}

# Sets $move (-1, 0, 1), $fire (0/1), $restart (0/1) and $quit from all
# keys pressed since the previous frame.
read_input() {
  move=0
  fire=0
  restart=0
  # Terminal is in min 0 time 0 mode, so read returns at once with whatever
  # is pending (status 1, as it sees EOF). IFS= keeps spaces (fire key).
  IFS= read -r keys
  while [ -n "$keys" ]; do
    rest=${keys#?}
    key=${keys%"$rest"}
    keys=$rest
    if [ "$key" = "$ESC" ]; then
      case $keys in
        '[D'*|'OD'*) move=-1 ;;
        '[C'*|'OC'*) move=1 ;;
        '[A'*|'OA'*) fire=1 ;;
      esac
      keys=${keys#??}
      continue
    fi
    case $key in
      q|Q) quit=1 ;;
      r|R) restart=1 ;;
      h|H|a|A) move=-1 ;;
      l|L|d|D) move=1 ;;
      ' ') fire=1 ;;
    esac
  done
}

# The player's shot climbs one row every $shot_period frames.
move_bullets() {
  shot_tick=$((shot_tick + 1))
  [ $shot_tick -lt $shot_period ] && return
  shot_tick=0
  moved=""
  for b in $bullets; do
    br=$((${b%:*} - 1))
    [ $br -ge $top_row ] && moved="$moved $br:${b#*:}"
  done
  bullets=$moved
}

check_collisions() {
  [ -z "$bullets" ] && return
  survivors=""
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    ir=$1; ic=$2
    hit=0
    remaining=""
    for b in $bullets; do
      if [ $hit -eq 0 ]; then
        br=${b%:*}; bc=${b#*:}
        # Emoji sprites are two columns wide
        if [ $br -eq $ir ] && [ $bc -ge $ic ] && [ $bc -le $((ic + 1)) ]; then
          hit=1
          points "$3"
          score=$((score + pts))
          inv_count=$((inv_count - 1))
          continue
        fi
      fi
      remaining="$remaining $b"
    done
    bullets=$remaining
    [ $hit -eq 0 ] && survivors="$survivors $inv"
  done
  invaders=$survivors
}

# Returns 0 if the formation moved this frame; sets $landed=1 if any invader
# has reached $land_row.
move_invaders() {
  landed=0
  # The arcade moves one invader 2 pixels per frame, so the whole formation
  # steps one column (~4 pixels) every 2 x invaders frames at 60 Hz: about
  # 1.75 x invaders frames here. The last invader moves 3 pixels per frame,
  # so it steps every frame.
  inv_tick=$((inv_tick + 1))
  [ $inv_tick -lt $((inv_count * 7 / 4)) ] && return 1
  inv_tick=0

  min_col=$cols
  max_col=0
  for inv in $invaders; do
    ic=${inv#*:}; ic=${ic%%:*}
    [ $ic -gt $max_col ] && max_col=$ic
    [ $ic -lt $min_col ] && min_col=$ic
  done

  # Reverse and drop on reaching a border (sprites are two columns wide)
  drop=0
  if [ $inv_dir -eq 1 ] && [ $((max_col + 1)) -ge $right ]; then
    inv_dir=-1; drop=1
  elif [ $inv_dir -eq -1 ] && [ $min_col -le $left ]; then
    inv_dir=1; drop=1
  fi

  moved=""
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    ir=$(($1 + drop))
    ic=$(($2 + inv_dir))
    [ $ir -ge $land_row ] && landed=1
    # Invaders passing through the shields erase them, as in the arcade
    if [ $ir -ge $shield_top ] && [ $ir -le $shield_bot ]; then
      eval "sh_${ir}_${ic}=0 sh_${ir}_$((ic + 1))=0"
      shields_dirty=1
    fi
    moved="$moved $ir:$ic:$3"
  done
  invaders=$moved
  return 0
}

# Invader shots fall one row every $bomb_period_slow frames, or every
# $bomb_period_fast frames once 8 or fewer invaders are left.
move_bombs() {
  bomb_tick=$((bomb_tick + 1))
  if [ $inv_count -le 8 ]; then
    [ $bomb_tick -lt $bomb_period_fast ] && return
  else
    [ $bomb_tick -lt $bomb_period_slow ] && return
  fi
  bomb_tick=0
  moved=""
  for m in $bombs; do
    mr=$((${m%:*} + 1))
    [ $mr -lt $ground_row ] && moved="$moved $mr:${m#*:}"
  done
  bombs=$moved
}

# Fires a new invader shot when reloaded and fewer than three are in flight
# (two when one invader is left: the arcade then disables its "plunger"
# shot). Every third shot is aimed at the player (the arcade's "rolling"
# shot); the rest drop from a random column. Shots come from the lowest
# invader in the chosen column.
drop_bomb() {
  bomb_wait=$((bomb_wait - 1))
  [ $bomb_wait -gt 0 ] && return
  [ -z "$invaders" ] && return
  max_bombs=3
  [ $inv_count -eq 1 ] && max_bombs=2
  set -- $bombs
  [ $# -ge $max_bombs ] && return

  if [ $bomb_turn -eq 0 ]; then
    target=$((ship_col + 1))
  else
    set -- $invaders
    rand $#
    shift $rnd
    target=${1#*:}; target=${target%%:*}
  fi
  bomb_turn=$(( (bomb_turn + 1) % 3 ))

  # Sprites are two columns wide; fire from whichever half is nearer the
  # target, so an aimed shot can't fall just beside the ship.
  best=-1; sr=0; sc=0
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    c=$2
    [ $target -gt $c ] && c=$((c + 1))
    d=$((c - target)); [ $d -lt 0 ] && d=$((-d))
    if [ $best -lt 0 ] || [ $d -lt $best ] ||
       { [ $d -eq $best ] && [ $1 -gt $sr ]; }; then
      best=$d; sr=$1; sc=$c
    fi
  done
  bombs="$bombs $((sr + 1)):$sc"
  reload_bombs
}

# Handles invader shots hitting the ship or meeting the player's shot. As in
# the arcade, when the two shots meet only the player's is destroyed.
check_bombs() {
  shot=0
  remaining=""
  for m in $bombs; do
    mr=${m%:*}; mc=${m#*:}
    # The ship's hitbox is its full 3x2 cell box: a shot touching the top of
    # either base triangle counts, not just one landing on it next frame.
    if [ $mr -ge $((ship_row - 1)) ] && [ $mr -le $ship_row ] &&
       [ $mc -ge $ship_col ] && [ $mc -le $((ship_col + 2)) ]; then
      shot=1
      continue
    fi
    for b in $bullets; do
      # The shots move toward each other, so they can pass between frames
      br=${b%:*}
      if [ ${b#*:} -eq $mc ] && [ $br -ge $((mr - 1)) ] && [ $br -le $mr ]; then
        bullets=""
      fi
    done
    remaining="$remaining $m"
  done
  bombs=$remaining
  [ $shot -eq 1 ] && player_hit
}

# ---------------------------------------------------------------------------
# Rendering: build the whole frame in a string, then emit it in one go
# (wrapped in synchronized-output escapes where the terminal supports them).
# ---------------------------------------------------------------------------

draw() {
  f="${ESC}[?2026h${ESC}[H${ESC}[2J$scenery"
  [ $bell -eq 1 ] && { f="$f$BEL"; bell=0; }

  # Lives are shown in reverse video while the ship explodes
  lives_txt="Lives: $lives"
  [ $boom -gt 0 ] && lives_txt="${ESC}[7m$lives_txt${ESC}[0m"
  f="$f${ESC}[$hud_row;${left}HScore: $score  $lives_txt  Wave: $wave"

  if [ $boom -gt 0 ]; then
    # Two-frame explosion, alternating every 4 frames like the arcade's
    if [ $((boom / 4 % 2)) -eq 0 ]; then
      f="$f${ESC}[$((ship_row - 1));${ship_col}H\\|/"
      f="$f${ESC}[$ship_row;${ship_col}H/|\\"
    else
      f="$f${ESC}[$((ship_row - 1));${ship_col}H.*."
      f="$f${ESC}[$ship_row;${ship_col}H*.*"
    fi
  else
    f="$f${ESC}[$((ship_row - 1));$((ship_col + 1))H▲"
    f="$f${ESC}[$ship_row;${ship_col}H◢ ◣"
  fi

  # Shields (green, like the arcade's screen overlay) change only when hit,
  # so they are re-rendered only then
  if [ $shields_dirty -eq 1 ]; then
    shield_frame="${ESC}[32m"
    for s in $shield_cells; do
      IFS=:
      set -- $s
      unset IFS
      eval "hp=\${sh_$1_$2:-0}"
      case $hp in
        0) continue ;;
        1) g='▒' ;;
        *)
          case $3 in
            L) g='▟' ;;
            R) g='▙' ;;
            *) g='█' ;;
          esac ;;
      esac
      shield_frame="$shield_frame${ESC}[$1;$2H$g"
    done
    shield_frame="$shield_frame${ESC}[0m"
    shields_dirty=0
  fi
  f="$f$shield_frame"

  # The formation rarely changes between frames (at the start it steps every
  # ~2s), so only re-render it when it has.
  if [ "$invaders" != "${drawn_invaders-}" ]; then
    inv_frame=""
    for inv in $invaders; do
      IFS=:
      set -- $inv
      unset IFS
      inv_frame="$inv_frame${ESC}[$1;$2H$3"
    done
    drawn_invaders=$invaders
  fi
  f="$f$inv_frame"

  for b in $bullets; do
    f="$f${ESC}[${b%:*};${b#*:}H!"
  done

  for m in $bombs; do
    f="$f${ESC}[${m%:*};${m#*:}H|"
  done

  if [ $game_over -eq 1 ]; then
    mid_r=$((y0 + field_h / 2))
    mid_c=$((left + field_w / 2))
    f="$f${ESC}[$((mid_r - 1));$((mid_c - 8))H=== GAME OVER ==="
    f="$f${ESC}[$mid_r;$((mid_c - 5))HScore: $score"
    f="$f${ESC}[$((mid_r + 1));$((mid_c - 16))HPress 'r' to restart, 'q' to quit"
  fi

  printf '%s' "$f${ESC}[?2026l"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

main() {
  init

  while [ $quit -eq 0 ]; do
    read_input

    if [ $game_over -eq 1 ] && [ $restart -eq 1 ]; then
      new_game
    elif [ $boom -gt 0 ]; then
      boom=$((boom - 1))
    elif [ $game_over -eq 0 ]; then
      if [ $move -lt 0 ] && [ $ship_col -gt $left ]; then
        ship_col=$((ship_col - 1))
      elif [ $move -gt 0 ] && [ $((ship_col + 2)) -lt $right ]; then
        ship_col=$((ship_col + 1))
      fi
      # One shot on screen at a time, as in the arcade
      if [ $fire -eq 1 ] && [ -z "$bullets" ]; then
        bullets="$((ship_row - 1)):$((ship_col + 1))"
        shot_tick=0
      fi

      move_bullets
      check_shields
      check_collisions
      if move_invaders; then
        # Re-check so bullets can't slip past invaders that just dropped
        check_collisions
        [ $landed -eq 1 ] && invaded
      fi
      if [ $game_over -eq 0 ]; then
        move_bombs
        drop_bomb
        check_shields
        check_bombs
      fi
      if [ -z "$invaders" ]; then
        wave=$((wave + 1))
        spawn_wave
      fi
    fi

    draw
    # Aim for ~50 fps. Frame work is <1ms; the rest is the cost of starting
    # sleep itself (~6-10ms on macOS), so the delay is set below 0.02.
    sleep 0.012
  done

  cleanup
}

main
