#!/usr/bin/env sh
# Space Invaders clone in POSIX shell
# Use monospaced Unicode for invaders, '!' for bullets
# Ship: looks cool with Unicode chars

set -u

# Terminal control
cleanup() {
  tput cnorm 2>/dev/null || true
  tput rmcup 2>/dev/null || true
  stty echo icanon 2>/dev/null || stty sane 2>/dev/null || true
  [ -n "${input_pid:-}" ] && kill $input_pid 2>/dev/null
  [ -n "${tmpfile:-}" ] && rm -f "$tmpfile" 2>/dev/null
  echo
  exit 0
}

trap cleanup INT TERM HUP

# Initialize
init() {
  # Get terminal size
  rows=$(tput lines)
  cols=$(tput cols)
  
  # Game state
  # Ship position
  ship_row=$((rows - 2))
  ship_col=$((cols / 2 - 2))
  
  # Bullets: format "row:col"
  bullets=""
  
  # Invaders: format "row:col:alive" (alive=1)
  invaders=""
  # Create invader grid
  inv_start_row=2
  inv_start_col=5
  inv_rows=4
  inv_cols=8
  inv_dir=1  # moving right
  inv_speed_count=0
  inv_drop=0
  
  # Fill invader formation
  r=0
  while [ $r -lt $inv_rows ]; do
    c=0
    while [ $c -lt $inv_cols ]; do
      ir=$((inv_start_row + r))
      ic=$((inv_start_col + c * 4))
      if [ $r -eq 0 ]; then
        sprite="👾"
      elif [ $r -eq 1 ]; then
        sprite="👽"
      elif [ $r -eq 2 ]; then
        sprite="🤖"
      else
        sprite="👹"
      fi
      invaders="$invaders $ir:$ic:1:$sprite"
      c=$((c + 1))
    done
    r=$((r + 1))
  done
  
  score=0
  lives=3
  game_over=0
  quit=0
  
  # Setup terminal
  stty -icanon -echo
  tput civis 2>/dev/null || true
  tput smcup 2>/dev/null || true
  tput clear 2>/dev/null || true
}

draw() {
  # Use a temporary file for double buffering
  frame=$(mktemp 2>/dev/null || echo "/tmp/frame$$")
  
  # Clear buffer with spaces (simple approach: just start fresh by writing to frame)
  # Easier: write the whole thing at once
  {
    # Move to home
    printf '\033[H'
    # Draw score and lives
    printf "Score: %d  Lives: %d  |  Move: h/l or arrows  Fire: SPACE  Quit: q" $score $lives
    printf '\n'
    
    # Create a 2D buffer representation? Or just draw row by row
    # Simpler: build line by line for each row
  } > "$frame"
  
  # Better approach: write everything at once
  {
    printf '\033[H'
    printf "Score: %d  Lives: %d  |  Move: h/l or arrows  Fire: SPACE  Quit: q\n" $score $lives
    
    # We need to draw at specific positions; easier to use cursor moves in buffer
    # But to avoid flicker, collect all cursor positions and chars
    # For this simple game, redraw minimal way
    printf '\033[%d;%dH◢◣' $((ship_row + 1)) $((ship_col + 1))  # note: tput uses 1-based in some terms, but we're mixing; better be careful
    printf '\033[%d;%dH▲' $ship_row $((ship_col + 2))  # adjust
  } > "$frame.tmp"
  
  # Use a cleaner buffered draw
  : > "$frame"
  # Clear and write HUD
  printf '\033[2J\033[0;0HScore: %d  Lives: %d  |  Move: h/l or arrows  Fire: SPACE  Quit: q' $score $lives >> "$frame"

  # Draw ship (with proper positioning)
  printf '\033[%d;%dH◢ ◣' $ship_row $ship_col >> "$frame"
  printf '\033[%d;%dH▲' $((ship_row - 1)) $((ship_col + 1)) >> "$frame"
  
  # Draw invaders
  invaders_tmp="$invaders"
  for inv in $invaders_tmp; do
    IFS=:
    set -- $inv
    ir=$1; ic=$2; alive=$3; isprite=$4
    unset IFS
    if [ "$alive" = "1" ]; then
      if [ $ir -ge 0 ] && [ $ir -lt $rows ] && [ $ic -ge 0 ] && [ $ic -lt $cols ]; then
        printf '\033[%d;%dH%s' $ir $ic "$isprite" >> "$frame"
      fi
    fi
  done
  
  # Draw bullets
  bullets_tmp="$bullets"
  for b in $bullets_tmp; do
    IFS=:
    set -- $b
    br=$1; bc=$2
    unset IFS
    if [ $br -ge 0 ] && [ $br -lt $rows ] && [ $bc -ge 0 ] && [ $bc -lt $cols ]; then
      printf '\033[%d;%dH!' $br $bc >> "$frame"
    fi
  done
  
  # Game over screen
  if [ $game_over -eq 1 ]; then
    printf '\033[%d;%dH=== GAME OVER ===' $((rows / 2 - 1)) $((cols / 2 - 10)) >> "$frame"
    printf '\033[%d;%dHScore: %d' $((rows / 2)) $((cols / 2 - 8)) $score >> "$frame"
    printf '\033[%d;%dHPress '\''q'\'' to quit' $((rows / 2 + 1)) $((cols / 2 - 12)) >> "$frame"
  fi
  
  # Output the entire frame at once
  cat "$frame"
  rm -f "$frame"
}

