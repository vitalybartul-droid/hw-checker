#!/bin/bash
# ramtest.sh — RAM test from the running live system with memtester.
# Tests the free RAM (the live system itself keeps ~0.5-1 GB).
# For a test of 100% of RAM use MemTest86+ (needs Secure Boot off).
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

echo
echo "================ RAM TEST ================"
if ! command -v memtester >/dev/null; then
  echo "  memtester is not installed."
  echo "  Put memtester_*_amd64.deb (Debian 13 / trixie) into hwcheck/debs/ on the stick and reboot."
  read -r -s -n 1 -p "  Press any key to return..." _; echo
  exit 0
fi

avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
full=$(( avail - 400 ))          # leave room so the system doesn't run out of memory
[ $full -lt 256 ] && full=256
echo "  Q = quick: 1024 MB, one pass (a few minutes)"
echo "  F = full : ${full} MB of free RAM, one pass (can take 30+ minutes)"
read -r -p "  Choice [Q/F, other = cancel]: " ch
case $ch in
  q|Q) size=1024 ;;
  f|F) size=$full ;;
  *) exit 0 ;;
esac
[ $size -gt $full ] && size=$full

echo "  Testing ${size} MB. Ctrl+C stops the test."
trap 'echo; echo "  Stopped by user."' INT
log=/tmp/ramtest.log
memtester "${size}M" 1 2>&1 | tee "$log"
trap - INT
if grep -qiE 'FAILURE' "$log"; then
  r="RAM test (${size} MB): FAILED !!! $(grep -ciE 'FAILURE' "$log") error(s)"
elif grep -q 'Done' "$log"; then
  r="RAM test (${size} MB): passed"
else
  r="RAM test (${size} MB): not finished"
fi
echo; echo "  $r"
echo "$r" >> /tmp/hwcheck.txt
read -r -s -n 1 -p "  Press any key to return..." _; echo
