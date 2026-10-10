#!/bin/bash
# rescue.sh — browse and copy files between a machine's disks and a USB drive, in mc.
# Internal disks open READ-ONLY by default (safe for data rescue).
# USB drives are mounted read-write automatically (the place to copy TO).
# W switches one internal disk to read-write for repair (delete/create files).
# Small service partitions (EFI, Recovery) are listed but not opened.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
. "$(dirname "$(readlink -f "$0")")/ui.sh"
have(){ command -v "$1" >/dev/null 2>&1; }
have mc || { echo "  mc is not on this stick. Add mc + mc-data + ntfs-3g .deb to hwcheck/debs/ and rebuild."; pause; exit 1; }
is_bitlocker(){ dd if="$1" bs=512 count=1 2>/dev/null | grep -qa 'FVE-FS-'; }

MNT=/mnt/rescue; mkdir -p "$MNT"

LOG=/tmp/rescue.log; : > "$LOG"
modprobe fuse 2>/dev/null      # ntfs-3g runs on FUSE: load it before the first mount
writable(){ touch "$1/.hwrw$$" 2>/dev/null && { rm -f "$1/.hwrw$$" 2>/dev/null; return 0; }; return 1; }
mount_one(){  # $1 dev  $2 fstype  $3 ro|rw  -> prints mountpoint on success
  local dev=$1 fs=$2 mode=$3 mp; mp="$MNT/$(basename "$dev")"; mkdir -p "$mp"
  mountpoint -q "$mp" && umount "$mp" 2>/dev/null
  if [ "$fs" = ntfs ]; then
    if [ "$mode" = rw ]; then
      # ntfs-3g opens "dirty" NTFS (Fast Startup / pulled drive) read-write; kernel ntfs3 would fall back to ro
      ntfs-3g "$dev" "$mp" 2>>"$LOG" || mount -t ntfs3 -o rw,force "$dev" "$mp" 2>>"$LOG" || mount -t ntfs3 -o ro "$dev" "$mp" 2>>"$LOG"
    else
      mount -t ntfs3 -o ro "$dev" "$mp" 2>/dev/null || ntfs-3g -o ro "$dev" "$mp" 2>/dev/null
    fi
  else
    mount -o "$mode" "$dev" "$mp" 2>/dev/null
  fi
  mountpoint -q "$mp" && echo "$mp"
}

declare -a SRC TGT
field(){ lsblk -pdnro "$2" "$1" 2>/dev/null; }   # one attribute of one device (space-safe)
row(){ printf '    %-15s %7s  %-6s %-8s %s\n' "$@"; }

