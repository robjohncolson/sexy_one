#!/usr/bin/env bash
# Render the four SXC-1 manual PDFs to per-page WebP images and commit them under
# site/static/pages/<slug>/page-NN.webp for the manual reader's "show original page (JA)"
# panel (M1-plan.md section 7).
#
# NOT part of the build: scripts/build-site.sh must never call this script. The WebP files
# it produces are committed to git; a fresh clone already has everything scripts/build-site.sh
# needs, with no PDF/image tooling required at build or CI time. Re-run this script by hand
# only when a source PDF changes.
#
# Pipeline per document:
#   1. pdftoppm -png -r 150  renders the PDF to manuals/pages/<slug>/page-NN.png (gitignored
#      scratch area, reused across runs).
#   2. Each page is encoded as WebP two ways -- lossy q88 and lossless -- and whichever
#      candidate is smaller is written to site/static/pages/<slug>/page-NN.webp. This is
#      self-tuning: lossless wins on text-only pages, lossy wins on photo-heavy pages.
#   3. The PNG intermediates are deleted afterwards unless --keep-png is given.
#
# Usage:
#   scripts/render-page-images.sh [--slug SLUG] [--force] [--keep-png]
#   scripts/render-page-images.sh --help
#
# Options:
#   --slug SLUG   only process one document (guide-book | startup-guide | midi | oss)
#   --force       re-encode every page even if its .webp already exists and is up to date
#   --keep-png    do not delete the manuals/pages/<slug>/*.png intermediates afterwards
#   --help        show this message and exit 0
#
# Idempotent: without --force, a document whose .webp files all already exist and are newer
# than its source PDF is skipped entirely (no pdftoppm invocation, no re-encoding).

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from BASH_SOURCE so this script works from any cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

MANUALS_DIR="$REPO_ROOT/manuals"
PAGES_SCRATCH_DIR="$REPO_ROOT/manuals/pages"
OUT_DIR="$REPO_ROOT/site/static/pages"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
FORCE=0
KEEP_PNG=0
ONLY_SLUG=""

