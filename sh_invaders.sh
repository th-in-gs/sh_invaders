#!/bin/sh


# This is "#!/bin/sh Invaders": a Space Invaders clone in pure POSIX shell!
#
# Emoji invaders, '¡' for bullets, Unicode ship; or plain ASCII, with -a
# (T switches between them as it runs).
#
# Geometry and timings follow the 1978 arcade game (224x256 pixel screen),
# scaled so that one terminal column is ~4 pixels: the playfield is a fixed
# 56 columns wide, centered in the terminal, and 24-32 rows tall.
#

# Conventions:
#
# "Arcade space" is the arcade's own screen: 256 pixels tall, with heights
# (Y) measured in pixels up from the bottom, as in its ROM. Positions like
# the shields' Y=48 are given in arcade space and mapped to rows for the
# current playfield height (see y2row). Shots keep their heights in arcade
# space, so they move at the arcade's speeds whatever the playfield height;
# their rows are worked out only to draw them and check for hits.
#
# The game runs at 60 frames per second, like the arcade, so the arcade's
# timings (in frames) are used as they are.


set -u
set -f  # no globbing when splitting state strings

ESC=$(printf '\033')
BEL=$(printf '\007')
NL='
'
BS=$(printf '\010')

old_stty=""     # the terminal's settings, to restore (see init)
alt_screen=0    # 1 once on the alternate screen
exit_msg=""     # why the game is exiting, if it has to (see cleanup)

field_w=56  # 224 arcade pixels at ~4 pixels per column

# ---------------------------------------------------------------------------
# Terminal setup / teardown
# ---------------------------------------------------------------------------

# The cursor is hidden and the alternate screen used with the standard
# escape sequences, like everything the game draws (tput's names for them
# are terminfo's, not POSIX's, and would need a program run for each).
# The cursor is hidden after the switch to the alternate screen, as some
# terminals keep its visibility per screen, and again after a resize, as some
# show it again then (it'd sit after whatever was drawn last, often the
# cannon's shot).
#
# cleanup runs from the EXIT trap, so the terminal is restored however the
# game ends: quitting, a signal, or the shell stopping on an error (set -u).
# It keeps the exit status, so an error is still reported as one. A reason
# for exiting in $exit_msg is shown once the terminal is back to normal.
cleanup() {
  rc=$?
  trap - EXIT INT TERM HUP
  if [ $alt_screen -eq 1 ]; then
    printf '%s' "${ESC}[?25h${ESC}[?1049l"   # show the cursor; main screen
  fi
  if [ -n "$old_stty" ]; then
    stty "$old_stty" 2>/dev/null || stty sane 2>/dev/null || true
  fi
  if [ -n "$exit_msg" ]; then
    echo "$exit_msg" >&2
  elif [ $rc -ne 0 ] && [ $rc -lt 128 ]; then
    # A shell error message went to the alternate screen, which has now
    # gone, so say that something went wrong (signals, 128 and up, aren't
    # errors)
    echo "#!/bin/sh INVADERS stopped with an error (exit status $rc)." >&2
  fi
  exit $rc
}

# Sets $rows and $cols to the terminal's size, by asking the terminal, as
# xterm's resize command does: the cursor is sent to row and column 999,
# which the terminal limits to its bottom-right corner, then asked where it
# is (ESC[6n). The terminal replies as if typed: ESC[<row>;<col>R. (The
# cursor is saved and restored around this, with ESC 7 and ESC 8.) The input
# must be unbuffered and unechoed (see init); anything else read meanwhile
# is dropped. Any terminal that can draw the game can answer. The game waits
# up to 2 seconds for the reply, in case of a slow connection, and returns
# 1 if none comes. $1, if given, is another question to ask first; all that
# was read is left in $term_reply.
term_size() {
  printf '%s' "${1-}${ESC}7${ESC}[999;999H${ESC}[6n${ESC}8"
  reply=""
  tries=0
  while [ $tries -lt 100 ]; do
    IFS= read -r chunk || true   # partial input (no newline) returns 1
    reply="$reply$chunk"
    case $reply in *"${ESC}["*R*) break ;; esac
    sleep 0.02
    tries=$((tries + 1))
  done
  term_reply=$reply
  # The reply is the ESC[...R with two numbers (others may be keys pressed)
  # ($csi, not a nested "${ESC}[" in ${reply#...}, which some editors'
  # syntax highlighting can't follow)
  csi="${ESC}["
  while :; do
    case $reply in
      *"$csi"*) reply=${reply#*"$csi"} ;;
      *) break ;;
    esac
    rows=${reply%%";"*}; cols=${reply#*";"}; cols=${cols%%R*}
    case $rows in ''|*[!0-9]*) continue ;; esac
    case $cols in ''|*[!0-9]*) continue ;; esac
    return 0
  done
  return 1
}

# The game draws emoji and box/block symbols, which need a UTF-8 locale.
# Warn (rather than draw garbage) if the locale doesn't look like UTF-8,
# unless the game is to draw in ASCII.
check_locale() {
  [ $ascii -eq 1 ] && return
  loc=${LANG:-}
  loc=${LC_CTYPE:-$loc}
  loc=${LC_ALL:-$loc}
  case $loc in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) return ;;
  esac
  echo "Your locale (${loc:-unset}) isn't UTF-8, so the game's emoji and" >&2
  echo "symbols may not display correctly. Try: LANG=en_US.UTF-8 $0" >&2
  echo "Or play in plain ASCII: $0 -a" >&2
  printf 'Press Enter to play anyway, or Ctrl-C to quit. ' >&2
  read -r _ || exit 1
}

# Sets the characters things are drawn with: emoji and Unicode symbols, or
# ASCII if $ascii is 1. Each takes the same number of columns in both. The
# invaders' types are kept as letters (o, c and s: see spawn_wave), drawn
# with $g_inv_o, $g_inv_c and $g_inv_s.
set_glyphs() {
  if [ $ascii -eq 1 ]; then
    g_inv_o='{}' g_inv_c='<>' g_inv_s='/\'
    g_ship='/^\' g_saucer=' oo ' g_shot='!' g_shot_boom='X'
    g_boom_l='>' g_boom_r='<'
    g_pl_foot='I' g_pl_mid='+' g_pl_top='T'
    g_sh_full='#' g_sh_l='/' g_sh_r='\' g_sh_hit=':'
    g_gnd='-' g_gnd_l='.' g_gnd_r='.' g_gnd_gaps='.'
    g_side='|' g_pm='~'
  else
    g_inv_o='🐙' g_inv_c='🦀' g_inv_s='👾'
    g_ship='╱▲╲' g_saucer=' ◜◝ ' g_shot='¡' g_shot_boom='Ж'
    g_boom_l='›' g_boom_r='‹'
    g_pl_foot='┴' g_pl_mid='┼' g_pl_top='┬'
    g_sh_full='█' g_sh_l='▟' g_sh_r='▙' g_sh_hit='▒'
    g_gnd='─' g_gnd_l='╴' g_gnd_r='╶' g_gnd_gaps='╌'
    g_side='│' g_pm='±'
  fi
}

# Switches between the two sets of characters (the T key), and redraws
# everything with the new ones.
switch_glyphs() {
  ascii=$((1 - ascii))
  set_glyphs
  build_scenery
  ground_dirty=1 shields_dirty=1 inv_rebuild=1
}

# Sets $row to the terminal row for arcade-space height $1 (in pixels).
y2row() {
  row=$((y0 + field_h - ($1 * field_h + 128) / 256))
}

# Sets $ry to an arcade-space height (in pixels) within row $1, chosen so
# that y2row gives back the same row. Used to start shots off.
rowy() {
  ry=$(( ((y0 + field_h - $1) * 256 + 127) / field_h ))
}

init() {
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "$0 must be run in a terminal (input and output)." >&2
    exit 1
  fi
  check_locale   # (it may wait for Enter, so before input is changed)
  set_glyphs

  # From here the terminal is changed, so make sure it gets restored. Signals
  # exit with the usual status (128 + signal number), which runs cleanup.
  trap cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # Non-blocking, unechoed, unbuffered input: reads return immediately
  old_stty=$(stty -g)
  stty -icanon -echo min 0 time 0

  # Also ask whether the terminal does synchronized output (ESC[?2026$p),
  # which frames are wrapped in where it does (see draw). It answers
  # ESC[?2026;<n>$y, with n 1, 2 or 3 if it does. A terminal that doesn't
  # know the question ignores it, and as terminals answer in turn, any
  # answer comes before the size: so there's no waiting for one that
  # doesn't come.
  if ! term_size "${ESC}[?2026\$p"; then
    exit_msg="The terminal didn't say what size it is (it didn't answer ESC[6n)."
    exit 1
  fi
  case $term_reply in
    *"${ESC}[?2026;"[123]"\$y"*) sync_on="${ESC}[?2026h" sync_off="${ESC}[?2026l" ;;
    *) sync_on="" sync_off="" ;;
  esac
  if [ $cols -lt $((field_w + 2)) ] || [ $rows -lt 24 ]; then
    exit_msg="Terminal is ${cols}x${rows}; at least $((field_w + 2))x24 is needed."
    exit 1
  fi

  # Redo the layout when the window is resized (see handle_resize)
  resized=0
  too_small=0
  sent_small=""   # the "too small" message last sent (see draw)
  cur_r=0 cur_a="" # where the cursor is isn't known yet (see emit)
  scenery_todo="" # scenery parts still to send (see draw)
  trap 'resized=1' WINCH 2>/dev/null || true

  printf '%s' "${ESC}[?1049h${ESC}[?25l"   # alternate screen; hide the cursor
  alt_screen=1
  layout
  init_game
}

# Computes the playfield layout, and everything placed on it, from the
# terminal size in $rows and $cols.
layout() {
  # Playfield: field_w columns (plus a border each side) by field_h rows,
  # centered. The arcade screen's aspect would be 32 rows; 24 is the minimum.
  field_h=$rows
  [ $field_h -gt 32 ] && field_h=32
  x0=$(( (cols - field_w - 2) / 2 + 1 ))  # left border column
  y0=$(( (rows - field_h) / 2 ))          # rows above the playfield
  left=$((x0 + 1))
  right=$((x0 + field_w))
  hud_row=$((y0 + 1))                     # score headings; values below
  top_row=$((y0 + 3))                     # shots vanish above this
  # Score headings, laid out like the arcade's " SCORE<1> HI-SCORE ...".
  # This game has one player, so it shows just SCORE, and the wave in place
  # of SCORE<2>.
  sc_x=$((left + 5))
  hi_x=$((left + field_w / 2 - 4))
  wv_x=$((right - 8))   # WAVE ends as far in from the right as SCORE starts

  y2row 16; ground_row=$row               # the arcade's green line
  ship_row=$((ground_row - 1))
  # The arcade ends the game when an invader goes below Y=40 (016B), just
  # above the cannon's top: the game ends when an invader reaches the row
  # below the one holding Y=40. On shorter playfields that can be the
  # cannon's row, so it's kept at least a row above it.
  y2row 40; land_row=$((row + 1))
  [ $land_row -gt $((ship_row - 1)) ] && land_row=$((ship_row - 1))

  # The flying saucer crosses at Y=208. It is drawn " ◜◝ " underlined: a
  # dome over a flat body, in red like the arcade's overlay, 4 columns wide
  # like the arcade's 16 pixels.
  y2row 208; saucer_row=$row
  saucer_w=4
  [ $saucer_row -lt $top_row ] && saucer_row=$top_row
  # The arcade prints GAME OVER at Y=192-200 (screen address $2D18): between
  # the saucer's lane and the top of the first wave
  y2row 196; go_row=$row
  # The first wave's starting height (Y=120). The saucer's timer only runs
  # once the formation is below it.
  y2row 120; rack_start_row=$row

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
      if [ $dc -lt 2 ] || [ $dc -gt 3 ]; then
        shield_cells="$shield_cells $shield_bot:$((sx + dc)):B"
      fi
      dc=$((dc + 1))
    done
  done

  # Shots move in arcade space (see the top of the file) at the arcade's
  # speeds: the player's shot 4 pixels a frame; invader shots 4 pixels a
  # step, each type stepping on its own frame of three (5 pixels once 8 or
  # fewer invaders are left: the arcade's SpeedShots)
  shot_speed=4

  # Invader formation: 11 x 5, rows 16 arcade pixels apart, and columns 16
  # (4 terminal columns: see inv_place)
  inv_rows=5
  inv_cols=11
  inv_spacing=$(( (16 * field_h + 128) / 256 ))
  [ $inv_spacing -lt 1 ] && inv_spacing=1

  build_scenery
}

