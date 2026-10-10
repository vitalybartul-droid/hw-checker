#!/bin/bash
# kbdtest.sh — keyboard test for the Linux text console.
# Reads key events straight from /dev/input, so it sees every key
# (including F-keys, Win, Menu, media/brightness hotkeys), not just "typed" characters.
# Yellow = key is held now, green = key worked. Exit: press Esc 3 times in a row.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"

# The console we run on (explicit, so mode changes and restore hit the same VT)
CON=/dev/tty$(fgconsole 2>/dev/null || echo 1)

# Put the console keyboard back to normal (UTF-8) mode and verify it.
kbd_restore() {
  command -v kbd_mode >/dev/null || return 0
  local i
  for i in 1 2 3; do
    kbd_mode -f -u -C "$CON" 2>/dev/null || kbd_mode -u -C "$CON" 2>/dev/null
    kbd_mode -C "$CON" 2>/dev/null | grep -qiE 'unicode|utf' && return 0
    sleep 0.2
  done
  kbd_mode -f -a -C "$CON" 2>/dev/null || kbd_mode -a -C "$CON" 2>/dev/null   # at least plain ASCII
}

# Don't let the power button / lid / sleep keys act while we test them.
# Not "exec": this outer copy restores the keyboard again after the test, whatever happened inside.
if [ "$1" != "--inhibited" ] && command -v systemd-inhibit >/dev/null; then
  systemd-inhibit --what=handle-power-key:handle-suspend-key:handle-hibernate-key:handle-lid-switch \
       --who=kbdtest --why="keyboard test" bash "$0" --inhibited
  rc=$?
  kbd_restore; stty sane 2>/dev/null
  exit $rc
fi

# ---- Keyboard input devices (everything with a "kbd" handler) ----
devs=""
while read -r line; do
  case $line in
    "H: Handlers="*kbd*)
      for w in $line; do case $w in event*) devs="$devs /dev/input/$w" ;; esac; done ;;
  esac
done < /proc/bus/input/devices
[ -z "$devs" ] && { echo "No keyboard devices found in /proc/bus/input/devices"; exit 1; }

