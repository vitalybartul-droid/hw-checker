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
  - **Windows password reset** — clears a LOCAL account password (chntpw). BitLocker system
    drives are detected and skipped. Microsoft (online) accounts cannot be reset this way and
    the screen warns about it (they are listed but clearing their SAM hash does not help login).

- **v1.3** — one consistent UI: shared `ui.sh` (key chips, `Q`/`Esc` = back everywhere, digits
  to pick, no typing). Disk test and surface scan merged into `D` (quick check ~1 min / full scan /
  SMART self-test), boot stick never offered. RAM test single-key. Repair menu: `F` files,
  `P` password (pick account from a list), `X` shell (moved out of the main menu). File rescue
  opens mc on the Windows partition and skips EFI/Recovery. Screen test: defects picked with digits.
  Surface scan: colour map of the whole disk on one screen (thresholds per disk type), live speed /
  temperature / SMART / cable CRC / kernel resets, SMART through USB adapters, disk drop-out detection
  (hung on a bad sector vs power problem). Test results in their own report section; no beeping.

- **v1.4** — surface scan: SMART / kernel-log polling runs in the background, so a slow `smartctl`
  never pauses the scan; NVMe "timeout, completion polled" (lost interrupt, Linux power-saving quirk,
  disk answered) shown in yellow as harmless and kept out of the error count.
  **Disk erase** (`D` → `E`): quick (wipefs + TRIM), secure (NVMe format with crypto/user-data
  erase, ATA Secure Erase with automatic unfreeze by sleep), overwrite with zeros; `Y` + last 4
  characters of the serial; before/after check of 64 points; optional empty GPT; result in the report.
  **Refresh** (`D` → `R`): rewrite the same data in place (whole disk or only the slow blocks of the
  last full scan), verified block by block; unreadable blocks skipped; battery warning.
  **HDD seek test** (`D` → `S`), **HPA/DCO** hidden-capacity line, key colour schemes (`B`).
  **Remap** (`D` → `M`, HDD): rewrite only unreadable sectors; extended SMART self-test (`T` → `L`);
  eject USB disk (`X`); Refresh stops if the disk drops off; seek verdict warns about SMART bad sectors.

## Priority 1

- **Disk WRITE test (destructive, for disks being wiped)** — in `D`, double confirmation + typed word:
  - write + read-back with checksums over the whole disk: catches disks that read fine but slow down
    on writing, and **fake capacity** (cheap SSD / flash that reports 1 TB but holds 64 GB and
    overwrites itself, like H2testw / f3);
- **Disk cloning (Ghost-style)** — clone disk→disk and disk→image with `partclone`
  (used by Clonezilla), progress display, verify after clone.
- **Partition tools** — show and edit partition tables with `parted` / `sfdisk`
  (list, delete, create, GPT/MBR conversion) behind a simple menu.

## Priority 2

- **NVMe power-saving boot option** — extra GRUB entry with `nvme_core.default_ps_max_latency_us=0`
  for laptops where NVMe interrupts get lost (many "completion polled" lines).

- **BitLocker unlock with the recovery key** in file rescue (`dislocker`) — ~10% of customer disks.
- **F2 user menu in mc** with ready actions: copy the whole Users folder, collect all documents, collect all photos.

- **Network copy in file rescue** — bring up wired (DHCP) / Wi-Fi, add `cifs-utils`/`smbclient`,
  and a "mount network share" option so files can go straight to the shop NAS (no network stack
  is started now; hardware is still detected without it).

- **CPU stress test** — `stress-ng` for 5–10 min with live CPU temperature and clock graph,
  to catch overheating and throttling (dirty cooler, dry thermal paste).
  Also show the **CPU temperature in the status line of every long test** (RAM, disk scans), and
  flag "CPU hot at idle" / "throttling under load" in the summary.
- **Save reports to the stick** — per-machine report file + one `intake.csv` table.
- **Send report to Odoo** — JSON to an Odoo endpoint when the network is available.
- **BIOS admin password detection** — via `firmware-attributes` (HP / Dell / Lenovo drivers).

## Maybe

- File recovery — `testdisk` / `photorec`.
