#!/bin/bash
# disks.sh — disk check for intake and repair (key D). All checks are READ-ONLY;
# R = refresh (refresh.sh: rewrites the same data in place) and E = erase (erase.sh) write.
#   Enter = quick check: SMART + read speed + surface scan at ~300 points (about a minute)
#   F     = full surface scan, Victoria-style latency map of the whole disk
#   S     = seek test (HDD only): random reads, head positioning time
#   T     = SMART short self-test (the drive tests itself, ~2 min)
#   R     = REFRESH: read each block and write the same data back (slow SSD zones) - see refresh.sh
#   M     = REMAP (HDD): write zeros only to unreadable sectors so the drive swaps them - see remap.sh
#   E     = ERASE the disk (quick / secure / overwrite) - see erase.sh
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
case $RPM in *"Solid State"*) ROT=0 ;; *rpm*) ROT=1 ;; esac          # USB adapters often claim "rotational"
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
    | grep -iE 'error|reset|timeout|offline|disconnect|fail|abort' | grep -viE 'completion polled'
}
# "nvme: I/O tag N QID x timeout, completion polled" = the command DID complete, only its
# interrupt was lost (NVMe power saving / firmware quirk under Linux). Not a disk fault: counted apart.
kern_polled() {
  dmesg 2>/dev/null | tail -n +$(( KBASE + 1 )) | grep -ciE 'nvme.*completion polled'
}

