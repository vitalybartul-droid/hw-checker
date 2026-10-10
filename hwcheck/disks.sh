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
smart_detect "$dev"
RPM=$(smartctl $SMARTD -i "$dev" 2>/dev/null | sed -n 's/^Rotation Rate: *//p' | head -1)
TRAN=$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ')
# USB link speed (480 = USB 2.0): walk up sysfs from the disk to the USB device
USBSPEED=""
if [ "$TRAN" = usb ]; then
  d=$(readlink -f "/sys/block/$(basename "$dev")/device")
  while [ -n "$d" ] && [ "$d" != / ]; do [ -r "$d/speed" ] && { USBSPEED=$(cat "$d/speed"); break; }; d=$(dirname "$d"); done
fi
# Colour thresholds depend on what the disk can do: MB/s for fast / ok / slow (below = very slow)
if   [ "$TRAN" = usb ] && [ -n "$USBSPEED" ] && [ "${USBSPEED%%.*}" -le 480 ] 2>/dev/null; then CLASS="USB 2.0 disk"; TH="25 15 5"
elif [ "$ROT" = 1 ];      then CLASS="HDD";      TH="80 40 10"
elif [ "$TRAN" = nvme ];  then CLASS="NVMe SSD"; TH="500 150 30"
elif [ "$TRAN" = usb ];   then CLASS="USB SSD";  TH="150 60 15"
else                           CLASS="SATA SSD"; TH="250 100 25"; fi
read -r MB1 MB2 MB3 <<< "$TH"
# ms per 32 MiB block for each threshold (32 MiB = 33.55 MB)
T1=$(( 33554 / MB1 )); T2=$(( 33554 / MB2 )); T3=$(( 33554 / MB3 ))

# O_DIRECT bypasses the cache so we measure the disk, not RAM. Some NVMe/USB bridges
# reject it: then fall back to normal reads instead of reporting every block as bad.
DIRECT=iflag=direct
dd if="$dev" of=/dev/null bs=1M count=1 iflag=direct status=none 2>/dev/null || DIRECT=""

