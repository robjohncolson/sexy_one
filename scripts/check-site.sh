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
                   run, the three-way content agreement check, the
                   exact-bytes source-integrity check, AND (M2) the
                   exe:exercise-check gate, the independent Python
                   re-derivation of exercise stats/citations, and the
                   fixture run + coverage invariant (also honoured via
                   SXC1_SKIP_CONTENT=1). M2's exercise checks live on this
                   SAME content axis -- no new skip flag was added; see
                   "Checks performed, in order" below (14-17). Local-
                   iteration escape hatch only -- never the default, and CI
                   must not pass it. Like --skip-browser, this also flips
                   the final marker to result=structural-only (NEW7: both
                   skippable axes now drive the same marker, via the
                   SKIPPED counter, so neither can silently report
                   result=complete). When skipped, checks 7/8's browser run
                   falls back to scripts/browser-check.mjs's own built-in
                   golden numbers instead of --expect-json, and runs
                   without --expect-exercise-json/--exercise-fixture (the
                   M2 exercise-engine browser assertions simply do not run
                   in that case -- see check 17 below).
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
  14. THE CLOCK/M4-STUB INVARIANT (unconditional, not on the content axis):
     site/app must use the real wall-clock and monotonic-clock mechanisms
     (GHC.Clock.getMonotonicTimeNSec and JS Date.getTime -- NOT
     Data.Time.Clock.POSIX, which does not build for this target) and
     must wire the M4 DeviceVerifier stub (noDeviceVerifier), all THREE
     on lines that are not Haskell comments. This replaces a vacuous
     sibling check (task "exercise-ui"'s own
     `grep -RqE "getPOSIXTime|POSIX"`, which only ever matches the
     Haddock comment explaining why POSIX is NOT used -- the M0-n2
     pattern) with one anchored to the real, non-comment code.
  15. EXERCISE VALIDATOR GATE (content axis): exe:exercise-check, resolved
     and run exactly like exe:content-check (checks 10-12) -- same
     toolchain env, same `wasm32-wasi-cabal list-bin` / wasm-run.mjs
     convention -- against the REAL content/translations roots with
     --content-dir/--translations-dir/--json, requiring the run to exit 0
     AND the captured JSON's "ok" field to be true (issues, if any, are
     printed). Unless --skip-content.
  16. INDEPENDENT PYTHON RE-DERIVATION (content axis): a from-scratch
     Python re-implementation recomputes, straight from
     content/exercises/*.ex.md and content/exercises/INDEX (never from
     the Haskell): the deck list (both directions against the directory),
     exercise/prompt/per-kind/citation counts, and per-deck chars/lines/
     FNV-1a-32 -- pinned against the published FNV-1a test vectors before
     trusting anything else -- and diffs all of it against check 15's
     captured JSON. It then RE-RESOLVES EVERY CITATION INDEPENDENTLY
     straight from translations/*.md (split on <!-- page N --> markers,
     page-range check, whitespace-collapsed anchor substring check) --
     two independent implementations of the citation check, because that
     check is the claim the whole content model rests on. Unless
     --skip-content.
  17. FIXTURE RUN, COVERAGE INVARIANT, AND STALE-BUILD DETECTION (content
     axis): exe:exercise-check --fixtures content/fixtures must exit 0;
     every code exe:exercise-check --list-codes prints (file/dir class)
     must have >=1 matching fixture under fixtures/files or fixtures/dirs
     (a validation rule with no fixture turns this red), the seam class
     is asserted to contain EXACTLY ONE code (E-BLOCK-UNPARSED -- the one
     code provably unreachable from any real file, demonstrated instead
     by exe:exercise-check --self-test), and the fixtures' own
     filename-declared verdicts are independently re-derived in Python
     and diffed against --fixtures --json. Finally, the SAME disk-derived
     stats from check 16 are handed to checks 7/8's
     scripts/browser-check.mjs as --expect-exercise-json, and
     exe:exercise-check --browser-fixture's output as --exercise-fixture
     -- comparing what is ACTUALLY EMBEDDED in the running app.wasm
     (#sxc1-exercise-stats) against what is on disk right now. This is
     M2's equivalent of check 12's `content-check --dump-source`
     exact-bytes comparison, but that trick cannot be reused here:
     --dump-source reads bytes the Haskell compiler already embedded,
     whereas exe:exercise-check only ever reads content/exercises/ off
     DISK (it has no view into what site/app/Exercises/Embed.hs's
     hand-written, per-file TH splices actually shipped) -- so a
     forgotten rebuild, OR a new deck added on disk but never given its
     own named splice in Embed.hs, shows up as a RED check instead of a
     silently stale site. The per-deck FNV-1a is what makes this
     byte-sensitive, not merely length-sensitive. Unless --skip-content.

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
# Check 14 (M2, task "verification", designer size-budget ruling condition
# A): THE CLOCK/M4-STUB INVARIANT, unconditional -- not on the content axis,
# never skipped, because it is a pure source-tree scan with no toolchain
# dependency.
#
# task "exercise-ui" ships its own verify command:
#   grep -RqE "getMonotonicTimeNSec" site/app \
#     && grep -RqE "getPOSIXTime|POSIX" site/app \
#     && grep -RqE "noDeviceVerifier" site/app
# The middle clause is VACUOUS: site/app/Main.hs does NOT use
# Data.Time.Clock.POSIX at all (it cannot -- that module does not build
# for wasm32-wasi here) and says so in a Haddock comment ("Wall-clock
# epoch: NOT 'Data.Time.Clock.POSIX' -- ... 'Date.getTime' gives the same
# ... value 'Data.Time.Clock.POSIX.getPOSIXTime' would have"). That
# comment is exactly what the grep matches -- the real wall-clock
# mechanism, JS's Date.getTime via the app's own FFI, is never actually
# required to be present. This is the M0-n2 pattern: a grep satisfied by
# a comment describing what ISN'T used, not by the code that IS.
#
# This check requires all three of getMonotonicTimeNSec, Date.getTime and
# noDeviceVerifier on lines that are NOT Haskell comments, using a small
# python3 pass (naive "split each line on its first '--'" line-comment
# strip -- sufficient here because none of these three identifiers ever
# appears after a literal '--' inside a string literal in this codebase;
# a block ({- -}) comment is not specially handled either, for the same
# reason: none of the three occurs inside one).
# ===========================================================================
CLOCK_STUB_PY="$(mktemp -t sxc1-check-site-clockstub.XXXXXX.py)"
register_temp_file "$CLOCK_STUB_PY"
cat > "$CLOCK_STUB_PY" <<'PYEOF'
import os
import sys

TARGETS = ["getMonotonicTimeNSec", "Date.getTime", "noDeviceVerifier"]
ROOT = sys.argv[1]

found = {t: False for t in TARGETS}
for dirpath, _dirnames, filenames in os.walk(ROOT):
    for fn in filenames:
        if not fn.endswith(".hs"):
            continue
        path = os.path.join(dirpath, fn)
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                code_part = line.split("--", 1)[0]
                if not code_part.strip():
                    continue
                for t in TARGETS:
                    if t in code_part:
                        found[t] = True

missing = [t for t in TARGETS if not found[t]]
if missing:
    print("FAIL missing on non-comment lines under %s: %s" % (ROOT, ", ".join(missing)))
    sys.exit(1)
print("OK all three real mechanisms present on non-comment .hs lines under %s: %s" % (ROOT, ", ".join(TARGETS)))
sys.exit(0)
PYEOF

if command -v python3 >/dev/null 2>&1; then
  # DIR is the built site/public directory (or whatever --dir names),
  # which is not the source tree -- the real target is the checked-out
  # site/app directory, addressed via REPO_ROOT so this works regardless
  # of --dir. `|| true`: a FAIL exits 1, which must not trip `set -e`
  # here -- the case dispatch below is what decides ok()/fail().
  CLOCK_STUB_OUT="$(python3 "$CLOCK_STUB_PY" "$REPO_ROOT/site/app" 2>&1)" || true
  case "$CLOCK_STUB_OUT" in
    "OK "*)
      ok "clocks and the M4 stub are wired on non-comment lines (getMonotonicTimeNSec, Date.getTime, noDeviceVerifier) (${CLOCK_STUB_OUT#OK })"
      ;;
    *)
      fail "clocks and the M4 stub are wired on non-comment lines (getMonotonicTimeNSec, Date.getTime, noDeviceVerifier) (observed: ${CLOCK_STUB_OUT#FAIL })"
      ;;
  esac
else
  fail "clocks and the M4 stub are wired on non-comment lines (getMonotonicTimeNSec, Date.getTime, noDeviceVerifier) (observed: python3 not found on PATH)"
fi
rm -f "$CLOCK_STUB_PY"

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
  # M2 (task "verification"): the exercise-validator gate, its
  # independent Python re-derivation, and the fixture/coverage invariant
  # all live on this SAME content axis -- no new skip flag (see the
  # module comment above checks 15-17 in usage()).
  skip "exe:exercise-check binary resolved"
  skip "exercise-check runs under wasm-run.mjs and exits 0 (--content-dir/--translations-dir --json)"
  skip "exercise validator reports zero issues over real content (exercise-check --json ok:true)"
  skip "exercise-stats/fnv1a-vectors (FNV-1a/32 pinned against published test vectors)"
  skip "exercise-stats/index-directory-agreement (content/exercises/INDEX vs directory, both directions)"
  skip "exercise-stats/totals-agreement (python re-derivation vs exercise-check --json totals)"
  skip "exercise-stats/per-deck-agreement (chapter/title/exercises/prompts/sourceChars)"
  skip "exercise-stats/citation-count-agreement (^cite:/^find: line count vs exercise-check --json)"
  skip "exercise-stats/citation-independent-resolution (page range + anchor re-checked from translations/*.md)"
  skip "disk-derived exercise stats computed for browser-check.mjs --expect-exercise-json (python re-derivation from content/exercises/, never from the app payload)"
  skip "exercise-check --browser-fixture produced JSON for browser-check.mjs --exercise-fixture"
  skip "exercise-check --fixtures content/fixtures exits 0 (the falsifiability corpus)"
  skip "fixture coverage invariant: every file/dir code from --list-codes has >=1 fixture"
  skip "seam-class coverage cap: exactly one seam-class code, E-BLOCK-UNPARSED"
  skip "independent verdict re-derivation from fixture filenames matches --fixtures --json"
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

  # =========================================================================
  # Checks 15-17 (M2, task "verification"): the exercise validator gate,
  # its independent Python re-derivation, the fixture run + coverage
  # invariant, and the stale-build/browser handoff. See usage() above for
  # the full description. Same content axis, same toolchain-env/
  # wasm-run.mjs convention as checks 10-12 above; --content-dir and
  # --translations-dir are always passed ABSOLUTE (never the binary's own
  # relative defaults, which assume a `site/` cwd) because
  # content/exercise-inventory.md is read from a FIXED, non-overridable
  # path ("../content/exercise-inventory.md", see
  # site/test/CheckExercises.hs's Haddock) -- every invocation below is
  # therefore wrapped in a subshell `cd`d to site/ so that fixed path
  # still resolves correctly regardless of check-site.sh's own cwd.
  # =========================================================================
  EXERCISE_CHECK_BIN=""
  if command -v wasm32-wasi-cabal >/dev/null 2>&1; then
    EXERCISE_CHECK_BIN="$(cd "$REPO_ROOT/site" && wasm32-wasi-cabal list-bin exe:exercise-check 2>/dev/null | tail -n1 || true)"
  fi

  if [ -n "$EXERCISE_CHECK_BIN" ] && [ -f "$EXERCISE_CHECK_BIN" ]; then
    ok "exe:exercise-check binary resolved (observed: $EXERCISE_CHECK_BIN)"
  else
    fail "exe:exercise-check binary resolved (observed: missing -- run ./scripts/build-site.sh first; fallback runner: wasmtime run --dir=/ <binary>)"
    EXERCISE_CHECK_BIN=""
  fi

  # terminology-rules.tsv (content/terminology-rules.tsv) is loaded by
  # exercise-check itself from --content-dir on every mode below -- this
  # is what grounds every E-TERM.<rule_id> code checks 15-17 exercise.
  EXERCISE_CHECK_ARGS=(--content-dir "$REPO_ROOT/content" --translations-dir "$REPO_ROOT/translations")
  run_exercise_check() {
    ( cd "$REPO_ROOT/site" && wasm-run.mjs "$EXERCISE_CHECK_BIN" "$@" )
  }

  # -------------------------------------------------------------------------
  # Check 15: EXERCISE VALIDATOR GATE. Run under wasm-run.mjs with --json
  # against the REAL content/translations roots; --json mode's own process
  # exit code is always 0 by design (it is meant for machine consumption,
  # see runJsonMode in site/test/CheckExercises.hs), so the actual gate is
  # the captured JSON's "ok" field, not the process exit code alone -- a
  # dangling/out-of-range citation appended to a real deck (this task's
  # negative control (a)) trips THIS check.
  # -------------------------------------------------------------------------
  EXERCISE_JSON_FILE=""
  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    CANDIDATE_EX_JSON="$(mktemp -t sxc1-check-site-exstats.XXXXXX.json)"
    register_temp_file "$CANDIDATE_EX_JSON"
    if run_exercise_check "${EXERCISE_CHECK_ARGS[@]}" --json >"$CANDIDATE_EX_JSON" 2>/dev/null && [ -s "$CANDIDATE_EX_JSON" ]; then
      ok "exercise-check runs under wasm-run.mjs and exits 0 (--content-dir/--translations-dir --json)"
      EXERCISE_JSON_FILE="$CANDIDATE_EX_JSON"
    else
      fail "exercise-check runs under wasm-run.mjs and exits 0 (--content-dir/--translations-dir --json) (observed: non-zero exit or empty output)"
    fi
  else
    fail "exercise-check runs under wasm-run.mjs and exits 0 (--content-dir/--translations-dir --json) (observed: toolchain env or binary unavailable -- see checks above; fallback runner: wasmtime run --dir=/ <binary>)"
  fi

  if [ -n "$EXERCISE_JSON_FILE" ] && command -v python3 >/dev/null 2>&1; then
    EX_OK_OUT="$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
if data.get("ok") is True and not data.get("issues"):
    print("OK exercise-check --json ok:true, 0 issues")
else:
    issues = data.get("issues", [])
    lines = ["%s:%s: %s  %s" % (i.get("file"), i.get("line"), i.get("code"), i.get("detail")) for i in issues]
    print("FAIL " + ("; ".join(lines) if lines else "\"ok\" field was not true"))
' "$EXERCISE_JSON_FILE" 2>&1)" || true
    case "$EX_OK_OUT" in
      "OK "*) ok "exercise validator reports zero issues over real content (exercise-check --json ok:true) (${EX_OK_OUT#OK })" ;;
      *)      fail "exercise validator reports zero issues over real content (exercise-check --json ok:true) (observed: ${EX_OK_OUT#FAIL })" ;;
    esac
  else
    fail "exercise validator reports zero issues over real content (exercise-check --json ok:true) (observed: no JSON capture available or python3 missing)"
  fi

  # -------------------------------------------------------------------------
  # Check 16: INDEPENDENT PYTHON RE-DERIVATION. One script, two modes:
  # "diff" recomputes everything straight from content/exercises/ and
  # translations/ and diffs it against check 15's captured JSON (item B);
  # "emit" prints the same disk-derived numbers as the exact JSON shape
  # scripts/browser-check.mjs's --expect-exercise-json expects (item D,
  # below) -- ONE implementation shared by both uses, so item D's
  # "the expected deck list comes from disk, never from the app payload"
  # property and item B's independent re-derivation are the same code
  # path, not two that could quietly drift apart.
  # -------------------------------------------------------------------------
  EXERCISE_STATS_PY="$(mktemp -t sxc1-check-site-exstats.XXXXXX.py)"
  register_temp_file "$EXERCISE_STATS_PY"
  cat > "$EXERCISE_STATS_PY" <<'PYEOF'
import json
import os
import re
import sys

MODE = sys.argv[1]
CONTENT_DIR = sys.argv[2]
TRANSLATIONS_DIR = sys.argv[3]

FNV_OFFSET = 2166136261
FNV_PRIME = 16777619
MASK32 = 0xFFFFFFFF


def fnv1a32(data):
    h = FNV_OFFSET
    for b in data:
        h ^= b
        h = (h * FNV_PRIME) & MASK32
    return h


# Pinned against the published test vectors (briefs/M2-plan-amendments.md
# sec. 4) BEFORE trusting any comparison that depends on this function --
# the last vector proves this operates on UTF-8 BYTES, not code points.
VECTORS = [
    (b"", 2166136261),
    (b"hello", 1335831723),
    (b"SELECT BANK 1", 1835518890),
    ("⊕⊖".encode("utf-8"), 3369799694),
]


def check_vectors():
    for data, want in VECTORS:
        got = fnv1a32(data)
        if got != want:
            return "FNV-1a(%r) = %d, want %d" % (data, got, want)
    return None


def heading_of(line):
    # Mirrors SXC1.Content.Markdown.headingLineOf exactly: 1-6 leading
    # '#', then a single space, then non-empty (after stripping) text.
    i = 0
    n = len(line)
    while i < n and line[i] == "#":
        i += 1
    if i < 1 or i > 6:
        return None
    rest = line[i:]
    if not rest.startswith(" "):
        return None
    txt = rest.strip()
    if not txt:
        return None
    return i, txt


def heading_level(line):
    h = heading_of(line)
    return h[0] if h else None


def field_kv(line):
    # Mirrors SXC1.Exercise.Parse.fieldKeyValueOf: key is
    # [a-z][a-z0-9-]*, value is the text after ':' with AT MOST ONE
    # leading space dropped (not fully stripped -- dkChapter keeps
    # whatever is left, exactly like the real flValue).
    m = re.match(r"^([a-z][a-z0-9-]*):(.*)$", line)
    if not m:
        return None
    key, rest = m.group(1), m.group(2)
    if rest.startswith(" "):
        rest = rest[1:]
    return key, rest


EXERCISES_DIR = os.path.join(CONTENT_DIR, "exercises")
INDEX_PATH = os.path.join(EXERCISES_DIR, "INDEX")


def parse_index(path):
    out = []
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.append(s)
    return out


TRANSLATION_FILES = {
    "guide-book": "guide-book.md",
    "startup-guide": "startup-guide.md",
    "midi": "midi.md",
    "oss": "oss.md",
}

_page_cache = {}


def pages_for(slug):
    # Independent re-implementation of splitPageTexts + normalizeWs
    # (SXC1.Content.Markdown / SXC1.Exercise.Verify): split on
    # "<!-- page N -->" marker lines, collapse whitespace runs to one
    # space per page body -- straight from translations/*.md, no
    # reference to the Haskell.
    if slug in _page_cache:
        return _page_cache[slug]
    fn = TRANSLATION_FILES.get(slug)
    if fn is None:
        _page_cache[slug] = None
        return None
    path = os.path.join(TRANSLATIONS_DIR, fn)
    if not os.path.isfile(path):
        _page_cache[slug] = None
        return None
    text = open(path, encoding="utf-8").read()
    lines = text.split("\n")
    markers = []
    for i, l in enumerate(lines):
        m = re.match(r"^<!-- page (\d+) -->$", l)
        if m:
            markers.append((i, int(m.group(1))))
    pages = {}
    for idx, (i, num) in enumerate(markers):
        j = markers[idx + 1][0] if idx + 1 < len(markers) else len(lines)
        body = "\n".join(lines[i + 1:j])
        pages[num] = " ".join(body.split())
    _page_cache[slug] = pages
    return pages


# Deliberately NOT anchored to "immediately after a heading" (unlike the
# real grammar's scanFieldBlock) -- this is a blunter, broader net over
# every line in the file that LOOKS like a citation, on purpose: it is
# what catches a stray cite:/find: line appended anywhere in a file
# (this task's negative control (a)), which the real parser would not
# even attempt to resolve as a field outside a field block.
CITE_RE = re.compile(r'^(cite|find): (\S+) (\d+) "(.*)"\s*$')


def load_decks():
    index_entries = parse_index(INDEX_PATH)
    on_disk = set(f for f in os.listdir(EXERCISES_DIR) if f.endswith(".ex.md"))
    index_set = set(index_entries)
    orphan = sorted(on_disk - index_set)
    dangling = sorted(index_set - on_disk)

    deck_files = [f for f in index_entries if f in on_disk]

    decks = []
    totals = {"exercises": 0, "prompts": 0, "quiz": 0, "drill": 0, "lookup": 0}
    citation_total = 0
    citation_failures = []
    resolved_count = 0

    for fname in deck_files:
        path = os.path.join(EXERCISES_DIR, fname)
        text = open(path, encoding="utf-8").read()
        raw_bytes = open(path, "rb").read()
        chars = len(text)
        lines_list = text.split("\n")
        n_lines = len(lines_list)
        fnv = fnv1a32(raw_bytes)

        title = ""
        for l in lines_list:
            if l.strip() == "":
                continue
            h = heading_of(l)
            if h and h[0] == 1:
                title = h[1]
            break

        deck_name = ""
        chapter = ""
        for l in lines_list:
            kv = field_kv(l)
            if not kv:
                continue
            k, v = kv
            if k == "deck" and not deck_name:
                deck_name = v.strip()
            elif k == "chapter" and not chapter:
                chapter = v

        ex_idx = [i for i, l in enumerate(lines_list) if heading_level(l) == 2]
        ex_count = len(ex_idx)
        quiz_count = sum(1 for l in lines_list if l == "type: quiz")
        drill_count = sum(1 for l in lines_list if l == "type: drill")
        lookup_count = sum(1 for l in lines_list if l == "type: lookup")

        # The deck's OWN cite: line(s) (dkCites -- required, repeatable),
        # in its field block before the first "## " exercise heading.
        # Counted once each toward citation_total, same as exCites below.
        deck_preamble = lines_list[:ex_idx[0]] if ex_idx else lines_list
        citation_total += sum(1 for l in deck_preamble if l.startswith("cite: "))

        prompts = 0
        for k, start in enumerate(ex_idx):
            end = ex_idx[k + 1] if k + 1 < len(ex_idx) else len(lines_list)
            span = lines_list[start:end]
            kind = None
            for l in span:
                kv = field_kv(l)
                if kv and kv[0] == "type":
                    kind = kv[1].strip()
                    break

            # Split the span on its own level-3 (### role) headings, so an
            # exercise-level cite: (in the preamble, before any role) can be
            # told apart from a drill step's OWN cite: (inside its "### Step"
            # chunk). Mirrors SXC1.Exercise.Report.buildTotals's real
            # formula (verified empirically against exercise-check --json
            # on the real seed content, briefs/M2-plan-amendments.md-style):
            # a quiz/lookup's single Prompt carries the SAME Citation list
            # as its Exercise (site/src/SXC1/Exercise/Parse.hs's
            # `theExCites`, at both `exCites` and, for quiz/lookup,
            # `prCites`) -- so totCitations counts a quiz's own cite: line
            # TWICE (once as exCites, once via its prompt's prCites) and a
            # lookup's find: line ZERO times (it lives only in the prompt's
            # FindPage payload, which totCitations never visits at all) --
            # while a drill's exercise-level cite: is counted once (exCites)
            # and each step's own cite: is counted once per step (prCites),
            # with no duplication. This is what agreement with A actually
            # requires; the raw ^cite:/^find: LINE SCAN just below (used for
            # independent citation RESOLUTION, not this count) stays
            # deliberately blind to this scoping -- see its own comment.
            role_idx = [i for i, l in enumerate(span) if heading_level(l) == 3]
            preamble = span[:role_idx[0]] if role_idx else span
            ex_cite_count = sum(1 for l in preamble if l.startswith("cite: "))
            step_cite_counts = []
            for ri, rstart in enumerate(role_idx):
                rend = role_idx[ri + 1] if ri + 1 < len(role_idx) else len(span)
                rh = heading_of(span[rstart])
                if rh and rh[1] == "Step":
                    step_cite_counts.append(sum(1 for l in span[rstart:rend] if l.startswith("cite: ")))

            if kind == "drill":
                prompts += len(step_cite_counts)
                citation_total += ex_cite_count + sum(step_cite_counts)
            else:
                prompts += 1
                # quiz: exCites + prCites duplicate = 2x. lookup: same
                # formula, but ex_cite_count is normally 0 (lookups use
                # find:, not cite:, at exercise level) and find: itself is
                # never counted (see the comment above).
                citation_total += 2 * ex_cite_count

        for l in lines_list:
            if not (l.startswith("cite: ") or l.startswith("find: ")):
                continue
            resolved_count += 1
            m = CITE_RE.match(l)
            if not m:
                citation_failures.append("%s: malformed cite/find line: %r" % (fname, l))
                continue
            _kind_word, slug, page_s, anchor = m.groups()
            page = int(page_s)
            pages = pages_for(slug)
            if pages is None:
                citation_failures.append("%s: unknown slug %r (%r)" % (fname, slug, l))
                continue
            if page not in pages:
                citation_failures.append("%s: page %d out of range for %s (%r)" % (fname, page, slug, l))
                continue
            if len(anchor.strip()) < 12:
                citation_failures.append("%s: anchor under 12 chars (%r)" % (fname, l))
                continue
            anchor_norm = " ".join(anchor.split())
            if anchor_norm not in pages[page]:
                citation_failures.append("%s: anchor not found on %s p.%d (%r)" % (fname, slug, page, anchor))

        totals["exercises"] += ex_count
        totals["prompts"] += prompts
        totals["quiz"] += quiz_count
        totals["drill"] += drill_count
        totals["lookup"] += lookup_count

        decks.append({
            "file": fname, "deck": deck_name, "chapter": chapter, "title": title,
            "exercises": ex_count, "prompts": prompts,
            "chars": chars, "lines": n_lines, "fnv1a": fnv,
        })

    totals["decks"] = len(decks)
    return {
        "orphan": orphan, "dangling": dangling,
        "decks": decks, "totals": totals,
        "citation_total": citation_total, "citation_failures": citation_failures,
        "resolved_count": resolved_count,
    }


def main():
    # "emit" mode's stdout IS the --expect-exercise-json payload
    # (check-site.sh writes it verbatim to a file) -- it must be the JSON
    # and NOTHING ELSE, so the diagnostic OK/FAIL lines below are only
    # printed in "diff" mode. A vector or index/directory failure in
    # "emit" mode goes to stderr and exits 1 (empty/no valid stdout),
    # which check 17's D1 dispatches as a FAIL on its own.
    vec_err = check_vectors()
    if vec_err is not None:
        print(("FNV1A FAIL " if MODE == "diff" else "") + vec_err, file=(sys.stdout if MODE == "diff" else sys.stderr))
        sys.exit(1)
    if MODE == "diff":
        print("FNV1A OK all 4 published FNV-1a/32 test vectors match")

    data = load_decks()

    if MODE == "diff":
        if data["orphan"] or data["dangling"]:
            print("INDEXDIR FAIL orphan=%s dangling=%s" % (data["orphan"], data["dangling"]))
        else:
            print("INDEXDIR OK %d files, INDEX and content/exercises/ directory agree in both directions" % len(data["decks"]))

    if MODE == "emit":
        print(json.dumps({"totals": data["totals"], "decks": data["decks"]}))
        return

    ex_json_path = sys.argv[4]
    try:
        with open(ex_json_path, encoding="utf-8") as fh:
            a = json.load(fh)
    except Exception as e:
        msg = "could not read exercise-check --json capture: %s" % e
        print("TOTALS FAIL " + msg)
        print("PERDECK FAIL " + msg)
        print("CITECOUNT FAIL " + msg)
        print("CITERESOLVE FAIL " + msg)
        sys.exit(1)

    a_totals = a.get("totals", {})
    tdiffs = []
    for f in ["decks", "exercises", "prompts", "quiz", "drill", "lookup"]:
        if a_totals.get(f) != data["totals"].get(f):
            tdiffs.append("%s: exercise-check=%r python=%r" % (f, a_totals.get(f), data["totals"].get(f)))
    if tdiffs:
        print("TOTALS FAIL " + "; ".join(tdiffs))
    else:
        print("TOTALS OK " + " ".join("%s=%s" % (f, data["totals"][f]) for f in ["decks", "exercises", "prompts", "quiz", "drill", "lookup"]))

    a_decks_by_name = {d.get("deck"): d for d in a.get("decks", [])}
    a_source_chars = {name: n for name, n in a.get("sourceChars", [])}
    pdiffs = []
    for pd in data["decks"]:
        ad = a_decks_by_name.get(pd["deck"])
        if ad is None:
            pdiffs.append("%s (deck %s): missing from exercise-check --json decks[]" % (pd["file"], pd["deck"]))
            continue
        for f in ["chapter", "title", "exercises", "prompts"]:
            if ad.get(f) != pd.get(f):
                pdiffs.append("%s.%s: exercise-check=%r python=%r" % (pd["file"], f, ad.get(f), pd.get(f)))
        n = a_source_chars.get(pd["file"])
        if n != pd["chars"]:
            pdiffs.append("%s.sourceChars: exercise-check=%r python=%r" % (pd["file"], n, pd["chars"]))
    if pdiffs:
        print("PERDECK FAIL " + "; ".join(pdiffs))
    else:
        print("PERDECK OK %d decks agree on chapter/title/exercises/prompts/sourceChars" % len(data["decks"]))

    if a_totals.get("citations") != data["citation_total"]:
        print("CITECOUNT FAIL exercise-check=%r python=%r" % (a_totals.get("citations"), data["citation_total"]))
    else:
        print("CITECOUNT OK %d citations (^cite:/^find: lines) agree" % data["citation_total"])

    if data["citation_failures"]:
        print("CITERESOLVE FAIL " + "; ".join(data["citation_failures"]))
    else:
        print("CITERESOLVE OK all %d citations independently re-resolved (page in range, anchor found after whitespace collapse)" % data["resolved_count"])


main()
PYEOF

  exstats_label() {
    case "$1" in
      FNV1A)       echo "exercise-stats/fnv1a-vectors (FNV-1a/32 pinned against published test vectors)" ;;
      INDEXDIR)    echo "exercise-stats/index-directory-agreement (content/exercises/INDEX vs directory, both directions)" ;;
      TOTALS)      echo "exercise-stats/totals-agreement (python re-derivation vs exercise-check --json totals)" ;;
      PERDECK)     echo "exercise-stats/per-deck-agreement (chapter/title/exercises/prompts/sourceChars)" ;;
      CITECOUNT)   echo "exercise-stats/citation-count-agreement (^cite:/^find: line count vs exercise-check --json)" ;;
      CITERESOLVE) echo "exercise-stats/citation-independent-resolution (page range + anchor re-checked from translations/*.md)" ;;
      *)           echo "exercise-stats/$1" ;;
    esac
  }

  if command -v python3 >/dev/null 2>&1; then
    if [ -n "$EXERCISE_JSON_FILE" ]; then
      EXSTATS_OUT="$(cd "$REPO_ROOT" && python3 "$EXERCISE_STATS_PY" diff "$REPO_ROOT/content" "$REPO_ROOT/translations" "$EXERCISE_JSON_FILE" 2>&1)" || true
    else
      EXSTATS_OUT="$(printf 'FNV1A FAIL no exercise-check --json capture available (see checks above)\nINDEXDIR FAIL no exercise-check --json capture available (see checks above)\nTOTALS FAIL no exercise-check --json capture available (see checks above)\nPERDECK FAIL no exercise-check --json capture available (see checks above)\nCITECOUNT FAIL no exercise-check --json capture available (see checks above)\nCITERESOLVE FAIL no exercise-check --json capture available (see checks above)\n')"
    fi
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      tag="${line%% *}"
      rest="${line#* }"
      status="${rest%% *}"
      detail="${rest#* }"
      label="$(exstats_label "$tag")"
      case "$status" in
        OK)   ok "$label ($detail)" ;;
        FAIL) fail "$label (observed: $detail)" ;;
        *)    fail "$label (unexpected output: $line)" ;;
      esac
    done <<< "$EXSTATS_OUT"
  else
    for tag in FNV1A INDEXDIR TOTALS PERDECK CITECOUNT CITERESOLVE; do
      fail "$(exstats_label "$tag") (observed: python3 not found on PATH)"
    done
  fi

  # -------------------------------------------------------------------------
  # Check 17, part D: STALE-BUILD DETECTION / BROWSER HANDOFF. Generate
  # the disk-derived --expect-exercise-json (via EXERCISE_STATS_PY's
  # "emit" mode -- the SAME code that just ran the check-16 diff above,
  # so item B's "every disagreement with A is caught" and item D's
  # "the expected deck list comes from disk" are one code path) and
  # exercise-check --browser-fixture's --exercise-fixture payload. Both
  # are handed to checks 7/8's scripts/browser-check.mjs below, which
  # compares them against #sxc1-exercise-stats -- what the RUNNING app
  # actually has embedded. See usage() check 17 for why
  # `content-check --dump-source`'s exact-bytes trick (M1's stale-build
  # detector) cannot be reused for the exercise corpus.
  # -------------------------------------------------------------------------
  EXPECT_EXERCISE_JSON_FILE=""
  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v python3 >/dev/null 2>&1; then
    CANDIDATE_EXPECT="$(mktemp -t sxc1-check-site-expect-ex.XXXXXX.json)"
    register_temp_file "$CANDIDATE_EXPECT"
    (cd "$REPO_ROOT" && python3 "$EXERCISE_STATS_PY" emit "$REPO_ROOT/content" "$REPO_ROOT/translations" >"$CANDIDATE_EXPECT" 2>/dev/null) || true
    if [ -s "$CANDIDATE_EXPECT" ] && python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$CANDIDATE_EXPECT" >/dev/null 2>&1; then
      ok "disk-derived exercise stats computed for browser-check.mjs --expect-exercise-json (python re-derivation from content/exercises/, never from the app payload)"
      EXPECT_EXERCISE_JSON_FILE="$CANDIDATE_EXPECT"
    else
      fail "disk-derived exercise stats computed for browser-check.mjs --expect-exercise-json (observed: python re-derivation failed or produced invalid JSON)"
    fi
  else
    fail "disk-derived exercise stats computed for browser-check.mjs --expect-exercise-json (observed: exe:exercise-check binary or python3 unavailable -- see checks above)"
  fi

  EXERCISE_FIXTURE_FILE=""
  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    CANDIDATE_FIXTURE="$(mktemp -t sxc1-check-site-exfixture.XXXXXX.json)"
    register_temp_file "$CANDIDATE_FIXTURE"
    run_exercise_check "${EXERCISE_CHECK_ARGS[@]}" --browser-fixture >"$CANDIDATE_FIXTURE" 2>/dev/null || true
    if [ -s "$CANDIDATE_FIXTURE" ]; then
      ok "exercise-check --browser-fixture produced JSON for browser-check.mjs --exercise-fixture"
      EXERCISE_FIXTURE_FILE="$CANDIDATE_FIXTURE"
    else
      fail "exercise-check --browser-fixture produced JSON for browser-check.mjs --exercise-fixture (observed: empty output -- real content may lack one of each exercise kind)"
    fi
  else
    fail "exercise-check --browser-fixture produced JSON for browser-check.mjs --exercise-fixture (observed: toolchain env or binary unavailable -- see checks above)"
  fi

  # -------------------------------------------------------------------------
  # Check 17, parts A/C (continued): FIXTURE RUN, COVERAGE INVARIANT, AND
  # THE SEAM-CLASS CAP.
  # -------------------------------------------------------------------------
  EXERCISE_FIXTURES_DIR="$REPO_ROOT/content/fixtures"

  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    if run_exercise_check "${EXERCISE_CHECK_ARGS[@]}" --fixtures "$EXERCISE_FIXTURES_DIR" >/dev/null 2>&1; then
      ok "exercise-check --fixtures content/fixtures exits 0 (the falsifiability corpus)"
    else
      fail "exercise-check --fixtures content/fixtures exits 0 (observed: non-zero exit -- a fixture disagrees with its own filename-declared verdict)"
    fi
  else
    fail "exercise-check --fixtures content/fixtures exits 0 (observed: toolchain env or binary unavailable -- see checks above)"
  fi

  LIST_CODES_OUT=""
  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    LIST_CODES_OUT="$(run_exercise_check "${EXERCISE_CHECK_ARGS[@]}" --list-codes 2>/dev/null)" || LIST_CODES_OUT=""
  fi

  if [ -n "$LIST_CODES_OUT" ]; then
    MISSING_CODES=()
    SEAM_CODES=()
    while IFS=$'\t' read -r code cls; do
      [ -n "$code" ] || continue
      case "$cls" in
        file)
          found=0
          for f in "$REPO_ROOT/content/fixtures/files"/*; do
            [ -e "$f" ] || continue
            bn="$(basename "$f")"
            case "$bn" in "$code--"*) found=1; break ;; esac
          done
          [ "$found" -eq 1 ] || MISSING_CODES+=("$code (file)")
          ;;
        dir)
          found=0
          for d in "$REPO_ROOT/content/fixtures/dirs"/*/; do
            [ -e "$d" ] || continue
            bn="$(basename "$d")"
            case "$bn" in "$code--"*) found=1; break ;; esac
          done
          [ "$found" -eq 1 ] || MISSING_CODES+=("$code (dir)")
          ;;
        seam)
          SEAM_CODES+=("$code")
          ;;
        *)
          MISSING_CODES+=("$code (unknown class '$cls')")
          ;;
      esac
    done <<< "$LIST_CODES_OUT"

    if [ "${#MISSING_CODES[@]}" -eq 0 ]; then
      ok "fixture coverage invariant: every file/dir code from --list-codes has >=1 fixture (checked every code exercise-check --list-codes prints)"
    else
      fail "fixture coverage invariant: every file/dir code from --list-codes has >=1 fixture (observed: missing for ${MISSING_CODES[*]})"
    fi

    # E-BLOCK-UNPARSED is provably unreachable from any real file (see
    # content/EXERCISE-FORMAT.md sec. 7 and content/fixtures/README.md) --
    # it CANNOT have a fixture, so the coverage invariant above exempts
    # the "seam" class and this asserts its cap instead: exactly one seam
    # code, and it must be E-BLOCK-UNPARSED. This is this task's negative
    # control (c2)'s target.
    if [ "${#SEAM_CODES[@]}" -eq 1 ] && [ "${SEAM_CODES[0]}" = "E-BLOCK-UNPARSED" ]; then
      ok "seam-class coverage cap: exactly one seam-class code, E-BLOCK-UNPARSED (observed: ${SEAM_CODES[*]})"
    else
      fail "seam-class coverage cap: exactly one seam-class code, E-BLOCK-UNPARSED (observed: ${SEAM_CODES[*]:-<none>})"
    fi
  else
    fail "fixture coverage invariant: every file/dir code from --list-codes has >=1 fixture (observed: --list-codes produced no output -- see checks above)"
    fail "seam-class coverage cap: exactly one seam-class code, E-BLOCK-UNPARSED (observed: --list-codes produced no output -- see checks above)"
  fi

  FIXTURES_PY="$(mktemp -t sxc1-check-site-fxverdict.XXXXXX.py)"
  register_temp_file "$FIXTURES_PY"
  cat > "$FIXTURES_PY" <<'PYEOF'
