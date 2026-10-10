#!/bin/bash
# repair.sh — tools for CUSTOMER machines (key R): file rescue, password reset, shell.
# The disk check (surface scan) is under D in the main menu: it is used for intake too.
export LC_ALL=C
T=$(dirname "$(readlink -f "$0")")
. "$T/ui.sh"
while true; do
  clear; title "REPAIR / RESCUE"
  echo "    F  File rescue        copy files off a machine that does not boot (Midnight Commander)"
  echo "    P  Windows password   clear the password of a LOCAL Windows account"
  echo "    X  Shell              Linux command line, type 'exit' to come back here"
  echo
  echo "  Disk check / surface scan: D in the main menu."
  keybar F "File rescue" P "Password" X "Shell" Q Back
  getkey
  case $KEY in
    f) bash "$T/rescue.sh" ;;
    p) bash "$T/pwreset.sh" ;;
    x) clear; echo "  Shell (root). Type 'exit' to come back to the menu."; echo; bash -l 2>/dev/null || bash ;;
    q) break ;;
  esac
done
