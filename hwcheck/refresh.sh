#!/bin/bash
# refresh.sh DEV — REFRESH a disk: read every block and write the SAME data back (key R, Disks screen).
# Why: on cheap SSDs old data slowly loses charge; the controller then reads it with many retries
# (slow zones in the surface scan). Writing it again stores fresh charge and the zone is fast again.
# On HDDs it rewrites weak but still readable sectors. The data is kept: each 32 MiB block is read
# into RAM, written back, read again and compared. Unreadable blocks are skipped, never overwritten.
# Choice: only the slow blocks remembered by the last FULL scan (fast), or the whole disk.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"

dev=$1
[ -b "$dev" ] || { echo "  No such disk: $dev"; pause; exit 1; }
[ "$dev" = "$BOOTDISK" ] && { echo "  This is the boot stick - refusing."; pause; exit 1; }
sz=$(blockdev --getsize64 "$dev" 2>/dev/null)
model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs)
ROT=$(cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null)
DN=$(basename "$dev")
CH=32                                           # MiB per block, the same blocks as the surface scan
totmb=$(( sz / 1048576 )); total=$(( (totmb + CH - 1) / CH ))
SLOWF=/tmp/scan-$DN.slow
BUF=/dev/shm/refresh.$$; trap 'rm -f "$BUF"' EXIT

elapsed() { local s=$(( $(date +%s) - $1 )); printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); }
on_battery() {                                  # true = a battery exists and no charger is plugged in
  local p bat=0 ac=0
  for p in /sys/class/power_supply/*; do
    case $(cat "$p/type" 2>/dev/null) in
      Battery) bat=1 ;;
      Mains|USB|USB_C|USB_PD) [ "$(cat "$p/online" 2>/dev/null)" = 1 ] && ac=1 ;;
    esac
  done
  [ $bat = 1 ] && [ $ac = 0 ]
}

clear; title "REFRESH - $dev $model"
echo "  Reads every block and writes the SAME data back, then reads it again to check."
echo "  Your files stay. Typical use: an SSD with many slow zones in the surface scan."
echo "  Blocks that cannot be read are skipped (not overwritten) and listed at the end."
echo
nslow=0; [ -f "$SLOWF" ] && nslow=$(grep -c . "$SLOWF")
if [ -f "$SLOWF" ]; then
  echo "  Last full scan: $nslow block(s) much slower than this disk's typical speed ($(( nslow * CH / 1024 )) GB)."
else
  echo "  No full scan of this disk yet: run F first to refresh only the slow zones."
fi
echo "  Whole disk: $(( sz / 1000000000 )) GB, three passes per block (read, write, check)."
# SSD wear cost: every refresh WRITES what it covers. For NVMe, estimate from the drive's own
# history: life used so far vs how many full-disk writes it has already taken.
if [ "$ROT" != 1 ]; then
  smart_detect "$dev" >/dev/null 2>&1
  sa=$(smartctl $SMARTD -A "$dev" 2>/dev/null)
  used=$(echo "$sa" | sed -n 's/^Percentage Used: *\([0-9]*\)%.*/\1/p')
  duw=$(echo "$sa" | sed -n 's/^Data Units Written: *\([0-9,]*\).*/\1/p' | tr -d ,)
  if [ -n "$used" ] && [ -n "$duw" ] && [ "$duw" -gt 0 ]; then
    fw10=$(( duw * 512000 * 10 / sz ))                 # full-disk writes so far, x10
    if [ "$used" -gt 0 ] && [ $fw10 -gt 0 ]; then
      cost=$(awk -v u=$used -v f=$fw10 'BEGIN{printf "%.2f", u*10/f}')
      echo "  Wear: life used ${used}% after $(( fw10 / 10 )) full-disk writes -> one whole-disk refresh costs ~${cost}% of its life."
    else
      echo "  Wear: life used ${used}% after $(( fw10 / 10 )) full-disk writes. One whole-disk refresh = one more full write."
    fi
  else
    echo "  Wear: one whole-disk refresh = one full write of the SSD (small/cheap SSDs: ~0.1-1% of life). Prefer S."
  fi
fi
on_battery && printf '\n  \e[1;31m!! Running on battery: plug in the charger. A power cut during a write can damage that block.\e[0m\n'
echo
args=()
[ "$nslow" -gt 0 ] && args+=(S "Slow zones only ($nslow blocks)")
args+=(A "Whole disk" Q Back)
keybar "${args[@]}"
while :; do
  getkey
  case $KEY in
    s) [ "$nslow" -gt 0 ] && { MODE=slow; break; } ;;
    a) MODE=all; break ;;
    q) exit 0 ;;
  esac