move_bullets() {
  new_bullets=""
  bullets_tmp="$bullets"
  for b in $bullets_tmp; do
    IFS=:
    set -- $b
    br=$1; bc=$2
    unset IFS
    br_new=$((br - 1))
    if [ $br_new -gt 0 ]; then
      new_bullets="$new_bullets $br_new:$bc"
    fi
  done
  bullets="$new_bullets"
}

check_collisions() {
  new_invaders=""
  invaders_tmp="$invaders"
  for inv in $invaders_tmp; do
    IFS=:
    set -- $inv
    ir=$1; ic=$2; alive=$3; isprite=$4
    unset IFS
    if [ "$alive" = "1" ]; then
      # Check collision with bullets
      hit=0
      new_bullets=""
      bullets_tmp="$bullets"
      for b in $bullets_tmp; do
        IFS=:
        set -- $b
        br=$1; bc=$2
        unset IFS
        # Simple collision: bullet hits invader (approximate)
        if [ $br -eq $ir ] && [ $bc -ge $ic ] && [ $bc -lt $((ic + 2)) ]; then
          hit=1
          score=$((score + 10))
        else
          new_bullets="$new_bullets $br:$bc"
        fi
      done
      bullets="$new_bullets"
      if [ $hit -eq 0 ]; then
        new_invaders="$new_invaders $ir:$ic:$alive:$isprite"
      fi
    fi
  done
  invaders="$new_invaders"
}

move_invaders() {
  inv_speed_count=$((inv_speed_count + 1))
  # Move slower
  if [ $inv_speed_count -lt 3 ]; then
    return
  fi
  inv_speed_count=0
  
  new_invaders=""
  invaders_tmp="$invaders"
  max_col=0
  min_col=$cols
  max_row=0
  for inv in $invaders_tmp; do
    IFS=:
    set -- $inv
    ir=$1; ic=$2; alive=$3; isprite=$4
    unset IFS
    if [ "$alive" = "1" ]; then
      if [ $ic -gt $max_col ]; then max_col=$ic; fi
      if [ $ic -lt $min_col ]; then min_col=$ic; fi
      if [ $ir -gt $max_row ]; then max_row=$ir; fi
    fi
  done
  
  # Check if need to drop and change direction
  if [ $max_col -ge $((cols - 4)) ] && [ $inv_dir -eq 1 ]; then
    inv_dir=-1
    inv_drop=1
  elif [ $min_col -le 2 ] && [ $inv_dir -eq -1 ]; then
    inv_dir=1
    inv_drop=1
  fi
  
  # Move
  for inv in $invaders_tmp; do
    IFS=:
    set -- $inv
    ir=$1; ic=$2; alive=$3; isprite=$4
    unset IFS
    if [ "$alive" = "1" ]; then
      if [ $inv_drop -eq 1 ]; then
        ir_new=$((ir + 1))
      else
        ir_new=$ir
      fi
      ic_new=$((ic + inv_dir))
      # Check if invaders reached ship
      if [ $ir_new -ge $((ship_row - 1)) ]; then
        game_over=1
      fi
      new_invaders="$new_invaders $ir_new:$ic_new:$alive:$isprite"
    fi
  done
  invaders="$new_invaders"
  inv_drop=0
  
  # Check if no invaders left
  if [ -z "$new_invaders" ]; then
    # Win - restart
    init
    return
  fi
}

