#!/bin/sh
# #!/bin/sh INVADERS: a Space Invaders clone in POSIX shell
# Emoji invaders, '¡' for bullets, Unicode ship.
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

# tput is part of ncurses, which minimal systems may lack: fall back to the
# standard escape sequences for showing/hiding the cursor and switching to
# and from the alternate screen.
cleanup() {
  trap - INT TERM HUP
  tput cnorm 2>/dev/null || printf '%s' "${ESC}[?25h"
  tput rmcup 2>/dev/null || printf '%s' "${ESC}[?1049l"
  if [ -n "${old_stty:-}" ]; then
    stty "$old_stty" 2>/dev/null || stty sane 2>/dev/null || true
  fi
  exit 0
}

# Sets $rows and $cols to the terminal size, from tput or else stty.
term_size() {
  rows=$(tput lines 2>/dev/null) || rows=""
  cols=$(tput cols 2>/dev/null) || cols=""
  case "$rows$cols" in
    ''|*[!0-9]*)
      set -- $(stty size 2>/dev/null)
      rows=${1:-}; cols=${2:-} ;;
  esac
  case "$rows$cols" in
    ''|*[!0-9]*)
      echo "Can't determine the terminal size (no tput or stty size)." >&2
      exit 1 ;;
  esac
}

# The game draws emoji and box/block symbols, which need a UTF-8 locale.
# Warn (rather than draw garbage) if the locale doesn't look like UTF-8.
check_locale() {
  loc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  case $loc in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return ;;
  esac
  echo "Your locale (${loc:-unset}) isn't UTF-8, so the game's emoji and" >&2
  echo "symbols may not display correctly. Try: LANG=en_US.UTF-8 $0" >&2
  printf 'Press Enter to play anyway, or Ctrl-C to quit. ' >&2
  read -r _ || exit 1
}

# Sets $row to the terminal row for arcade height $1 (pixels from the bottom
# of the 256-pixel-tall arcade screen).
y2row() {
  row=$((y0 + field_h - ($1 * field_h + 128) / 256))
}

init() {
  term_size
  if [ $cols -lt $((field_w + 2)) ] || [ $rows -lt 24 ]; then
    echo "Terminal is ${cols}x${rows}; at least $((field_w + 2))x24 is needed." >&2
    exit 1
  fi
  check_locale

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
  # The flying saucer crosses at Y=208. Its timer only runs once the
  # formation is below the first wave's starting height (Y=120).
  # It is drawn " ◜◝ " underlined: a dome over a flat body, in red like the
  # arcade's overlay, 4 columns wide like the arcade's 16 pixels.
  y2row 208; saucer_row=$row
  saucer_w=4
  [ $saucer_row -lt $top_row ] && saucer_row=$top_row
  y2row 120; rack_start_row=$row

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
  go_letter=6  # frames per letter of "GAME OVER" (the arcade waits 7 ticks)
  load_hiscore
  new_game     # sets up a game (so the score line has something to show) ...
  mode=title   # ... but start on the title screen, like the arcade
  title_t=0

  # Non-blocking, unechoed, unbuffered input: reads return immediately
  old_stty=$(stty -g)
  stty -icanon -echo min 0 time 0
  tput civis 2>/dev/null || printf '%s' "${ESC}[?25l"
  tput smcup 2>/dev/null || printf '%s' "${ESC}[?1049h"

  # Frame pacing (see pace)
  target_us=19231   # 52 fps: the rate the game's timings are converted to
  delay_us=12000    # initial sleep per frame, adjusted as the game runs
  pace_frames=0
  pace_check=0
  pace_sec=""       # second at which the current measurement started
  pace_seen=$(date +%s 2>/dev/null) || pace_seen=""
  case $pace_seen in
    ''|*[!0-9]*) pace_seen="" ;;   # no usable clock: keep the initial delay
  esac
}

# ---------------------------------------------------------------------------
# Game state
#   invaders: space-separated "row:col:sprite"
#   bullets:  the player's shot, "row:col" (at most one, as in the arcade)
#   bombs:    space-separated "row:col:type" invader shots, at most one of
#             each type: r (aimed "rolling"), p ("plunger"), s ("squiggly")
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
    IFS=:
    set -- $m
    unset IFS
    hit_shield $1 $2 && continue
    remaining="$remaining $m"
  done
  bombs=$remaining
}

