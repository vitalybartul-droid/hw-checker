#!/bin/bash
# hwcheck.sh — quick hardware report for intake of used PCs/laptops
# Runs automatically from the Debian Live stick (see live/config-hooks/9990-hwcheck)
# Manual run: sudo bash hwcheck.sh
# Labels are in English on purpose: the Linux text console font has no Cyrillic.
# Works without dmidecode/lspci/smartctl/iw (falls back to /sys),
# but RAM slot details need dmidecode, disk hours need smartctl,
# Wi-Fi standard detection needs iw.

export LC_ALL=C
OUT=/tmp/hwcheck.txt
have() { command -v "$1" >/dev/null 2>&1; }
rd()   { cat "$1" 2>/dev/null | head -1 | xargs; }
gb()   { awk -v b="$1" 'BEGIN{printf "%.0f GB", b/1e9}'; }

# DMI field: dmidecode if present, otherwise /sys/class/dmi/id
dmi() {
  local v=""
  have dmidecode && v=$(dmidecode -s "$1" 2>/dev/null | grep -v '^#' | head -1 | xargs)
  if [ -z "$v" ]; then
    local f
    case $1 in
      system-manufacturer)     f=sys_vendor ;;
      system-product-name)     f=product_name ;;
      system-version)          f=product_version ;;
      system-sku-number)       f=product_sku ;;
      system-serial-number)    f=product_serial ;;
      system-uuid)             f=product_uuid ;;
      chassis-asset-tag)       f=chassis_asset_tag ;;
      baseboard-manufacturer)  f=board_vendor ;;
      baseboard-product-name)  f=board_name ;;
      baseboard-serial-number) f=board_serial ;;
      bios-vendor)             f=bios_vendor ;;
      bios-version)            f=bios_version ;;
      bios-release-date)       f=bios_date ;;
    esac
    [ -n "$f" ] && v=$(rd "/sys/class/dmi/id/$f")
  fi
  echo "$v"
}

chassis() {
  local t
  t=$(rd /sys/class/dmi/id/chassis_type)
  case $t in
    3|4|6|7) echo "Desktop" ;;  8) echo "Portable" ;;  9) echo "Laptop" ;;
    10) echo "Notebook" ;;  13) echo "All-in-One" ;;  14) echo "Sub-notebook" ;;
    30) echo "Tablet" ;;  31) echo "Convertible" ;;  32) echo "Detachable" ;;
    35) echo "Mini PC" ;;  *) echo "type $t" ;;
  esac
}

pciname() {  # $1 = /sys/bus/pci/devices/XXXX
  if have lspci; then
    # Device = chip/bridge name, SDevice = actual module (e.g. "Wi-Fi 6 AX201 160MHz")
    local info dev sdev ven
    info=$(lspci -vmm -s "$(basename "$1")")
    dev=$(echo "$info"  | sed -n 's/^Device:[[:space:]]*//p'  | head -1)
    sdev=$(echo "$info" | sed -n 's/^SDevice:[[:space:]]*//p' | head -1)
    ven=$(echo "$info"  | sed -n 's/^Vendor:[[:space:]]*//p'  | head -1)
    if [ -n "$sdev" ] && [ "$sdev" != "$dev" ] && ! echo "$sdev" | grep -qiE '^device [0-9a-f]{4}$'; then
      echo "$ven $sdev"
    else
      echo "$ven $dev"
    fi
  else
    echo "PCI $(rd "$1/vendor" | sed 's/0x//'):$(rd "$1/device" | sed 's/0x//') driver=$(basename "$(readlink "$1/driver" 2>/dev/null)")"
  fi
}
usbname() {  # $1 = /sys/bus/usb/devices/X
  local id name
  id="$(rd "$1/idVendor"):$(rd "$1/idProduct")"
  name="$(rd "$1/manufacturer") $(rd "$1/product")"
  name=$(echo "$name" | xargs)
  if [ -z "$name" ] && have lsusb; then
    name=$(lsusb -d "$id" 2>/dev/null | head -1 | sed -E 's/^.*ID [0-9a-f]{4}:[0-9a-f]{4} ?//')
  fi
  if [ -z "$name" ]; then   # common Intel Bluetooth parts without a product string
    case $id in
      8087:0026) name="Intel AX201 Bluetooth" ;;  8087:0029) name="Intel AX200 Bluetooth" ;;
      8087:0032) name="Intel AX210 Bluetooth" ;;  8087:0033) name="Intel AX211 Bluetooth" ;;
      8087:0aaa) name="Intel 9460/9560 Bluetooth" ;;  8087:0a2b) name="Intel 8260/8265 Bluetooth" ;;
      8087:0a2a) name="Intel 7265 Bluetooth" ;;  8087:07dc) name="Intel 7260 Bluetooth" ;;
      8087:0025) name="Intel 9260 Bluetooth" ;;  8087:0036) name="Intel BE200 Bluetooth" ;;
    esac
  fi
  echo "${name:-unknown} [$id]"
}
usbparent() {  # walk up from a sysfs path to the USB device dir (has idVendor)
  local d
  d=$(readlink -f "$1")
  while [ -n "$d" ] && [ "$d" != "/" ] && [ ! -f "$d/idVendor" ]; do d=$(dirname "$d"); done
  [ -f "$d/idVendor" ] && echo "$d"
}