# Builds the scenery that doesn't change, for the layout and the characters
# in use: side borders, the whole ground line, score headings, controls.
# Then the screen is cleared and drawn afresh.
build_scenery() {
  # The playfield's sides. They're also cut into parts of 4 rows, for
  # sending a part at a time on a slow line (see draw).
  scenery="${ESC}[2m" scenery_parts="" part=""
  r=$top_row
  while [ $r -lt $ground_row ]; do
    t="${ESC}[$r;${x0}H$g_side${ESC}[$r;$((right + 1))H$g_side"
    scenery="$scenery$t" part="$part$t"
    if [ $(( (r - top_row) % 4)) -eq 3 ]; then
      scenery_parts="$scenery_parts${ESC}[2m$part${ESC}[0m$NL" part=""
    fi
    r=$((r + 1))
  done
  [ -n "$part" ] && scenery_parts="$scenery_parts${ESC}[2m$part${ESC}[0m$NL"
  scenery="$scenery${ESC}[0m"
  # The ground line whole, for the title screen; in play it erodes (see
  # erode_ground)
  line=""
  c=0
  while [ $c -lt $field_w ]; do line="$line$g_gnd"; c=$((c + 1)); done
  ground_line=$line
  ground_dirty=1
  redraw_all=1
  t="${ESC}[$hud_row;${sc_x}HSCORE${ESC}[$hud_row;${hi_x}HHI-SCORE"
  t="$t${ESC}[$hud_row;${wv_x}HWAVE"
  scenery="$scenery$t" scenery_parts="$t$NL$scenery_parts"
  # The row below the ground shows the cannons left (see draw); the
  # controls go below that
  help="MOVE: H/L OR ARROWS   FIRE: SPACE   QUIT: Q"
  t="${ESC}[$((ground_row + 2));$((left + (field_w - ${#help}) / 2))H$help"
  scenery="$scenery$t" scenery_parts="${scenery_parts%%"$NL"*}$NL$t$NL${scenery_parts#*"$NL"}"
}

init_game() {
  quit=0
  dbg=0          # 1 to show the frame rate (F toggles it)
  fps_hist=""    # the last 8 measured rates, in tenths of a frame a second
  dbg_fps="" dbg_sd=""   # the last measured rate and spread (see fps_stats)
  go_letter=7  # frames per letter of "GAME OVER", as in the arcade
  load_hiscore
  new_game     # sets up a game (so the score line has something to show) ...
  mode=title   # ... but start on the title screen, like the arcade
  title_t=0

  frame=0           # counts every frame from startup (see meet_outcome)

  # Frame pacing (see pace)
  target_us=16667   # 60 fps, the arcade's rate
  frame_us=$target_us   # the last measured frame time (see pace_measure)
  delay_us=9000     # initial sleep per frame, adjusted as the game runs
  pace_frames=0
  pace_check=0
  pace_sec=""       # second at which the current measurement started
  pace_win=2        # seconds a measurement of the frame rate takes
  pace_mode=fine    # fine, cal, tick or busy (see pace)
  pace_prev_delay=0 pace_prev_frame=0   # a measurement to compare, in fine
  pace_coarse=0     # 1 if the last measurement suggested coarse sleeps
  pace_long=0       # 1 if its frames were too long
  spin=0            # count to busy-wait, and how long a count takes, in ns
  spin_ns=0
  cal_f="" cal_k=0  # the last measurement's frame time and count, in cal
  work_us=0         # time a frame takes without waiting
  cyc=0             # frame in the cycle, in tick
  pace_quiet=0      # measurements since the count last changed, in tick
  pace_drift=0      # frames gained (+) or lost (-) since the last
                    # correction, in tick
  pace_bad=0        # how often the count has needed correcting, in tick
  clock_sec
  pace_seen=$now    # (empty if there's no usable clock: keep the delay)
}

# Sets $nr to the new layout's row for row $1 of the old layout. If the
# playfield's height hasn't changed it just moves; otherwise the row is
# converted to an arcade-space height and back, which can round by a row.
remap_row() {
  if [ $field_h -eq $o_h ]; then
    nr=$(($1 + y0 - o_y0))
  else
    y2row $(( ( (o_y0 + o_h - $1) * 256 + 128) / o_h ))
    nr=$row
  fi
}

# The window was resized: lay the game out afresh and move everything on it
# to match, so play carries on where it was. If the window is now too small
# the game pauses (keeping the old layout) until it is big enough again.
handle_resize() {
  resized=0
  sent_small=""   # (the terminal may have redrawn the screen)
  printf '%s' "${ESC}[?25l"   # hide the cursor again (see cleanup)
  o_rows=$rows o_cols=$cols
  if ! term_size; then
    rows=$o_rows cols=$o_cols   # carry on as we were
    return
  fi
  if [ $cols -lt $((field_w + 2)) ] || [ $rows -lt 24 ]; then
    too_small=1
    return
  fi
  too_small=0

  o_y0=$y0; o_h=$field_h; o_left=$left
  o_cells=$shield_cells
  layout
  dx=$((left - o_left))

  # Formation: its bottom row moves to the new layout (as it was both
  # before and after its last move), and invaders are placed from it afresh.
  # Rounding mustn't put it above the first wave's starting row (where it
  # could meet the saucer) or down where it would land.
  for v in rack_y prev_rack_y; do
    eval "remap_row \$$v"
    [ $nr -lt $rack_start_row ] && nr=$rack_start_row
    [ $nr -ge $land_row ] && nr=$((land_row - 1))
    eval "$v=$nr"
  done
  moved=""
  k=0
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    # Invaders the cursor has reached this sweep are at the new position
    if [ $k -lt $inv_cur ]; then
      inv_place $4 $5 $rack_px $rack_y
    else
      inv_place $4 $5 $prev_rack_px $prev_rack_y
    fi
    moved="$moved $ir:$ic:$3:$4:$5"
    k=$((k + 1))
  done
  invaders=$moved
  inv_rebuild=1

  # Shots keep their heights in arcade space, so they just get their rows in
  # the new layout; any now outside the playfield are dropped
  moved=""
  for b in $bullets; do
    y2row $bullet_y
    if [ $row -ge $top_row ] && [ $row -lt $ship_row ]; then
      moved="$row:$((${b#*:} + dx))"
    fi
  done
  bullets=$moved
  moved=""
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    y2row $5
    if [ $row -ge $top_row ] && [ $row -lt $ground_row ]; then
      moved="$moved $row:$(($2 + dx)):$3:$4:$5"
    fi
  done
  bombs=$moved

  # Explosions in progress move with everything else
  if [ $inv_boom -gt 0 ]; then
    remap_row ${inv_boom_at%:*}
    inv_boom_at="$nr:$((${inv_boom_at#*:} + dx))"
  fi
  if [ $shot_boom -gt 0 ]; then
    remap_row ${shot_boom_at%:*}
    shot_boom_at="$nr:$((${shot_boom_at#*:} + dx))"
  fi
  moved=""
  for e in $bomb_booms; do
    IFS=:
    set -- $e
    unset IFS
    remap_row $1
    moved="$moved $nr:$(($2 + dx)):$3:$4"
  done
  bomb_booms=$moved

  ship_col=$((ship_col + dx))
  [ $saucer_x -ne 0 ] && saucer_x=$((saucer_x + dx))

  # Shields: the cells are listed in the same order in both layouts, so
  # carry each cell's damage across. Read them all first: old and new cells
  # can share positions.
  hps=""
  for o in $o_cells; do
    or=${o%%:*}; t=${o#*:}; oc=${t%%:*}
    eval "hps=\"\$hps \${sh_${or}_${oc}:-0}\"; unset sh_${or}_${oc}"
  done
  for s in $shield_cells; do
    hps=${hps# }; hp=${hps%% *}; hps=${hps#"$hp"}
    sr=${s%%:*}; t=${s#*:}; sc=${t%%:*}
    eval "sh_${sr}_${sc}=$hp"
  done

  # Redraw everything that is normally cached
  shields_dirty=1
}

# ---------------------------------------------------------------------------
# Game state
#   invaders: space-separated "row:col:kind:r:c" (kind o, c or s, for octopus,
#             crab or squid; r, c their place in the rack, 0,0 the bottom
#             left), in the order the arcade moves them: from the bottom
#             left, along each row and up
#   bullets:  the player's shot, "row:col" (at most one, as in the arcade);
#             its height in arcade space is in $bullet_y
#   bombs:    space-separated "row:col:type:steps:height" invader shots
#             (height in arcade space), at most one of
#             each type: r (aimed "rolling"), p ("plunger"), s ("squiggly")
#   sh_ROW_COL: hit points left in each shield cell (2 full, 1 damaged,
#             unset or 0 gone). POSIX sh has no arrays, hence one variable
#             per cell, accessed with eval.
#   gnd_I:    the ground line's lit pixels in the field's column I, a 4-bit
#             mask (bit 0 the leftmost of the column's 4 arcade pixels)
#   inv_boom, shot_boom: frames left of an invader's or the player's shot's
#             explosion, at "row:col" $inv_boom_at, $shot_boom_at
#   bomb_booms: space-separated "row:col:type:turns" invader shot explosions
#             (see bomb_explodes)
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
  shields_whole=1    # send them all (see draw)
  shield_changed=""
}

# Damages the shield cell at row $1, column $2. Returns 1 if there is no
# shield there.
hit_shield() {
  if [ $1 -lt $shield_top ] || [ $1 -gt $shield_bot ]; then
    return 1
  fi
  eval "hp=\${sh_$1_$2:-0}"
  [ $hp -eq 0 ] && return 1
  eval "sh_$1_$2=$((hp - 1))"
  shields_dirty=1
  shield_changed="$shield_changed $1;$2"
  return 0
}

# Shots that hit a shield damage it and blow up.
check_shields() {
  for b in $bullets; do
    hit_shield ${b%:*} ${b#*:} && shot_explodes ${b%:*} ${b#*:}
  done
  remaining=""
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    if hit_shield $1 $2; then
      bomb_explodes $1 $2 $3
      continue
    fi
    remaining="$remaining $m"
  done
  bombs=$remaining
}

# ---------------------------------------------------------------------------
# Explosions, as in the arcade:
#  - An invader that is hit explodes for 16 frames (1504-152F, 1538). Until
#    it's gone the formation stands still (DrawAlien, 0100, times the
#    explosion instead of moving an invader) and the player can't fire.
#  - The player's shot explodes for 16 frames when it hits anything but an
#    invader or the saucer, or misses and reaches Y=216 (03D7-03F7, 14E1).
#    It's still the one shot allowed, so the player can't fire until it's
#    gone.
#  - An invader shot that hits something stays where it hit until its next
#    turn (0612), then explodes, and is gone three turns later (0644).
#    Until then its type can't fire again.
#  - One difference: a shot that hits a shield or the ground damages it at
#    once. In the arcade the shot just lands on their pixels; it's erasing
#    the explosion when it ends (0436, 0675) that clears them.
# ---------------------------------------------------------------------------

# The player's shot blows up at row $1, column $2.
shot_explodes() {
  bullets=""
  shot_boom=16
  shot_boom_at="$1:$2"
}

# An invader shot of type $3 blows up at row $1, column $2. Its turns count
# down from 4: at 4 it's still the shot, then 3 turns of explosion.
bomb_explodes() {
  bomb_booms="$bomb_booms $1:$2:$3:4"
}

# Counts down the invader's and the player's shot's explosions (invader
# shots' count down in move_bombs, on their turns).
tick_explosions() {
  [ $inv_boom -gt 0 ] && inv_boom=$((inv_boom - 1))
  [ $shot_boom -gt 0 ] && shot_boom=$((shot_boom - 1))
  return 0
}

# Sets $g to draw column $1 of the ground line as its 4 pixels now are, as
# best a character can.
ground_glyph() {
  eval "g=\$gnd_$1"
  case $g in
    15) g=$g_gnd ;;
    0) g=' ' ;;
    1|2|3) g=$g_gnd_l ;;   # left half only
    4|8|12) g=$g_gnd_r ;;  # right half only
    *) g=$g_gnd_gaps ;;    # gaps across the column
  esac
}

