#!/usr/bin/env sh
# Space Invaders clone in POSIX shell
# Emoji invaders, '!' for bullets, Unicode ship.

set -u
set -f  # no globbing when splitting state strings

ESC=$(printf '\033')

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
  inv_delay=3  # invaders move once every N frames

  score=0
  lives=3
  game_over=0
  quit=0
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
#   bullets:  space-separated "row:col"
# ---------------------------------------------------------------------------

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
  bullets=""
  inv_dir=1
  inv_tick=0
}

lose_life() {
  lives=$((lives - 1))
  if [ $lives -le 0 ]; then
    game_over=1
  else
    spawn_wave
  fi
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
  inv_tick=$((inv_tick + 1))
  [ $inv_tick -lt $inv_delay ] && return 1
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

# ---------------------------------------------------------------------------
# Rendering: build the whole frame in a string, then emit it in one go
# (wrapped in synchronized-output escapes where the terminal supports them).
# ---------------------------------------------------------------------------

draw() {
  f="${ESC}[?2026h${ESC}[H${ESC}[2J"
  f="${f}Score: $score  Lives: $lives  |  Move: h/l or arrows  Fire: SPACE  Quit: q"

  f="$f${ESC}[$((ship_row - 1));$((ship_col + 1))H▲"
  f="$f${ESC}[$ship_row;${ship_col}H◢ ◣"

  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    f="$f${ESC}[$1;$2H$3"
  done

  for b in $bullets; do
    f="$f${ESC}[${b%:*};${b#*:}H!"
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

    if [ $game_over -eq 0 ]; then
      if [ $move -lt 0 ] && [ $ship_col -gt 1 ]; then
        ship_col=$((ship_col - 1))
      elif [ $move -gt 0 ] && [ $ship_col -lt $((cols - 6)) ]; then
        ship_col=$((ship_col + 1))
      fi
      [ $fire -eq 1 ] && bullets="$bullets $((ship_row - 1)):$((ship_col + 1))"

      move_bullets
      check_collisions
      if move_invaders; then
        # Re-check so bullets can't slip past invaders that just dropped
        check_collisions
        [ $landed -eq 1 ] && lose_life
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