# ---------- surface scan: $1 = quick | full ----------
# Full-screen layout that never scrolls: header (title, SMART, legend) / map of the WHOLE disk /
# status lines. If there are more blocks than cells, one cell covers several blocks and takes
# the colour of the WORST of them, so no slow or bad spot is hidden.
scan() {
  local CHUNK=32 total step niters START i=0 b=0 ms t t0 t1 el pct eta d k alerts lv zf zms kp=0 tt qalerts="" bgpid="" BGF=/tmp/.scanbg.$$
  local good=0 ok=0 slow=0 vslow=0 bad=0 worst=0 readms=0 badlist="" maxt sm_before sm_after chg
  total=$(( (sz + CHUNK*1048576 - 1) / (CHUNK*1048576) )); [ $total -lt 1 ] && total=1   # last, shorter block included
  step=1; [ "$1" = quick ] && { step=$(( total/300 )); [ $step -lt 1 ] && step=1; }
  niters=$(( (total + step - 1) / step ))

  SB=(); while IFS='=' read -r k d; do SB[$k]=$d; done < <(smart_vals "$dev")
  KBASE=$(dmesg 2>/dev/null | wc -l); DN=$(basename "$dev")
  sm_before=$(smart_line "$dev"); t=$(temp_now "$dev"); maxt=${t:-0}
  local prebad=""                               # unstable / unreadable sectors known before we start
  for k in pending uncorr media_errors; do [ "${SB[$k]:-0}" -gt 0 ] 2>/dev/null && prebad="$prebad $k=${SB[$k]}"; done

  # the map starts below the header; the header grows by one line for each optional line in it
  local LN CL W MROWS K ncells used ST MAPTOP=8 cellmb cellsz
  [ -n "$prebad" ] && MAPTOP=$((MAPTOP+1))
  [ "$ROT" = 1 ] && MAPTOP=$((MAPTOP+1))
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


  clear; printf '\e[?25l'                       # hide the cursor while drawing
  title "SURFACE SCAN ($1) - $dev $model${RPM:+, $RPM}"
  echo "  SMART before : $sm_before${t:+   temp ${t}C}"
  [ -n "$prebad" ] && printf '  \e[1;31m!! The disk already reports bad sectors:%s - expect slow or unreadable spots\e[0m\n' "$prebad"
  printf '  %s scale:  %s fast (>%s MB/s)  %s ok (%s-%s)  %s slow (%s-%s)  %s very slow (<%s)  %s unreadable\n' \
    "$CLASS" "$C_FAST" $MB1 "$C_OK" $MB2 $MB1 "$C_SLOW" $MB3 $MB2 "$C_VSLOW" $MB3 "$C_BAD"
  [ "$ROT" = 1 ] && echo "  (HDD: speeds for the start of the disk; the end is normally half as fast and is judged accordingly)"
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
    printf '\e[%d;1H\e[K  temp %s (max %sC)   \e[1;31m%s\e[0m  \e[1;33m%s\e[0m' $(( ST+1 )) "${t:+${t}C}" "$maxt" "$alerts" "$qalerts"
    winms=0; winn=0
  }

  SLOWF=/tmp/scan-$DN.slow; : > "$SLOWF.tmp"
  BADF=/tmp/scan-$DN.bad; : > "$BADF"            # unreadable blocks, for Remap (M): only from THIS scan
  # which physical disk the lists belong to: sdb today may be another disk after a swap
  # every scan (quick too) rewrites .bad, so every scan records whose lists these are; a slow list
  # left by a full scan of ANOTHER disk under the same name is dropped
  local nid; nid=$(disk_id "$dev")
  [ "$(cat "/tmp/scan-$DN.id" 2>/dev/null)" = "$nid" ] || rm -f "$SLOWF"
  echo "$nid" > "/tmp/scan-$DN.id"
  START=$(date +%s); alerts=""
  local stop=0 lost=0
  trap 'stop=1' INT                             # Ctrl+C ends the scan but still prints the result
  while [ $b -lt $total ] && [ $stop = 0 ]; do
    t0=$(date +%s%N)
    if dd if="$dev" of=/dev/null bs=1M count=$CHUNK skip=$(( b*CHUNK )) $DIRECT status=none 2>/dev/null; then
      t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 )); readms=$(( readms + ms )); winms=$(( winms + ms )); winn=$(( winn + 1 ))
      [ $ms -gt $worst ] && worst=$ms
      # HDD: the inner end of the platters is read about twice as slowly as the outer start, by design
      # (fewer sectors per turn). Scale the thresholds with the position so a normal disk stays green.
      zf=1000; [ "$ROT" = 1 ] && zf=$(( 1000 + 1000 * b / total ))
      zms=$(( ms * 1000 / zf ))
      if   [ $zms -lt $T1 ]; then lv=0; good=$((good+1))
      elif [ $zms -lt $T2 ]; then lv=1; ok=$((ok+1))
      elif [ $zms -lt $T3 ]; then lv=2; slow=$((slow+1))
      else                       lv=3; vslow=$((vslow+1)); fi
      echo "$b $ms $lv" >> "$SLOWF.tmp"          # every block's read time, for Refresh (R)
    else
      [ $stop = 1 ] && break                    # read interrupted by Ctrl+C, not a disk error
      # Did the disk drop off the bus (USB power / adapter reset)? Then stop instead of drawing X forever.
      if [ ! -b "$dev" ] || [ -z "$(blockdev --getsize64 "$dev" 2>/dev/null)" ] || kern_lines | grep -qiE 'disconnect|offline device'; then
        lost=1; break
      fi
      lv=4; bad=$((bad+1)); badlist="$badlist $(( b*CHUNK/1024 ))G"
      echo $b >> "$BADF"
    fi
    i=$((i+1)); cn=$((cn+1)); [ $lv -gt $cw ] && cw=$lv
    [ $cn -ge $K ] && drawcell
    now=$(date +%s)
    if [ $now -ne $lastsec ]; then
      lastsec=$now
      # SMART and kernel log every 10 s, IN THE BACKGROUND: a slow or stuck smartctl
      # (e.g. NVMe lost interrupt = up to 60 s) must never pause the scan itself.
      if [ $(( now - lastchk )) -ge 10 ] && ! { [ -n "$bgpid" ] && kill -0 "$bgpid" 2>/dev/null; }; then
        lastchk=$now
        ( x1=$(temp_now "$dev"); x2=$(smart_deltas); x3=$(kern_lines | wc -l); x4=$(kern_polled)
          printf '%s|%s|%s|%s\n' "$x1" "$x2" "$x3" "$x4" > "$BGF.tmp" && mv -f "$BGF.tmp" "$BGF" ) </dev/null >/dev/null 2>&1 &
        bgpid=$!
      fi
      if [ -s "$BGF" ]; then
        IFS='|' read -r tt d k kp < "$BGF"; rm -f "$BGF"
        [ -n "$tt" ] && t=$tt; [ -n "$t" ] && [ "$t" -gt "$maxt" ] && maxt=$t
        alerts="$d"; [ "${k:-0}" -gt 0 ] && alerts="$alerts${alerts:+ }kernel-errors:$k"
        qalerts=""; [ "${kp:-0}" -gt 0 ] && qalerts="nvme-irq-quirk:$kp (harmless)"
      fi
      status
    fi
    b=$(( b+step ))
  done
  trap - INT
  [ -n "$bgpid" ] && kill "$bgpid" 2>/dev/null; rm -f "$BGF" "$BGF.tmp"
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
  kp=$(kern_polled)
  if [ "$kp" -gt 0 ]; then
    printf '  \e[1;33mNVMe note    : %s command(s) "timeout, completion polled" - the disk answered, Linux missed the\e[0m\n' "$kp"
    printf '  \e[1;33m               interrupt (NVMe power-saving quirk). Not a disk fault; Windows is not affected.\e[0m\n'
  fi

  local hung=""
  [ $lost = 1 ] && hung=$(printf '%s\n' "$kl" | sed -n 's/.*I\/O error, dev [^,]*, sector \([0-9]*\).*/\1/p' | head -1)
  local tmo; tmo=$(printf '%s\n' "$kl" | grep -ciE 'error=-110|timed? ?out')     # disk stopped answering
  if [ $lost = 1 ] && [ -n "$hung" ]; then
    printf '\n  \e[1;37;41m DISK DISCONNECTED: it hung on an unreadable sector at %s GB \e[0m\n' "$(( hung / 2097152 ))"
    echo "  The disk could not read sector $hung, kept retrying (clicking) and the controller/USB adapter"
    echo "  gave up and reset it. This is a failing disk${prebad:+ (SMART already reported:$prebad)}."
    echo "  Copy the data off with care (file rescue / ddrescue), do not trust this disk."
  elif [ $lost = 1 ] && { [ -n "$prebad" ] || [ "$tmo" -gt 0 ]; }; then
    printf '\n  \e[1;37;41m DISK HUNG and dropped off at %s GB \e[0m\n' "$(( b*CHUNK/1024 ))"
    echo "  The disk stopped answering (timeout) and the controller / USB adapter reset it."
    [ -n "$prebad" ] && echo "  SMART already reported bad sectors before the scan:$prebad - it most likely hung on one of them."
    echo "  Treat it as a failing disk and copy the data off with care. To rule out power, try another port / SATA."
  elif [ $lost = 1 ]; then
    printf '\n  \e[1;37;41m DISK DISCONNECTED during the scan at %s GB \e[0m\n' "$(( b*CHUNK/1024 ))"
    echo "  The disk vanished without a read error first. Usually: not enough power on the USB port,"
    echo "  a bad USB adapter or cable. Try another port, a Y-cable / powered adapter, or SATA, then scan again."
  fi
  local nslow=$(( slow + vslow )) verdict
  if [ $lost = 1 ] && [ -n "$hung" ]; then
    verdict="READ ERRORS - disk hung on an unreadable sector at $(( hung / 2097152 )) GB and dropped off - disk is failing, copy the data off first"
  elif [ $lost = 1 ] && { [ -n "$prebad" ] || [ "$tmo" -gt 0 ]; }; then
    verdict="DISK HUNG and dropped off${prebad:+ (SMART bad sectors:$prebad)} - most likely failing, copy the data off; rule out power with another port"
    prebad=""                                   # already in the verdict
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
  elif [ "$ROT" = 1 ] && [ "$1" = quick ]; then
    # the quick scan reads one block per cell: a single hiccup paints a whole cell, so do not judge yet
    verdict="some slow reads in the quick sample - run F (full scan): slow in the same places = weak sectors"
  elif [ "$ROT" = 1 ]; then
    verdict="slow sectors, no errors yet - HDD starting to wear"
  else
    verdict="slow zones, no read errors - typical of cheap SSD controllers; scan again: slow in the SAME places = aging data, elsewhere = normal"
  fi
  [ -n "$prebad" ] && [ $bad -eq 0 ] && [ -z "$hung" ] && warn="$warn; SMART bad sectors:$prebad"
  [ -n "$warn" ] && [ $bad -eq 0 ] && [ -z "$hung" ] && verdict="$verdict (but:${warn#;})"
  [ "$kp" -gt 0 ] && verdict="$verdict [NVMe lost interrupts: $kp, harmless]"
  printf '  Verdict      : \e[1m%s\e[0m\n' "$verdict"
  # a completed FULL scan leaves its list of slow blocks for Refresh (R)
  # "Slow for Refresh" is judged against THIS disk's own typical speed, not only the colour scale:
  # a block 1.5x slower than the disk's median read (and not fast by the class scale), or any
  # slow/very slow block. On a disk that tops out near the class limit (e.g. a DRAM-less NVMe at
  # ~530 MB/s) the orange "ok" zones are exactly the aged ones Refresh fixes.
  local nref=0 med
  if [ "$1" = full ] && [ $stop = 0 ] && [ $lost = 0 ]; then
    med=$(awk '{print $2}' "$SLOWF.tmp" | sort -n | awk '{a[NR]=$1} END{print (NR ? a[int((NR+1)/2)] : 0)}')
    awk -v m="$med" -v t1="$T1" '$3>=2 || ($2*2 > m*3 && $2 >= t1) {print $1}' "$SLOWF.tmp" > "$SLOWF"
    nref=$(grep -c . "$SLOWF")
  fi
  rm -f "$SLOWF.tmp"
  if [ "$ROT" != 1 ] && [ $bad -eq 0 ] && [ $lost = 0 ] && [ $nref -gt 0 ] && [ $(( nref * 100 / (i>0?i:1) )) -ge 1 ]; then
    echo "  Tip          : $nref block(s) are much slower than this disk's typical speed (${med} ms). R (Refresh) rewrites"
    echo "                 them in place - on SSDs such zones of old data often become fast again."
  fi
  report_add "Disk check ($1) $dev $model: ${speed:-?} MB/s, fast=$good slow=$nslow bad=$bad, worst ${worst}ms - $verdict"
}