# ---------- live diagnostics during the scan ----------
declare -A SB                                   # SMART error counters at the start of the scan
smart_deltas() {                                # -> "cable_crc+3 realloc+1" (only what grew)
  local k v bv out=""
  while IFS='=' read -r k v; do
    v=${v//,/}; bv=${SB[$k]//,/}
    [ -n "$v" ] && [ -n "$bv" ] && [ "$v" -gt "$bv" ] 2>/dev/null && out="$out $k+$(( v - bv ))"
  done < <(smart_vals "$dev")
  echo "${out# }"
}
kern_lines() {                                  # new kernel messages about disk errors / resets
  dmesg 2>/dev/null | tail -n +$(( KBASE + 1 )) | grep -iE "$DN|ata[0-9]|usb [0-9]|nvme" \
    | grep -iE 'error|reset|timeout|offline|disconnect|fail|abort'
}

# ---------- surface scan: $1 = quick | full ----------
scan() {
  local CHUNK=32 total step niters START i=0 b=0 col=0 c ms t t0 t1 el pct eta W cols
  local good=0 ok=0 slow=0 vslow=0 bad=0 worst=0 readms=0 rowms=0 rown=0 badlist="" maxt sm_before sm_after chg d k alerts
  total=$(( sz / (CHUNK*1024*1024) )); [ $total -lt 1 ] && total=1
  step=1; [ "$1" = quick ] && { step=$(( total/300 )); [ $step -lt 1 ] && step=1; }
  niters=$(( (total + step - 1) / step ))
  cols=$(tput cols 2>/dev/null || echo 120)
  W=$(( (cols - 50) / 2 )); [ $W -gt 64 ] && W=64; [ $W -lt 16 ] && W=16      # cells per row (cell + gap = 2 columns)

  clear; title "SURFACE SCAN ($1) - $dev $model${RPM:+, $RPM}"
  SB=(); while IFS='=' read -r k d; do SB[$k]=$d; done < <(smart_vals "$dev")
  KBASE=$(dmesg 2>/dev/null | wc -l); DN=$(basename "$dev")
  sm_before=$(smart_line "$dev"); t=$(temp_now "$dev"); maxt=${t:-0}
  echo "  SMART before : $sm_before${t:+   temp ${t}C}"
  # Colour cells (background colour, no special glyphs: works with any console font).
  # The console has only dim backgrounds (yellow looks orange); bold+reverse gives a bright yellow cell.
  local C_FAST=$'\e[42m \e[0m' C_OK=$'\e[1;7;33m \e[0m' C_SLOW=$'\e[41m \e[0m' C_VSLOW=$'\e[41;1;37m!\e[0m' C_BAD=$'\e[47;1;31mX\e[0m'
  printf '  %s scale, each cell = 32 MiB:  %s fast (>%s MB/s)  %s ok (%s-%s)  %s slow (%s-%s)  %s very slow (<%s)  %s unreadable\n' \
    "$CLASS" "$C_FAST" $MB1 "$C_OK" $MB2 $MB1 "$C_SLOW" $MB3 $MB2 "$C_VSLOW" $MB3 "$C_BAD"
  echo "  Right column: done %, elapsed<left, speed of that row, disk temperature, red = error counters that GREW."
  echo "  Ctrl+C = stop"
  echo
  START=$(date +%s)
  local stop=0
  trap 'stop=1' INT                           # Ctrl+C ends the scan but still prints the result
  while [ $b -lt $total ] && [ $stop = 0 ]; do
    t0=$(date +%s%N)
    if dd if="$dev" of=/dev/null bs=1M count=$CHUNK skip=$(( b*CHUNK )) $DIRECT status=none 2>/dev/null; then
      t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); readms=$(( readms + ms )); rowms=$(( rowms + ms )); rown=$(( rown + 1 ))
      [ $ms -gt $worst ] && worst=$ms
      if   [ $ms -lt $T1 ]; then c=$C_FAST; good=$((good+1))
      elif [ $ms -lt $T2 ]; then c=$C_OK; ok=$((ok+1))
      elif [ $ms -lt $T3 ]; then c=$C_SLOW; slow=$((slow+1))
      else                       c=$C_VSLOW; vslow=$((vslow+1)); fi
    else
      [ $stop = 1 ] && break                  # read interrupted by Ctrl+C, not a disk error
      c=$C_BAD; bad=$((bad+1)); badlist="$badlist $(( b*CHUNK/1024 ))G"
    fi
    printf '%s ' "$c"                         # cell + dark gap: every block stays visible
    i=$((i+1)); col=$((col+1))
    if [ $col -ge $W ] || [ $(( b + step )) -ge $total ]; then
      el=$(( $(date +%s) - START )); pct=$(( i*100/niters )); eta=$(( el*(niters-i)/i ))
      t=$(temp_now "$dev"); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
      d=$(smart_deltas); k=$(kern_lines | wc -l)
      alerts="$d"; [ "$k" -gt 0 ] && alerts="$alerts${alerts:+ }kernel:$k"
      printf '%*s %3d%%  %02d:%02d<%02d:%02d  %4s MB/s  %s\e[1;31m%s\e[0m\n' $(( (W-col)*2 )) "" "$pct" $((el/60)) $((el%60)) $((eta/60)) $((eta%60)) \
        "$([ $rowms -gt 0 ] && echo $(( rown*CHUNK*1049/rowms )) || echo -)" "${t:+${t}C  }" "$alerts"
      col=0; rowms=0; rown=0
    fi
    b=$(( b+step ))
  done
  trap - INT
  [ $col -gt 0 ] && printf '\n'
  echo

  local nread=$(( good+ok+slow+vslow )) speed=""
  [ $readms -gt 0 ] && speed=$(( nread*CHUNK*1049/readms ))
  sm_after=$(smart_line "$dev"); t=$(temp_now "$dev"); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
  d=$(smart_deltas); local kl; kl=$(kern_lines); k=$(printf '%s' "$kl" | grep -c .)
  chg=""; [ "$sm_after" != "$sm_before" ] && chg="   <- CHANGED during the scan"
  echo "  SMART after  : $sm_after${t:+   temp ${t}C, max ${maxt}C}$chg"
  [ -n "$speed" ] && echo "  Read speed   : ${speed} MB/s average   (typical: HDD 60-160, SATA SSD 400-550, NVMe 1500+)"
  echo "  Worst read   : ${worst} ms per 32 MiB block"
  echo "  Blocks       : fast=$good ok=$ok slow=$slow very-slow=$vslow bad=$bad   ($i of $niters read)"
  [ -n "$badlist" ] && echo "  Read errors near:$badlist"
  local warn=""
  case " $d " in *" cable_crc+"*) printf '  \e[1;31mCable / port : interface (CRC) errors grew during the scan - check the SATA cable, port or USB adapter, not the disk\e[0m\n'; warn="$warn; CRC errors grew" ;; esac
  case " $d " in *realloc+*|*pending+*|*uncorr+*|*media_errors+*)
    printf '  \e[1;31mSMART        : bad-sector counters grew DURING the scan (%s) - the disk is failing now\e[0m\n' "$d"; warn="$warn; bad sectors grew" ;; esac
  if [ "$k" -gt 0 ]; then
    printf '  \e[1;31mKernel log   : %s disk error / reset message(s) during the scan - cable, power, adapter or controller\e[0m\n' "$k"
    printf '%s\n' "$kl" | tail -3 | sed 's/^/      /'
    warn="$warn; kernel disk errors $k"
  fi

  local nslow=$(( slow + vslow )) verdict
  if [ $bad -gt 0 ]; then
    verdict="READ ERRORS - disk is failing, copy the data off first"
  elif case "$warn" in *"bad sectors grew"*) true ;; *) false ;; esac; then
    verdict="bad sectors appearing right now - disk is failing, copy the data off first"
  elif [ $nslow -gt 0 ] && [ "$maxt" -ge 70 ]; then
    verdict="slow zones while hot (${maxt}C) - likely thermal throttling, not damage"
  elif [ $(( nslow * 100 / (i>0?i:1) )) -lt 3 ]; then
    verdict="surface OK"; [ $nslow -gt 0 ] && verdict="surface OK (a few slow blocks - normal background work)"
  elif [ "$ROT" = 1 ]; then
    verdict="slow sectors, no errors yet - HDD starting to wear"
  else
    verdict="slow zones, no read errors - typical of cheap SSD controllers; scan again: slow in the SAME places = aging data, elsewhere = normal"
  fi
  [ -n "$warn" ] && [ $bad -eq 0 ] && verdict="$verdict (but:${warn#;})"
  printf '  Verdict      : \e[1m%s\e[0m\n' "$verdict"
  echo "Disk check ($1) $dev $model: ${speed:-?} MB/s, fast=$good slow=$nslow bad=$bad, worst ${worst}ms - $verdict" >> "$REPORT"
}

