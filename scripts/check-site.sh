#!/usr/bin/env bash
# check-site.sh -- verify an EXISTING site/public/ build. This is the single
# command that proves M0's definition of done: it does not build anything
# (run ./scripts/build-site.sh first), it only checks what is already there.
#
# Usage:
#   ./scripts/check-site.sh [--skip-browser] [--port N] [--dir DIR] [--help]
#
# Exit status: 0 if every check passed, non-zero otherwise. Every check runs
# regardless of earlier failures (a full report is more useful than bailing
# on the first FAIL); the summary line at the end says how many passed.
#
# Final machine-readable marker (last line before the exit code, see the
# "Final: summary + machine-readable result marker" section near the bottom
# of this script):
#   check-site: result=complete         every check actually ran: SKIPPED
#                                        is exactly 0, on every axis.
#   check-site: result=structural-only  one or more checks were SKIPPED --
#                                        currently via --skip-browser /
#                                        SXC1_SKIP_BROWSER=1 and/or
#                                        --skip-content / SXC1_SKIP_CONTENT=1.
# CI must assert BOTH result=complete AND zero skipped checks (see
# .github/workflows/site.yml) so a silently skipped axis -- on either flag,
# or any future third one -- cannot masquerade as a full gate. (NEW7, M1
# gate round 3: this marker used to key off --skip-browser alone, which
# silently stopped being the whole truth the day --skip-content was added;
# see the final-marker section below for the fix.)
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from this script's location so it works from any cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

DIR="$REPO_ROOT/site/public"
PORT="${SXC1_PORT:-8123}"
SKIP_BROWSER=0
if [ "${SXC1_SKIP_BROWSER:-0}" = "1" ]; then
  SKIP_BROWSER=1
fi
# --skip-content: local-iteration escape hatch for the exe:content-check +
# three-way content agreement checks (B and C below), which need a built
# wasm32-wasi content-check binary. Off by default -- see check 11's usage
# text for why this must never be the default.
SKIP_CONTENT=0
if [ "${SXC1_SKIP_CONTENT:-0}" = "1" ]; then
  SKIP_CONTENT=1
fi