# Sets $reload: how long (in frames) every falling invader shot must have
# been falling before another may be fired. The arcade's table at 1AA1, by
# score: 48/16/11/8/7 shot steps of 3 frames at 60 Hz, converted to ~52 fps.
reload_bombs() {
  if [ $score -lt 200 ]; then reload=125
  elif [ $score -lt 1000 ]; then reload=42
  elif [ $score -lt 2000 ]; then reload=29
  elif [ $score -lt 3000 ]; then reload=21
  else reload=18
  fi
}

# The arcade's column-firing table (1D00), columns numbered 1-11 from the
# left. The plunger shot cycles through entries 0-15, the squiggly shot
# through entries 6-20. Sets $col to entry $1.
col_fire_table() {
  set -- $(($1 + 1)) 1 7 1 1 1 4 11 1 6 3 1 1 11 9 2 8 2 11 4 7 10
  shift $1
  col=$1
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
  shot_turn=0
  rack_x=$inv_start_col  # screen column of the formation's column 1
  rack_y=$bottom         # screen row of the formation's bottom row
  saucer_x=0             # no saucer on screen
  saucer_hit=0
  inv_dir=1
  inv_tick=0
}

# Starts a new game (at launch, and on 'r' after game over).
new_game() {
  mode=play
  score=0
  lives=3
  wave=1
  game_over=0
  boom=0   # frames left of the ship's explosion (game is paused meanwhile)
  bell=0   # ring the terminal bell on the next draw
  ship_col=$((left + field_w / 2 - 2))
  shots=0               # player shots fired (sets saucer direction and score)
  saucer_timer=1331     # 1536 frames at 60 Hz between saucers
  saucer_pending=0
  plu_idx=0      # positions in the column-firing table
  squ_idx=6
  fire_delay=42  # invaders hold fire for 48 counts at 60 Hz at the start
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
  fire_delay=42  # as at the start, the invaders hold fire for a while
  [ $lives -le 0 ] && end_game
}

# Invaders reached the bottom: as in the arcade, the ship is destroyed and
# the game ends, however many lives are left.
invaded() {
  player_hit
  lives=0
  end_game
}

# The game has ended. As in the arcade, the high score is updated at once;
# "GAME OVER" is then typed out (once the explosion is over), followed by a
# pause and the title screen. Not doing it twice matters when invaders land
# on the last life.
end_game() {
  [ $game_over -eq 1 ] && return
  game_over=1
  go_t=0
  if [ $score -gt $hi ]; then
    hi=$score
    save_hiscore
  fi
}

# The high score is kept in a file in the home directory. Reading and
# writing use only shell built-ins; failures (no HOME, read-only home) are
# ignored and just mean the high score isn't kept.
load_hiscore() {
  hi=0
  hi_file=""
  [ -n "${HOME:-}" ] && hi_file="$HOME/.space_invaders_hiscore"
  [ -n "$hi_file" ] && [ -r "$hi_file" ] || return
  { read -r hi < "$hi_file"; } 2>/dev/null || hi=0
  case $hi in
    ''|*[!0-9]*) hi=0 ;;
  esac
}

save_hiscore() {
  [ -n "$hi_file" ] || return
  { printf '%s\n' "$hi" > "$hi_file"; } 2>/dev/null || true
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
  rack_x=$((rack_x + inv_dir))
  rack_y=$((rack_y + drop))
  return 0
}

# Invader shots fall one row every $bomb_period_slow frames, or every
# $bomb_period_fast frames once 8 or fewer invaders are left. Each shot also
# counts its age in frames (the arcade's step count, used for reloading).
move_bombs() {
  [ -z "$bombs" ] && return
  bomb_tick=$((bomb_tick + 1))
  period=$bomb_period_slow
  [ $inv_count -le 8 ] && period=$bomb_period_fast
  step=0
  if [ $bomb_tick -ge $period ]; then
    step=1
    bomb_tick=0
  fi
  moved=""
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    mr=$(($1 + step))
    [ $mr -lt $ground_row ] && moved="$moved $mr:$2:$3:$(($4 + 1))"
  done
  bombs=$moved
}

