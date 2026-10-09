#!/bin/bash
# pwreset.sh — clear a LOCAL Windows account password with chntpw.
# Clears (empties) the password only. Does not touch group membership or lock state.
# Local accounts only: Microsoft (online) accounts cannot be reset this way.
# A BitLocker-encrypted system drive cannot be opened without the recovery key.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
have(){ command -v "$1" >/dev/null 2>&1; }
have chntpw || { echo "  chntpw is not on this stick."; echo "  Add chntpw + ntfs-3g .deb to hwcheck/debs/ and rebuild."; read -rsn1 _; exit 1; }
is_bitlocker(){ dd if="$1" bs=512 count=1 2>/dev/null | grep -qa 'FVE-FS-'; }

echo "  WINDOWS LOCAL PASSWORD RESET"
echo "  Empties the password of a LOCAL account so you can log in with no password."
echo "  It does NOT work for Microsoft (online) accounts."
echo
MNT=/mnt/win; mkdir -p "$MNT"; windev=""
echo "  Looking for a Windows installation..."
while read -r dev fstype; do
  [ "$fstype" = ntfs ] || continue
  is_bitlocker "$dev" && { echo "  $dev: BitLocker-encrypted, skipped."; continue; }
  { mount -t ntfs3 -o ro "$dev" "$MNT" 2>/dev/null || mount -t ntfs-3g -o ro "$dev" "$MNT" 2>/dev/null; } || continue
  [ -f "$MNT/Windows/System32/config/SAM" ] && { windev="$dev"; umount "$MNT"; break; }
  umount "$MNT" 2>/dev/null
done < <(lsblk -pnro NAME,FSTYPE 2>/dev/null)
[ -z "$windev" ] && { echo "  No Windows found (no readable SAM). The drive may be BitLocker-encrypted."; read -rsn1 _; exit 1; }

echo "  Windows system drive: $windev"
{ ntfs-3g -o remove_hiberfile,recover "$windev" "$MNT" 2>/dev/null || mount -t ntfs3 -o rw,force "$windev" "$MNT" 2>/dev/null; } || { echo "  Cannot mount read-write."; echo "  NTFS is 'dirty' - in Windows turn off Fast Startup, or shut down fully, then retry."; read -rsn1 _; exit 1; }
cfg="$MNT/Windows/System32/config"
echo
echo "  Local accounts on this Windows:"
chntpw -l "$cfg/SAM" 2>/dev/null | awk '/RID/{p=1} p'
echo
read -rp "  Type the exact user name to clear (empty = cancel): " u
[ -z "$u" ] && { umount "$MNT" 2>/dev/null; exit 0; }
printf '1\nq\ny\n' | chntpw -u "$u" "$cfg/SAM" >/tmp/pwreset.log 2>&1
sync; umount "$MNT" 2>/dev/null
if grep -qiE 'written back|hives.*chang' /tmp/pwreset.log; then
  echo "  Done. '$u' now has an empty password. Boot Windows and log in, leave the password blank."
  echo "Windows password: cleared for '$u' on $windev" >> /tmp/hwcheck.txt
else
  echo "  Could not change it. Last lines:"; tail -4 /tmp/pwreset.log
fi
echo
read -rsn1 -p "  Press any key to return..." _
