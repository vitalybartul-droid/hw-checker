# ui.sh — shared helpers for all hwcheck screens (sourced, not run).
# One look and one set of rules everywhere:
#   coloured key chips (B in the main menu changes the colours) at the bottom, single keys (no Enter to confirm a choice),
#   Q or Esc = back, Enter = the default action, digits 1-9 = pick from a list,
#   Y = confirm something risky.

# Key chip colours. Some screens show black-on-orange badly, so B (main menu) cycles the schemes;
# the choice is kept in /tmp for the session and every screen sources this file.
# Linux console: bold = bright foreground; "1;7;33" (bold + reverse) = BRIGHT yellow background.
KEYSCHEMES=($'\e[0;1;37;44m' $'\e[0;1;37;43m' $'\e[0;1;7;37m')
KEYNAMES=("white on blue" "white on orange" "black on white")
KEYIDX=$(cat /tmp/.hwcheck-keys 2>/dev/null); [[ $KEYIDX =~ ^[0-2]$ ]] || KEYIDX=0
KEYC=${KEYSCHEMES[$KEYIDX]}; KEYN=$'\e[0m'
next_keys() {                                   # cycle to the next scheme and remember it
  KEYIDX=$(( (KEYIDX + 1) % ${#KEYSCHEMES[@]} )); echo "$KEYIDX" > /tmp/.hwcheck-keys 2>/dev/null
  KEYC=${KEYSCHEMES[$KEYIDX]}
}

title() { printf '\n  \e[1;36m=============== %s ===============\e[0m\n\n' "$1"; }

# keybar KEY LABEL [KEY LABEL ...]  -> one row of key chips
keybar() {
  local out=""
  while [ $# -ge 2 ]; do out="$out $KEYC $1 $KEYN $2  "; shift 2; done
  printf '\n%s\n' "$out"
}

# getkey -> KEY: one keypress, lower-cased. Enter = "", Esc = "q".
# Arrow / page keys arrive as Esc + a sequence: they become "up", "down", "pgup", "pgdn"
# (other function keys "?"), so their letters ([A [B [C [D) never act as keys of their own.
getkey() {
  KEY=""
  IFS= read -rsn1 KEY || { KEY=q; return; }
  if [ "$KEY" = $'\e' ]; then
    local rest="" c
    # read the sequence one char at a time up to its final letter/~, so two quick arrow presses
    # are never merged into one
    if IFS= read -rsn1 -t 0.05 c; then
      rest=$c
      if [ "$c" = "[" ] || [ "$c" = "O" ]; then
        while IFS= read -rsn1 -t 0.05 c; do rest+=$c; [[ $c == [A-Za-z~] ]] && break; done
      fi
    fi
    case $rest in
      "")          KEY=q ;;
      "[A"|"OA")   KEY=up ;;
      "[B"|"OB")   KEY=down ;;
      "[5~")       KEY=pgup ;;
      "[6~")       KEY=pgdn ;;
      *)           KEY="?" ;;
    esac
    return
  fi
  KEY=${KEY,,}
}

pause() { printf '\n  Press any key to return...'; IFS= read -rsn1 _; echo; }

# The live stick we booted from: never offered as a disk to test or rescue.
# lsblk -s walks from the mounted medium down to the whole device: stick partition -> stick,
# Ventoy (device-mapper over a partition) -> stick, CD/ISO in a VM -> sr0.
BOOTSRC=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
BOOTDISK=""
[ -n "$BOOTSRC" ] && BOOTDISK=$(lsblk -lnspo NAME,TYPE "$BOOTSRC" 2>/dev/null | awk '$2=="disk"||$2=="rom"{d=$1} END{print d}')

# target_ok DEV — gate for the screens that WRITE to a disk (Erase, Remap, Refresh).
# Fail-closed: if we cannot tell which disk is the ViCheck stick, nothing is written anywhere.
# (HWC_TEST=1 skips only the "stick unknown" check - for development on loop disks, never set on the stick.)
target_ok() {
  local d=$1 p
  if [ -z "$BOOTDISK" ] && [ "$HWC_TEST" != 1 ]; then
    printf '  \e[1;31mCannot tell which disk is the ViCheck stick - refusing to write to any disk.\e[0m\n'
    echo "  (Was the stick pulled out, or started in an unusual way?) Reboot from the stick and try again."
    return 1
  fi
  if [ "$d" = "$BOOTDISK" ]; then echo "  This is the ViCheck stick - refusing."; return 1; fi
  # the running system itself must not live on this disk
  for p in /run/live/medium /run/live/persistence; do
    findmnt -no SOURCE "$p" 2>/dev/null | grep -q . || continue
    lsblk -lnspo NAME "$(findmnt -no SOURCE "$p")" 2>/dev/null | grep -qx "$d" && { echo "  The live system runs from this disk - refusing."; return 1; }
  done
  return 0
}