# One-line SMART health summary: "health PASSED, used 3%, written 12.3 TB, errors 0"
smart_summary() {  # $1 = /dev/xxx
  have smartctl || return
  local out h parts=() v
  out=$(smartctl -H -A "$1" 2>/dev/null)
  [ -n "$out" ] || return
  h=$(echo "$out" | sed -nE 's/.*(self-assessment test result|Health Status): *([A-Z]+).*/\2/p' | head -1)
  [ -n "$h" ] && parts+=("health $h")
  if echo "$out" | grep -q 'Percentage Used:'; then                       # NVMe
    v=$(echo "$out" | sed -nE 's/^Percentage Used:[[:space:]]*([0-9]+%).*/\1/p'); [ -n "$v" ] && parts+=("used $v")
    v=$(echo "$out" | sed -nE 's/^Data Units Written:.*\[(.*)\].*/\1/p'); [ -n "$v" ] && parts+=("written $v")
    v=$(echo "$out" | sed -nE 's/^Available Spare:[[:space:]]*([0-9]+%).*/\1/p'); [ -n "$v" ] && parts+=("spare $v")
    v=$(echo "$out" | sed -nE 's/^Media and Data Integrity Errors:[[:space:]]*([0-9,]+).*/\1/p'); [ -n "$v" ] && parts+=("media errors $v")
  else                                                                      # SATA/ATA
    v=$(echo "$out" | awk '$2=="Reallocated_Sector_Ct"{print $10}');  [ -n "$v" ] && parts+=("realloc $v")
    v=$(echo "$out" | awk '$2=="Current_Pending_Sector"{print $10}'); [ -n "$v" ] && parts+=("pending $v")
    v=$(echo "$out" | awk '$2=="Offline_Uncorrectable"{print $10}');  [ -n "$v" ] && parts+=("uncorr $v")
    v=$(echo "$out" | awk '$2 ~ /^(Wear_Leveling_Count|Media_Wearout_Indicator|SSD_Life_Left|Percent_Lifetime_Remain)$/ {print $4+0; exit}')
    [ -n "$v" ] && parts+=("life left ~${v}%")
    v=$(echo "$out" | awk '$2=="Total_LBAs_Written"{printf "%.1f TB", $10*512/1e12}'); [ -n "$v" ] && parts+=("written $v")
  fi
  [ ${#parts[@]} -gt 0 ] && (IFS=','; echo "      SMART: ${parts[*]}" | sed 's/,/, /g')
}

# EDID of a panel -> "VEN product | model text | size | resolution@Hz | bit depth | year"
edid_info() {  # $1 = path to edid file
  local -a b
  b=($(od -An -tu1 -v "$1" 2>/dev/null))
  [ ${#b[@]} -ge 128 ] || return 1
  local v=$(( (b[8]<<8) | b[9] ))
  local mfg
  mfg=$(printf "\\$(printf %o $(( ((v>>10)&31)+64 )))\\$(printf %o $(( ((v>>5)&31)+64 )))\\$(printf %o $(( (v&31)+64 )))")
  local prod
  prod=$(printf "%04X" $(( b[10] | (b[11]<<8) )))
  local name="" text="" o i t s
  for o in 54 72 90 108; do
    if [ "${b[o]}" = 0 ] && [ "${b[o+1]}" = 0 ]; then
      t=${b[o+3]}; s=""
      for ((i=o+5; i<o+18; i++)); do
        [ "${b[i]}" = 10 ] && break
        [ "${b[i]}" -ge 32 ] && [ "${b[i]}" -lt 127 ] && s+=$(printf "\\$(printf %o "${b[i]}")")
      done
      s=$(echo "$s" | xargs)
      case $t in 252) name="$s" ;; 254) [ -n "$s" ] && text="${text:+$text }$s" ;; esac
    fi
  done
  # First detailed timing descriptor = native mode
  local res="" hz="" diag=""
  if [ $(( b[54] | b[55] )) -ne 0 ]; then
    local pclk=$(( (b[54] | (b[55]<<8)) * 10000 ))
    local ha=$(( b[56] | ((b[58]>>4)<<8) )) hb=$(( b[57] | ((b[58]&15)<<8) ))
    local va=$(( b[59] | ((b[61]>>4)<<8) )) vb=$(( b[60] | ((b[61]&15)<<8) ))
    res="${ha}x${va}"
    [ $(( (ha+hb)*(va+vb) )) -gt 0 ] && hz=$(awk -v p=$pclk -v t=$(( (ha+hb)*(va+vb) )) 'BEGIN{printf "%.0f", p/t}')
    local hmm=$(( b[66] | ((b[68]>>4)<<8) )) vmm=$(( b[67] | ((b[68]&15)<<8) ))
    [ $hmm -gt 0 ] && diag=$(awk -v h=$hmm -v v=$vmm 'BEGIN{printf "%.1f\"", sqrt(h*h+v*v)/25.4}')
  fi
  [ -z "$diag" ] && [ "${b[21]}" -gt 0 ] && diag=$(awk -v h=${b[21]} -v v=${b[22]} 'BEGIN{printf "%.1f\"", sqrt(h*h+v*v)/2.54}')
  local depth=""
  if [ $(( b[20] & 128 )) -ne 0 ] && [ "${b[19]}" -ge 4 ]; then
    case $(( (b[20]>>4)&7 )) in 1) depth="6-bit" ;; 2) depth="8-bit" ;; 3) depth="10-bit" ;; 4) depth="12-bit" ;; esac
  fi
  # All refresh rates the panel declares: every detailed timing in the base block,
  # in CTA-861 extensions and in DisplayID extensions (high-Hz modes often live there),
  # plus the range-limits descriptor (variable refresh range).
  local rates="" vrr="" n=${#b[@]} e o pc ha hb va vb t
  dtd_hz() {  # $1 = offset of an 18-byte detailed timing descriptor
    local o=$1
    pc=$(( (b[o] | (b[o+1]<<8)) * 10000 )); [ $pc -gt 0 ] || return
    ha=$(( b[o+2] | ((b[o+4]>>4)<<8) )); hb=$(( b[o+3] | ((b[o+4]&15)<<8) ))
    va=$(( b[o+5] | ((b[o+7]>>4)<<8) )); vb=$(( b[o+6] | ((b[o+7]&15)<<8) ))
    t=$(( (ha+hb)*(va+vb) )); [ $t -gt 0 ] && rates="$rates $(( (pc + t/2) / t ))"
  }
  for o in 54 72 90 108; do
    if [ $(( b[o] | b[o+1] )) -ne 0 ]; then dtd_hz $o
    elif [ "${b[o+3]}" = 253 ]; then               # 0xFD range limits
      local vmin=${b[o+5]} vmax=${b[o+6]}
      [ $(( b[o+4] & 1 )) -ne 0 ] && vmin=$(( vmin + 255 ))
      [ $(( b[o+4] & 2 )) -ne 0 ] && vmax=$(( vmax + 255 ))
      [ "$vmax" -gt "$vmin" ] && vrr="${vmin}-${vmax} Hz"
    fi
  done
  for (( e=128; e+127 < n; e+=128 )); do
    case ${b[e]} in
      2)    # CTA-861: detailed timings start at offset d
        local d=${b[e+2]}
        if [ "$d" -ge 4 ]; then
          for (( o=e+d; o+18 <= e+127; o+=18 )); do [ $(( b[o] | b[o+1] )) -ne 0 ] && dtd_hz $o; done
        fi ;;
      112)  # DisplayID: data blocks; type I (0x03, 10 kHz) and type VII (0x22, 1 kHz) timings
        local end=$(( e + 5 + b[e+2] )) blk tag len unit k
        [ $end -gt $(( e + 127 )) ] && end=$(( e + 127 ))
        for (( blk=e+5; blk+3 <= end; blk+=3+len )); do
          tag=${b[blk]}; len=${b[blk+2]}; [ "$len" -gt 0 ] || break
          case $tag in 3) unit=10000 ;; 34) unit=1000 ;; *) continue ;; esac
          for (( k=blk+3; k+20 <= blk+3+len; k+=20 )); do
            pc=$(( ((b[k] | (b[k+1]<<8) | (b[k+2]<<16)) + 1) * unit ))
            ha=$(( (b[k+4] | (b[k+5]<<8)) + 1 )); hb=$(( (b[k+6] | (b[k+7]<<8)) + 1 ))
            va=$(( (b[k+12] | (b[k+13]<<8)) + 1 )); vb=$(( (b[k+14] | (b[k+15]<<8)) + 1 ))
            t=$(( (ha+hb)*(va+vb) )); [ $t -gt 0 ] && rates="$rates $(( (pc + t/2) / t ))"
          done
        done ;;
    esac
  done
  rates=$(echo $rates | tr ' ' '\n' | sort -rnu | paste -sd ',' - | sed 's/,/, /g')
  local maxhz=${rates%%,*}
  # A variable-refresh range can go above the listed modes (e.g. modes 60, range 48-144)
  [ -n "$vrr" ] && [ "${vmax:-0}" -gt "${maxhz:-0}" ] && maxhz=$vmax

  local year=$(( b[17] + 1990 ))
  echo "Panel         : $mfg $prod${name:+  \"$name\"}${text:+  ($text)}"
  echo "Native        : ${res:-?}${hz:+ @ ${hz} Hz}${diag:+, $diag}${depth:+, $depth color}"
  if [ -n "$rates" ] && { [ "$rates" != "$hz" ] || [ -n "$vrr" ]; }; then
    echo "Refresh       : max ${maxhz} Hz  (panel modes: $rates Hz${vrr:+; variable range $vrr})"
  fi
  echo "Panel made    : $year"
}

