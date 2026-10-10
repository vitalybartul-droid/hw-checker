#!/bin/bash
# disks.sh — disk check for intake and repair (key D). Everything is READ-ONLY.
#   Enter = quick check: SMART + read speed + surface scan at ~300 points (about a minute)
#   F     = full surface scan, Victoria-style latency map of the whole disk
#   T     = SMART short self-test (the drive tests itself, ~2 min)
# Result lines are appended to the report (/tmp/hwcheck.txt).
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"
have() { command -v "$1" >/dev/null 2>&1; }
REPORT=/tmp/hwcheck.txt

clear; title "DISK CHECK"
pick_disk "Which disk?" || exit 0
dev=$DISK
sz=$(blockdev --getsize64 "$dev" 2>/dev/null)
[ -n "$sz" ] || { echo "  Cannot read the size of $dev"; pause; exit 1; }
model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs)
ROT=$(cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null)     # 1 = spinning HDD

# O_DIRECT bypasses the cache so we measure the disk, not RAM. Some NVMe/USB bridges
# reject it: then fall back to normal reads instead of reporting every block as bad.
DIRECT=iflag=direct
dd if="$dev" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null || DIRECT=""

# ---------- surface scan: $1 = quick | full ----------
scan() {
  local CHUNK=32 total step niters START i=0 b=0 col=0 c ms t t0 t1 el pct eta
  local good=0 ok=0 slow=0 vslow=0 bad=0 worst=0 readms=0 badlist="" maxt sm_before sm_after chg
  total=$(( sz / (CHUNK*1024*1024) )); [ $total -lt 1 ] && total=1
  step=1; [ "$1" = quick ] && { step=$(( total/300 )); [ $step -lt 1 ] && step=1; }
  niters=$(( (total + step - 1) / step ))

  clear; title "SURFACE SCAN ($1) - $dev $model"
  sm_before=$(smart_line "$dev"); t=$(temp_now "$dev"); maxt=${t:-0}
  echo "  SMART before : $sm_before${t:+   temp ${t}C}"
  echo "  Legend:  . fast    : ok    = slow    ! very slow    X read error        (Ctrl+C = stop)"
  echo
  START=$(date +%s)
  local stop=0
  trap 'stop=1' INT                           # Ctrl+C ends the scan but still prints the result
  while [ $b -lt $total ] && [ $stop = 0 ]; do
    t0=$(date +%s%N)
    if dd if="$dev" of=/dev/null bs=1M count=$CHUNK skip=$(( b*CHUNK )) $DIRECT status=none 2>/dev/null; then
      t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); readms=$(( readms + ms ))
      [ $ms -gt $worst ] && worst=$ms
      if   [ $ms -lt 150 ];  then c='.'; good=$((good+1))
      elif [ $ms -lt 500 ];  then c=':'; ok=$((ok+1))
      elif [ $ms -lt 1500 ]; then c='='; slow=$((slow+1))
      else                        c='!'; vslow=$((vslow+1)); fi
    else
      [ $stop = 1 ] && break                  # read interrupted by Ctrl+C, not a disk error
      c='X'; bad=$((bad+1)); badlist="$badlist $(( b*CHUNK/1024 ))G"
    fi
    printf '%s' "$c"
    i=$((i+1)); col=$((col+1))
    if [ $col -ge 64 ]; then
      el=$(( $(date +%s) - START )); pct=$(( i*100/niters ))
      eta=$(( el*(niters-i)/i ))
      t=$(temp_now "$dev"); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
      printf '  %3d%%  %02d:%02d<%02d:%02d  %s\n' "$pct" $((el/60)) $((el%60)) $((eta/60)) $((eta%60)) "${t:+${t}C}"
      col=0
    fi
    b=$(( b+step ))
  done
  trap - INT
  [ $col -gt 0 ] && printf '\n'
  echo

  local nread=$(( good+ok+slow+vslow )) speed=""
  [ $readms -gt 0 ] && speed=$(awk -v n=$nread -v c=$CHUNK -v ms=$readms 'BEGIN{printf "%.0f", n*c*1.048576*1000/ms}')
  sm_after=$(smart_line "$dev"); t=$(temp_now "$dev"); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
  chg=""; [ "$sm_after" != "$sm_before" ] && chg="   <- CHANGED during the scan"
  echo "  SMART after  : $sm_after${t:+   temp ${t}C, max ${maxt}C}$chg"
  [ -n "$speed" ] && echo "  Read speed   : ${speed} MB/s average   (typical: HDD 80-160, SATA SSD 400-550, NVMe 1500+)"
  echo "  Worst read   : ${worst} ms per 32 MiB block"
  echo "  Blocks       : fast=$good ok=$ok slow=$slow very-slow=$vslow bad=$bad   ($i of $niters read)"
  [ -n "$badlist" ] && echo "  Read errors near:$badlist"

  local nslow=$(( slow + vslow )) verdict
  if [ $bad -gt 0 ]; then
    verdict="READ ERRORS - disk is failing, copy the data off first"
  elif [ $nslow -gt 0 ] && [ "$maxt" -ge 70 ]; then
    verdict="slow zones while hot (${maxt}C) - likely thermal throttling, not damage"
  elif [ $(( nslow * 100 / (i>0?i:1) )) -lt 3 ]; then
    verdict="surface OK"; [ $nslow -gt 0 ] && verdict="surface OK (a few slow blocks - normal background work)"
  elif [ "$ROT" = 1 ]; then
    verdict="slow sectors, no errors yet - HDD starting to wear"
  else
    verdict="slow zones, no read errors - typical of cheap SSD controllers; scan again: slow in the SAME places = aging data, elsewhere = normal"
  fi
  printf '  Verdict      : \e[1m%s\e[0m\n' "$verdict"
  echo "Disk check ($1) $dev $model: ${speed:-?} MB/s, fast=$good slow=$nslow bad=$bad, worst ${worst}ms - $verdict" >> "$REPORT"
}

