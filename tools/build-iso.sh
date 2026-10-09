#!/bin/bash
# build-iso.sh — make a ready-to-write hwcheck ISO from the official Debian Live "standard" ISO.
#
# Usage:  tools/build-iso.sh debian-live-13.x.x-amd64-standard.iso [output.iso]
#
# What it does (the original ISO is not modified):
#   * adds hwcheck/ and live/config-hooks/ from this repository into the ISO;
#   * patches the boot menus (UEFI grub.cfg and legacy isolinux) of the default entry:
#     1-second menu, autostart hook, quick boot-time RAM test;
#   * drops the Debian installer (/install, /pool, /pool-udeb, /dists, /firmware and the
#     installer menu entries) — the live system already has all firmware in its squashfs;
#   * keeps one copy of the kernel/initrd (/live/vmlinuz, /live/initrd.img);
#   * rewrites md5sum.txt / sha256sum.txt so "Utilities > Verify integrity" still works;
#   * keeps Debian's signed bootloader and hybrid layout ("-boot_image any replay"),
#     so the result boots with Secure Boot ON, from Rufus (ISO or DD mode) or dd.
# Needs: xorriso (set XORRISO=/path/to/xorriso if it is not in PATH), md5sum, sha256sum.
set -euo pipefail

SRC=${1:?usage: $0 debian-live-...-standard.iso [output.iso]}
REPO=$(cd "$(dirname "$0")/.." && pwd)
VER=${HWCHECK_VERSION:-$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)}
DEB=$(basename "$SRC" | sed -nE 's/debian-live-([0-9.]+)-.*/\1/p')
OUT=${2:-hwcheck-${VER}-debian-${DEB:-live}.iso}
X=${XORRISO:-xorriso}
HOOK="hooks=file:///run/live/medium/live/config-hooks/9990-hwcheck"
EXTRA="memtest=1 $HOOK"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
I=$W/iso            # files to put into the ISO, laid out by their path in the ISO
mkdir -p "$I/boot/grub" "$I/isolinux" "$I/hwcheck" "$I/live/config-hooks"

# --- what is in the source ISO ---
"$X" -indev "$SRC" -find / -maxdepth 1 2>/dev/null | tr -d "'" | sed -n 's|^/\(.\)|\1|p' > "$W/top"
"$X" -indev "$SRC" -find /live -maxdepth 1 2>/dev/null | tr -d "'" | sed -n 's|^/live/||p' > "$W/live"

# --- current boot menus from the ISO ---
"$X" -osirrox on -indev "$SRC" \
     -extract /boot/grub/grub.cfg "$I/boot/grub/grub.cfg" \
     -extract /isolinux/isolinux.cfg "$I/isolinux/isolinux.cfg" \
     -extract /isolinux/menu.cfg "$I/isolinux/menu.cfg" \
     -extract /isolinux/live.cfg "$I/isolinux/live.cfg" \
     -extract /md5sum.txt "$W/md5sum.txt" \
     -extract /sha256sum.txt "$W/sha256sum.txt" >/dev/null 2>&1 || true
