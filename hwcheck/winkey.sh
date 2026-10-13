#!/bin/bash
# winkey.sh — which Windows edition a product key is for, and which Windows is installed.
#   winkey.sh decode KEY   -> "group|serial|ok or bad|EditionID or ?|Name"  (ok/bad = key checksum)
#   winkey.sh nice EDITIONID -> the usual name (Professional -> Pro)
#   winkey.sh installed    -> one line per Windows found on the internal disks:
#                             "partition|Name|EditionID|DisplayVersion|build|key in its registry"
# How: since Windows 8 a key is a 115-bit number written in 24 letters (+ one "N" that marks
# where the first digit was). Its lowest 20 bits = the key GROUP, which fixes the edition; bits
# 103-112 = a CRC checksum, so a mistyped/garbled key is detected. GROUP -> edition comes from
# Microsoft's key configuration (pkeyconfig, OEM:DM = keys in the BIOS MSDM table, Windows 8-11);
# only these facts (group number, edition id) are kept here. Unknown group -> "?", the number is
# still printed so the report shows what to look up.
export LC_ALL=C

# ---- group -> EditionID (OEM:DM keys) ----
KEYGROUPS="
  1034 HomePremium 1038 Professional 1042 ServerDatacenter 1046 ServerEnterprise 1050 ServerWinFoundation 1054 ServerStandard
  1058 ServerWeb 1062 Ultimate 1066 Prerelease 1067 PrereleaseARM 1068 ServerStorageWorkgroup 1069 ServerStorageStandard
  1070 ServerHPC 1071 ServerMultiPointStandard 1072 ServerMultiPointPremium 1073 ServerSolution 1074 ServerSolutionsPremium 1076 CoreARM
  1077 Core 1078 CoreCountrySpecific 1079 CoreN 1080 CoreSingleLanguage 1081 Professional 1082 ProfessionalN
  1790 CoreN 1792 CoreCountrySpecific 1794 CoreSingleLanguage 1796 Core 1798 ProfessionalN 1801 Professional
  1865 CoreARM 1913 CoreSingleLanguage 1914 Core 1915 Professional 2217 CoreARM 2228 EmbeddedA
  2274 Embedded 2275 Embedded 2289 EmbeddedIndustry 2290 EmbeddedIndustry 2291 EmbeddedIndustry 2502 EmbeddedIndustry
  2512 EmbeddedIndustryA 2586 Core 2587 Professional 2588 ProfessionalN 2597 Core 2608 CoreARM
  2619 CoreARM 2621 CoreCountrySpecific 2622 CoreN 2623 CoreSingleLanguage 2624 CoreSingleLanguage 2625 Professional
  2634 EmbeddedIndustry 2635 EmbeddedIndustry 2636 EmbeddedIndustry 2637 EmbeddedIndustry 2638 EmbeddedIndustry 2649 EmbeddedIndustryA
  2650 EmbeddedIndustryA 2651 EmbeddedIndustryA 2652 EmbeddedIndustryA 2667 CoreConnected 2668 CoreConnected 2672 CoreConnectedN
  2676 ProfessionalStudent 2677 ProfessionalStudent 2681 ProfessionalStudentN 2685 CoreConnectedSingleLanguage 2686 CoreConnectedSingleLanguage 2689 CoreConnectedCountrySpecific
  2787 CoreConnected 2792 CoreConnectedCountrySpecific 2797 CoreConnectedN 2802 CoreConnectedSingleLanguage 2807 ProfessionalStudent 2812 ProfessionalStudentN
  2994 Education 3085 Enterprise 3258 Core 3259 Core 3264 CoreCountrySpecific 3268 CoreN
  3273 CoreSingleLanguage 3274 CoreSingleLanguage 3278 Education 3283 EducationN 3288 Enterprise 3293 EnterpriseS
  3305 Professional 3306 Professional 3314 ProfessionalN 3422 Core 3423 CoreCountrySpecific 3424 CoreSingleLanguage
  3425 Professional 3473 EducationN 3485 EnterpriseS 3489 EnterpriseSN 3555 Professional 3556 Professional
  3557 Professional 3558 ProfessionalN 3559 ProfessionalN 3560 Core 3561 CoreCountrySpecific 3562 CoreSingleLanguage
  3563 Professional 3568 Core 3574 CoreCountrySpecific 3578 CoreN 3582 CoreSingleLanguage 3586 Education
  3591 EducationN 3596 Enterprise 3603 EnterpriseS 3614 EnterpriseSN 3619 Professional 3626 ProfessionalN
  3633 CoreARM 3792 ProfessionalEducation 3794 ProfessionalEducationN 3806 EnterpriseS 3854 EnterpriseG 3859 EnterpriseGN
  3863 Cloud 3866 CloudN 3909 ServerDatacenter 3910 ServerStandard 3915 ProfessionalWorkstation 3920 ProfessionalWorkstationN
  4232 CloudE 4247 EnterpriseS 4256 Andromeda 4257 HubOS 4295 ServerStandard 4296 ServerStandard
  4308 AzureStackHCIAddOn 4309 AzureStackHCIAddOn 4310 ServerDatacenter 4335 ServerSolution 4361 Holographic 4362 IoTEnterprise
  4364 IoTEnterpriseS 4367 ModernPC 4545 ServerStandard 4560 ServerStandard 4561 ServerDatacenter 4572 ServerDatacenter
  4757 CloudEdition 4761 CloudEditionN 9977 Ultimate   
