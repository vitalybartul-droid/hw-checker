#!/bin/bash
# erase.sh DEV — ERASE a disk before it is sold or reused (key E on the Disks screen).
# THE ONLY DESTRUCTIVE SCREEN. Three methods, offered by disk type:
#   1 Quick      - partition table + filesystem signatures removed; SSD: TRIM of the whole disk.
#                  Seconds. On an HDD the old data stays physically on the platters.
#   2 Secure     - the drive erases itself, incl. spare areas we cannot reach from outside.
#                  NVMe: Format with (crypto) erase, seconds. SATA: ATA Secure Erase (SSD minutes,
#                  HDD hours). Internal disks only: USB adapters do not pass these commands and an
#                  interrupted Secure Erase behind an adapter can leave the drive locked.
#   3 Overwrite  - zeros over every sector (HDD: ~2-3 h per TB). Weak sectors get reallocated.
# Safety: the boot stick is never offered (pick_disk), partitions + labels are shown first,
# then Y and the last 4 characters of the serial number must be typed.
# Proof: 64 sample points are fingerprinted before and checked after; result goes to the report.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"
have() { command -v "$1" >/dev/null 2>&1; }

dev=$1
[ -b "$dev" ] || { echo "  No such disk: $dev"; pause; exit 1; }
[ "$dev" = "$BOOTDISK" ] && { echo "  This is the boot stick - refusing."; pause; exit 1; }
sz=$(blockdev --getsize64 "$dev" 2>/dev/null)
model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs)
serial=$(lsblk -dno SERIAL "$dev" 2>/dev/null | xargs)
TRAN=$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ')
ROT=$(cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null)
gb=$(( sz / 1000000000 ))
if [ "$TRAN" = nvme ]; then KIND="NVMe SSD"; elif [ "$ROT" = 1 ]; then KIND="HDD"; else KIND="SSD"; fi
[ "$TRAN" = usb ] && KIND="$KIND via USB"

# ---------- before / after fingerprint of 64 points spread over the disk ----------
SAMPLES=64
fingerprint() {                                 # -> one line per point: "<md5>" or "ZERO" or "ERR"
  local n mb=$(( sz / 1048576 )) off
  for n in $(seq 0 $(( SAMPLES - 1 ))); do
    off=$(( (mb - 1) * n / (SAMPLES - 1) ))
    dd if="$dev" bs=1M count=1 skip=$off iflag=direct status=none 2>/dev/null \
      | { h=$(md5sum | cut -d' ' -f1)
          case $h in b6d81b360a5672d80c27430f39153e2c) echo ZERO ;; d41d8cd98f00b204e9800998ecf8427e) echo ERR ;; *) echo "$h" ;; esac; }
  done
}
# compare: changed = had data, now different; empty = zeros before and after;
# same = old data still there; unread = cannot be read after the erase
compare_fp() {
  paste -d' ' "$1" "$2" | awk '{ if ($2=="ERR") u++; else if ($1=="ZERO" && $2=="ZERO") e++; else if ($1==$2) s++; else c++ }
    END { printf "%d %d %d %d\n", c+0, e+0, s+0, u+0 }'
}

# ---------- helpers ----------
unmount_all() {                                 # rescue may have mounted partitions
  local p
  for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do
    findmnt -rn -S "$p" >/dev/null 2>&1 && { umount "$p" 2>/dev/null || umount -l "$p" 2>/dev/null; }
  done
  swapoff -a 2>/dev/null
  ! lsblk -lnpo MOUNTPOINT "$dev" | grep -q .
}
reread() { blockdev --rereadpt "$dev" 2>/dev/null; partprobe "$dev" 2>/dev/null; udevadm settle 2>/dev/null; }
elapsed() { local s=$(( $(date +%s) - $1 )); printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); }
# run a long blocking command in the background, show elapsed time (and estimate), return its exit code
run_wait() {                                    # run_wait "estimate text" cmd...
  local est=$1; shift
  local st; st=$(date +%s)
  "$@" > /tmp/erase.out 2>&1 &
  local pid=$!
  while kill -0 $pid 2>/dev/null; do
    printf '\r\e[K  Working... %s elapsed%s   (do NOT power off)' "$(elapsed $st)" "${est:+, expected ~$est}"
    sleep 1
  done
  wait $pid; local rc=$?
  printf '\r\e[K  Finished after %s\n' "$(elapsed $st)"
  return $rc
}