# ---------- SMART short self-test ----------
selftest() {
  clear; title "SMART SELF-TEST - $dev $model"
  have smartctl || { echo "  smartctl is not available."; return; }
  if ! smartctl $SMARTD -t short "$dev" >/dev/null 2>&1; then echo "  This drive (or its USB bridge) does not support a self-test."; return; fi
  local i st pr res h
  for i in $(seq 1 60); do                     # up to 5 minutes
    sleep 5
    st=$(smartctl $SMARTD -c -l selftest "$dev" 2>/dev/null)
    # NVMe prints "No self-test in progress" when idle: that line must not count as running
    if echo "$st" | grep -i 'in progress' | grep -qvi 'no self-test in progress'; then
      pr=$(echo "$st" | grep -oiE '[0-9]+% (of test remaining|completed)' | head -1)
      printf '\r\e[K  Running... %s (%ds)' "$pr" $(( i * 5 ))
    else break; fi
  done
  printf '\r\e[K'
  res=$(smartctl $SMARTD -l selftest "$dev" 2>/dev/null | grep -E '^ *#? *[0-9]+ +(Short|Extended|Offline)' | head -1 | sed -E 's/^ *#? *[0-9]+ +//; s/ {2,}/  /g')
  h=$(smartctl $SMARTD -H "$dev" 2>/dev/null | sed -nE 's/.*(self-assessment test result|Health Status): *([A-Z]+).*/\2/p' | head -1)
  echo "  Self-test    : ${res:-no result (still running or not reported)}"
  [ -n "$h" ] && echo "  SMART health : $h"
  echo "Self-test    : $dev ${res:-no result}${h:+, SMART health $h}" >> "$REPORT"
}

while true; do
  clear; title "DISK CHECK"
  printf '  Disk   : \e[1m%s  %s\e[0m  (%s GB, %s)\n' "$dev" "$model" "$(( sz/1000000000 ))" "$CLASS${USBSPEED:+, USB link ${USBSPEED} Mb/s}"
  t=$(temp_now "$dev")
  echo "  SMART  : $(smart_line "$dev")${t:+   temp ${t}C}${SMARTD:+   (via USB bridge: $SMARTD)}"
  [ -n "$RPM" ] && echo "  Spindle: $RPM"
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
