#!/bin/bash
# pwreset.sh — clear a LOCAL Windows account password with chntpw.
# Clears (empties) the password only. Does not touch group membership or lock state.
# Local accounts only: Microsoft (online) accounts cannot be reset this way.
# A BitLocker-encrypted system drive cannot be opened without the recovery key.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"
have(){ command -v "$1" >/dev/null 2>&1; }
have chntpw || { echo "  chntpw is not on this stick."; echo "  Add chntpw + ntfs-3g .deb to hwcheck/debs/ and rebuild."; pause; exit 1; }
is_bitlocker(){ dd if="$1" bs=512 count=1 2>/dev/null | grep -qa 'FVE-FS-'; }
modprobe fuse 2>/dev/null      # ntfs-3g runs on FUSE

clear; title "WINDOWS PASSWORD"
echo "  Empties the password of a LOCAL account so you can log in with no password."
echo "  It does NOT work for Microsoft (online) accounts."
echo
MNT=/mnt/win; mkdir -p "$MNT"; windev=""; WINS=()
echo "  Looking for Windows installations..."
while read -r dev fstype; do
  [ "$fstype" = ntfs ] || continue
  is_bitlocker "$dev" && { echo "  $dev: BitLocker-encrypted, skipped."; continue; }
  { mount -t ntfs3 -o ro "$dev" "$MNT" 2>/dev/null || mount -t ntfs-3g -o ro "$dev" "$MNT" 2>/dev/null; } || continue
  [ -f "$MNT/Windows/System32/config/SAM" ] && WINS+=("$dev")
  umount "$MNT" 2>/dev/null
done < <(lsblk -pnro NAME,FSTYPE 2>/dev/null)
[ ${#WINS[@]} -eq 0 ] && { echo "  No Windows found (no readable SAM). The drive may be BitLocker-encrypted."; pause; exit 1; }
if [ ${#WINS[@]} -eq 1 ]; then
  windev=${WINS[0]}
else
  # several Windows (two disks, or a client disk next to the PC's own): never guess which one
  echo; echo "  More than one Windows found:"
  i=1
  for d in "${WINS[@]:0:9}"; do
    pk=$(lsblk -npo PKNAME "$d" 2>/dev/null | head -1)
    printf '    %s %d %s  %-12s %7s  %-12s on %s %s\n' "$KEYC" $i "$KEYN" "$d" "$(lsblk -dno SIZE "$d" | xargs)" \
      "$(lsblk -dno LABEL "$d" | xargs)" "$pk" "$(lsblk -dno MODEL,TRAN "$pk" 2>/dev/null | xargs)"
    i=$((i+1))
  done
  n=${#WINS[@]}; [ $n -gt 9 ] && n=9
  keybar 1-$n "Windows" Q Cancel
  while :; do
    getkey
    case $KEY in
      q) exit 0 ;;
      [1-9]) [ "$KEY" -le $n ] && { windev=${WINS[$((KEY-1))]}; break; } ;;
    esac
  done
fi

echo "  Windows system drive: $windev"
# remove_hiberfile discards a saved Windows session (safe); recover replays the NTFS journal.
# We never use ntfs3 "force", which can corrupt a dirty filesystem.
echo "  If Windows was hibernated / Fast Startup, its saved session will be discarded"
echo "  (files are not touched; the next start is a normal full boot)."
keybar Y "Continue" Q Cancel
getkey; [ "$KEY" = y ] || exit 0
ntfs-3g -o remove_hiberfile,recover "$windev" "$MNT" 2>/dev/null || { echo "  Cannot mount read-write."; echo "  The drive may be BitLocker-encrypted, or NTFS is damaged. Run chkdsk in Windows, then retry."; pause; exit 1; }
# ntfs-3g can silently fall back to read-only: check before chntpw tries to write
if ! touch "$MNT/.hwrw$$" 2>/dev/null; then
  umount "$MNT" 2>/dev/null
  echo "  The drive opened READ-ONLY (NTFS in an unsafe state). Run chkdsk in Windows, then retry."; pause; exit 1
fi
rm -f "$MNT/.hwrw$$"
cfg="$MNT/Windows/System32/config"
# chntpw -l lists accounts as:  | 03e9 | user name | ADMIN | dis/lock |
mapfile -t ACC < <(chntpw -l "$cfg/SAM" 2>/dev/null | awk -F'|' '$2 ~ /^ *[0-9a-fA-F]+ *$/ {
  for (i=2;i<=5;i++) gsub(/^ +| +$/,"",$i); print $2 "|" $3 "|" $4 "|" $5 }' | head -9)
[ ${#ACC[@]} -eq 0 ] && { echo "  Could not read the account list."; umount "$MNT" 2>/dev/null; pause; exit 1; }
echo
echo "  Local accounts on this Windows:"
i=1
for a in "${ACC[@]}"; do
  IFS='|' read -r rid name adm lock <<< "$a"
  printf '    %s %d %s  %-24s %-6s %s\n' "$KEYC" $i "$KEYN" "$name" "$adm" "$lock"; i=$((i+1))
done
echo "  (\"dis\" = account disabled - clearing its password will not enable it)"
echo "  Local accounts only. If an account is a Microsoft (online) login, clearing does nothing -"
echo "  the real password lives on Microsoft's servers, not in this SAM."
keybar 1-${#ACC[@]} "Clear this password" Q Cancel
while :; do
  getkey
  case $KEY in
    q) umount "$MNT" 2>/dev/null; exit 0 ;;
    [1-9]) [ "$KEY" -le ${#ACC[@]} ] && break ;;
  esac
done
IFS='|' read -r rid u adm lock <<< "${ACC[$((KEY-1))]}"
echo "  Clear the password of '$u'?"
keybar Y "Yes, clear it" Q Cancel
getkey; [ "$KEY" = y ] || { umount "$MNT" 2>/dev/null; exit 0; }
printf '1\nq\ny\n' | chntpw -u "0x$rid" "$cfg/SAM" >/tmp/pwreset.log 2>&1
sync; umount "$MNT" 2>/dev/null
if grep -qiE 'written back|hives.*chang' /tmp/pwreset.log; then
  echo "  Done. '$u' now has an empty password: boot Windows and leave the password field blank."
  report_add "Windows password: cleared for '$u' on $windev"
else
  echo "  Could not change it. Last lines:"; tail -4 /tmp/pwreset.log
fi
pause
