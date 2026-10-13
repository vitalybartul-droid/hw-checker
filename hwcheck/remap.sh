#!/bin/bash
# remap.sh DEV — REMAP unreadable sectors of an HDD (key M, Disks screen; HDDs only).
# An HDD cannot read a weak sector ("pending") until something WRITES to it: the write lets the
# drive test the spot and, if it is really bad, swap it for a spare sector ("reallocated").
# This screen finds the unreadable sectors and writes zeros to EXACTLY those sectors - their data
# is lost already; everything readable stays untouched. Then it reads them again to check.
# Where it looks (no full-disk pass needed):
#   - the LBA of the first error in the SMART self-test log (run T first),
#   - "I/O error ... sector N" lines in the kernel log (left by a surface scan that hit them),
#   - the unreadable 32 MiB blocks remembered by the last surface scan.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"

dev=$1
[ -b "$dev" ] || { echo "  No such disk: $dev"; pause; exit 1; }
target_ok "$dev" || { pause; exit 1; }
DN=$(basename "$dev")
model=$(lsblk -dno MODEL "$dev" 2>/dev/null | xargs)
sz=$(blockdev --getsize64 "$dev" 2>/dev/null)
# Units: everything below counts PHYSICAL sectors k, which start at byte AO + k*PB.
#   LS = logical sector (what SMART LBAs count: 512, or 4096 on 4Kn disks)
#   PB = physical sector (4096 on most HDDs since ~2011, also on 512e ones)
#   AO = alignment offset (almost always 0; old "jumpered" 512e disks: 3584)
#   kernel "I/O error ... sector N" is always in 512-byte units.
LS=$(blockdev --getss "$dev" 2>/dev/null); [ -n "$LS" ] && [ "$LS" -ge 512 ] || LS=512
PB=$(blockdev --getpbsz "$dev" 2>/dev/null); [ -n "$PB" ] && [ "$PB" -ge "$LS" ] || PB=$LS
AO=$(cat "/sys/block/$(basename "$dev")/alignment_offset" 2>/dev/null); [[ $AO =~ ^[0-9]+$ ]] || AO=0
[ $(( AO % LS )) = 0 ] || AO=0
maxsec=$(( (sz - AO) / PB ))                     # whole physical sectors on the disk
b2k() { local b=$(( $1 - AO )); [ $b -lt 0 ] && b=0; echo $(( b / PB )); }   # byte -> physical sector
TRAN=$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ')
gone() { [ ! -b "$dev" ] || [ -z "$(blockdev --getsize64 "$dev" 2>/dev/null)" ]; }
counters() { smart_vals "$dev" | awk -F= '$1=="pending"||$1=="realloc"||$1=="uncorr"{printf "%s=%s ", $1, $2}'; }

clear; title "REMAP BAD SECTORS - $dev $model"
echo "  Writes zeros ONLY to sectors that cannot be read (their data is already lost), so the"
echo "  disk can test them and swap real bad ones for spares. Readable data is not touched."
echo

# ---------- collect regions to probe: "first_sector count" in physical sectors ----------
smart_detect "$dev" >/dev/null 2>&1
before=$(counters)
regions=()
around() { local k; k=$(b2k "$1"); echo "$(( k > 256 ? k - 256 : 0 )) 512"; }   # 512 physical sectors around a byte
# 1) SMART self-test log: last column = LBA_of_first_error (in LOGICAL sectors) when a test failed
while read -r lba; do
  [ -n "$lba" ] && regions+=("$(around $(( lba * LS )))")