# Device that holds this live stick (to skip it in the disk list)
bootdev=""
src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
[ -n "$src" ] && bootdev=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)

# Keep kernel messages (e.g. harmless ACPI/thermal firmware warnings) off the screen
dmesg -n 1 2>/dev/null

# ---- Console font size: auto-scale on HiDPI panels, adjustable with +/- in the menu ----
FONTDIR=/usr/share/consolefonts
FONTS=()   # available Terminus Bold sizes, smallest first (e.g. 16 20x10 22x11 24x11 28x14 32x16)
mapfile -t FONTS < <(ls "$FONTDIR"/Uni2-TerminusBold*.psf.gz 2>/dev/null | sed -E 's/.*TerminusBold([0-9x]+)\.psf\.gz/\1/' | sort -t x -k1,1n)
fh() { echo "${1%%x*}"; }                       # font height from "28x14"
setfont_idx() {                                 # $1 = index in FONTS, -1 = system default
  if [ "$1" -lt 0 ]; then
    if [ -s /tmp/.hwcheck_origfont ]; then setfont /tmp/.hwcheck_origfont 2>/dev/null; else setfont 2>/dev/null; fi
  else setfont "$FONTDIR/Uni2-TerminusBold${FONTS[$1]}.psf.gz" 2>/dev/null; fi
  echo "$1" > /tmp/.hwcheck_font
}
FIDX=-1
if [ -t 1 ] && command -v setfont >/dev/null && [ ${#FONTS[@]} -gt 0 ]; then
  [ -e /tmp/.hwcheck_origfont ] || setfont -O /tmp/.hwcheck_origfont 2>/dev/null   # remember the original font
  if [ -r /tmp/.hwcheck_font ]; then
    FIDX=$(cat /tmp/.hwcheck_font)              # keep the size chosen earlier in this session
  else
    scr_h=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size 2>/dev/null)
    want=$(( ${scr_h:-1080} / 60 ))             # aim for ~60 text rows on screen
    for i in "${!FONTS[@]}"; do [ "$(fh "${FONTS[$i]}")" -le "$want" ] && FIDX=$i; done
    [ "$want" -le 18 ] && FIDX=-1               # normal screens: leave the default font
  fi
  setfont_idx "$FIDX"
fi

[ -t 1 ] && { clear; printf '\n  Collecting hardware information...\n'; }

{
echo "================ SYSTEM ================"
echo "Vendor        : $(dmi system-manufacturer)"
echo "Model         : $(dmi system-product-name)"
echo "Version/name  : $(dmi system-version)"
echo "SKU / P/N     : $(dmi system-sku-number)"
echo "Serial        : $(dmi system-serial-number)"
echo "Chassis       : $(chassis)"
asset=$(dmi chassis-asset-tag)
if [ -n "$asset" ] && ! echo "$asset" | grep -qiE '^(not specified|no asset tag|default string|to be filled by o\.?e\.?m\.?|none|n/a|0+|asset tag.*)$'; then
  echo "Asset tag     : $asset   (previous owner's inventory no.)"
fi
echo "Board         : $(dmi baseboard-manufacturer) $(dmi baseboard-product-name), s/n $(dmi baseboard-serial-number)"
echo "UUID          : $(dmi system-uuid)"
echo "BIOS          : $(dmi bios-vendor) $(dmi bios-version) ($(dmi bios-release-date))"
if [ -d /sys/firmware/efi ]; then
  sb=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* 2>/dev/null | awk '{print $NF}')
  echo "Boot mode     : UEFI, Secure Boot $([ "$sb" = 1 ] && echo ON || echo OFF)"
else
  echo "Boot mode     : Legacy/CSM"
fi
tpm=$(rd /sys/class/tpm/tpm0/tpm_version_major)
if [ -n "$tpm" ]; then echo "TPM           : $tpm.0"
elif [ -e /sys/class/tpm/tpm0 ]; then echo "TPM           : present (1.2?)"
else echo "TPM           : not found (disabled in BIOS?)"; fi

echo; echo "================ WINDOWS KEY (BIOS) ================"
if [ -r /sys/firmware/acpi/tables/MSDM ]; then
  echo "OEM key       : $(tail -c 29 /sys/firmware/acpi/tables/MSDM)"
else
  echo "OEM key       : none (no MSDM table)"
fi

echo; echo "================ CPU ================"
cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)
echo "Model         : $cpu"
gen=$(echo "$cpu" | sed -nE 's/.*i[3579]-([0-9]{4,5})[A-Z]*.*/\1/p')
if [ -n "$gen" ]; then
  # 10210U -> 10, 1135G7 -> 11, 1005G1 -> 10, 8250U -> 8
  if [ ${#gen} = 5 ] || [ "${gen:0:1}" = 1 ]; then gen=${gen:0:2}; else gen=${gen:0:1}; fi
  echo "Generation    : Intel Core ${gen}th gen"
fi
ult=$(echo "$cpu" | sed -nE 's/.*Ultra [3579] ([12])[0-9]{2}([A-Z]*).*/\1 \2/p')
if [ -n "$ult" ]; then
  case $ult in
    1*)  echo "Generation    : Intel Core Ultra Series 1 (Meteor Lake, E-cores incl. low-power island)" ;;
    "2 V"*) echo "Generation    : Intel Core Ultra Series 2 (Lunar Lake)" ;;
    2*)  echo "Generation    : Intel Core Ultra Series 2 (Arrow Lake)" ;;
  esac
