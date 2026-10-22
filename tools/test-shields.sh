#!/bin/sh
# Unit checks for shield capacity and the damage each hit does.
#
# The functions are taken from the game itself, so the test can't drift from
# them. The shield's shape and place are fixed here, as build_scenery lays
# them out at the standard height.

here=$(dirname "$0")
game=$here/../sh_invaders.sh

eval "$(sed -n \
  -e '/^reset_shields() {/,/^}$/p' \
  -e '/^damage_shield() {/,/^}$/p' \
  -e '/^damage_cell() {/,/^}$/p' "$game")"

shield_top=20
shield_bot=21
shield_cells=""
for c in 1 2 3 4 5 6; do
  k=B
  [ $c -eq 1 ] && k=L
  [ $c -eq 6 ] && k=R
  shield_cells="$shield_cells 20:$c:$k"
done
shield_cells="$shield_cells 21:1:B 21:2:B 21:5:B 21:6:B"

fail=0
check() {   # label expected actual
  if [ "$2" = "$3" ]; then
    echo "ok   $1: $3"
  else
    echo "FAIL $1: $3 (expected $2)"
    fail=1
  fi
}

reset_shields
tot=0
for s in $shield_cells; do
  IFS=:
  set -- $s
  unset IFS
  eval "tot=$((tot + sh_$1_$2))"
done
check 'capacity total' 29400 $tot

# (row, column, shot: p the player's, b an invader's, total damage)
for hit in "20 4 p 2922" "20 4 b 2221" "21 1 b 2491" \
           "20 1 p 1852" "20 1 b 1523"; do
  set -- $hit
  hr=$1 hc=$2 hs=$3 want=$4
  reset_shields
  damage_shield $hr $hc $hs
  t=0
  for s in $shield_cells; do
    IFS=:
    set -- $s
    unset IFS
    eval "h=\$sh_$1_$2 shc=\$shc_$1_$2"
    t=$((t + shc - h))
  done
  check "hit $hr $hc $hs" $want $t
done

reset_shields
if damage_shield 19 4 p; then
  echo "FAIL hit outside the shield: returned 0"
  fail=1
else
  echo "ok   hit outside the shield: no shield there"
fi

exit $fail