# ---------- HPA / DCO: part of the disk hidden from the system (SATA only) ----------
# HPA = Host Protected Area (set by some OEM recovery tools or malware), DCO = Device Configuration
# Overlay (capacity cut by the vendor or by someone selling a "smaller" disk). Quiet when nothing hidden.
HPA=""
hpa_check() {
  case $TRAN in sata|ata) ;; *) return ;; esac
  command -v hdparm >/dev/null 2>&1 || return
  local n cur nat real
  n=$(hdparm -N "$dev" 2>/dev/null | sed -n 's/.*max sectors *= *\([0-9]*\)\/\([0-9]*\).*/\1 \2/p')
  read -r cur nat <<< "$n"
  if [ -n "$cur" ] && [ -n "$nat" ] && [ "$nat" -gt "$cur" ]; then
    HPA="HPA hides $(( (nat - cur) * 512 / 1000000000 )) GB ($cur of $nat sectors visible) - removable with hdparm -N"
  fi
  real=$(hdparm --dco-identify "$dev" 2>/dev/null | sed -n 's/.*Real max sectors: *\([0-9]*\).*/\1/p')
  if [ -n "$real" ] && [ -n "$nat" ] && [ "$real" -gt "$nat" ]; then
    HPA="${HPA:+$HPA; }DCO hides $(( (real - nat) * 512 / 1000000000 )) GB (disk is really $(( real * 512 / 1000000000 )) GB)"
  fi
}
hpa_check