# Invader firing, following the arcade's code (0476-0643). There are three
# shot types, at most one of each in flight, and each gets a chance to fire
# on its own frame in turn:
#   r  "rolling":  from the column directly over the player
#   p  "plunger":  from columns in the table's order; disabled when one
#                  invader is left
#   s  "squiggly": from columns in the table's order; survives meeting the
#                  player's shot
# A shot may only be fired if every shot already falling has been falling
# for longer than $reload. It comes from the lowest invader in its column;
# if that column has none left, no shot is fired (but the table still
# advances).
drop_bomb() {
  if [ $fire_delay -gt 0 ]; then
    fire_delay=$((fire_delay - 1))
    return
  fi
  [ -z "$invaders" ] && return

  shot_turn=$(( (shot_turn + 1) % 3 ))
  case $shot_turn in
    0) bt=r ;;
    1) bt=p ;;
    *) bt=s ;;
  esac
  [ $bt = p ] && [ $inv_count -eq 1 ] && return
  # The saucer uses the squiggly shot's slot in the arcade
  [ $bt = s ] && [ $saucer_x -ne 0 ] && return

  reload_bombs
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    [ $3 = $bt ] && return          # this type is already in flight
    [ $4 -le $reload ] && return    # another shot was fired too recently
  done

  case $bt in
    r)
      # Formation column (1-11) over the player's centre, clamped to the
      # formation (the arcade uses column 11 when the player is beyond it)
      x=$((ship_col + 1 - rack_x))
      if [ $x -lt 0 ]; then col=1; else col=$((x / 4 + 1)); fi
      [ $col -gt 11 ] && col=11 ;;
    p)
      col_fire_table $plu_idx
      plu_idx=$((plu_idx + 1))
      [ $plu_idx -gt 15 ] && plu_idx=0 ;;
    s)
      col_fire_table $squ_idx
      squ_idx=$((squ_idx + 1))
      [ $squ_idx -gt 20 ] && squ_idx=6 ;;
  esac

  # Lowest live invader in that column
  colx=$((rack_x + (col - 1) * 4))
  sr=0
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    [ $2 -eq $colx ] && [ $1 -gt $sr ] && sr=$1
  done
  [ $sr -eq 0 ] && return

  # Sprites are two columns wide; the rolling shot falls from whichever
  # half is nearer the player, the others from the left half
  sc=$colx
  [ $bt = r ] && [ $((ship_col + 1)) -gt $colx ] && sc=$((colx + 1))
  bombs="$bombs $((sr + 1)):$sc:$bt:0"
}