usage() {
  cat <<EOF
Usage: $(basename -- "${BASH_SOURCE[0]}") [options]

Verify an EXISTING site/public/ build (structural checks + headless-Chrome
smoke tests, including a GitHub-Pages-subpath deployability test). Does NOT
build the site -- run ./scripts/build-site.sh first if site/public is
missing or stale.

Options:
  --skip-browser   Skip the headless-browser checks (also honoured via the
                   SXC1_SKIP_BROWSER=1 environment variable). The browser
                   checks are counted as SKIPPED members of the total and
                   the final marker reads result=structural-only instead of
                   result=complete -- this is a local escape hatch only;
                   CI asserts result=complete AND zero skipped checks.
  --skip-content   SKIPPED (conspicuously, never silently) the exe:content-check
                   run, the three-way content agreement check, and the
                   exact-bytes source-integrity check (also honoured via
                   SXC1_SKIP_CONTENT=1). Local-iteration escape hatch only --
                   never the default, and CI must not pass it. Like
                   --skip-browser, this also flips the final marker to
                   result=structural-only (NEW7: both skippable axes now
                   drive the same marker, via the SKIPPED counter, so
                   neither can silently report result=complete). When
                   skipped, checks 7/8's browser run falls back to
                   scripts/browser-check.mjs's own built-in golden numbers
                   instead of --expect-json.
  --port N         TCP port to try first for the dev server used by the
                   browser checks (default: 8123, env SXC1_PORT). If busy,
                   the next free port is used instead.
  --dir DIR        Directory to check (default: <repo>/site/public).
  --help           Show this help and exit.

Node.js resolution (needed for the wasm export check and to run
scripts/browser-check.mjs): the first of these that runs and exposes a
global WebSocket + WebAssembly wins --
  1. \$SXC1_NODE                                  explicit override
  2. \${GHC_WASM_PREFIX:-\$HOME/.ghc-wasm}/nodejs/bin/node   toolchain's private Node
  3. node                                          on PATH
Node 22+ is required for the global WebSocket used by the browser driver;
M0 was validated on Node 24. If none of the above qualifies, check-site.sh
fails immediately with an actionable message.

Checks performed, in order:
  1. Required files exist at the root of the directory.
  2. app.wasm begins with the \0asm magic bytes and version 1.
  3. app.wasm exports hs_start, memory and _initialize (via the resolved
     Node's WebAssembly.Module.exports -- proves the reactor exec-model and
     --export linker flags took effect).
  4. ghc_wasm_jsffi.js is larger than 1 KiB and has a default export.
  5. index.html / index.js contain no root-absolute URL and no external
     origin, by a broadened syntactic scan (single/double quotes, template
     literals, CSS url(...), new URL(...), protocol-relative //host). This
     scan is advisory defence-in-depth and a better error message ONLY --
     see check 8 below for the authoritative test of this property.
  6. Byte sizes of app.wasm and ghc_wasm_jsffi.js, raw and gzipped
     (informational, never a failure).
  7. A real headless-Chrome run of scripts/browser-check.mjs against the
     bundle served at the root of a local HTTP server, unless skipped.
  8. THE AUTHORITATIVE GitHub-Pages-subpath deployability test: the bundle
     is copied under a non-root prefix ("<tmp>/sub/path/"), served there,
     and scripts/browser-check.mjs is required to pass against it, unless
     skipped. A bundle that only works at the origin root (e.g. because it
     fetches an absolute "/app.wasm" instead of a relative "./app.wasm")
     fails this check even when check 5's syntactic scan misses it.
  9. PAGE IMAGES: every site/public/pages/<slug>/page-NN.webp exists for
     guide-book (1-71), startup-guide (1-15), midi (1-6) and oss (1-16) --
     108 files, two-digit zero padding. Each is validated as a REAL WebP,
     not just a 12-byte magic prefix (NEW6, host half): the RIFF chunk-size
     field must match the file's actual size, the chunk immediately after
     "WEBP" must be one of the three real WebP payload types (VP8 /VP8L/
     VP8X), and the pixel dimensions parsed from that chunk must be
     plausible. None exceeds 300 KB, and the total is under 12 MB (info).
     This is a fast, dependency-free, non-authoritative check; the
     AUTHORITATIVE decoder is checks 7/8's real headless-Chrome image
     decode (see NEW6, browser half, below).
  10. CONTENT CHECKER: sources $HOME/.ghc-wasm/env (actionable failure, not
     a silent skip, if missing), resolves exe:content-check via
     `wasm32-wasi-cabal list-bin`, and runs it under wasm-run.mjs -- must
     exit 0. FAILs (never silently skips) with "run ./scripts/build-site.sh
     first" if the binary is missing; `wasmtime run --dir=/ <binary>` is
     the documented fallback runner. Unless --skip-content.
  11. THREE-WAY CONTENT AGREEMENT: `exe:content-check --json`'s stats are
     diffed field-by-field (chars, lines, pages, headings, tables, figures,
     sections, subsections, parts, per document) against numbers an
     embedded python3 snippet recomputes INDEPENDENTLY, straight from
     translations/*.md by regex. This is a STRUCTURAL fingerprint -- it
     catches a translation edited without rebuilding IF the edit changes
     any counted field. Unless --skip-content. The same JSON is also passed
     to checks 7/8's scripts/browser-check.mjs via --expect-json, so the
     running app is compared against numbers derived from the source of
     truth rather than constants baked into the harness.
  12. EXACT-BYTES SOURCE INTEGRITY (NEW4): unlike check 11's structural
     fingerprint, this compares actual bytes -- `exe:content-check
     --dump-source <slug>` (stdout: the exact embedded UTF-8 bytes, no
     banner, no added trailing newline) diffed byte-for-byte against
     translations/<slug>.md, for all five embedded documents (guide-book,
     startup-guide, midi, oss, glossary). Catches an equal-length,
     line-count-preserving prose edit that check 11 cannot. Unless
     --skip-content.
  13. APP.WASM SIZE TRIPWIRE (A5): app.wasm's gzip size must stay under a
     hard, deliberately generous ceiling (see the check itself for the
     current value and rationale). Never a diet, never expected to fire
     today -- it exists so the bundle roughly doubling before it is caught
     some other way still fails loudly here. The current value and
     headroom are printed on every run, skip or no skip.

Exit status is non-zero if any check (other than the informational size
report) failed.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-browser)
      SKIP_BROWSER=1
      shift
      ;;
    --skip-content)
      SKIP_CONTENT=1
      shift
      ;;
    --port)
      [ "$#" -ge 2 ] || { echo "error: --port requires an argument" >&2; exit 1; }
      PORT="$2"
      shift 2
      ;;
    --port=*)
      PORT="${1#--port=}"
      shift
      ;;
    --dir)
      [ "$#" -ge 2 ] || { echo "error: --dir requires an argument" >&2; exit 1; }
      DIR="$2"
      shift 2
      ;;
    --dir=*)
      DIR="${1#--dir=}"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "check-site.sh: unrecognized option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$DIR" ]; then
  echo "check-site: '$DIR' does not exist -- run ./scripts/build-site.sh first" >&2
  exit 1
fi
DIR="$(cd -- "$DIR" >/dev/null 2>&1 && pwd -P)"

# ---------------------------------------------------------------------------
# M5 fix: resolve Node explicitly instead of relying on a bare `node` that
# may not exist on a host meeting every OTHER documented prerequisite.
# Order: $SXC1_NODE > the toolchain's private Node > `node` on PATH. The
# chosen binary is validated once (it must run and expose a global
# WebSocket + WebAssembly, both required by scripts/browser-check.mjs) so a
# too-old Node fails here, loudly, instead of failing late and confusingly
# inside the CDP driver.
# ---------------------------------------------------------------------------
node_is_usable() {
  local bin="$1"
  [ -x "$bin" ] || command -v "$bin" >/dev/null 2>&1 || return 1
  "$bin" -e '
    if (typeof WebSocket !== "function") { process.exit(1); }
    if (typeof WebAssembly === "undefined") { process.exit(1); }
  ' >/dev/null 2>&1
}

NODE=""
NODE_SOURCE=""
if [ -n "${SXC1_NODE:-}" ]; then
  # SXC1_NODE is an explicit override: if it does not work, that is a
  # configuration error to report, NOT a cue to silently fall back to a
  # lower-priority candidate (which would hide the misconfiguration).
  if node_is_usable "$SXC1_NODE"; then
    NODE="$SXC1_NODE"
    NODE_SOURCE='$SXC1_NODE'
  fi
else
  TOOLCHAIN_NODE="${GHC_WASM_PREFIX:-$HOME/.ghc-wasm}/nodejs/bin/node"
  if node_is_usable "$TOOLCHAIN_NODE"; then
    NODE="$TOOLCHAIN_NODE"
    NODE_SOURCE="toolchain private Node"
  elif command -v node >/dev/null 2>&1 && node_is_usable "$(command -v node)"; then
    NODE="$(command -v node)"
    NODE_SOURCE="PATH"
  fi
fi

if [ -z "$NODE" ]; then
  {
    if [ -n "${SXC1_NODE:-}" ]; then
      echo "check-site: SXC1_NODE=$SXC1_NODE is not a usable Node.js -- refusing to silently fall back."
    else
      echo "check-site: no usable Node.js found."
    fi
    echo "  Tried, in order: \$SXC1_NODE, \${GHC_WASM_PREFIX:-\$HOME/.ghc-wasm}/nodejs/bin/node, 'node' on PATH."
    echo "  A usable Node must run and provide a global WebSocket (Node 22+ required;"
    echo "  M0 was validated on Node 24) plus WebAssembly."
    echo "  Fix: set SXC1_NODE=/path/to/node, install/upgrade Node, or run"
    echo "  ./scripts/install-toolchain.sh to get the toolchain's private Node."
  } >&2
  exit 1
fi
NODE_VERSION="$("$NODE" --version 2>/dev/null || echo '<unknown>')"
echo "check-site: using Node $NODE_VERSION from $NODE_SOURCE ($NODE)"

# ---------------------------------------------------------------------------
# Reporting helpers.
# ---------------------------------------------------------------------------
PASS=0
TOTAL=0
SKIPPED=0
FAILED=0

ok() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo "ok   - $1"
}

fail() {
  TOTAL=$((TOTAL + 1))
  FAILED=1
  echo "FAIL - $1"
}

skip() {
  TOTAL=$((TOTAL + 1))
  SKIPPED=$((SKIPPED + 1))
  echo "SKIP - $1"
}

info() {
  echo "info - $1"
}

# ---------------------------------------------------------------------------
# Server + log cleanup (m1/n1 fix): every server we start and every log file
# we create for it is tracked here so a trap on every exit path (normal,
# INT, TERM) tears it down -- no leaked processes, no leaked /tmp files.
# Logs are deleted unconditionally; if the run had already failed by the
# time cleanup runs, each log's contents are printed first (more useful
# than a silently discarded file).
# ---------------------------------------------------------------------------
SERVER_PIDS=()
SERVER_LOGS=()
# NEW1 fix: any temp DIRECTORY (as opposed to the log FILES above) that a
# check creates -- e.g. the sub-path bundle copy below -- is registered here
# so cleanup() (which already runs on EXIT/INT/TERM) removes it on every
# exit path, not just the happy one. Initialised before the traps are
# installed so cleanup can never reference it unset.
TEMP_DIRS=()
# Same idea for ordinary temp FILES the content-checker/three-way checks
# create (the captured --json, the embedded python3 snippet's script file):
# tracked here, never left behind, regardless of which check fails.
TEMP_FILES=()

cleanup() {
  local pid
  for pid in "${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}"; do
    [ -n "$pid" ] || continue
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true
  done
  SERVER_PIDS=()

  local log
  for log in "${SERVER_LOGS[@]+"${SERVER_LOGS[@]}"}"; do
    [ -n "$log" ] || continue
    if [ "$FAILED" -ne 0 ] && [ -s "$log" ]; then
      echo "----- server log ($log) -----" >&2
      cat "$log" >&2
      echo "----- end server log -----" >&2
    fi
    rm -f "$log"
  done
  SERVER_LOGS=()

  local dir
  for dir in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    [ -n "$dir" ] || continue
    rm -rf "$dir"
  done
  TEMP_DIRS=()

  local f
  for f in "${TEMP_FILES[@]+"${TEMP_FILES[@]}"}"; do
    [ -n "$f" ] || continue
    rm -f "$f"
  done
  TEMP_FILES=()
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# register_temp_dir/unregister_temp_dir: bookkeeping for TEMP_DIRS above.
# register immediately after every `mktemp -d` (never later -- see NEW1);
# unregister only once a caller has already removed the path itself on the
# happy path, so cleanup() cannot later try to remove a path some other
# process has since reused.
register_temp_dir() {
  TEMP_DIRS+=("$1")
}

unregister_temp_dir() {
  local target="$1" d filtered=()
  for d in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
    [ "$d" = "$target" ] || filtered+=("$d")
  done
  TEMP_DIRS=("${filtered[@]+"${filtered[@]}"}")
}

# register_temp_file: bookkeeping for TEMP_FILES above (mirrors
# register_temp_dir). Register immediately after every `mktemp` used by the
# content-checker / three-way checks below.
register_temp_file() {
  TEMP_FILES+=("$1")
}

echo "check-site: checking '$DIR'"

# ===========================================================================
# Check 1: required files exist at the root of the build directory.
# ===========================================================================
REQUIRED_FILES=(
  "index.html"
  "index.js"
  "app.wasm"
  "ghc_wasm_jsffi.js"
  ".nojekyll"
  "vendor/browser_wasi_shim/index.js"
)
for rel in "${REQUIRED_FILES[@]}"; do
  if [ -f "$DIR/$rel" ]; then
    ok "required file present: $rel"
  else
    fail "required file present: $rel (observed: missing)"
  fi
done

# ===========================================================================
# Check 2: app.wasm begins with the 8-byte \0asm + version-1 magic.
# ===========================================================================
WASM_FILE="$DIR/app.wasm"
if [ -f "$WASM_FILE" ]; then
  MAGIC_OBSERVED="$(head -c 8 "$WASM_FILE" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
else
  MAGIC_OBSERVED=""
fi
if [ "$MAGIC_OBSERVED" = "0061736d01000000" ]; then
  ok "app.wasm magic bytes are \\0asm version 1 (observed: $MAGIC_OBSERVED)"
else
  fail "app.wasm magic bytes are \\0asm version 1 (observed: ${MAGIC_OBSERVED:-<missing>})"
fi

# ===========================================================================
# Check 3: app.wasm exports hs_start, memory and _initialize (via the
# resolved Node). This is the direct proof that the reactor exec-model and
# --export linker flags took effect.
# ===========================================================================
node_wasm_exports() {
  "$NODE" -e '
    const fs = require("fs");
    const bytes = fs.readFileSync(process.argv[1]);
    WebAssembly.compile(bytes).then((mod) => {
      const names = WebAssembly.Module.exports(mod).map((e) => e.name);
      console.log(names.join(","));
    }).catch((e) => {
      console.error(String(e && e.message ? e.message : e));
      process.exit(1);
    });
  ' "$1"
}

WASM_EXPORTS=""
WASM_EXPORTS_OK=0
if [ -f "$WASM_FILE" ]; then
  if WASM_EXPORTS="$(node_wasm_exports "$WASM_FILE" 2>&1)"; then
    WASM_EXPORTS_OK=1
  fi
fi

for name in hs_start memory _initialize; do
  if [ "$WASM_EXPORTS_OK" -eq 1 ] && printf '%s\n' "$WASM_EXPORTS" | tr ',' '\n' | grep -qx -- "$name"; then
    ok "app.wasm exports '$name'"
  else
    fail "app.wasm exports '$name' (observed: ${WASM_EXPORTS:-<compile failed>})"
  fi
done

# ===========================================================================
# Check 4: ghc_wasm_jsffi.js is a non-trivial ES module.
# ===========================================================================
JSFFI_FILE="$DIR/ghc_wasm_jsffi.js"
if [ -f "$JSFFI_FILE" ]; then
  JSFFI_SIZE="$(wc -c < "$JSFFI_FILE" | tr -d ' ')"
else
  JSFFI_SIZE=0
fi
if [ "$JSFFI_SIZE" -gt 1024 ]; then
  ok "ghc_wasm_jsffi.js is larger than 1 KiB (observed: $JSFFI_SIZE bytes)"
else
  fail "ghc_wasm_jsffi.js is larger than 1 KiB (observed: $JSFFI_SIZE bytes)"
fi

if [ -f "$JSFFI_FILE" ] && grep -q 'export default' "$JSFFI_FILE"; then
  ok "ghc_wasm_jsffi.js has a default export"
else
  fail "ghc_wasm_jsffi.js has a default export (observed: no 'export default' found)"
fi

# ===========================================================================
# Check 5 (M9, advisory half): syntactic scan for root-absolute URLs and
# external origins in index.html/index.js.
#
# IMPORTANT: this grep is advisory defence-in-depth and a better error
# message ONLY. It is NOT the control that enforces GitHub-Pages-subpath
# deployability -- that is check 8 below, which actually serves the bundle
# under a non-root prefix and requires the browser check to pass there.
# Do not "fix" a future miss here by widening the regex alone; if this scan
# and the sub-path run ever disagree, the sub-path run is authoritative.
# ===========================================================================
check_no_root_absolute() {
  local file="$1" rel="$2" pattern hit=""
  local patterns=(
    'src="/' "src='/" 'src=`/'
    'href="/' "href='/" 'href=`/'
    'from "/' "from '/" 'from `/'
    'fetch("/' "fetch('/" 'fetch(`/'
    'import("/' "import('/" 'import(`/'
    "new URL(\"/" "new URL('/" "new URL(\`/"
    'url(/'
  )
  for pattern in "${patterns[@]}"; do
    if [ -f "$file" ] && grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
      hit="$pattern"
      break
    fi
  done
  if [ -z "$hit" ]; then
    ok "$rel has no root-absolute URL (advisory scan; see check 8 for the authoritative test)"
  else
    fail "$rel has no root-absolute URL (observed match: $hit)"
  fi
}

check_no_external_origin() {
  local file="$1" rel="$2" pattern hit=""
  local patterns=(
    'http://' 'https://'
    'src="//' "src='//" 'src=`//'
    'href="//' "href='//" 'href=`//'
    'from "//' "from '//" 'from `//'
    'fetch("//' "fetch('//" 'fetch(`//'
    'import("//' "import('//" 'import(`//'
    "new URL(\"//" "new URL('//" "new URL(\`//"
    'url(//'
  )
  for pattern in "${patterns[@]}"; do
    if [ -f "$file" ] && grep -F -- "$pattern" "$file" >/dev/null 2>&1; then
      hit="$pattern"
      break
    fi
  done
  if [ -z "$hit" ]; then
    ok "$rel has no external-origin URL (advisory scan; see check 8 for the authoritative test)"
  else
    fail "$rel has no external-origin URL (observed match: $hit)"
  fi
}

check_no_root_absolute "$DIR/index.html" "index.html"
check_no_external_origin "$DIR/index.html" "index.html"
check_no_root_absolute "$DIR/index.js" "index.js"
check_no_external_origin "$DIR/index.js" "index.js"

# ===========================================================================
# Check 6: byte sizes, raw and gzipped -- informational, never a failure.
# ===========================================================================
report_size() {
  local file="$1" label="$2"
  if [ -f "$file" ]; then
    local raw gz
    raw="$(wc -c < "$file" | tr -d ' ')"
    gz="$(gzip -c "$file" | wc -c | tr -d ' ')"
    info "$label: $raw bytes raw, $gz bytes gzipped"
  else
    info "$label: <missing>"
  fi
}

report_size "$WASM_FILE" "app.wasm"
report_size "$JSFFI_FILE" "ghc_wasm_jsffi.js"

# ===========================================================================
# Check 13 (A5 size tripwire, M1 gate round 3): hard gzip ceiling on
# app.wasm.
#
# Check 6 above reports raw/gzip sizes purely as info and never fails --
# deliberately, ordinary size drift shouldn't break the gate. But Codex's
# A5 finding was that NOTHING anywhere fails on size, so the bundle could
# double before M2 lands and nobody would notice from CI. This adds
# exactly one hard, DELIBERATELY GENEROUS ceiling on the gzip size of
# app.wasm (the artifact that actually has to travel over the network).
#
# Sizing rationale (read this before ever moving the constant): at the
# time this check was written, gzip(app.wasm) measured ~827,602 bytes --
# already +27.8% over the M0-era design probe after M1's manual-reader
# content/parser work, per Codex's own measurement of ~823,588 bytes a
# round earlier. The ceiling below is set at 1,000,000 bytes: comfortable
# headroom over today's value (not a diet), but well short of "the app
# doubled and nobody noticed." A tripwire nobody trips is the point one
# is added now, before M2, rather than after the bundle has already grown
# past a budget added in hindsight. The current value and headroom are
# printed on every run (regardless of pass/fail) so growth is visible in
# CI logs long before the ceiling is ever approached. If this constant
# ever needs to move, that must be a deliberate, explained change -- not
# a silent bump to make a red build green.
# ===========================================================================
WASM_GZIP_CEILING_BYTES=1000000
if [ -f "$WASM_FILE" ]; then
  WASM_GZIP_BYTES="$(gzip -c "$WASM_FILE" | wc -c | tr -d ' ')"
  WASM_GZIP_HEADROOM=$((WASM_GZIP_CEILING_BYTES - WASM_GZIP_BYTES))
  info "app.wasm gzip size = $WASM_GZIP_BYTES bytes; ceiling = $WASM_GZIP_CEILING_BYTES bytes; headroom = $WASM_GZIP_HEADROOM bytes"
  if [ "$WASM_GZIP_BYTES" -lt "$WASM_GZIP_CEILING_BYTES" ]; then
    ok "app.wasm gzip size is under the $WASM_GZIP_CEILING_BYTES byte ceiling (observed: $WASM_GZIP_BYTES bytes, headroom $WASM_GZIP_HEADROOM bytes)"
  else
    fail "app.wasm gzip size is under the $WASM_GZIP_CEILING_BYTES byte ceiling (observed: $WASM_GZIP_BYTES bytes, OVER by $((WASM_GZIP_BYTES - WASM_GZIP_CEILING_BYTES)) bytes -- A5 size tripwire tripped)"
  fi
else
  fail "app.wasm gzip size is under the $WASM_GZIP_CEILING_BYTES byte ceiling (observed: app.wasm missing)"
fi

# ===========================================================================
# Check 9: PAGE IMAGES. site/public/pages/<slug>/page-NN.webp exists for
# guide-book 1-71, startup-guide 1-15, midi 1-6, oss 1-16 (108 files,
# two-digit zero padding); none exceeds 300 KB; the total is under 12 MB
# (reported as info). A single python3 pass (not 108 shell/dd invocations)
# does the byte-level work and prints OK/FAIL/INFO lines that this script
# just dispatches (any "OK <label> ..." / "FAIL <label> ..." line becomes
# an ok()/fail() call automatically -- the dispatch loop below does not
# hardcode label text).
#
# NEW6 (host half, M1 gate round 3): the original version of this check
# validated only a 12-byte magic prefix ("RIFF"...."WEBP" at offsets 0/8).
# Codex demonstrated that a copy of midi/page-03.webp corrupted from byte
# 12 onward -- while preserving that prefix AND the RIFF length field --
# sailed straight through: PIL could not decode it, but this gate reported
# all-OK. This check now also, still with no third-party library (no
# Pillow, no cwebp) so CI stays dependency-free: (a) validates the RIFF
# chunk-size field against the file's actual size, (b) requires the chunk
# immediately after "WEBP" to be one of the three real WebP payload types
# (VP8 /VP8L/VP8X -- Codex's corruption turns this into "AAAA", which is
# exactly what this catches), and (c) parses and sanity-checks the pixel
# dimensions carried in that chunk against a generous range (real files
# here are 875x1241 or 1241x1755). This is a minimal, purpose-built
# reimplementation of the RIFF/WebP container header, not a general
# decoder -- it is fast (no full pixel decode) but still NOT authoritative:
# the AUTHORITATIVE decoder is checks 7/8's real headless-Chrome run of
# scripts/browser-check.mjs, which really calls img.decode() on every one
# of the 108 images (see NEW6, browser half). This host-side check exists
# so a corrupted committed file is still caught locally even when
# --skip-browser is used.
# ===========================================================================
PAGE_IMAGES_PY="$(mktemp -t sxc1-check-site-pages.XXXXXX.py)"
register_temp_file "$PAGE_IMAGES_PY"
cat > "$PAGE_IMAGES_PY" <<'PYEOF'
import os
import struct
import sys

BASE = sys.argv[1]
DOCS = [("guide-book", 71), ("startup-guide", 15), ("midi", 6), ("oss", 16)]
MAX_BYTES = 300 * 1024
TOTAL_MAX_BYTES = 12 * 1024 * 1024

# Generous sanity range for pixel dimensions -- real renders here are
# 875x1241 (most pages) or 1241x1755 (midi's landscape-source pages); this
# is deliberately wide so a legitimate future re-render at a different DPI
# does not need this constant touched, while still catching "the chunk
# parsed to 0x0" or similarly nonsensical values a corrupted payload
# produces.
DIM_MIN = 200
DIM_MAX = 3000


def parse_dims(head):
    """head: at least the first 30 bytes of a .webp file (offset 12 is
    already known to be the 4-byte chunk FourCC immediately after "WEBP").
    Returns (width, height); raises ValueError with a human-readable reason
    if the chunk type is unrecognised or its payload is truncated/malformed."""
    fourcc = head[12:16]
    if fourcc == b"VP8 ":
        # Lossy: payload = 3-byte frame tag, 3-byte start code
        # (0x9d 0x01 0x2a), then 14-bit width and 14-bit height, both LE
        # with 2 high bits reserved for a scale factor we ignore here.
        payload = head[20:30]
        if len(payload) < 10 or payload[3:6] != b"\x9d\x01\x2a":
            raise ValueError("VP8 chunk missing its 0x9d 0x01 0x2a start code")
        w = payload[6] | ((payload[7] & 0x3F) << 8)
        h = payload[8] | ((payload[9] & 0x3F) << 8)
        return w, h
    if fourcc == b"VP8L":
        # Lossless: payload = 1-byte signature (0x2f), then a 32-bit LE
        # bitfield packing (width-1):14, (height-1):14, alpha:1, version:3.
        payload = head[20:26]
        if len(payload) < 5 or payload[0] != 0x2F:
            raise ValueError("VP8L chunk missing its 0x2f signature byte")
        bits = payload[1] | (payload[2] << 8) | (payload[3] << 16) | (payload[4] << 24)
        w = (bits & 0x3FFF) + 1
        h = ((bits >> 14) & 0x3FFF) + 1
        return w, h
    if fourcc == b"VP8X":
        # Extended: payload = 1 byte flags, 3 bytes reserved, then 24-bit
        # LE (canvas width-1) and 24-bit LE (canvas height-1).
        payload = head[20:30]
        if len(payload) < 10:
            raise ValueError("VP8X chunk truncated")
        w = (payload[4] | (payload[5] << 8) | (payload[6] << 16)) + 1
        h = (payload[7] | (payload[8] << 8) | (payload[9] << 16)) + 1
        return w, h
    raise ValueError("chunk after 'WEBP' is %r, not one of VP8 /VP8L/VP8X" % (fourcc,))


total_bytes = 0
overall_ok = True
oversize_details = []

for slug, count in DOCS:
    missing = []
    bad_magic = []
    bad_riff_len = []
    bad_chunk = []
    bad_dims = []
    slug_total = 0
    for n in range(1, count + 1):
        fname = "page-%02d.webp" % n
        path = os.path.join(BASE, slug, fname)
        if not os.path.isfile(path):
            missing.append(fname)
            continue
        size = os.path.getsize(path)
        slug_total += size
        if size > MAX_BYTES:
            oversize_details.append("%s/%s=%d bytes" % (slug, fname, size))
        with open(path, "rb") as fh:
            head = fh.read(30)
        if len(head) < 12 or head[0:4] != b"RIFF" or head[8:12] != b"WEBP":
            bad_magic.append(fname)
            continue  # nothing past a broken 12-byte header is meaningful

        riff_len = struct.unpack("<I", head[4:8])[0]
        if riff_len + 8 != size:
            bad_riff_len.append("%s(riff_len+8=%d,actual=%d)" % (fname, riff_len + 8, size))

        try:
            w, h = parse_dims(head)
            if not (DIM_MIN <= w <= DIM_MAX and DIM_MIN <= h <= DIM_MAX):
                bad_dims.append("%s(%dx%d outside [%d,%d])" % (fname, w, h, DIM_MIN, DIM_MAX))
        except ValueError as e:
            bad_chunk.append("%s(%s)" % (fname, e))

    total_bytes += slug_total

    if missing:
        print("FAIL count %s expected=%d files, missing=%s" % (slug, count, ",".join(missing)))
        overall_ok = False
    else:
        print("OK count %s all %d files present (page-01.webp..page-%02d.webp)" % (slug, count, count))

    if bad_magic:
        print("FAIL magic %s files failing RIFF/WEBP magic=%s" % (slug, ",".join(bad_magic)))
        overall_ok = False
    else:
        print("OK magic %s all %d files begin RIFF..WEBP" % (slug, count))

    if bad_riff_len:
        print("FAIL rifflen %s files whose RIFF length field does not match their actual size=%s" % (slug, ",".join(bad_riff_len)))
        overall_ok = False
    else:
        print("OK rifflen %s all %d files' RIFF length field matches their actual size" % (slug, count))

    if bad_chunk:
        print("FAIL chunk %s files not starting with a real VP8 /VP8L/VP8X payload chunk=%s" % (slug, ",".join(bad_chunk)))
        overall_ok = False
    else:
        print("OK chunk %s all %d files begin with a real VP8 /VP8L/VP8X payload chunk" % (slug, count))

    if bad_dims:
        print("FAIL dims %s files with implausible pixel dimensions=%s" % (slug, ",".join(bad_dims)))
        overall_ok = False
    else:
        print("OK dims %s all %d files have plausible pixel dimensions (width and height both in [%d,%d])" % (slug, count, DIM_MIN, DIM_MAX))

if oversize_details:
    print("FAIL maxsize " + "; ".join(oversize_details) + (" (limit %d bytes)" % MAX_BYTES))
    overall_ok = False
else:
    print("OK maxsize none of 108 files exceeds %d bytes (300 KB)" % MAX_BYTES)

print("INFO total %d bytes (%.2f MB) across 108 files" % (total_bytes, total_bytes / 1024.0 / 1024.0))

if total_bytes > TOTAL_MAX_BYTES:
    print("FAIL totalsize %d bytes exceeds %d bytes (12 MB)" % (total_bytes, TOTAL_MAX_BYTES))
    overall_ok = False
else:
    print("OK totalsize %d bytes under %d bytes (12 MB)" % (total_bytes, TOTAL_MAX_BYTES))

sys.exit(0 if overall_ok else 1)
PYEOF

if command -v python3 >/dev/null 2>&1; then
  PAGE_IMAGES_OUT="$(python3 "$PAGE_IMAGES_PY" "$DIR/pages" 2>&1)" || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "OK "*)   ok "page-images/${line#OK }" ;;
      "FAIL "*) fail "page-images/${line#FAIL } (observed above)" ;;
      "INFO "*) info "page-images/${line#INFO }" ;;
      *)        fail "page-images (unexpected output: $line)" ;;
    esac
  done <<< "$PAGE_IMAGES_OUT"
else
  fail "page-images (observed: python3 not found on PATH -- required for check 9)"
fi
rm -f "$PAGE_IMAGES_PY"

# ===========================================================================
# Checks 10 & 11: CONTENT CHECKER + THREE-WAY CONTENT AGREEMENT, unless
# --skip-content. See usage() above for the full description; the short
# version is: (10) exe:content-check, a real Haskell parser over the
# TH-embedded corpus, must run under wasm-run.mjs and exit 0; (11) its
# `--json` stats are diffed field-by-field against numbers an embedded
# python3 snippet recomputes independently, straight from
# translations/*.md -- this is the check that catches a stale build. The
# captured JSON is also handed to checks 7/8's browser driver via
# --expect-json (see CONTENT_JSON_FILE below).
# ===========================================================================
CONTENT_JSON_FILE=""

if [ "$SKIP_CONTENT" -eq 1 ]; then
  echo "SKIPPED -- content checker + three-way content agreement + exact-bytes source integrity (requested via --skip-content or SXC1_SKIP_CONTENT=1)"
  skip "exe:content-check runs under wasm-run.mjs and exits 0"
  skip "three-way content agreement/guide-book (content-check --json vs translations/guide-book.md)"
  skip "three-way content agreement/startup-guide (content-check --json vs translations/startup-guide.md)"
  skip "three-way content agreement/midi (content-check --json vs translations/midi.md)"
  skip "three-way content agreement/oss (content-check --json vs translations/oss.md)"
  skip "exact-bytes source integrity/guide-book (content-check --dump-source vs translations/guide-book.md)"
  skip "exact-bytes source integrity/startup-guide (content-check --dump-source vs translations/startup-guide.md)"
  skip "exact-bytes source integrity/midi (content-check --dump-source vs translations/midi.md)"
  skip "exact-bytes source integrity/oss (content-check --dump-source vs translations/oss.md)"
  skip "exact-bytes source integrity/glossary (content-check --dump-source vs translations/glossary.md)"
else
  TOOLCHAIN_ENV_FILE="${GHC_WASM_PREFIX:-$HOME/.ghc-wasm}/env"
  if [ -f "$TOOLCHAIN_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$TOOLCHAIN_ENV_FILE"
    ok "GHC WebAssembly toolchain env sourced ($TOOLCHAIN_ENV_FILE)"
  else
    fail "GHC WebAssembly toolchain env sourced (observed: '$TOOLCHAIN_ENV_FILE' missing -- run ./scripts/install-toolchain.sh)"
  fi

  CONTENT_CHECK_BIN=""
  if command -v wasm32-wasi-cabal >/dev/null 2>&1; then
    CONTENT_CHECK_BIN="$(cd "$REPO_ROOT/site" && wasm32-wasi-cabal list-bin exe:content-check 2>/dev/null | tail -n1 || true)"
  fi

  if [ -n "$CONTENT_CHECK_BIN" ] && [ -f "$CONTENT_CHECK_BIN" ]; then
    ok "exe:content-check binary resolved (observed: $CONTENT_CHECK_BIN)"
  else
    fail "exe:content-check binary resolved (observed: missing -- run ./scripts/build-site.sh first; fallback runner: wasmtime run --dir=/ <binary>)"
    CONTENT_CHECK_BIN=""
  fi

  if [ -n "$CONTENT_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    CONTENT_RUN_LOG="$(mktemp -t sxc1-check-site-content-run.XXXXXX)"
    register_temp_file "$CONTENT_RUN_LOG"
    if wasm-run.mjs "$CONTENT_CHECK_BIN" >"$CONTENT_RUN_LOG" 2>&1; then
      ok "exe:content-check runs under wasm-run.mjs and exits 0"
    else
      fail "exe:content-check runs under wasm-run.mjs and exits 0 (observed: non-zero exit; output follows)"
      sed 's/^/    /' "$CONTENT_RUN_LOG" >&2
    fi
    rm -f "$CONTENT_RUN_LOG"
  else
    fail "exe:content-check runs under wasm-run.mjs and exits 0 (observed: toolchain env or binary unavailable -- see checks above; fallback runner: wasmtime run --dir=/ <binary>)"
  fi

  # Capture `content-check --json` once, for both the three-way agreement
  # check below and checks 7/8's --expect-json.
  if [ -n "$CONTENT_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    CANDIDATE_JSON="$(mktemp -t sxc1-check-site-stats.XXXXXX.json)"
    register_temp_file "$CANDIDATE_JSON"
    if wasm-run.mjs "$CONTENT_CHECK_BIN" --json >"$CANDIDATE_JSON" 2>/dev/null && [ -s "$CANDIDATE_JSON" ]; then
      CONTENT_JSON_FILE="$CANDIDATE_JSON"
    fi
  fi

  THREEWAY_PY="$(mktemp -t sxc1-check-site-threeway.XXXXXX.py)"
  register_temp_file "$THREEWAY_PY"
  cat > "$THREEWAY_PY" <<'PYEOF'
import json
import re
import sys

DOCS = [
    ("guide-book", "translations/guide-book.md"),
    ("startup-guide", "translations/startup-guide.md"),
    ("midi", "translations/midi.md"),
    ("oss", "translations/oss.md"),
]
FIELDS = ["chars", "lines", "pages", "headings", "tables", "figures", "sections", "subsections", "parts"]

PAGE_MARKER_RE = re.compile(r"^<!-- page (\d+) -->$")
HEADING_LINE_RE = re.compile(r"^#{1,6} +\S")
TABLE_SEP_RE = re.compile(r"^\s*\|[\s:|-]+\|\s*$")
FIGURE_RE = re.compile(r"(?<!\*)\*\[[^\]\n]*\]\*(?!\*)")
BODY_HEADING_RE = re.compile(r"^(#{1,6}) +(\S.*)$")
PART_RE = re.compile(r"^PART\s+\d+\b")


def compute(path):
    text = open(path, encoding="utf-8").read()
    chars = len(text)
    lines_list = text.split("\n")
    lines = len(lines_list)

    page_markers = []
    for i, l in enumerate(lines_list):
        m = PAGE_MARKER_RE.match(l)
        if m:
            page_markers.append((i, int(m.group(1))))
    nums = [n for _, n in page_markers]
    if nums != list(range(1, len(nums) + 1)):
        raise ValueError("page markers not 1..N once each: %r" % (nums,))
    pages = len(nums)

    headings = sum(1 for l in lines_list if HEADING_LINE_RE.match(l))
    tables = sum(1 for l in lines_list if TABLE_SEP_RE.match(l))
    figures = len(FIGURE_RE.findall(text))

    body_start = page_markers[0][0] + 1 if page_markers else 0
    heads = []
    level_counts = {}
    for l in lines_list[body_start:]:
        m = BODY_HEADING_RE.match(l)
        if m:
            lvl = len(m.group(1))
            txt = m.group(2).strip()
            heads.append((lvl, txt))
            level_counts[lvl] = level_counts.get(lvl, 0) + 1
    qualifying = sorted(lvl for lvl, c in level_counts.items() if c >= 2)
    if qualifying:
        sec_level = qualifying[0]
    elif heads:
        sec_level = heads[0][0]
    else:
        sec_level = 1

    sections = sum(1 for lvl, _ in heads if lvl == sec_level)
    subsections = sum(1 for lvl, _ in heads if lvl == sec_level + 1)
    parts = sum(1 for lvl, txt in heads if lvl == sec_level and PART_RE.match(txt))

    return dict(chars=chars, lines=lines, pages=pages, headings=headings,
                tables=tables, figures=figures, sections=sections,
                subsections=subsections, parts=parts)


def main():
    json_path = sys.argv[1] if len(sys.argv) > 1 else ""
    parsed_docs = {}
    parse_error = None
    if json_path:
        try:
            with open(json_path, encoding="utf-8") as fh:
                data = json.load(fh)
            for d in data.get("docs", []):
                parsed_docs[d.get("slug")] = d
        except Exception as e:
            parse_error = "could not read/parse content-check --json capture: %s" % e
    else:
        parse_error = "no content-check --json capture available (see check 10 above)"

    overall_ok = True
    for slug, path in DOCS:
        try:
            py = compute(path)
        except Exception as e:
            print("FAIL %s recompute-error=%s" % (slug, e))
            overall_ok = False
            continue
        if parse_error is not None:
            print("FAIL %s %s" % (slug, parse_error))
            overall_ok = False
            continue
        cc = parsed_docs.get(slug)
        if cc is None:
            print("FAIL %s missing from content-check --json docs[]" % slug)
            overall_ok = False
            continue
        diffs = []
        for field in FIELDS:
            if cc.get(field) != py[field]:
                diffs.append("%s: content-check=%r python=%r" % (field, cc.get(field), py[field]))
        if diffs:
            print("FAIL %s " % slug + "; ".join(diffs))
            overall_ok = False
        else:
            print("OK %s " % slug + " ".join("%s=%s" % (f, py[f]) for f in FIELDS))

    sys.exit(0 if overall_ok else 1)


main()
PYEOF

  if command -v python3 >/dev/null 2>&1; then
    THREEWAY_OUT="$(cd "$REPO_ROOT" && python3 "$THREEWAY_PY" "$CONTENT_JSON_FILE" 2>&1)" || true
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        "OK "*)
          rest="${line#OK }"
          slug="${rest%% *}"
          detail="${rest#* }"
          ok "three-way content agreement/$slug ($detail)"
          ;;
        "FAIL "*)
          rest="${line#FAIL }"
          slug="${rest%% *}"
          detail="${rest#* }"
          fail "three-way content agreement/$slug (observed: $detail)"
          ;;
        *)
          fail "three-way content agreement (unexpected output: $line)"
          ;;
      esac
    done <<< "$THREEWAY_OUT"
  else
    for slug in guide-book startup-guide midi oss; do
      fail "three-way content agreement/$slug (observed: python3 not found on PATH)"
    done
  fi
  rm -f "$THREEWAY_PY"

  # -------------------------------------------------------------------------
  # Check 12 (NEW4, M1 gate round 3): EXACT-BYTES SOURCE INTEGRITY.
  #
  # Check 11 above is a STRUCTURAL fingerprint only: chars/lines/pages/
  # headings/tables/figures/sections/subsections/parts are all it compares,
  # so an equal-length, line-count-preserving prose edit (e.g. swapping one
  # five-character word for another of the same length) leaves every one of
  # those fields identical and a stale build sails straight through it.
  # This check instead diffs the ACTUAL embedded bytes: task
  # 'content-core-model' added `content-check --dump-source <slug>`, which
  # writes the exact embedded UTF-8 bytes for a document to stdout -- no
  # banner, no trailing newline of its own beyond whatever the source file
  # already ends with -- for exactly this purpose. Comparing that
  # byte-for-byte against translations/<slug>.md is strictly stronger than
  # any digest (a digest would only tell you THAT it changed; this doesn't
  # need to, because it IS the full comparison) and needs no cryptographic
  # code. Runs for all FIVE embedded documents, including glossary, which
  # checks 10/11 do not cover at all (content-check's stats/three-way
  # agreement only track the four manual documents). Inside the content
  # axis, like checks 10/11: --skip-content skips this too, and (NEW7,
  # check "Final" below) a skipped content axis can no longer silently
  # report result=complete.
  # -------------------------------------------------------------------------
  DUMP_SOURCE_SLUGS=(guide-book startup-guide midi oss glossary)
  if [ -n "$CONTENT_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    for slug in "${DUMP_SOURCE_SLUGS[@]}"; do
      DUMP_OUT="$(mktemp -t "sxc1-check-site-dump.XXXXXX")"
      register_temp_file "$DUMP_OUT"
      TRANSLATION_FILE="$REPO_ROOT/translations/$slug.md"
      if wasm-run.mjs "$CONTENT_CHECK_BIN" --dump-source "$slug" >"$DUMP_OUT" 2>/dev/null \
         && [ -f "$TRANSLATION_FILE" ] && cmp -s "$DUMP_OUT" "$TRANSLATION_FILE"; then
        ok "exact-bytes source integrity/$slug (content-check --dump-source $slug is byte-identical to translations/$slug.md)"
      else
        fail "exact-bytes source integrity/$slug (observed: content-check --dump-source $slug diverges from translations/$slug.md -- stale build or a translation edited without rebuilding)"
      fi
      rm -f "$DUMP_OUT"
    done
  else
    for slug in "${DUMP_SOURCE_SLUGS[@]}"; do
      fail "exact-bytes source integrity/$slug (observed: toolchain env or exe:content-check binary unavailable -- see checks above)"
    done
  fi
fi

# ===========================================================================
# Checks 7 & 8: headless-Chrome smoke test at the root, and (authoritative)
# at a non-root GitHub-Pages-style sub-path, unless skipped.
# ===========================================================================
port_in_use() {
  local port="$1"
  if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    return 0
  fi
  return 1
}

wait_for_port() {
  local port="$1" timeout_s="${2:-15}"
  local deadline=$(( $(date +%s) + timeout_s ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if port_in_use "$port"; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

resolve_browser() {
  if [ -n "${SXC1_BROWSER:-}" ]; then
    printf '%s' "$SXC1_BROWSER"
    return 0
  fi
  local cand
  for cand in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$cand" >/dev/null 2>&1; then
      command -v "$cand"
      return 0
    fi
  done
  return 1
}

# m1 fix: after starting a server, prove it is actually OUR server before
# trusting it -- confirm the child process is still alive and that
# fetching /index.html from it byte-matches the on-disk file we intend to
# serve. wait_for_port() alone only proves SOMEBODY is listening on that
# port (TOCTOU: it could be an unrelated service that raced us to it).
verify_server_healthy() {
  local pid="$1" port="$2" url_path="$3" on_disk_file="$4"

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "check-site: dev server process (pid $pid) exited before it could be verified" >&2
    return 1
  fi

  local fetched url disk_sum fetched_sum
  fetched="$(mktemp)"
  url="http://127.0.0.1:${port}${url_path}"
  if ! curl -fsS --max-time 5 "$url" -o "$fetched" 2>/dev/null; then
    echo "check-site: could not fetch $url" >&2
    rm -f "$fetched"
    return 1
  fi
  disk_sum="$(sha256sum "$on_disk_file" | awk '{print $1}')"
  fetched_sum="$(sha256sum "$fetched" | awk '{print $1}')"
  rm -f "$fetched"
  if [ "$disk_sum" != "$fetched_sum" ]; then
    echo "check-site: content served at $url does not byte-match $on_disk_file" >&2
    return 1
  fi
  return 0
}

# Start scripts/serve-site.sh over `serve_dir`, beginning port probing at
# `start_port`. On success, sets START_SERVER_PORT and START_SERVER_PID and
# returns 0; on failure to come up at all, returns 1 (no ok/fail reported
# here -- the caller reports one check per stage).
START_SERVER_PORT=""
START_SERVER_PID=""
start_server() {
  local serve_dir="$1" start_port="$2"
  local chosen_port="$start_port" attempts=0
  while port_in_use "$chosen_port" && [ "$attempts" -lt 50 ]; do
    chosen_port=$((chosen_port + 1))
    attempts=$((attempts + 1))
  done

  local log
  log="$(mktemp -t sxc1-check-site-server.XXXXXX)"
  SERVER_LOGS+=("$log")

  "$REPO_ROOT/scripts/serve-site.sh" --dir "$serve_dir" --port "$chosen_port" >"$log" 2>&1 &
  local pid=$!
  SERVER_PIDS+=("$pid")

  if ! wait_for_port "$chosen_port" 15; then
    echo "check-site: dev server did not come up on port $chosen_port within 15s (see $log)" >&2
    return 1
  fi

  START_SERVER_PORT="$chosen_port"
  START_SERVER_PID="$pid"
  return 0
}

# Run one "stage": start a server over `serve_dir`, verify it is healthy
# (m1), then run scripts/browser-check.mjs against `url_path` on it and
# report exactly two named checks: "$health_label" and "$browser_label".
run_browser_stage() {
  local serve_dir="$1" on_disk_index="$2" url_path="$3" health_label="$4" browser_label="$5" browser_path="$6"

  if ! start_server "$serve_dir" "$PORT"; then
    fail "$health_label"
    fail "$browser_label (observed: dev server never came up)"
    return
  fi

  if verify_server_healthy "$START_SERVER_PID" "$START_SERVER_PORT" "$url_path" "$on_disk_index"; then
    ok "$health_label"
  else
    fail "$health_label"
    fail "$browser_label (observed: dev server did not verify healthy, browser check not run)"
    return
  fi

  local run_url="http://127.0.0.1:${START_SERVER_PORT}${url_path}"
  # Check 11 fix: hand the SAME content-check --json capture to the browser
  # driver via --expect-json, so #sxc1-content-stats is compared against
  # numbers derived from the source of truth (translations/*.md) rather
  # than the golden constants baked into browser-check.mjs. Falls back to
  # those built-in constants (no --expect-json) when --skip-content was
  # passed or check 10/11 could not produce a JSON capture.
  #
  # --timeout override (M1 gate round 3 harness fix): this governs ONE
  # browser-check.mjs invocation -- one call to run_browser_stage(), i.e.
  # either check 7's root run or check 8's authoritative sub-path run, each
  # gets its own fresh budget, not a shared one. browser-check.mjs's own
  # default is 45000ms (sized back when the only real work was M0's single
  # counter page). M1's round-3 gate additions -- the exhaustive 108-page
  # /ja image-decode sweep (NEW6) plus a genuinely cold second CDP target
  # for the deep-link check (NEW5) -- made that default too tight under
  # load: on this project's 4-core development machine, a busy run was
  # observed to exhaust the 45s budget mid-sweep (one stage reported "cold
  # target failed to boot", an unrelated sub-path stage exited 2 in the
  # same run) and pass cleanly on an otherwise-idle re-run with nothing
  # else changed -- i.e. budget starvation masquerading as a real failure,
  # exactly the class of check this whole gate round exists to eliminate.
  # check-site.sh therefore overrides the default explicitly with real
  # headroom: 120000ms (120s) per stage. That is comfortably above the
  # sweep's measured cost (the 108-route pass itself takes low single-digit
  # seconds; decoding the ~9.4MB image set adds more but nowhere near a
  # minute) even several times over on a loaded CI runner, while a genuine
  # hang (dead CDP peer, boot that never completes) still fails -- just at
  # 120s instead of 45s, not never.
  local -a browser_cmd=("$REPO_ROOT/scripts/browser-check.mjs" --url "$run_url" --timeout 120000)
  if [ -n "${CONTENT_JSON_FILE:-}" ] && [ -s "$CONTENT_JSON_FILE" ]; then
    browser_cmd+=(--expect-json "$CONTENT_JSON_FILE")
  fi
  echo "check-site: serving '$serve_dir' at $run_url (browser: $browser_path)"
  set +e
  "$NODE" "${browser_cmd[@]}"
  local browser_rc=$?
  set -e
  if [ "$browser_rc" -eq 0 ]; then
    ok "$browser_label"
  else
    fail "$browser_label (scripts/browser-check.mjs exit $browser_rc)"
  fi
}

ROOT_HEALTH_LABEL="root dev server serves the on-disk index.html byte-for-byte"
ROOT_BROWSER_LABEL="browser check at the origin root (http://127.0.0.1:<port>/)"
SUBPATH_HEALTH_LABEL="sub-path dev server serves the on-disk index.html byte-for-byte"
SUBPATH_BROWSER_LABEL="browser check at a GitHub-Pages-style sub-path (AUTHORITATIVE deployability check)"

if [ "$SKIP_BROWSER" -eq 1 ]; then
  echo "SKIPPED -- browser checks (requested via --skip-browser or SXC1_SKIP_BROWSER=1)"
  skip "$ROOT_HEALTH_LABEL"
  skip "$ROOT_BROWSER_LABEL"
  skip "$SUBPATH_HEALTH_LABEL"
  skip "$SUBPATH_BROWSER_LABEL"
else
  if ! BROWSER_PATH="$(resolve_browser)"; then
    fail "$ROOT_HEALTH_LABEL (observed: no browser found -- set SXC1_BROWSER, install Chrome/Chromium, or pass --skip-browser)"
    fail "$ROOT_BROWSER_LABEL"
    fail "$SUBPATH_HEALTH_LABEL (observed: no browser found -- set SXC1_BROWSER, install Chrome/Chromium, or pass --skip-browser)"
    fail "$SUBPATH_BROWSER_LABEL"
  else
    # Check 7: ordinary root-served smoke test.
    run_browser_stage "$DIR" "$DIR/index.html" "/" "$ROOT_HEALTH_LABEL" "$ROOT_BROWSER_LABEL" "$BROWSER_PATH"

    # Check 8 (M9 fix): copy the bundle under a non-root prefix and require
    # the browser check to pass THERE. This is the property test for GitHub
    # Pages project-subpath deployability; unlike the check-5 grep it
    # cannot be evaded by quoting style, template literals, url(/...),
    # new URL('/...') or protocol-relative //host -- it actually loads the
    # bundle from a path where a hardcoded "/app.wasm" resolves to nothing.
    SUBPATH_TMP="$(mktemp -d -t sxc1-check-site-subpath.XXXXXX)"
    register_temp_dir "$SUBPATH_TMP"
    SUBPATH_DIR="$SUBPATH_TMP/sub/path"
    mkdir -p "$SUBPATH_DIR"
    cp -R "$DIR"/. "$SUBPATH_DIR"/
    run_browser_stage "$SUBPATH_TMP" "$SUBPATH_DIR/index.html" "/sub/path/" "$SUBPATH_HEALTH_LABEL" "$SUBPATH_BROWSER_LABEL" "$BROWSER_PATH"
    rm -rf "$SUBPATH_TMP"
    unregister_temp_dir "$SUBPATH_TMP"
  fi
fi

# ===========================================================================
# Final: summary + machine-readable result marker.
#
# m2 fix, WIDENED by NEW7 (M1 gate round 3 -- this is an M0 REGRESSION
# fix, not a new feature): a skipped axis is counted in the total (as
# SKIPPED, not PASS) so "N/N checks passed" can never be printed for a run
# that did not exercise everything -- and the result= marker below lets a
# caller that only records this one line (as CI does) tell a full gate
# from a partial run apart, without having to parse the fraction.
#
# The original m2 fix keyed the marker off SKIP_BROWSER alone, which was
# the whole truth as long as --skip-browser was the only skippable axis.
# M1 then added --skip-content (checks 10/11/12) without widening the
# marker, so `SXC1_SKIP_CONTENT=1 ./scripts/check-site.sh` could print
# result=complete while the content checker, three-way agreement and
# exact-bytes source-integrity checks all silently never ran -- exactly
# the kind of can't-fail check this whole gate round exists to eliminate,
# and a real regression of a guarantee this comment used to describe as
# already won. The rule is now keyed off the SKIPPED counter itself, which
# every skippable axis already increments via skip(): result=complete iff
# SKIPPED is exactly 0, regardless of how many axes exist or which flag(s)
# skipped them. A future third skippable axis is therefore covered for
# free, as long as it reports through skip() like the first two do. CI
# additionally asserts SKIPPED is 0 directly (not just the marker) so a
# hypothetical bug in this very condition cannot self-certify -- see
# .github/workflows/site.yml.
# ===========================================================================
if [ "$SKIPPED" -gt 0 ]; then
  echo "check-site: ${PASS}/${TOTAL} checks passed (${SKIPPED} skipped)"
else
  echo "check-site: ${PASS}/${TOTAL} checks passed"
fi

if [ "$SKIPPED" -gt 0 ]; then
  echo "check-site: result=structural-only"
else
  echo "check-site: result=complete"
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
exit 0