# Restores the ground line, as the arcade does for each wave (0804); a lost
# cannon doesn't restore it.
reset_ground() {
  i=0
  while [ $i -lt $field_w ]; do
    eval "gnd_$i=15"
    i=$((i + 1))
  done
  ground_dirty=1
}

# An invader shot blew up on the ground at column $1. The arcade draws the
# explosion over its 1-pixel green line, then erases it, which clears the
# line's pixels under the explosion's lit ones. Its pixels on the line
# depend on the height the shot blew up at (shots blow up below Y=21):
#   Y=16: -2 -1 0 1 2  (relative to the shot's middle; the shot itself
#   Y=17: -3 -1 0 1        lands on the line, and erasing it clears pixels
#   Y=18: -2 0 2           its explosion clears anyway)
#   Y=19, 20: none, as the explosion is above the line
# At normal speed shots always blow up at Y=18 (the heights shots move
# through are fixed: see docs/shot-collisions); at 5 pixels a step, any of
# 16-20. Shots fall from odd X, so the middle is on an even pixel, one of
# the two in the column. The frame count chooses where the game can't know.
erode_ground() {
  if [ $inv_count -le 8 ]; then
    case $((frame / 2 % 5)) in
      0) set -- $1 -2 -1 0 1 2 ;;
      1) set -- $1 -3 -1 0 1 ;;
      2) set -- $1 -2 0 2 ;;
      *) return ;;
    esac
  else
    set -- $1 -2 0 2
  fi
  mid=$(( ($1 - left) * 4 + frame % 2 * 2 ))
  shift
  for d in "$@"; do
    p=$((mid + d))
    if [ $p -lt 0 ] || [ $p -ge $((field_w * 4)) ]; then
      continue
    fi
    eval "gnd_$((p / 4))=\$((gnd_$((p / 4)) & ~(1 << $((p % 4)))))"
  done
  ground_dirty=1
}

# Sets $bcol to the color of the arcade's screen overlay at row $1: red at
# the top (from the saucer's lane up), green from the shields down.
boom_color() {
  if [ $1 -le $saucer_row ]; then
    bcol="${ESC}[31m"
  elif [ $1 -ge $shield_top ]; then
    bcol="${ESC}[32m"
  else
    bcol=""
  fi
}

# Sets $reload: how many steps every falling invader shot must have made
# before another may be fired. The arcade's table at 1AA1, by score.
reload_bombs() {
  if [ $score -lt 200 ]; then reload=48
  elif [ $score -lt 1000 ]; then reload=16
  elif [ $score -lt 2000 ]; then reload=11
  elif [ $score -lt 3000 ]; then reload=8
  else reload=7
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
    s) pts=30 ;;
    c) pts=20 ;;
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

  # The formation's reference: its bottom-left invader's slot at X=24, as in
  # the arcade (see inv_place). Rows count up from the bottom.
  rack_px=24
  rack_y=$bottom
  invaders=""
  r=0
  while [ $r -lt $inv_rows ]; do
    case $r in
      0|1) kind=o ;;   # the arcade's "octopus"
      2|3) kind=c ;;   # "crab"
      *) kind=s ;;     # "squid"
    esac
    c=0
    while [ $c -lt $inv_cols ]; do
      inv_place $r $c $rack_px $rack_y
      invaders="$invaders $ir:$ic:$kind:$r:$c"
      c=$((c + 1))
    done
    r=$((r + 1))
  done
  inv_count=$((inv_rows * inv_cols))
  prev_rack_px=$rack_px prev_rack_y=$rack_y
  inv_dx=2       # pixels per sweep, to the right first
  inv_drop=0     # rows to drop on the next sweep
  inv_cur=0      # the cursor: the next invader to move (see move_invaders)
  inv_events=""  # invaders moved or gone since the last draw (see draw)
  inv_rebuild=1
  reset_shields
  reset_ground
  bullets=""
  bombs=""
  inv_boom=0 shot_boom=0 bomb_booms=""
  wave_wait=0   # frames since the last invader was hit (see main)
  bomb_tick=0   # which invader shot type's turn it is (see move_bombs)
  turn=r
  saucer_x=0             # no saucer on screen
  saucer_hit=0
}

# Sets $ir, $ic to where the invader in rack row $1 (0 at the bottom),
# column $2 (0 at the left) is drawn, with the formation's reference at
# X=$3 arcade pixels and bottom row $4. As in the arcade, each invader has a
# 16-pixel slot (the reference is the bottom-left one's left edge); the
# invader is 2 columns (8 pixels) wide, in the middle of it.
inv_place() {
  ic=$((left + ($3 + $2 * 16 + 4) / 4))
  ir=$(($4 - $1 * inv_spacing))
}

# Starts a new game (at launch, and on 'r' after game over).
new_game() {
  mode=play
  redraw_all=1
  score=0
  lives=3
  wave=1
  game_over=0
  boom=0   # frames left of the ship's explosion (game is paused meanwhile)
  bell=0   # ring the terminal bell on the next draw
  ship_col=$((left + field_w / 2 - 2))
  shots=0               # player shots fired (sets saucer direction and score)
  passed_r="" passed_p="" passed_s=""  # player shot each type has passed
  saucer_timer=1536     # frames between saucers
  saucer_pending=0
  plu_idx=0      # positions in the column-firing table
  squ_idx=6
  fire_delay=48  # invaders hold fire for 48 frames at the start
  bonus_given=0  # the extra cannon at 1500 points (once per game)
  bonus_flash=0
  spawn_wave
}

# As in the arcade (0935-0979), one extra cannon is awarded the first time
# the score reaches 1500 (the arcade's default; operators could set 1000).
# The arcade played a sound; here the bell rings and the cannon count
# flashes.
check_bonus() {
  [ $bonus_flash -gt 0 ] && bonus_flash=$((bonus_flash - 1))
  if [ $bonus_given -ne 0 ] || [ $score -lt 1500 ] || [ $game_over -ne 0 ]
  then
    return
  fi
  bonus_given=1
  lives=$((lives + 1))
  bell=1
  bonus_flash=120   # 2 seconds
}

# Sets $p4 to $1 zero-padded to four digits, as the arcade shows scores.
pad4() {
  p4=$1
  while [ ${#p4} -lt 4 ]; do p4="0$p4"; done
}

# The ship was hit: lose a life, ring the bell and play the explosion. As in
# the arcade, the game pauses while the ship explodes and the screen is
# cleared of shots.
player_hit() {
  lives=$((lives - 1))
  bell=1
  boom=60        # the arcade's 12 explosion pictures, 5 frames each
  bullets=""
  bombs=""
  inv_boom=0 shot_boom=0 bomb_booms=""
  fire_delay=48  # as at the start, the invaders hold fire for a while
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

# Sets $sp to as much of "GAME OVER" as has typed out, letter-spaced (see
# arcade_text), and $gx to the column it starts at, on row $go_row.
game_over_text() {
  arcade_text "GAME OVER" $((go_t / go_letter))
  gx=$((left + field_w / 2 - 8))
}

# "GAME OVER" types out over the frozen invaders, as in the arcade (and is
# drawn last: see draw). The arcade's text simply overwrote any invader
# pixels; here an invader the letters reach is removed whole, so no half of
# a two-column invader is left showing.
type_game_over() {
  game_over_text
  [ -n "$sp" ] || return 0
  gend=$((gx + ${#sp} - 1))
  survivors=""
  for inv in $invaders; do
    ir=${inv%%:*}; t=${inv#*:}; ic=${t%%:*}
    if [ $ir -eq $go_row ] && [ $((ic + 1)) -ge $gx ] && [ $ic -le $gend ]
    then
      inv_events="$inv_events -$inv"
      continue
    fi
    survivors="$survivors $inv"
  done
  invaders=$survivors
}

# The high score is kept in a file in the home directory. Reading and
# writing use only shell built-ins; failures (no HOME, read-only home) are
# ignored and just mean the high score isn't kept.
load_hiscore() {
  hi=0
  hi_file=""
  [ -n "${HOME:-}" ] && hi_file="$HOME/.sh_invaders_hiscore"
  if [ -z "$hi_file" ] || [ ! -r "$hi_file" ]; then
    return
  fi
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
# keys pressed since the previous frame. Toggles $dbg on F, and switches
# between emoji and ASCII on T.
read_input() {
  move=0
  fire=0
  restart=0
  # Terminal is in min 0 time 0 mode, so read returns at once with whatever
  # is pending (status 1, as it sees EOF). IFS= keeps spaces (fire key).
  IFS= read -r keys
  # (Not [ -n "$keys" ]: some shells' test reads keys like = or ! as
  # operators)
  while [ ${#keys} -gt 0 ]; do
    rest=${keys#?}
    key=${keys%"$rest"}
    keys=$rest
    if [ "$key" = "$ESC" ]; then
      # An escape sequence: ESC [ (parameters) final, or ESC O final. Read
      # the whole sequence, so other keys' sequences (or their modifier
      # parameters, as in ESC [ 1 ; 5 D) aren't taken as ordinary keys. A
      # lone ESC is just skipped.
      case $keys in
        '['*|O*)
          rest=${keys#?}
          intro=${keys%"$rest"}
          keys=$rest
          if [ "$intro" = '[' ]; then
            while :; do
              case $keys in
                [0-9]*|\;*) keys=${keys#?} ;;
                *) break ;;
              esac
            done
          fi
          rest=${keys#?}
          final=${keys%"$rest"}
          keys=$rest
          case $final in
            D) move=-1 ;;   # left arrow
            C) move=1 ;;    # right arrow
            A) fire=1 ;;    # up arrow
          esac ;;
      esac
      continue
    fi
    case $key in
      q|Q) quit=1 ;;
      r|R) restart=1 ;;
      f|F) dbg=$((1 - dbg)) ;;   # the frame-rate display (see draw)
      t|T) switch_glyphs ;;
      h|H|a|A) move=-1 ;;
      l|L|d|D) move=1 ;;
      ' ') fire=1 ;;
    esac
  done
}

# The player's shot climbs $shot_speed pixels each frame in arcade space. As
# in the arcade, one that reaches Y=216 has missed, and blows up there.
move_bullets() {
  moved=""
  for b in $bullets; do
    bullet_y=$((bullet_y + shot_speed))
    if [ $bullet_y -ge 216 ]; then
      y2row 216
      shot_explodes $row ${b#*:}
    else
      y2row $bullet_y
      moved="$row:${b#*:}"
    fi
  done
  bullets=$moved
}

# The player's shot hitting an invader: the invader explodes and scores.
check_collisions() {
  [ -z "$bullets" ] && return
  # Usually no invader is in the shot's cell (or the one before,
  # invaders being two columns wide), which is quick to see
  br=${bullets%:*}; bc=${bullets#*:}
  case "$invaders " in
    *" $br:$bc:"*|*" $br:$((bc - 1)):"*) ;;
    *) return ;;
  esac
  survivors=""
  k=0
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    ir=$1; ic=$2
    hit=0
    k=$((k + 1))
    remaining=""
    for b in $bullets; do
      if [ $hit -eq 0 ]; then
        br=${b%:*}; bc=${b#*:}
        # Invaders are two columns wide
        if [ $br -eq $ir ] && [ $bc -ge $ic ] && [ $bc -le $((ic + 1)) ]; then
          hit=1
          inv_boom=16
          inv_boom_at="$ir:$ic"
          points "$3"
          score=$((score + pts))
          inv_count=$((inv_count - 1))
          inv_events="$inv_events -$inv"
          # The cursor stays on the same invader
          [ $k -le $inv_cur ] && inv_cur=$((inv_cur - 1))
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

# Moves one invader a frame, as the arcade does (0141, 0100). A cursor
# steps through the live invaders, from the bottom left along each row and
# up, putting each where the formation's reference now places it. Once the
# cursor has been round them all, the reference moves (01A1): 2 pixels
# across, and also down a row if the formation has reached an edge. So each
# move ripples through the formation, bottom row first, and an invader
# moves a column (4 pixels) every 2 x invaders frames. (A lone invader
# moves 3 pixels to the right, but only once it has turned at the left
# edge: the arcade picks the step as the formation turns, 18F1.)
# Returns 0 if an invader moved to another cell; sets $landed=1 if it
# reached $land_row.
move_invaders() {
  landed=0
  [ -z "$invaders" ] && return 1
  set -- $invaders
  if [ $inv_cur -ge $# ]; then
    prev_rack_px=$rack_px prev_rack_y=$rack_y
    rack_px=$((rack_px + inv_dx))
    rack_y=$((rack_y + inv_drop))
    inv_drop=0
    inv_cur=0
  fi
  eval "old=\${$((inv_cur + 1))}"
  inv_cur=$((inv_cur + 1))
  IFS=:
  set -- $old
  unset IFS
  inv_place $4 $5 $rack_px $rack_y
  [ $ir -ge $land_row ] && landed=1
  # Invaders passing through the shields erase them, as in the arcade
  if [ $ir -ge $shield_top ] && [ $ir -le $shield_bot ]; then
    eval "sh_${ir}_${ic}=0 sh_${ir}_$((ic + 1))=0"
    shields_dirty=1
    shield_changed="$shield_changed $ir;$ic $ir;$((ic + 1))"
  fi
  # As in the arcade (1597), the formation turns, dropping on its next
  # move, as soon as an invader's pixels reach X=213 or X=9. The types'
  # sprites are different widths in their 16-pixel slots (1C00-1C2F).
  x=$((rack_px + $5 * 16))
  case $3 in   # its leftmost and rightmost pixels in the slot
    o) px_l=2 px_r=13 ;;
    c) px_l=3 px_r=13 ;;
    *) px_l=4 px_r=11 ;;
  esac
  if [ $inv_dx -gt 0 ] && [ $((x + px_r)) -ge 213 ]; then
    inv_dx=-2 inv_drop=1
  elif [ $inv_dx -lt 0 ] && [ $((x + px_l)) -le 9 ]; then
    inv_dx=2 inv_drop=1
    [ $inv_count -eq 1 ] && inv_dx=3
  fi
  new="$ir:$ic:$3:$4:$5"
  [ "$new" = "$old" ] && return 1
  # (Cutting at the end first and the known start second is much quicker
  # than ${invaders#*" $old"}, which is slow in long strings)
  pre=${invaders%%" $old"*}
  invaders="$pre $new${invaders#"$pre $old"}"
  inv_events="$inv_events -$old +$new"
  return 0
}

# Invader shots step down 4 pixels in arcade space, or 5 once 8 or fewer
# invaders are left (the arcade's SpeedShots). As in the arcade, the three
# types take turns: each frame one of them steps (squiggly, then plunger,
# then rolling, as the arcade's timer counts down 2, 1, 0), so each steps
# every third frame. Shots count their steps, which the reload rule uses.
move_bombs() {
  bomb_tick=$(( (bomb_tick + 2) % 3 ))
  case $bomb_tick in
    0) turn=r ;;
    1) turn=p ;;
    *) turn=s ;;
  esac
  moved=""
  for e in $bomb_booms; do
    IFS=:
    set -- $e
    unset IFS
    if [ $3 != $turn ]; then
      moved="$moved $e"
    elif [ $4 -gt 1 ]; then
      moved="$moved $1:$2:$3:$(($4 - 1))"
    fi
  done
  bomb_booms=$moved
  [ -z "$bombs" ] && return
  step=4
  [ $inv_count -le 8 ] && step=5
  moved=""
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    if [ $3 = $turn ]; then
      h=$(($5 - step))
      y2row $h
      if [ $row -lt $ground_row ]; then
        moved="$moved $row:$2:$3:$(($4 + 1)):$h"
      else
        # Blows up on the ground, just above the line, eroding it
        bomb_explodes $ship_row $2 $3
        erode_ground $2
      fi
    else
      moved="$moved $m"
    fi
  done
  bombs=$moved
}