fi
cores=$(lscpu -p=CORE,SOCKET | grep -v '^#' | sort -u | wc -l)
echo "Cores/threads : $cores / $(nproc --all)"
# Hybrid Intel (12th gen+): P-cores and E-cores are listed by the kernel separately
cpulist() {  # "0-7,16" -> one cpu number per line
  tr ',' '\n' < "$1" 2>/dev/null | awk -F- 'NF==2{for(i=$1;i<=$2;i++)print i; next} NF==1&&$1!=""{print $1}'
}
khz_set() {  # unique base/max frequencies (MHz) of the given cpus: $1 = file name, rest = cpus
  local f=$1 c; shift
  for c in "$@"; do cat "/sys/devices/system/cpu/cpu$c/cpufreq/$f" 2>/dev/null; done | sort -un | awk '{printf "%s%d", (NR>1?"/":""), $1/1000}'
}
if [ -r /sys/devices/cpu_core/cpus ] && [ -r /sys/devices/cpu_atom/cpus ]; then
  pc=$(cpulist /sys/devices/cpu_core/cpus); ec=$(cpulist /sys/devices/cpu_atom/cpus)
  map=$(lscpu -p=CPU,CORE | grep -v '^#')
  pcores=$(for c in $pc; do echo "$map" | awk -F, -v c="$c" '$1==c{print $2}'; done | sort -u | wc -l)
  ecores=$(for c in $ec; do echo "$map" | awk -F, -v c="$c" '$1==c{print $2}'; done | sort -u | wc -l)
  echo "Core types    : $pcores P-cores ($(echo $pc | wc -w) threads) + $ecores E-cores ($(echo $ec | wc -w) threads)"
  pb=$(khz_set base_frequency $pc); eb=$(khz_set base_frequency $ec)
  pm=$(khz_set cpuinfo_max_freq $pc); em=$(khz_set cpuinfo_max_freq $ec)
  [ -n "$pb$eb" ] && echo "Base freq     : P ${pb:-?} MHz, E ${eb:-?} MHz"
  [ -n "$pm$em" ] && echo "Turbo max     : P ${pm:-?} MHz, E ${em:-?} MHz"
else
  allc=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | sed 's/.*cpu//')
  b=$(khz_set base_frequency $allc)
  [ -n "$b" ] && echo "Base freq     : $b MHz"
