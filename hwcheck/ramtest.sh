#!/bin/bash
# ramtest.sh — RAM test from the running live system with memtester.
# Tests the free RAM (the live system itself keeps ~0.5-1 GB).
# For a test of 100% of RAM use MemTest86+ (needs Secure Boot off).
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"

clear; title "RAM TEST"
if ! command -v memtester >/dev/null; then
  echo "  memtester is not installed."
  echo "  Put memtester_*_amd64.deb (Debian 13 / trixie) into hwcheck/debs/ on the stick and reboot."
  pause; exit 0
fi

avail=$(awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo)
full=$(( avail - 400 ))          # leave room so the system doesn't run out of memory
[ $full -lt 256 ] && full=256
echo "  Tests the free RAM with memtester (the live system itself keeps ~0.5-1 GB)."
echo "  Quick = 1024 MB, one pass, a few minutes.  Full = ${full} MB, one pass, can take 30+ minutes."
keybar Enter "Quick (1 GB)" F "Full (${full} MB)" Q Back
getkey
case $KEY in
  "") size=1024 ;;
  f)  size=$full ;;
  *)  exit 0 ;;
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
pause