# Invader firing, following the arcade's code (0476-0643). There are three
# shot types, at most one of each in flight. On its turn (see move_bombs) a
# type that isn't falling gets a chance to fire:
#   r  "rolling":  from the column directly over the player
#   p  "plunger":  from columns in the table's order; disabled when one
#                  invader is left
#   s  "squiggly": from columns in the table's order
# A shot may only be fired if every shot already falling has made more than
# $reload steps. It comes from the lowest invader in its column; if that
# column has none left, no shot is fired (but the table still advances).
drop_bomb() {
  if [ $fire_delay -gt 0 ]; then
    fire_delay=$((fire_delay - 1))
    return
  fi
  [ -z "$invaders" ] && return

  bt=$turn
  # A type whose last shot is still blowing up can't fire yet
  case "$bomb_booms" in *":$bt:"*) return ;; esac
  if [ $bt = p ] && [ $inv_count -eq 1 ]; then
    return
  fi
  # The saucer uses the squiggly shot's slot in the arcade
  if [ $bt = s ] && [ $saucer_x -ne 0 ]; then
    return
  fi

  reload_bombs
  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    [ $3 = $bt ] && return          # this type is already in flight
    [ $4 -le $reload ] && return    # another shot hasn't gone far enough
  done

  case $bt in
    r)
      # Formation column (1-11) over the player's center (in arcade
      # pixels, from the reference), clamped to the formation (the arcade
      # uses column 11 when the player is beyond it)
      x=$(( (ship_col + 1 - left) * 4 + 2 - rack_px ))
      if [ $x -lt 0 ]; then col=1; else col=$((x / 16 + 1)); fi
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

  # Lowest live invader in that column (the list starts with the bottom
  # row). As in the arcade, the shot starts where the reference puts it,
  # whether or not the cursor has reached it yet.
  lr=""
  for inv in $invaders; do
    IFS=:
    set -- $inv
    unset IFS
    if [ $5 -eq $((col - 1)) ]; then
      lr=$4
      break
    fi
  done
  [ -z "$lr" ] && return
  inv_place $lr $((col - 1)) $rack_px $rack_y
  sr=$ir colx=$ic

  # Sprites are two columns wide; the rolling shot falls from whichever
  # half is nearer the player, the others from the left half
  sc=$colx
  if [ $bt = r ] && [ $((ship_col + 1)) -gt $colx ]; then
    sc=$((colx + 1))
  fi
  # A new shot starts below the invader, with 1 step made (as in the arcade)
  rowy $((sr + 1))
  bombs="$bombs $((sr + 1)):$sc:$bt:1:$ry"
  eval "passed_$bt="
}

# Decides what happens when the player's shot meets an invader shot of type
# $mt, setting $outcome to pass (both carry on), bomb (only the invader's
# survives), bullet (only the player's survives) or neither.
#
# The arcade decides pixel by pixel. This game only knows positions to the
# cell, so it uses the arcade's frequencies for shots meeting within one
# column, simulated in docs/shot-collisions (percentages):
#
#                  pass  bomb  bullet  neither
#   rolling          45    14       6       35
#   plunger          28    22       9       41
#   squiggly         25     6       6       63
#   with 8 or fewer invaders, when shots fall faster:
#   rolling          45     9       6       40
#   plunger          28    28      12       32
#   squiggly         25    29       6       40
#
# The choice comes from the frame count. Which frame shots meet on depends
# on the player's timing, to the 1/60 s, much as the arcade's pixel
# positions do. (100 has no factor of 3, so invader shots moving every
# third frame doesn't skew it.)
meet_outcome() {
  if [ $inv_count -le 8 ]; then
    case $mt in r) set -- 45 9 6 ;; p) set -- 28 28 12 ;; *) set -- 25 29 6 ;; esac
  else
    case $mt in r) set -- 45 14 6 ;; p) set -- 28 22 9 ;; *) set -- 25 6 6 ;; esac
  fi
  roll=$((frame % 100))
  if [ $roll -lt $1 ]; then
    outcome=pass
  elif [ $roll -lt $(($1 + $2)) ]; then
    outcome=bomb
  elif [ $roll -lt $(($1 + $2 + $3)) ]; then
    outcome=bullet
  else
    outcome=neither
  fi
}

# Handles invader shots hitting the ship or meeting the player's shot (see
# meet_outcome).
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
    # Shots that have passed each other may still be level for a frame
    eval "pv=\$passed_$mt"
    [ "$pv" = $shots ] && bullets_here="" || bullets_here=$bullets
    met=0
    for b in $bullets_here; do
      # The shots move toward each other, so they can pass between frames
      br=${b%:*}
      if [ ${b#*:} -eq $mc ] && [ $br -ge $((mr - 1)) ] && [ $br -le $mr ]; then
        met=1
      fi
    done
    if [ $met -eq 1 ]; then
      meet_outcome
      case $outcome in
        pass) eval "passed_$mt=$shots" ;;
        bomb) shot_explodes $br $mc ;;
        bullet) bomb_explodes $mr $mc $mt; continue ;;
        neither) shot_explodes $br $mc; bomb_explodes $mr $mc $mt; continue ;;
      esac
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
#  - A saucer is due every 1536 frames, counted only once the
#    formation is below the first wave's starting height.
#  - It sets off when due, with 8 or more invaders left and no squiggly shot
#    falling (it shares the squiggly shot's slot).
#  - An odd number of shots fired sends it left to right, even right to left.
#  - It moves 2 pixels every third frame, as in the arcade (a column every 6).
update_saucer() {
  if [ $rack_y -gt $rack_start_row ]; then
    saucer_timer=$((saucer_timer - 1))
    if [ $saucer_timer -le 0 ]; then
      saucer_timer=1536
      saucer_pending=1
    fi
  fi

  # Hit: explosion, then the score in its place; points added as it shows
  if [ $saucer_hit -gt 0 ]; then
    saucer_hit=$((saucer_hit - 1))
    [ $saucer_hit -eq 72 ] && score=$((score + saucer_pts))
    if [ $saucer_hit -eq 0 ]; then
      saucer_x=0
      saucer_pending=0
    fi
    return
  fi

  if [ $saucer_x -eq 0 ]; then
    if [ $saucer_pending -ne 1 ] || [ $inv_count -lt 8 ]; then
      return
    fi
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
  [ $saucer_tick -lt 6 ] && return
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
      saucer_hit=96   # the arcade's 32 ticks of 3 frames
    fi
  done
}

# ---------------------------------------------------------------------------
# Rendering: build the frame's changes in a string, then emit it in one go
# (wrapped in synchronized-output escapes where the terminal supports them).
# docs/screen-updates explains all this in more detail: keep it up to date
# with changes here.
#
# The screen isn't cleared each frame: where the terminal doesn't support
# synchronized output (Terminal.app, for one), it can show the screen
# part-drawn, and a cleared one flickers. Instead the frame is drawn over
# the last one:
#  - Things that move (the cannon, shots, explosions, the saucer) are
#    tracked: each frame blanks just the cells that something covered last
#    frame and nothing covers now, and draws just the things that have
#    changed (or that something else is drawn over).
#  - Layers that change only now and then (the score, the ground, the
#    shields, the formation) send just the parts that have changed, or that
#    something that moved has left a mark on.
#  - The changes are sent in order of row and column, so the cursor mostly
#    runs on from one to the next (see add_item and emit).
# The screen is only cleared and drawn afresh when $redraw_all is set: at
# startup, on a resize, for a new game, back at the title screen, and when
# the glyphs are switched (the T key). A frame with nothing changed isn't
# sent at all.
# ---------------------------------------------------------------------------