# ---- Layout: "linux_keycode:label" ('_' in a label is shown as a space) ----
R0=( '1:Esc' '59:F1' '60:F2' '61:F3' '62:F4' '63:F5' '64:F6' '65:F7' '66:F8' '67:F9' '68:F10' '87:F11' '88:F12' '99:PrtSc' '110:Ins' '111:Del' )
R1=( '41:`' '2:1' '3:2' '4:3' '5:4' '6:5' '7:6' '8:7' '9:8' '10:9' '11:0' '12:-' '13:=' '14:Bksp' '102:Home' )
R2=( '15:Tab' '16:Q' '17:W' '18:E' '19:R' '20:T' '21:Y' '22:U' '23:I' '24:O' '25:P' '26:[' '27:]' '43:\' '104:PgUp' )
R3=( '58:Caps' '30:A' '31:S' '32:D' '33:F' '34:G' '35:H' '36:J' '37:K' '38:L' '39:;' "40:'" '28:Enter' '109:PgDn' )
R4=( '42:Shift' '86:<>' '44:Z' '45:X' '46:C' '47:V' '48:B' '49:N' '50:M' '51:,' '52:.' '53:/' '54:Shift' '103:Up' '107:End' )
R5=( '29:Ctrl' '125:Win' '56:Alt' '57:____Space____' '100:AltGr' '127:Menu' '97:Ctrl' '105:Left' '108:Down' '106:Right' )
N0=( '69:Num' '98:/' '55:*' '74:-' )
N1=( '71:7' '72:8' '73:9' '78:+' )
N2=( '75:4' '76:5' '77:6' )
N3=( '79:1' '80:2' '81:3' '96:Ent' )
N4=( '82:0__' '83:.' )

declare -A POS LBL DONE OTHER
TOP=3
place_row() {  # $1 = y, $2 = x start, rest = keys ; sets ROWEND
  local y=$1 x=$2 k c l; shift 2
  for k in "$@"; do
    c=${k%%:*}; l=${k#*:}
    POS[$c]="$y $x"; LBL[$c]="$l"
    x=$(( x + ${#l} + 3 ))
  done
  ROWEND=$x
}
maxx=0; i=0
for r in R0 R1 R2 R3 R4 R5; do
  eval "place_row $((TOP + i*2)) 2 \"\${$r[@]}\""
  [ $ROWEND -gt $maxx ] && maxx=$ROWEND
  i=$((i+1))
done
# ---- Font: the largest Terminus size at which the whole layout still fits ----
# (on HiDPI panels the default console font makes the key labels tiny)
FONTDIR=/usr/share/consolefonts
KFONT_SAVED=""
NEED_ROWS=$(( TOP + 13 + 5 ))                    # layout + status lines
if [ -t 1 ] && command -v setfont >/dev/null && [ -r /sys/class/graphics/fb0/virtual_size ]; then
  IFS=, read -r scr_w scr_h < /sys/class/graphics/fb0/virtual_size
  best=""; best_np=""
  for f in $(ls "$FONTDIR"/Uni2-TerminusBold*.psf.gz 2>/dev/null | sed -E 's/.*TerminusBold([0-9x]+)\.psf\.gz/\1/' | sort -t x -k1,1n); do
    fh=${f%%x*}; case $f in *x*) fw=${f#*x} ;; *) fw=8 ;; esac   # "16" = 8x16, "28x14" = 14 wide
    [ $(( scr_h / fh )) -ge $NEED_ROWS ] || continue
    [ $(( scr_w / fw )) -ge $(( maxx + 30 )) ] && best_np=$f         # fits with the numpad
    [ $(( scr_w / fw )) -ge $(( maxx + 2 )) ]  && best=$f            # fits without it
  done
  f=${best_np:-$best}                            # prefer showing the numpad over a bigger font
  if [ -n "$f" ] && setfont -O /tmp/.kbdtest_font 2>/dev/null; then
    KFONT_SAVED=1
    setfont "$FONTDIR/Uni2-TerminusBold$f.psf.gz" 2>/dev/null
  fi
fi

COLS=$(tput cols 2>/dev/null || echo 80)
if [ $(( maxx + 30 )) -le "$COLS" ]; then      # numpad only if the screen is wide enough
  i=1
  for r in N0 N1 N2 N3 N4; do
    eval "place_row $((TOP + i*2)) $((maxx + 3)) \"\${$r[@]}\""
    i=$((i+1))
  done
fi
STATUS=$(( TOP + 13 ))
TOTAL=${#POS[@]}

keyname() {  # names for keys outside the drawn layout
  case $1 in
    70) echo ScrollLock ;; 119) echo Pause ;; 113) echo Mute ;; 114) echo Vol- ;; 115) echo Vol+ ;;
    224) echo Bright- ;; 225) echo Bright+ ;; 227) echo Display ;; 247) echo Airplane ;; 248) echo MicMute ;;
    190) echo MicMute\(F20\) ;; 163) echo Next ;; 164) echo Play ;; 165) echo Prev ;; 166) echo Stop ;;
    116) echo Power ;; 142) echo Sleep ;; 152) echo ScreenLock ;; 158) echo Back ;; 172) echo HomePage ;;
    217) echo Search ;; 228) echo KbdLight ;; 229) echo KbdLight- ;; 230) echo KbdLight+ ;;
    148) echo Prog1 ;; 149) echo Prog2 ;; 202) echo Prog3 ;; 203) echo Prog4 ;; 212) echo Camera ;;
    237) echo Bluetooth ;; 238) echo WLAN ;; 240) echo Unknown ;; 464) echo Fn ;; 465) echo Fn+Esc ;;
    *) echo "code$1" ;;
  esac
}

