#!/usr/bin/env sh
# Space Invaders clone in POSIX shell
# Emoji invaders, '!' for bullets, Unicode ship.

set -u
set -f  # no globbing when splitting state strings

ESC=$(printf '\033')
BEL=$(printf '\007')

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

init() {
  trap cleanup INT TERM HUP

  rows=$(tput lines)
  cols=$(tput cols)

  # Ship: "◢ ◣" on ship_row starting at ship_col, "▲" above at ship_col+1
  ship_row=$((rows - 2))
  ship_col=$((cols / 2 - 2))

  # Invader formation (row 1 is the HUD)
  inv_start_row=2
  inv_start_col=5
  inv_rows=4
  inv_cols=8

  score=0
  lives=3
  game_over=0
  quit=0
  boom=0   # frames left of the ship's explosion (game is paused meanwhile)
  bell=0   # ring the terminal bell on the next draw
  seed=$$  # random number generator state (see rand)
  spawn_wave

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
# ---------------------------------------------------------------------------

# Sets $rnd to a pseudo-random number in 0..$1-1 without a subprocess
# (POSIX sh has no $RANDOM). Linear congruential generator.
rand() {
  seed=$(( (seed * 1103515245 + 12345) % 2147483648 ))
  rnd=$(( (seed / 65536) % $1 ))
}

# Frames before the invaders may fire again. As in the arcade, they fire
# faster as the player's score rises.
reload_bombs() {
  if [ $score -lt 200 ]; then bomb_wait=96
  elif [ $score -lt 1000 ]; then bomb_wait=32
  elif [ $score -lt 2000 ]; then bomb_wait=22
  elif [ $score -lt 3000 ]; then bomb_wait=16
  else bomb_wait=14
  fi
}

spawn_wave() {
  invaders=""
  r=0
  while [ $r -lt $inv_rows ]; do
    case $r in
      0) sprite="👾" ;;
      1) sprite="👽" ;;
      2) sprite="🤖" ;;
      *) sprite="👹" ;;
    esac
    c=0
    while [ $c -lt $inv_cols ]; do
      invaders="$invaders $((inv_start_row + r)):$((inv_start_col + c * 4)):$sprite"
      c=$((c + 1))
    done
    r=$((r + 1))
  done
  inv_count=$((inv_rows * inv_cols))
  bullets=""
  bombs=""
  bomb_tick=0
  bomb_turn=0
  reload_bombs
  inv_dir=1
  inv_tick=0
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

# Invaders reached the ship's row: lose a life and restart the wave.
lose_life() {
  player_hit
  [ $game_over -eq 0 ] && spawn_wave
}

# Sets $move (-1, 0, 1), $fire (0/1) and $quit from all keys pressed since
# the previous frame.
read_input() {
  move=0
  fire=0
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
      h|H|a|A) move=-1 ;;
      l|L|d|D) move=1 ;;
      ' ') fire=1 ;;
    esac
  done
}

move_bullets() {
  moved=""
  for b in $bullets; do
    br=$((${b%:*} - 1))
    # Row 1 is the HUD; bullets disappear once they reach it
    [ $br -gt 1 ] && moved="$moved $br:${b#*:}"
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
          score=$((score + 10))
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
# has reached the ship.
move_invaders() {
  landed=0
  # The arcade moves one invader per frame, so the march speeds up as the
  # formation thins out. Approximate that by moving the whole formation
  # every (invaders / 4) frames: 32 left -> every 8th frame, 1 -> every frame.
  inv_tick=$((inv_tick + 1))
  [ $inv_tick -lt $(( (inv_count + 3) / 4 )) ] && return 1
  inv_tick=0

  min_col=$cols
  max_col=0
  for inv in $invaders; do
    ic=${inv#*:}; ic=${ic%%:*}
    [ $ic -gt $max_col ] && max_col=$ic
    [ $ic -lt $min_col ] && min_col=$ic
  done

  drop=0
  if [ $inv_dir -eq 1 ] && [ $max_col -ge $((cols - 4)) ]; then
    inv_dir=-1; drop=1
  elif [ $inv_dir -eq -1 ] && [ $min_col -le 2 ]; then
    inv_dir=1; drop=1
  fi

  moved=""
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    ir=$(($1 + drop))
    ic=$(($2 + inv_dir))
    [ $ir -ge $((ship_row - 1)) ] && landed=1
    moved="$moved $ir:$ic:$3"
  done
  invaders=$moved
  return 0
}

# Invader shots fall at half the speed of the player's.
move_bombs() {
  bomb_tick=$((1 - bomb_tick))
  [ $bomb_tick -eq 0 ] && return
  moved=""
  for m in $bombs; do
    mr=$((${m%:*} + 1))
    [ $mr -le $rows ] && moved="$moved $mr:${m#*:}"
  done
  bombs=$moved
}

# Fires a new invader shot when reloaded and fewer than three are in flight.
# Every third shot is aimed at the player (the arcade's "rolling" shot); the
# rest drop from a random column. Shots come from the lowest invader in the
# chosen column.
drop_bomb() {
  bomb_wait=$((bomb_wait - 1))
  [ $bomb_wait -gt 0 ] && return
  [ -z "$invaders" ] && return
  set -- $bombs
  [ $# -ge 3 ] && return

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
  f="${ESC}[?2026h${ESC}[H${ESC}[2J"
  [ $bell -eq 1 ] && { f="$f$BEL"; bell=0; }

  # Lives are shown in reverse video while the ship explodes
  lives_txt="Lives: $lives"
  [ $boom -gt 0 ] && lives_txt="${ESC}[7m$lives_txt${ESC}[0m"
  f="${f}Score: $score  $lives_txt  |  Move: h/l or arrows  Fire: SPACE  Quit: q"

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

  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    f="$f${ESC}[$1;$2H$3"
  done

  for b in $bullets; do
    f="$f${ESC}[${b%:*};${b#*:}H!"
  done

  for m in $bombs; do
    f="$f${ESC}[${m%:*};${m#*:}H|"
  done

  if [ $game_over -eq 1 ]; then
    f="$f${ESC}[$((rows / 2 - 1));$((cols / 2 - 8))H=== GAME OVER ==="
    f="$f${ESC}[$((rows / 2));$((cols / 2 - 5))HScore: $score"
    f="$f${ESC}[$((rows / 2 + 1));$((cols / 2 - 8))HPress 'q' to quit"
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

    if [ $boom -gt 0 ]; then
      boom=$((boom - 1))
    elif [ $game_over -eq 0 ]; then
      if [ $move -lt 0 ] && [ $ship_col -gt 1 ]; then
        ship_col=$((ship_col - 1))
      elif [ $move -gt 0 ] && [ $ship_col -lt $((cols - 6)) ]; then
        ship_col=$((ship_col + 1))
      fi
      # One shot on screen at a time, as in the arcade
      [ $fire -eq 1 ] && [ -z "$bullets" ] &&
        bullets="$((ship_row - 1)):$((ship_col + 1))"

      move_bullets
      check_collisions
      if move_invaders; then
        # Re-check so bullets can't slip past invaders that just dropped
        check_collisions
        [ $landed -eq 1 ] && lose_life
      fi
      if [ $game_over -eq 0 ]; then
        move_bombs
        drop_bomb
        check_bombs
      fi
      [ -z "$invaders" ] && spawn_wave
    fi

    draw
    # Aim for ~50 fps. Frame work is <1ms; the rest is the cost of starting
    # sleep itself (~6-10ms on macOS), so the delay is set below 0.02.
    sleep 0.012
  done

  cleanup
}

main
