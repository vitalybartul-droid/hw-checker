# Roadmap

Ideas for next versions, in priority order. All tools below are free and open source
(GPL or similar), so they can be shipped inside the ISO.

## Smaller ISO

Goal: as small as possible, without losing any hardware information in the report.
The stick is only for testing hardware, not for using Linux.

Done in `tools/build-iso.sh` (v1.1): **~2.0 GB → ~1.4 GB**.
- Debian installer dropped: `/install`, `/pool`, `/pool-udeb`, `/dists`, `/firmware` and the
  installer entries in both boot menus. All firmware is still there — it lives inside
  `filesystem.squashfs`, the `/pool` copies were only for the installer.
- One kernel/initrd copy (`/live/vmlinuz`, `/live/initrd.img`), both menus point to it.
  (In the Debian ISO the two copies already share data blocks, so this is cleanup, not savings.)
- `md5sum.txt` / `sha256sum.txt` regenerated, "Verify integrity of the boot medium" works.
- Legacy BIOS menu now also starts automatically after 1 second.

Next step — **own minimal image with `live-build`** (~0.6–0.8 GB or less): Debian kernel and signed
shim/GRUB (Secure Boot keeps working), firmware for GPU/display and all network adapters,
all our tools baked in (no `.deb` install at boot, faster start), no docs, man pages,
locales or desktop bits. Now 1.28 GB of the 1.4 GB is `filesystem.squashfs`, so further
savings can only come from there.
**Keep everything needed for full hardware info**, including networking: Wi-Fi / Bluetooth /
LAN / LTE drivers and firmware, `iw`, `ethtool`, `iputils-ping` — the report must show the
Wi-Fi standard, bands and all network details. Only things not used for hardware info are cut
(NetworkManager GUI bits, desktop, docs, extra locales).

## Priority 1

- **Disk surface / write test (Victoria-style)** — block-by-block scan with a latency map
  (fast / slow / bad blocks), read-only mode by default and an optional **destructive write test**
  for SSD/HDD that will be wiped anyway. Based on `badblocks` / custom `dd` scan with timing.
  Write mode must require explicit double confirmation.
- **Disk cloning (Ghost-style)** — clone disk→disk and disk→image with `partclone`
  (used by Clonezilla), progress display, verify after clone.
- **Windows password reset** — `chntpw`: list local accounts, clear password / unlock / make admin.
  Works for local accounts only (not Microsoft accounts); impossible on BitLocker-encrypted drives
  without the recovery key — detect and say so.
- **Partition tools** — show and edit partition tables with `parted` / `sfdisk`
  (list, delete, create, GPT/MBR conversion) behind a simple menu.

## Priority 2

- **CPU stress test** — `stress-ng` for 5–10 min with live temperature and clock graph,
  to catch overheating and throttling (dirty cooler, dry thermal paste).
- **Secure disk wipe before resale** — NVMe format / ATA Secure Erase / `nwipe` for HDD,
  with double confirmation.
- **Save reports to the stick** — per-machine report file + one `intake.csv` table.
- **Send report to Odoo** — JSON to an Odoo endpoint when the network is available.
- **BIOS admin password detection** — via `firmware-attributes` (HP / Dell / Lenovo drivers).

## Maybe

- File recovery — `testdisk` / `photorec`.