done < <(smartctl $SMARTD -l selftest "$dev" 2>/dev/null | awk '/^# *[0-9]/ && $NF ~ /^[0-9]+$/ {print $NF}' | sort -u | head -8)
n_smart=${#regions[@]}
# 2) kernel log: I/O error sectors on this disk (always 512-byte units)
while read -r lba; do
  [ -n "$lba" ] && regions+=("$(around $(( lba * 512 )))")
done < <(dmesg 2>/dev/null | sed -n "s/.*I\/O error, dev $DN, sector \([0-9]*\).*/\1/p" | sort -un | head -16)
n_kern=$(( ${#regions[@]} - n_smart ))
# 3) unreadable 32 MiB blocks from the last surface scan
n_scan=0
if [ -s "/tmp/scan-$DN.bad" ] && scan_is_this_disk "$dev"; then
  while read -r b; do
    regions+=("$(b2k $(( b * 33554432 ))) $(( 33554432 / PB + 1 ))"); n_scan=$((n_scan+1))
  done < <(sort -un "/tmp/scan-$DN.bad" | head -16)
fi
echo "  SMART now    : ${before:-not available}"
echo "  Places found : $n_smart from the SMART self-test log, $n_kern from the kernel log, $n_scan from the last scan"
if [ ${#regions[@]} -eq 0 ]; then
  echo
  echo "  No known bad places yet. First run T (SMART self-test) or F (full scan) on this disk:"
  echo "  they record where the unreadable sectors are, then come back to M."
  pause; exit 0
fi
[ "$TRAN" = usb ] && printf '\n  \e[1;33mVia USB: if the disk hangs on a bad sector the adapter may reset it. SATA is more reliable.\e[0m\n'
keybar Y "Start" Q Back
while :; do getkey; case $KEY in y) break ;; q|n) exit 0 ;; esac; done

# partitions mounted by file rescue must be released first - and must really be released
for p in $(lsblk -lnpo NAME "$dev" | tail -n +2); do findmnt -rn -S "$p" >/dev/null 2>&1 && umount "$p" 2>/dev/null; done
if lsblk -lnpo MOUNTPOINT "$dev" | grep -q .; then
  echo; echo "  A partition of this disk is still in use (open files in file rescue?) - cannot remap."; pause; exit 1
fi

# ---------- probe each region; write zeros to each physical sector that cannot be read ----------
CH=$(( 65536 / PB )); [ $CH -lt 1 ] && CH=1      # probe 64 KiB at a time, single sectors only on error
fixed=0 still=0 probed=0 bad=0 stop=0 lost=0 list=""
readsec() { ( trap '' INT; dd if="$dev" of=/dev/null bs=$PB count=${2:-1} skip=$(( AO + $1 * PB )) iflag=direct,skip_bytes status=none 2>/dev/null ); }
lba() { echo $(( (AO + $1 * PB) / LS )); }      # physical sector -> LBA as SMART shows it
trap 'stop=1' INT
echo
for r in "${regions[@]}"; do
  read -r first cnt <<< "$r"
  [ $(( first + cnt )) -gt $maxsec ] && cnt=$(( maxsec - first ))
  s=$first
  while [ $s -lt $(( first + cnt )) ] && [ $stop = 0 ]; do
    n=$CH; [ $(( s + n )) -gt $(( first + cnt )) ] && n=$(( first + cnt - s ))
    printf '\r\e[K  Checking sector %d (%s GB)   unreadable %d, fixed %d, still bad %d   (Ctrl+C = stop)' \
      $(lba $s) $(( (AO + s * PB) / 1000000000 )) $bad $fixed $still
    if ! readsec $s $n; then
      gone && { lost=1; break 2; }
      for (( x = s; x < s + n && stop == 0; x++ )); do
        # a single failed read can be a timeout or a USB reset, not a bad sector: try 3 times,
        # and zero the sector only if it fails every time (and the disk is still there)
        readsec $x && continue
        gone && { lost=1; break 3; }
        sleep 0.2; readsec $x && continue
        sleep 0.5; readsec $x && continue
        gone && { lost=1; break 3; }
        bad=$((bad+1))
        ( trap '' INT; dd if=/dev/zero of="$dev" bs=$PB count=1 seek=$(( AO + x * PB )) oflag=direct,seek_bytes conv=notrunc,fsync status=none 2>/dev/null )
        if readsec $x; then fixed=$((fixed+1)); else still=$((still+1)); fi
        list="$list $(lba $x)"
      done
    fi
    probed=$(( probed + n )); s=$(( s + n ))
  done
  [ $stop = 1 ] && break
done
trap - INT
echo; echo
sync
after=$(counters)
echo "  Probed       : $probed sectors around ${#regions[@]} place(s)$([ $stop = 1 ] && echo '  - STOPPED by Ctrl+C')"
echo "  Unreadable   : $bad   rewritten and readable now: $fixed   still unreadable: $still"
[ -n "$list" ] && echo "  Sectors (LBA):$(echo $list | tr ' ' '\n' | head -12 | tr '\n' ' ')$([ $bad -gt 12 ] && echo ...)"
echo "  SMART before : ${before:-n/a}"
echo "  SMART after  : ${after:-n/a}"
if [ $lost = 1 ]; then res="disk dropped off while reading a bad sector - connect it by SATA (or a powered adapter) and run M again"
elif [ $bad -eq 0 ]; then res="no unreadable sectors at the known places - nothing to remap"
elif [ $still -gt 0 ]; then res="$still sector(s) still unreadable after writing - the disk cannot remap them, it is failing"
else res="$fixed sector(s) rewritten and readable again; see realloc/pending above"; fi
printf '  Result       : \e[1m%s\e[0m\n' "$res"
echo "  Next         : run F (full scan) to look for more, and T (self-test) to confirm."
report_add "Remap        : $dev $model - unreadable $bad, fixed $fixed, still bad $still - SMART ${before:-n/a}-> ${after:-n/a} - $res"
pause