import json
import os
import sys

FIXTURES_DIR = sys.argv[1]
JSON_PATH = sys.argv[2]

files_dir = os.path.join(FIXTURES_DIR, "files")
dirs_dir = os.path.join(FIXTURES_DIR, "dirs")


def expected_code_of(name):
    return name.split("--", 1)[0]


disk_names = set()
if os.path.isdir(files_dir):
    for f in os.listdir(files_dir):
        if f.endswith(".ex.md"):
            disk_names.add(f)
if os.path.isdir(dirs_dir):
    for d in os.listdir(dirs_dir):
        if os.path.isdir(os.path.join(dirs_dir, d)):
            disk_names.add(d)

expected_map = {n: expected_code_of(n) for n in disk_names}

try:
    with open(JSON_PATH, encoding="utf-8") as fh:
        data = json.load(fh)
except Exception as e:
    print("FAIL could not read --fixtures --json capture: %s" % e)
    sys.exit(1)

json_names = set()
diffs = []
for f in data.get("fixtures", []):
    name = f.get("name")
    json_names.add(name)
    want = expected_map.get(name)
    if want is not None and want != f.get("expected"):
        diffs.append("%s: filename says expected=%s but JSON expected=%s" % (name, want, f.get("expected")))
    if not f.get("pass"):
        diffs.append("%s: pass=false (want=%s got=%s)" % (name, f.get("expected"), f.get("got")))