chmod -R u+w "$I" "$W"/*.txt 2>/dev/null || true
G=$I/boot/grub/grub.cfg
[ -s "$G" ] && [ -s "$I/isolinux/live.cfg" ] || { echo "ERROR: boot menus not found in $SRC" >&2; exit 1; }

# UEFI menu: 1 s timeout + extra kernel options on the FIRST "boot=live" entry only
grep -q 'hwcheck' "$G" || {
  sed -i '0,/^source \/boot\/grub\/config.cfg/s//&\n\n# hwcheck: boot straight into the live system after 1 second\nset default=0\nset timeout=1/' "$G"
  sed -i "0,\|boot=live components quiet splash|s||& $EXTRA|" "$G"
}
# UEFI menu: no installer; kernel/initrd by their short names (the versioned copies are dropped)
sed -i '/^# Installer (if any)/,/^fi$/d' "$G"
sed -i -E 's|/live/vmlinuz-[^[:space:]]+|/live/vmlinuz|g; s|/live/initrd\.img-[^[:space:]]+|/live/initrd.img|g' "$G"

# Legacy BIOS menu: same options on the default entry, 1 s timeout, no installer
grep -q 'hwcheck' "$I/isolinux/live.cfg" || \
  sed -i "0,\|append boot=live components quiet splash|s||& $EXTRA|" "$I/isolinux/live.cfg"
sed -i 's/^timeout 0$/timeout 10/' "$I/isolinux/isolinux.cfg"      # isolinux counts in 1/10 s
sed -i '/^include install\.cfg$/d' "$I/isolinux/menu.cfg"

grep -q "$HOOK" "$G"                  || { echo "ERROR: could not patch grub.cfg" >&2; exit 1; }
grep -q "$HOOK" "$I/isolinux/live.cfg" || { echo "ERROR: could not patch isolinux/live.cfg" >&2; exit 1; }
grep -hv '^[[:space:]]*#' "$G" "$I/isolinux/menu.cfg" "$I/isolinux/live.cfg" | grep -q '/install/' && { echo "ERROR: installer entries left in boot menus" >&2; exit 1; }
grep -qE '/live/(vmlinuz|initrd\.img)-' "$G" "$I/isolinux/live.cfg" && { echo "ERROR: versioned kernel still referenced" >&2; exit 1; }
grep -qx vmlinuz "$W/live" && grep -qx initrd.img "$W/live" || { echo "ERROR: /live/vmlinuz or /live/initrd.img missing in $SRC" >&2; exit 1; }

# --- payload: scripts with LF line endings ---
for f in "$REPO"/hwcheck/*.sh; do tr -d '\r' < "$f" > "$I/hwcheck/$(basename "$f")"; done
ls "$REPO"/hwcheck/debs/*.deb >/dev/null 2>&1 && { mkdir -p "$I/hwcheck/debs"; cp "$REPO"/hwcheck/debs/*.deb "$I/hwcheck/debs/"; }
tr -d '\r' < "$REPO/live/config-hooks/9990-hwcheck" > "$I/live/config-hooks/9990-hwcheck"
echo "hwcheck $VER built $(date -u +%Y-%m-%dT%H:%MZ) from $(basename "$SRC")" > "$I/hwcheck/VERSION"
chmod 755 "$I"/hwcheck/*.sh "$I/live/config-hooks/9990-hwcheck"

# --- what to remove: installer, its packages, versioned kernel copies ---
RM=()
for d in install pool pool-udeb dists firmware debian; do grep -qx "$d" "$W/top" && RM+=("/$d"); done
RM+=(/boot/grub/install.cfg /boot/grub/install_start.cfg /isolinux/install.cfg)
while read -r f; do RM+=("/live/$f"); done < <(grep -E '^(vmlinuz|initrd\.img)-' "$W/live")

# --- checksum lists: drop removed files, re-hash the files we add or change ---
DROP='^\./(install|pool|pool-udeb|dists|firmware)/|^\./live/(vmlinuz|initrd\.img)-|^\./boot/grub/(install|install_start)\.cfg$|^\./isolinux/install\.cfg$'
for s in md5 sha256; do
  [ -s "$W/${s}sum.txt" ] || continue
  (cd "$I" && find . -type f | sort) > "$W/ours"
  DROP=$DROP awk 'BEGIN{drop=ENVIRON["DROP"]} NR==FNR{ours[$0]=1; next} { p=$0; sub(/^[0-9a-f]+  /,"",p); if (p ~ drop || (p in ours)) next; print }' \
      "$W/ours" "$W/${s}sum.txt" > "$W/${s}.new"
  (cd "$I" && xargs -d '\n' "${s}sum" < "$W/ours") >> "$W/${s}.new"
  mv "$W/${s}.new" "$I/${s}sum.txt"
done

# --- write the new ISO, replaying Debian's boot setup ---
MAP=()
while read -r f; do MAP+=(-map "$I/${f#./}" "/${f#./}"); done < <(cd "$I" && find . -type f | sort)
rm -f "$OUT"
"$X" -indev "$SRC" -outdev "$OUT" \
     -rm_r "${RM[@]}" -- \
     "${MAP[@]}" \
     -boot_image any replay \
     -end 2>&1 | grep -E 'Writing to|Written to|SORRY|FAILURE|ERROR' || true

[ -s "$OUT" ] || { echo "ERROR: no output written" >&2; exit 1; }
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