# ---------- SMART short self-test ----------
selftest() {
  clear; title "SMART SELF-TEST - $dev $model"
  have smartctl || { echo "  smartctl is not available."; return; }
  if ! smartctl -t short "$dev" >/dev/null 2>&1; then echo "  This drive (or its USB bridge) does not support a self-test."; return; fi
  local i st pr res h
  for i in $(seq 1 60); do                     # up to 5 minutes
    sleep 5
    st=$(smartctl -c -l selftest "$dev" 2>/dev/null)
    # NVMe prints "No self-test in progress" when idle: that line must not count as running
    if echo "$st" | grep -i 'in progress' | grep -qvi 'no self-test in progress'; then
      pr=$(echo "$st" | grep -oiE '[0-9]+% (of test remaining|completed)' | head -1)
      printf '\r\e[K  Running... %s (%ds)' "$pr" $(( i * 5 ))
    else break; fi
  done
  printf '\r\e[K'
  res=$(smartctl -l selftest "$dev" 2>/dev/null | grep -E '^ *#? *[0-9]+ +(Short|Extended|Offline)' | head -1 | sed -E 's/^ *#? *[0-9]+ +//; s/ {2,}/  /g')
  h=$(smartctl -H "$dev" 2>/dev/null | sed -nE 's/.*(self-assessment test result|Health Status): *([A-Z]+).*/\2/p' | head -1)
  echo "  Self-test    : ${res:-no result (still running or not reported)}"
  [ -n "$h" ] && echo "  SMART health : $h"
  echo "Self-test    : $dev ${res:-no result}${h:+, SMART health $h}" >> "$REPORT"
}

while true; do
  clear; title "DISK CHECK"
  printf '  Disk   : \e[1m%s  %s\e[0m  (%s GB, %s)\n' "$dev" "$model" "$(( sz/1000000000 ))" "$([ "$ROT" = 1 ] && echo HDD || echo SSD)"
  t=$(temp_now "$dev")
  echo "  SMART  : $(smart_line "$dev")${t:+   temp ${t}C}"
  echo "  Every check here is READ-ONLY. Nothing is written to the disk."
  keybar Enter "Quick check (~1 min)" F "Full surface scan" T "SMART self-test (~2 min)" Q Back
  getkey
  case $KEY in
    "") scan quick; pause ;;
    f)  scan full;  pause ;;
    t)  selftest;   pause ;;
    q)  break ;;
  esac
done