only_disk = sorted(disk_names - json_names)
only_json = sorted(json_names - disk_names)
if only_disk:
    diffs.append("fixtures on disk but missing from --fixtures --json output: %s" % only_disk)
if only_json:
    diffs.append("fixtures in --fixtures --json output but not found on disk: %s" % only_json)

if not data.get("ok", False):
    diffs.append("--fixtures --json overall ok=false")

if diffs:
    print("FAIL " + "; ".join(diffs))
    sys.exit(1)
print("OK %d fixtures (filename-declared verdicts independently re-derived and matched)" % len(disk_names))
sys.exit(0)
PYEOF

  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    CANDIDATE_FIXTURES_JSON="$(mktemp -t sxc1-check-site-fxjson.XXXXXX.json)"
    register_temp_file "$CANDIDATE_FIXTURES_JSON"
    run_exercise_check "${EXERCISE_CHECK_ARGS[@]}" --fixtures "$EXERCISE_FIXTURES_DIR" --json >"$CANDIDATE_FIXTURES_JSON" 2>/dev/null || true
    if [ -s "$CANDIDATE_FIXTURES_JSON" ]; then
      FX_VERDICT_OUT="$(python3 "$FIXTURES_PY" "$EXERCISE_FIXTURES_DIR" "$CANDIDATE_FIXTURES_JSON" 2>&1)" || true
      case "$FX_VERDICT_OUT" in
        "OK "*) ok "independent verdict re-derivation from fixture filenames matches --fixtures --json (${FX_VERDICT_OUT#OK })" ;;
        *)      fail "independent verdict re-derivation from fixture filenames matches --fixtures --json (observed: ${FX_VERDICT_OUT#FAIL })" ;;
      esac
    else
      fail "independent verdict re-derivation from fixture filenames matches --fixtures --json (observed: could not capture --fixtures --json output)"
    fi
  else
    fail "independent verdict re-derivation from fixture filenames matches --fixtures --json (observed: toolchain env, binary, or python3 unavailable -- see checks above)"
  fi
  rm -f "$FIXTURES_PY"
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
  # M2 (task "verification", item D): the disk-derived exercise stats and
  # exercise-check --browser-fixture payload, so #sxc1-exercise-stats (what
  # app.wasm actually has embedded) is compared against what is on disk
  # right now -- see checks 16/17 above for how these two files are built.
  # Falls back to no exercise-engine browser assertions at all when either
  # is unavailable (--skip-content, or checks 16/17 could not produce a
  # capture) -- mirroring --expect-json's own fallback immediately above.
  if [ -n "${EXPECT_EXERCISE_JSON_FILE:-}" ] && [ -s "$EXPECT_EXERCISE_JSON_FILE" ]; then
    browser_cmd+=(--expect-exercise-json "$EXPECT_EXERCISE_JSON_FILE")
  fi
  if [ -n "${EXERCISE_FIXTURE_FILE:-}" ] && [ -s "$EXERCISE_FIXTURE_FILE" ]; then
    browser_cmd+=(--exercise-fixture "$EXERCISE_FIXTURE_FILE")
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