draw() {  # $1 = code, $2 = 0 untested / 1 ok / 2 held
  local p=${POS[$1]} y x l
  [ -n "$p" ] || return 1
  y=${p% *}; x=${p#* }; l=${LBL[$1]//_/ }
  tput cup "$y" "$x"
  case $2 in
    0) printf '[%s]' "$l" ;;
    1) printf '\e[30;42m[%s]\e[0m' "$l" ;;
    2) printf '\e[30;43m[%s]\e[0m' "$l" ;;
  esac
}
status() {
  local o="" c
  for c in "${!OTHER[@]}"; do o="$o $(keyname "$c")"; done
  tput cup $STATUS 2;       printf 'Tested: %d of %d keys on the layout\e[K' "${#DONE[@]}" "$TOTAL"
  tput cup $((STATUS+1)) 2; printf 'Last  : %s\e[K' "$LAST"
  tput cup $((STATUS+2)) 2; printf 'Other keys:%s\e[K' "${o:- (none yet: try Fn+F-keys, brightness, volume)}"
}

# ---- Terminal setup / restore ----
SAVED=$(stty -g)
cleanup() {
  pkill -f 'od -An -v -tu2 -w24 /dev/input/' 2>/dev/null
  kbd_restore
  stty "$SAVED" 2>/dev/null || stty sane
  while read -r -s -t 0.1 -n 256 _; do :; done   # drop the keystrokes that piled up
  printf '\e[0m'; tput cnorm
  tput cup $((STATUS+4)) 0
  [ -n "$KFONT_SAVED" ] && setfont /tmp/.kbdtest_font 2>/dev/null   # back to the report's font size
}
trap cleanup EXIT
trap 'exit' INT TERM
stty -icanon -echo -isig -ixon -icrnl
# keycode mode: Alt+F1..F12, Ctrl+Alt+Del etc. no longer act on the console during the test
command -v kbd_mode >/dev/null && { kbd_mode -f -k -C "$CON" 2>/dev/null || kbd_mode -k -C "$CON" 2>/dev/null; }
tput civis; clear
tput cup 0 2; printf 'KEYBOARD TEST   yellow = held, green = OK.   Exit: press Esc 3 times.   (Fn alone sends no code)'
for c in "${!POS[@]}"; do draw "$c" 0; done
LAST="-"; status

# ---- Event loop: struct input_event on amd64 = 24 bytes = 12 x u16 ----
# fields: [0..7] time, [8] type, [9] code, [10..11] value (1 press, 0 release, 2 repeat)
esc=0
while read -r -a f; do
  [ "${f[8]}" = 1 ] || continue
  c=${f[9]}; v=${f[10]}
  case $v in
    1)
      if [ -n "${POS[$c]}" ]; then draw "$c" 2; LAST="${LBL[$c]//_/ } (code $c)"
      else OTHER[$c]=1; LAST="$(keyname "$c") (code $c)"; fi
      if [ "$c" = 1 ]; then esc=$((esc+1)); [ $esc -ge 3 ] && break; else esc=0; fi
      status ;;
    0)
      if [ -n "${POS[$c]}" ]; then draw "$c" 1; DONE[$c]=1; status; fi ;;
  esac
done < <(for d in $devs; do stdbuf -o0 od -An -v -tu2 -w24 "$d" & done; wait)

# Summary (shown after the keyboard is back to normal)
miss=""
for c in "${!POS[@]}"; do [ -z "${DONE[$c]}" ] && miss="$miss ${LBL[$c]//_/}"; done
other=""
for c in "${!OTHER[@]}"; do other="$other $(keyname "$c")"; done
cleanup; trap - EXIT
if command -v kbd_mode >/dev/null && ! kbd_mode -C "$CON" 2>/dev/null | grep -qiE 'unicode|utf|ascii|xlate'; then
  echo "!!! Keyboard is still in test mode. Press Alt+PrtSc+R (SysRq R) or the power button."
fi
echo
echo "Keyboard test: ${#DONE[@]} of $TOTAL layout keys OK."
[ -n "$miss" ]  && echo "Not pressed (absent on this model, or faulty):$miss"
[ -n "$other" ] && echo "Extra keys seen:$other"
r="Keyboard test: ${#DONE[@]} of $TOTAL layout keys OK"
[ -n "$miss" ] && r="$r; not pressed:$miss"
report_add "$r"
read -r -s -n 1 -p "Press any key to return..." _
echo