# Handles invader shots hitting the ship or meeting the player's shot. As in
# the arcade, when the two shots meet the player's is destroyed, and so is
# the invader's unless it is the squiggly shot.
check_bombs() {
  shot=0
  remaining=""
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    mr=$1; mc=$2; mt=$3
    # The cannon is one row of 3 cells, like the arcade's 13x8-pixel sprite
    if [ $mr -eq $ship_row ] &&
       [ $mc -ge $ship_col ] && [ $mc -le $((ship_col + 2)) ]; then
      shot=1
      continue
    fi
    met=0
    for b in $bullets; do
      # The shots move toward each other, so they can pass between frames
      br=${b%:*}
      if [ ${b#*:} -eq $mc ] && [ $br -ge $((mr - 1)) ] && [ $br -le $mr ]; then
        met=1
      fi
    done
    if [ $met -eq 1 ]; then
      bullets=""
      [ "$mt" != s ] && continue
    fi
    remaining="$remaining $m"
  done
  bombs=$remaining
  [ $shot -eq 1 ] && player_hit
}

# ---------------------------------------------------------------------------
# Flying saucer, following the arcade's code (0447-0475, 0682-0739, 0913)
# ---------------------------------------------------------------------------

# Sets $saucer_pts from the arcade's saucer score table (1D54), indexed by
# the number of shots fired. The arcade's index wraps after 15 entries (a
# bug: the table has 16), so 300 points come with shots 8, 23, 38, ...
saucer_points() {
  set -- $((shots % 15 + 1)) 10 5 5 10 15 10 10 5 30 10 10 10 5 15 10
  shift $1
  saucer_pts=$(($1 * 10))
}

# Starts, moves and retires the saucer.
#  - A saucer is due every 1536 frames at 60 Hz, counted only once the
#    formation is below the first wave's starting height.
#  - It sets off when due, with 8 or more invaders left and no squiggly shot
#    falling (it shares the squiggly shot's slot).
#  - An odd number of shots fired sends it left to right, even right to left.
#  - It moves about 40 pixels a second (a column every 5 frames).
update_saucer() {
  if [ $rack_y -gt $rack_start_row ]; then
    saucer_timer=$((saucer_timer - 1))
    if [ $saucer_timer -le 0 ]; then
      saucer_timer=1331
      saucer_pending=1
    fi
  fi

  # Hit: explosion, then the score in its place; points added as it shows
  if [ $saucer_hit -gt 0 ]; then
    saucer_hit=$((saucer_hit - 1))
    [ $saucer_hit -eq 62 ] && score=$((score + saucer_pts))
    if [ $saucer_hit -eq 0 ]; then
      saucer_x=0
      saucer_pending=0
    fi
    return
  fi

  if [ $saucer_x -eq 0 ]; then
    [ $saucer_pending -eq 1 ] && [ $inv_count -ge 8 ] || return
    case $bombs in
      *:s:*) return ;;
    esac
    if [ $((shots % 2)) -eq 1 ]; then
      saucer_x=$left; saucer_dir=1
    else
      saucer_x=$((right - saucer_w + 1)); saucer_dir=-1
    fi
    saucer_tick=0
    return
  fi

  saucer_tick=$((saucer_tick + 1))
  [ $saucer_tick -lt 5 ] && return
  saucer_tick=0
  saucer_x=$((saucer_x + saucer_dir))
  if [ $saucer_x -lt $left ] || [ $((saucer_x + saucer_w - 1)) -gt $right ]; then
    saucer_x=0
    saucer_pending=0
  fi
}

# The player's shot hitting the saucer (any of its $saucer_w columns).
check_saucer() {
  [ $saucer_x -eq 0 ] && return
  [ $saucer_hit -gt 0 ] && return
  for b in $bullets; do
    bc=${b#*:}
    if [ ${b%:*} -eq $saucer_row ] && [ $bc -ge $saucer_x ] &&
       [ $bc -le $((saucer_x + saucer_w - 1)) ]; then
      bullets=""
      saucer_points
      saucer_hit=83   # 32 ticks of 3 frames at 60 Hz
    fi
  done
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
  f="$f${ESC}[$hud_row;${left}HScore: $score  Hi-Score: $hi  $lives_txt  Wave: $wave"

  if [ $mode = title ]; then
    draw_title
    printf '%s' "$f${ESC}[?2026l"
    return
  fi

  if [ $boom -gt 0 ]; then
    # Two-frame explosion, alternating every 4 frames like the arcade's
    if [ $((boom / 4 % 2)) -eq 0 ]; then
      f="$f${ESC}[$ship_row;${ship_col}H\\|/"
    else
      f="$f${ESC}[$ship_row;${ship_col}H*.*"
    fi
  elif [ $game_over -eq 0 ]; then   # the last cannon stays destroyed
    # One row, like the arcade's: sloping shoulders with a solid point.
    # These characters are in SF Mono (Terminal.app's default font), so
    # nothing is borrowed from another font.
    f="$f${ESC}[$ship_row;${ship_col}H╱▲╲"
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

  # The saucer, or once hit its explosion and then its score (in red, like
  # the arcade's top screen overlay)
  if [ $saucer_x -ne 0 ]; then
    if [ $saucer_hit -eq 0 ]; then
      f="$f${ESC}[$saucer_row;${saucer_x}H${ESC}[31;4m ◜◝ ${ESC}[0m"
    else
      if [ $saucer_hit -gt 62 ]; then txt='<*>'; else txt=$saucer_pts; fi
      tx=$saucer_x
      [ $((tx + ${#txt} - 1)) -gt $right ] && tx=$((right - ${#txt} + 1))
      f="$f${ESC}[$saucer_row;${tx}H${ESC}[31m$txt${ESC}[0m"
    fi
  fi

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
    f="$f${ESC}[${b%:*};${b#*:}H¡"   # dot first, as it leaves the cannon
  done

  # Invader shots animate as they fall, frame chosen by row, after the
  # arcade's shot sprites:
  #   rolling   { | } |   a spike circling the shaft
  #   plunger   ┬ ┼ ┴ ┼   a crossbar sliding along the shaft
  #   squiggly  \ /       a zig-zag
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    case $3 in
      r)
        case $(($1 % 4)) in
          0) g='{' ;;
          2) g='}' ;;
          *) g='|' ;;
        esac ;;
      p)
        case $(($1 % 4)) in
          0) g='┬' ;;
          2) g='┴' ;;
          *) g='┼' ;;
        esac ;;
      *)
        if [ $(($1 % 2)) -eq 0 ]; then g='\'; else g='/'; fi ;;
    esac
    f="$f${ESC}[$1;$2H$g"
  done

  # "GAME OVER" typed out near the top over the frozen invaders, as in the
  # arcade, once the explosion has finished
  if [ $game_over -eq 1 ] && [ $boom -eq 0 ]; then
    arcade_text "GAME OVER" $((go_t / go_letter))
    f="$f${ESC}[$((top_row + 1));$((left + field_w / 2 - 8))H$sp"
  fi

  printf '%s' "$f${ESC}[?2026l"
}