fi
minmhz=$(lscpu | sed -n 's/^CPU min MHz:[[:space:]]*//p' | head -1)
maxmhz=$(lscpu | sed -n 's/^CPU max MHz:[[:space:]]*//p' | head -1)
[ -n "$maxmhz" ] && echo "Freq min/max  : ${minmhz%.*} / ${maxmhz%.*} MHz  (min = idle power-saving floor)"
l2=$(lscpu | sed -n 's/^L2 cache:[[:space:]]*//p' | head -1 | sed 's/ (.*//')
l3=$(lscpu | sed -n 's/^L3 cache:[[:space:]]*//p' | head -1 | sed 's/ (.*//')
[ -n "$l3$l2" ] && echo "Cache         : L2 ${l2:-?}, L3 ${l3:-?}"
virt=$(lscpu | sed -n 's/^Virtualization:[[:space:]]*//p' | head -1)
echo "Virtualization: ${virt:-not reported (disabled in BIOS?)}"
if have dmidecode; then
  sock=$(dmidecode -t 4 | sed -n 's/^[[:space:]]*Upgrade:[[:space:]]*//p' | head -1)
  case $sock in ""|Other|Unknown|None) ;; *) echo "Socket        : $sock" ;; esac   # laptops: soldered, says "Other"
fi
temp=""
for h in /sys/class/hwmon/hwmon*; do
  case $(rd "$h/name") in coretemp|k10temp|zenpower)
    t=$(rd "$h/temp1_input"); [ -n "$t" ] && temp="$((t/1000)) C"; break ;;
  esac
done
[ -n "$temp" ] && echo "Temp now      : $temp"

echo; echo "================ MEMORY ================"
memkb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
echo "Seen by OS    : $(awk -v k="$memkb" 'BEGIN{printf "%.1f GB", k/1024/1024}')"
if have dmidecode; then
  slots=$(dmidecode -t 17 | grep -c '^Memory Device')
  empty=$(dmidecode -t 17 | grep -cE 'Size: (No Module Installed|Not Installed)')
  echo "Slots         : $slots, free: $empty"
  dmidecode -t 17 | awk -F': ' '
    function pr(   d) {
      n++; L[n]=loc
      if (size ~ /No Module|Not Installed/) D[n]="empty"
      else D[n]=sprintf("%s %s %s  %s %s", size, type, speed, man, pn)
      cnt[D[n]]++
    }
    function out(   i, k, done) {
      for (i=1; i<=n; i++) {
        k=D[i]
        if (cnt[k] >= 3 && k != "empty") {        # e.g. 8 x 2 GB LPDDR5 = soldered memory
          if (!(k in done)) { printf "  %-14s: %d x %s  (soldered/on-board)\n", "Modules", cnt[k], k; done[k]=1 }
        } else printf "  %-14s: %s\n", L[i], k
      }
    }
    /^Memory Device/ { if (loc != "") pr(); loc=size=type=speed=man=pn="" }
    /^\tLocator:/      { loc=$2 }
    /^\tSize:/         { size=$2 }
    /^\tType:/         { type=$2 }
    /^\tSpeed:/        { speed=$2 }
    /^\tManufacturer:/ { man=$2 }
    /^\tPart Number:/  { pn=$2 }
    END { if (loc != "") pr(); out() }'
else
  echo "Slots         : unknown (dmidecode not installed)"
fi

if dmesg 2>/dev/null | grep -q 'early_memtest'; then
  bad=$(dmesg 2>/dev/null | grep -c 'bad mem addr')
  np=$(dmesg 2>/dev/null | sed -nE 's/.*early_memtest: # of tests: ([0-9]+).*/\1/p' | head -1)
  if [ "$bad" = 0 ]; then echo "Boot RAM test : passed (${np:-?} pattern(s), quick check)"
  else echo "Boot RAM test : !!! FAILED: $bad bad region(s) found - run full RAM test (M) !!!"; fi
else
  echo "Boot RAM test : not run (no memtest= in boot options)"
fi

