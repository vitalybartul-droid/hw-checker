# Development notes

Practical notes for working on hw-checker from any computer (and for AI-assisted sessions:
read this file first).

## Sync between computers

- The GitHub repository is the single source of truth. Every computer has its own clone
  in a `Projects` folder; nothing is synced by other means.
- Start of work: **Fetch → Pull**. End of work: **Commit → Push**.
- Commit identity must be the GitHub noreply address, never a personal e-mail
  (the repository is public):
  - name: `vitalybartul-droid`
  - email: `vitalybartul-droid@users.noreply.github.com`
- Line endings: `.gitattributes` forces LF. The scripts also strip CR at boot, but keep
  editors on LF anyway.

## Not in git (copy or download on each computer)

| What | Where | Source |
|------|-------|--------|
| Debian Live ISO (`debian-live-13.7.0-amd64-standard.iso`, standard, not gnome) | `Projects/_images/` | cdimage.debian.org → current-live / amd64 / iso-hybrid (older versions: cdimage.debian.org/cdimage/archive/) |
| `.deb` packages in `hwcheck/debs/` (installed at boot by the hook) | `hwcheck/debs/` | see list below |

Required `.deb` packages for the Repair menu and disk erase (not in the base Debian Live image):
`mc`, `mc-data`, `chntpw`, `ntfs-3g`, `libntfs-3g89t64`, `fuse3`, `libfuse3-3`, `nvme-cli`, `libnvme1t64`, and for previews in mc: `fbi`, `libgif7`, `libjpeg8`, `libjpeg-turbo8`, `catdoc`, `docx2txt`, `unzip`, `odt2txt`, `xlsx2csv` (`poppler-utils` for PDF is in the base).
(`hdparm`, `wipefs`, `blkdiscard`, `sfdisk`, `rtcwake` used by disk erase are already in the base image.)
(`memtester` is already in the base image, so it is not shipped in `debs/`.)
ntfs-3g is used read-write; read-only mounts use the kernel `ntfs3` driver, which needs no package.
Do not download these by hand — run `tools/get-debs.sh`, which fetches the exact pinned versions
from the Ubuntu pool and checks each `sha256`. The pinned list lives at the top of that script.
Any other `.deb` in `hwcheck/debs/` is moved to `hwcheck/debs/unused/`: the build and the boot hook
take every `debs/*.deb`, so two versions of one package must never sit there together.
| Built ISOs | not kept locally | GitHub Releases |

## Test on a stick (fast loop, no ISO build)

1. Write any built hwcheck ISO (or the plain Debian ISO, see `README.ru.txt`) with Rufus
   in **ISO mode** — the stick stays writable (FAT32).
2. Copy the changed `hwcheck/*.sh` to `hwcheck/` on the stick, boot a laptop, check.
3. Keyboard stuck after a test: `Alt+SysRq+R`, or power button.

## Build a release ISO

```bash
tools/build-iso.sh ../_images/debian-live-13.7.0-amd64-standard.iso
# -> hwcheck-<git describe>-debian-13.7.0.iso
```

- Needs `xorriso`. If it is not installed and there is no root (e.g. a sandboxed VM),
  unpack Ubuntu 22.04 (jammy) packages without installing them:
  ```bash
  mkdir -p ~/x && cd ~/x
  B=http://archive.ubuntu.com/ubuntu/pool
  for u in universe/libi/libisoburn/xorriso_1.5.4-2_amd64.deb \
           universe/libi/libisoburn/libisoburn1_1.5.4-2_amd64.deb \
           main/libb/libburn/libburn4_1.5.4-1_amd64.deb \
           main/libi/libisofs/libisofs6_1.5.4-1_amd64.deb \
           universe/j/jigit/libjte2_1.22-3build1_amd64.deb; do
    curl -sSLO "$B/$u" && dpkg -x "$(basename "$u")" root; done
  export LD_LIBRARY_PATH=~/x/root/usr/lib/x86_64-linux-gnu XORRISO=~/x/root/usr/bin/xorriso
  ```
  (If a URL 404s, look up the current file name in the pool directory.)
- Build on a local disk, not on a slow network/shared folder, then copy the result.
- `-boot_image any replay` keeps Debian's signed shim/GRUB and the hybrid layout, so
  Secure Boot keeps working. Do not replace the bootloader.
- Release: tag `vX.Y`, GitHub → Releases → new release, attach the ISO and its `.sha256`
  (`sha256sum file.iso > file.iso.sha256`). Asset limit is 2 GB per file.

## How the stick works (key facts)

- Kernel line gets `memtest=1 hooks=file:///run/live/medium/live/config-hooks/9990-hwcheck`.
  `hooks=medium` does **not** work on Debian 13 (it looks in an old path).
- The hook installs `.deb`s from `hwcheck/debs/`, copies the scripts to
  `/usr/local/lib/hwcheck`, and starts `hwcheck` on tty1 after autologin.
- Console font has no Cyrillic → all on-screen text is English.
- Test scripts append one result line to `/tmp/hwcheck.txt`; the summary reads it.
- `chargetest.sh` can be tested off-hardware with `PS_ROOT` / `TC_ROOT` pointing to
  fake sysfs trees.

## Release checklist

1. All changes pushed; tested on at least one real laptop from a stick.
2. Build ISO, boot it once (Secure Boot ON).
3. Tag + GitHub release with ISO and `.sha256`.
