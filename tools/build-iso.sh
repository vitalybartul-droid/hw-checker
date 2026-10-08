#!/bin/bash
# build-iso.sh — make a ready-to-write hwcheck ISO from the official Debian Live "standard" ISO.
#
# Usage:  tools/build-iso.sh debian-live-13.x.x-amd64-standard.iso [output.iso]
#
# What it does (the original ISO is not modified):
#   * adds hwcheck/ and live/config-hooks/ from this repository into the ISO;
#   * patches the boot menus (UEFI grub.cfg and legacy isolinux live.cfg) of the
#     default entry: 1-second menu, autostart hook, quick boot-time RAM test;
#   * keeps Debian's signed bootloader and hybrid layout ("-boot_image any replay"),
#     so the result boots with Secure Boot ON, from Rufus (ISO or DD mode) or dd.
# Needs: xorriso (set XORRISO=/path/to/xorriso if it is not in PATH).
set -euo pipefail

SRC=${1:?usage: $0 debian-live-...-standard.iso [output.iso]}
REPO=$(cd "$(dirname "$0")/.." && pwd)
VER=$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d)
DEB=$(basename "$SRC" | sed -nE 's/debian-live-([0-9.]+)-.*/\1/p')
OUT=${2:-hwcheck-${VER}-debian-${DEB:-live}.iso}
X=${XORRISO:-xorriso}
HOOK="hooks=file:///run/live/medium/live/config-hooks/9990-hwcheck"
EXTRA="memtest=1 $HOOK"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# --- current boot menus from the ISO ---
"$X" -osirrox on -indev "$SRC" \
     -extract /boot/grub/grub.cfg "$W/grub.cfg" \
     -extract /isolinux/live.cfg "$W/live.cfg" >/dev/null 2>&1
chmod u+w "$W"/*.cfg

# UEFI menu: 1 s timeout + extra kernel options on the FIRST "boot=live" entry only
grep -q 'hwcheck' "$W/grub.cfg" || {
  sed -i '0,/^source \/boot\/grub\/config.cfg/s//&\n\n# hwcheck: boot straight into the live system after 1 second\nset default=0\nset timeout=1/' "$W/grub.cfg"
  sed -i "0,\|boot=live components quiet splash|s||& $EXTRA|" "$W/grub.cfg"
}
# Legacy BIOS menu: same options on the default entry
grep -q 'hwcheck' "$W/live.cfg" || \
  sed -i "0,\|append boot=live components quiet splash|s||& $EXTRA|" "$W/live.cfg"

grep -q "$HOOK" "$W/grub.cfg" || { echo "ERROR: could not patch grub.cfg" >&2; exit 1; }
grep -q "$HOOK" "$W/live.cfg" || { echo "ERROR: could not patch isolinux/live.cfg" >&2; exit 1; }

# --- payload: scripts with LF line endings ---
mkdir -p "$W/hwcheck" "$W/hooks"
for f in "$REPO"/hwcheck/*.sh; do tr -d '\r' < "$f" > "$W/hwcheck/$(basename "$f")"; done
ls "$REPO"/hwcheck/debs/*.deb >/dev/null 2>&1 && { mkdir -p "$W/hwcheck/debs"; cp "$REPO"/hwcheck/debs/*.deb "$W/hwcheck/debs/"; }
tr -d '\r' < "$REPO/live/config-hooks/9990-hwcheck" > "$W/hooks/9990-hwcheck"
echo "hwcheck $VER built $(date -u +%Y-%m-%dT%H:%MZ) from $(basename "$SRC")" > "$W/hwcheck/VERSION"
chmod 755 "$W"/hwcheck/*.sh "$W/hooks/9990-hwcheck"

# --- write the new ISO, replaying Debian's boot setup ---
rm -f "$OUT"
"$X" -indev "$SRC" -outdev "$OUT" \
     -map "$W/hwcheck" /hwcheck \
     -map "$W/hooks/9990-hwcheck" /live/config-hooks/9990-hwcheck \
     -map "$W/grub.cfg" /boot/grub/grub.cfg \
     -map "$W/live.cfg" /isolinux/live.cfg \
     -boot_image any replay \
     -end 2>&1 | grep -E 'Writing to|Written to|ERROR|FAILURE' || true

[ -s "$OUT" ] || { echo "ERROR: no output written" >&2; exit 1; }
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