# ---------- method 1: quick ----------
m_quick() {
  local p ok=""
  for p in $(lsblk -lnpo NAME "$dev" | tail -n +2 | tac); do wipefs -a -q "$p" 2>/dev/null; done
  wipefs -a -q "$dev" 2>/dev/null
  if [ "$ROT" != 1 ]; then
    blkdiscard -f "$dev" 2>/dev/null && ok="TRIM of the whole disk done"
  fi
  # also clear the first and last 32 MiB (boot code, GPT backup at the end, leftovers of old tables)
  local mb=$(( sz / 1048576 ))
  dd if=/dev/zero of="$dev" bs=1M count=32 oflag=direct status=none conv=fsync 2>/dev/null
  dd if=/dev/zero of="$dev" bs=1M count=32 seek=$(( mb - 32 )) oflag=direct status=none conv=fsync 2>/dev/null
  reread
  METHOD="quick wipe (partitions + signatures removed${ok:+, $ok})"
  [ "$ROT" = 1 ] && NOTE="HDD: the old files are still physically on the disk - use Secure or Overwrite before selling."
  [ "$ROT" != 1 ] && [ -z "$ok" ] && NOTE="TRIM not supported here (USB adapter?) - old data may still be readable."
  return 0
}

# ---------- method 2a: NVMe format with secure erase ----------
m_nvme() {
  have nvme || { echo "  nvme-cli is missing on this stick."; return 1; }
  local ctrl=${dev%n[0-9]*} fna oacs ses=1 what="user-data erase"
  oacs=$(nvme id-ctrl "$ctrl" 2>/dev/null | awk '$1=="oacs"{print $3}')
  fna=$(nvme id-ctrl "$ctrl" 2>/dev/null | awk '$1=="fna"{print $3}')
  if [ -n "$oacs" ] && [ $(( oacs & 0x2 )) -eq 0 ]; then echo "  This NVMe does not support the Format command."; return 1; fi
  if [ -n "$fna" ] && [ $(( fna & 0x4 )) -ne 0 ]; then ses=2; what="cryptographic erase"; fi
  echo "  NVMe Format, $what (the drive does it internally)."
  run_wait "a few seconds to a minute" nvme format "$dev" --ses=$ses --force
  local rc=$?
  if [ $rc -ne 0 ] && [ $ses = 2 ]; then          # some drives advertise crypto erase but reject it
    echo "  Cryptographic erase refused, trying user-data erase..."; ses=1; what="user-data erase"
    run_wait "a few seconds to a minute" nvme format "$dev" --ses=1 --force; rc=$?
  fi
  [ $rc -ne 0 ] && { echo "  Failed:"; tail -3 /tmp/erase.out | sed 's/^/    /'; return 1; }
  reread; METHOD="NVMe secure format ($what)"
}

# ---------- method 2b: ATA Secure Erase (SATA SSD / HDD) ----------
m_ata() {
  have hdparm || { echo "  hdparm is missing on this stick."; return 1; }
  local info; info=$(hdparm -I "$dev" 2>/dev/null)
  # hdparm -I prints "<tab><tab>frozen" when set and "<tab>not<tab>frozen" when not
  echo "$info" | grep -qE '^[[:space:]]+supported$' || { echo "  This drive does not support ATA Secure Erase."; return 1; }
  if echo "$info" | grep -qE '^[[:space:]]+frozen'; then
    echo "  The BIOS has FROZEN the drive's security commands (normal on many laptops)."
    echo "  Fix: a short sleep and wake-up unfreezes it. The screen may go dark for ~5 s;"
    echo "  if the laptop does not wake by itself, press the power button briefly."
    keybar S "Sleep 5 s and retry" Q Cancel
    while :; do getkey; case $KEY in s) break ;; q) return 1 ;; esac; done
    rtcwake -m mem -s 5 >/dev/null 2>&1 || echo -n mem > /sys/power/state 2>/dev/null
    sleep 3; info=$(hdparm -I "$dev" 2>/dev/null)
    if echo "$info" | grep -qE '^[[:space:]]+frozen'; then
      echo "  Still frozen. Use method 3 (Overwrite) instead, or erase from another PC."; return 1
    fi
  fi
  if echo "$info" | grep -qE '^[[:space:]]+enabled'; then
    echo "  The drive already has a security password set (locked by someone else) - cannot erase."; return 1
  fi
  local enh="" est
  echo "$info" | grep -qE '^[[:space:]]+supported: enhanced erase' && enh=-enhanced
  local pat='[0-9]+min for SECURITY ERASE UNIT'; [ -n "$enh" ] && pat='[0-9]+min for ENHANCED SECURITY ERASE UNIT'
  est=$(echo "$info" | grep -oE "$pat" | head -1 | grep -oE '^[0-9]+min')
  echo "  ATA Secure Erase${enh:+ (enhanced)}. A temporary password 'p' is set and removed by the erase."
  hdparm --user-master u --security-set-pass p "$dev" >/dev/null 2>&1 || { echo "  Could not set the temporary password."; return 1; }
  run_wait "${est:-unknown}" hdparm --user-master u --security-erase$enh p "$dev"
  local rc=$?
  if [ $rc -ne 0 ]; then
    hdparm --user-master u --security-disable p "$dev" >/dev/null 2>&1
    echo "  Failed:"; tail -3 /tmp/erase.out | sed 's/^/    /'
    echo "  If the drive is now locked, its password is: p   (hdparm --security-disable p)"
    return 1
  fi
  reread; METHOD="ATA Secure Erase${enh:+ enhanced}"
}

