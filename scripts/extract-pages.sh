#!/usr/bin/env bash
# Render each manual PDF to per-page PNGs (150 dpi) and extract per-page text
# (raw + layout-preserving). Output is gitignored; rerun anytime.
set -euo pipefail
cd "$(dirname "$0")/.."

slug_for() {
  case "$1" in
    SXC-1_guide_book_JA) echo guide-book ;;
    SXC-1_MIDI_JA)       echo midi ;;
    SXC-1_OSS_JA)        echo oss ;;
    SXC-1_SUG_WB_JA)     echo startup-guide ;;
    *)                   echo "$1" ;;
  esac
}

for pdf in manuals/*.pdf; do
  base=$(basename "$pdf" .pdf)
  slug=$(slug_for "$base")
  pages=$(pdfinfo "$pdf" | awk '/^Pages:/{print $2}')
  mkdir -p "manuals/pages/$slug" "manuals/text/$slug"

  pdftoppm -png -r 150 "$pdf" "manuals/pages/$slug/page"

  # Normalize pdftoppm's variable zero-padding to page-NN.png
  for f in "manuals/pages/$slug"/page-*.png; do
    n=${f##*page-}; n=${n%.png}
    printf -v target 'manuals/pages/%s/page-%02d.png' "$slug" "$((10#$n))"
    [ "$f" = "$target" ] || mv "$f" "$target"
  done

  for i in $(seq 1 "$pages"); do
    printf -v nn '%02d' "$i"
    pdftotext -f "$i" -l "$i" "$pdf" "manuals/text/$slug/page-$nn.txt"
    pdftotext -layout -f "$i" -l "$i" "$pdf" "manuals/text/$slug/page-$nn.layout.txt"
  done
  echo "$slug: $pages pages extracted"
done