# ---------- HDD seek test: how fast the heads move ----------
# 1000 random 4 KiB reads across the whole disk. Access time = head seek + half a rotation.
# A healthy laptop HDD is ~12-20 ms; worn mechanics show a higher average and many very slow
# seeks (the drive retries positioning) even when sequential reading looks fine.
seektest() {
  clear; title "SEEK TEST - $dev $model${RPM:+, $RPM}"
  echo "  1000 random reads across the whole disk: measures how fast the heads move. Read-only."
  echo
  local n=1000 i total r t0 t1 us sum=0 max=0 s100=0 s500=0 err=0 oh=0 lst=() stop=0
  local ID=iflag=direct
  dd if="$dev" of=/dev/null bs=4096 count=1 iflag=direct status=none 2>/dev/null || ID=""
  # calibration: re-reading one sector comes from the drive cache, so what remains is the
  # cost of starting dd itself (slow CPUs: 1-3 ms) - subtracted from every measurement
  local c=()
  for i in 1 2 3 4 5 6 7 8 9 10 11; do
    t0=$(date +%s%N); dd if="$dev" of=/dev/null bs=4096 count=1 $ID status=none 2>/dev/null; t1=$(date +%s%N)
    c+=($(( (t1 - t0) / 1000 )))
  done
  oh=$(printf '%s\n' "${c[@]:1}" | sort -n | sed -n 5p)    # median of 10 (first run warms up)
  total=$(( sz / 4096 ))
  trap 'stop=1' INT
  printf '\e[?25l'
  for (( i = 1; i <= n && stop == 0; i++ )); do
    r=$(( ((RANDOM << 30) | (RANDOM << 15) | RANDOM) % total ))
    t0=$(date +%s%N)
    dd if="$dev" of=/dev/null bs=4096 count=1 skip=$r $ID status=none 2>/dev/null || err=$((err+1))
    t1=$(date +%s%N)
    us=$(( (t1 - t0) / 1000 - oh )); [ $us -lt 0 ] && us=0
    lst+=($us); sum=$(( sum + us )); [ $us -gt $max ] && max=$us
    [ $us -gt 100000 ] && s100=$((s100+1)); [ $us -gt 500000 ] && s500=$((s500+1))
    [ $(( i % 25 )) -eq 0 ] && printf '\r\e[K  %4d / %d   average %s ms   slowest %d ms   >100 ms: %d' \
      $i $n "$(awk -v s=$sum -v k=$i 'BEGIN{printf "%.1f", s/k/1000}')" $(( max / 1000 )) $s100
  done
  trap - INT; printf '\e[?25h\n\n'
  local k=${#lst[@]}; [ $k -eq 0 ] && return
  local avg p95 lim=22000 typ="laptop HDD"
  avg=$(( sum / k ))
  p95=$(printf '%s\n' "${lst[@]}" | sort -n | sed -n "$(( (k * 95 + 99) / 100 ))p")
  case $RPM in *7200*) lim=18000; typ="7200 rpm" ;; *5400*) lim=22000; typ="5400 rpm" ;; *4200*) lim=26000; typ="4200 rpm" ;; esac
  [ "$TRAN" = usb ] && lim=$(( lim + 2000 ))      # USB adapters add a little latency
  printf '  Access time  : average %s ms, 95%% within %s ms, slowest %s ms   (%d reads, start-up %s ms subtracted)\n' \
    "$(awk -v a=$avg 'BEGIN{printf "%.1f", a/1000}')" "$(awk -v a=$p95 'BEGIN{printf "%.1f", a/1000}')" $(( max / 1000 )) $k \
    "$(awk -v a=$oh 'BEGIN{printf "%.1f", a/1000}')"
  echo "  Very slow    : $s100 over 100 ms, $s500 over 500 ms   (healthy: almost none)"
  [ $err -gt 0 ] && printf '  \e[1;31mRead errors  : %d\e[0m\n' $err
  local v
  if [ $err -gt 0 ]; then v="READ ERRORS during seeking - disk is failing"
  elif [ $(( s100 * 100 )) -gt $(( k * 2 )) ] || [ $s500 -gt 2 ]; then v="heads struggling - many very slow seeks (retries), mechanics wearing out"
  elif [ $avg -gt $(( lim * 3 / 2 )) ]; then v="heads very slow (average far above normal for a $typ) - worn mechanics"
  elif [ $avg -gt $lim ]; then v="heads slower than typical for a $typ - mild wear, or a slow USB adapter"
  else v="heads OK (normal for a $typ)"; fi
  [ $stop = 1 ] && v="$v (stopped early)"
  # heads OK does not mean the disk is OK: the surface may have unreadable sectors in one spot
  local pb=""; pb=$(smart_vals "$dev" | awk -F= '($1=="pending"||$1=="uncorr") && $2+0>0 {printf " %s=%s", $1, $2}')
  [ -n "$pb" ] && v="$v - BUT SMART reports unreadable sectors ($pb ) - surface problem: run F, then M (remap)"
  printf '  Verdict      : \e[1m%s\e[0m\n' "$v"
  report_add "Seek test    : $dev $model: avg $(awk -v a=$avg 'BEGIN{printf "%.1f", a/1000}') ms, p95 $(awk -v a=$p95 'BEGIN{printf "%.1f", a/1000}') ms, >100ms $s100 - $v"
}