# Sets $piece to draw the shield cell at row $1, column $2 as it now is
# (blank once shot away).
shield_piece() {
  eval "hp=\${sh_$1_$2:-0}"
  case $hp in
    0) g=' ' ;;
    1) g=$g_sh_hit ;;
    *)
      case " $shield_cells " in
        *" $1:$2:L "*) g=$g_sh_l ;;
        *" $1:$2:R "*) g=$g_sh_r ;;
        *) g=$g_sh_full ;;
      esac ;;
  esac
  piece="${ESC}[$1;$2H$g"
}

# Sets $g to draw an invader shot of type $2 at row $1. The shots animate
# as they fall, frame chosen by row, after the arcade's shot sprites:
#   rolling   { | } |   a spike circling the shaft
#   plunger   ┴ ┼ ┼ ┬   a crossbar climbing the shaft, then back to the foot
#   squiggly  \ /       a zig-zag
bomb_glyph() {
  case $2 in
    r)
      case $(($1 % 4)) in
        0) g='{' ;;
        2) g='}' ;;
        *) g='|' ;;
      esac ;;
    p)
      case $(($1 % 4)) in
        0) g=$g_pl_foot ;;
        3) g=$g_pl_top ;;
        *) g=$g_pl_mid ;;
      esac ;;
    *)
      if [ $(($1 % 2)) -eq 0 ]; then g='\'; else g='/'; fi ;;
  esac
}

# Adds $4 to the frame at row $1, column $2, $3 columns wide ($pieces lists
# them as "row;col;width text", one a line), and in play records the cells
# it covers ($items lists "row;col;width", $cov " row;col " per cell).
put() {
  pieces="$pieces$1;$2;$3 $4$NL"
  # The cells are for blanking what moved, which the title screen never
  # needs (it only grows); its lines are long, so this saves a lot
  [ $mode = title ] && return
  items="$items $1;$2;$3"
  pc=0
  while [ $pc -lt $3 ]; do
    cov="$cov $1;$(($2 + pc)) "
    pc=$((pc + 1))
  done
}

# As put, for text that only grows as it types out (the title's, and "GAME
# OVER"): when it has, only what's new is sent (see grown).
put_grow() {
  put "$@"
  grows="$grows $1;$2 "
}

# For a piece at row $fr, column $fc ($fw wide, drawn with $text) that's to
# be sent: if it's text that only grows (see put_grow), and it has only
# grown since it was last sent, sets $fc, $fw and $text to just what's new.
# Not if a layer has been drawn in its row this frame, in case it's over
# the text. (Nothing else moves while these texts type out.)
grown() {
  case $grows in *" $fr;$fc "*) ;; *) return 1 ;; esac
  case $lay_cov in *" $fr;"*) return 1 ;; esac
  old="$NL$prev_pieces"
  case $old in *"$NL$fr;$fc;"*) ;; *) return 1 ;; esac
  old=${old#*"$NL$fr;$fc;"}; old=${old%%"$NL"*}
  ow=${old%% *}; old=${old#* }
  case $text in "$old"?*) ;; *) return 1 ;; esac
  text=${text#"$old"} fc=$((fc + ow)) fw=$((fw - ow))
}

# Sets $cells to the cells " row;col " covered by a piece "row;col;width"
# ($1).
piece_cells() {
  zr=${1%%";"*}; t=${1#*";"}; zc=${t%";"*}; zw=${t#*";"}
  cells=""
  while [ $zw -gt 0 ]; do
    cells="$cells $zr;$zc "
    zc=$((zc + 1)); zw=$((zw - 1))
  done
}

# Adds to $dirty the cells of the pieces in list $1 that aren't in list $2
# (lists as in $pieces).
dirty_unless_in() {
  IFS=$NL
  for p in $1; do
    case "$NL$2" in
      *"$NL$p$NL"*) ;;
      *) piece_cells "${p%% *}"; dirty="$dirty$cells" ;;
    esac
  done
  unset IFS
}