echo; echo "================ GPU ================"
ngpu=0
for p in /sys/bus/pci/devices/*; do
  case $(rd "$p/class") in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
  ngpu=$((ngpu+1))
  vid=$(rd "$p/vendor")
  slot=$(basename "$p")
  vram=""
  if [ -r "$p/mem_info_vram_total" ]; then                       # amdgpu
    vram="$(( $(cat "$p/mem_info_vram_total") / 1048576 )) MB"
  else                                                            # nouveau / amdgpu log
    vram=$(dmesg 2>/dev/null | grep "$slot" | grep -oE 'VRAM: ?[0-9]+ ?(MiB|M)' | head -1 | grep -oE '[0-9]+')
    [ -n "$vram" ] && vram="$vram MB"
  fi
  if [ -z "$vram" ]; then
    case $vid in 0x8086) vram="shared (system RAM)" ;; 0x10de) vram="unknown (nouveau gave none)" ;; *) vram="unknown" ;; esac
  elif [ "$vid" = 0x1002 ] && [ "${slot:5:2}" = "00" ]; then
    vram="$vram (reserved from RAM, APU)"
  fi
  echo "  $(pciname "$p")"
  echo "    VRAM: $vram, driver: $(basename "$(readlink "$p/driver" 2>/dev/null)")"
done
[ $ngpu = 0 ] && echo "  not found"

echo; echo "================ DISPLAY ================"
npanel=0
for c in /sys/class/drm/card*-eDP-* /sys/class/drm/card*-LVDS-* /sys/class/drm/card*-DSI-*; do
  [ -e "$c/edid" ] || continue
  edid_info "$c/edid" || continue
  npanel=$((npanel+1))
done
[ $npanel = 0 ] && echo "Panel         : no internal panel EDID (desktop or panel off?)"
touch=no
for e in /sys/class/input/event*; do
  udevadm info -q property -p "$e" 2>/dev/null | grep -q '^ID_INPUT_TOUCHSCREEN=1' && { touch=yes; break; }
done
echo "Touchscreen   : $touch"
ports=$(ls -d /sys/class/drm/card*-* 2>/dev/null | sed 's|.*/card[0-9]*-||' | grep -vE '^(eDP|LVDS|DSI|Writeback)' | sort -u | xargs)
echo "Video ports   : ${ports:-none}"
# One line per camera: a USB webcam exposes several video nodes (colour, IR, metadata)
# whose names are cut to 31 chars, so name it by the USB device instead.
cams=""; seen=""
for v in /sys/class/video4linux/video*; do
  [ -e "$v/name" ] || continue
  usb=$(readlink -f "$v/device/.." 2>/dev/null)
  key=${usb:-$v}
  case " $seen " in *" $key "*) continue ;; esac
  seen="$seen $key"
  n=$(rd "$usb/product"); [ -n "$n" ] || n=$(rd "$v/name" | sed 's/: .*//')
  cat "$usb"/*/interface 2>/dev/null | grep -qiE '(^|[^a-z])ir([^a-z]|$)|infrared' && n="$n + IR camera (Windows Hello)"
  cams="$cams${cams:+; }$n"
done
echo "Webcam        : ${cams:-not found}"

echo; echo "================ DISKS ================"
ndisk=0
for d in /sys/block/*; do
  n=$(basename "$d")
  case $n in loop*|ram*|zram*|sr*|fd*|dm-*|md*|mmcblk*boot*) continue;; esac
  [ "$n" = "$bootdev" ] && continue
  bytes=$(lsblk -dbno SIZE "/dev/$n" 2>/dev/null | tr -d ' ')
  [ "${bytes:-0}" -eq 0 ] && continue
  model=$(rd "$d/device/model")
  tran=$(lsblk -dno TRAN "/dev/$n" 2>/dev/null | tr -d ' ')
  if [[ $n == nvme* ]]; then t=NVMe
  elif [[ $n == mmcblk* ]]; then t=eMMC
  elif [ "$(cat "$d/queue/rotational")" = 1 ]; then t=HDD
  else t=SSD; fi
  [ "$tran" = usb ] && t="$t (USB)"
  extra=""
  if have smartctl; then
    h=$(smartctl -A "/dev/$n" 2>/dev/null | awk '/Power_On_Hours/{print $10} /Power On Hours:/{gsub(",","",$4); print $4}' | head -1)
    [ -n "$h" ] && extra="  hours: $h"
  fi
  echo "  $n : $(gb "$bytes")  $t  $model$extra"
  smart_summary "/dev/$n"
  ndisk=$((ndisk+1))
done
[ $ndisk = 0 ] && echo "  no internal disks found"

echo; echo "================ NETWORK ================"
wifi=0; lan=0; lanlines=""
for p in /sys/bus/pci/devices/*; do
  c=$(rd "$p/class")
  case $c in
    0x0280*) echo "  Wi-Fi : $(pciname "$p")"; wifi=1 ;;
    0x0200*) lanlines="$lanlines  LAN   : $(pciname "$p")"$'\n'; lan=1 ;;
  esac
done
for i in /sys/class/net/*; do   # USB Wi-Fi
  [ -d "$i/phy80211" ] || continue
  dev=$(readlink -f "$i/device")
  case $dev in */usb*) echo "  Wi-Fi : USB $(usbname "$(usbparent "$dev")")"; wifi=1 ;; esac
done
if [ $wifi = 0 ]; then
  echo "  Wi-Fi : not found"
