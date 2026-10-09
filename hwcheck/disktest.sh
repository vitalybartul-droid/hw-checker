#!/bin/bash
# disktest.sh — non-destructive disk check: read speed + SMART short self-test.
# Nothing is written to the disks. Takes ~2-3 minutes per disk.
# stdout = result lines (hwcheck.sh appends them to the report);
# stderr = progress and hints, shown on screen only, so the report stays plain text.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
have() { command -v "$1" >/dev/null 2>&1; }

bootdev=""
src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
[ -n "$src" ] && bootdev=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)

echo
echo "================ DISK TEST ================"
have smartctl || echo "  (smartctl not installed: only the read speed test will run)"
for d in /sys/block/*; do
  n=$(basename "$d")
  case $n in loop*|ram*|zram*|sr*|fd*|dm-*|md*|mmcblk*boot*) continue ;; esac
  [ "$n" = "$bootdev" ] && continue
  [ "$(lsblk -dbno SIZE "/dev/$n" 2>/dev/null | tr -d ' ')" -gt 0 ] 2>/dev/null || continue
  model=$(cat "$d/device/model" 2>/dev/null | xargs)
  echo "  $n  $model"

  # 1) Sequential read speed: 1 GiB from the start of the disk, bypassing the cache
  t0=$(date +%s%N)
  if dd if="/dev/$n" of=/dev/null bs=4M count=256 iflag=direct status=none 2>/dev/null; then
    t1=$(date +%s%N)
    speed=$(awk -v t=$(( t1 - t0 )) 'BEGIN{printf "%.0f", 1073.741824 / (t/1e9)}')
    echo "    Read speed  : ${speed} MB/s   (typical: HDD 80-160, SATA SSD 400-550, NVMe 1500+)"
  else
    echo "    Read speed  : READ ERROR in the first 1 GiB !!!"
  fi

  # 2) SMART short self-test (the drive tests itself, ~1-2 min)
  have smartctl || continue
  if ! smartctl -t short "/dev/$n" >/dev/null 2>&1; then
    echo "    Self-test   : not supported by this drive"
    continue
  fi
  for i in $(seq 1 60); do               # up to 5 minutes
    sleep 5
    st=$(smartctl -c -l selftest "/dev/$n" 2>/dev/null)
    # NVMe prints "No self-test in progress" when idle, so that line must not count as running
    if echo "$st" | grep -i 'in progress' | grep -qvi 'no self-test in progress'; then
      pr=$(echo "$st" | grep -oiE '[0-9]+% (of test remaining|completed)' | head -1)
      printf '\r\e[K    Self-test   : running... %s (%ds)' "$pr" $(( i * 5 )) >&2
    else
      break
    fi
  done
  printf '\r\e[K' >&2
  res=$(smartctl -l selftest "/dev/$n" 2>/dev/null | grep -E '^ *#? *[0-9]+ +(Short|Extended|Offline)' | head -1 | sed -E 's/^ *#? *[0-9]+ +//; s/ {2,}/  /g')
  echo "    Self-test   : ${res:-no result (still running or not reported)}"
  h=$(smartctl -H "/dev/$n" 2>/dev/null | sed -nE 's/.*(self-assessment test result|Health Status): *([A-Z]+).*/\2/p' | head -1)
  [ -n "$h" ] && echo "    SMART health: $h"
done
echo "  Done. Results were added to /tmp/hwcheck.txt" >&2