"
edition_of() { set -- $KEYGROUPS; while [ $# -ge 2 ]; do [ "$1" = "$G" ] && { echo "$2"; return; }; shift 2; done; }

# EditionID -> the name people use (shop, stickers, Windows setup)
nice() {
  case $1 in
    Core) echo "Home" ;;                       CoreN) echo "Home N" ;;
    CoreSingleLanguage) echo "Home Single Language" ;;
    CoreCountrySpecific) echo "Home China" ;;  CoreARM) echo "Windows RT" ;;
    CoreConnected) echo "Home (with Bing)" ;;  CoreConnectedN) echo "Home N (with Bing)" ;;
    CoreConnectedSingleLanguage) echo "Home Single Language (with Bing)" ;;
    CoreConnectedCountrySpecific) echo "Home China (with Bing)" ;;
    Professional) echo "Pro" ;;                ProfessionalN) echo "Pro N" ;;
    ProfessionalEducation) echo "Pro Education" ;; ProfessionalEducationN) echo "Pro Education N" ;;
    ProfessionalWorkstation) echo "Pro for Workstations" ;; ProfessionalWorkstationN) echo "Pro for Workstations N" ;;
    ProfessionalStudent) echo "Pro Student" ;; ProfessionalStudentN) echo "Pro Student N" ;;
    Education) echo "Education" ;;             EducationN) echo "Education N" ;;
    Enterprise) echo "Enterprise" ;;           EnterpriseS) echo "Enterprise LTSC" ;;
    EnterpriseSN) echo "Enterprise LTSC N" ;;  IoTEnterprise) echo "IoT Enterprise" ;;
    IoTEnterpriseS) echo "IoT Enterprise LTSC" ;;
    Cloud|CloudE|CloudEdition) echo "S / SE" ;; CloudN|CloudEditionN) echo "S N / SE N" ;;
    Server*) echo "Server ${1#Server}" ;;
    *) echo "$1" ;;
  esac
}

