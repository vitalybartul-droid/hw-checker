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
# Full-screen layout that never scrolls: header (title, SMART, legend) / map of the WHOLE disk /
# status lines. If there are more blocks than cells, one cell covers several blocks and takes
# the colour of the WORST of them, so no slow or bad spot is hidden.
scan() {
  local CHUNK=32 total step niters START i=0 b=0 ms t t0 t1 el pct eta d k alerts lv
  local good=0 ok=0 slow=0 vslow=0 bad=0 worst=0 readms=0 badlist="" maxt sm_before sm_after chg
  total=$(( sz / (CHUNK*1024*1024) )); [ $total -lt 1 ] && total=1
  step=1; [ "$1" = quick ] && { step=$(( total/300 )); [ $step -lt 1 ] && step=1; }
  niters=$(( (total + step - 1) / step ))

  local LN CL W MROWS K ncells used ST MAPTOP=8 cellmb cellsz
  LN=$(tput lines 2>/dev/null || echo 40); CL=$(tput cols 2>/dev/null || echo 120)
  W=$(( (CL - 10) / 2 )); [ $W -gt 100 ] && W=100; [ $W -lt 10 ] && W=10      # cells per row (cell + gap)
  MROWS=$(( (LN - MAPTOP - 13) / 2 )); [ $MROWS -lt 3 ] && MROWS=3           # map rows are 2 lines apart; keep room for status + result
  K=$(( (niters + W*MROWS - 1) / (W*MROWS) ))                                 # blocks per cell
  ncells=$(( (niters + K - 1) / K )); used=$(( (ncells + W - 1) / W ))
  ST=$(( MAPTOP + used*2 ))
  cellmb=$(( K * step * CHUNK ))
  if [ $cellmb -ge 1024 ]; then cellsz="$(awk -v m=$cellmb 'BEGIN{printf "%.1f GiB", m/1024}')"; else cellsz="$cellmb MiB"; fi

  local C_FAST=$'\e[42m \e[0m' C_OK=$'\e[1;7;33m \e[0m' C_SLOW=$'\e[41m \e[0m' C_VSLOW=$'\e[41;1;37m!\e[0m' C_BAD=$'\e[47;1;31mX\e[0m'
  local CELL=("$C_FAST" "$C_OK" "$C_SLOW" "$C_VSLOW" "$C_BAD")

  SB=(); while IFS='=' read -r k d; do SB[$k]=$d; done < <(smart_vals "$dev")
  KBASE=$(dmesg 2>/dev/null | wc -l); DN=$(basename "$dev")
  sm_before=$(smart_line "$dev"); t=$(temp_now "$dev"); maxt=${t:-0}
  local prebad=""                               # unstable / unreadable sectors known before we start
  for k in pending uncorr media_errors; do [ "${SB[$k]:-0}" -gt 0 ] 2>/dev/null && prebad="$prebad $k=${SB[$k]}"; done

  clear; printf '\e[?25l'                       # hide the cursor while drawing
  title "SURFACE SCAN ($1) - $dev $model${RPM:+, $RPM}"
  echo "  SMART before : $sm_before${t:+   temp ${t}C}"
  [ -n "$prebad" ] && printf '  \e[1;31m!! The disk already reports bad sectors:%s - expect slow or unreadable spots\e[0m\n' "$prebad"
  printf '  %s scale:  %s fast (>%s MB/s)  %s ok (%s-%s)  %s slow (%s-%s)  %s very slow (<%s)  %s unreadable\n' \
    "$CLASS" "$C_FAST" $MB1 "$C_OK" $MB2 $MB1 "$C_SLOW" $MB3 $MB2 "$C_VSLOW" $MB3 "$C_BAD"
  printf '  Whole disk on one screen: each cell = %s, coloured by its worst block.   \e[1mCtrl+C = stop\e[0m\n' "$cellsz"

  local ci=0 cn=0 cw=0 r
  drawcell() {                                  # draw cell ci with level cw; row label at the start of each row
    r=$(( MAPTOP + (ci / W) * 2 ))             # empty line between map rows: cells never merge into columns
    [ $(( ci % W )) -eq 0 ] && printf '\e[%d;1H%6sG ' $r "$(( ci * cellmb / 1024 ))"
    printf '\e[%d;%dH%s' $r $(( 9 + (ci % W) * 2 )) "${CELL[$cw]}"
    ci=$(( ci + 1 )); cn=0; cw=0
  }
  local lastsec=0 lastchk=0 winms=0 winn=0 now nowsp avg
  status() {
    el=$(( $(date +%s) - START )); pct=$(( i*100/niters )); eta=0; [ $i -gt 0 ] && eta=$(( el*(niters-i)/i ))
    nowsp="-"; [ $winms -gt 0 ] && nowsp=$(( winn*CHUNK*1049/winms ))
    avg="-";   [ $readms -gt 0 ] && avg=$(( (good+ok+slow+vslow)*CHUNK*1049/readms ))
    printf '\e[%d;1H\e[K  \e[1m%3d%%\e[0m   %02d:%02d elapsed   ~%02d:%02d left   now %s MB/s   average %s MB/s   blocks: %d ok, %d slow, %d bad' \
      $ST "$pct" $((el/60)) $((el%60)) $((eta/60)) $((eta%60)) "$nowsp" "$avg" $((good+ok)) $((slow+vslow)) $bad
    printf '\e[%d;1H\e[K  temp %s (max %sC)   \e[1;31m%s\e[0m' $(( ST+1 )) "${t:+${t}C}" "$maxt" "$alerts"
    winms=0; winn=0
  }

  START=$(date +%s); alerts=""
  local stop=0 lost=0
  trap 'stop=1' INT                             # Ctrl+C ends the scan but still prints the result
  while [ $b -lt $total ] && [ $stop = 0 ]; do
    t0=$(date +%s%N)
    if dd if="$dev" of=/dev/null bs=1M count=$CHUNK skip=$(( b*CHUNK )) $DIRECT status=none 2>/dev/null; then
      t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); readms=$(( readms + ms )); winms=$(( winms + ms )); winn=$(( winn + 1 ))
      [ $ms -gt $worst ] && worst=$ms
      if   [ $ms -lt $T1 ]; then lv=0; good=$((good+1))
      elif [ $ms -lt $T2 ]; then lv=1; ok=$((ok+1))
      elif [ $ms -lt $T3 ]; then lv=2; slow=$((slow+1))
      else                       lv=3; vslow=$((vslow+1)); fi
    else
      [ $stop = 1 ] && break                    # read interrupted by Ctrl+C, not a disk error
      # Did the disk drop off the bus (USB power / adapter reset)? Then stop instead of drawing X forever.
      if [ ! -b "$dev" ] || [ -z "$(blockdev --getsize64 "$dev" 2>/dev/null)" ] || kern_lines | grep -qiE 'disconnect|offline device'; then
        lost=1; break
      fi
      lv=4; bad=$((bad+1)); badlist="$badlist $(( b*CHUNK/1024 ))G"
    fi
    i=$((i+1)); cn=$((cn+1)); [ $lv -gt $cw ] && cw=$lv
    [ $cn -ge $K ] && drawcell
    now=$(date +%s)
    if [ $now -ne $lastsec ]; then
      lastsec=$now
      if [ $(( now - lastchk )) -ge 10 ]; then   # SMART and kernel log every 10 s (smartctl is slow-ish)
        lastchk=$now
        t=$(temp_now "$dev"); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
        d=$(smart_deltas); k=$(kern_lines | wc -l)
        alerts="$d"; [ "$k" -gt 0 ] && alerts="$alerts${alerts:+ }kernel-errors:$k"
      fi
      status
    fi
    b=$(( b+step ))
  done
  trap - INT
  [ $cn -gt 0 ] && drawcell
  status
  printf '\e[?25h\e[%d;1H\n' $(( ST+2 ))      # cursor back, results go below the status lines

  local nread=$(( good+ok+slow+vslow )) speed=""
  [ $readms -gt 0 ] && speed=$(( nread*CHUNK*1049/readms ))
  sm_after=$(smart_line "$dev"); t=$(temp_now "$dev"); [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
  d=$(smart_deltas); local kl; kl=$(kern_lines); k=$(printf '%s' "$kl" | grep -c .)
  chg=""; [ -n "$d" ] && chg="   <- error counters GREW during the scan: $d"
  [ $lost = 1 ] && { sm_after="not available (the disk is gone)"; chg=""; }
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

  local hung=""
  [ $lost = 1 ] && hung=$(printf '%s\n' "$kl" | sed -n 's/.*I\/O error, dev [^,]*, sector \([0-9]*\).*/\1/p' | head -1)
  if [ $lost = 1 ] && [ -n "$hung" ]; then
    printf '\n  \e[1;37;41m DISK DISCONNECTED: it hung on an unreadable sector at %s GB \e[0m\n' "$(( hung / 2097152 ))"
    echo "  The disk could not read sector $hung, kept retrying (clicking) and the controller/USB adapter"
    echo "  gave up and reset it. This is a failing disk${prebad:+ (SMART already reported:$prebad)}."
    echo "  Copy the data off with care (file rescue / ddrescue), do not trust this disk."
  elif [ $lost = 1 ]; then
    printf '\n  \e[1;37;41m DISK DISCONNECTED during the scan at %s GB \e[0m\n' "$(( b*CHUNK/1024 ))"
    echo "  The disk vanished without a read error first. Usually: not enough power on the USB port,"
    echo "  a bad USB adapter or cable. Try another port, a Y-cable / powered adapter, or SATA, then scan again."
  fi
  local nslow=$(( slow + vslow )) verdict
  if [ $lost = 1 ] && [ -n "$hung" ]; then
    verdict="READ ERRORS - disk hung on an unreadable sector at $(( hung / 2097152 )) GB and dropped off - disk is failing, copy the data off first"
  elif [ $lost = 1 ]; then
    verdict="DISK DISCONNECTED during the scan - check power / USB adapter / cable before judging the disk"
  elif [ $bad -gt 0 ]; then
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
  [ -n "$prebad" ] && [ $bad -eq 0 ] && [ -z "$hung" ] && warn="$warn; SMART bad sectors:$prebad"
  [ -n "$warn" ] && [ $bad -eq 0 ] && [ -z "$hung" ] && verdict="$verdict (but:${warn#;})"
  printf '  Verdict      : \e[1m%s\e[0m\n' "$verdict"
  report_add "Disk check ($1) $dev $model: ${speed:-?} MB/s, fast=$good slow=$nslow bad=$bad, worst ${worst}ms - $verdict"
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
  report_add "Self-test    : $dev ${res:-no result}${h:+, SMART health $h}"
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