# pick_disk "question" -> DISK=/dev/xxx ; return 1 = cancelled / no disk.
# One disk: picked silently. Several: one digit, no Enter.
pick_disk() {
  local list=() d i
  while read -r d; do
    [ "$d" = "$BOOTDISK" ] && continue
    case $d in */zram*|*/ram*|*/loop*|*/sr*) continue ;; esac
    list+=("$d")
  done < <(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}')
  if [ ${#list[@]} -eq 0 ]; then echo "  No disks found (the boot stick is not counted)."; pause; return 1; fi
  if [ ${#list[@]} -eq 1 ]; then DISK=${list[0]}; return 0; fi
  echo "  $1"; echo
  i=1
  for d in "${list[@]}"; do
    printf '    %s %d %s  %-14s %8s  %s\n' "$KEYC" $i "$KEYN" "$d" "$(lsblk -dno SIZE "$d" | xargs)" "$(lsblk -dno MODEL,TRAN "$d" | xargs)"
    i=$((i+1)); [ $i -gt 9 ] && break
  done
  keybar 1-$(( ${#list[@]} > 9 ? 9 : ${#list[@]} )) "Disk" Q Back
  while :; do
    getkey
    case $KEY in
      q) return 1 ;;
      [1-9]) [ "$KEY" -le ${#list[@]} ] && { DISK=${list[$((KEY-1))]}; return 0; } ;;
    esac
  done
}

# Many USB-SATA adapters answer SMART only with "-d sat": find what works for this disk.
SMARTD=""
smart_detect() {
  local o
  for o in "" "-d sat" "-d sat,12" "-d usbjmicron" "-d usbcypress" "-d usbsunplus"; do
    smartctl $o -A "$1" 2>/dev/null | grep -qE 'ID#|Percentage Used' && { SMARTD=$o; return 0; }
  done
  SMARTD=""; return 1
}

# SMART health in one line — NVMe and SATA report it with different fields.
smart_line() {
  local a; a=$(smartctl $SMARTD -A "$1" 2>/dev/null)
  if echo "$a" | grep -q 'Percentage Used'; then
    echo "$a" | awk -F: '
      /Percentage Used/{gsub(/[ %]/,"",$2); u=$2}
      /Available Spare:/{gsub(/[ %]/,"",$2); s=$2}
      /Media and Data Integrity Errors/{gsub(/ /,"",$2); m=$2}
      /Critical Warning/{gsub(/ /,"",$2); w=$2}
      /Error Information Log Entries/{gsub(/[ ,]/,"",$2); e=$2}
      END{printf "wear=%s%% spare=%s%% media_errors=%s err_log=%s warning=%s", u!=""?u:"?", s!=""?s:"?", m!=""?m:"?", e!=""?e:"?", w!=""?w:"?"}'
  elif [ -n "$a" ]; then
    echo "$a" | awk '
      $2=="Reallocated_Sector_Ct"{r=$10} $2=="Current_Pending_Sector"{p=$10} $2=="Offline_Uncorrectable"{u=$10}
      $2=="UDMA_CRC_Error_Count"{c=$10} $2=="Power_On_Hours"{h=$10}
      END{printf "realloc=%s pending=%s uncorr=%s cable_crc=%s%s", r!=""?r:"n/a", p!=""?p:"n/a", u!=""?u:"n/a", c!=""?c:"n/a", h!=""?"  hours="h:""}'
  else
    echo "not available (USB bridge without SMART?)"
  fi
}

temp_now() {
  smartctl $SMARTD -A "$1" 2>/dev/null | awk '
    /^Temperature:/{print $2; exit}
    /Temperature_Celsius|Airflow_Temperature_Cel/{print $10; exit}' | grep -oE '^[0-9]+' | head -1
}

# Error counters as name=value lines (for "did it grow during the test?")
smart_vals() {
  local a; a=$(smartctl $SMARTD -A "$1" 2>/dev/null)
  echo "$a" | awk -F: '/Media and Data Integrity Errors/{gsub(/[ ,]/,"",$2); print "media_errors="$2}
                       /Error Information Log Entries/{gsub(/[ ,]/,"",$2); print "err_log="$2}'
  echo "$a" | awk '$2=="Reallocated_Sector_Ct"{print "realloc="$10} $2=="Current_Pending_Sector"{print "pending="$10}
                   $2=="Offline_Uncorrectable"{print "uncorr="$10} $2=="UDMA_CRC_Error_Count"{print "cable_crc="$10}'
}

# disk_id DEV -> "model serial bytes": tells a disk apart from the next one plugged in as the same /dev/sdX
disk_id() { echo "$(lsblk -dno MODEL,SERIAL "$1" 2>/dev/null | xargs) $(blockdev --getsize64 "$1" 2>/dev/null)"; }
# scan_is_this_disk DEV: the slow/bad lists in /tmp/scan-<name>.* were made on this very disk
scan_is_this_disk() { local f=/tmp/scan-$(basename "$1").id; [ -s "$f" ] && [ "$(cat "$f")" = "$(disk_id "$1")" ]; }

# Append one test result to the report, under its own TEST RESULTS section
# (otherwise results would appear glued to the last hardware section, BATTERY).
report_add() {
  local f=/tmp/hwcheck.txt
  grep -q '^=* TEST RESULTS =*$' "$f" 2>/dev/null || printf '\n================ TEST RESULTS ================\n' >> "$f"
  echo "$1" >> "$f"
}
