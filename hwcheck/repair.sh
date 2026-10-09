#!/bin/bash
# repair.sh — repair/rescue tools for working on CUSTOMER machines.
# Not needed for used-PC intake; grouped here to keep the main report clean.
export LC_ALL=C
T=$(dirname "$(readlink -f "$0")")
while true; do
  clear; echo
  echo "  =============== REPAIR / RESCUE TOOLS ==============="
  echo "  For customer machines. Not needed for used-PC intake."
  echo
  echo "    S   Surface scan        is the disk healthy? (read-only)"
  echo "    F   File rescue (mc)     copy files off a dead Windows"
  echo "    W   Windows password     clear a LOCAL account password"
  echo
  echo "    Q   Back to the report"
  echo
  printf "  Choose a key: "
  IFS= read -rsn1 k; echo
  case $k in
    s|S) bash "$T/surftest.sh" ;;
    f|F) bash "$T/rescue.sh" ;;
    w|W) bash "$T/pwreset.sh" ;;
    q|Q|"") break ;;
  esac
done
