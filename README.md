# hw-checker

A bootable USB stick for fast intake checks of used laptops and PCs.
Plug it in, pick the USB drive in the boot menu, and about a minute later the
screen shows a full hardware report — no OS on the machine, no BIOS changes,
**works with Secure Boot enabled**.

Built on the official Debian Live "standard" image (signed bootloader is kept
untouched) plus a set of Bash scripts that start automatically.

## What the report shows

- **System:** vendor, model, SKU / product number, serial, board, BIOS, Secure Boot, TPM version
- **Windows OEM key** embedded in the firmware (MSDM table)
- **CPU:** model, generation (incl. Core Ultra), P/E cores, base/turbo clocks, cache, VT-x, temperature
- **Memory:** every slot with size/type/speed/part number, free slots, soldered RAM detection, quick boot-time RAM test
- **GPU:** all adapters, VRAM (AMD/NVIDIA), driver
- **Display:** panel maker and part number, resolution, max refresh rate (incl. 120/144/165 Hz and VRR range), size, 6/8/10-bit, touchscreen, video ports, webcam
- **Disks:** NVMe/SSD/HDD, size, power-on hours, SMART health, wear %, TB written, errors
- **Network:** exact Wi-Fi module, Wi-Fi standard (5/6/6E/7) and bands, MAC, LAN, Bluetooth, LTE/WWAN modem
- **Battery:** design vs. current capacity (Wh), health %, cycles, serial, chemistry
- **Summary** with a red/yellow list of problems (worn battery, SSD wear, SMART/RAM errors, missing TPM, loose charger socket, …)

## Built-in tests (single key, no Enter)

| Key | Test |
|-----|------|
| `K` | Keyboard: on-screen layout lights up every key, incl. Fn/media keys (exit: `Esc` 3 times) |
| `C` | Charger & battery live monitor: charge power, USB-C PD info, detects brief contact drops of a loose socket |
| `V` | Screen: full-screen colours for dead/stuck pixels and backlight bleed; defects picked with number keys |
| `D` | Disks (read-only): `Enter` quick check (SMART + read speed + surface scan at ~300 points, ~1 min), `F` full Victoria-style surface scan with latency map, %, ETA and temperature, `T` SMART self-test |
| `M` | RAM: memtester, `Enter` quick (1 GB) or `F` full |
| `L` | Scroll the report · `+`/`-` text size (auto-scaled on HiDPI) · `Enter` twice power off |
| `R` | Repair / rescue tools (below) |

The plain-text report is kept in `/tmp/hwcheck.txt`; test results are added to it and to the summary.

**Same rules on every screen:** single keys, no Enter to confirm a choice; `Q` or `Esc` = back;
`Enter` = the default action; digits `1`-`9` = pick from a list; `Y` = confirm something risky.
The boot stick itself is never offered as a disk.

## Repair / rescue tools (key `R`)

For working on **customer** machines:

| Key | Tool |
|-----|------|
| `F` | File rescue: internal disks open **read-only** (service partitions skipped), USB drives and USB SSD/HDD enclosures open read-write, USB disks with Windows stay read-only; opens Midnight Commander on the Windows partition. `W` = make an internal disk writable for repair, `U` = rescan |
| `P` | Windows password: pick a **local** account from the list, its password is cleared (chntpw) |
| `X` | Linux shell (`exit` comes back) |

BitLocker-encrypted drives are detected and listed as locked (they need the recovery key).
Microsoft (online) accounts cannot be reset.

## Quick start

1. Download the ready ISO from **Releases**, write it with [Rufus](https://rufus.ie) (ISO or DD mode) or `dd`. A 2 GB USB 3.0 stick is enough (the ISO is ~1.4 GB).
2. Boot the laptop from the stick (F9 HP, F12 Lenovo/Dell, Esc/F8 ASUS).

### Build the ISO yourself

```bash
tools/build-iso.sh debian-live-13.7.0-amd64-standard.iso
```

Takes the official [Debian Live](https://www.debian.org/CD/live/) *standard* ISO,
adds `hwcheck/` and the boot hook, patches the boot menu, drops the Debian installer
(~0.6 GB, not needed on a test stick), and replays Debian's
boot setup so the hybrid ISO and Secure Boot keep working. Needs `xorriso`.

Ventoy is not recommended: with Secure Boot on it needs its key enrolled on every machine.

## Repository layout

```
hwcheck/                 report + tests (hwcheck.sh, kbdtest.sh, chargetest.sh, screentest.sh, disks.sh, ramtest.sh, repair.sh, rescue.sh, pwreset.sh; ui.sh = shared menu helpers)
hwcheck/debs/            optional .deb packages installed at boot (e.g. memtester)
live/config-hooks/       live-config boot hook: installs the scripts and starts the report on tty1
boot/grub/grub.cfg       example patched boot menu for Debian Live 13.7.0
tools/build-iso.sh       builds the ready-to-write ISO
README.ru.txt            manual setup notes in Russian
DEVELOPMENT.md           how to sync, test, build and release (read first)
ROADMAP.md               planned features
```

## Credits

Developed with the assistance of [Claude](https://claude.ai) (Anthropic).
Requirements, design decisions, testing on real hardware and maintenance by the author.

## License

Scripts: MIT (see `LICENSE`). Release ISOs also contain Debian, whose components are
distributed under their own licenses; sources are available from [Debian](https://www.debian.org/CD/source-cd/).
