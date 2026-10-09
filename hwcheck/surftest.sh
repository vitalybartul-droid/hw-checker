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

smart_counts(){ smartctl -A "$dev" 2>/dev/null | awk '
  /Reallocated_Sector_Ct/{r=$NF} /Current_Pending_Sector/{p=$NF} /Offline_Uncorrectable/{u=$NF}
  END{printf "realloc=%s pending=%s uncorr=%s", r?r:"n/a", p?p:"n/a", u?u:"n/a"}'; }

echo "  SMART before : $(smart_counts)"
echo
echo "  Legend:  . fast    : ok    = slow    ! very slow    X read error"
echo
good=0; ok=0; slow=0; vslow=0; bad=0; col=0; worst=0; badlist=""
b=0
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
  col=$((col+1)); [ $col -ge 64 ] && { printf '\n'; col=0; }
  b=$(( b+step ))
done
printf '\n\n'
echo "  SMART after  : $(smart_counts)"
echo "  Worst read   : ${worst} ms per 32 MiB block"
echo "  Blocks       : fast=$good ok=$ok slow=$slow very-slow=$vslow bad=$bad"
[ -n "$badlist" ] && echo "  Read errors near:$badlist"
verdict="surface OK"
{ [ $slow -gt 0 ] || [ $vslow -gt 0 ]; } && verdict="some slow blocks (disk aging or busy)"
[ $bad -gt 0 ] && verdict="READ ERRORS - disk is failing"
echo "  Verdict      : $verdict"
echo "Surface scan ($dev): fast=$good slow=$((slow+vslow)) bad=$bad, worst ${worst}ms - $verdict" >> /tmp/hwcheck.txt
echo
read -rsn1 -p "  Press any key to return..." _