scan(){
  SRC=(); TGT=()
  for m in "$MNT"/*; do mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null; done
  row DEVICE SIZE FS OPENED "DISK / NOTE"
  local dev type fs size bytes label pk rmv tran model ext mp
  while read -r dev type; do
    [ "$type" = part ] && [ -b "$dev" ] || continue
    fs=$(field "$dev" FSTYPE); size=$(field "$dev" SIZE); label=$(field "$dev" LABEL); pk=$(field "$dev" PKNAME)
    [ "$pk" = "$BOOTDISK" ] && continue
    bytes=$(lsblk -bdno SIZE "$dev" 2>/dev/null | tr -d ' ')
    rmv=$(cat "/sys/block/$(basename "$pk")/removable" 2>/dev/null)
    tran=$(lsblk -dno TRAN "$pk" 2>/dev/null | tr -d ' ')
    model=$(lsblk -dno MODEL "$pk" 2>/dev/null | xargs)
    # External = USB or removable. USB SSD/HDD enclosures report removable=0, so check TRAN too.
    ext=0; { [ "$rmv" = 1 ] || [ "$tran" = usb ]; } && ext=1
    if [ "$fs" = BitLocker ] || { [ "$fs" = ntfs ] && is_bitlocker "$dev"; }; then
      row "$dev" "$size" BitLck "LOCKED" "[$model] BitLocker - needs the recovery key"; continue
    fi
    case "$fs" in ntfs|vfat|exfat|ext2|ext3|ext4) ;; *) continue ;; esac
    if [ $ext = 0 ] && [ "${bytes:-0}" -lt 1610612736 ]; then        # < 1.5 GiB on an internal disk
      row "$dev" "$size" "$fs" "-" "[$model] service partition (EFI/Recovery), not opened"; continue
    fi
    if [ $ext = 1 ]; then
      mp=$(mount_one "$dev" "$fs" rw)
      if [ -n "$mp" ] && [ -d "$mp/Windows/System32" ]; then
        # a customer's system disk on a USB adapter: never a copy target
        mp=$(mount_one "$dev" "$fs" ro)
        [ -n "$mp" ] && { SRC+=("$mp"); row "$dev" "$size" "$fs" "read" "[$model] Windows inside - customer disk${label:+, $label}"; }
      elif [ -n "$mp" ] && writable "$mp"; then
        TGT+=("$mp"); row "$dev" "$size" "$fs" "WRITE" "[$model] USB - copy files here${label:+, $label}"
      elif [ -n "$mp" ]; then
        TGT+=("$mp"); row "$dev" "$size" "$fs" "read!" "[$model] USB but READ-ONLY - run chkdsk on it in Windows (/tmp/rescue.log)"
      fi
    else
      mp=$(mount_one "$dev" "$fs" ro)
      [ -n "$mp" ] && { SRC+=("$mp"); row "$dev" "$size" "$fs" "read" "[$model] internal${label:+, $label}$([ -d "$mp/Windows/System32" ] && echo ' - Windows')"; }
    fi
  done < <(lsblk -pnro NAME,TYPE 2>/dev/null)
}

# The source panel: the partition with Windows / Users, otherwise the biggest one.
best_src(){
  local m best="" bsz=0 s
  for m in "${SRC[@]}"; do [ -d "$m/Users" ] && { echo "$m"; return; }; done
  for m in "${SRC[@]}"; do s=$(df -k --output=size "$m" 2>/dev/null | tail -1 | tr -d ' '); [ "${s:-0}" -gt $bsz ] && { bsz=$s; best=$m; }; done
  echo "${best:-$MNT}"
}

make_writable(){
  [ ${#SRC[@]} -eq 0 ] && { echo "  No internal disk is open."; sleep 1; return; }
  echo; echo "  Open which disk for WRITING (delete / create files)?"
  local i=1 m mp dev fs new
  for m in "${SRC[@]}"; do printf '    %s %d %s  %s  (%s)\n' "$KEYC" $i "$KEYN" "$(findmnt -no SOURCE "$m")" "$m"; i=$((i+1)); [ $i -gt 9 ] && break; done
  keybar 1-$(( ${#SRC[@]} > 9 ? 9 : ${#SRC[@]} )) "Disk" Q Cancel
  getkey; case $KEY in [1-9]) ;; *) return ;; esac
  mp=${SRC[$((KEY-1))]}; [ -z "$mp" ] && return
  dev=$(findmnt -no SOURCE "$mp"); fs=$(findmnt -no FSTYPE "$mp"); [ "$fs" = fuseblk ] && fs=ntfs; [ "$fs" = ntfs3 ] && fs=ntfs
  echo "  Writing to NTFS is safe only if Windows was FULLY shut down (not Fast Startup / sleep)."
  keybar Y "Yes, open for writing" Q Cancel
  getkey; [ "$KEY" = y ] || return
  new=$(mount_one "$dev" "$fs" rw)
  if [ -n "$new" ] && writable "$new"; then echo "  $dev is now WRITABLE."; echo "    -> $dev is now open for WRITING" >>"$TBL"
  else echo "  Could not open it for writing (dirty NTFS? turn off Fast Startup in Windows)."; fi
  sleep 2
}

TBL=/tmp/rescue.tbl; need=1
while true; do
  clear; title "FILE RESCUE"
  # disks are (re)opened only at start and on U - not after mc or W, so W's change stays
  if [ $need = 1 ]; then echo "  Opening disks..."; scan >"$TBL"; need=0; clear; title "FILE RESCUE"; fi
  cat "$TBL"
  echo
  echo "  mc keys: Tab = other panel, F5 = copy, Insert = select, F3 = view, F10 = back here."
  keybar Enter "Open mc" W "Make a disk writable" U "Rescan (after plugging USB)" Q Back
  getkey
  case $KEY in
    ""|o) mc "$(best_src)" "${TGT[0]:-$MNT}" ;;
    w)    make_writable ;;
    u)    need=1 ;;
    q)    break ;;
  esac
done
for m in "$MNT"/*; do mountpoint -q "$m" 2>/dev/null && umount "$m" 2>/dev/null; done
echo "  All disks unmounted - safe to unplug."
sleep 1