else
  # Standard and bands from the radio itself (needs iw and loaded firmware)
  if have iw && iw phy >/dev/null 2>&1 && [ -n "$(iw phy 2>/dev/null)" ]; then
    phy=$(iw phy 2>/dev/null)
    std="Wi-Fi 4 (n)"
    echo "$phy" | grep -q 'VHT Capabilities' && std="Wi-Fi 5 (ac)"
    echo "$phy" | grep -q 'HE Iftypes'       && std="Wi-Fi 6 (ax)"
    echo "$phy" | grep -q 'Band 4:'          && std="Wi-Fi 6E (ax, 6 GHz)"
    echo "$phy" | grep -q 'EHT Iftypes'      && std="Wi-Fi 7 (be)"
    bands=$(echo "$phy" | grep -oE '^[[:space:]]*Band [0-9]+:' | grep -oE '[0-9]+' | sort -u | \
            sed 's/^1$/2.4/;s/^2$/5/;s/^4$/6/;s/^3$/60/' | paste -sd '/' -)
    echo "    Standard: $std, bands: ${bands:-?} GHz"
  fi
  for i in /sys/class/net/*; do
    [ -d "$i/phy80211" ] && echo "    MAC: $(rd "$i/address")  ($(basename "$i"), driver $(basename "$(readlink "$i/device/driver" 2>/dev/null)"))"
  done
fi
if [ $lan = 0 ]; then echo "  LAN   : not found"; else printf '%s' "$lanlines"; fi
bt=0
for h in /sys/class/bluetooth/hci*; do
  [ -e "$h" ] || continue
  u=$(usbparent "$h/device")
  if [ -n "$u" ]; then echo "  BT    : $(usbname "$u")"; else echo "  BT    : present ($(basename "$h"))"; fi
  bt=1; break
done
[ $bt = 0 ] && echo "  BT    : not found"
lte=0
for u in /sys/bus/usb/devices/*; do
  [ -f "$u/product" ] || continue
  s="$(rd "$u/manufacturer") $(rd "$u/product")"
  if echo "$s" | grep -qiE 'modem|\blte\b|wwan|mobile broadband|sierra|quectel|fibocom|telit|ericsson|gobi|em7[0-9]{3}|l8[0-9]{2}-gl'; then
    echo "  LTE   : $(usbname "$u")"; lte=1
  fi
done
for p in /sys/bus/pci/devices/*; do   # PCIe/M.2 WWAN modems
  drv=$(basename "$(readlink "$p/driver" 2>/dev/null)")
  case $drv in mhi*|iosm|t7xx) echo "  LTE   : $(pciname "$p")"; lte=1 ;; esac
done
ls /dev/wwan* /dev/cdc-wdm* >/dev/null 2>&1 && [ $lte = 0 ] && { echo "  LTE   : present (wwan/cdc-wdm device)"; lte=1; }
[ $lte = 0 ] && echo "  LTE   : not found"

echo; echo "================ BATTERY ================"
found=0
for b in /sys/class/power_supply/BAT*; do
  [ -d "$b" ] || continue
  found=1
  if [ -f "$b/energy_full" ]; then          # values in uWh
    full=$(cat "$b/energy_full"); design=$(cat "$b/energy_full_design")
    fullwh=$(awk -v x="$full" 'BEGIN{printf "%.1f", x/1e6}')
    deswh=$(awk -v x="$design" 'BEGIN{printf "%.1f", x/1e6}')
  elif [ -f "$b/charge_full" ]; then        # values in uAh -> convert via design voltage
    v=$(cat "$b/voltage_min_design")
    full=$(cat "$b/charge_full"); design=$(cat "$b/charge_full_design")
    fullwh=$(awk -v x="$full" -v v="$v" 'BEGIN{printf "%.1f", x*v/1e12}')
    deswh=$(awk -v x="$design" -v v="$v" 'BEGIN{printf "%.1f", x*v/1e12}')
  else
    echo "  $(basename "$b"): no capacity data"; continue
  fi
  health=$(awk -v f="$full" -v d="$design" 'BEGIN{ if (d>0) printf "%.0f", f*100/d; else print "?" }')
  cyc=$(rd "$b/cycle_count")
  { [ -z "$cyc" ] || [ "$cyc" = 0 ]; } && cyc="not reported"
  echo "  $(basename "$b")          : $(rd "$b/manufacturer") $(rd "$b/model_name")"
  if [ "$health" = "?" ]; then
    echo "  Capacity      : ${fullwh} Wh of ${deswh} Wh"
  else
    echo "  Capacity      : ${fullwh} Wh of ${deswh} Wh  (health ${health}%, wear $((100 - health))%)"
  fi
  echo "  Cycles        : $cyc"
  bs=$(rd "$b/serial_number"); bt=$(rd "$b/technology")
  [ -n "$bs$bt" ] && echo "  Serial / chem : ${bs:--} / ${bt:--}"
done
[ $found = 0 ] && echo "  no battery (desktop?)"
} 2>/dev/null > "$OUT"

# ================= Presentation =================
# Colourise the plain report for the screen (the file itself stays plain text)
colorize() {
  sed -E \
    -e 's/^(=+ .* =+)$/\x1b[1;36m\1\x1b[0m/' \
    -e 's/^( *[A-Za-z][^:=]{0,16}: )(.*)$/\1\x1b[1m\2\x1b[0m/' \
    -e 's/(PASSED|passed|Completed without error)/\x1b[32m\1\x1b[39m/g' \
    -e 's/(FAILED|FAILURE|ERROR|!!![^!]*!!!)/\x1b[1;31m\1\x1b[39m/g' \
    -e 's/(not found|empty|none \(no MSDM table\)|not reported|not run[^,]*)/\x1b[2m\1\x1b[22m/g' \
    "$1"
}

# Short summary + list of problems, computed from the plain report
summary() {
  local f=$OUT model ver serial cpu ram slots disks disp hz gpu bh key issues=() warns=() v
  model=$(sed -n 's/^Model *: //p' "$f" | head -1); ver=$(sed -n 's/^Version\/name *: //p' "$f" | head -1)
  case $ver in *" "*) model="$(sed -n 's/^Vendor *: //p' "$f" | head -1) $ver" ;; esac
  serial=$(sed -n 's/^Serial *: //p' "$f" | head -1)
  cpu=$(sed -n '/= CPU =/,/= MEMORY =/s/^Model *: //p' "$f" | head -1 | sed -E 's/\((R|TM)\)//g; s/ CPU//; s/ @.*//; s/[0-9]+th Gen //; s/  +/ /g')
  ram=$(sed -n 's/^Seen by OS *: //p' "$f" | head -1)
  slots=$(sed -n 's/^Slots *: \([0-9]*\), free: \([0-9]*\).*/\2 of \1 slots free/p' "$f" | head -1)
  grep -q '(soldered/on-board)' "$f" && slots="soldered, not upgradeable"
  disks=$(sed -nE '/= DISKS =/,/= NETWORK =/s/^  [a-z0-9]+ : ([0-9]+ GB) +([A-Za-z]+).*/\2 \1/p' "$f" | paste -sd '+' - | sed 's/+/ + /g')
  disp=$(sed -n 's/^Native *: \([0-9x]*\).*\(, [0-9.]*"\).*/\1\2/p' "$f" | head -1)
  hz=$(sed -n 's/^Refresh *: max \([0-9]*\) Hz.*/\1/p' "$f" | head -1)
  [ -z "$hz" ] && hz=$(sed -n 's/^Native *: [0-9x]* @ \([0-9]*\) Hz.*/\1/p' "$f" | head -1)
  gpu=$(sed -n '/= GPU =/,/= DISPLAY =/p' "$f" | grep -E '^  (NVIDIA|Advanced Micro|AMD)' | sed -E 's/.*\[([^]]+)\].*/\1/' | head -1)
  bh=$(sed -n '/= BATTERY =/,$s/.*health \([0-9]*\)%.*/\1/p' "$f" | head -1)
  grep -q '^OEM key *: [A-Z0-9]\{5\}-' "$f" && key=yes || key=no

  # ---- problems ----
  if [ -n "$bh" ]; then
    if   [ "$bh" -lt 60 ]; then issues+=("battery health ${bh}% - replace")
    elif [ "$bh" -lt 80 ]; then warns+=("battery worn: health ${bh}%"); fi
  fi
  while read -r v; do [ -n "$v" ] && [ "$v" -ge 80 ] && issues+=("SSD wear ${v}%") || { [ -n "$v" ] && [ "$v" -ge 50 ] && warns+=("SSD wear ${v}%"); }; done \
    < <(sed -n 's/.*SMART:.*used \([0-9]*\)%.*/\1/p' "$f")
  grep -q 'SMART:.*health FAILED' "$f"               && issues+=("disk SMART health FAILED")
  grep -qE 'media errors [1-9]' "$f"                 && issues+=("disk media errors")
  grep -qE '(realloc|pending|uncorr) [1-9]' "$f"     && warns+=("disk has reallocated/pending sectors")
  grep -q 'READ ERROR' "$f"                          && issues+=("disk read error")
  grep -qiE 'Self-test *:.*fail' "$f"                && issues+=("disk self-test failed")
  grep -q 'Boot RAM test : !!!' "$f"                 && issues+=("RAM errors at boot test")
  grep -q 'RAM test.*FAILED' "$f"                    && issues+=("RAM test FAILED")
  grep -q '^TPM *: not found' "$f"                   && warns+=("no TPM (check BIOS) - needed for Windows 11")
  v=$(sed -n 's/^Temp now *: \([0-9]*\) C/\1/p' "$f"); [ -n "$v" ] && [ "$v" -ge 85 ] && warns+=("CPU ${v} C at idle - check cooling")
  v=$(sed -n 's/.*brief drops \([0-9]*\).*/\1/p' "$f" | tail -1); [ -n "$v" ] && [ "$v" -gt 0 ] && issues+=("charger dropped out ${v}x for <3 s - loose socket or cable")
  grep -q 'charger detected NO' "$f"                 && warns+=("charger was not detected")
  v=$(sed -n 's/^Keyboard test:.*not pressed:\(.*\)/\1/p' "$f" | tail -1); [ -n "$v" ] && warns+=("keys not pressed:$v")
  v=$(sed -n 's/^Screen test: //p' "$f" | tail -1); [ -n "$v" ] && [ "$v" != "no defects noted" ] && issues+=("screen: $v")

  printf '\n\e[1;36m================ SUMMARY ================\e[0m\n'
  printf '  \e[1m%s\e[0m   s/n %s\n' "$model" "$serial"
  printf '  %s | %s RAM (%s) | %s\n' "$cpu" "$ram" "${slots:-slots ?}" "${disks:-no disk}"
  printf '  %s%s%s | battery %s | Windows key: %s\n' "${disp:-no panel}" "${hz:+ ${hz}Hz}" "${gpu:+ | $gpu}" "$( [ -n "$bh" ] && echo "${bh}%" || echo none )" "$key"
  if [ ${#issues[@]} -eq 0 ] && [ ${#warns[@]} -eq 0 ]; then
    printf '  \e[1;32mNo problems found.\e[0m\n'
  else
    for v in "${issues[@]}"; do printf '  \e[1;31m!! %s\e[0m\n' "$v"; done
    for v in "${warns[@]}";  do printf '  \e[33m!  %s\e[0m\n' "$v"; done
  fi
}

show() { clear; colorize "$OUT"; summary; }
menu() {
  local k=$'\e[0;30;43m' n=$'\e[0m'        # not bold: on the Linux console bold black is grey
  printf '\n %s Enter x2 %s Power off  %s K %s Keyboard  %s C %s Charger  %s V %s Screen  %s D %s Disks  %s M %s RAM  %s L %s Scroll  %s S %s Shell ' \
    "$k" "$n" "$k" "$n" "$k" "$n" "$k" "$n" "$k" "$n" "$k" "$n" "$k" "$n" "$k" "$n"
  [ ${#FONTS[@]} -gt 0 ] && printf ' %s +/- %s Text size ' "$k" "$n"
}

if [ ! -t 0 ]; then cat "$OUT"; exit 0; fi

T=/usr/local/lib/hwcheck                         # installed by the boot hook
[ -f "$T/kbdtest.sh" ] || T=$(dirname "$(readlink -f "$0")")
show
redraw=1
while true; do
  # Print the menu only after the screen was redrawn: a key that does nothing
  # (e.g. +/- at the largest/smallest size) must not stack another menu line
  [ $redraw = 1 ] && menu
  redraw=1
  IFS= read -rsn1 k                              # one key, no Enter needed
  case $k in
    "")   # second Enter required: one stray key must not wipe the report (it lives only in RAM)
          printf '\n  \e[1;33mPower off? Press Enter again to confirm, any other key to cancel.\e[0m '
          IFS= read -rsn1 k2; echo
          if [ -z "$k2" ]; then printf '\n  Powering off...\n'; poweroff; exit; fi
          show ;;
    k|K)  bash "$T/kbdtest.sh"
          # safety net: make sure the console keyboard is back in normal mode
          kbd_mode -f -u 2>/dev/null || kbd_mode -u 2>/dev/null; stty sane 2>/dev/null
          show ;;
    c|C)  bash "$T/chargetest.sh"; show ;;
    v|V)  bash "$T/screentest.sh"; show ;;
    d|D)  bash "$T/disktest.sh" | tee -a "$OUT"         # stdout = results for the report, stderr = progress (screen only)
          read -rsn1 -p "  Press any key..." _; show ;;
    m|M)  bash "$T/ramtest.sh"; show ;;
    l|L)  colorize "$OUT" | less -R; show ;;
    +|=)  if [ ${#FONTS[@]} -gt 0 ] && [ "$FIDX" -lt $(( ${#FONTS[@]} - 1 )) ]; then
            FIDX=$((FIDX+1)); setfont_idx "$FIDX"; show
          else redraw=0; fi ;;                   # already the largest size
    -|_)  if [ ${#FONTS[@]} -gt 0 ] && [ "$FIDX" -gt -1 ]; then
            FIDX=$((FIDX-1)); setfont_idx "$FIDX"; show
          else redraw=0; fi ;;                   # already the smallest size
    s|S)  printf '\n  Shell. Type "sudo hwcheck" to come back, "sudo poweroff" to turn off.\n'; exit 0 ;;
    *)    redraw=0 ;;                          # ignore other keys, keep the screen as is
  esac
done