# ---- decode: base 24 -> 8 limbs of 16 bits (L[0] = lowest) ----
A=BCDFGHJKMPQRTVWXY2346789
decode() {
  local k=${1//-/} c i j d carry npos digits=()
  k=${k^^}
  [ ${#k} = 25 ] || return 1
  npos=$(expr index "$k" N); [ "$npos" -gt 0 ] || return 1
  digits=($(( npos - 1 )))
  k=${k:0:npos-1}${k:npos}
  for (( i = 0; i < 24; i++ )); do
    c=${k:i:1}; d=${A%%"$c"*}; [ ${#d} = ${#A} ] && return 1
    digits+=(${#d})
  done
  L=(0 0 0 0 0 0 0 0)
  for d in "${digits[@]}"; do                  # L = L*24 + d
    carry=$d
    for (( j = 0; j < 8; j++ )); do
      carry=$(( L[j] * 24 + carry )); L[j]=$(( carry & 0xFFFF )); carry=$(( carry >> 16 ))
    done
  done
  G=$(( L[0] | (L[1] & 0xF) << 16 ))                                  # bits 0-19
  S=$(( (L[1] >> 4) | L[2] << 12 | (L[3] & 0x3) << 28 ))              # bits 20-49
  C=$(( (L[6] >> 7) | (L[7] & 0x1) << 9 ))                            # bits 103-112
}
# CRC32/MPEG-2 of the 16 key bytes with the checksum bits cleared; its low 10 bits = checksum
crc_ok() {
  local b=() i v crc=$(( 0xFFFFFFFF )) x k
  local M=("${L[@]}"); M[6]=$(( M[6] & 0x7F )); M[7]=$(( M[7] & 0xFFFE ))
  for (( i = 0; i < 8; i++ )); do b+=($(( M[i] & 0xFF )) $(( M[i] >> 8 ))); done
  for v in "${b[@]}"; do
    x=$(( ((crc >> 24) ^ v) & 0xFF )); x=$(( x << 24 ))
    for (( k = 0; k < 8; k++ )); do
      if (( x & 0x80000000 )); then x=$(( ((x << 1) ^ 0x04C11DB7) & 0xFFFFFFFF )); else x=$(( (x << 1) & 0xFFFFFFFF )); fi
    done
    crc=$(( ((crc << 8) & 0xFFFFFFFF) ^ x ))
  done
  [ $(( ~crc & 0x3FF )) = "$C" ]
}

case $1 in
nice) nice "$2" ;;
decode)
  decode "$2" || { echo "|||bad||"; exit 1; }
  ed=$(edition_of)
  crc_ok && ck=ok || ck=bad
  echo "$G|$S|$ck|${ed:-?}|$([ -n "$ed" ] && nice "$ed")"
  ;;

installed)
  # read-only look at every NTFS partition that has a Windows registry (not the boot stick)
  . "$(dirname "$(readlink -f "$0")")/ui.sh" 2>/dev/null
  command -v reged >/dev/null || exit 0
  MNT=$(mktemp -d /tmp/wk.XXXXXX); TMPR=$(mktemp /tmp/wk.XXXXXX.reg)
  while read -r p fs pk; do
    [ "$fs" = ntfs ] || continue
    [ -n "$BOOTDISK" ] && [ "/dev/$pk" = "$BOOTDISK" ] && continue
    findmnt -rn -S "$p" >/dev/null 2>&1 && continue                 # already mounted (rescue): skip
    dd if="$p" bs=512 count=1 2>/dev/null | grep -qa 'FVE-FS-' && { echo "$p|BitLocker-encrypted|||||"; continue; }
    { mount -t ntfs3 -o ro "$p" "$MNT" 2>/dev/null || mount -t ntfs-3g -o ro "$p" "$MNT" 2>/dev/null; } || continue
    h="$MNT/Windows/System32/config/SOFTWARE"
    if [ -f "$h" ]; then
      rm -f "$TMPR"
      reged -x "$h" 'HKEY_LOCAL_MACHINE\SOFTWARE' '\Microsoft\Windows NT\CurrentVersion' "$TMPR" >/dev/null 2>&1
      val() { tr -d '\r' < "$TMPR" | sed -n "/^\[[^]]*CurrentVersion\]\$/,/^\[/s/^\"$1\"=\"\(.*\)\"\$/\1/p" | head -1; }
      pn=$(val ProductName); ed=$(val EditionID); dv=$(val DisplayVersion); [ -z "$dv" ] && dv=$(val ReleaseId)
      bn=$(val CurrentBuildNumber); [ -z "$bn" ] && bn=$(val CurrentBuild)
      # Windows 11 still writes "Windows 10 ..." in ProductName: the build number tells them apart
      [ -n "$bn" ] && [ "$bn" -ge 22000 ] 2>/dev/null && pn=${pn/Windows 10/Windows 11}
      bk=$(tr -d '\r' < "$TMPR" | sed -n 's/^"BackupProductKeyDefault"="\([A-Z0-9-]*\)"$/\1/p' | head -1)
      [ -n "$pn$ed" ] && echo "$p|$pn|$ed|$dv|$bn|$bk"
    fi
    umount "$MNT" 2>/dev/null
  done < <(lsblk -lnpo NAME,FSTYPE,PKNAME 2>/dev/null | awk '{print $1, $2, $3}' | sed 's| /dev/| |')
  rmdir "$MNT" 2>/dev/null; rm -f "$TMPR"
  ;;
esac