# ---------- method 3: overwrite with zeros ----------
m_zero() {
  local CH=64 total b=0 st now pct sp eta errs=0 errlist="" stop=0 ms0 done_mb=0 lastp=0
  local totmb=$(( sz / 1048576 )) n
  total=$(( (totmb + CH - 1) / CH ))
  local OF=oflag=direct
  dd if=/dev/zero of="$dev" bs=1M count=1 $OF status=none 2>/dev/null || OF=""
  st=$(date +%s); ms0=$(date +%s%N)
  trap 'stop=1' INT
  printf '\e[?25l'
  while [ $b -lt $total ] && [ $stop = 0 ]; do
    n=$(( totmb - b*CH )); [ $n -gt $CH ] && n=$CH                   # last chunk: only up to the end
    if ! dd if=/dev/zero of="$dev" bs=1M count=$n seek=$(( b*CH )) $OF status=none 2>/dev/null; then
      [ $stop = 1 ] && break
      [ -b "$dev" ] && [ -n "$(blockdev --getsize64 "$dev" 2>/dev/null)" ] || { echo; echo "  The disk disappeared during writing."; break; }
      errs=$((errs+1)); errlist="$errlist $(( b*CH/1024 ))G"
    fi
    b=$((b+1)); now=$(date +%s)
    if [ $now -ne $lastp ] || [ $b -ge $total ]; then
      lastp=$now; pct=$(( b*100/total )); done_mb=$(( b*CH ))
      sp=$(( done_mb * 1000 / ( ($(date +%s%N) - ms0) / 1000000 + 1 ) ))
      eta=$(( sp > 0 ? (total-b)*CH / sp : 0 ))
      printf '\r\e[K  \e[1m%3d%%\e[0m  %s GB of %s GB   %s MB/s   %s elapsed   ~%02d:%02d left   write errors: %d   (Ctrl+C = stop)' \
        $pct $(( done_mb*1049/1000000 )) $gb $sp "$(elapsed $st)" $((eta/3600)) $((eta%3600/60)) $errs
    fi
  done
  trap - INT; printf '\e[?25h\n'
  sync
  reread
  if [ $stop = 1 ]; then METHOD="overwrite with zeros - STOPPED at $(( b*100/total ))%"; NOTE="Only the first part of the disk was erased."; return 1; fi
  METHOD="overwrite with zeros (${sp} MB/s, $(elapsed $st))"
  [ $errs -gt 0 ] && NOTE="WRITE ERRORS near:$errlist - the disk is failing, do not sell it."
  return 0
}

# ---------- screen ----------
clear; title "ERASE DISK - $dev"
printf '  Disk   : \e[1m%s  %s\e[0m  (%s GB, %s)\n' "$dev" "$model" "$gb" "$KIND"
printf '  Serial : \e[1m%s\e[0m\n\n' "${serial:-not reported}"
echo "  What is on it now:"
lsblk -no NAME,SIZE,FSTYPE,LABEL "$dev" 2>/dev/null | sed 's/^/    /'
echo
printf '  \e[1;31mEVERYTHING ON THIS DISK WILL BE DESTROYED. There is no undo.\e[0m\n\n'

# methods allowed / recommended per type
if [ "$TRAN" = usb ]; then
  echo "  1  Quick      seconds. Partitions removed; SSD: TRIM if the adapter allows it."
  echo "  2  Secure     not possible through a USB adapter - connect the disk to SATA / M.2 inside a PC."
  echo "  3  Overwrite  zeros over the whole disk, up to ~$(( (gb + 359) / 360 )) h (at 100 MB/s)."
  REC=3; [ "$ROT" != 1 ] && REC=1
elif [ "$TRAN" = nvme ]; then
  echo "  1  Quick      seconds. Partitions removed + TRIM."
  echo "  2  Secure     seconds. NVMe secure format: the drive wipes itself incl. spare areas.  [recommended]"
  echo "  3  Overwrite  not useful on an SSD (wear, spare areas stay) - only if 2 fails."
  REC=2
