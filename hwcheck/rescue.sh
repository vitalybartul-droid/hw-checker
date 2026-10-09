#!/bin/bash
# rescue.sh — get files off a machine whose Windows does not boot.
# Internal partitions are mounted READ-ONLY (safe even after Fast Startup / hibernation);
# USB drives are mounted read-write as the place to copy files to. Then opens mc.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
have(){ command -v "$1" >/dev/null 2>&1; }
have mc || { echo "  mc (file manager) is not on this stick."; echo "  Add mc + mc-data + ntfs-3g .deb to hwcheck/debs/ and rebuild."; read -rsn1 _; exit 1; }

is_bitlocker(){ dd if="$1" bs=512 count=1 2>/dev/null | grep -qa 'FVE-FS-'; }
MNT=/mnt/rescue; mkdir -p "$MNT"
stick=$(lsblk -npo PKNAME "$(findmnt -no SOURCE /run/live/medium 2>/dev/null)" 2>/dev/null | head -1)

declare -a RO RW
echo "  Scanning partitions..."
while read -r dev fstype label pk; do
  [ -b "$dev" ] || continue
  [ "/dev/$pk" = "$stick" ] && continue
  case "$fstype" in ntfs|vfat|exfat|ext2|ext3|ext4) ;; *) continue ;; esac
  mp="$MNT/$(basename "$dev")${label:+_$label}"; mp=$(echo "$mp" | tr -c 'A-Za-z0-9_/.-' '_'); mkdir -p "$mp"
  if [ "$fstype" = ntfs ] && is_bitlocker "$dev"; then
    echo "  $dev: BitLocker-encrypted - needs the recovery key, skipped."; continue
  fi
  rmv=$(cat /sys/block/$pk/removable 2>/dev/null)
  opt=ro; grp=RO; [ "$rmv" = 1 ] && { opt=rw; grp=RW; }
  if [ "$fstype" = ntfs ]; then
    mount -t ntfs3 -o "$opt" "$dev" "$mp" 2>/dev/null || mount -t ntfs-3g -o "$opt" "$dev" "$mp" 2>/dev/null
  else mount -o "$opt" "$dev" "$mp" 2>/dev/null; fi
  if mountpoint -q "$mp"; then [ "$grp" = RW ] && RW+=("$mp") || RO+=("$mp"); fi
done < <(lsblk -pnro NAME,FSTYPE,LABEL,PKNAME 2>/dev/null | awk 'NF>=2')

echo
echo "  Internal disks (read-only):"; for m in "${RO[@]}"; do echo "    $m"; done; [ ${#RO[@]} = 0 ] && echo "    (none)"
echo "  USB targets (read-write):";   for m in "${RW[@]}"; do echo "    $m"; done; [ ${#RW[@]} = 0 ] && echo "    (none - plug a USB drive to copy files onto)"
echo
echo "  mc: left = source, right = target.  F5 copy, F3 view, Tab switch, F10 quit."
read -rsn1 -p "  Press any key to open mc..." _
mc "${RO[0]:-$MNT}" "${RW[0]:-$MNT}"
for m in "${RO[@]}" "${RW[@]}"; do umount "$m" 2>/dev/null; done
echo "  Rescue mounts unmounted. Safe to unplug."
read -rsn1 -p "  Press any key to return..." _
