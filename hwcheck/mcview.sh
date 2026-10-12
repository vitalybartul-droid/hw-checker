#!/bin/bash
# mcview.sh — previews in mc (file rescue) on the text console, no graphics desktop needed.
#   mcview.sh install      add our handlers to the top of /etc/mc/mc.ext.ini (boot hook, once)
#   mcview.sh open FILE    (keys are listed on the file rescue screen)
#                          photo: full screen with fbi (all photos of the folder; PgDn/Space next,
#                          PgUp back, q = return to mc);  PDF: pages as pictures (first 20)
#   mcview.sh view FILE    text of PDF / Word / Excel / OpenOffice / PowerPoint for mc's viewer
# mc passes the file as %f; it also sets MC_EXT_FILENAME.
IMG='jpe?g|png|gif|bmp|tiff?|webp'
OFF='docx?|xlsx?|xlsm|odt|ods|odp|pptx?|rtf'

mode=$1; f=${2:-$MC_EXT_FILENAME}
LOG=/tmp/mcview.log

# fbi draws on the framebuffer and needs a REAL Linux console on stdin. mc runs our command inside
# its own pseudo-terminal, so we hand fbi the console itself (/dev/ttyN) as stdin/stdout.
# NOT "fbi -T N": with -T fbi forks into the background and returns at once - mc and fbi then
# fight over the screen and keyboard, and temporary PDF pages are deleted while fbi still loads them.
show() {
  local vt; vt=$(fgconsole 2>/dev/null); [ -n "$vt" ] || vt=1
  echo "== $(date +%T) vt=$vt fbi $*" >> "$LOG"
  fbi -a "$@" < "/dev/tty$vt" > "/dev/tty$vt" 2>> "$LOG" && return 0
  echo; echo "Cannot show it. Last lines of $LOG:"; tail -4 "$LOG" | sed 's/^/  /'
  printf 'Press any key to return...'; IFS= read -rsn1 _ < /dev/tty
}
ext=${f##*.}; ext=${ext,,}

case $mode in
install)
  ini=/etc/mc/mc.ext.ini
  [ -f "$ini" ] || exit 0
  grep -q '^\[hwc-image\]' "$ini" && exit 0
  me=$(readlink -f "$0")
  # mc tries the sections in file order (only [Default] is last), so ours go right after the header
  {
    sed -n '1,/^Version=/p' "$ini"
    cat <<EOF

[hwc-image]
Regex=\\\\.($IMG)\$
RegexIgnoreCase=true
Open=$me open %f
View=$me open %f

[hwc-pdf]
Regex=\\\\.pdf\$
RegexIgnoreCase=true
Open=$me open %f
View=%view{ascii} $me view %f

[hwc-text]
Regex=\\\\.(txt|log|ini|inf|cfg|conf|csv|xml|json|md|nfo|htm|html|bat|cmd|ps1|reg|vbs|sh|py)\$
RegexIgnoreCase=true
Open=%view{ascii}
View=%view{ascii}

[hwc-office]
Regex=\\\\.($OFF)\$
RegexIgnoreCase=true
Open=%view{ascii} $me view %f
View=%view{ascii} $me view %f
EOF
    sed -n '/^Version=/,$p' "$ini" | tail -n +2
  } > "$ini.new" && mv -f "$ini.new" "$ini"
  ;;

open)
  if [[ $ext =~ ^($IMG)$ ]]; then
    # every picture in the same folder, starting with the chosen one
    dir=$(dirname "$f"); before=(); after=(); found=0
    while IFS= read -r -d '' x; do
      if [ "$x" = "$f" ] || [ "$(readlink -f "$x")" = "$(readlink -f "$f")" ]; then found=1; continue; fi
      [[ ${x##*.} =~ ^($IMG)$ ]] || [[ ${x,,} =~ \.($IMG)$ ]] || continue
      if [ $found = 0 ]; then before+=("$x"); else after+=("$x"); fi
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
    show "$f" "${after[@]}" "${before[@]}"
  elif [ "$ext" = pdf ]; then
    t=$(mktemp -d /tmp/mcv.XXXXXX)
    echo "Preparing pages (up to 20)..."
    pdftoppm -r 110 -png -l 20 "$f" "$t/p" 2>> "$LOG"
    if ls "$t"/p*.png >/dev/null 2>&1; then
      show "$t"/p*.png
    else
      echo "Cannot render this PDF (see $LOG)."; sleep 2
    fi
    rm -rf "$t"
  fi
  ;;

view)
  case $ext in
    pdf)       pdftotext -layout -nopgbrk "$f" - 2>/dev/null ;;
    docx)      docx2txt "$f" - 2>/dev/null ;;
    doc|rtf)   catdoc -w "$f" 2>/dev/null ;;
    xlsx|xlsm) xlsx2csv -a -d '	' "$f" 2>/dev/null ;;
    xls)       xls2csv "$f" 2>/dev/null ;;
    odt|ods|odp) odt2txt "$f" 2>/dev/null ;;
    ppt)       catppt "$f" 2>/dev/null ;;
    pptx)      unzip -p "$f" 'ppt/slides/slide*.xml' 2>/dev/null | sed 's/<\/a:p>/\n/g; s/<[^>]*>//g' | grep -v '^\s*$' ;;
  esac || true
  ;;
esac