done

printf '\n  Refresh %s on \e[1m%s %s\e[0m. The disk must not be used meanwhile.' \
  "$([ $MODE = slow ] && echo "$nslow slow blocks" || echo "the whole disk")" "$dev" "$model"
keybar Y "Start" Q Cancel
while :; do getkey; case $KEY in y) break ;; q|n) exit 0 ;; esac; done

# partitions mounted by file rescue must be released first
for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do
  findmnt -rn -S "$p" >/dev/null 2>&1 && umount "$p" 2>/dev/null
done
if lsblk -lnpo MOUNTPOINT "$dev" | grep -q .; then echo; echo "  A partition of this disk is still in use - cannot refresh."; pause; exit 1; fi

# O_DIRECT so we really read/write the disk, not the RAM cache (fallback if the adapter refuses)
ID=iflag=direct; OD=oflag=direct
dd if="$dev" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null || { ID=""; OD=""; }

if [ $MODE = slow ]; then list=$(sort -n -u "$SLOWF"); else list=$(seq 0 $(( total - 1 ))); fi
todo=$(printf '%s\n' "$list" | grep -c .)

lost=0 done_n=0 okn=0 unread=0 werr=0 vfail=0 badlist="" stop=0 r1ms=0 r2ms=0 mbdone=0 lastp=0
st=$(date +%s)
trap 'stop=1' INT                               # Ctrl+C: finish the current block, then stop
echo; printf '\e[?25l'
for b in $list; do
  [ $stop = 1 ] && break
  n=$(( totmb - b*CH )); [ $n -gt $CH ] && n=$CH; [ $n -le 0 ] && continue
  done_n=$((done_n+1))
  # each dd ignores Ctrl+C itself, so a block is never left half-written by the keypress
  t0=$(date +%s%N)
  if ! ( trap '' INT; dd if="$dev" of="$BUF" bs=1M count=$n skip=$(( b*CH )) $ID status=none 2>/dev/null ); then
    # the disk dropped off (USB reset, hung on a bad sector)? stop instead of "failing" every block
    if [ ! -b "$dev" ] || [ -z "$(blockdev --getsize64 "$dev" 2>/dev/null)" ]; then
      printf '\e[?25h\n\n  \e[1;37;41m STOPPED: the disk disappeared at %s GB \e[0m (hung on a bad sector or USB power/adapter reset)\n' "$(( b*CH/1024 ))"
      stop=1; lost=1; break
    fi
    unread=$((unread+1)); badlist="$badlist $(( b*CH/1024 ))G"; continue
  fi
  t1=$(date +%s%N); r1ms=$(( r1ms + (t1-t0)/1000000 ))
  sum1=$(md5sum < "$BUF")
  if ! ( trap '' INT; dd if="$BUF" of="$dev" bs=1M count=$n seek=$(( b*CH )) $OD conv=notrunc,fsync status=none 2>/dev/null ); then
    werr=$((werr+1)); badlist="$badlist $(( b*CH/1024 ))G(write)"; continue
  fi
  t0=$(date +%s%N)
  sum2=$( ( trap '' INT; dd if="$dev" bs=1M count=$n skip=$(( b*CH )) $ID status=none 2>/dev/null ) | md5sum )
  t1=$(date +%s%N); r2ms=$(( r2ms + (t1-t0)/1000000 ))
  if [ "$sum1" != "$sum2" ]; then
    # one more try with the copy still in RAM; if it still differs, stop at once
    ( trap '' INT; dd if="$BUF" of="$dev" bs=1M count=$n seek=$(( b*CH )) $OD conv=notrunc,fsync status=none 2>/dev/null )
    sum2=$( ( trap '' INT; dd if="$dev" bs=1M count=$n skip=$(( b*CH )) $ID status=none 2>/dev/null ) | md5sum )
    if [ "$sum1" != "$sum2" ]; then
      vfail=$((vfail+1)); cp "$BUF" "/tmp/refresh-block-$b.bin" 2>/dev/null
      printf '\e[?25h\n\n  \e[1;37;41m STOPPED: block at %s GB reads back DIFFERENT from what was written. \e[0m\n' "$(( b*CH/1024 ))"
      echo "  The disk does not store data reliably. Its original content is saved in /tmp/refresh-block-$b.bin"
      echo "  (lost on reboot - copy it off if needed). Do not trust this disk."
      break
    fi
  fi
  okn=$((okn+1)); mbdone=$(( mbdone + n ))
  now=$(date +%s)
  if [ $now -ne $lastp ]; then
    lastp=$now; el=$(( now - st )); eta=$(( done_n > 0 ? el * (todo - done_n) / done_n : 0 ))
    printf '\r\e[K  \e[1m%3d%%\e[0m  %d of %d blocks   %s elapsed   ~%02d:%02d:%02d left   skipped %d   (Ctrl+C = stop)' \
      $(( done_n*100/todo )) $done_n $todo "$(elapsed $st)" $((eta/3600)) $((eta%3600/60)) $((eta%60)) $(( unread + werr ))
  fi
