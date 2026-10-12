#!/bin/bash
# get-debs.sh — download the extra .deb packages (Repair menu, disk erase) into hwcheck/debs/.
#
# These are NOT kept in git (binary, and anyone can re-fetch them). The boot hook unpacks
# whatever is in hwcheck/debs/ into the live system. Run this once on each computer before
# building an ISO, or whenever the pinned versions below change.
#
#   tools/get-debs.sh            # download + verify into hwcheck/debs/
#   tools/get-debs.sh --check    # only verify what is already there
#
# Any other .deb found in hwcheck/debs/ (e.g. an older hand-downloaded version) is moved to
# hwcheck/debs/unused/. Both build-iso.sh and the boot hook take EVERY hwcheck/debs/*.deb, so two
# versions of one package would overwrite each other's files at boot. --check reports them.
#
# Source: the Ubuntu 24.04 (noble) pool. Ubuntu is used because its archive is reliably
# reachable; the binaries are built against an OLDER glibc than Debian 13 ships, so they run
# on the Debian Live base (forward-compatible). Every file is pinned to an exact version and
# checked against its sha256 below, so a mirror change or a truncated download cannot slip in.
# The dependency closure of these packages is already present in the Debian Live base image.
set -euo pipefail

BASE=http://archive.ubuntu.com/ubuntu
DEST=$(cd "$(dirname "$0")/.." && pwd)/hwcheck/debs

# sha256  pool-path   (one per line; filename is the basename of the path)
PKGS="
01bc069996fe2a94cabcb6465df0499227ba503f4450c65ac4d71295597a0606  pool/universe/m/mc/mc_4.8.30-1ubuntu0.1_amd64.deb
7b2caba7cc960978612d48b66c055c8aeda520cafa8b8720f20f650f5ff56204  pool/universe/m/mc/mc-data_4.8.30-1ubuntu0.1_all.deb
c19e877582f5cf4f35e017f49c5abd40e21f3b1117413114b4544b4064948953  pool/universe/c/chntpw/chntpw_140201-1_amd64.deb
3a34223b68b55596eb91768b9c879b8a740b16467f56673ea2b1c0e8093d678e  pool/main/n/ntfs-3g/ntfs-3g_2022.10.3-1.2ubuntu3.2_amd64.deb
4ae668265884cbccb44d01a389cee7909343916627d21b04a7f202719d916071  pool/main/n/ntfs-3g/libntfs-3g89t64_2022.10.3-1.2ubuntu3.2_amd64.deb
1e5580eeb72e830f0b242254b2438669a94c9912abf1e2f188b2992f188cc995  pool/main/f/fuse3/fuse3_3.14.0-5build1_amd64.deb
3042159c6d7d4dcb3df9d49cd21e49ecb57f4ba8c4153a72102f512a4fc534a2  pool/main/f/fuse3/libfuse3-3_3.14.0-5build1_amd64.deb
2e2bf58e08848870834e31f7c38927bf8a862d875773faa8b4baa1768c09720b  pool/main/n/nvme-cli/nvme-cli_2.8-1ubuntu0.1_amd64.deb
6cf86a02e66abf2fbdef9f97340775bbe0b58c7b687e146636cc1ed1702e4c59  pool/main/libn/libnvme/libnvme1t64_1.8-3ubuntu1_amd64.deb
50129b90a355a0cf28ed5ed619779d8cdbbeef1b335a2ee8dddf22aed3fe3485  pool/universe/f/fbi/fbi_2.10-4ubuntu4_amd64.deb
2640ecc16a63c5f580c3bdb1271fdb04d9fb392c573bdfef1daf22165bb14c00  pool/main/g/giflib/libgif7_5.2.2-1ubuntu1_amd64.deb
4d6ed682972bddf62af158a06d68a0dda497e421423b7ca92fb450b3d9ceaac9  pool/main/libj/libjpeg8-empty/libjpeg8_8c-2ubuntu11_amd64.deb
f68b5b23bc8a1688fb787d2aed7e2cdf895a73022f6a5025e183162dac4500b2  pool/main/libj/libjpeg-turbo/libjpeg-turbo8_2.1.5-2ubuntu2_amd64.deb
e28c43bf89546ed0927b9e132d869d973c7ef07265273dc900e0f9d29afe95ce  pool/universe/c/catdoc/catdoc_0.95-5build1_amd64.deb
3c67fad4140fee70f3f033f53495622488a777eaad3da3e05044c8cec8905900  pool/universe/d/docx2txt/docx2txt_1.4-5_all.deb
9ea37bc2f1e43df0a98530d08e5bab1a8801bdaf0a4c81330861e788d9155bbc  pool/main/u/unzip/unzip_6.0-28ubuntu4_amd64.deb
692ca42066872ebd683bfad422c0c800b7f5ab582ac6225a9a5cbb65f7c16003  pool/universe/o/odt2txt/odt2txt_0.5-7build1_amd64.deb
57e837664e7d24badfcd81bfa49812d5e2f8bc5b92138d8f072a33e7f17a0816  pool/universe/x/xlsx2csv/xlsx2csv_0.7.8-1_all.deb
"

mode=${1:-get}
mkdir -p "$DEST"
fail=0; n=0

while read -r sha path; do
  [ -n "$sha" ] || continue
  n=$((n+1))
  f="$DEST/$(basename "$path")"
  if [ -f "$f" ] && echo "$sha  $f" | sha256sum -c --status -; then
    echo "ok (cached)  $(basename "$f")"; continue
  fi
  if [ "$mode" = --check ]; then echo "MISSING/BAD  $(basename "$f")"; fail=1; continue; fi
  echo "fetching     $(basename "$f")"
  curl -fsSL --retry 3 -o "$f.part" "$BASE/$path"
  if echo "$sha  $f.part" | sha256sum -c --status -; then
    mv -f "$f.part" "$f"; echo "ok           $(basename "$f")"
  else
    rm -f "$f.part"; echo "SHA256 MISMATCH  $(basename "$f")"; fail=1
  fi
done <<< "$PKGS"

# .deb files that are not in the pinned list must not end up in the ISO
pinned=$(echo "$PKGS" | awk 'NF{n=split($2,a,"/"); print a[n]}')
for f in "$DEST"/*.deb; do
  [ -e "$f" ] || continue
  b=$(basename "$f")
  echo "$pinned" | grep -qxF "$b" && continue
  if [ "$mode" = --check ]; then
    echo "EXTRA        $b  (not pinned; would be shipped too - run without --check to move it aside)"; fail=1
  else
    mkdir -p "$DEST/unused"; mv -f "$f" "$DEST/unused/"
    echo "moved aside  $b  -> hwcheck/debs/unused/ (not pinned, not shipped)"
  fi
done

echo
if [ "$fail" = 0 ]; then
  echo "All $n packages present and verified in $DEST"
else
  echo "Some packages are missing or failed verification."; exit 1
fi