usage() {
  cat <<'EOF'
Usage: scripts/render-page-images.sh [--slug SLUG] [--force] [--keep-png]
       scripts/render-page-images.sh --help

Renders manuals/*.pdf to 150 dpi WebP page images under site/static/pages/<slug>/.
Not part of scripts/build-site.sh -- run it by hand when a source PDF changes.

Options:
  --slug SLUG   only process one document (guide-book | startup-guide | midi | oss)
  --force       re-encode every page even if its .webp already exists and is up to date
  --keep-png    do not delete the manuals/pages/<slug>/*.png intermediates afterwards
  --help        show this message and exit 0
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help)
      usage
      exit 0
      ;;
    --slug)
      [ $# -ge 2 ] || { echo "ERROR: --slug requires an argument" >&2; exit 1; }
      ONLY_SLUG="$2"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --keep-png)
      KEEP_PNG=1
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight: everything required, reported as ONE message if anything is missing.
# ---------------------------------------------------------------------------
missing=()
command -v pdftoppm >/dev/null 2>&1 || missing+=("pdftoppm")
command -v pdfinfo  >/dev/null 2>&1 || missing+=("pdfinfo")
command -v python3  >/dev/null 2>&1 || missing+=("python3")

HAVE_CWEBP=0
command -v cwebp >/dev/null 2>&1 && HAVE_CWEBP=1

HAVE_PIL=0
if command -v python3 >/dev/null 2>&1 && python3 -c "from PIL import Image" >/dev/null 2>&1; then
  HAVE_PIL=1
fi

if [ "$HAVE_CWEBP" -eq 0 ] && [ "$HAVE_PIL" -eq 0 ]; then
  missing+=("a WebP encoder (cwebp, or python3 with a working 'from PIL import Image')")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  echo "ERROR: missing required tool(s): ${missing[*]}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Slug mapping -- identical to scripts/extract-pages.sh (read there, not changed here).
# ---------------------------------------------------------------------------
slug_for() {
  case "$1" in
    SXC-1_guide_book_JA) echo guide-book ;;
    SXC-1_MIDI_JA)       echo midi ;;
    SXC-1_OSS_JA)        echo oss ;;
    SXC-1_SUG_WB_JA)     echo startup-guide ;;
    *)                   echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# Encode one PNG to WebP at $2, trying both lossy q88 and lossless, keeping the
# smaller. Echoes "lossy" or "lossless" on stdout to report the winner.
# ---------------------------------------------------------------------------
encode_page() {
  local png="$1" out="$2" tmp_lossy tmp_lossless sz_lossy sz_lossless winner
  tmp_lossy="$(mktemp -u "${out}.lossy.XXXXXX.webp")"
  tmp_lossless="$(mktemp -u "${out}.lossless.XXXXXX.webp")"

  if [ "$HAVE_CWEBP" -eq 1 ]; then
    cwebp -quiet -q 88 -m 6 "$png" -o "$tmp_lossy"
    cwebp -quiet -lossless -m 6 "$png" -o "$tmp_lossless"
  else
    python3 - "$png" "$tmp_lossy" "$tmp_lossless" <<'PYEOF'
import sys
from PIL import Image

png_path, lossy_path, lossless_path = sys.argv[1], sys.argv[2], sys.argv[3]
im = Image.open(png_path)
if im.mode not in ("RGB", "RGBA"):
    im = im.convert("RGB")
im.save(lossy_path, format="WEBP", quality=88, method=6)
im.save(lossless_path, format="WEBP", lossless=True, method=6)
PYEOF
  fi

  sz_lossy=$(stat -c%s "$tmp_lossy")
  sz_lossless=$(stat -c%s "$tmp_lossless")

  if [ "$sz_lossy" -le "$sz_lossless" ]; then
    mv -f "$tmp_lossy" "$out"
    rm -f "$tmp_lossless"
    winner="lossy"
  else
    mv -f "$tmp_lossless" "$out"
    rm -f "$tmp_lossy"
    winner="lossless"
  fi
  echo "$winner"
}

# ---------------------------------------------------------------------------
# Does document $slug (source $pdf, $pages pages) have any page whose WebP is
# missing, stale, or being forced? Returns 0 (true) if there is work to do.
# ---------------------------------------------------------------------------
doc_needs_work() {
  local slug="$1" pdf="$2" pages="$3" i nn webp
  [ "$FORCE" -eq 1 ] && return 0
  for i in $(seq 1 "$pages"); do
    nn=$(printf '%02d' "$i")
    webp="$OUT_DIR/$slug/page-$nn.webp"
    if [ ! -e "$webp" ] || [ "$pdf" -nt "$webp" ]; then
      return 0
    fi
  done
  return 1
}

human_mb() {
  awk -v b="$1" 'BEGIN{printf "%.2f", b/1000000}'
}

# ---------------------------------------------------------------------------
# Main loop.
# ---------------------------------------------------------------------------
printf '%-14s %6s %-16s %11s %11s %6s %9s %10s\n' \
  "document" "pages" "status" "png MB" "webp MB" "lossy" "lossless" "largest KB"
printf -- '-------------- ------ ---------------- ----------- ----------- ------ --------- ----------\n'

grand_webp_bytes=0
grand_png_bytes=0
grand_pages=0
grand_max_bytes=0
grand_max_desc=""

for pdf in "$MANUALS_DIR"/*.pdf; do
  base=$(basename "$pdf" .pdf)
  slug=$(slug_for "$base")

  if [ -n "$ONLY_SLUG" ] && [ "$slug" != "$ONLY_SLUG" ]; then
    continue
  fi

  pages=$(pdfinfo "$pdf" | awk '/^Pages:/{print $2}')
  out_dir="$OUT_DIR/$slug"
  png_dir="$PAGES_SCRATCH_DIR/$slug"
  mkdir -p "$out_dir"

  if ! doc_needs_work "$slug" "$pdf" "$pages"; then
    webp_bytes=0
    max_bytes=0
    max_page=""
    for f in "$out_dir"/page-*.webp; do
      [ -e "$f" ] || continue
      sz=$(stat -c%s "$f")
      webp_bytes=$((webp_bytes + sz))
      if [ "$sz" -gt "$max_bytes" ]; then
        max_bytes=$sz
        max_page=$(basename "$f")
      fi
    done
    printf '%-14s %6s %-16s %11s %11s %6s %9s %10s\n' \
      "$slug" "$pages" "skip(up-to-date)" "-" "$(human_mb "$webp_bytes")" "-" "-" "$((max_bytes/1000))"
    grand_webp_bytes=$((grand_webp_bytes + webp_bytes))
    grand_pages=$((grand_pages + pages))
    if [ "$max_bytes" -gt "$grand_max_bytes" ]; then
      grand_max_bytes=$max_bytes
      grand_max_desc="$slug/$max_page"
    fi
    continue
  fi

  mkdir -p "$png_dir"
  pdftoppm -png -r 150 "$pdf" "$png_dir/page"

  # Normalise pdftoppm's variable zero padding to page-NN.png -- identical logic to
  # scripts/extract-pages.sh.
  for f in "$png_dir"/page-*.png; do
    n=${f##*page-}; n=${n%.png}
    printf -v target '%s/page-%02d.png' "$png_dir" "$((10#$n))"
    [ "$f" = "$target" ] || mv "$f" "$target"
  done

  n_lossy=0
  n_lossless=0
  pages_encoded=0
  for i in $(seq 1 "$pages"); do
    nn=$(printf '%02d' "$i")
    png="$png_dir/page-$nn.png"
    webp="$out_dir/page-$nn.webp"

    if [ "$FORCE" -eq 0 ] && [ -e "$webp" ] && [ ! "$pdf" -nt "$webp" ]; then
      continue
    fi

    winner=$(encode_page "$png" "$webp")
    if [ "$winner" = "lossy" ]; then
      n_lossy=$((n_lossy + 1))
    else
      n_lossless=$((n_lossless + 1))
    fi
    pages_encoded=$((pages_encoded + 1))
  done

  png_bytes=0
  for f in "$png_dir"/page-*.png; do
    [ -e "$f" ] || continue
    png_bytes=$((png_bytes + $(stat -c%s "$f")))
  done

  webp_bytes=0
  max_bytes=0
  max_page=""
  for f in "$out_dir"/page-*.webp; do
    [ -e "$f" ] || continue
    sz=$(stat -c%s "$f")
    webp_bytes=$((webp_bytes + sz))
    if [ "$sz" -gt "$max_bytes" ]; then
      max_bytes=$sz
      max_page=$(basename "$f")
    fi
  done

  if [ "$KEEP_PNG" -eq 0 ]; then
    rm -rf "$png_dir"
  fi

  status="encoded $pages_encoded/$pages"
  printf '%-14s %6s %-16s %11s %11s %6s %9s %10s\n' \
    "$slug" "$pages" "$status" "$(human_mb "$png_bytes")" "$(human_mb "$webp_bytes")" \
    "$n_lossy" "$n_lossless" "$((max_bytes/1000))"

  grand_webp_bytes=$((grand_webp_bytes + webp_bytes))
  grand_png_bytes=$((grand_png_bytes + png_bytes))
  grand_pages=$((grand_pages + pages))
  if [ "$max_bytes" -gt "$grand_max_bytes" ]; then
    grand_max_bytes=$max_bytes
    grand_max_desc="$slug/$max_page"
  fi
done

printf -- '-------------- ------ ---------------- ----------- ----------- ------ --------- ----------\n'
printf 'TOTAL          %6s %-16s %11s %11s %6s %9s %10s\n' \
  "$grand_pages" "" "$(human_mb "$grand_png_bytes")" "$(human_mb "$grand_webp_bytes")" "" "" ""
echo "largest single page: $grand_max_desc ($((grand_max_bytes/1000)) KB)"
echo "encoder used: $([ "$HAVE_CWEBP" -eq 1 ] && echo cwebp || echo 'python3 + Pillow')"

exit 0