done
trap - INT; printf '\e[?25h\n\n'
sync

sp1="-"; sp2="-"
[ $r1ms -gt 0 ] && sp1=$(( mbdone * 1049 / r1ms ))
[ $r2ms -gt 0 ] && sp2=$(( mbdone * 1049 / r2ms ))
echo "  Refreshed    : $okn of $todo blocks ($(( mbdone / 1024 )) GB) in $(elapsed $st)$([ $stop = 1 ] && [ $lost = 0 ] && echo '  - STOPPED by Ctrl+C')"
echo "  Read speed   : before ${sp1} MB/s  ->  check read ${sp2} MB/s   (right after writing; the next F scan is the real comparison)"
[ $unread -gt 0 ] && printf '  \e[1;31mUnreadable   : %d block(s), skipped, data there is already damaged\e[0m\n' $unread
[ $werr -gt 0 ]   && printf '  \e[1;31mWrite errors : %d block(s) - the disk refuses writes there\e[0m\n' $werr
[ -n "$badlist" ] && echo "  Near         :$badlist"
if [ $lost = 1 ]; then res="STOPPED - the disk dropped off; reconnect (SATA or a powered adapter) before trusting it"
elif [ $vfail -gt 0 ]; then res="FAILED - data read back different, disk unreliable"
elif [ $unread -gt 0 ] || [ $werr -gt 0 ]; then res="done with $(( unread + werr )) bad block(s) skipped - disk is failing"
elif [ $stop = 1 ]; then res="stopped by user"
else res="done, no errors"; fi
[ -n "$ID" ] || echo "  Note         : the adapter refused direct I/O - speeds include the RAM cache."
printf '  Result       : \e[1m%s\e[0m\n' "$res"
echo "  Next         : run F (full scan) again and compare the map."
report_add "Refresh      : $dev $model - $([ $MODE = slow ] && echo "slow zones ($todo blocks)" || echo "whole disk") - read ${sp1} -> ${sp2} MB/s - $res"
pause