# ---------- SMART short self-test ----------
selftest() {
  clear; title "SMART SELF-TEST - $dev $model"
  have smartctl || { echo "  smartctl is not available."; return; }
  # Short = electronics + a small sample of the surface (~2 min): it can PASS on a disk with a few
  # bad sectors. Extended = the drive reads its WHOLE surface itself (HDD ~1-3 h, SSD minutes).
  local typ=short mins
  mins=$(smartctl $SMARTD -c "$dev" 2>/dev/null | sed -n 's/.*Extended self-test routine.*(\ *\([0-9]*\)).*/\1/p; /Extended self-test routine/{n;s/.*( *\([0-9]*\)) minutes.*/\1/p}' | head -1)
  echo "  Short    : ~2 min, electronics + a sample of the surface (can miss a few bad sectors)"
  echo "  Extended : the drive reads its whole surface itself${mins:+, ~$mins min}"
  keybar Enter "Short" L "Extended" Q Back
  while :; do getkey; case $KEY in "") break ;; l) typ=long; break ;; q) return ;; esac; done
  if ! smartctl $SMARTD -t $typ "$dev" >/dev/null 2>&1; then echo "  This drive (or its USB bridge) does not support this self-test."; return; fi
  local i=0 st pr res h
  while :; do                                   # until the drive reports it finished (Q = stop waiting)
    IFS= read -rsn1 -t 5 k && [ "${k,,}" = q ] && { smartctl $SMARTD -X "$dev" >/dev/null 2>&1; echo; echo "  Self-test aborted."; return; }
    i=$((i+1))
    st=$(smartctl $SMARTD -c -l selftest "$dev" 2>/dev/null)
    # NVMe prints "No self-test in progress" when idle: that line must not count as running
    if echo "$st" | grep -i 'in progress' | grep -qvi 'no self-test in progress'; then
      pr=$(echo "$st" | grep -oiE '[0-9]+% (of test remaining|completed)' | head -1)
      printf '\r\e[K  Running %s test... %s (%d min)   Q = abort' "$typ" "$pr" $(( i * 5 / 60 ))
    else break; fi
    [ $i -gt 8640 ] && break                    # 12 h safety limit
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
  [ -n "$HPA" ] && printf '  \e[1;33mHidden : %s\e[0m\n' "$HPA"
  echo "  Checks are READ-ONLY. R rewrites the same data in place; E erases. Both ask first."
  kb=(Enter "Quick check (~1 min)" F "Full surface scan")
  [ "$ROT" = 1 ] && kb+=(S "Seek test (heads, ~30 s)")
  kb+=(T "SMART self-test" R "Refresh (keeps data)")
  [ "$ROT" = 1 ] && kb+=(M "Remap bad sectors")
  kb+=(E "Erase disk")
  [ "$TRAN" = usb ] && kb+=(X "Eject (safe to unplug)")
  kb+=(Q Back)
  keybar "${kb[@]}"
  getkey
  case $KEY in
    "") scan quick; pause ;;
    f)  scan full;  pause ;;
    t)  selftest;   pause ;;   # Enter = short, L = extended (whole surface)
    s)  [ "$ROT" = 1 ] && { seektest; pause; } ;;
    x)  [ "$TRAN" = usb ] || continue
        # nothing here mounts the disk, but file rescue may have: release it, flush, and power the
        # disk down (an HDD parks its heads) so it can be unplugged safely
        for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do findmnt -rn -S "$p" >/dev/null 2>&1 && umount "$p" 2>/dev/null; done
        sync
        if lsblk -lnpo MOUNTPOINT "$dev" | grep -q .; then echo "  A partition is still in use - close it first."; pause; continue; fi
        echo 1 > "/sys/block/$(basename "$dev")/device/delete" 2>/dev/null
        printf '\n  \e[1;32m%s %s is switched off - safe to unplug.\e[0m\n' "$dev" "$model"; pause; break ;;
    m)  [ "$ROT" = 1 ] && bash "$(dirname "$(readlink -f "$0")")/remap.sh" "$dev" ;;
    r)  bash "$(dirname "$(readlink -f "$0")")/refresh.sh" "$dev" ;;
    e)  bash "$(dirname "$(readlink -f "$0")")/erase.sh" "$dev"
        sz=$(blockdev --getsize64 "$dev" 2>/dev/null || echo "$sz") ;;
    q)  break ;;
  esac
done
