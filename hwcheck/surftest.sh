#!/bin/bash
# surftest.sh — read-only disk surface scan (Victoria-style): latency map + bad blocks.
# Nothing is written to the disk. Reads the disk in blocks and times each read.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
have(){ command -v "$1" >/dev/null 2>&1; }

mapfile -t DISKS < <(lsblk -dnpo NAME,SIZE,MODEL,TYPE 2>/dev/null | awk '$NF=="disk"{$NF="";print}')
[ ${#DISKS[@]} -eq 0 ] && { echo "  No disks found."; read -rsn1 _; exit 1; }
echo "  Disks on this machine:"
i=0; for d in "${DISKS[@]}"; do echo "    $i) $d"; i=$((i+1)); done
if [ ${#DISKS[@]} -eq 1 ]; then n=0; else echo; read -rp "  Scan which disk number? " n; fi
dev=$(echo "${DISKS[$n]}" | awk '{print $1}')
[ -b "$dev" ] || { echo "  Not a disk: $dev"; read -rsn1 _; exit 1; }

sz=$(blockdev --getsize64 "$dev" 2>/dev/null)
[ -n "$sz" ] || { echo "  Cannot read size of $dev"; read -rsn1 _; exit 1; }
echo
echo "  Device : $dev   ($(( sz /1024/1024/1024 )) GiB)"
echo "  Mode   : READ-ONLY. Nothing is written to the disk."
echo
echo "    f = full scan (reads the whole disk, can take many minutes)"
echo "    q = quick scan (~300 points across the disk, about a minute)"
echo "    x = cancel"
read -rsn1 m; echo
[ "$m" = x ] || [ "$m" = X ] && exit 0

CHUNK=32                              # MiB read per sample (done as 1-MiB reads, O_DIRECT-friendly)
total=$(( sz / (CHUNK*1024*1024) )); [ $total -lt 1 ] && total=1
step=1; { [ "$m" = q ] || [ "$m" = Q ]; } && { step=$(( total/300 )); [ $step -lt 1 ] && step=1; }
# Use O_DIRECT (bypass cache = measure the real disk) only if the device actually allows it;
# some NVMe/USB bridges reject it, so fall back to normal reads instead of flagging every block bad.
DIRECT=iflag=direct
dd if="$dev" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null || DIRECT=""

ROT=$(cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null)   # 1 = spinning HDD
smart_counts(){                       # NVMe and SATA report health with different fields
  local a; a=$(smartctl -A "$dev" 2>/dev/null)
  if echo "$a" | grep -q 'Percentage Used'; then
    echo "$a" | awk -F: '
      /Percentage Used/{gsub(/[ %]/,"",$2); u=$2}
      /Available Spare:/{gsub(/[ %]/,"",$2); s=$2}
      /Media and Data Integrity Errors/{gsub(/ /,"",$2); m=$2}
      /Critical Warning/{gsub(/ /,"",$2); w=$2}
      END{printf "wear=%s%% spare=%s%% media_errors=%s warning=%s", u!=""?u:"?", s!=""?s:"?", m!=""?m:"?", w!=""?w:"?"}'
  else
    echo "$a" | awk '
      /Reallocated_Sector_Ct/{r=$10} /Current_Pending_Sector/{p=$10} /Offline_Uncorrectable/{u=$10}
      END{printf "realloc=%s pending=%s uncorr=%s", r!=""?r:"n/a", p!=""?p:"n/a", u!=""?u:"n/a"}'
  fi
}
temp_now(){ smartctl -A "$dev" 2>/dev/null | awk '
  /^Temperature:/{print $2; exit}
  /Temperature_Celsius|Airflow_Temperature_Cel/{print $10; exit}' | grep -oE '^[0-9]+' | head -1; }

sm_before=$(smart_counts); t=$(temp_now); maxt=${t:-0}
echo "  SMART before : $sm_before${t:+   temp ${t}C}"
echo
echo "  Legend:  . fast    : ok    = slow    ! very slow    X read error"
echo
good=0; ok=0; slow=0; vslow=0; bad=0; col=0; worst=0; badlist=""
niters=$(( (total + step - 1) / step )); [ $niters -lt 1 ] && niters=1
START=$(date +%s); i=0; b=0
while [ $b -lt $total ]; do
  t0=$(date +%s%N)
  if dd if="$dev" of=/dev/null bs=1M count=$CHUNK skip=$(( b*CHUNK )) $DIRECT status=none 2>/dev/null; then
    t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 ))
    [ $ms -gt $worst ] && worst=$ms
    if   [ $ms -lt 150 ];  then c='.'; good=$((good+1))
    elif [ $ms -lt 500 ];  then c=':'; ok=$((ok+1))
    elif [ $ms -lt 1500 ]; then c='='; slow=$((slow+1))
    else                        c='!'; vslow=$((vslow+1)); fi
  else
    c='X'; bad=$((bad+1)); badlist="$badlist $(( b*CHUNK/1024 ))G"
  fi
  printf '%s' "$c"
  i=$((i+1)); col=$((col+1))
  if [ $col -ge 64 ]; then
    el=$(( $(date +%s) - START )); pct=$(( i*100/niters ))
    eta=0; [ $i -gt 0 ] && eta=$(( el*(niters-i)/i ))
    t=$(temp_now); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
    printf '  %3d%%  %02d:%02d<%02d:%02d  %s\n' "$pct" $((el/60)) $((el%60)) $((eta/60)) $((eta%60)) "${t:+${t}C}"
    col=0
  fi
  b=$(( b+step ))
done
[ $col -gt 0 ] && printf '\n'
printf '\n\n'
sm_after=$(smart_counts); t=$(temp_now); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
chg=""; [ "$sm_after" != "$sm_before" ] && chg="   <- CHANGED during the scan"
echo "  SMART after  : $sm_after${t:+   temp ${t}C, max ${maxt}C}$chg"
echo "  Worst read   : ${worst} ms per 32 MiB block"
echo "  Blocks       : fast=$good ok=$ok slow=$slow very-slow=$vslow bad=$bad"
[ -n "$badlist" ] && echo "  Read errors near:$badlist"
nslow=$(( slow + vslow ))
if [ $bad -gt 0 ]; then
  verdict="READ ERRORS - disk is failing, copy the data off first"
elif [ $nslow -gt 0 ] && [ "$maxt" -ge 70 ]; then
  verdict="slow zones while hot (${maxt}C) - likely thermal throttling, not damage"
elif [ $(( nslow * 100 / niters )) -lt 3 ]; then
  verdict="surface OK"; [ $nslow -gt 0 ] && verdict="surface OK (a few slow blocks - normal background work)"
elif [ "$ROT" = 1 ]; then
  verdict="slow sectors, no errors yet - HDD starting to wear"
else
  verdict="slow zones, no errors - SSD reads old data slowly (aged/cheap NAND); repeat: same places = aged data"
fi
echo "  Verdict      : $verdict"
echo "Surface scan ($dev): fast=$good slow=$((slow+vslow)) bad=$bad, worst ${worst}ms - $verdict" >> /tmp/hwcheck.txt
echo
read -rsn1 -p "  Press any key to return..." _
