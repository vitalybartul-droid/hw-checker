#!/bin/bash
# rescue.sh — browse and copy files between a machine's disks and a USB drive, in mc.
# Internal disks open READ-ONLY by default (safe for data rescue).
# USB drives are mounted read-write automatically (the place to copy TO).
# Option W switches one internal disk to read-write for repair (delete/create files).
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
have(){ command -v "$1" >/dev/null 2>&1; }
have mc || { echo "  mc is not on this stick. Add mc + mc-data + ntfs-3g .deb to hwcheck/debs/ and rebuild."; read -rsn1 _; exit 1; }
is_bitlocker(){ dd if="$1" bs=512 count=1 2>/dev/null | grep -qa 'FVE-FS-'; }

MNT=/mnt/rescue; mkdir -p "$MNT"
stick=$(lsblk -npo PKNAME "$(findmnt -no SOURCE /run/live/medium 2>/dev/null)" 2>/dev/null | head -1)

mount_one(){  # $1 dev  $2 fstype  $3 ro|rw  -> prints mountpoint on success
  local dev=$1 fs=$2 mode=$3 mp; mp="$MNT/$(basename "$dev")"; mkdir -p "$mp"
  mountpoint -q "$mp" && umount "$mp" 2>/dev/null
  if [ "$fs" = ntfs ]; then
    if [ "$mode" = rw ]; then
      mount -t ntfs-3g -o rw,remove_hiberfile "$dev" "$mp" 2>/dev/null || mount -t ntfs3 -o rw "$dev" "$mp" 2>/dev/null
    else
      mount -t ntfs3 -o ro "$dev" "$mp" 2>/dev/null || mount -t ntfs-3g -o ro "$dev" "$mp" 2>/dev/null
    fi
  else
    mount -o "$mode" "$dev" "$mp" 2>/dev/null
  fi
  mountpoint -q "$mp" && echo "$mp"
}

declare -a SRC TGT
field(){ lsblk -pdnro "$2" "$1" 2>/dev/null; }   # one attribute of one device (space-safe)
scan(){
  SRC=(); TGT=()
  for m in "$MNT"/*; do mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null; done
  echo "  Partitions found:"
  printf '    %-14s %-7s %-7s %-6s %s\n' DEVICE SIZE FS OPENED LABEL
  while read -r dev type; do
    [ "$type" = part ] && [ -b "$dev" ] || continue
    local fs size label pk rmv
    fs=$(field "$dev" FSTYPE); size=$(field "$dev" SIZE); label=$(field "$dev" LABEL); pk=$(field "$dev" PKNAME)
    [ "$pk" = "$stick" ] && continue
    rmv=$(cat "/sys/block/$(basename "$pk")/removable" 2>/dev/null)
    if [ "$fs" = BitLocker ] || { [ "$fs" = ntfs ] && is_bitlocker "$dev"; }; then
      printf '    %-14s %-7s %-7s %-6s %s\n' "$dev" "$size" BitLck "NO" "${label:-}(needs recovery key)"; continue
    fi
    case "$fs" in ntfs|vfat|exfat|ext2|ext3|ext4) ;; *) continue ;; esac
    if [ "$rmv" = 1 ]; then
      mp=$(mount_one "$dev" "$fs" rw); [ -n "$mp" ] && { TGT+=("$mp"); printf '    %-14s %-7s %-7s %-6s %s\n' "$dev" "$size" "$fs" "USB-rw" "${label:-}"; }
    else
      mp=$(mount_one "$dev" "$fs" ro); [ -n "$mp" ] && { SRC+=("$mp"); printf '    %-14s %-7s %-7s %-6s %s\n' "$dev" "$size" "$fs" "ro" "${label:-}"; }
    fi
  done < <(lsblk -pnro NAME,TYPE 2>/dev/null)
}

make_writable(){
  [ ${#SRC[@]} -eq 0 ] && { echo "  No internal disk is open."; sleep 1; return; }
  echo; echo "  Open which disk for WRITING (delete/create files)?"
  local i=0; for m in "${SRC[@]}"; do echo "    $i) $(findmnt -no SOURCE "$m")  ($m)"; i=$((i+1)); done
  read -rp "  Number (empty = cancel): " n; [ -z "$n" ] && return
  local mp=${SRC[$n]}; [ -z "$mp" ] && return
  local dev fs; dev=$(findmnt -no SOURCE "$mp"); fs=$(findmnt -no FSTYPE "$mp"); [ "$fs" = fuseblk ] && fs=ntfs
  echo "  NOTE: writing to NTFS is safe only if Windows was FULLY shut down"
  echo "  (not Fast Startup / sleep). Continue? (y = yes)"
  read -rsn1 c; echo; [ "$c" = y ] || [ "$c" = Y ] || return
  local new; new=$(mount_one "$dev" "$fs" rw)
  if [ -n "$new" ] && findmnt -no OPTIONS "$new" | grep -q '\brw\b'; then
    echo "  $dev is now READ-WRITE at $new"
  else echo "  Could not open read-write (dirty NTFS? disable Fast Startup in Windows)."; fi
  sleep 2
}

clear; echo; echo "  ============ FILE RESCUE (mc) ============"
scan
while true; do
  echo
  echo "    O  open mc   (internal = read-only, USB = read-write)"
  echo "    W  open an internal disk for WRITING (repair)"
  echo "    U  rescan    (after plugging in a USB drive)"
  echo "    Q  quit"
  printf "  Choose: "; IFS= read -rsn1 k; echo
  case $k in
    o|O|"")
      left="${SRC[0]:-$MNT}"; right="${TGT[0]:-$MNT}"
      echo "  mc: left = $left, right = ${TGT[0]:+USB }$right"
      echo "  F5 copy, F3 view, Insert select, F10 quit mc."
      read -rsn1 -p "  Press any key..." _; mc "$left" "$right"; clear; scan ;;
    w|W) make_writable; clear; echo "  ============ FILE RESCUE (mc) ============"; scan ;;
    u|U) clear; echo "  ============ FILE RESCUE (mc) ============"; scan ;;
    q|Q) break ;;
  esac
done
for m in "$MNT"/*; do mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null; done
echo "  All disks unmounted. Safe to unplug."
read -rsn1 -p "  Press any key to return..." _
