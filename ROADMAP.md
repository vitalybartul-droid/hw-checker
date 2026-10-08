# Roadmap

Ideas for next versions, in priority order. All tools below are free and open source
(GPL or similar), so they can be shipped inside the ISO.

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