elif [ "$ROT" = 1 ]; then
  echo "  1  Quick      seconds. Partitions removed - old files stay on the platters (recoverable)."
  echo "  2  Secure     ATA Secure Erase, done by the drive, hours (time shown by the drive)."
  echo "  3  Overwrite  zeros over every sector, up to ~$(( (gb + 359) / 360 )) h; slow sectors get remapped.  [recommended]"
  REC=3
else
  echo "  1  Quick      seconds. Partitions removed + TRIM (good enough for reuse in-house)."
  echo "  2  Secure     ATA Secure Erase, seconds to minutes, incl. spare areas.  [recommended for sale]"
  echo "  3  Overwrite  not useful on an SSD (wear, spare areas stay) - only if 2 fails."
  REC=2
fi
keybar 1-3 "Method" Q Back
while :; do
  getkey
  case $KEY in
    q) exit 0 ;;
    1|3) M=$KEY; break ;;
    2) [ "$TRAN" = usb ] && continue; M=2; break ;;
  esac
done

# ---------- confirmation: Y, then the last 4 characters of the serial ----------
code=$(printf '%s' "$serial" | tr -cd '[:alnum:]' | tail -c 4 | tr '[:lower:]' '[:upper:]')
[ ${#code} -lt 4 ] && code=WIPE
echo
printf '  Method %s on \e[1m%s %s (%s GB)\e[0m.  Sure?' "$M" "$dev" "$model" "$gb"
keybar Y "Yes, erase" Q Cancel
while :; do getkey; case $KEY in y) break ;; q|n) exit 0 ;; esac; done
if [ "$code" = WIPE ]; then
  printf '\n  No serial number reported. Type \e[1mWIPE\e[0m and Enter to start: '
else
  printf '\n  Type the LAST 4 characters of the serial (\e[1m%s\e[0m) and Enter to start: ' "$serial"
fi
stty echo 2>/dev/null; read -r typed
typed=$(printf '%s' "$typed" | tr -d ' ' | tr '[:lower:]' '[:upper:]')
[ "$typed" = "$code" ] || { echo "  Does not match - nothing was erased."; pause; exit 0; }

# ---------- do it ----------
echo
unmount_all || { echo "  A partition of this disk is still in use - cannot erase."; pause; exit 1; }
echo "  Taking fingerprints of $SAMPLES points (to prove the erase afterwards)..."
fingerprint > /tmp/erase.before
METHOD=""; NOTE=""
trap '' INT                                     # Ctrl+C must not interrupt a firmware erase
case $M in
  1) m_quick ;;
  2) if [ "$TRAN" = nvme ]; then m_nvme; else m_ata; fi ;;
  3) trap - INT; m_zero ;;
esac
rc=$?
trap - INT
[ $rc -ne 0 ] && [ -z "$METHOD" ] && { echo; echo "  Nothing was erased (or the erase did not complete)."; report_add "Disk erase   : $dev $model SN ${serial:-?} - method $M FAILED"; pause; exit 1; }

echo "  Checking the $SAMPLES points again..."
fingerprint > /tmp/erase.after
read -r chg empty same unread < <(compare_fp /tmp/erase.before /tmp/erase.after)
echo
printf '  Method   : %s\n' "$METHOD"
printf '  Check    : %d of %d points had data and are now different, %d were already empty, %d unchanged%s\n' "$chg" "$SAMPLES" "$empty" "$same" "$( [ "$unread" -gt 0 ] && echo ", $unread unreadable")"
if [ "$same" -eq 0 ]; then
  printf '  Result   : \e[1;32mERASED - no old data found at the checked points\e[0m\n'; res="ERASED"
elif [ "$M" = 1 ]; then
  printf '  Result   : \e[1;33mpartitions removed, old data still readable at %d points\e[0m\n' "$same"; res="partitions removed (data still readable)"
else
  printf '  Result   : \e[1;31mNOT fully erased - old data still at %d points\e[0m\n' "$same"; res="NOT fully erased ($same points unchanged)"
fi
[ -n "$NOTE" ] && printf '  \e[1;33mNote     : %s\e[0m\n' "$NOTE"
report_add "Disk erase   : $dev $model SN ${serial:-?} - $METHOD - $res, checked $SAMPLES points - $(date '+%Y-%m-%d %H:%M')${NOTE:+ - $NOTE}"

# optional: empty GPT so the Windows installer sees a clean disk
keybar G "Create empty GPT (ready for Windows setup)" Enter "Leave it blank"
getkey
if [ "$KEY" = g ]; then
  echo 'label: gpt' | sfdisk -q "$dev" >/dev/null 2>&1 && { reread; echo "  Empty GPT created."; } || echo "  Could not create GPT (the Windows installer will do it)."
fi
pause
