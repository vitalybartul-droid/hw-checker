# ui.sh — shared helpers for all hwcheck screens (sourced, not run).
# One look and one set of rules everywhere:
#   yellow key chips at the bottom, single keys (no Enter to confirm a choice),
#   Q or Esc = back, Enter = the default action, digits 1-9 = pick from a list,
#   Y = confirm something risky.

KEYC=$'\e[0;30;43m'; KEYN=$'\e[0m'           # not bold: bold black is grey on the Linux console

title() { printf '\n  \e[1;36m=============== %s ===============\e[0m\n\n' "$1"; }

# keybar KEY LABEL [KEY LABEL ...]  -> one row of key chips
keybar() {
  local out=""
  while [ $# -ge 2 ]; do out="$out $KEYC $1 $KEYN $2  "; shift 2; done
  printf '\n%s\n' "$out"
}

# getkey -> KEY: one keypress, lower-cased. Enter = "", Esc = "q".
# Arrow/function keys (Esc + sequence) become "?" so they never act as "back".
getkey() {
  KEY=""
  IFS= read -rsn1 KEY || { KEY=q; return; }
  if [ "$KEY" = $'\e' ]; then
    local rest=""
    IFS= read -rsn5 -t 0.05 rest
    if [ -n "$rest" ]; then KEY="?"; else KEY=q; fi
  fi
  KEY=${KEY,,}
}

pause() { printf '\n  Press any key to return...'; IFS= read -rsn1 _; echo; }

# The live stick we booted from: never offered as a disk to test or rescue.
BOOTDISK=$(lsblk -npo PKNAME "$(findmnt -no SOURCE /run/live/medium 2>/dev/null)" 2>/dev/null | head -1)

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
