#!/bin/bash
# screentest.sh — dead/stuck pixel and backlight test.
# Fills the whole panel with solid colours, pixel-exact, by writing to the framebuffer.
# Any key = next colour, q = quit. Look for: black dots on white (dead pixels),
# bright dots on black (stuck pixels), light patches on black (backlight bleed),
# uneven tint or stripes on grey.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"

FB=/dev/fb0
TMP=/tmp/screentest; mkdir -p "$TMP"
SAVED=$(stty -g)
cleanup() {
  printf '\e]R\e[0m\e[?25h'; stty "$SAVED" 2>/dev/null
  command -v setterm >/dev/null && setterm --cursor on 2>/dev/null
  rm -rf "$TMP"; clear
}
trap cleanup EXIT
trap 'exit' INT TERM
stty -echo
printf '\e[?25l'
command -v setterm >/dev/null && setterm --cursor off --blank 0 2>/dev/null

# name : pixel bytes in framebuffer order (B G R X) : console fallback colour index : rgb for palette
COLORS=(
  "WHITE  - look for black/dark dots (dead pixels):ff ff ff 00:7:ffffff"
  "BLACK  - look for bright dots (stuck pixels) and light patches at the edges (backlight bleed):00 00 00 00:0:000000"
  "RED    - dots of another colour = stuck subpixel:00 00 ff 00:1:ff0000"
  "GREEN:00 ff 00 00:2:00ff00"
  "BLUE:ff 00 00 00:4:0000ff"
  "GREY 50% - uneven tint, stripes, pressure marks:80 80 80 00:7:808080"
)

use_fb=0
if [ -w "$FB" ] && [ -r /sys/class/graphics/fb0/stride ]; then
  bpp=$(cat /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null)
  stride=$(cat /sys/class/graphics/fb0/stride)
  h=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size 2>/dev/null)
  [ "$bpp" = 32 ] && [ -n "$h" ] && use_fb=1
fi

fill_fb() {  # $1 = "bb gg rr xx" -> whole framebuffer
  local f="$TMP/px" total=$(( stride * h )) size=4
  printf "$(echo "$1" | sed 's/\([0-9a-f][0-9a-f]\)/\\x\1/g; s/ //g')" > "$f"
  while [ $size -lt $total ]; do cat "$f" "$f" > "$f.2"; mv "$f.2" "$f"; size=$(( size * 2 )); done
  head -c "$total" "$f" > "$FB" 2>/dev/null
}
fill_console() {  # fallback: console background via redefined palette entry
  local idx=$1 rgb=$2
  printf '\e]P%x%s' "$idx" "$rgb"          # set palette colour idx to exact rgb
  printf '\e[0;4%dm\e[2J\e[H' "$idx"       # background idx, clear whole screen
}

clear
cat <<'EOF'

  SCREEN TEST - the whole screen will be filled with one colour at a time:

    WHITE  -> look for black or dark dots            (dead pixels)
    BLACK  -> look for bright dots                   (stuck pixels)
              and light patches near the edges       (backlight bleed)
    RED / GREEN / BLUE -> dots of a different colour (stuck sub-pixels)
    GREY   -> uneven tint, stripes, pressure marks, yellow spots

  Any key = next colour,  Q / Esc = stop.     Press any key to start...
EOF
read -rsn1 _

i=0
for c in "${COLORS[@]}"; do
  IFS=: read -r name px idx rgb <<< "$c"
  if [ $use_fb = 1 ]; then fill_fb "$px"; else fill_console "$idx" "$rgb"; fi
  i=$((i+1))
  getkey
  [ "$KEY" = q ] && break
done

printf '\e]R\e[0m'; clear
echo
echo "  Screen test finished. What did you see? Press every number that applies, then Enter."
echo
D=( "" "dead pixels (dark dots on white)" "stuck pixels (bright dots on black)" "backlight bleed (light patches on black)" \
    "lines or stripes" "uneven tint / spots / pressure marks" "other - type a note" )
for n in 1 2 3 4 5 6; do printf '    %s %d %s  %s\n' "$KEYC" $n "$KEYN" "${D[$n]}"; done
keybar 1-6 "Toggle a defect" Enter "Done (nothing pressed = no defects)"
sel=""
while :; do
  getkey
  case $KEY in
    [1-6]) case " $sel " in *" $KEY "*) sel=$(echo " $sel " | sed "s/ $KEY / /; s/^ *//; s/ *$//") ;; *) sel="$sel $KEY" ;; esac
           printf '\r  Selected: %s\e[K' "$(for n in $sel; do printf '%s; ' "${D[$n]%% (*}"; done)" ;;
    "") break ;;
  esac
done
echo
note=""
for n in $sel; do
  if [ "$n" = 6 ]; then stty echo 2>/dev/null; read -r -p "  Note: " o; [ -n "$o" ] && note="$note${note:+, }$o"
  else note="$note${note:+, }${D[$n]%% (*}"; fi
done
res="Screen test: ${note:-no defects noted}"
echo "  $res"
echo "$res" >> /tmp/hwcheck.txt
sleep 1