# Sets $pre to the first $2 characters of $1 (ASCII text) without a
# subshell, by stripping a pattern of $2 '?' wildcards.
prefix() {
  if [ $2 -ge ${#1} ]; then
    pre=$1
    return
  fi
  q=""
  i=0
  while [ $i -lt $2 ]; do q="$q?"; i=$((i + 1)); done
  rest=${1#$q}
  pre=${1%"$rest"}
}

# Sets $sp to the first $2 characters of $1, letter-spaced to the arcade's
# character width: its letters are 8 pixels wide, 2 columns at this scale,
# so each character is followed by a space (a space becomes two). The first
# $3 characters (default 0) are left unspaced. A text of n characters with
# p unspaced is p + 2(n-p) - 1 columns wide.
arcade_text() {
  prefix "$1" $2
  s=$pre
  prefix "$s" ${3:-0}
  sp=$pre
  s=${s#"$pre"}
  while [ -n "$s" ]; do
    s_rest=${s#?}
    sp="$sp${s%"$s_rest"} "
    s=$s_rest
  done
  sp=${sp% }
}

# Adds the title screen to the frame, after the arcade's attract screen:
# "PLAY #!/bin/sh INVADERS" and the score advance table, typed out a letter at
# a time ($title_t counts frames since it appeared). The arcade's "INSERT
# COIN" becomes the keys to press, shown straight away.
draw_title() {
  mid_c=$((left + field_w / 2))
  # Centre the 17 rows of text between the score line and the ground
  avail=$((ground_row - top_row - 1))
  r0=$((top_row + 1 + (avail - 17) / 2))
  [ $r0 -le $top_row ] && r0=$((top_row + 1))

  # Each line: row offset, column ("c" to centre), icon (drawn when typing
  # reaches the line), number of leading characters to leave unspaced, text.
  # "|" separates fields; icons use "-" for none. Text is letter-spaced to
  # the arcade's character width, except "#!/bin/sh" in the game's name.
  tx=$((mid_c - 7))   # table text column, leaving room for the icons
  set -- \
    "0|c|-|0|PLAY" \
    "2|c|-|9|#!/bin/sh INVADERS" \
    "5|c|-|0|*SCORE ADVANCE TABLE*" \
    "7|$tx|S|0|= ? MYSTERY" \
    "9|$tx|👾|0|= 30 POINTS" \
    "11|$tx|🦀|0|= 20 POINTS" \
    "13|$tx|🐙|0|= 10 POINTS"
  # Typing advances a column per frame (a spaced letter every 2 frames, an
  # unspaced one every frame), so the text grows across the screen at a
  # steady pace, as in the arcade where all letters are the same width.
  left_cols=$title_t
  for line in "$@"; do
    [ $left_cols -le 0 ] && break
    lr=$((r0 + ${line%%|*})); rest=${line#*|}
    lc=${rest%%|*}; rest=${rest#*|}
    icon=${rest%%|*}; rest=${rest#*|}
    plain=${rest%%|*}; text=${rest#*|}
    width=$((plain + 2 * (${#text} - plain) - 1))
    [ "$lc" = c ] && lc=$((mid_c - width / 2))
    case $icon in
      S) f="$f${ESC}[$lr;$((lc - 6))H${ESC}[31;4m ◜◝ ${ESC}[0m" ;;
      -) ;;
      *) f="$f${ESC}[$lr;$((lc - 4))H$icon" ;;
    esac
    # Letters shown so far: unspaced ones take 1 column, spaced ones 2
    if [ $left_cols -le $plain ]; then
      n=$left_cols
    else
      n=$((plain + (left_cols - plain + 1) / 2))
    fi
    arcade_text "$text" $n $plain
    f="$f${ESC}[$lr;${lc}H$sp"
    left_cols=$((left_cols - plain - 2 * (${#text} - plain)))
  done

  arcade_text "PRESS R TO PLAY, Q TO QUIT" 99
  f="$f${ESC}[$((r0 + 16));$((mid_c - 25))H$sp"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

# Sleeps between frames, keeping the game at ~52 fps on any machine. Most of
# a frame is the sleep, and a sleep takes longer than requested: measured on
# a Mac running macOS 27, ~1.6ms to start the sleep program plus ~3-4ms of
# oversleep. Other systems will differ, so the actual frame rate is measured
# and the delay adjusted to suit. POSIX sh has no sub-second clock, so the
# rate is measured over 2-second windows that start and end on second
# boundaries (date +%s, checked every 4th frame).
pace() {
  if [ -n "$pace_seen" ]; then
    pace_frames=$((pace_frames + 1))
    pace_check=$((pace_check + 1))
    if [ $pace_check -ge 4 ]; then
      pace_check=0
      now=$(date +%s)
      if [ "$now" != "$pace_seen" ]; then
        pace_seen=$now
        if [ -z "$pace_sec" ]; then
          pace_sec=$now        # first second boundary: start measuring
          pace_frames=0
        elif [ $((now - pace_sec)) -ge 2 ]; then
          frame_us=$(( (now - pace_sec) * 1000000 / pace_frames ))
          # Correct half the error each time, so noise doesn't make it hunt
          delay_us=$((delay_us - (frame_us - target_us) / 2))
          [ $delay_us -lt 0 ] && delay_us=0
          [ $delay_us -gt 40000 ] && delay_us=40000
          pace_sec=$now
          pace_frames=0
        fi
      fi
    fi
  fi
  # Format microseconds as 0.dddddd without a subshell (delay is < 1s)
  d=$((delay_us + 1000000))
  sleep "0.${d#1}"
}

main() {
  init

  while [ $quit -eq 0 ]; do
    read_input

    if [ $mode = title ]; then
      title_t=$((title_t + 1))
      [ $restart -eq 1 ] && new_game
    elif [ $game_over -eq 1 ] && [ $restart -eq 1 ]; then
      new_game
    elif [ $boom -gt 0 ]; then
      boom=$((boom - 1))
    elif [ $game_over -eq 1 ]; then
      # Type "GAME OVER", pause two seconds, then the title screen
      go_t=$((go_t + 1))
      if [ $go_t -ge $((9 * go_letter + 104)) ]; then
        mode=title
        title_t=0
      fi
    else
      if [ $move -lt 0 ] && [ $ship_col -gt $left ]; then
        ship_col=$((ship_col - 1))
      elif [ $move -gt 0 ] && [ $((ship_col + 2)) -lt $right ]; then
        ship_col=$((ship_col + 1))
      fi
      # One shot on screen at a time, as in the arcade
      if [ $fire -eq 1 ] && [ -z "$bullets" ]; then
        bullets="$((ship_row - 1)):$((ship_col + 1))"
        shots=$((shots + 1))
        shot_tick=0
      fi

      move_bullets
      check_saucer
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
        update_saucer
      fi
      if [ -z "$invaders" ]; then
        wave=$((wave + 1))
        spawn_wave
      fi
    fi

    draw
    pace
  done

  cleanup
}

main
