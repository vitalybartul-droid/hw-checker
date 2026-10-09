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

## Next (v1.2) — found while testing v1.1

- **Keyboard test text is too small on HiDPI screens** (key labels hard to read on 3200x2000).
  `kbdtest.sh` picks the largest Terminus font at which the layout still fits (~115 columns x
  ~16 rows), like the report's auto-scaling, and restores the report font on exit.
  No manual +/- inside the test: those keys are being tested.
- **Webcam line duplicated and truncated** — the camera exposes two USB interfaces; show the
  device name once.
- **Hide "Socket: Other"** (meaningless on laptops with soldered CPUs).

## Done

- **v1.1** — ISO trimmed to ~1.4 GB; Enter-twice power off; disk-test progress kept out of the
  report; stricter LTE match; auto-start on legacy BIOS too.
- **v1.2** — bigger keyboard-test font on HiDPI; webcam shown once per device (+IR); hid
  meaningless CPU socket; **Repair/rescue menu (key R)** with:
  - **Surface scan** — read-only block-by-block read with a latency map (fast/slow/bad) and
    SMART reallocated/pending counts; full or quick (~300 points). Write mode will come later.
  - **File rescue (mc)** — auto-mounts internal partitions read-only and USB drives read-write,
    lists every partition with its type, flags BitLocker volumes, can switch one internal disk to
    read-write for repair (W), rescan after plugging a USB drive (U); opens mc on the mounts.
  - **Windows password reset** — clears a LOCAL account password (chntpw); Microsoft accounts
    and BitLocker drives detected and refused.

## Priority 1

- **Disk surface WRITE test** — optional destructive write/verify pass for disks that will be
  wiped anyway (badblocks -w or dd), double confirmation + typed word.
- **Disk cloning (Ghost-style)** — clone disk→disk and disk→image with `partclone`
  (used by Clonezilla), progress display, verify after clone.
- **Partition tools** — show and edit partition tables with `parted` / `sfdisk`
  (list, delete, create, GPT/MBR conversion) behind a simple menu.

## Priority 2

- **Network copy in file rescue** — bring up wired (DHCP) / Wi-Fi, add `cifs-utils`/`smbclient`,
  and a "mount network share" option so files can go straight to the shop NAS (no network stack
  is started now; hardware is still detected without it).

- **CPU stress test** — `stress-ng` for 5–10 min with live temperature and clock graph,
  to catch overheating and throttling (dirty cooler, dry thermal paste).
- **Secure disk wipe before resale** — NVMe format / ATA Secure Erase / `nwipe` for HDD,
  with double confirmation.
- **Save reports to the stick** — per-machine report file + one `intake.csv` table.
- **Send report to Odoo** — JSON to an Odoo endpoint when the network is available.
- **BIOS admin password detection** — via `firmware-attributes` (HP / Dell / Lenovo drivers).

## Maybe

- File recovery — `testdisk` / `photorec`.