fire() {
  # Add bullet at ship position
  bullets="$bullets $((ship_row - 1)):$((ship_col + 1))"
}

# Main game loop
main() {
  init
  
  tmpfile=$(mktemp /tmp/si_XXXXXX)
  echo "" > "$tmpfile"

  (
    while true; do
      key_char=$(dd bs=1 count=1 2>/dev/null < /dev/tty)
      if [ -z "$key_char" ]; then
        continue
      fi
      if [ "$key_char" = "$(printf '\033')" ]; then
        seq=$(dd bs=1 count=2 2>/dev/null < /dev/tty)
        printf "%s%s\n" "$key_char" "$seq" > "$tmpfile"
      else
        printf "%s\n" "$key_char" > "$tmpfile"
      fi
    done
  ) &
  input_pid=$!

  while [ $quit -eq 0 ]; do
    # Read all pending keys
    if [ -s "$tmpfile" ]; then
      key_buffer=$(cat "$tmpfile")
      echo "" > "$tmpfile"
      key_cmds=$(mktemp 2>/dev/null || echo "/tmp/keys$$")
      echo "move_left=0" > "$key_cmds"
      echo "move_right=0" >> "$key_cmds"
      printf "%s" "$key_buffer" | while IFS= read -r key_line || [ -n "$key_line" ]; do
        [ -z "$key_line" ] && continue
        key_char=$(printf "%s" "$key_line" | cut -c1-1)
        if [ "$key_char" = "$(printf '\033')" ]; then
          seq=$(printf "%s" "$key_line" | cut -c2-3)
          case "$seq" in
            '[D')
              echo "move_left=1" >> "$key_cmds" ;;
            '[C')
              echo "move_right=1" >> "$key_cmds" ;;
            '[A'|'[B')
              if [ $game_over -eq 0 ]; then echo "fire" >> "$key_cmds"; fi ;;
          esac
        else
          case "$key_char" in
            q|Q)
              echo "quit=1" >> "$key_cmds" ;;
            h|H|a|A|j|J)
              echo "move_left=1" >> "$key_cmds" ;;
            l|L|d|D|k|K)
              echo "move_right=1" >> "$key_cmds" ;;
            ' ')
              if [ $game_over -eq 0 ]; then echo "fire" >> "$key_cmds"; fi ;;
            *)
              if [ $game_over -eq 0 ]; then echo "fire" >> "$key_cmds"; fi ;;
          esac
        fi
      done
      # Source the commands
      . "$key_cmds" 2>/dev/null
      rm -f "$key_cmds"
      if [ $game_over -eq 0 ]; then
        if [ $move_left -eq 1 ] && [ $move_right -eq 0 ] && [ $ship_col -gt 1 ]; then
          ship_col=$((ship_col - 1))
        elif [ $move_right -eq 1 ] && [ $move_left -eq 0 ] && [ $ship_col -lt $((cols - 6)) ]; then
          ship_col=$((ship_col + 1))
        fi
      fi
    fi
    
    if [ $game_over -eq 0 ]; then
      move_bullets
      move_invaders
      check_collisions
    fi
    
    draw
    
    sleep 0.01
  done
  
  cleanup
}

main