# Adds $4 to $out at row $1, column $2, $3 columns wide, in attributes $5
# (see todo_add), moving the cursor there the shortest way from where the
# last text left it ($cur_r, $cur_c; $cur_r is 0 if that isn't known). The
# moves are all ones the VT100 had: to a row and column (ESC[r;cH), up,
# down, right or left (ESC[nA, B, C, D; n can be left out if 1), up one
# (ESC M, reverse index: it would scroll only from the top row) and
# backspace. The attributes are changed only if they differ from the last
# text's ($cur_a). (Text with attributes of its own sets them and puts them
# back to none itself.)
emit() {
  mv="${ESC}[$1;$2H"
  if [ $cur_r -gt 0 ]; then
    dr=$(($1 - cur_r)) dc=$(($2 - cur_c))
    case $dr in
      0) v="" ;;
      -1) v="${ESC}M" ;;
      1) v="${ESC}[B" ;;
      -*) v="${ESC}[${dr#-}A" ;;
      *) v="${ESC}[${dr}B" ;;
    esac
    case $dc in
      0) h="" ;;
      -1) h="$BS" ;;
      1) h="${ESC}[C" ;;
      -*) h="${ESC}[${dc#-}D" ;;
      *) h="${ESC}[${dc}C" ;;
    esac
    [ ${#v} -lt $((${#mv} - ${#h})) ] && mv=$v$h
  fi
  if [ "${5-}" != "$cur_a" ]; then
    if [ -z "${5-}" ]; then
      mv="$mv${ESC}[m"
    elif [ -z "$cur_a" ]; then
      mv="$mv${ESC}[${5}m"
    else
      mv="$mv${ESC}[0;${5}m"
    fi
    cur_a=${5-}
  fi
  out="$out$mv$4"
  cur_r=$1 cur_c=$(($2 + $3))
  # Text that reaches the last column leaves the cursor waiting to wrap,
  # where moves from it differ between terminals
  [ $cur_c -gt $cols ] && cur_r=0
  return 0
}

# Adds $1 to $out, after which where the cursor is isn't known. ($1 must
# end with no attributes set.)
emit_raw() {
  [ -n "$cur_a" ] && out="$out${ESC}[m"
  out="$out$1"
  cur_r=0 cur_a=""
}

# Adds an item to $todo, the layers' changes this frame, one a line (see
# flush_todo): $4 at row $1, column $2, $3 columns wide, in attributes $5
# (the parameters of an ESC[...m, such as 32 for green; none if empty or
# left out).
todo_add() {
  add_item 0 "$@"
}

# As todo_add, for the formation's invaders and for cells to blank. They're
# sent after the rest, as invaders go over the shields. (A blank is never
# where anything else is drawn, so it can go with either.)
top_add() {
  add_item 1 "$@"
}

# Adds an item (row $2, column $3, ...: see todo_add) to $todo, keeping it
# in order: group $1 (0 or 1: see top_add), then row, then column, so the
# cursor mostly runs on from one to the next. Items mostly come in order,
# so it's checked first whether this one goes at the end ($todo_last is
# the last one's key). On a whole formation redrawn, they're just added at
# the end: it's sent row by row anyway.
add_item() {
  key=$(($1 * 1000000 + $2 * 1000 + $3))
  item="$key;$2;$3;$4;${6-} $5$NL"
  if [ $key -ge $todo_last ] || [ $inv_touched -eq 1 ]; then
    todo=$todo$item todo_last=$key
    return
  fi
  before="" rest=$todo
  while [ -n "$rest" ]; do
    q=${rest%%"$NL"*}
    [ ${q%%";"*} -gt $key ] && break
    before="$before$q$NL" rest=${rest#*"$NL"}
  done
  todo=$before$item$rest
}

# As todo_add ($1 "top" for top_add), for a layer drawn on cells a thing
# that moves may be on: the cells are marked ($lay_cov), so such a thing is
# drawn again over it (see changed_pieces).
lay() {
  if [ "$1" = top ]; then
    shift
    top_add "$@"
  else
    todo_add "$@"
  fi
  pc=0
  while [ $pc -lt $3 ]; do
    lay_cov="$lay_cov $1;$(($2 + pc)) "
    pc=$((pc + 1))
  done
}

# Adds the items in $todo to $out (see todo_add).
flush_todo() {
  IFS=$NL
  for p in $todo; do
    unset IFS
    k=${p%% *}; k=${k#*";"}          # (the key is only for keeping order)
    fr=${k%%";"*}; t=${k#*";"}; fc=${t%%";"*}; t=${t#*";"}
    emit $fr $fc ${t%%";"*} "${p#* }" "${t#*";"}"
  done
  unset IFS
  todo="" todo_last=0
}

# Sends $head and then $out, unless there's nothing to send: no changes, no
# bell and no clear. With a line speed set, its cost in bytes comes off
# $credit (see draw).
send_frame() {
  if [ -n "$cur_a" ]; then
    out="$out${ESC}[m" cur_a=""
  fi
  if [ -n "$out" ] || [ "$head" != "$sync_on" ]; then
    out="$head$out$sync_off"
    printf '%s' "$out"
    if [ $baud -gt 0 ]; then
      if [ $ascii -eq 1 ]; then
        n=${#out}
      else
        # Some shells' ${#} counts characters, but in the C locale they're
        # bytes. (The player's own locale setting is put back.)
        lc=${LC_ALL-} lc_set=${LC_ALL+1}
        LC_ALL=C
        n=${#out}
        if [ -n "$lc_set" ]; then LC_ALL=$lc; else unset LC_ALL; fi
      fi
      credit=$((credit - 60 * n))
    fi
  fi
}

draw() {
  # With a line speed set (-b), frames are sent only as fast as the line
  # carries them: $credit grows each frame by what the line carries in a
  # frame's time (as last measured: see pace), and each byte sent costs 60.
  # (In those units a 60th of a second's worth is the line's bytes a
  # second.) While it's below 0, frames aren't sent: their changes all go
  # with the next frame that's sent, as everything is compared with what
  # was last sent.
  # Up to a tenth of a second's credit can be saved up, for bursts.
  if [ $baud -gt 0 ]; then
    credit=$((credit + baud * 6 * frame_us / 1000000))
    [ $credit -gt $((baud * 6 / 10)) ] && credit=$((baud * 6 / 10))
    if [ $credit -lt 0 ] && [ $redraw_all -eq 0 ]; then
      return
    fi
  fi
  if [ $too_small -eq 1 ]; then
    t="Window too small: ${cols}x${rows}, need at least $((field_w + 2))x24. Paused (q quits)."
    if [ "$t" != "$sent_small" ]; then
      printf '%s' "$sync_on${ESC}[H${ESC}[2J$t$sync_off"
      sent_small=$t cur_r=0
    fi
    return
  fi
  inv_touched=0 cleared=0
  if [ $redraw_all -eq 1 ]; then
    # With a line speed set, the scenery is left to send a part a frame
    # (below), so the game itself appears sooner
    if [ $baud -gt 0 ]; then
      head="$sync_on${ESC}[H${ESC}[2J" scenery_todo=$scenery_parts
    else
      head="$sync_on${ESC}[H${ESC}[2J$scenery" scenery_todo=""
    fi
    cleared=1 cur_r=0
    prev_items="" prev_pieces=""
    # Nothing has been sent onto the cleared screen yet
    sent_hud="" sent_ground="" sent_shields=""
    inv_touched=1
    redraw_all=0
  else
    head=$sync_on
  fi
  out="" todo="" todo_last=0 grows="" pieces="" items="" cov="" lay_cov=""
  [ $bell -eq 1 ] && { head="$head$BEL"; bell=0; }

  # Score values under their headings, zero-padded like the arcade's
  # (The scores, and the timing below, are items: see todo_add)
  pad4 $score
  hud="$((hud_row + 1));$sc_x;4; $p4$NL"
  pad4 $hi
  hud="$hud$((hud_row + 1));$((hi_x + 2));4; $p4$NL"
  # Right-justified under WAVE, mirroring the score under SCORE
  hud="$hud$((hud_row + 1));$((wv_x + 4 - ${#wave}));${#wave}; $wave$NL"
  # With F, timing in the window's top-left corner (6 columns are free
  # there at any width). On the first row, how it's pacing (see pace): "f"
  # (fine) and the sleep in ms, or "c", "t" or "b" (cal, tick or busy) and
  # the busy-wait's count; the letter is in upper case if frames are
  # wrapped in synchronized output. On the second, the last measured frame
  # rate and how much the last 8 vary (see fps_stats). Turned off, the same
  # cells are sent as blanks.
  if [ $dbg -eq 1 ]; then
    case $pace_mode in
      fine) t="f $((delay_us / 1000))ms" ;;
      cal) t="c$spin" ;;
      tick) t="t$spin" ;;
      busy) t="b$spin" ;;
    esac
    if [ -n "$sync_on" ]; then
      case $t in
        f*) t="F${t#?}" ;;
        c*) t="C${t#?}" ;;
        t*) t="T${t#?}" ;;
        *) t="B${t#?}" ;;
      esac
    fi
    while [ ${#t} -lt 6 ]; do t="$t "; done
    if [ -n "$dbg_fps" ]; then d="$dbg_fps$g_pm$dbg_sd"; else d="--    "; fi
    hud="${hud}1;1;6; $t${NL}2;1;6; $d$NL"
  else
    hud="${hud}1;1;6;       ${NL}2;1;6;       $NL"
  fi
  # Only the fields that have changed are sent
  if [ "$hud" != "$sent_hud" ]; then
    IFS=$NL
    for p in $hud; do
      unset IFS
      case "$NL$sent_hud" in
        *"$NL$p$NL"*) ;;
        *)
          fr=${p%%";"*}; t=${p#*";"}; fc=${t%%";"*}; t=${t#*";"}
          todo_add $fr $fc ${t%%";"*} "${p#* }" ;;
      esac
    done
    unset IFS
    sent_hud=$hud
  fi

  # Below the ground, as in the arcade: the number of cannons (including
  # the one in play), then a picture of each spare. The number is in
  # reverse video while the ship explodes or a cannon has just been won.
  if [ $mode = play ]; then
    n_txt=$lives
    if [ $boom -gt 0 ] || [ $bonus_flash -gt 0 ]; then
      n_txt="${ESC}[7m$lives${ESC}[0m"
    fi
    spares="" w=${#lives}
    i=1
    while [ $i -lt $lives ]; do
      spares="$spares $g_ship" w=$((w + 4)) i=$((i + 1))
    done
    put $((ground_row + 1)) $((left + 1)) $w "$n_txt$spares"
  fi

  # The ground line, worn by invader shots blowing up on it (whole on the
  # title screen). In play, only the columns that have changed since they
  # were last sent ($sent_gnd_I) are sent.
  if [ $mode = title ]; then
    if [ "$sent_ground" != title ]; then
      todo_add $ground_row $left $field_w "$ground_line" 32
      sent_ground=title
    fi
  elif [ $ground_dirty -eq 1 ] || [ "$sent_ground" != play ]; then
    i=0
    while [ $i -lt $field_w ]; do
      eval "m=\$gnd_$i n=\${sent_gnd_$i-}"
      if [ "$sent_ground" != play ] || [ "$m" != "$n" ]; then
        ground_glyph $i
        todo_add $ground_row $((left + i)) 1 "$g" 32
        eval "sent_gnd_$i=\$m"
      fi
      i=$((i + 1))
    done
    ground_dirty=0 sent_ground=play
  fi
  # A part of the scenery still to send after a full redraw (nothing else
  # is drawn where it goes)
  if [ -n "$scenery_todo" ]; then
    emit_raw "${scenery_todo%%"$NL"*}"
    scenery_todo=${scenery_todo#*"$NL"}
  fi

  # The title screen's text is drawn like the things that move, so only
  # what has typed out since the last frame is sent
  if [ $mode = title ]; then
    draw_title
    flush_todo
    changed_pieces
    send_frame
    return
  fi

  if [ $boom -gt 0 ]; then
    # Two-frame explosion, changing every 5 frames like the arcade's
    if [ $((boom / 5 % 2)) -eq 0 ]; then
      put $ship_row $ship_col 3 '\|/'
    else
      put $ship_row $ship_col 3 '*.*'
    fi
  elif [ $game_over -eq 0 ]; then   # the last cannon stays destroyed
    # One row, like the arcade's: sloping shoulders with a solid point.
    # These characters are in SF Mono (Terminal.app's default font), so
    # nothing is borrowed from another font.
    put $ship_row $ship_col 3 "$g_ship"
  fi

  # Shields (green, like the arcade's screen overlay) change only when hit,
  # so they are re-rendered only then (and sent as below)
  if [ $shields_dirty -eq 1 ]; then
    shield_cov=""
    for s in $shield_cells; do
      qr=${s%%:*}; t=${s#*:}; qc=${t%%:*}
      shield_cov="$shield_cov $qr;$qc "
    done
    shields_dirty=0
  fi

  # The saucer, or once hit its explosion and then its score (in red, like
  # the arcade's top screen overlay). The explosion is a single picture like
  # the arcade's, and as in the arcade it's wider than the saucer: a column
  # more each side (kept inside the borders).
  if [ $saucer_x -ne 0 ]; then
    if [ $saucer_hit -eq 0 ]; then
      put $saucer_row $saucer_x 4 "${ESC}[31;4m$g_saucer${ESC}[0m"
    elif [ $saucer_hit -gt 72 ]; then
      el='-' er='-' tx=$((saucer_x - 1))
      if [ $tx -lt $left ]; then el=""; tx=$left; fi
      [ $((saucer_x + saucer_w)) -gt $right ] && er=""
      put $saucer_row $tx $((4 + ${#el} + ${#er})) \
        "${ESC}[31m$el$g_boom_l**$g_boom_r$er${ESC}[0m"
    else
      txt=$saucer_pts
      tx=$saucer_x
      [ $((tx + ${#txt} - 1)) -gt $right ] && tx=$((right - ${#txt} + 1))
      put $saucer_row $tx ${#txt} "${ESC}[31m$txt${ESC}[0m"
    fi
  fi

  # "GAME OVER", as far as it has typed out once the explosion has finished
  # (see type_game_over). (The text is drawn last.)
  sp=""
  if [ $game_over -eq 1 ] && [ $boom -eq 0 ]; then
    game_over_text
  fi

  # The formation: $inv_frame draws it all and $inv_cov lists its cells.
  # Usually just one invader has moved (or one has gone) since the last
  # frame, so only those changes are drawn: each moved or gone invader's
  # piece is taken out, and each moved one's added and drawn. The cells
  # they leave are blanked below. A new wave or layout rebuilds it all.
  inv_add="" gone_cov=""
  if [ $inv_rebuild -eq 1 ]; then
    gone_cov=${inv_cov-}
    inv_frame="" inv_cov=""
    for inv in $invaders; do
      IFS=:
      set -- $inv
      unset IFS
      eval "g=\$g_inv_$3"
      inv_frame="$inv_frame${ESC}[$1;$2H$g"
      inv_cov="$inv_cov $1;$2  $1;$(($2 + 1)) "
    done
    inv_touched=1
    inv_rebuild=0
  else
    for ev in $inv_events; do
      IFS=:
      set -- ${ev#?}
      unset IFS
      eval "g=\$g_inv_$3"
      piece="${ESC}[$1;$2H$g"
      cells=" $1;$2  $1;$(($2 + 1)) "
      case $ev in
        -*)
          case $inv_frame in
            *"$piece"*)
              # (see move_invaders for why it's cut this way)
              pre=${inv_frame%%"$piece"*}
              inv_frame="$pre${inv_frame#"$pre$piece"}"
              pre=${inv_cov%%"$cells"*}
              inv_cov="$pre${inv_cov#"$pre$cells"}"
              gone_cov="$gone_cov$cells" ;;
          esac ;;
        *)
          inv_frame="$inv_frame$piece"
          inv_cov="$inv_cov$cells"
          inv_add="$inv_add $piece" ;;
      esac
    done
  fi
  inv_events=""

  for b in $bullets; do
    # (¡ is dot first, as the shot leaves the cannon)
    put ${b%:*} ${b#*:} 1 "$g_shot"
  done

  for m in $bombs; do
    IFS=:
    set -- $m
    unset IFS
    bomb_glyph $1 $3
    put $1 $2 1 "$g"
  done

  # Explosions, in the overlay's color where they are. An invader's is 4
  # columns wide like the arcade's 16-pixel starburst, centered on the
  # invader (but kept inside the borders), and a single picture like the
  # arcade's. The arcade's shot explosions are 8 pixels wide (the player's)
  # and 6 (invaders'): each is a single cell here, told apart by its glyph.
  # An invader shot shows as itself until its next turn (see
  # bomb_explodes).
  if [ $inv_boom -gt 0 ]; then
    ir=${inv_boom_at%:*}; ic=$((${inv_boom_at#*:} - 1))
    # Widths by hand: in dash, ${#} counts bytes, and › and ‹ are 3
    el=$g_boom_l em="**" er=$g_boom_r w=4
    if [ $ic -lt $left ]; then el=""; ic=$left; w=$((w - 1)); fi
    if [ $((${inv_boom_at#*:} + 2)) -gt $right ]; then er=""; w=$((w - 1)); fi
    boom_color $ir
    put $ir $ic $w "${bcol}${el}${em}${er}${ESC}[0m"
  fi
  if [ $shot_boom -gt 0 ]; then
    boom_color ${shot_boom_at%:*}
    put ${shot_boom_at%:*} ${shot_boom_at#*:} 1 "$bcol$g_shot_boom${ESC}[0m"
  fi
  for e in $bomb_booms; do
    IFS=:
    set -- $e
    unset IFS
    if [ $4 -eq 4 ]; then
      bomb_glyph $1 $3
      put $1 $2 1 "$g"
    else
      boom_color $1
      put $1 $2 1 "${bcol}*${ESC}[0m"
    fi
  done

  [ -n "$sp" ] && put_grow $go_row $gx ${#sp} "$sp"

  # Blank what moved: cells covered last frame and not this one. Where a
  # moving thing was over an invader or a shield, that invader or shield
  # cell is redrawn instead. (Blanks are never where a layer is drawn, so
  # they can go before or after the layers.)
  inv_redo="" shield_redo=""
  for k in $prev_items; do
    case "$items " in *" $k "*) continue ;; esac
    zr=${k%%";"*}; t=${k#*";"}; zc=${t%";"*}; zw=${t#*";"}
    while [ $zw -gt 0 ]; do
      case $cov in
        *" $zr;$zc "*) ;;
        *)
          case $inv_cov in
            *" $zr;$zc "*) inv_redo="$inv_redo $zr;$zc" ;;
            *)
              case $shield_cov in
                *" $zr;$zc "*) shield_redo="$shield_redo $zr;$zc" ;;
                *) top_add $zr $zc 1 " " ;;
              esac ;;
          esac ;;
      esac
      zc=$((zc + 1)); zw=$((zw - 1))
    done
  done
  prev_items=$items

  # Invaders that moved or went: blank the cells they left that nothing
  # covers now. (A cleared screen has nothing to blank, and after a resize,
  # the cells left are in the old layout.)
  if [ $cleared -eq 0 ]; then
    for z in $gone_cov; do
      case $inv_cov$cov in
        *" $z "*) ;;
        *)
          case $shield_cov in
            *" $z "*) shield_redo="$shield_redo $z" ;;
            *) top_add ${z%";"*} ${z#*";"} 1 " " ;;
          esac ;;
      esac
    done
  fi

  # Shields: all of them on a cleared screen or for a new wave; otherwise
  # just the cells that were hit, or that something has passed over. Shields
  # go under invaders (passing through them), so an invader on a redrawn
  # cell is redrawn too.
  if [ -z "$sent_shields" ] || [ $shields_whole -eq 1 ]; then
    for s in $shield_cells; do
      qr=${s%%:*}; t=${s#*:}; qc=${t%%:*}
      shield_piece $qr $qc
      todo_add $qr $qc 1 "$g" 32
    done
    sent_shields=1 shields_whole=0
    inv_touched=1
  elif [ -n "$shield_changed$shield_redo" ]; then
    for z in $shield_changed $shield_redo; do
      shield_piece ${z%";"*} ${z#*";"}
      lay ${z%";"*} ${z#*";"} 1 "$g" 32
      case $inv_cov in *" $z "*) inv_redo="$inv_redo $z" ;; esac
    done
  fi
  shield_changed=""

  # Invaders: all of them when need be; otherwise just those that moved
  # (and are still there), and any on cells redrawn or passed over
  if [ $inv_touched -eq 1 ]; then
    for inv in $invaders; do
      ir=${inv%%:*}; t=${inv#*:}; ic=${t%%:*}; t=${t#*:}
      eval "g=\$g_inv_${t%%:*}"
      top_add $ir $ic 2 "$g"
    done
  else
    inv_sent=""
    for piece in $inv_add; do
      case $inv_frame in
        *"$piece"*)
          t=${piece#"${ESC}["}; zr=${t%%";"*}; t=${t#*";"}
          lay top $zr ${t%%H*} 2 "${t#*H}"
          inv_sent="$inv_sent $piece " ;;
      esac
    done
    for z in $inv_redo; do
      zr=${z%";"*} zc=${z#*";"}
      # The invader there starts in this column or the one before
      for zc in $zc $((zc - 1)); do
        case $invaders in
          *" $zr:$zc:"*)
            pre=${invaders%%" $zr:$zc:"*}
            t=${invaders#"$pre $zr:$zc:"}
            eval "g=\$g_inv_${t%%:*}"
            piece="${ESC}[$zr;${zc}H$g"
            case $inv_sent in
              *" $piece "*) ;;
              *) lay top $zr $zc 2 "$g"; inv_sent="$inv_sent $piece " ;;
            esac ;;
        esac
      done
    done
  fi

  flush_todo
  changed_pieces
  send_frame
}

# Adds to $out the things that move ($pieces, see put): just those that
# are new or changed, and any under something else drawn this frame (or
# last: a thing that's gone may have been drawn over them). As layers are
# drawn first, a whole formation or shields drawn afresh could be over any
# of them, so then they're all drawn.
changed_pieces() {
  if [ $inv_touched -eq 1 ]; then
    dirty=all
  else
    # The cells drawn by the layers, and those of things new, changed or
    # gone
    dirty=$lay_cov
    dirty_unless_in "$pieces" "$prev_pieces"
    dirty_unless_in "$prev_pieces" "$pieces"
  fi
  IFS=$NL
  for p in $pieces; do
    unset IFS
    k=${p%% *}
    # Most pieces have no dirty cell even in their row: a quick check first
    case $dirty in
      all|*" ${k%%";"*};"*) ;;
      *) continue ;;
    esac
    piece_cells "$k"
    for z in $cells; do
      case $dirty in
        all|*" $z "*)
          fr=${k%%";"*}; t=${k#*";"}; fc=${t%";"*}; fw=${t#*";"}
          text=${p#* }
          [ "$dirty" = all ] || grown
          emit $fr $fc $fw "$text"
          break ;;
      esac
    done
  done
  unset IFS
  prev_pieces=$pieces
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
  # (Not [ -n "$s" ]: some shells' test reads an s of "=" as an operator)
  while [ ${#s} -gt 0 ]; do
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
  # Center the 17 rows of text between the score line and the ground
  avail=$((ground_row - top_row - 1))
  r0=$((top_row + 1 + (avail - 17) / 2))
  [ $r0 -le $top_row ] && r0=$((top_row + 1))

  # Each line: row offset, column ("c" to center), icon (drawn when typing
  # reaches the line), number of leading characters to leave unspaced, text.
  # "|" separates fields. Icons are S for the saucer, an invader's kind
  # (see spawn_wave), or "-" for none. Text is letter-spaced to the
  # arcade's character width, except "#!/bin/sh" in the game's name.
  tx=$((mid_c - 7))   # table text column, leaving room for the icons
  set -- \
    "0|c|-|0|PLAY" \
    "2|c|-|9|#!/bin/sh INVADERS" \
    "5|c|-|0|*SCORE ADVANCE TABLE*" \
    "7|$tx|S|0|= ? MYSTERY" \
    "9|$tx|s|0|= 30 POINTS" \
    "11|$tx|c|0|= 20 POINTS" \
    "13|$tx|o|0|= 10 POINTS"
  # Typing advances a column per frame (a spaced letter every 2 frames, an
  # unspaced one every frame), so the text grows across the screen at a
  # steady pace, as in the arcade where all letters are the same width.
  left_cols=$title_t
  for line in "$@"; do
    [ $left_cols -le 0 ] && break
    # ("|" is quoted: Korn shells read a bare | in a pattern as "or")
    lr=${line%%"|"*}; rest=${line#*"|"}
    lr=$((r0 + lr))
    lc=${rest%%"|"*}; rest=${rest#*"|"}
    icon=${rest%%"|"*}; rest=${rest#*"|"}
    plain=${rest%%"|"*}; text=${rest#*"|"}
    width=$((plain + 2 * (${#text} - plain) - 1))
    [ "$lc" = c ] && lc=$((mid_c - width / 2))
    case $icon in
      S) put $lr $((lc - 6)) 4 "${ESC}[31;4m$g_saucer${ESC}[0m" ;;
      -) ;;
      *) eval "g=\$g_inv_$icon"; put $lr $((lc - 4)) 2 "$g" ;;
    esac
    # Letters shown so far: unspaced ones take 1 column, spaced ones 2
    if [ $left_cols -le $plain ]; then
      n=$left_cols
    else
      n=$((plain + (left_cols - plain + 1) / 2))
    fi
    arcade_text "$text" $n $plain
    put_grow $lr $lc ${#sp} "$sp"
    left_cols=$((left_cols - plain - 2 * (${#text} - plain)))
  done

  arcade_text "PRESS R TO PLAY, Q TO QUIT" 99
  put $((r0 + 16)) $((mid_c - 25)) ${#sp} "$sp"
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

# Sets $now to the clock's seconds, 0-59, or empty if there's no clock.
# date +%S is POSIX; seconds since 1970 (+%s) is a newer addition. The
# leading 0 is dropped, as shell arithmetic would read 08 and 09 as (bad)
# octal.
clock_sec() {
  now=$(date +%S 2>/dev/null) || now=""
  now=${now#0}
  case $now in ''|*[!0-9]*) now="" ;; esac
}

# For the frame-rate display: adds the rate just measured ($frame_us per
# frame, usually over 2 seconds: see pace_measure) to the last 8, and sets
# $dbg_fps to it and $dbg_sd to the 8's standard deviation, padded so
# that "$dbg_fps±$dbg_sd" is 6 columns.
# (There's no sub-second clock, so single frames can't be timed: this is how
# much the measured rates vary.) Rates are in tenths of a frame a second.
fps_stats() {
  fps10=$((10000000 / frame_us))
  set -- $fps10 $fps_hist
  [ $# -gt 8 ] && set -- $1 $2 $3 $4 $5 $6 $7 $8
  fps_hist="$*"
  sum=0
  for v in "$@"; do sum=$((sum + v)); done
  mean=$((sum / $#))
  var=0
  for v in "$@"; do var=$((var + (v - mean) * (v - mean))); done
  var=$((var / $#))
  # Integer square root (Newton's method)
  sd=$var
  if [ $sd -gt 1 ]; then
    sd2=$(( (sd + 1) / 2 ))
    while [ $sd2 -lt $sd ]; do
      sd=$sd2
      sd2=$(( (sd + var / sd) / 2 ))
    done
  fi
  # As "60±0.4": the decimal is dropped if it won't fit in 6 columns
  f=$(( (fps10 + 5) / 10 )); [ $f -gt 999 ] && f=999
  [ $sd -gt 999 ] && sd=999
  t="$((sd / 10)).$((sd % 10))"
  [ $((${#f} + 1 + ${#t})) -gt 6 ] && t=$(( (sd + 5) / 10 ))
  pad=$((6 - ${#f} - 1 - ${#t}))
  dbg_fps=$f dbg_sd=$t
  while [ $pad -gt 0 ]; do dbg_sd="$dbg_sd "; pad=$((pad - 1)); done
}

# Sleeps between frames, keeping the game at 60 fps on any machine. Most of
# a frame is the sleep, and a sleep takes longer than requested: measured on
# a Mac running macOS 27, ~1.6ms to start the sleep program plus ~3-4ms of
# oversleep. Other systems will differ, so the actual frame rate is measured
# and the delay adjusted to suit (see below for how, with a clock that only
# gives seconds).
#
# (POSIX sleep only takes whole seconds: sleeping for a fraction of one is
# the game's one requirement beyond POSIX, and every system has it.)
#
# Some systems sleep in whole clock ticks: a sleep ends on a tick, and lasts
# at least a tick or two whatever is asked (OpenBSD, usually at 100 ticks a
# second, ends even a 0.001s sleep on the second tick after it starts:
# 10-20ms, often longer than a 60 fps frame). The game then
# busy-waits (counts) instead, and where it can, uses the ticks to keep
# exact time. $pace_mode says how it's pacing:
#
#  - fine: sleeping every frame, as above.
#  - cal: sleeps are coarse. Busy-waiting in every frame and not sleeping,
#    trying different counts until near 60 fps. That gives how long a count
#    takes, and how long a frame takes without one (see pace_cal).
#  - tick: if frames take little time without waiting, locked to the ticks.
#    The game sleeps only every third frame, and busy-waits in the others.
#    As a sleep ends on a tick, a cycle of 3 frames lasts a whole number of
#    ticks: exactly 50ms, 3 frames at 60 fps, if the sleep starts 30-40ms
#    into the cycle (it then ends at the tick after next). Anywhere in that
#    10ms slot will do, so the busy-waits needn't be exact, and the frame
#    rate is exactly 60 (see pace_tick).
#  - busy: if frames take too long, or vary too much, for that slot,
#    busy-waiting in every frame, with the count adjusted as the sleep is
#    in fine.
#
# Busy-waiting keeps a processor busy, but only on such systems.
#
# All this needs timing to well under a millisecond, but the only clock
# POSIX sh has is date, which gives whole seconds (clock_sec), and takes a
# millisecond or two to run, so is read only every few frames. No single
# frame is ever timed. Instead:
#
#  - Measuring averages. Counting the frames between one change of the
#    second and the next but one (pace_measure) gives the average frame
#    time over those 2 seconds. Each change is noticed at the first read
#    after it, up to 4 frames late, but so is the next, so of ~120 frames
#    the count is out by at most 4: about 3%.
#  - Feedback. After each measurement, the sleep (or the count) is moved by
#    half the error. One measurement's error is small, and is made up for
#    in the next few, so over time the rate comes out right.
#  - Adding up. Each measurement starts where the last ended, so the frames
#    counted over many of them are out by only the latest end's error,
#    however long the game has run. That's how pace_tick can tell a few
#    cycles 10ms too long (each costs 0.6 of a frame) from that error.
#  - A ruler. Two measurements with different counts give how long a count
#    takes (pace_cal). Busy-waiting is then a sub-second unit of time,
#    measured against the second.
#  - The kernel's clock. Where sleeps end on ticks, the ticks themselves
#    keep exact time: the clock only has to show whether cycles end on the
#    right tick, at 50ms, not 40 or 60. That's a difference of about 20% in
#    the frame rate, easy to see.
pace() {
  pace_frames=$((pace_frames + 1))
  if [ $pace_mode = tick ]; then
    cyc=$((cyc + 1))
    if [ $cyc -lt 3 ]; then
      spin_wait
      return
    fi
    cyc=0
    sleep 0.001
    pace_measure   # (just after a tick, at the same point in every cycle)
    return
  fi
  pace_check=$((pace_check + 1))
  if [ $pace_check -ge 4 ]; then
    pace_check=0
    pace_measure
  fi
  if [ $pace_mode != fine ]; then
    spin_wait
    return
  fi
  # Format microseconds as 0.dddddd without a subshell (delay is < 1s)
  d=$((delay_us + 1000000))
  sleep "0.${d#1}"
}

# Busy-waits: counts down from $spin.
spin_wait() {
  i=$spin
  while [ $i -gt 0 ]; do i=$((i - 1)); done
}

# Reads the clock, and at the end of each measurement ($pace_win seconds),
# adjusts the pacing (see pace).
pace_measure() {
  [ -n "$pace_seen" ] || return 0
  clock_sec
  if [ -z "$now" ] || [ "$now" = "$pace_seen" ]; then
    return 0
  fi
  pace_seen=$now
  # Seconds since the measurement started (the clock wraps at 60)
  secs=$(( (now - ${pace_sec:-$now} + 60) % 60 ))
  if [ -z "$pace_sec" ]; then
    pace_sec=$now        # first second boundary: start measuring
    pace_frames=0
    return
  fi
  [ $secs -ge $pace_win ] || return 0
  frame_us=$((secs * 1000000 / pace_frames))
  fps_stats
  pace_$pace_mode
  pace_sec=$now
  pace_frames=0
}

# Sleeping every frame: adjusts the sleep by half the error, so noise
# doesn't make it hunt, or decides that sleeps are coarse. They are if two
# measurements in a row (so not just a moment when the machine was busy)
# have frames over 10% too long, and:
#  - a frame takes more than a frame's time beyond its sleep, or
#  - sleeping under 3ms, or
#  - sleeping 3ms or more less than in the measurement compared with (the
#    last with frames not too long, or the first) made frames shorter by
#    under a quarter of that.
# While frames stay too long (two measurements in a row, so again not just a
# busy moment) but sleeps aren't suspected of being coarse, the whole error
# is corrected, not half, so that 3ms cut comes after a few measurements.
pace_fine() {
  cut=$((pace_prev_delay - delay_us))
  if [ $((frame_us * 100)) -gt $((target_us * 110)) ]; then
    if [ $((frame_us - delay_us)) -gt $target_us ] ||
       [ $delay_us -lt 3000 ] ||
       { [ $cut -ge 3000 ] &&
         [ $(( (pace_prev_frame - frame_us) * 4)) -lt $cut ]; }
    then
      if [ $pace_coarse -eq 1 ]; then
        # Busy-wait instead, at first for a 1-second measurement, in case
        # the count is far out
        pace_mode=cal pace_win=1 spin=1000 cal_f=""
      else
        # See if the next measurement agrees, without changing anything
        pace_coarse=1
      fi
      return
    fi
    pace_coarse=0
    if [ $pace_prev_frame -eq 0 ] || [ $cut -ge 3000 ]; then
      pace_prev_delay=$delay_us pace_prev_frame=$frame_us
    fi
    if [ $pace_long -eq 1 ]; then
      delay_us=$((delay_us - (frame_us - target_us)))
    else
      delay_us=$((delay_us - (frame_us - target_us) / 2))
    fi
    pace_long=1
  else
    pace_coarse=0 pace_long=0
    pace_prev_delay=$delay_us pace_prev_frame=$frame_us
    delay_us=$((delay_us - (frame_us - target_us) / 2))
  fi
  [ $delay_us -lt 0 ] && delay_us=0
  [ $delay_us -gt 40000 ] && delay_us=40000
}

# After each measurement of busy-waiting in every frame (see pace), works
# out how long a count takes from this measurement and the last, and how
# long a frame takes without one. Then if the frame rate was within 10% of
# 60, goes on to tick or busy, and if not, tries the count that should give
# 60.
pace_cal() {
  # The first measurement, of 1 second, is too rough to compare with: it
  # just gives the count to start from
  if [ $pace_win -eq 1 ]; then
    pace_win=2
    spin=$((spin * target_us / frame_us))
    [ $spin -lt 1 ] && spin=1
    return
  fi
  # (If the count hardly changed, noise would swamp the difference: the
  # last estimate is kept)
  i=$((spin - cal_k)); [ $i -lt 0 ] && i=$((-i))
  if [ -n "$cal_f" ] && [ $((i * 8)) -ge $spin ]; then
    spin_ns=$(( (frame_us - cal_f) * 1000 / (spin - cal_k) ))
  fi
  cal_f=$frame_us cal_k=$spin
  if [ $spin_ns -le 0 ]; then
    # With no estimate yet (or if something else changed the frames'
    # length more), assume the frames took no time but the count. That can
    # only overestimate the count's time, so the next measurement can't be
    # slower than 60. If that's hardly a change (already near 60), try 3/4
    # of the count, so the next measurement gives a measurable difference.
    spin_ns=0
    i=$((spin * target_us / frame_us))
    if [ $(( (spin - i) * 4)) -lt $spin ] &&
       [ $(( (i - spin) * 4)) -lt $spin ]; then
      i=$((spin * 3 / 4))
    fi
    spin=$i
    [ $spin -lt 1 ] && spin=1
    return
  fi
  work_us=$((frame_us - spin * spin_ns / 1000))
  [ $work_us -lt 0 ] && work_us=0
  if [ $(( (frame_us - target_us) * 10)) -gt $target_us ] ||
     [ $(( (target_us - frame_us) * 10)) -gt $target_us ]; then
    spin=$(( (target_us - work_us) * 1000 / spin_ns ))
    [ $spin -lt 1 ] && spin=1
    return
  fi
  # Lock to the ticks only if frames take under 4ms without waiting: 3
  # frames' work then leaves most of a cycle to the busy-waits, which take
  # much the same time every cycle. Frames that take longer also vary more,
  # by more than the 10ms slot over 3 frames (OpenBSD in a VM: 7-12ms).
  if [ $work_us -lt 4000 ]; then
    # Start the sleeps in the middle of the slot, by the estimates
    pace_mode=tick cyc=0 pace_drift=0 pace_bad=0 spin=0
    spin_more $((3 * target_us - 15000 - 3 * work_us))
  else
    pace_mode=busy
  fi
}

# Adds to the busy-wait count, to make the sleep start $1 us later in the
# cycle (or earlier, if negative), but with no frame longer than a 60th of
# a second.
spin_more() {
  spin=$((spin + $1 * 500 / spin_ns))   # (2 frames in a cycle busy-wait)
  i=$(( (target_us - work_us) * 1000 / spin_ns ))
  [ $spin -gt $i ] && spin=$i
  [ $spin -lt 0 ] && spin=0
  pace_quiet=0
}

# Locked to the ticks, after each measurement: if cycles have been too long
# or too short, makes the sleeps start 1.5ms earlier or later. If not, every
# 8 measurements makes them start 0.5ms later, to space the frames more
# evenly. If it keeps needing correcting (in over a third of measurements,
# for a while), frames vary too much for the slot: just busy-wait.
#
# The frames gained or lost on 60 a second are added up over the
# measurements: their ends are only found to within a cycle (3 frames), but
# that error cancels out from one to the next, while cycles of the wrong
# length add up. Frames are counted in whole cycles, so 6 (2 cycles) is more
# than the error.
pace_tick() {
  pace_drift=$((pace_drift + pace_frames - 60 * secs))
  if [ $pace_drift -ge 6 ]; then
    spin_more 1500
  elif [ $pace_drift -le -6 ]; then
    spin_more -1500
  else
    pace_quiet=$((pace_quiet + 1))
    [ $pace_bad -gt 0 ] && pace_bad=$((pace_bad - 1))
    [ $pace_quiet -ge 8 ] && spin_more 500
    return 0
  fi
  pace_drift=0
  pace_bad=$((pace_bad + 2))
  if [ $pace_bad -ge 12 ]; then
    pace_mode=busy
    spin=$(( (target_us - work_us) * 1000 / spin_ns ))
  fi
}

# Busy-waiting in every frame: adjusts the count by half the error, as
# pace_fine does the sleep.
pace_busy() {
  spin=$((spin - (frame_us - target_us) * 500 / spin_ns))
  [ $spin -lt 0 ] && spin=0
}

usage() {
  echo "Usage: $0 [-a] [-b baud]" >&2
  echo "  -a       plain ASCII, without emoji or symbols" >&2
  echo "  -b baud  send no more than a serial line of that speed carries" >&2
  echo "           (for a real terminal on a serial line, say -b 9600);" >&2
  echo "           draws in ASCII, as -a" >&2
  exit 2
}

main() {
  ascii=0   # 1 to draw in ASCII (see set_glyphs)
  baud=0    # the line's speed, to keep within (see draw); 0 for no limit
  while [ $# -gt 0 ]; do
    case $1 in
      -a) ascii=1 ;;
      -b)
        case ${2-} in
          ''|*[!0-9]*) usage ;;
        esac
        # A slow line wants as few bytes as possible: ASCII's characters
        # are 1 each, where symbols are 2 or 3
        baud=$2 ascii=1
        shift ;;
      *) usage ;;
    esac
    shift
  done
  credit=0
  init

  while [ $quit -eq 0 ]; do
    frame=$((frame + 1))
    read_input
    [ $resized -eq 1 ] && handle_resize

    if [ $too_small -eq 1 ]; then
      :   # paused until the window is big enough again
    elif [ $mode = title ]; then
      title_t=$((title_t + 1))
      [ $restart -eq 1 ] && new_game
    elif [ $game_over -eq 1 ] && [ $restart -eq 1 ]; then
      new_game
    elif [ $boom -gt 0 ]; then
      boom=$((boom - 1))
    elif [ $game_over -eq 1 ]; then
      # Type "GAME OVER", pause two seconds, then the title screen
      go_t=$((go_t + 1))
      type_game_over
      if [ $go_t -ge $((9 * go_letter + 120)) ]; then
        mode=title
        redraw_all=1
        title_t=0
      fi
    else
      tick_explosions
      if [ $move -lt 0 ] && [ $ship_col -gt $left ]; then
        ship_col=$((ship_col - 1))
      elif [ $move -gt 0 ] && [ $((ship_col + 2)) -lt $right ]; then
        ship_col=$((ship_col + 1))
      fi
      # One shot on screen at a time, as in the arcade, counting it while it
      # blows up or the invader it hit does
      if [ $fire -eq 1 ] && [ -z "$bullets" ] && [ $shot_boom -eq 0 ] &&
         [ $inv_boom -eq 0 ]; then
        bullets="$((ship_row - 1)):$((ship_col + 1))"
        rowy $((ship_row - 1)); bullet_y=$ry
        shots=$((shots + 1))
      fi

      move_bullets
      check_saucer
      check_shields
      check_collisions
      # The formation stands still while an invader explodes
      if [ $inv_boom -eq 0 ] && move_invaders; then
        # Re-check so a shot can't slip past the invader that just moved
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
      check_bonus
      # As in the arcade (0A3C), play goes on for 48 frames after the last
      # invader is hit, then the next wave starts
      if [ -z "$invaders" ]; then
        wave_wait=$((wave_wait + 1))
        if [ $wave_wait -ge 48 ]; then
          wave=$((wave + 1))
          spawn_wave
        fi
      fi
    fi

    draw
    pace
  done

  exit 0   # the EXIT trap restores the terminal
}

main "$@"
