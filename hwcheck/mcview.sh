#!/bin/bash
# mcview.sh — previews in mc (file rescue) on the text console, no graphics desktop needed.
#   mcview.sh install      add our handlers to the top of /etc/mc/mc.ext.ini (boot hook, once)
#   mcview.sh open FILE    photo: full screen with fbi (all photos of the folder; PgDn/Space next,
#                          PgUp back, q = return to mc);  PDF: pages as pictures (first 20)
#   mcview.sh view FILE    text of PDF / Word / Excel / OpenOffice / PowerPoint for mc's viewer
# mc passes the file as %f; it also sets MC_EXT_FILENAME.
IMG='jpe?g|png|gif|bmp|tiff?|webp'
OFF='docx?|xlsx?|xlsm|odt|ods|odp|pptx?|rtf'

mode=$1; f=${2:-$MC_EXT_FILENAME}
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
  # the viewer itself shows no help, so show the keys first (they are hard to remember)
  hint() {
    clear
    printf '\n\n   %s\n\n' "$1"
    printf '   \e[1mSpace\e[0m or \e[1mFn+Down\e[0m (PgDn) = next      \e[1mFn+Up\e[0m (PgUp) = back\n'
    printf '   \e[1m+\e[0m / \e[1m-\e[0m = zoom, arrows = move a zoomed picture      \e[1mq\e[0m = back to the file manager\n'
    sleep 2
  }
  if [[ $ext =~ ^($IMG)$ ]]; then
    hint "PHOTOS of this folder, starting with $(basename "$f")"
    # every picture in the same folder, starting with the chosen one
    dir=$(dirname "$f"); before=(); after=(); found=0
    while IFS= read -r -d '' x; do
      if [ "$x" = "$f" ] || [ "$(readlink -f "$x")" = "$(readlink -f "$f")" ]; then found=1; continue; fi
      [[ ${x##*.} =~ ^($IMG)$ ]] || [[ ${x,,} =~ \.($IMG)$ ]] || continue
      if [ $found = 0 ]; then before+=("$x"); else after+=("$x"); fi
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
    fbi -a "$f" "${after[@]}" "${before[@]}" 2>/dev/null \
      || { echo "Cannot show the picture (no framebuffer?)."; sleep 2; }
  elif [ "$ext" = pdf ]; then
    t=$(mktemp -d /tmp/mcv.XXXXXX)
    hint "PDF: $(basename "$f") - preparing pages (up to 20)..."
    pdftoppm -r 110 -png -l 20 "$f" "$t/p" 2>/dev/null
    if ls "$t"/p*.png >/dev/null 2>&1; then
      fbi -a "$t"/p*.png 2>/dev/null
    else
      echo "Cannot render this PDF."; sleep 2
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
