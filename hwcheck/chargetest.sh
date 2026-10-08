#!/bin/bash
# chargetest.sh — live charger / battery monitor (refreshes every second).
# Plug and unplug the charger, wiggle the cable in the port: every disconnect is counted,
# so a loose DC / USB-C socket shows up immediately. Exit: q or Esc.
export LC_ALL=C
[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"

r()  { cat "$1" 2>/dev/null | head -1; }
f1() { awk -v x="$1" -v d="$2" 'BEGIN{ if (x=="" || d==0) print ""; else printf "%.1f", x/d }'; }
hm() { awk -v h="$1" 'BEGIN{ if (h<=0 || h>99) print "-"; else printf "%d:%02d", int(h), int((h-int(h))*60+0.5) }'; }

BAT=$(ls -d ${PS_ROOT:-/sys/class/power_supply}/BAT* 2>/dev/null | head -1)

# ---------- Battery passport (read once) ----------
battery_details() {
  [ -n "$BAT" ] || return
  local b=$BAT v t dv ed ef cf cd vd cells yr mo dy h w lines=()
  v=$(r "$b/manufacturer"); t=$(r "$b/model_name")
  lines+=("Maker / model : ${v:--} / ${t:--}")
  v=$(r "$b/serial_number"); [ -n "$v" ] && lines+=("Serial        : $v")
  v=$(r "$b/technology");    [ -n "$v" ] && lines+=("Chemistry     : $v")
  vd=$(r "$b/voltage_min_design")
  if [ -n "$vd" ] && [ "$vd" -gt 0 ]; then
    cells=$(awk -v v="$vd" 'BEGIN{printf "%d", v/1e6/3.75 + 0.5}')     # ~3.6-3.85 V per Li-ion cell
    lines+=("Design voltage: $(f1 "$vd" 1000000) V  (~${cells} cells in series)")
  fi
  ed=$(r "$b/energy_full_design"); ef=$(r "$b/energy_full")
  if [ -z "$ed" ]; then
    cd=$(r "$b/charge_full_design"); cf=$(r "$b/charge_full")
    [ -n "$cd" ] && lines+=("Design charge : $(f1 "$cd" 1000) mAh, now holds $(f1 "$cf" 1000) mAh")
    [ -n "$cd" ] && [ -n "$vd" ] && { ed=$(( cd * vd / 1000000 )); ef=$(( cf * vd / 1000000 )); }
  fi
  if [ -n "$ed" ] && [ "${ed:-0}" -gt 0 ]; then
    h=$(awk -v f="$ef" -v d="$ed" 'BEGIN{printf "%.0f", f*100/d}')
    lines+=("Capacity      : $(f1 "$ef" 1000000) Wh of $(f1 "$ed" 1000000) Wh design  -> health ${h}%, wear $((100-h))%")
  fi
  v=$(r "$b/cycle_count")
  if [ -n "$v" ] && [ "$v" -gt 0 ]; then
    w=""
    [ -n "$h" ] && w=$(awk -v h="$h" -v c="$v" 'BEGIN{ if (h<100) printf "  (%.2f%% wear per 100 cycles)", (100-h)*100/c }')
    lines+=("Cycles        : $v$w")
  else
    lines+=("Cycles        : not reported by this battery")
  fi
  yr=$(r "$b/manufacture_year"); mo=$(r "$b/manufacture_month"); dy=$(r "$b/manufacture_day")
  [ -n "$yr" ] && [ "$yr" -gt 0 ] && lines+=("Manufactured  : $yr-$(printf %02d "${mo:-0}")-$(printf %02d "${dy:-0}")")
  v=$(r "$b/capacity_level"); [ -n "$v" ] && [ "$v" != Unknown ] && lines+=("Level         : $v")
  v=$(r "$b/health");         [ -n "$v" ] && lines+=("Health flag   : $v")
  t=$(r "$b/charge_control_start_threshold"); v=$(r "$b/charge_control_end_threshold")
  [ -n "$v" ] && lines+=("Charge window : start ${t:--}% / stop ${v}%")
  v=$(r "$b/charge_behaviour" | grep -oE '\[[^]]+\]' | tr -d '[]'); [ -n "$v" ] && lines+=("Charge mode   : $v")
  v=$(r "$b/charge_types"     | grep -oE '\[[^]]+\]' | tr -d '[]'); [ -n "$v" ] && lines+=("Charge type   : $v")
  # Healthy-pack hints
  if [ -n "$h" ]; then
    if   [ "$h" -lt 60 ]; then lines+=("Verdict       : $(printf '\e[31mREPLACE (below 60%%)\e[0m')")
    elif [ "$h" -lt 80 ]; then lines+=("Verdict       : $(printf '\e[33mworn (60-80%%), mention to buyer\e[0m')")
    else lines+=("Verdict       : $(printf '\e[32mgood (80%%+)\e[0m')"); fi
  fi
  printf '  %s\n' "${lines[@]}"
}
DETAILS=$(battery_details)
SAVED=$(stty -g)
cleanup() { printf '\e[?25h\e[0m'; stty "$SAVED" 2>/dev/null; }
trap cleanup EXIT
trap 'exit' INT TERM
stty -echo
printf '\e[?25l'; clear

view=""; prev_ac=""; ever_ac=0; plugs=0; unplugs=0; drops=0; unplug_t=0; maxchg=0; maxadp=0; log=""
start=$(date +%s)

while true; do
  # ---------- Power sources (AC adapter, USB-C PD) ----------
  ac=0; src=""
  for p in ${PS_ROOT:-/sys/class/power_supply}/*; do
    t=$(r "$p/type")
    case $t in Mains|USB|USB_C|USB_PD|USB_PD_DRP|Wireless) ;; *) continue ;; esac
    on=$(r "$p/online"); [ "$on" = 1 ] && { ac=1; ever_ac=1; }
    v=$(r "$p/voltage_now"); imax=$(r "$p/current_max"); inow=$(r "$p/current_now")
    utype=$(r "$p/usb_type" | grep -oE '\[[^]]+\]' | tr -d '[]')
    info=""
    if [ "$on" = 1 ] && [ -n "$v" ] && [ "${v:-0}" -gt 0 ]; then
      info=" $(f1 "$v" 1000000) V"
      if [ -n "$imax" ] && [ "$imax" -gt 0 ]; then
        w=$(awk -v v="$v" -v i="$imax" 'BEGIN{printf "%.0f", v*i/1e12}')
        info="$info, max $(f1 "$imax" 1000000) A = ${w} W adapter"
        [ "$w" -gt "$maxadp" ] && maxadp=$w
      fi
      [ -n "$inow" ] && [ "$inow" -gt 0 ] && info="$info, now $(f1 "$inow" 1000000) A"
    fi
    nm=$(basename "$p" | sed -E 's/^ucsi-source-psy-/USB-C PD /')
    src="$src$(printf '  %-28s %-8s %s%s' "$nm" "${utype:-$t}" "$([ "$on" = 1 ] && echo CONNECTED || echo -)" "$info")"$'\n'
  done
  [ -z "$src" ] && src="  no power-supply devices found"$'\n'

  # USB-C ports (typec class, filled in by the UCSI firmware driver if the laptop has it)
  tc=""
  for port in ${TC_ROOT:-/sys/class/typec}/port[0-9]; do
    [ -d "$port" ] || continue
    pn=$(basename "$port"); partner="$port/../$pn-partner"
    [ -d "$port-partner" ] && partner="$port-partner"
    prole=$(r "$port/power_role" | grep -oE '\[[a-z]+\]' | tr -d '[]')
    mode=$(r "$port/power_operation_mode")
    if [ -d "$partner" ]; then
      line="device connected, laptop is $( [ "$prole" = sink ] && echo 'SINK (charging from it)' || echo "${prole:-?}" ), mode ${mode:-?}"
      # Offered PD profiles from the adapter (kernel usb_power_delivery class)
      pd=$(readlink -f "$partner/usb_power_delivery" 2>/dev/null)
      if [ -n "$pd" ] && [ -d "$pd/source-capabilities" ]; then
        best=0; list=""
        for pdo in "$pd"/source-capabilities/*fixed_supply*; do
          [ -d "$pdo" ] || continue
          mv=$(r "$pdo/voltage" | tr -dc 0-9); ma=$(r "$pdo/maximum_current" | tr -dc 0-9)
          [ -n "$mv" ] && [ -n "$ma" ] || continue
          w=$(( mv * ma / 1000000 )); [ $w -gt $best ] && best=$w
          list="$list $((mv/1000))V/$(awk -v a="$ma" 'BEGIN{printf "%.2g", a/1000}')A"
        done
        [ $best -gt 0 ] && line="$line"$'\n'"$(printf '  %-28s adapter offers:%s  -> max %d W' '' "$list" "$best")"
        [ $best -gt "$maxadp" ] && maxadp=$best
      fi
    else
      line="empty"
    fi
    tc="$tc$(printf '  %-28s %s' "USB-C $pn" "$line")"$'\n'
    [ -d "$partner" ] && [ -z "$pd" -o ! -d "$pd/source-capabilities" ] && \
      tc="$tc$(printf '  %-28s %s' '' '(adapter wattage not reported by firmware - judge by battery Power below)')"$'\n'
  done
  # Charging, but every USB-C port the firmware describes is empty -> charger sits in a port it doesn't report
  if [ -n "$tc" ] && [ "$ac" = 1 ] && ! echo "$tc" | grep -q 'device connected'; then
    tc="$tc  (charger is in a USB-C port the firmware does not describe - try the other port to see PD details)"$'\n'
  fi

  # Count plug / unplug events (a loose socket makes these jump)
  now=$(date +%H:%M:%S)
  if [ -n "$prev_ac" ] && [ "$ac" != "$prev_ac" ]; then
    if [ "$ac" = 1 ]; then
      plugs=$((plugs+1)); gap=$(( $(date +%s) - unplug_t ))
      # back within 3 s = a contact drop (loose socket/cable), longer = charger moved on purpose
      if [ "$unplug_t" -gt 0 ] && [ $gap -le 3 ]; then
        drops=$((drops+1)); log="$now plugged in again after ${gap}s  <-- BRIEF DROP"$'\n'"$log"
      else log="$now plugged in"$'\n'"$log"; fi
    else unplugs=$((unplugs+1)); unplug_t=$(date +%s); log="$now UNPLUGGED"$'\n'"$log"; fi
    log=$(echo "$log" | head -6)$'\n'
  fi
  prev_ac=$ac

  # ---------- Battery ----------
  bat=""
  if [ -n "$BAT" ]; then
    st=$(r "$BAT/status"); cap=$(r "$BAT/capacity")
    vn=$(r "$BAT/voltage_now"); vd=$(r "$BAT/voltage_min_design")
    pw=$(r "$BAT/power_now")
    if [ -z "$pw" ]; then
      cn=$(r "$BAT/current_now")
      [ -n "$cn" ] && [ -n "$vn" ] && pw=$(awk -v i="$cn" -v v="$vn" 'BEGIN{printf "%.0f", (i<0?-i:i)*v/1e6}')
    fi
    pw=${pw#-}; W=$(f1 "${pw:-0}" 1000000)
    en=$(r "$BAT/energy_now"); ef=$(r "$BAT/energy_full")
    if [ -z "$en" ]; then  # charge_* in uAh -> uWh via design voltage
      chn=$(r "$BAT/charge_now"); chf=$(r "$BAT/charge_full")
      [ -n "$chn" ] && en=$(awk -v c="$chn" -v v="${vd:-$vn}" 'BEGIN{printf "%.0f", c*v/1e6}')
      [ -n "$chf" ] && ef=$(awk -v c="$chf" -v v="${vd:-$vn}" 'BEGIN{printf "%.0f", c*v/1e6}')
    fi
    eta="-"
    if [ "${pw:-0}" -gt 100000 ] && [ -n "$en" ] && [ -n "$ef" ]; then
      case $st in
        Charging)    # with a charge limit (e.g. 80%) "full" means the limit
                     tgt=$ef; tl=$(r "$BAT/charge_control_end_threshold")
                     [ -n "$tl" ] && [ "$tl" -lt 100 ] && tgt=$(( ef * tl / 100 ))
                     eta="full in $(hm "$(awk -v a="$tgt" -v b="$en" -v p="$pw" 'BEGIN{print (a-b)/p}')")" ;;
        Discharging) eta="empty in $(hm "$(awk -v a="$en" -v p="$pw" 'BEGIN{print a/p}')")" ;;
      esac
    fi
    if [ "$st" = Charging ]; then
      wi=${W%.*}; [ "${wi:-0}" -gt "$maxchg" ] && maxchg=$wi
    fi
    # bar: power scaled to 100 W
    n=$(awk -v w="${W:-0}" 'BEGIN{n=int(w/2.5); if(n>40)n=40; print n}')
    bar=$(printf '%*s' "$n" '' | tr ' ' '#')
    color=0; case $st in Charging) color=32 ;; Discharging) color=33 ;; "Not charging") color=36 ;; esac
    temp=$(r "$BAT/temp"); [ -n "$temp" ] && temp="$(f1 "$temp" 10) C"
    thr=$(r "$BAT/charge_control_end_threshold")
    bat=$(printf '  Status        : \e[%sm%s\e[0m\n' "$color" "$st")
    bat="$bat"$'\n'"$(printf '  Charge        : %s%%   (%s of %s Wh)' "$cap" "$(f1 "$en" 1000000)" "$(f1 "$ef" 1000000)")"
    bat="$bat"$'\n'"$(printf '  Power         : %6s W  [%-40s]' "$W" "$bar")"
    bat="$bat"$'\n'"$(printf '  Battery V     : %s V   %s' "$(f1 "$vn" 1000000)" "$eta")"
    [ -n "$temp" ] && bat="$bat"$'\n'"  Battery temp  : $temp"
    [ -n "$thr" ] && [ "$thr" -lt 100 ] && bat="$bat"$'\n'"  Charge limit  : ${thr}% (set in BIOS/firmware: stops charging at ${thr}%)"
  else
    bat="  no battery found"
  fi

  # ---------- Draw ----------
  el=$(( $(date +%s) - start ))
  {
    printf '\e[H'
    printf '  CHARGER / BATTERY - live          %s   (running %ds)   R = raw fields   q / Esc = exit\e[K\n\e[K\n' "$now" "$el"
    printf '  POWER SOURCES\e[K\n'
    printf '%s' "$src" | sed 's/$/\x1b[K/'
    if [ -n "$tc" ]; then printf '%s' "$tc" | sed 's/$/\x1b[K/'
    else printf '  (no USB-C port info from firmware: a USB-C charger shows up only as "AC Mains")\e[K\n'; fi
    printf '\e[K\n  BATTERY\e[K\n'
    printf '%s\n' "$bat" | sed 's/$/\x1b[K/'
    if [ "$view" = raw ]; then
      printf '\e[K\n  ALL BATTERY FIELDS (R = back)\e[K\n'
      sed 's/^POWER_SUPPLY_/    /; s/$/\x1b[K/' "$BAT/uevent" 2>/dev/null | head -40
    else
      printf '\e[K\n  BATTERY PASSPORT   (R = all raw fields)\e[K\n'
      printf '%s\n' "$DETAILS" | sed 's/$/\x1b[K/'
    fi
    printf '\e[K\n  SESSION\e[K\n'
    printf '  Plugged in %d x, unplugged %d x, \e[%sm%d brief drop(s)\e[0m      max charge power seen: %s W%s\e[K\n' \
      "$plugs" "$unplugs" "$([ $drops -gt 0 ] && echo '1;31' || echo 0)" "$drops" "$maxchg" "$([ "$maxadp" -gt 0 ] && echo ", adapter reports ${maxadp} W")"
    printf '%s' "$log" | sed 's/^/    /; s/$/\x1b[K/'
    printf '\e[K\n  Tip: wiggle the charger plug - any "UNPLUGGED" while it stays in means a loose socket or cable.\e[K\n'
    printf '  "Not charging" at a fixed %% with charger in = charge limit or battery protection, not a fault.\e[K\n\e[J'
  }
  # 1-second refresh doubles as the key wait
  if read -rsn1 -t 1 k; then
    case $k in
      q|Q|$'\e') break ;;
      r|R) [ "$view" = raw ] && view="" || view=raw; printf '\e[2J' ;;
    esac
  fi
done

bh=$(printf '%s\n' "$DETAILS" | sed -nE 's/.*health ([0-9]+)%.*/\1/p' | head -1)
bc=$(r "$BAT/cycle_count"); { [ -z "$bc" ] || [ "$bc" = 0 ]; } && bc="n/a"
res="Charging test: battery health ${bh:-?}%, cycles ${bc:-?}, charger detected $([ "$ever_ac" = 1 ] && echo yes || echo NO), max charge power ${maxchg} W$([ "$maxadp" -gt 0 ] && echo ", USB-C adapter ${maxadp} W"), unplug events ${unplugs}, brief drops ${drops}"
clear
echo "  $res"
echo "$res" >> /tmp/hwcheck.txt
sleep 1
