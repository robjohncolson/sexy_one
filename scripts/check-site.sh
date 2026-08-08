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
# --optimized (M3 harness, "build the lever, do not pull it" -- see the
# big comment right before its implementation below, near the top of the
# main check sequence): NOT a new skip axis (this is opt-IN extra work,
# never fewer checks) and NOT a change to what a plain `check-site.sh`
# checks by default. Off by default, same convention as the two flags
# above.
OPTIMIZED=0

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
  --optimized      Re-derives an optimized+stripped COPY of the artifact
                   already at --dir by running \`wasm-opt --detect-features
                   -Oz --converge\` then
                   \`wasm-tools strip\` on a copy of app.wasm (never the
                   original -- the unoptimized artifact this invocation
                   was pointed at is left untouched), reports both gzip
                   sizes, then re-runs THIS ENTIRE SAME SUITE against the
                   optimized copy via a fresh self-invocation with --dir
                   pointed at it (forwarding --port/--skip-browser/
                   --skip-content). Exits with that inner run's exit
                   code. Requires wasm-opt and wasm-tools on PATH (the
                   toolchain env is sourced automatically, same as the
                   content-checker below). Does NOT change what a plain
                   \`check-site.sh\` (no --optimized) checks. The flags
                   match build-site.sh --optimize -- the SHIPPING build
                   per PLAN.md's Size ruling and its 2026-08-07
                   amendment -- so this flag reproduces the shipping
                   pipeline on an unoptimized input.
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
  14. THE CLOCK/M4-VERIFIER INVARIANT (unconditional, not on the content
     axis): site/app must use the real wall-clock and monotonic-clock
     mechanisms (GHC.Clock.getMonotonicTimeNSec and JS Date.getTime -- NOT
     Data.Time.Clock.POSIX, which does not build for this target) and
     must wire the real M4 device verifier (webMidiVerifier, consumed
     through a dvWatch call site), all FOUR on lines that are not Haskell
     comments. M4 note: this check used to require the M2-era stub
     noDeviceVerifier, which M4 (task "device-app", manifest Part B)
     deliberately DELETED in favour of the real Device.Midi verifier --
     the identifier list tracks the tree, and check 18's V5 asserts the
     stub is gone. This replaces a vacuous sibling check (task
     "exercise-ui"'s own `grep -RqE "getPOSIXTime|POSIX"`, which only
     ever matches the Haddock comment explaining why POSIX is NOT used --
     the M0-n2 pattern) with one anchored to the real, non-comment code.
  15. EXERCISE VALIDATOR GATE (content axis): exe:exercise-check, resolved
     and run exactly like exe:content-check (checks 10-12) -- same
     toolchain env, same `wasm32-wasi-cabal list-bin` / wasm-run.mjs
     convention -- against the REAL content/translations roots with
     --content-dir/--translations-dir/--json, requiring the run to exit 0
     AND the captured JSON's "ok" field to be true (issues, if any, are
     printed). M5 (briefs/M5-ship.md debt item 6) adds one sibling
     check: the SAME binary must also pass --self-test when invoked
     from the REPO ROOT (cwd-robust content-root resolution -- its
     disk groups read content/ and translations/ through the probed
     root). Unless --skip-content.
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
     -- comparing what the running app ACTUALLY LOADED
     (#sxc1-exercise-stats -- since M6 W1 computed from the content
     bundle the app fetched at boot, before that from the TH-embedded
     corpus) against what is on disk right now. This is M2's equivalent
     of check 12's `content-check --dump-source` exact-bytes comparison,
     but that trick cannot be reused here: --dump-source reads bytes the
     Haskell compiler already embedded, whereas exe:exercise-check only
     ever reads content/exercises/ off DISK -- so a forgotten rebuild
     (now: a stale content bundle -- see check 20's freshness half)
     shows up as a RED check instead of a silently stale site. The
     per-deck FNV-1a is what makes this byte-sensitive, not merely
     length-sensitive. Unless --skip-content.
  18. M4 DEVICE-VERIFICATION GATE (task "verification"): checks V1-V8
     from briefs/M4-manifest.json, on the EXISTING axes only -- no new
     skip flag. V1, V2, V8 (size/budget: the frozen ceiling constant
     asserted in this script's own source; then, per the coordinator's
     2026-08-08 M5 re-scope ruling -- whose three authorized numbers
     are PINNED AS LITERALS in this script (M5_M4_FINAL=927008,
     M5_RESERVE=60000, M5_TASK_CEILING=987008; M5 final-review fix,
     briefs/M5-codex-final1.json finding M5-R1-2: the mutable
     briefs/M5-budget.json may not raise its own authorized reserve) --
     V2 measures the artifact against the PINNED task-local ceiling
     (= pinned m4_final + pinned m5_reserve) printing the observed gzip
     and its delta from the pinned m4_final, and V8 checks that
     briefs/M5-budget.json MATCHES the three pinned values exactly
     (a doctored file fails even when internally consistent), the M5
     budget's own arithmetic, the fresh artifact against the M5 window,
     AND that briefs/M4-budget.json still stands unchanged as the M4
     historical record), V3/V4 (the
     scripts/fake-midi.js harness fake exists, parses, names every
     driver member, and is NEVER shipped into site/public or
     site/static), V5 (the seven M4 structural invariants over site/app,
     anchored to non-comment lines: single requestMIDIAccess call site
     in the device bridge; sysex only as False; no storage under
     site/app/Device/, case-insensitive; no network egress; the M2 stub
     noDeviceVerifier gone; a live dvWatch call site; SXC1.Midi.Table
     unreachable from exe:app) and V7 (every route and DOM id named by
     docs/M4-device-test-protocol.md exists in the tree, with extraction
     anti-vacuity floors) are all unconditional. V6 (the 27 WebMIDI
     device assertions D1..D27 actually ran and passed inside check 7's
     root browser run -- D26/D27 are the M5 a11y device assertions,
     pulled INSIDE the floor by the M5 final-review fix for
     briefs/M5-codex-final1.json finding M5-R1-1; the old D1..D25 floor
     let them be silently unplugged) lives on the BROWSER axis: skipped
     via skip() under --skip-browser, so a skipped run still counts it
     and the TOTAL never changes.
  19. M5 CARDINALITY CONTRACT (briefs/M5-codex-final1.json, M5-R1-1):
     (a) the root and sub-path browser stages must EACH report a final
     "browser-check: N/N assertions passed" line with N >=
     M5_BROWSER_ASSERT_FLOOR (175). These are FLOORS, never equalities
     -- future additions must not break them, and RAISING THE FLOOR IS
     PART OF ADDING ASSERTIONS. Only meaningful on full fixture inputs:
     skipped via skip() under --skip-browser (stage never ran) and
     under --skip-content (the browser stages lawfully run fewer
     assertions without the content/exercise fixtures -- see check 17).
     (b) this script's own final TOTAL must equal the pinned
     M5_CHECK_TOTAL constant (see the reporting helpers below),
     unconditionally -- skip() counts toward TOTAL, so the pin holds on
     skip runs too, and a deleted check turns the gate red instead of
     silently shrinking the total. ADDING OR REMOVING ANY CHECK
     REQUIRES A VISIBLE EDIT TO THE PIN.
  20. M6 CONTENT-BUNDLE CHECKS (unconditional): the corpus-externalization
     re-baseline (briefs/M6-plan.md rulings 1/6). content/content.en.txt
     and content.ja.txt are required files (check 1); the
     M6_BUNDLE_CEILING=300000 combined-gzip ceiling constant is asserted
     in this script's own source (the V1 pattern); both bundle gzips are
     measured, recorded to state/bundle-ledger.tsv, and the combined
     number is HARD-gated under the ceiling; both shipped bundles must
     byte-match a fresh scripts/emit-content-bundles.py emission from
     content/exercises/ (the stale-bundle detector, check 12's
     exact-bytes discipline); and briefs/M6-budget.json must match the
     pinned M6 re-baseline (m5_final==933305, frozen ceiling,
     bundle_ceiling==M6_BUNDLE_CEILING, m6_entry shrunk by >=
     M6_SHRINK_MIN, fresh artifact in [m6_entry-3000, 1000000)) AND
     (M6 W4) its recorded M6-FINAL figures must describe THIS tree:
     m6_final_gzip_bytes within 3000 of the freshly measured artifact,
     and the recorded en/ja/combined bundle gzips self-consistent,
     under the bundle ceiling, and within 3000 of the live measurement
     (a 3000-byte window rather than an equality because gzip's exact
     output is a property of the local gzip build, not of this tree --
     the same window the artifact figure already uses).
  21. M6 FETCH-FAILURE DEGRADATION (browser axis): a COPY of the bundle
     is served WITHOUT its content/ directory and browser-check
     --check-content-missing must report 4/4: the app still boots (the
     JS-side content guard), the visible #sxc1-content-error banner
     names the failure, a real manual page stays readable, and the
     exercise routes offer #btn-content-retry. Skipped via skip() under
     --skip-browser, like every other browser-axis stage.
  22. M6 W2 UI-LANGUAGE TOGGLE ROUNDTRIP (browser axis): a COPY of the
     bundle is served whose content bundles are RE-EMITTED from a COPY
     of content/exercises carrying ONE injected ja: fixture variant
     (content/ itself is never touched -- the M6-c/d freshness checks
     pin that), and browser-check --check-ja-toggle must report 9/9 on
     a fresh profile: boots EN fetching content.en.txt; #btn-ui-lang
     switches to JA through the app's own persist-then-reload
     (reload-as-refetch, proven by the fresh document's resource
     entries naming content.ja.txt); Japanese header + document lang;
     the sxc1.uilang boot hint and the SXC1PREFS uiLang line survive;
     ruling 4's one-time jaFirst suggestion fires (fresh profile ==
     never explicitly set) without marking the choice taken; the
     injected JA exercise title renders from the ja bundle; a JA
     device flow (fake-midi) pins the JA status/waiting/confirmed
     sentences including the describeSpec JA renderer; and switching
     back restores EN. The injection is grep-confirmed both into the
     served copy's ja bundle AND absent from its en bundle before the
     browser ever runs. Skipped via skip() under --skip-browser.
  23. M6 W4 JA COURSE FLOOR (browser axis): the five "ja course:"
     assertions scripts/browser-check.mjs runs inside BOTH full stages
     (checks 7/8, within the UI-language JA flow) must each be reported
     ok, counted BY NAME in each stage's own capture -- the D-suite's
     V6 discipline, because the N/N cardinality floor (check 19a) only
     catches assertions being REMOVED, not replaced. What those five
     prove is the milestone claim itself: the ja bundle the site SHIPS
     renders the real Japanese course -- #sxc1-exercise-stats reports
     52 decks / 435 exercises and the pinned deck's JAPANESE title; the
     deck index card, deck page title and deck summary: are the
     corpus's Japanese; a real corpus quiz renders its JA title,
     question and both option labels and, clicked BY ITS JAPANESE
     LABEL, grades to the JA "Correct" feedback with the JA rationale;
     and a real corpus drill step shows its JA check: sentence. Every
     expectation is a LITERAL pinned in browser-check.mjs
     (JA_COURSE_PINS), never derived from the bundle under test, so an
     EN-fallback ja bundle (the emitter's documented degenerate case,
     and what content.ja.txt actually was through waves 1-2) turns all
     five red. Skipped via skip() under --skip-browser (the stages
     never ran) and under --skip-content (without --exercise-fixture
     the JA flow does not run at all).

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
    --optimized)
      OPTIMIZED=1
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
# M5 CARDINALITY CONTRACT PINS (M5 final-review fix, briefs/
# M5-codex-final1.json finding M5-R1-1). Every total in this gate used to be
# DYNAMICALLY ACCUMULATED -- ok()/fail()/skip() above for check-site's own
# total, report() inside scripts/browser-check.mjs for the browser stages --
# so a deleted check or an unplugged browser assertion produced a SMALLER
# all-green run instead of a failure. These two constants pin the
# cardinalities, in the same frozen-literal style as
# WASM_GZIP_CEILING_BYTES:
#
#   M5_CHECK_TOTAL         the exact final TOTAL this script must report,
#                          asserted by the last check before the summary
#                          (that check counts itself). skip() increments
#                          TOTAL exactly like ok()/fail(), so this pin
#                          holds on --skip-browser/--skip-content runs
#                          too. ADDING (or removing) A CHECK REQUIRES A
#                          VISIBLE EDIT TO THIS PIN -- that is the point.
#   M5_BROWSER_ASSERT_FLOOR  the minimum "N/N assertions passed" total
#                          each of the two full browser stages (root and
#                          sub-path, checks 7/8) must report on a full
#                          run. A FLOOR, never an equality: future
#                          assertion additions must not break it, and
#                          RAISING THE FLOOR IS PART OF ADDING
#                          ASSERTIONS (leave it behind and the new
#                          assertions are exactly as unpluggable as
#                          D26/D27 were before this fix).
# ---------------------------------------------------------------------------
# M6 W1 pin raise (the documented procedure: ADDING A CHECK REQUIRES A
# VISIBLE EDIT TO THE PIN; RAISING THE FLOOR IS PART OF ADDING
# ASSERTIONS): 99 -> 107 (+2 required content bundles in check 1, +1
# M6_BUNDLE_CEILING literal, +1 bundle ledger/ceiling, +2 bundle
# freshness en/ja, +1 M6 budget re-baseline, +1 fetch-failure
# degradation stage) and 175 -> 176 (+1: the degraded-content
# absent-scenario parity assertion in runExerciseAssertions, present in
# both full stages).
# M6 W2 pin raise (same documented procedure): 107 -> 108 (+1: the
# ui-language toggle roundtrip stage, check 22) and 176 -> 233 (the
# UI-language JA flow in both full stages: the toggle's own six
# assertions plus the ENTIRE runExerciseAssertions/a11y set re-run
# under lang='ja' with every learner-visible text pin pinning the JA
# string -- measured 233/233 on both full stages at this raise).
# M6 W4 pin raise (same documented procedure): 108 -> 109 (+1: the JA
# COURSE floor, check 23 -- the named counterpart of the D-suite's V6)
# and 233 -> 238 (+5: the JA course assertions inside
# runUiLangJaAssertions -- shipped-bundle totals + JA deck title, the
# deck card/page/summary in Japanese, a real corpus quiz COMPLETED in
# Japanese, and a real corpus drill step's JA check: sentence --
# measured 238/238 on both full stages at this raise).
M5_CHECK_TOTAL=109
M5_BROWSER_ASSERT_FLOOR=238

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
# --optimized (M3 harness, task "harness", item 5): BUILD THE LEVER, DO NOT
# PULL IT. This must run before Check 1 and short-circuit everything below
# -- it is a "build a variant, then delegate the entire suite to it" step,
# not a check of its own.
#
# What it does NOT do, on purpose: it never touches $DIR/app.wasm itself
# (the artifact this invocation was pointed at stays exactly as
# build-site.sh left it -- optimized or not, whatever it already was); it
# never edits build-site.sh's own OPTIMIZE default (still 0, checked by
# this task's own verify_commands); and it adds no new skip axis -- this is
# opt-in EXTRA verification, never fewer checks on the default path.
#
# Ordering (mirrors build-site.sh's own --optimize branch exactly): run
# wasm-opt/wasm-tools strip strictly AFTER post-link.mjs, never before --
# stripping removes the custom wasm section post-link.mjs reads to emit
# ghc_wasm_jsffi.js. $DIR/app.wasm was already produced by build-site.sh,
# which always runs post-link.mjs before any optional optimize step
# (--optimize or not) -- so optimizing a COPY of it here, without ever
# re-running post-link, satisfies that ordering by construction.
#
# Sizing context (coordinator, PLAN.md "Size ruling", 2026-08-07): the M3
# designer measured wasm-opt -O2 saving 169-179 KB on this codebase and
# could not make it miscompile (exercise-check --self-test byte-identical
# output; the real optimized app passed 70/70 browser assertions across
# six runs). This flag is what lets that lever be re-verified on demand,
# against the SAME suite everything else is judged by, without silently
# adopting it as the default build. Measured on this tree (M3 harness
# wave, full 52-deck/435-exercise course): unoptimized app.wasm gzips to
# 1,094,331 bytes (over the 1,000,000 ceiling -- see the WASM_GZIP_CEILING
# comment below for why that is a known, already-ruled-on gap this task
# does not close); wasm-opt -all -O2 + wasm-tools strip brings that down
# to approximately 907,600-907,650 bytes (measured 907,644 and 907,635 on
# two runs a few source-tree edits apart) -- comfortably under budget.
# Adopting wasm-opt as the DEFAULT shipping build is a coordinator/CI
# decision (task "docs-and-ci"), never this script's to make on its own.
# ===========================================================================
if [ "$OPTIMIZED" -eq 1 ]; then
  TOOLCHAIN_ENV_FILE="${GHC_WASM_PREFIX:-$HOME/.ghc-wasm}/env"
  if [ -f "$TOOLCHAIN_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$TOOLCHAIN_ENV_FILE"
  fi

  if ! command -v wasm-opt >/dev/null 2>&1 || ! command -v wasm-tools >/dev/null 2>&1; then
    echo "check-site: --optimized requires both wasm-opt and wasm-tools on PATH (source $TOOLCHAIN_ENV_FILE or install the toolchain)" >&2
    exit 1
  fi
  if [ ! -f "$DIR/app.wasm" ]; then
    echo "check-site: --optimized needs an existing build at '$DIR/app.wasm' -- run ./scripts/build-site.sh first" >&2
    exit 1
  fi

  ORIG_GZIP="$(gzip -c "$DIR/app.wasm" | wc -c | tr -d ' ')"

  OPT_TMP="$(mktemp -d -t sxc1-check-site-optimized.XXXXXX)"
  register_temp_dir "$OPT_TMP"
  OPT_DIR="$OPT_TMP/public"
  mkdir -p "$OPT_DIR"
  cp -R "$DIR"/. "$OPT_DIR"/

  echo "check-site: --optimized -- running wasm-opt --detect-features -Oz --converge then wasm-tools strip on a COPY of '$DIR/app.wasm' (the original is untouched; same flags as build-site.sh --optimize, the shipping build)"
  if ! wasm-opt --detect-features -Oz --converge "$OPT_DIR/app.wasm" -o "$OPT_DIR/app.opt.wasm"; then
    echo "check-site: --optimized -- wasm-opt failed; the artifact at '$DIR' was never modified" >&2
    exit 1
  fi
  if ! wasm-tools strip -o "$OPT_DIR/app.wasm" "$OPT_DIR/app.opt.wasm"; then
    echo "check-site: --optimized -- wasm-tools strip failed; the artifact at '$DIR' was never modified" >&2
    exit 1
  fi
  rm -f "$OPT_DIR/app.opt.wasm"

  OPT_GZIP="$(gzip -c "$OPT_DIR/app.wasm" | wc -c | tr -d ' ')"
  echo "check-site: app.wasm gzip -- UNOPTIMIZED (as built): $ORIG_GZIP bytes; OPTIMIZED+stripped (this flag): $OPT_GZIP bytes; saved $((ORIG_GZIP - OPT_GZIP)) bytes"

  CHILD_ARGS=(--dir "$OPT_DIR" --port "$PORT")
  if [ "$SKIP_BROWSER" -eq 1 ]; then CHILD_ARGS+=(--skip-browser); fi
  if [ "$SKIP_CONTENT" -eq 1 ]; then CHILD_ARGS+=(--skip-content); fi

  echo "check-site: --optimized -- running the ENTIRE existing suite against the optimized copy: ${BASH_SOURCE[0]} ${CHILD_ARGS[*]}"
  set +e
  "${BASH_SOURCE[0]}" "${CHILD_ARGS[@]}"
  CHILD_RC=$?
  set -e
  exit "$CHILD_RC"
fi

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
  # M6 W1 (briefs/M6-plan.md, ruling 1): the per-language exercise
  # content bundles the app now loads at boot (build-site.sh step 7b,
  # scripts/emit-content-bundles.py). A bundle-less build ships a
  # permanently degraded app, so their absence is a missing-required-file
  # failure exactly like a missing app.wasm.
  "content/content.en.txt"
  "content/content.ja.txt"
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
# A): THE CLOCK/M4-VERIFIER INVARIANT, unconditional -- not on the content
# axis, never skipped, because it is a pure source-tree scan with no
# toolchain dependency.
#
# M4 UPDATE (task "verification"): the identifier list below used to
# require the M2-era stub noDeviceVerifier. M4's device-app wave
# deliberately DELETED that stub (briefs/M4-manifest.json Part B) and
# replaced it with the real thing: Device.Midi.webMidiVerifier over one
# Hub, consumed through dvWatch. The list now tracks the tree --
# webMidiVerifier and dvWatch on non-comment lines -- and reintroducing
# the stub is caught separately (check 18's V5 asserts noDeviceVerifier
# is GONE from site/app). Do not put noDeviceVerifier back here.
#
# M2 gate fix (M4): this check certifies PRESENCE, not WIRING -- it marks
# success once getMonotonicTimeNSec, Date.getTime, webMidiVerifier and
# dvWatch occur ANYWHERE on a non-comment line, which is satisfied even when the
# app feeds the WRONG clock into Begin/Restart or never calls
# beginIfNeeded at all on a cold route (H1/H6 -- both shipped past this
# very check). Identifier presence is not wiring, so this grep is now
# explicitly SUBORDINATE, cheap defence in depth and a better error
# message ONLY: it may still run and still fail loudly on a genuinely
# missing mechanism, but it is NOT the check that certifies the clock
# seam is correctly wired. The BEHAVIOURAL gate for that is checks 7/8
# below (the real, running app under a headless browser):
# scripts/browser-check.mjs's cold-load + known-wait + first-try
# elapsedMs assertion, its Restart-yields-a-blank-prompt assertion, and
# its drill/lookup citation assertions -- see that script's own
# COLD_ELAPSED_ASSERTION_NAME and runExerciseAssertions. THOSE are what
# must go green for the clock/M4 seam to be considered proven; this grep
# going green proves nothing on its own.
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
# This check requires all four of getMonotonicTimeNSec, Date.getTime,
# webMidiVerifier and dvWatch on lines that are NOT Haskell comments,
# using a small python3 pass (naive "split each line on its first '--'"
# line-comment strip -- sufficient here because none of these four
# identifiers ever appears after a literal '--' inside a string literal
# in this codebase; a block ({- -}) comment is not specially handled
# either, for the same reason: none of the four occurs inside one).
# ===========================================================================
CLOCK_STUB_PY="$(mktemp -t sxc1-check-site-clockstub.XXXXXX.py)"
register_temp_file "$CLOCK_STUB_PY"
cat > "$CLOCK_STUB_PY" <<'PYEOF'
import os
import sys

TARGETS = ["getMonotonicTimeNSec", "Date.getTime", "webMidiVerifier", "dvWatch"]
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
print("OK all four real mechanisms present on non-comment .hs lines under %s: %s" % (ROOT, ", ".join(TARGETS)))
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
      ok "clock/M4 identifiers present on non-comment lines (SUBORDINATE defence-in-depth only -- the BEHAVIOURAL clock-wiring gate is checks 7/8's browser assertions below) (${CLOCK_STUB_OUT#OK })"
      ;;
    *)
      fail "clock/M4 identifiers present on non-comment lines (SUBORDINATE defence-in-depth only -- the BEHAVIOURAL clock-wiring gate is checks 7/8's browser assertions below) (observed: ${CLOCK_STUB_OUT#FAIL })"
      ;;
  esac
else
  fail "clock/M4 identifiers present on non-comment lines (SUBORDINATE defence-in-depth only -- the BEHAVIOURAL clock-wiring gate is checks 7/8's browser assertions below) (observed: python3 not found on PATH)"
fi
rm -f "$CLOCK_STUB_PY"

# ===========================================================================
# THE Miso.Storage STANDING GUARD (M3 harness, task "harness", item 6).
# Unconditional -- not on the content axis, never skipped, a pure
# source-tree grep with no toolchain dependency, exactly like the clock/M4
# invariant just above.
#
# briefs/M3-manifest.json's own milestone_verify_commands already gate this
# exact property at the MILESTONE level; this check exists so a plain
# `./scripts/check-site.sh` run also catches it, on the same "every check
# reports through ok()/fail()/skip()" bookkeeping everything else here
# uses. "SXC1.Progress.Store" (site/app/Progress/Store.hs) is the ONE
# module in the project allowed to import Miso.Storage -- pure codecs live
# in SXC1.Progress.Codec, and every OTHER module is expected to go through
# Store's small IO-boundary API (loadProgress/saveProgress/wipeProgress/
# loadPrefs/savePrefs/storageAvailable) rather than touching localStorage
# directly, so the never-overwrite-a-corrupt-blob rule has exactly one
# place it can be violated from.
#
# CASE-INSENSITIVE, DELIBERATELY: Miso's actual API surface is
# `setLocalStorage`/`getLocalStorage`/`removeLocalStorage` (see
# Miso.Storage's own export list) -- a case-SENSITIVE grep for the module
# name still catches an `import Miso.Storage` line, but the module-name
# grep alone would miss a hypothetical direct FFI/JS-DSL reach for
# `window.localStorage` under a differently-cased identifier. Grepping
# case-insensitively for the substring "localstorage" catches both the
# import line and any such call, wherever spelled.
#
# ANCHORED TO NON-COMMENT LINES (house standard 5): a naive
# `grep -rli "miso.storage\|localstorage"` across this tree ALSO matches
# Haddock prose that merely DESCRIBES the rule ("no 'Miso.Storage' import"
# in SXC1.Exercise.Engine's module header; "the ONE module ... allowed to
# ... write @localStorage@" in Store.hs's own Haddock and in
# SXC1.Progress.Codec's) -- demonstrated directly: an unanchored grep over
# this exact tree returns THREE files, not one, purely from comments
# describing the very discipline this check exists to enforce (the M0-n2
# pattern this project has been bitten by before). This uses the same
# split-each-line-on-its-first-"--" strip the clock/M4 check just above
# already uses, for the same reason -- a naive grep is trivially defeated
# by (or in this case, trivially defeats itself against) a comment.
# ===========================================================================
STORAGE_GUARD_PY="$(mktemp -t sxc1-check-site-storageguard.XXXXXX.py)"
register_temp_file "$STORAGE_GUARD_PY"
cat > "$STORAGE_GUARD_PY" <<'PYEOF'
import os
import sys

ROOTS = sys.argv[1:]
# M3 storage-refused fix: NO Haskell file may reach localStorage or
# Miso.Storage AT ALL any more (a JS exception thrown by localStorage
# does not unwind into Haskell -- it killed boot; see Progress/Store.hs's
# module Haddock). All access goes through the JS-side try/catch bridge
# window.__sxc1Storage (site/static/index.js), and exactly ONE Haskell
# file may name that bridge: Progress/Store.hs.
DIRECT = ("miso.storage", "localstorage")
BRIDGE = ("__sxc1storage",)

direct_hits, bridge_hits = [], []
for root in ROOTS:
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not fn.endswith(".hs"):
                continue
            path = os.path.join(dirpath, fn)
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    code_part = line.split("--", 1)[0].lower()
                    if any(n in code_part for n in DIRECT):
                        direct_hits.append(path)
                    if any(n in code_part for n in BRIDGE):
                        bridge_hits.append(path)

print("DIRECT " + "\t".join(sorted(set(direct_hits))))
print("BRIDGE " + "\t".join(sorted(set(bridge_hits))))
PYEOF

if command -v python3 >/dev/null 2>&1; then
  STORAGE_GUARD_OUT="$(python3 "$STORAGE_GUARD_PY" "$REPO_ROOT/site/src" "$REPO_ROOT/site/app" "$REPO_ROOT/site/test" 2>&1)" || true
  STORAGE_DIRECT="$(printf '%s\n' "$STORAGE_GUARD_OUT" | sed -n 's/^DIRECT //p')"
  STORAGE_BRIDGE="$(printf '%s\n' "$STORAGE_GUARD_OUT" | sed -n 's/^BRIDGE //p')"
  if [ -z "$STORAGE_DIRECT" ] && [ "$STORAGE_BRIDGE" = "$REPO_ROOT/site/app/Progress/Store.hs" ]; then
    ok "storage access: zero Haskell files touch Miso.Storage/localStorage; the __sxc1Storage bridge is named by exactly site/app/Progress/Store.hs"
  else
    fail "storage access: zero Haskell files may touch Miso.Storage/localStorage and only Progress/Store.hs may name __sxc1Storage (observed direct: ${STORAGE_DIRECT:-<none>}; bridge: ${STORAGE_BRIDGE:-<none>})"
  fi
else
  fail "Miso.Storage (case-insensitive, non-comment lines only: Miso.Storage or *localStorage*) appears in exactly one file, site/app/Progress/Store.hs (observed: python3 not found on PATH)"
fi
rm -f "$STORAGE_GUARD_PY"

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
#
# M3 UPDATE (coordinator, PLAN.md "Size ruling", 2026-08-07, binding):
# THE SHIPPING ARTIFACT IS build-site.sh --optimize'S OUTPUT. The full
# 52-deck/435-exercise course does not fit under this ceiling unoptimized
# (measured 1,094,331 bytes on this tree -- OVER by 94,331); wasm-opt -O2
# + wasm-tools strip (this task's own --optimized flag above reproduces
# that pipeline exactly, ordering included) measured ~907,600-907,650,
# comfortably under. That gap and its resolution are a COORDINATOR
# decision, not this task's: this task does not enable --optimize by
# default in build-site.sh (still OPTIMIZE=0 there) and does not touch
# this constant -- CI wiring of --optimize as the default shipping build
# belongs to task "docs-and-ci". What this check DOES do, unchanged by
# any of the above and by design: it measures gzip($WASM_FILE) --
# whatever is ACTUALLY sitting at site/public/app.wasm right now, e.g.
# via `report_size` above -- REGARDLESS of which build flavour produced
# it. Point build-site.sh at either flavour (plain, or --optimize) and
# this same check fails if, and only if, THAT artifact -- the one that
# would actually ship -- is at or over the ceiling. There is no separate
# "optimized-only" carve-out: an optimized build that somehow still came
# in over budget would fail this exactly as an unoptimized one does.
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
# Check 18 (M4, task "verification"): THE M4 DEVICE-VERIFICATION GATE,
# checks V1-V8 from briefs/M4-manifest.json. Everything in this section is
# UNCONDITIONAL (pure source-tree/artifact/JSON work, no toolchain, no
# browser) EXCEPT V6, which needs the real browser run and therefore lives
# on the existing BROWSER axis down in the checks-7/8 section -- skipped
# through skip() so the TOTAL never changes. NO NEW SKIP AXIS: M2's ruling
# stands (one fewer switch is one fewer route to result=complete without
# having checked), and the two existing axes are the only two.
# ===========================================================================

# --- V1: the frozen ceiling CONSTANT itself -------------------------------
# Check 13 above already fails when the artifact is over the ceiling; this
# asserts the CONSTANT, in this script's own source, so a silent raise is
# caught even while the artifact still fits under the raised value (the
# exact scenario in which check 13 stays green and nobody notices). Three
# conditions: the live value is 1000000, the source contains exactly one
# assignment line, and that line is literally WASM_GZIP_CEILING_BYTES=1000000.
V1_LABEL="WASM_GZIP_CEILING_BYTES is literally 1000000 (the frozen constant asserted in this script's own source; the artifact-under-ceiling half is check 13 above)"
CEILING_ASSIGN_COUNT="$(grep -c '^WASM_GZIP_CEILING_BYTES=' "${BASH_SOURCE[0]}" || true)"
if [ "$WASM_GZIP_CEILING_BYTES" -eq 1000000 ] \
   && [ "$CEILING_ASSIGN_COUNT" -eq 1 ] \
   && grep -qx 'WASM_GZIP_CEILING_BYTES=1000000' "${BASH_SOURCE[0]}"; then
  ok "$V1_LABEL"
else
  fail "$V1_LABEL (observed: live value=$WASM_GZIP_CEILING_BYTES, assignment lines matching ^WASM_GZIP_CEILING_BYTES==$CEILING_ASSIGN_COUNT -- the frozen ceiling was moved; that is a coordinator decision, never a task's)"
fi

# --- V2: the M5 task-local budget ceiling (BUDGET WINDOW re-scoped by ------
# the coordinator's 2026-08-08 ruling, recorded in briefs/M5-budget.json) --
# briefs/M4-budget.json's task_local_ceiling_bytes (932,713 = m3_final +
# m4_budget) was an M4-SCOPED construct; M4 closed at m4_final = 927,008
# gzip, and the M4 budget's 60,000-byte reserve was held under the frozen
# 1,000,000 ceiling explicitly FOR M5's polish. The M5 window is therefore
# task_local_ceiling_bytes = m4_final + m5_reserve = 987,008 -- without
# this re-point, the M5 tree (932,087, 626 bytes under the old M4 ceiling)
# would false-block the a11y pass. V2 measures the artifact at --dir
# against the M5 window and prints the delta from m4_final so growth
# across the M5 waves stays visible in every log. briefs/M4-budget.json is
# preserved UNCHANGED as the M4 historical record -- V8 below still checks
# its internal arithmetic. As before: THE SHIPPING ARTIFACT IS
# build-site.sh --optimize's OUTPUT (PLAN.md "Size ruling" + its
# 2026-08-07 amendment: wasm-opt --detect-features -Oz --converge); a
# plain unoptimized build correctly fails both check 13 and this check,
# because that artifact is not what ships.
#
# M5 final-review fix (briefs/M5-codex-final1.json, finding M5-R1-2): V2
# and V8 used to READ m4_final/m5_reserve/task_local_ceiling from the
# mutable briefs/M5-budget.json -- so the budget file could raise its own
# authorized reserve (e.g. reserve 72,992 + ceiling 1,000,000 keeps the
# formula true and everything green while the coordinator-authorized M5
# ceiling silently grew by 12,992 bytes). The ruling's three numbers are
# therefore PINNED HERE AS LITERALS, in the same frozen-constant style as
# WASM_GZIP_CEILING_BYTES above: COORDINATOR-RULING CONSTANTS (2026-08-08
# M5 re-scope ruling) -- moving ANY of them is a coordinator decision,
# never a task's, and now requires a visible edit to this script instead
# of an edit to the JSON the checks were supposed to be constraining.
# briefs/M5-budget.json remains the human-readable RECORD of the ruling;
# V8 below asserts that record MATCHES these pins exactly, so a doctored
# file fails even when it is internally consistent.
# M6 W1 NOTE (briefs/M6-plan.md, ruling 6 + W1): these three remain the
# M5 HISTORICAL-RECORD pins -- V8 still asserts briefs/M5-budget.json
# matches them exactly, and V2 keeps the M5 task ceiling as a (now loose)
# outer bound under the frozen 1,000,000. The corpus-externalization
# re-baseline moved the CURRENT fresh-artifact honesty window to the M6
# pins below (M6_M5_FINAL/M6_SHRINK_MIN + briefs/M6-budget.json): after
# W1 the shipping artifact sits ~73K gzip BELOW the recorded M5 close ON
# PURPOSE, so V8's old fresh-in-[m4_final-3000, m5_ceiling] clause was
# retired (it described the M5 window, which closed at 933,305) and its
# job is done by the M6 budget check.
M5_M4_FINAL=927008
M5_RESERVE=60000
M5_TASK_CEILING=987008
M4_BUDGET_JSON="$REPO_ROOT/briefs/M4-budget.json"
M5_BUDGET_JSON="$REPO_ROOT/briefs/M5-budget.json"
V2_LABEL="app.wasm gzip is under the PINNED M5 task-local ceiling M5_TASK_CEILING=987008 (= pinned m4_final 927008 + pinned m5_reserve 60000, coordinator-ruling constants in this script's own source -- briefs/M5-budget.json only RECORDS them, V8 asserts it matches; the shipping artifact is build-site.sh --optimize's output per PLAN.md's Size ruling)"
if [ -f "$WASM_FILE" ]; then
  M5_DELTA=$((WASM_GZIP_BYTES - M5_M4_FINAL))
  info "M5 budget: app.wasm gzip observed=$WASM_GZIP_BYTES bytes; pinned task ceiling=$M5_TASK_CEILING; delta from pinned m4_final ($M5_M4_FINAL) = $M5_DELTA bytes"
  if [ "$WASM_GZIP_BYTES" -le "$M5_TASK_CEILING" ]; then
    ok "$V2_LABEL (observed: $WASM_GZIP_BYTES of $M5_TASK_CEILING bytes; delta from pinned m4_final=$M5_M4_FINAL is $M5_DELTA bytes; headroom $((M5_TASK_CEILING - WASM_GZIP_BYTES)) bytes)"
  else
    fail "$V2_LABEL (observed: $WASM_GZIP_BYTES bytes, OVER the pinned M5_TASK_CEILING=$M5_TASK_CEILING by $((WASM_GZIP_BYTES - M5_TASK_CEILING)) bytes; delta from pinned m4_final=$M5_M4_FINAL is $M5_DELTA bytes)"
  fi
else
  fail "$V2_LABEL (observed: app.wasm missing)"
fi

# --- V8: both budget files cohere (M5 re-scope, same 2026-08-08 ruling ----
# as V2's) -- the M5 window is internally consistent AND the M4 record ----
# still stands ------------------------------------------------------------
# The fresh measurement, like V2's, is of the OPTIMIZED shipping artifact
# at --dir:
#   (a0) M5 (final-review fix, briefs/M5-codex-final1.json M5-R1-2): the
#       file's m4_final_gzip_bytes, m5_reserve_bytes and
#       task_local_ceiling_bytes must EQUAL the coordinator-ruling
#       literals pinned above (M5_M4_FINAL/M5_RESERVE/M5_TASK_CEILING) --
#       an internally consistent but doctored file (e.g. reserve 70000,
#       ceiling 997008) fails HERE, on the literal mismatch;
#   (a) M5: task_local_ceiling_bytes is exactly m4_final_gzip_bytes +
#       m5_reserve_bytes -- a doctored ceiling cannot license anything
#       the formula does not;
#   (b) M5: ceiling_bytes is the frozen 1000000 (the outer tripwire,
#       V1/check 13 -- the budget file may not pretend otherwise);
#   (c) M5: the freshly measured artifact sits in
#       [m4_final - 3000, task_local_ceiling_bytes]: an artifact more
#       than the variance window BELOW the recorded M4 close proves the
#       recorded baseline never described this pipeline/tree (stale-high
#       budget); one above the task ceiling is over-licensed (stale-low
#       budget). m5_entry_gzip_bytes is a FIXED historical record of the
#       reader-debt-wave tree and is deliberately NOT re-measured against
#       the fresh artifact -- later M5 waves lawfully move away from it;
#   (d) M4: briefs/M4-budget.json still exists and its own internal
#       arithmetic still holds (authorised:true; task_local_ceiling_bytes
#       == min(940000, m3_final+m4_budget); ceiling_bytes==1000000;
#       |m3_final - second_build| <= 3000) -- the M4 HISTORICAL RECORD is
#       preserved unchanged, but the fresh artifact is judged against the
#       M5 window in (c), not against the M3 baseline (that was V8's old
#       clause (d), retired by the re-scope ruling: the M5 tree sat 626
#       bytes under the M4-scoped ceiling and would have false-blocked
#       the a11y pass).
V8_LABEL="briefs/M5-budget.json MATCHES the pinned coordinator-ruling constants (m4_final==927008, m5_reserve==60000, task_local_ceiling==987008 -- M5-R1-2: a doctored file fails even when internally consistent) and coheres (task_local_ceiling_bytes == m4_final + m5_reserve; ceiling_bytes==1000000) and briefs/M4-budget.json still stands as the M4 historical record (authorised:true; task_local == min(940000, m3_final+m4_budget); ceiling_bytes==1000000; |m3_final - second_build| <= 3000) -- the FRESH artifact's own window moved to the M6 budget check (corpus-externalization re-baseline)"
if [ -f "$M5_BUDGET_JSON" ] && [ -f "$M4_BUDGET_JSON" ] && [ -f "$WASM_FILE" ] && command -v python3 >/dev/null 2>&1; then
  V8_OUT="$(python3 -c '
import json, sys
try:
    m5 = json.load(open(sys.argv[1], encoding="utf-8"))
    m4 = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception as e:
    print("FAIL could not parse a budget file: %s" % e)
    raise SystemExit
observed = int(sys.argv[3])
pin_final, pin_res, pin_task = int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
problems = []
try:
    m5_task = int(m5["task_local_ceiling_bytes"])
    m5_final = int(m5["m4_final_gzip_bytes"])
    m5_res = int(m5["m5_reserve_bytes"])
    m5_ceil = int(m5["ceiling_bytes"])
    if m5_final != pin_final:
        problems.append("M5-budget.json m4_final_gzip_bytes=%d does not match the pinned coordinator ruling M5_M4_FINAL=%d -- the record was doctored" % (m5_final, pin_final))
    if m5_res != pin_res:
        problems.append("M5-budget.json m5_reserve_bytes=%d does not match the pinned coordinator ruling M5_RESERVE=%d -- the budget file may not raise its own authorized reserve" % (m5_res, pin_res))
    if m5_task != pin_task:
        problems.append("M5-budget.json task_local_ceiling_bytes=%d does not match the pinned coordinator ruling M5_TASK_CEILING=%d -- the record was doctored" % (m5_task, pin_task))
    want = m5_final + m5_res
    if m5_task != want:
        problems.append("M5 task_local_ceiling_bytes=%d is not m4_final+m5_reserve=%d" % (m5_task, want))
    if m5_ceil != 1000000:
        problems.append("M5 ceiling_bytes=%d, not the frozen 1000000" % m5_ceil)
    # M6 W1: the fresh-artifact-in-M5-window clauses (observed >=
    # m4_final-3000, observed <= m5_task) are RETIRED -- the M5 window is
    # a closed historical record now, and the externalized corpus puts
    # the current artifact deliberately far below it. The fresh-artifact
    # honesty window is asserted by the M6 budget check
    # (briefs/M6-budget.json vs the M6_* pins), never silently unchecked.
except KeyError as e:
    problems.append("M5-budget.json is missing field %s" % e)
try:
    m4_task = int(m4["task_local_ceiling_bytes"])
    m4_m3 = int(m4["m3_final_gzip_bytes"])
    m4_b = int(m4["m4_budget_bytes"])
    m4_second = int(m4["second_build_gzip_bytes"])
    m4_ceil = int(m4["ceiling_bytes"])
    if m4.get("authorised") is not True:
        problems.append("M4 authorised is %r, not true" % m4.get("authorised"))
    if m4_ceil != 1000000:
        problems.append("M4 ceiling_bytes=%d, not the frozen 1000000" % m4_ceil)
    m4_want = min(940000, m4_m3 + m4_b)
    if m4_task != m4_want:
        problems.append("M4 task_local_ceiling_bytes=%d is not min(940000, m3_final+m4_budget)=%d -- the historical record was edited" % (m4_task, m4_want))
    if abs(m4_m3 - m4_second) > 3000:
        problems.append("M4 |m3_final(%d) - second_build(%d)| = %d exceeds the 3000-byte variance window -- the historical record was edited" % (m4_m3, m4_second, abs(m4_m3 - m4_second)))
except KeyError as e:
    problems.append("M4-budget.json is missing field %s" % e)
if problems:
    print("FAIL " + "; ".join(problems))
else:
    print("OK M5 record matches the pinned ruling (m4_final=%d, reserve=%d, task ceiling=%d), formula holds (task ceiling %d = %d+%d, ceiling_bytes=1000000); fresh gzip %d is judged by the M6 budget check; M4 record intact (task ceiling %d = min(940000, %d+%d), authorised, variance |%d-%d|<=3000)"
          % (pin_final, pin_res, pin_task, m5_task, m5_final, m5_res, observed,
             m4_task, m4_m3, m4_b, m4_m3, m4_second))
' "$M5_BUDGET_JSON" "$M4_BUDGET_JSON" "$WASM_GZIP_BYTES" "$M5_M4_FINAL" "$M5_RESERVE" "$M5_TASK_CEILING" 2>&1)" || true
  case "$V8_OUT" in
    "OK "*) ok "$V8_LABEL (${V8_OUT#OK })" ;;
    *)      fail "$V8_LABEL (observed: ${V8_OUT#FAIL })" ;;
  esac
else
  fail "$V8_LABEL (observed: briefs/M5-budget.json or briefs/M4-budget.json missing, python3 missing, or app.wasm missing)"
fi

# ===========================================================================
# M6 W1 (briefs/M6-plan.md, rulings 1/6 + wave W1): CORPUS-EXTERNALIZATION
# RE-BASELINE + CONTENT-BUNDLE LEDGER. The exercise corpus moved OUT of
# app.wasm into per-language bundles (site/public/content/content.{en,ja}
# .txt, emitted by build-site.sh step 7b via scripts/emit-content-
# bundles.py and loaded at boot by site/static/index.js +
# site/app/Exercises/Bundle.hs). Everything here is unconditional (pure
# artifact/file/python work, no toolchain, no browser); the behavioral
# half -- the fetch-failure degradation stage -- lives on the browser
# axis below.
#
# COORDINATOR-RULING CONSTANTS (2026-08-08 M6 plan, ruling 6; pinned here
# per the M5-R1-2 pattern -- the mutable briefs/M6-budget.json may not
# authorize its own numbers, this script's literals are what it must
# MATCH):
#   M6_BUNDLE_CEILING  the hard ceiling on gzip(content.en.txt) +
#                      gzip(content.ja.txt) COMBINED: 300,000 bytes
#                      ("Content bundles get their OWN ledger line and
#                      ceiling: 300,000 gzip bytes combined (en+ja),
#                      asserted by check-site" -- ruling 6). W1 measures
#                      ~153K combined (the ja bundle is the EN fallback
#                      until wave 3 fills the ja: fields; wave 3's real
#                      Japanese text compresses independently, hence the
#                      2x headroom).
#   M6_M5_FINAL        gzip of the M5-final shipping artifact -- 933,305
#                      bytes, the pre-externalization baseline the
#                      re-baseline is measured against (briefs/
#                      M6-plan.md ruling 1: "933,305 today").
#   M6_SHRINK_MIN      the externalization must have RESTORED at least
#                      this much wasm-ceiling headroom: m6_entry <=
#                      m5_final - 50,000 (ruling 1 expected "roughly
#                      -100K gzip"; measured -73,560 on this tree -- the
#                      pin is a deliberate floor under the measurement,
#                      not a target).
# Moving ANY of these is a coordinator decision, never a task's.
# ===========================================================================
M6_BUNDLE_CEILING=300000
M6_M5_FINAL=933305
M6_SHRINK_MIN=50000
M6_BUDGET_JSON="$REPO_ROOT/briefs/M6-budget.json"

# --- M6-a: the bundle-ceiling CONSTANT itself (the V1 pattern) ------------
M6A_LABEL="M6_BUNDLE_CEILING is literally 300000 (the combined en+ja bundle-gzip ceiling, coordinator-ruling constant asserted in this script's own source; the artifact half is the bundle ledger check below)"
M6_CEILING_ASSIGN_COUNT="$(grep -c '^M6_BUNDLE_CEILING=' "${BASH_SOURCE[0]}" || true)"
if [ "$M6_BUNDLE_CEILING" -eq 300000 ] \
   && [ "$M6_CEILING_ASSIGN_COUNT" -eq 1 ] \
   && grep -qx 'M6_BUNDLE_CEILING=300000' "${BASH_SOURCE[0]}"; then
  ok "$M6A_LABEL"
else
  fail "$M6A_LABEL (observed: live value=$M6_BUNDLE_CEILING, assignment lines matching ^M6_BUNDLE_CEILING==$M6_CEILING_ASSIGN_COUNT -- the bundle ceiling was moved; that is a coordinator decision, never a task's)"
fi

# --- M6-b: THE BUNDLE LEDGER + the combined-gzip ceiling ------------------
# The wasm size ledger's sibling: both bundle gzips are measured and
# RECORDED on every run (state/bundle-ledger.tsv), and -- unlike the wasm
# ledger's advisory projection -- the combined number is a HARD gate
# against M6_BUNDLE_CEILING (ruling 6 says "asserted by check-site").
BUNDLE_EN_FILE="$DIR/content/content.en.txt"
BUNDLE_JA_FILE="$DIR/content/content.ja.txt"
BUNDLE_LEDGER_FILE="$REPO_ROOT/state/bundle-ledger.tsv"
M6B_LABEL="content bundles: combined gzip(content.en.txt)+gzip(content.ja.txt) is under the M6_BUNDLE_CEILING=$M6_BUNDLE_CEILING byte ceiling, recorded to state/bundle-ledger.tsv"
if [ -f "$BUNDLE_EN_FILE" ] && [ -f "$BUNDLE_JA_FILE" ]; then
  BUNDLE_EN_GZIP="$(gzip -c "$BUNDLE_EN_FILE" | wc -c | tr -d ' ')"
  BUNDLE_JA_GZIP="$(gzip -c "$BUNDLE_JA_FILE" | wc -c | tr -d ' ')"
  BUNDLE_COMBINED_GZIP=$((BUNDLE_EN_GZIP + BUNDLE_JA_GZIP))
  BUNDLE_HEADROOM=$((M6_BUNDLE_CEILING - BUNDLE_COMBINED_GZIP))
  mkdir -p "$REPO_ROOT/state"
  if [ ! -f "$BUNDLE_LEDGER_FILE" ]; then
    printf 'timestamp\ten_gzip_bytes\tja_gzip_bytes\tcombined_gzip_bytes\tceiling_bytes\theadroom_bytes\n' > "$BUNDLE_LEDGER_FILE"
  fi
  printf '%s\t%d\t%d\t%d\t%d\t%d\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$BUNDLE_EN_GZIP" "$BUNDLE_JA_GZIP" \
    "$BUNDLE_COMBINED_GZIP" "$M6_BUNDLE_CEILING" "$BUNDLE_HEADROOM" >> "$BUNDLE_LEDGER_FILE"
  info "bundle ledger: content.en.txt gzip=$BUNDLE_EN_GZIP, content.ja.txt gzip=$BUNDLE_JA_GZIP, combined=$BUNDLE_COMBINED_GZIP; ceiling=$M6_BUNDLE_CEILING; headroom=$BUNDLE_HEADROOM"
  if [ "$BUNDLE_COMBINED_GZIP" -lt "$M6_BUNDLE_CEILING" ]; then
    ok "$M6B_LABEL (observed: en=$BUNDLE_EN_GZIP + ja=$BUNDLE_JA_GZIP = $BUNDLE_COMBINED_GZIP bytes, headroom $BUNDLE_HEADROOM)"
  else
    fail "$M6B_LABEL (observed: en=$BUNDLE_EN_GZIP + ja=$BUNDLE_JA_GZIP = $BUNDLE_COMBINED_GZIP bytes, OVER by $((BUNDLE_COMBINED_GZIP - M6_BUNDLE_CEILING)) bytes)"
  fi
else
  fail "$M6B_LABEL (observed: $DIR/content/content.en.txt or content.ja.txt missing -- run ./scripts/build-site.sh first)"
fi

# --- M6-c/M6-d: BUNDLE FRESHNESS (the exact-bytes discipline) -------------
# A fresh emission from content/exercises/ (the same
# scripts/emit-content-bundles.py build-site runs) must byte-match what
# is actually shipping at --dir -- this is the bundle counterpart of
# check 12's --dump-source exact-bytes comparison: a deck edited (or a
# ja: variant added) without re-running build-site turns this red
# instead of silently shipping a stale bundle. Emitter CORRECTNESS is
# separately cross-checked by the browser stages (#sxc1-exercise-stats,
# computed by the app from the FETCHED bundle, must match the harness's
# independent disk-derived numbers -- checks 16/17).
BUNDLE_FRESH_TMP="$(mktemp -d -t sxc1-check-site-bundles.XXXXXX)"
register_temp_dir "$BUNDLE_FRESH_TMP"
BUNDLE_EMIT_OUT="$(python3 "$REPO_ROOT/scripts/emit-content-bundles.py" \
  --exercises-dir "$REPO_ROOT/content/exercises" --out-dir "$BUNDLE_FRESH_TMP" 2>&1)" || BUNDLE_EMIT_OUT="EMIT-FAILED: $BUNDLE_EMIT_OUT"
for lang in en ja; do
  M6F_LABEL="bundle freshness/content.$lang.txt ($DIR/content/content.$lang.txt is byte-identical to a fresh scripts/emit-content-bundles.py emission from content/exercises/)"
  case "$BUNDLE_EMIT_OUT" in
    EMIT-FAILED:*)
      fail "$M6F_LABEL (observed: fresh emission failed -- ${BUNDLE_EMIT_OUT#EMIT-FAILED: })"
      ;;
    *)
      if [ -f "$DIR/content/content.$lang.txt" ] && cmp -s "$BUNDLE_FRESH_TMP/content.$lang.txt" "$DIR/content/content.$lang.txt"; then
        ok "$M6F_LABEL"
      else
        fail "$M6F_LABEL (observed: shipped bundle diverges from a fresh emission -- stale bundle, or content/exercises edited without rebuilding)"
      fi
      ;;
  esac
done
rm -rf "$BUNDLE_FRESH_TMP"
unregister_temp_dir "$BUNDLE_FRESH_TMP"

# --- M6-e: THE WASM-SHRINK RE-BASELINE (briefs/M6-budget.json) ------------
# The M5-R1-2 pattern applied to the M6 record: the file must MATCH the
# pins (a doctored file fails even when internally consistent), the
# recorded m6_entry must show the externalization actually restored the
# ceiling headroom (m6_entry <= m5_final - M6_SHRINK_MIN), and the FRESH
# artifact must sit inside the M6 window [m6_entry - 3000,
# WASM_GZIP_CEILING): the lower bound is baseline honesty (an artifact
# far below the recorded entry means the record never described this
# pipeline/tree), the upper bound stays the one frozen ceiling (ruling
# 6: no new task-local wasm ceiling was granted for M6 -- later M6
# waves' JA UI strings lawfully grow the artifact above m6_entry, under
# the frozen 1,000,000).
M6E_LABEL="briefs/M6-budget.json MATCHES the pinned M6 re-baseline (m5_final==933305, ceiling==1000000, bundle_ceiling==$M6_BUNDLE_CEILING; m6_entry <= m5_final - M6_SHRINK_MIN=$M6_SHRINK_MIN -- the externalization really shrank the wasm) and its recorded M6-FINAL figures describe THIS tree (artifact gzip in [m6_entry-3000, 1000000) and within 3000 of m6_final; recorded en+ja bundle gzips self-consistent, under the bundle ceiling and within 3000 of the live measurement)"
if [ -f "$M6_BUDGET_JSON" ] && [ -f "$WASM_FILE" ] && command -v python3 >/dev/null 2>&1; then
  M6E_OUT="$(python3 -c '
import json, sys
try:
    m6 = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    print("FAIL could not parse briefs/M6-budget.json: %s" % e)
    raise SystemExit
observed = int(sys.argv[2])
pin_m5_final, pin_shrink, pin_ceiling = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
pin_bundle_ceiling = int(sys.argv[6])
# live bundle gzips, or -1/-1 when the bundles were missing (M6-b
# already failed loudly in that case; this check then skips only the
# bundle COMPARISON, never the pin checks).
live_en, live_ja = int(sys.argv[7]), int(sys.argv[8])
problems = []
try:
    m5_final = int(m6["m5_final_gzip_bytes"])
    m6_entry = int(m6["m6_entry_gzip_bytes"])
    m6_final = int(m6["m6_final_gzip_bytes"])
    ceiling = int(m6["ceiling_bytes"])
    bundle_ceiling = int(m6["bundle_ceiling_bytes"])
    b_en = int(m6["bundle_en_gzip_bytes"])
    b_ja = int(m6["bundle_ja_gzip_bytes"])
    b_combined = int(m6["bundle_combined_gzip_bytes"])
    if m5_final != pin_m5_final:
        problems.append("m5_final_gzip_bytes=%d does not match the pinned M6_M5_FINAL=%d -- the record was doctored" % (m5_final, pin_m5_final))
    if ceiling != pin_ceiling:
        problems.append("ceiling_bytes=%d, not the frozen %d" % (ceiling, pin_ceiling))
    if bundle_ceiling != pin_bundle_ceiling:
        problems.append("bundle_ceiling_bytes=%d does not match the pinned M6_BUNDLE_CEILING=%d -- raising a ceiling is a visible check-site.sh edit, never a budget-file edit" % (bundle_ceiling, pin_bundle_ceiling))
    if m6_entry > m5_final - pin_shrink:
        problems.append("m6_entry_gzip_bytes=%d did not shrink by at least M6_SHRINK_MIN=%d from m5_final=%d (the externalization is not doing its job)" % (m6_entry, pin_shrink, m5_final))
    if observed < m6_entry - 3000:
        problems.append("fresh artifact gzip=%d is %d bytes BELOW the recorded m6_entry=%d (beyond the 3000-byte window) -- the recorded re-baseline never described this pipeline/tree" % (observed, m6_entry - observed, m6_entry))
    if observed >= pin_ceiling:
        problems.append("fresh artifact gzip=%d is at/over the frozen ceiling %d" % (observed, pin_ceiling))
    if abs(observed - m6_final) > 3000:
        problems.append("fresh artifact gzip=%d is %d bytes from the recorded m6_final_gzip_bytes=%d (beyond the 3000-byte window) -- re-measure and update briefs/M6-budget.json" % (observed, observed - m6_final, m6_final))
    if b_en + b_ja != b_combined:
        problems.append("bundle_combined_gzip_bytes=%d is not bundle_en_gzip_bytes=%d + bundle_ja_gzip_bytes=%d" % (b_combined, b_en, b_ja))
    if b_combined >= bundle_ceiling:
        problems.append("recorded bundle_combined_gzip_bytes=%d is at/over the bundle ceiling %d" % (b_combined, bundle_ceiling))
    if live_en >= 0 and live_ja >= 0:
        live_combined = live_en + live_ja
        if abs(live_combined - b_combined) > 3000:
            problems.append("live combined bundle gzip=%d (en=%d + ja=%d) is %d bytes from the recorded %d (beyond the 3000-byte window) -- re-measure and update briefs/M6-budget.json" % (live_combined, live_en, live_ja, live_combined - b_combined, b_combined))
except KeyError as e:
    problems.append("briefs/M6-budget.json is missing field %s" % e)
if problems:
    print("FAIL " + "; ".join(problems))
else:
    print("OK m5_final=%d, m6_entry=%d (shrink %d >= %d), m6_final=%d, fresh gzip %d in [%d, %d); bundles en=%d + ja=%d = %d of %d; ceiling headroom %d bytes"
          % (m5_final, m6_entry, m5_final - m6_entry, pin_shrink, m6_final, observed, m6_entry - 3000, pin_ceiling, b_en, b_ja, b_combined, bundle_ceiling, pin_ceiling - observed))
' "$M6_BUDGET_JSON" "$WASM_GZIP_BYTES" "$M6_M5_FINAL" "$M6_SHRINK_MIN" "$WASM_GZIP_CEILING_BYTES" \
  "$M6_BUNDLE_CEILING" "${BUNDLE_EN_GZIP:--1}" "${BUNDLE_JA_GZIP:--1}" 2>&1)" || true
  case "$M6E_OUT" in
    "OK "*) ok "$M6E_LABEL (${M6E_OUT#OK })" ;;
    *)      fail "$M6E_LABEL (observed: ${M6E_OUT#FAIL })" ;;
  esac
else
  fail "$M6E_LABEL (observed: briefs/M6-budget.json missing, app.wasm missing, or python3 missing)"
fi

# --- V3: the harness fake exists and carries its whole driver surface -----
# scripts/fake-midi.js is the committed, reviewable fake behind the D1..D27
# browser assertions. It must exist, parse, and name every driver member
# the sabotage sweep depends on -- a fake that silently lost setOutcome or
# emit would turn the whole device suite vacuous.
V3_LABEL="scripts/fake-midi.js exists, parses under node --check, and names every driver member (calls setOutcome addPort removePort emit subscribedCount ports)"
FAKE_MIDI_SRC="$REPO_ROOT/scripts/fake-midi.js"
if [ -f "$FAKE_MIDI_SRC" ] && "$NODE" --check "$FAKE_MIDI_SRC" >/dev/null 2>&1; then
  FAKE_MIDI_MISSING=""
  for member in calls setOutcome addPort removePort emit subscribedCount ports; do
    if ! grep -Eq "(^|[^A-Za-z0-9_])${member}([^A-Za-z0-9_]|\$)" "$FAKE_MIDI_SRC"; then
      FAKE_MIDI_MISSING="$FAKE_MIDI_MISSING $member"
    fi
  done
  if [ -z "$FAKE_MIDI_MISSING" ]; then
    ok "$V3_LABEL"
  else
    fail "$V3_LABEL (observed: member(s) not found:$FAKE_MIDI_MISSING)"
  fi
else
  fail "$V3_LABEL (observed: missing, or node --check rejected it)"
fi

# --- V4: the harness fake is never shipped --------------------------------
# The fake exists to be INJECTED by the harness (CDP
# Page.addScriptToEvaluateOnNewDocument); a copy inside the shipped bundle
# would let the app grant itself a fake MIDI device in production.
# Checked under the directory being verified AND the canonical
# site/public + site/static, so a --dir pointed elsewhere still guards
# the real tree. browser-check.mjs's D22 asserts the same property from
# the browser side; this is the host-side half that still runs when the
# browser axis is skipped.
V4_LABEL="harness fake never shipped: no fake-midi.js under the checked dir, site/public or site/static"
FAKE_SHIPPED="$(find "$DIR" "$REPO_ROOT/site/public" "$REPO_ROOT/site/static" -name 'fake-midi.js' -print 2>/dev/null | sort -u | tr '\n' ' ')"
if [ -z "${FAKE_SHIPPED// /}" ]; then
  ok "$V4_LABEL"
else
  fail "$V4_LABEL (observed: $FAKE_SHIPPED)"
fi

# --- V5: the seven M4 structural invariants over site/app -----------------
# briefs/M4-plan.md section 5, all anchored to NON-COMMENT lines (M0
# finding n2: a grep a comment can satisfy -- or defeat -- proves
# nothing). Same naive first-'--' line-comment strip as checks 14 and the
# storage guard above, valid here for the same measured reason: none of
# these identifiers appears after a literal '--' inside a string, nor
# inside a {- -} block comment, anywhere in site/app. The storage grep is
# CASE-INSENSITIVE because Miso's API surface is setLocalStorage (M2's
# recorded lesson). The SXC1.Midi.Table reachability check walks the real
# import graph from site/app/Main.hs and carries its own anti-vacuity
# anchor: SXC1.Midi.Spec MUST be in the closure and Table.hs MUST exist
# on disk, so a broken traversal or a renamed module fails loudly instead
# of checking nothing.
M4_INVARIANTS_PY="$(mktemp -t sxc1-check-site-m4inv.XXXXXX.py)"
register_temp_file "$M4_INVARIANTS_PY"
cat > "$M4_INVARIANTS_PY" <<'PYEOF'
import os
import re
import sys

APP = sys.argv[1]   # <repo>/site/app
SRC = sys.argv[2]   # <repo>/site/src


def hs_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in sorted(filenames):
            if fn.endswith(".hs"):
                yield os.path.join(dirpath, fn)


def noncomment(path):
    with open(path, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            if code.strip():
                yield i, code


def rel(path):
    return os.path.relpath(path, os.path.dirname(os.path.dirname(APP)))


def scan(root, needles, lower=False):
    hits = []
    for path in hs_files(root):
        for i, code in noncomment(path):
            hay = code.lower() if lower else code
            for n in needles:
                if n in hay:
                    hits.append((path, i, n))
    return hits

# 1. requestMIDIAccess: exactly one non-comment occurrence, in the bridge.
req = scan(APP, ["requestMIDIAccess"])
if len(req) == 1 and req[0][0].endswith(os.path.join("Device", "Midi.hs")):
    print("REQMIDI OK exactly one non-comment occurrence, %s:%d" % (rel(req[0][0]), req[0][1]))
else:
    print("REQMIDI FAIL want exactly one non-comment occurrence inside site/app/Device/Midi.hs, observed %d: %s"
          % (len(req), "; ".join("%s:%d" % (rel(p), i) for p, i, _ in req) or "<none>"))

# 2. sysex: exactly once, as False, in the bridge.
sy = scan(APP, ["sysex"], lower=True)
sy_ok = (len(sy) == 1
         and sy[0][0].endswith(os.path.join("Device", "Midi.hs")))
if sy_ok:
    _, ln, _ = sy[0]
    code = [c for i, c in noncomment(sy[0][0]) if i == ln][0]
    sy_ok = "False" in code
if sy_ok:
    print("SYSEX OK exactly one non-comment occurrence, carrying False, %s:%d" % (rel(sy[0][0]), sy[0][1]))
else:
    print("SYSEX FAIL want exactly one non-comment occurrence in site/app/Device/Midi.hs with False on the same line, observed %d: %s"
          % (len(sy), "; ".join("%s:%d" % (rel(p), i) for p, i, _ in sy) or "<none>"))

# 3. No storage under site/app/Device/ (case-insensitive).
st = scan(os.path.join(APP, "Device"), ["localstorage", "sessionstorage", "miso.storage"], lower=True)
if not st:
    print("DEVSTORAGE OK no localStorage/sessionStorage/Miso.Storage on non-comment lines under site/app/Device/ (case-insensitive)")
else:
    print("DEVSTORAGE FAIL storage reached from site/app/Device/: %s"
          % "; ".join("%s:%d (%s)" % (rel(p), i, n) for p, i, n in st))

# 4. No network egress anywhere in site/app.
net = scan(APP, ["fetch", "getJSON", "postJSON", "sendBeacon", "WebSocket"])
if not net:
    print("NETWORK OK no fetch/getJSON/postJSON/sendBeacon/WebSocket on non-comment lines in site/app")
else:
    print("NETWORK FAIL network egress identifiers on non-comment lines: %s"
          % "; ".join("%s:%d (%s)" % (rel(p), i, n) for p, i, n in net))

# 5. The M2 stub is gone.
stub = scan(APP, ["noDeviceVerifier"])
if not stub:
    print("NODEVSTUB OK noDeviceVerifier has zero non-comment occurrences in site/app (M2's stub did not survive M4)")
else:
    print("NODEVSTUB FAIL noDeviceVerifier still present: %s"
          % "; ".join("%s:%d" % (rel(p), i) for p, i, _ in stub))

# 6. dvWatch is defined in the bridge AND called outside it.
dv = scan(APP, ["dvWatch"])
dv_in = [h for h in dv if h[0].endswith(os.path.join("Device", "Midi.hs"))]
dv_out = [h for h in dv if not h[0].endswith(os.path.join("Device", "Midi.hs"))]
if dv_in and dv_out:
    print("DVWATCH OK defined in Device/Midi.hs (%d occurrence(s)) and called outside it (%s)"
          % (len(dv_in), "; ".join("%s:%d" % (rel(p), i) for p, i, _ in dv_out)))
else:
    print("DVWATCH FAIL want dvWatch on non-comment lines both inside Device/Midi.hs and outside it (a real call site); observed inside=%d outside=%d"
          % (len(dv_in), len(dv_out)))

# 7. SXC1.Midi.Table is not reachable from exe:app's import graph.
module_map = {}
for root in (APP, SRC):
    for path in hs_files(root):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^module\s+([A-Za-z][A-Za-z0-9_.']*)", line)
                if m:
                    module_map[m.group(1)] = path
                    break

IMPORT_RE = re.compile(r"^import\s+(?:qualified\s+)?([A-Za-z][A-Za-z0-9_.']*)")
main_path = os.path.join(APP, "Main.hs")
queue = [main_path]
seen_files = set()
reached = set()
while queue:
    path = queue.pop()
    if path in seen_files or not os.path.isfile(path):
        continue
    seen_files.add(path)
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            m = IMPORT_RE.match(line)
            if not m:
                continue
            name = m.group(1)
            reached.add(name)
            target = module_map.get(name)
            if target is not None and target not in seen_files:
                queue.append(target)

table_on_disk = os.path.isfile(os.path.join(SRC, "SXC1", "Midi", "Table.hs"))
problems = []
if not os.path.isfile(main_path):
    problems.append("site/app/Main.hs missing")
if not table_on_disk:
    problems.append("site/src/SXC1/Midi/Table.hs missing (anti-vacuity anchor: the module this check exists to fence off must exist)")
if "SXC1.Midi.Spec" not in reached:
    problems.append("SXC1.Midi.Spec NOT in exe:app's import closure (anti-vacuity anchor: the traversal is broken or the device bridge lost its pure layer)")
if "SXC1.Midi.Table" in reached:
    problems.append("SXC1.Midi.Table IS reachable from exe:app (the parse-at-startup table belongs to the checkers, never the app)")
if problems:
    print("TABLEREACH FAIL " + "; ".join(problems))
else:
    print("TABLEREACH OK SXC1.Midi.Table unreachable from site/app/Main.hs's import closure (%d modules reached, incl. the SXC1.Midi.Spec anchor; Table.hs present on disk)" % len(reached))
PYEOF

m4_invariant_label() {
  case "$1" in
    REQMIDI)    echo "m4-invariants/requestMIDIAccess-single-call-site (exactly one non-comment occurrence in site/app, inside Device/Midi.hs)" ;;
    SYSEX)      echo "m4-invariants/sysex-false-only (exactly one non-comment occurrence in site/app, carrying False, in Device/Midi.hs)" ;;
    DEVSTORAGE) echo "m4-invariants/device-no-storage (no localStorage/sessionStorage/Miso.Storage, case-insensitive, on non-comment lines under site/app/Device/)" ;;
    NETWORK)    echo "m4-invariants/no-network-egress (no fetch/getJSON/postJSON/sendBeacon/WebSocket on non-comment lines in site/app -- MIDI bytes never leave the browser)" ;;
    NODEVSTUB)  echo "m4-invariants/noDeviceVerifier-gone (zero non-comment occurrences in site/app -- M2's dead stub must not survive M4)" ;;
    DVWATCH)    echo "m4-invariants/dvWatch-called (defined in Device/Midi.hs and consumed by a real call site outside it)" ;;
    TABLEREACH) echo "m4-invariants/midi-table-unreachable (SXC1.Midi.Table absent from exe:app's import closure, with SXC1.Midi.Spec as the traversal's anti-vacuity anchor)" ;;
    *)          echo "m4-invariants/$1" ;;
  esac
}

if command -v python3 >/dev/null 2>&1; then
  M4_INVARIANTS_OUT="$(python3 "$M4_INVARIANTS_PY" "$REPO_ROOT/site/app" "$REPO_ROOT/site/src" 2>&1)" || true
  M4_INV_SEEN=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tag="${line%% *}"
    rest="${line#* }"
    status="${rest%% *}"
    detail="${rest#* }"
    label="$(m4_invariant_label "$tag")"
    case "$status" in
      OK)   ok "$label ($detail)"; M4_INV_SEEN=$((M4_INV_SEEN + 1)) ;;
      FAIL) fail "$label (observed: $detail)"; M4_INV_SEEN=$((M4_INV_SEEN + 1)) ;;
      *)    fail "$label (unexpected output: $line)"; M4_INV_SEEN=$((M4_INV_SEEN + 1)) ;;
    esac
  done <<< "$M4_INVARIANTS_OUT"
  # The scan prints exactly seven verdict lines; anything else (a crashed
  # python pass prints fewer) is itself a failure, never a silent shrink.
  if [ "$M4_INV_SEEN" -ne 7 ]; then
    fail "m4-invariants/verdict-count (observed: $M4_INV_SEEN verdict line(s), want exactly 7 -- the invariant scan itself is broken)"
  fi
else
  for tag in REQMIDI SYSEX DEVSTORAGE NETWORK NODEVSTUB DVWATCH TABLEREACH; do
    fail "$(m4_invariant_label "$tag") (observed: python3 not found on PATH)"
  done
fi
rm -f "$M4_INVARIANTS_PY"

# --- V7: the real-device protocol names only things that exist ------------
# docs/M4-device-test-protocol.md is the owner's checklist; a protocol
# that names a route or a control the app does not have is worse than no
# protocol. Extraction anti-vacuity floors (this exact vacuity class has
# bitten two manifest verify commands this milestone): >= 3 routes and
# >= 7 DOM ids must actually be extracted, so a drifted extraction regex
# fails loudly instead of successfully checking an empty set. Routes are
# proven against content/exercises (the named deck must contain the named
# exercise id); DOM ids against non-comment source literals in site/app.
M4_PROTOCOL_PY="$(mktemp -t sxc1-check-site-m4proto.XXXXXX.py)"
register_temp_file "$M4_PROTOCOL_PY"
cat > "$M4_PROTOCOL_PY" <<'PYEOF'
import os
import re
import sys

DOC = sys.argv[1]
EXERCISES_DIR = sys.argv[2]
APP = sys.argv[3]

if not os.path.isfile(DOC):
    print("ROUTES FAIL docs/M4-device-test-protocol.md is missing")
    print("DOMIDS FAIL docs/M4-device-test-protocol.md is missing")
    raise SystemExit(1)

text = open(DOC, encoding="utf-8").read()

routes = sorted(set(re.findall(r"#/x/([A-Za-z0-9-]+)/([A-Za-z0-9-]+)", text)))
dom_ids = sorted(set(re.findall(r"`#([A-Za-z][A-Za-z0-9_-]*)`", text)))

# Deck slug -> set of exercise ids, straight from content/exercises/.
decks = {}
for fn in sorted(os.listdir(EXERCISES_DIR)):
    if not fn.endswith(".ex.md"):
        continue
    deck_name = None
    ids = set()
    with open(os.path.join(EXERCISES_DIR, fn), encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^deck: (\S+)\s*$", line)
            if m and deck_name is None:
                deck_name = m.group(1)
            m = re.match(r"^id: (\S+)\s*$", line)
            if m:
                ids.add(m.group(1))
    if deck_name is not None:
        decks.setdefault(deck_name, set()).update(ids)

problems = []
if len(routes) < 3:
    problems.append("only %d route(s) extracted (< 3) -- the extraction regex has gone vacuous" % len(routes))
for deck, ex in routes:
    if deck not in decks:
        problems.append("route #/x/%s/%s names deck %r, which no content/exercises deck declares" % (deck, ex, deck))
    elif ex not in decks[deck]:
        problems.append("route #/x/%s/%s names exercise id %r, which deck %r does not contain" % (deck, ex, ex, deck))
if problems:
    print("ROUTES FAIL " + "; ".join(problems))
else:
    print("ROUTES OK %d route(s) extracted (%s), each deck/exercise pair exists in content/exercises"
          % (len(routes), ", ".join("#/x/%s/%s" % r for r in routes)))

# Every DOM id must appear as a quoted literal on a NON-comment line in
# site/app (the same first-'--' strip as every other invariant here).
app_code = []
for dirpath, _dirnames, filenames in os.walk(APP):
    for fn in filenames:
        if not fn.endswith(".hs"):
            continue
        with open(os.path.join(dirpath, fn), encoding="utf-8") as fh:
            for line in fh:
                code = line.split("--", 1)[0]
                if code.strip():
                    app_code.append(code)
blob = "\n".join(app_code)

problems = []
if len(dom_ids) < 7:
    problems.append("only %d DOM id(s) extracted (< 7) -- the extraction regex has gone vacuous" % len(dom_ids))
missing = [i for i in dom_ids if '"%s"' % i not in blob]
if missing:
    problems.append("id(s) named by the protocol but absent from site/app non-comment source literals: %s" % ", ".join(missing))
if problems:
    print("DOMIDS FAIL " + "; ".join(problems))
else:
    print("DOMIDS OK %d DOM id(s) extracted (%s), every one a non-comment source literal in site/app"
          % (len(dom_ids), ", ".join(dom_ids)))
PYEOF

m4_protocol_label() {
  case "$1" in
    ROUTES) echo "protocol-doc/routes (every #/x/<deck>/<exercise> route in docs/M4-device-test-protocol.md exists in content/exercises; >= 3 extracted)" ;;
    DOMIDS) echo "protocol-doc/dom-ids (every backticked #id in docs/M4-device-test-protocol.md is a non-comment source literal in site/app; >= 7 extracted)" ;;
    *)      echo "protocol-doc/$1" ;;
  esac
}

if command -v python3 >/dev/null 2>&1; then
  M4_PROTOCOL_OUT="$(python3 "$M4_PROTOCOL_PY" "$REPO_ROOT/docs/M4-device-test-protocol.md" "$REPO_ROOT/content/exercises" "$REPO_ROOT/site/app" 2>&1)" || true
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tag="${line%% *}"
    rest="${line#* }"
    status="${rest%% *}"
    detail="${rest#* }"
    label="$(m4_protocol_label "$tag")"
    case "$status" in
      OK)   ok "$label ($detail)" ;;
      FAIL) fail "$label (observed: $detail)" ;;
      *)    fail "$label (unexpected output: $line)" ;;
    esac
  done <<< "$M4_PROTOCOL_OUT"
else
  for tag in ROUTES DOMIDS; do
    fail "$(m4_protocol_label "$tag") (observed: python3 not found on PATH)"
  done
fi
rm -f "$M4_PROTOCOL_PY"

# ===========================================================================
# THE SIZE LEDGER (M3 harness, task "harness", item 4): a standing
# instrument, not a check that goes red -- see the WASM_GZIP_CEILING_BYTES
# comment above for the actual gate. This exists so "the full course does
# not fit the ceiling unoptimized" (briefs/M3-manifest.json's own
# top-level note; PLAN.md's "Size ruling") is a NUMBER RECORDED ON EVERY
# RUN, forever, rather than something that has to be manually
# rediscovered the next time the corpus grows -- "the instrument that
# keeps the decision from being rediscovered at deck 40".
#
# THE COEFFICIENT (named, commented, a single easy-to-find constant so a
# future re-measurement is a one-line, explained change -- never a silent
# bump): 0.3456 gzip bytes per raw byte of .ex.md, measured by the M3
# designer (briefs/M3-plan.md) from gzip(app.wasm) deltas against
# content/exercises/*.ex.md raw-byte deltas as the corpus grew. This is a
# LINEAR APPROXIMATION (content compresses reasonably uniformly; it is
# not exact for any single deck) -- good enough for an early-warning
# instrument, never treated as more precise than that.
SXC1_SIZE_LEDGER_GZIP_PER_RAW_BYTE=0.3456
SXC1_SIZE_LEDGER_TARGET_EXERCISES=435
#
# Method: measure the CURRENT corpus's raw bytes and exercise count
# straight off disk (independent of the content axis -- this runs even
# under --skip-content, since it needs no built binary, only
# content/exercises/ and python3 for the one floating-point line), scale
# both linearly to the 435-exercise target, and hold the app's own
# non-content baseline fixed at whatever today's measured total minus
# today's corpus's own estimated contribution implies. When the corpus
# already IS the full 435-exercise course (true on this tree as of the
# M3 harness wave: 435 "^id: " lines across content/exercises/), the
# scale factor is 1 and the projection collapses to (and is a live
# cross-check against) today's actual measurement; if the tree is ever
# checked out at a smaller, partial-course state again (e.g. mid-authoring
# on a future content branch), the same formula extrapolates forward
# instead of silently under-reporting.
#
# This block FAILS if it cannot compute all three numbers (content/
# exercises/ missing or empty, python3 unavailable, or app.wasm missing).
# It NEVER fails merely because the projection is over
# WASM_GZIP_CEILING_BYTES -- that is reported loudly as an info line
# naming the exact shortfall, because acting on it is the coordinator's
# call (PLAN.md), not a build-breaking assertion this task may add.
# ===========================================================================
SIZE_LEDGER_DIR="$REPO_ROOT/state"
SIZE_LEDGER_FILE="$SIZE_LEDGER_DIR/size-ledger.tsv"
mkdir -p "$SIZE_LEDGER_DIR"
if [ ! -f "$SIZE_LEDGER_FILE" ]; then
  printf 'timestamp\tapp_wasm_gzip_bytes\tcorpus_raw_bytes\tcorpus_exercise_count\tprojected_435_gzip_bytes\tceiling_bytes\tover_ceiling_bytes\n' > "$SIZE_LEDGER_FILE"
fi

CORPUS_DIR="$REPO_ROOT/content/exercises"
if [ -d "$CORPUS_DIR" ] && command -v python3 >/dev/null 2>&1 && [ -f "$WASM_FILE" ]; then
  CORPUS_RAW_BYTES=0
  CORPUS_EX_COUNT=0
  for f in "$CORPUS_DIR"/*.ex.md; do
    [ -e "$f" ] || continue
    fsz="$(wc -c < "$f" | tr -d ' ')"
    CORPUS_RAW_BYTES=$((CORPUS_RAW_BYTES + fsz))
    fn="$(grep -cE '^id: ' "$f" || true)"
    CORPUS_EX_COUNT=$((CORPUS_EX_COUNT + fn))
  done

  if [ "$CORPUS_RAW_BYTES" -gt 0 ] && [ "$CORPUS_EX_COUNT" -gt 0 ]; then
    LEDGER_CALC="$(python3 - "$WASM_GZIP_BYTES" "$CORPUS_RAW_BYTES" "$CORPUS_EX_COUNT" \
        "$SXC1_SIZE_LEDGER_GZIP_PER_RAW_BYTE" "$SXC1_SIZE_LEDGER_TARGET_EXERCISES" "$WASM_GZIP_CEILING_BYTES" <<'PYEOF'
import sys
wasm_gzip, corpus_raw, corpus_ex, target_ex, ceiling = (
    int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[5]), int(sys.argv[6])
)
coeff = float(sys.argv[4])
scaled_raw = corpus_raw * target_ex / corpus_ex
current_contribution = corpus_raw * coeff
baseline = wasm_gzip - current_contribution
projected = baseline + scaled_raw * coeff
projected_i = int(round(projected))
over = projected_i - ceiling
print("%d\t%d" % (projected_i, over))
PYEOF
)"
    PROJECTED_435_BYTES="$(printf '%s' "$LEDGER_CALC" | cut -f1)"
    OVER_CEILING="$(printf '%s' "$LEDGER_CALC" | cut -f2)"

    SIZE_LEDGER_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\t%d\t%d\t%d\t%d\t%d\t%d\n' \
      "$SIZE_LEDGER_TS" "$WASM_GZIP_BYTES" "$CORPUS_RAW_BYTES" "$CORPUS_EX_COUNT" \
      "$PROJECTED_435_BYTES" "$WASM_GZIP_CEILING_BYTES" "$OVER_CEILING" \
      >> "$SIZE_LEDGER_FILE"
    ok "size ledger: recorded app.wasm=$WASM_GZIP_BYTES corpus_raw=$CORPUS_RAW_BYTES (${CORPUS_EX_COUNT} exercises) projected_435=$PROJECTED_435_BYTES to state/size-ledger.tsv"
    if [ "$OVER_CEILING" -gt 0 ]; then
      info "size ledger: the 435-exercise projection ($PROJECTED_435_BYTES bytes) is OVER the $WASM_GZIP_CEILING_BYTES byte ceiling by $OVER_CEILING bytes -- see PLAN.md 'Size ruling' (a coordinator decision, not a build failure)"
    else
      info "size ledger: the 435-exercise projection ($PROJECTED_435_BYTES bytes) is under the $WASM_GZIP_CEILING_BYTES byte ceiling (headroom $((0 - OVER_CEILING)) bytes)"
    fi
  else
    fail "size ledger: recorded app.wasm/corpus/projection to state/size-ledger.tsv (observed: corpus_raw_bytes=$CORPUS_RAW_BYTES corpus_exercise_count=$CORPUS_EX_COUNT -- could not compute)"
  fi
else
  fail "size ledger: recorded app.wasm/corpus/projection to state/size-ledger.tsv (observed: missing content/exercises/, python3, or app.wasm -- see checks above)"
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
  # L2 fix (M2 gate round): a full run increments TOTAL for BOTH of these
  # two preconditions (sourcing the toolchain env, resolving the
  # exe:content-check binary -- see the `else` branch below) before it
  # ever gets to running content-check itself. The skip branch used to
  # jump straight to "exe:content-check runs..." without a skip() for
  # either precondition, so TOTAL differed between
  # `./check-site.sh` and `SXC1_SKIP_CONTENT=1 ./check-site.sh` -- CI
  # could not pass either way, and it contradicted NEW7's promise that a
  # skipped check stays a counted member of the total. Base label text
  # matches the real ok()/fail() calls below exactly (sans their
  # parenthetical "(observed: ...)" detail), same convention every other
  # skip() in this branch already follows.
  skip "GHC WebAssembly toolchain env sourced"
  skip "exe:content-check binary resolved"
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
  skip "exercise-stats/inventory-binding-scope-fired (totals.inventoryChecked equals totals.decks)"
  skip "exercise-check --self-test passes from the repo root as well as site/ (cwd-robust content-root resolution, M5 debt item 6)"
  skip "exercise-stats/fnv1a-vectors (FNV-1a/32 pinned against published test vectors)"
  skip "exercise-stats/index-directory-agreement (content/exercises/INDEX vs directory, both directions)"
  skip "exercise-stats/totals-agreement (python re-derivation vs exercise-check --json totals)"
  skip "exercise-stats/per-deck-agreement (chapter/title/exercises/prompts/sourceChars)"
  skip "exercise-stats/citation-recount-independent (scripts/recount-citations.py: blind ^cite:/^find: line scan vs exercise-check --json totals.citations, no knowledge of exCites/prCites/FindPage)"
  skip "exercise-stats/citation-independent-resolution (page range + anchor re-checked from translations/*.md)"
  skip "disk-derived exercise stats computed for browser-check.mjs --expect-exercise-json (python re-derivation from content/exercises/, never from the app payload)"
  skip "exercise-check --browser-fixture produced JSON for browser-check.mjs --exercise-fixture"
  skip "exercise-check --fixtures content/fixtures exits 0 (the falsifiability corpus)"
  skip "fixture coverage invariant: every file/dir code from --list-codes has >=1 fixture"
  skip "seam-class coverage cap: exactly one seam-class code, E-BLOCK-UNPARSED"
  skip "independent verdict re-derivation from fixture filenames matches --fixtures --json"
  # M3 harness item 6: progress-check/registry-check share this SAME
  # content axis (no new skip flag) -- see the real run's matching ok()/
  # fail() calls below for why.
  skip "exe:progress-check binary resolved"
  skip "exe:progress-check --self-test runs under wasm-run.mjs and exits 0"
  skip "exe:registry-check binary resolved"
  skip "exe:registry-check --self-test runs under wasm-run.mjs and exits 0"
  skip "exe:registry-check (no args, against the real content/id-registry.tsv and corpus) runs under wasm-run.mjs and exits 0"
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
  # Check 15b (briefs/M2-signoff-fixes.json, task "quiz-selection-semantics",
  # FIX 3): INVENTORY-BINDING SCOPE IS OBSERVABLE.
  #
  # The four id-inventory-binding checks (E-ID-NOT-IN-INVENTORY/
  # E-ID-RETIRED/E-ID-TYPE-MISMATCH/E-ID-CHAPTER-MISMATCH) are scoped
  # STRUCTURALLY since M5 (briefs/M5-ship.md debt item 7 -- see
  # inventoryScopedCodes in site/test/CheckExercises.hs): the real-corpus
  # modes always bind, a dirs/ fixture binds iff the code its own name
  # declares is inventory-scoped, loose files/ fixtures never bind.
  # (Until M5 the scope was a path-substring probe for the literal
  # "content/exercises/", which a moved/copied/renamed content root
  # silently defeated -- the "check that can silently stop checking"
  # pattern this project has shipped twice.) exercise-check --json's
  # totals.inventoryChecked reports how many successfully-parsed decks
  # the scope actually fired for; on the real corpus this must equal
  # totals.decks. A wiring regression that stops the binding from firing
  # reports inventoryChecked=0 and turns this check RED -- demonstrated
  # in the M5 wave by a sabotage build that forced the --json mode's
  # bind flag off (inventoryChecked=0 vs decks=52), not by this script
  # itself (this check only ever runs against the real corpus, via
  # $EXERCISE_JSON_FILE above).
  # -------------------------------------------------------------------------
  if [ -n "$EXERCISE_JSON_FILE" ] && command -v python3 >/dev/null 2>&1; then
    INV_OUT="$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
t = data.get("totals", {})
inv = t.get("inventoryChecked")
decks = t.get("decks")
if inv is not None and inv == decks:
    print("OK inventoryChecked=%r equals totals.decks=%r" % (inv, decks))
else:
    print("FAIL inventoryChecked=%r totals.decks=%r -- the id-inventory-binding checks did not fire over the whole real corpus" % (inv, decks))
' "$EXERCISE_JSON_FILE" 2>&1)" || true
    case "$INV_OUT" in
      "OK "*) ok "exercise-stats/inventory-binding-scope-fired (${INV_OUT#OK })" ;;
      *)      fail "exercise-stats/inventory-binding-scope-fired (observed: ${INV_OUT#FAIL })" ;;
    esac
  else
    fail "exercise-stats/inventory-binding-scope-fired (observed: no exercise-check --json capture available or python3 missing)"
  fi

  # -------------------------------------------------------------------------
  # Check 15c (M5, briefs/M5-ship.md debt item 6): CWD-ROBUST CONTENT-ROOT
  # RESOLUTION. exercise-check's default paths (--content-dir/
  # --translations-dir/--fixtures, the fixed inventory path, and the
  # self-test's disk groups 17/18/20) were ..-relative -- run from
  # anywhere but site/ the binary died with harness errors (M2 advisory).
  # The M5 fix probes for the repo root (resolveRootPrefix in
  # site/test/CheckExercises.hs), so the SAME binary must now pass
  # --self-test from the REPO ROOT as well as from site/ (the cwd every
  # other exercise-check invocation in this script still uses,
  # unchanged). The self-test is the strongest single probe: its groups
  # 17/18/20 read content/exercises/, content/fixtures/ and
  # translations/ through the resolved root, so a broken resolution
  # cannot pass it from the root. RED state demonstrated with the
  # pre-fix binary from the repo root: groups 17/18/20 failed
  # ("../content/exercises/INDEX does not exist", 162/165, exit 1) --
  # and again with a sabotaged probe marker after the fix.
  # -------------------------------------------------------------------------
  BOTHCWD_LABEL="exercise-check --self-test passes from the repo root as well as site/ (cwd-robust content-root resolution, M5 debt item 6)"
  if [ -n "$EXERCISE_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    set +e
    ROOTCWD_OUT="$(cd "$REPO_ROOT" && wasm-run.mjs "$EXERCISE_CHECK_BIN" --self-test 2>&1)"
    ROOTCWD_RC=$?
    set -e
    ROOTCWD_LAST="$(printf '%s\n' "$ROOTCWD_OUT" | tail -n 1)"
    if [ "$ROOTCWD_RC" -eq 0 ] && printf '%s' "$ROOTCWD_LAST" | grep -qE '^exercise-check --self-test: [0-9]+/[0-9]+ checks passed$'; then
      ok "$BOTHCWD_LABEL (observed from the repo root: $ROOTCWD_LAST)"
    else
      fail "$BOTHCWD_LABEL (observed: exit $ROOTCWD_RC from the repo root; last line: ${ROOTCWD_LAST:-<empty>})"
    fi
  else
    fail "$BOTHCWD_LABEL (observed: toolchain env or binary unavailable -- see checks above)"
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
    citation_failures = []
    resolved_count = 0

    for fname in deck_files:
        path = os.path.join(EXERCISES_DIR, fname)
        text = open(path, encoding="utf-8").read()
        # M6 W2 seam repair: the app's per-deck chars/lines/fnv1a derive
        # from the CONTENT BUNDLE it fetched, i.e. the EN EMISSION (every
        # column-0 "ja:" variant line deleted, byte-identical otherwise --
        # scripts/emit-content-bundles.py's EN rule / SXC1.Exercise.
        # Reader.isJaLine). This derivation went red the moment W3 landed
        # the first real ja: lines, because it still measured the RAW
        # file. It now models the same EN emission; whole-bundle
        # staleness (BOTH languages, byte-for-byte) is the M6-c/d
        # freshness checks' own job. lines_list stays RAW on purpose --
        # structural counting (headings, type:, cite:) is emission-
        # invariant, and a ja: payload can never match those patterns.
        en_text = "".join(l for l in text.splitlines(True) if not l.startswith("ja:"))
        chars = len(en_text)
        lines_list = text.split("\n")
        n_lines = len(en_text.split("\n"))
        fnv = fnv1a32(en_text.encode("utf-8"))

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

            # A drill's prompt count is its STEP count (one "### Step"
            # role heading per prompt); every other kind has exactly one
            # prompt. (M2 gate fix, M1 harness half: this function used
            # to ALSO accumulate a "citation_total" here by reproducing
            # SXC1.Exercise.Report.buildTotals's own per-kind citation
            # scoping rule in Python -- a quiz's cite: line counted
            # twice, a lookup's find: line never counted, etc. -- so
            # "agreement" with the model proved nothing: one
            # implementation, checked twice. That comparison has moved to
            # scripts/recount-citations.py, a genuinely independent
            # ^cite:/^find: line scan with NO knowledge of this scoping
            # at all; see its own module docstring. Only the STEP-COUNTING
            # half of this logic (needed for the `prompts` TOTAL, which
            # recount-citations.py does not compute) stays here.)
            role_idx = [i for i, l in enumerate(span) if heading_level(l) == 3]
            if kind == "drill":
                step_count = 0
                for ri, rstart in enumerate(role_idx):
                    rh = heading_of(span[rstart])
                    if rh and rh[1] == "Step":
                        step_count += 1
                prompts += step_count
            else:
                prompts += 1

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
        "citation_failures": citation_failures,
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
      CITERESOLVE) echo "exercise-stats/citation-independent-resolution (page range + anchor re-checked from translations/*.md)" ;;
      *)           echo "exercise-stats/$1" ;;
    esac
  }

  if command -v python3 >/dev/null 2>&1; then
    if [ -n "$EXERCISE_JSON_FILE" ]; then
      EXSTATS_OUT="$(cd "$REPO_ROOT" && python3 "$EXERCISE_STATS_PY" diff "$REPO_ROOT/content" "$REPO_ROOT/translations" "$EXERCISE_JSON_FILE" 2>&1)" || true
    else
      EXSTATS_OUT="$(printf 'FNV1A FAIL no exercise-check --json capture available (see checks above)\nINDEXDIR FAIL no exercise-check --json capture available (see checks above)\nTOTALS FAIL no exercise-check --json capture available (see checks above)\nPERDECK FAIL no exercise-check --json capture available (see checks above)\nCITERESOLVE FAIL no exercise-check --json capture available (see checks above)\n')"
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
    for tag in FNV1A INDEXDIR TOTALS PERDECK CITERESOLVE; do
      fail "$(exstats_label "$tag") (observed: python3 not found on PATH)"
    done
  fi

  # -------------------------------------------------------------------------
  # M2 gate fix (M1, harness half): the GENUINELY independent citation
  # recount, factored out into scripts/recount-citations.py so its
  # falsifiability can be demonstrated on its own (see that script's own
  # module docstring, and this task's negative control: doctor a COPY of
  # $EXERCISE_JSON_FILE's totals.citations and require the script to
  # reject it -- never a corpus mutation, which would go red on the
  # UNRELATED stale-build/FNV-1a comparison above before the citation
  # logic itself was ever exercised). Replaces the CITECOUNT check that
  # used to live inside EXERCISE_STATS_PY above, which did not
  # independently count anything -- it reproduced
  # SXC1.Exercise.Report.buildTotals's own per-kind citation-scoping rule
  # in Python, so agreement proved nothing.
  # -------------------------------------------------------------------------
  RECOUNT_LABEL="exercise-stats/citation-recount-independent (scripts/recount-citations.py: blind ^cite:/^find: line scan vs exercise-check --json totals.citations, no knowledge of exCites/prCites/FindPage)"
  if [ -n "$EXERCISE_JSON_FILE" ]; then
    set +e
    RECOUNT_OUT="$("$REPO_ROOT/scripts/recount-citations.py" --report "$EXERCISE_JSON_FILE" --content-dir "$REPO_ROOT/content/exercises" 2>&1)"
    RECOUNT_RC=$?
    set -e
    if [ "$RECOUNT_RC" -eq 0 ]; then
      ok "$RECOUNT_LABEL ($RECOUNT_OUT)"
    else
      fail "$RECOUNT_LABEL (observed: $RECOUNT_OUT)"
    fi
  else
    fail "$RECOUNT_LABEL (observed: no exercise-check --json capture available -- see checks above)"
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

  # -------------------------------------------------------------------------
  # M3 harness item 6: exe:progress-check and exe:registry-check, wired
  # onto this SAME content axis -- NO NEW SKIP FLAG (M2's ruling: one
  # fewer switch is one fewer route to result=complete without having
  # checked). Resolved and run exactly like exe:content-check/
  # exe:exercise-check above: same toolchain env (already sourced at the
  # top of this branch), same wasm32-wasi-cabal list-bin / wasm-run.mjs
  # convention, same site/-relative-path convention (both binaries read
  # e.g. "../content/id-registry.tsv" / "src/SXC1/Progress/*.hs" relative
  # to site/, so every invocation below is cd'd there first).
  # -------------------------------------------------------------------------
  PROGRESS_CHECK_BIN=""
  if command -v wasm32-wasi-cabal >/dev/null 2>&1; then
    PROGRESS_CHECK_BIN="$(cd "$REPO_ROOT/site" && wasm32-wasi-cabal list-bin exe:progress-check 2>/dev/null | tail -n1 || true)"
  fi
  if [ -n "$PROGRESS_CHECK_BIN" ] && [ -f "$PROGRESS_CHECK_BIN" ]; then
    ok "exe:progress-check binary resolved (observed: $PROGRESS_CHECK_BIN)"
  else
    fail "exe:progress-check binary resolved (observed: missing -- run ./scripts/build-site.sh first; fallback runner: wasmtime run --dir=/ <binary>)"
    PROGRESS_CHECK_BIN=""
  fi
  if [ -n "$PROGRESS_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    PROGRESS_RUN_LOG="$(mktemp -t sxc1-check-site-progress-run.XXXXXX)"
    register_temp_file "$PROGRESS_RUN_LOG"
    if ( cd "$REPO_ROOT/site" && wasm-run.mjs "$PROGRESS_CHECK_BIN" --self-test ) >"$PROGRESS_RUN_LOG" 2>&1; then
      ok "exe:progress-check --self-test runs under wasm-run.mjs and exits 0"
    else
      fail "exe:progress-check --self-test runs under wasm-run.mjs and exits 0 (observed: non-zero exit; output follows)"
      sed 's/^/    /' "$PROGRESS_RUN_LOG" >&2
    fi
    rm -f "$PROGRESS_RUN_LOG"
  else
    fail "exe:progress-check --self-test runs under wasm-run.mjs and exits 0 (observed: toolchain env or binary unavailable -- see checks above; fallback runner: wasmtime run --dir=/ <binary>)"
  fi

  REGISTRY_CHECK_BIN=""
  if command -v wasm32-wasi-cabal >/dev/null 2>&1; then
    REGISTRY_CHECK_BIN="$(cd "$REPO_ROOT/site" && wasm32-wasi-cabal list-bin exe:registry-check 2>/dev/null | tail -n1 || true)"
  fi
  if [ -n "$REGISTRY_CHECK_BIN" ] && [ -f "$REGISTRY_CHECK_BIN" ]; then
    ok "exe:registry-check binary resolved (observed: $REGISTRY_CHECK_BIN)"
  else
    fail "exe:registry-check binary resolved (observed: missing -- run ./scripts/build-site.sh first; fallback runner: wasmtime run --dir=/ <binary>)"
    REGISTRY_CHECK_BIN=""
  fi
  if [ -n "$REGISTRY_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    REGISTRY_SELFTEST_LOG="$(mktemp -t sxc1-check-site-registry-selftest.XXXXXX)"
    register_temp_file "$REGISTRY_SELFTEST_LOG"
    if ( cd "$REPO_ROOT/site" && wasm-run.mjs "$REGISTRY_CHECK_BIN" --self-test ) >"$REGISTRY_SELFTEST_LOG" 2>&1; then
      ok "exe:registry-check --self-test runs under wasm-run.mjs and exits 0"
    else
      fail "exe:registry-check --self-test runs under wasm-run.mjs and exits 0 (observed: non-zero exit; output follows)"
      sed 's/^/    /' "$REGISTRY_SELFTEST_LOG" >&2
    fi
    rm -f "$REGISTRY_SELFTEST_LOG"
  else
    fail "exe:registry-check --self-test runs under wasm-run.mjs and exits 0 (observed: toolchain env or binary unavailable -- see checks above; fallback runner: wasmtime run --dir=/ <binary>)"
  fi
  if [ -n "$REGISTRY_CHECK_BIN" ] && command -v wasm-run.mjs >/dev/null 2>&1; then
    REGISTRY_RUN_LOG="$(mktemp -t sxc1-check-site-registry-run.XXXXXX)"
    register_temp_file "$REGISTRY_RUN_LOG"
    if ( cd "$REPO_ROOT/site" && wasm-run.mjs "$REGISTRY_CHECK_BIN" ) >"$REGISTRY_RUN_LOG" 2>&1; then
      ok "exe:registry-check (no args, against the real content/id-registry.tsv and corpus) runs under wasm-run.mjs and exits 0"
    else
      fail "exe:registry-check (no args, against the real content/id-registry.tsv and corpus) runs under wasm-run.mjs and exits 0 (observed: non-zero exit; output follows)"
      sed 's/^/    /' "$REGISTRY_RUN_LOG" >&2
    fi
    rm -f "$REGISTRY_RUN_LOG"
  else
    fail "exe:registry-check (no args, against the real content/id-registry.tsv and corpus) runs under wasm-run.mjs and exits 0 (observed: toolchain env or binary unavailable -- see checks above; fallback runner: wasmtime run --dir=/ <binary>)"
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
# M4 (task "verification", V6): the stage's browser output is also teed
# into a temp capture and its path left in LAST_BROWSER_STAGE_LOG, so the
# V6 check below can prove the D1..D27 device suite actually ran INSIDE
# the root run (an unplugged suite would leave checks 7/8 green while the
# device assertions silently stopped existing -- the exact
# can't-fail-anymore class this project keeps re-finding), and the M5
# cardinality-contract checks below can hold each stage's own
# "N/N assertions passed" summary to the M5_BROWSER_ASSERT_FLOOR.
LAST_BROWSER_STAGE_LOG=""
run_browser_stage() {
  local serve_dir="$1" on_disk_index="$2" url_path="$3" health_label="$4" browser_label="$5" browser_path="$6"
  LAST_BROWSER_STAGE_LOG=""

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
  local browser_log
  browser_log="$(mktemp -t sxc1-check-site-browser-stage.XXXXXX.log)"
  register_temp_file "$browser_log"
  set +e
  "$NODE" "${browser_cmd[@]}" 2>&1 | tee "$browser_log"
  local browser_rc="${PIPESTATUS[0]}"
  set -e
  LAST_BROWSER_STAGE_LOG="$browser_log"
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
# M4 (task "verification", V6): the D1..D27 WebMIDI device assertions are
# part of scripts/browser-check.mjs's ordinary full run (checks 7/8), on
# fresh CDP targets with scripts/fake-midi.js injected. This named check
# proves they actually RAN AND PASSED inside check 7's root run, by
# counting the 27 distinct "ok - D<n>: ..." report lines in that stage's
# captured output -- so silently unplugging the device suite from the
# browser driver turns this red even while checks 7/8 stay green. M4
# gate-2 fix (briefs/M4-codex-gate2.json, new finding 1): the floor was
# left at D1..D22 when gate-1 added D23/D24/D25, so those three could be
# silently unplugged while everything stayed green -- the exact
# unplugged-check class V6 exists to prevent. M5 final-review fix
# (briefs/M5-codex-final1.json, finding M5-R1-1): the SAME mistake was
# then repeated -- M5's a11y device assertions D26/D27 were left OUTSIDE
# the D1..D25 floor, so they too could be silently unplugged; the floor
# is now D1..D27 and MUST grow every time a D-assertion is added.
# On the EXISTING browser axis: skipped via skip() (counted, conspicuous,
# TOTAL unchanged), never via any new flag.
DEVICE_SUITE_LABEL="device assertions D1..D27 ran and passed inside check 7's root browser run (WebMIDI suite driven through scripts/fake-midi.js; D26/D27 are the M5 a11y device assertions)"
# M5 cardinality contract (briefs/M5-codex-final1.json, M5-R1-1), browser
# half -- see usage() check 19 and the M5_BROWSER_ASSERT_FLOOR pin near the
# reporting helpers. Each full browser stage's own dynamically accumulated
# total is held to a pinned FLOOR, so deleting a block of assertions (e.g.
# the whole T17 D26/D27 scenario) can no longer just produce a smaller
# all-green run. Floors, never equalities: raising the floor is part of
# adding assertions. Skipped conspicuously (via skip(), TOTAL unchanged)
# under --skip-browser (the stages never ran) AND under --skip-content
# (without the content/exercise fixtures the stages lawfully run fewer
# assertions -- see check 17's fallback note in usage()).
# M6 W1: the fetch-failure degradation stage -- the behavioral half of
# the corpus externalization (the structural half is the M6 bundle
# section above). A COPY of the bundle at --dir is served WITHOUT its
# content/ directory, so the boot-time bundle load 404s, and
# browser-check --check-content-missing asserts the app still boots,
# renders the visible #sxc1-content-error banner naming the failure,
# keeps a real manual page readable, and offers #btn-content-retry on
# the exercise routes. RED-FIRST: demonstrated by sabotaging the served
# copy's index.js content guard to rethrow (the pre-guard behavior) --
# boot dies with __SXC1_BOOT_ERROR and the mode reports 0/4 (see the M6
# W1 report). Same owned-server discipline as the storage-refused stage
# (M5-R1-3): reject a pre-occupied port, verify the child serves OUR
# copy's index.html byte-for-byte, kill only our own child.
CONTENT_MISSING_LABEL="fetch-failure degradation: served WITHOUT content/ bundles the app still boots, names the failure, keeps manuals readable, and offers a retry (browser-check --check-content-missing, 4/4)"
# M6 W2: the ui-language toggle roundtrip stage -- see usage() check 22.
JA_TOGGLE_LABEL="ui-language toggle roundtrip: served copy with one injected ja: fixture variant -- EN boot, JA switch via reload-as-refetch, header/pref/ruling-4 suggestion, JA content title, JA device flow, back to EN (browser-check --check-ja-toggle, 9/9)"
ROOT_CARDINALITY_LABEL="M5 cardinality contract: root browser stage reports N/N assertions passed with N >= $M5_BROWSER_ASSERT_FLOOR (floor, never an equality -- raising the floor is part of adding assertions)"
SUBPATH_CARDINALITY_LABEL="M5 cardinality contract: sub-path browser stage reports N/N assertions passed with N >= $M5_BROWSER_ASSERT_FLOOR (floor, never an equality -- raising the floor is part of adding assertions)"
# M6 W4 (check 23): THE JA COURSE FLOOR -- V6's naming discipline
# applied to the five "ja course:" assertions runUiLangJaAssertions runs
# inside BOTH full stages. The N/N cardinality floor above is a FLOOR:
# it catches five assertions being deleted, but not five being deleted
# while five others are added. These five are the entire proof that the
# JAPANESE COURSE (not merely the JA UI, and not merely a bundle file on
# disk) renders end to end from the bundle the site ships, so -- exactly
# like D1..D27 -- they are counted BY NAME, in each stage's own capture.
# Their expectations are LITERAL corpus strings inside
# scripts/browser-check.mjs (JA_COURSE_PINS), which is what makes an
# EN-fallback ja bundle red rather than self-consistent; the red-first
# demonstration served a copy whose content.ja.txt was the EN emission
# relabelled "ja" and all five failed (M6 W4 report).
JA_COURSE_ASSERT_COUNT=5
JA_COURSE_LABEL="M6 W4 JA course floor: BOTH full browser stages reported all $JA_COURSE_ASSERT_COUNT 'ja course:' assertions ok (the SHIPPED ja bundle renders the real Japanese course: 52 decks/435 exercises + a JA deck title from #sxc1-exercise-stats, the deck card/page/summary, a JA quiz COMPLETED, a JA drill check: sentence) -- counted BY NAME, so unplugging them cannot hide under the N/N floor"

# Parse one stage's captured output for its final "browser-check: N/M
# assertions passed" summary line and enforce the contract: the line must
# exist, every assertion must have passed (N == M), and the total must be
# at or above the pinned floor.
# M6 W4 (check 23): how many DISTINCT "ja course:" assertions one stage
# capture reported ok. A failed assertion prints "FAIL - ja course: ..."
# instead, so it is missing from this count -- the check goes red both
# when the suite is unplugged and when any member fails.
ja_course_ok_count() {
  local log="$1"
  if [ -n "$log" ] && [ -s "$log" ]; then
    grep -oE '^ok - ja course: [^(]*' "$log" | sort -u | grep -c '^ok - ja course: ' || true
  else
    echo 0
  fi
}

browser_stage_assertion_floor() {
  local log="$1" label="$2"
  local line="" bs_passed="" bs_total=""
  if [ -n "$log" ] && [ -s "$log" ]; then
    line="$(grep -E '^browser-check: [0-9]+/[0-9]+ assertions passed$' "$log" | tail -n1)"
  fi
  if [ -z "$line" ]; then
    fail "$label (observed: no 'browser-check: N/M assertions passed' summary line in the stage capture -- the stage never ran to its summary)"
    return
  fi
  bs_passed="$(printf '%s\n' "$line" | sed -E 's|^browser-check: ([0-9]+)/([0-9]+) assertions passed$|\1|')"
  bs_total="$(printf '%s\n' "$line" | sed -E 's|^browser-check: ([0-9]+)/([0-9]+) assertions passed$|\2|')"
  if [ "$bs_passed" = "$bs_total" ] && [ "$bs_total" -ge "$M5_BROWSER_ASSERT_FLOOR" ]; then
    ok "$label (observed: $bs_passed/$bs_total assertions passed, floor $M5_BROWSER_ASSERT_FLOOR)"
  else
    fail "$label (observed: $bs_passed/$bs_total assertions passed -- not all passed, or the total fell below the $M5_BROWSER_ASSERT_FLOOR floor: assertions were removed/unplugged from the suite)"
  fi
}

if [ "$SKIP_BROWSER" -eq 1 ]; then
  echo "SKIPPED -- browser checks (requested via --skip-browser or SXC1_SKIP_BROWSER=1)"
  skip "$ROOT_HEALTH_LABEL"
  skip "$ROOT_BROWSER_LABEL"
  skip "$SUBPATH_HEALTH_LABEL"
  skip "$SUBPATH_BROWSER_LABEL"
  skip "storage refused: app boots and reports available=false when localStorage throws (private-mode simulation)"
  skip "$CONTENT_MISSING_LABEL"
  skip "$JA_TOGGLE_LABEL"
  skip "$DEVICE_SUITE_LABEL"
  skip "$ROOT_CARDINALITY_LABEL"
  skip "$SUBPATH_CARDINALITY_LABEL"
  skip "$JA_COURSE_LABEL"
else
  if ! BROWSER_PATH="$(resolve_browser)"; then
    fail "$ROOT_HEALTH_LABEL (observed: no browser found -- set SXC1_BROWSER, install Chrome/Chromium, or pass --skip-browser)"
    fail "$ROOT_BROWSER_LABEL"
    fail "$SUBPATH_HEALTH_LABEL (observed: no browser found -- set SXC1_BROWSER, install Chrome/Chromium, or pass --skip-browser)"
    fail "$SUBPATH_BROWSER_LABEL"
    fail "storage refused: app boots and reports available=false when localStorage throws (private-mode simulation) (observed: no browser found, the stage never ran)"
    fail "$CONTENT_MISSING_LABEL (observed: no browser found, the stage never ran)"
    fail "$JA_TOGGLE_LABEL (observed: no browser found, the stage never ran)"
    fail "$DEVICE_SUITE_LABEL (observed: no browser found, the suite never ran)"
    fail "$ROOT_CARDINALITY_LABEL (observed: no browser found, the stage never ran)"
    fail "$SUBPATH_CARDINALITY_LABEL (observed: no browser found, the stage never ran)"
    fail "$JA_COURSE_LABEL (observed: no browser found, the stages never ran)"
  else
    # Check 7: ordinary root-served smoke test.
    run_browser_stage "$DIR" "$DIR/index.html" "/" "$ROOT_HEALTH_LABEL" "$ROOT_BROWSER_LABEL" "$BROWSER_PATH"
    ROOT_BROWSER_STAGE_LOG="$LAST_BROWSER_STAGE_LOG"

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
    SUBPATH_BROWSER_STAGE_LOG="$LAST_BROWSER_STAGE_LOG"
    rm -rf "$SUBPATH_TMP"
    unregister_temp_dir "$SUBPATH_TMP"

    # Check 9 (M3, storage-refused -- PROMOTED from standalone diagnostic
    # to gating check once the defect it found was fixed): with
    # localStorage forced to throw (real private-mode behavior: the
    # object present, every call throwing), the app must still boot and
    # #sxc1-progress must report available:false. Its red state was the
    # real pre-fix app (boot death via a JS exception crossing the wasm
    # boundary); the fix is the window.__sxc1Storage JS-side try/catch
    # bridge in site/static/index.js + Progress/Store.hs. Falsifiable by
    # construction: revert either half and this fails exactly as it did
    # before the fix.
    STORAGE_REFUSED_LABEL="storage refused: app boots and reports available=false when localStorage throws (private-mode simulation)"
    STORAGE_PORT=$((PORT + 7))
    # M5 fix (briefs/M5-ship.md, debt item 12): this used to be
    #   ( cd "$DIR" && python3 -m http.server ... ) &
    # which put the SUBSHELL's pid -- not python's -- in $!; the kill
    # below (and cleanup()'s) then terminated only the subshell, leaving
    # the python child orphaned after every full run (observed twice,
    # 2026-08-07: stray `http.server 8130`/`8307`). `--directory "$DIR"`
    # lets python serve the bundle with NO subshell and NO cd, so $! IS
    # the python process and killing it actually stops the server. The
    # check itself is unchanged.
    #
    # M5 final-review fix (briefs/M5-codex-final1.json, finding M5-R1-3):
    # this stage used to start python on the fixed derived port, sleep 1,
    # and probe -- never proving the server it probed was ITS OWN child.
    # A stale/foreign listener on PORT+7 (exactly where item 12's leaked
    # orphans sat) would win the bind race, the fresh python child would
    # exit, and the browser check would run against the WRONG bytes --
    # possibly an older, passing bundle masking a current storage
    # regression. Now, like the ordinary stages: (1) an already-occupied
    # port is REJECTED outright (FAIL, never a silent probe of somebody
    # else's server); (2) the child must come up within the same
    # wait_for_port budget the ordinary stages get; (3)
    # verify_server_healthy proves the child is still alive (kill -0)
    # AND that /index.html fetched through the port byte-matches the
    # on-disk $DIR/index.html it is supposed to serve. Mismatch or dead
    # child = FAIL, not skip. The item-12 direct-child kill+wait cleanup
    # is preserved intact on every path that started the child.
    if port_in_use "$STORAGE_PORT"; then
      fail "$STORAGE_REFUSED_LABEL (observed: port $STORAGE_PORT is already in use BEFORE this stage started its own server -- refusing to probe a server this run does not own (M5-R1-3); free the port (a leaked http.server?) or pass a different --port)"
    else
      python3 -m http.server "$STORAGE_PORT" --bind 127.0.0.1 --directory "$DIR" >/dev/null 2>&1 &
      STORAGE_SRV_PID=$!
      SERVER_PIDS+=("$STORAGE_SRV_PID")
      STORAGE_SRV_VERIFIED=0
      if ! wait_for_port "$STORAGE_PORT" 15; then
        fail "$STORAGE_REFUSED_LABEL (observed: this stage's own python http.server (pid $STORAGE_SRV_PID) never came up on port $STORAGE_PORT within 15s)"
      elif ! verify_server_healthy "$STORAGE_SRV_PID" "$STORAGE_PORT" "/index.html" "$DIR/index.html"; then
        fail "$STORAGE_REFUSED_LABEL (observed: the listener on port $STORAGE_PORT is not provably this stage's own child serving '$DIR' -- child dead, /index.html unfetchable, or served bytes do not match the on-disk index.html (M5-R1-3); browser check not run)"
      else
        STORAGE_SRV_VERIFIED=1
      fi
      if [ "$STORAGE_SRV_VERIFIED" -eq 1 ]; then
        set +e
        "$NODE" "$REPO_ROOT/scripts/browser-check.mjs" --check-storage-refused --url "http://127.0.0.1:$STORAGE_PORT/" >/dev/null 2>&1
        STORAGE_REFUSED_RC=$?
        set -e
        if [ "$STORAGE_REFUSED_RC" -eq 0 ]; then
          ok "$STORAGE_REFUSED_LABEL"
        else
          fail "$STORAGE_REFUSED_LABEL (browser-check --check-storage-refused exit $STORAGE_REFUSED_RC)"
        fi
      fi
      kill "$STORAGE_SRV_PID" >/dev/null 2>&1 || true
      wait "$STORAGE_SRV_PID" 2>/dev/null || true
    fi

    # M6 W1: the fetch-failure degradation stage -- see
    # CONTENT_MISSING_LABEL's comment above.
    CONTENT_MISSING_PORT=$((PORT + 9))
    if port_in_use "$CONTENT_MISSING_PORT"; then
      fail "$CONTENT_MISSING_LABEL (observed: port $CONTENT_MISSING_PORT is already in use BEFORE this stage started its own server -- refusing to probe a server this run does not own (M5-R1-3); free the port or pass a different --port)"
    else
      CONTENT_MISSING_TMP="$(mktemp -d -t sxc1-check-site-nocontent.XXXXXX)"
      register_temp_dir "$CONTENT_MISSING_TMP"
      cp -R "$DIR"/. "$CONTENT_MISSING_TMP"/
      rm -rf "$CONTENT_MISSING_TMP/content"
      python3 -m http.server "$CONTENT_MISSING_PORT" --bind 127.0.0.1 --directory "$CONTENT_MISSING_TMP" >/dev/null 2>&1 &
      CONTENT_MISSING_SRV_PID=$!
      SERVER_PIDS+=("$CONTENT_MISSING_SRV_PID")
      CONTENT_MISSING_VERIFIED=0
      if ! wait_for_port "$CONTENT_MISSING_PORT" 15; then
        fail "$CONTENT_MISSING_LABEL (observed: this stage's own python http.server (pid $CONTENT_MISSING_SRV_PID) never came up on port $CONTENT_MISSING_PORT within 15s)"
      elif ! verify_server_healthy "$CONTENT_MISSING_SRV_PID" "$CONTENT_MISSING_PORT" "/index.html" "$CONTENT_MISSING_TMP/index.html"; then
        fail "$CONTENT_MISSING_LABEL (observed: the listener on port $CONTENT_MISSING_PORT is not provably this stage's own child serving the pruned copy -- child dead, /index.html unfetchable, or served bytes mismatch; browser check not run)"
      else
        CONTENT_MISSING_VERIFIED=1
      fi
      if [ "$CONTENT_MISSING_VERIFIED" -eq 1 ]; then
        set +e
        "$NODE" "$REPO_ROOT/scripts/browser-check.mjs" --check-content-missing --url "http://127.0.0.1:$CONTENT_MISSING_PORT/" --timeout 120000 >/dev/null 2>&1
        CONTENT_MISSING_RC=$?
        set -e
        if [ "$CONTENT_MISSING_RC" -eq 0 ]; then
          ok "$CONTENT_MISSING_LABEL"
        else
          fail "$CONTENT_MISSING_LABEL (browser-check --check-content-missing exit $CONTENT_MISSING_RC)"
        fi
      fi
      kill "$CONTENT_MISSING_SRV_PID" >/dev/null 2>&1 || true
      wait "$CONTENT_MISSING_SRV_PID" 2>/dev/null || true
      rm -rf "$CONTENT_MISSING_TMP"
      unregister_temp_dir "$CONTENT_MISSING_TMP"
    fi

    # M6 W2: the ui-language toggle roundtrip stage -- see
    # JA_TOGGLE_LABEL's comment / usage() check 22. The served copy's
    # bundles are re-emitted from a COPY of content/exercises carrying
    # one injected ja: heading variant for q-2-01 (the same exercise the
    # D-suite's DEVICE_REAL_CFG already pins), so the stage proves the
    # WHOLE pipe: ja: variant -> emit-content-bundles.py ja substitution
    # -> boot-hint bundle pick -> the wasm renders the Japanese title.
    # Injection is grep-confirmed IN (ja bundle) and OUT (en bundle)
    # before the browser runs; content/ itself is never touched.
    JA_TOGGLE_PORT=$((PORT + 13))
    if port_in_use "$JA_TOGGLE_PORT"; then
      fail "$JA_TOGGLE_LABEL (observed: port $JA_TOGGLE_PORT is already in use BEFORE this stage started its own server -- refusing to probe a server this run does not own (M5-R1-3); free the port or pass a different --port)"
    else
      JA_TOGGLE_TMP="$(mktemp -d -t sxc1-check-site-jatoggle.XXXXXX)"
      register_temp_dir "$JA_TOGGLE_TMP"
      cp -R "$DIR"/. "$JA_TOGGLE_TMP"/
      JA_EX_TMP="$(mktemp -d -t sxc1-check-site-jaex.XXXXXX)"
      register_temp_dir "$JA_EX_TMP"
      cp -R "$REPO_ROOT/content/exercises"/. "$JA_EX_TMP"/
      JA_TOGGLE_PREP_ERR=""
      JA_FIXTURE_TITLE='「BANK」とは'
      if ! python3 - "$JA_EX_TMP/024-pad-01.ex.md" <<'PYEOF2'
import sys
path = sys.argv[1]
ANCHOR = '## What a "BANK" is'
VARIANT = 'ja: ## \u300cBANK\u300d\u3068\u306f\n'
lines = open(path, encoding='utf-8').read().splitlines(True)
out, done, skipping = [], False, False
for ln in lines:
    # W3 lands real ja: variants concurrently: if the anchor already
    # carries a variant run, REPLACE it with the pinned fixture variant
    # (two variant lines after a heading anchor would be an emitter
    # error; and the stage pins the exact fixture title).
    if skipping:
        if ln.startswith('ja:'):
            continue
        skipping = False
    out.append(ln)
    if not done and ln.rstrip('\n') == ANCHOR:
        out.append(VARIANT)
        done = True
        skipping = True
if not done:
    print('anchor heading %r not found in %s' % (ANCHOR, path))
    raise SystemExit(1)
open(path, 'w', encoding='utf-8').write(''.join(out))
PYEOF2
      then
        JA_TOGGLE_PREP_ERR="could not inject the ja: fixture variant (anchor heading missing from 024-pad-01.ex.md?)"
      elif ! grep -qF "$JA_FIXTURE_TITLE" "$JA_EX_TMP/024-pad-01.ex.md"; then
        JA_TOGGLE_PREP_ERR="grep-confirm IN failed: the injected ja: variant is not in the temp deck copy"
      elif ! python3 "$REPO_ROOT/scripts/emit-content-bundles.py" --exercises-dir "$JA_EX_TMP" --out-dir "$JA_TOGGLE_TMP/content" >/dev/null 2>&1; then
        JA_TOGGLE_PREP_ERR="emit-content-bundles.py failed on the variant-injected temp corpus"
      elif ! grep -qF "$JA_FIXTURE_TITLE" "$JA_TOGGLE_TMP/content/content.ja.txt"; then
        JA_TOGGLE_PREP_ERR="grep-confirm IN failed: the served copy's content.ja.txt does not carry the injected JA title"
      elif grep -qF "$JA_FIXTURE_TITLE" "$JA_TOGGLE_TMP/content/content.en.txt"; then
        JA_TOGGLE_PREP_ERR="grep-confirm OUT failed: the injected JA title leaked into the served copy's content.en.txt"
      fi
      if [ -n "$JA_TOGGLE_PREP_ERR" ]; then
        fail "$JA_TOGGLE_LABEL (observed: $JA_TOGGLE_PREP_ERR)"
      else
        python3 -m http.server "$JA_TOGGLE_PORT" --bind 127.0.0.1 --directory "$JA_TOGGLE_TMP" >/dev/null 2>&1 &
        JA_TOGGLE_SRV_PID=$!
        SERVER_PIDS+=("$JA_TOGGLE_SRV_PID")
        JA_TOGGLE_VERIFIED=0
        if ! wait_for_port "$JA_TOGGLE_PORT" 15; then
          fail "$JA_TOGGLE_LABEL (observed: this stage's own python http.server (pid $JA_TOGGLE_SRV_PID) never came up on port $JA_TOGGLE_PORT within 15s)"
        elif ! verify_server_healthy "$JA_TOGGLE_SRV_PID" "$JA_TOGGLE_PORT" "/index.html" "$JA_TOGGLE_TMP/index.html"; then
          fail "$JA_TOGGLE_LABEL (observed: the listener on port $JA_TOGGLE_PORT is not provably this stage's own child serving the variant-injected copy -- child dead, /index.html unfetchable, or served bytes mismatch; browser check not run)"
        else
          JA_TOGGLE_VERIFIED=1
        fi
        if [ "$JA_TOGGLE_VERIFIED" -eq 1 ]; then
          set +e
          "$NODE" "$REPO_ROOT/scripts/browser-check.mjs" --check-ja-toggle --url "http://127.0.0.1:$JA_TOGGLE_PORT/" --timeout 120000 >/dev/null 2>&1
          JA_TOGGLE_RC=$?
          set -e
          if [ "$JA_TOGGLE_RC" -eq 0 ]; then
            ok "$JA_TOGGLE_LABEL"
          else
            fail "$JA_TOGGLE_LABEL (browser-check --check-ja-toggle exit $JA_TOGGLE_RC)"
          fi
        fi
        kill "$JA_TOGGLE_SRV_PID" >/dev/null 2>&1 || true
        wait "$JA_TOGGLE_SRV_PID" 2>/dev/null || true
      fi
      rm -rf "$JA_TOGGLE_TMP" "$JA_EX_TMP"
      unregister_temp_dir "$JA_TOGGLE_TMP"
      unregister_temp_dir "$JA_EX_TMP"
    fi

    # V6 (M4, task "verification"; floor widened to D1..D27 by the M5
    # final-review fix, briefs/M5-codex-final1.json M5-R1-1) -- see
    # DEVICE_SUITE_LABEL's comment above. 27 DISTINCT passing
    # device-assertion lines must appear in check 7's root-stage capture;
    # a failed assertion prints "FAIL - Dn:" instead and is therefore
    # missing from this count, so V6 goes red both when the suite is
    # unplugged and when any of its members fail. The fail message NAMES
    # the missing assertion(s), not just the count.
    DEVICE_SUITE_OK_COUNT=0
    DEVICE_SUITE_SEEN=""
    if [ -n "${ROOT_BROWSER_STAGE_LOG:-}" ] && [ -s "$ROOT_BROWSER_STAGE_LOG" ]; then
      DEVICE_SUITE_SEEN="$(grep -oE '^ok - D([1-9]|1[0-9]|2[0-7]): ' "$ROOT_BROWSER_STAGE_LOG" | grep -oE 'D[0-9]+' | sort -u)"
      DEVICE_SUITE_OK_COUNT="$(printf '%s' "$DEVICE_SUITE_SEEN" | grep -c '^D' || true)"
    fi
    if [ "$DEVICE_SUITE_OK_COUNT" -eq 27 ]; then
      ok "$DEVICE_SUITE_LABEL (observed: 27/27 distinct D-assertions reported ok in the root stage)"
    else
      DEVICE_SUITE_MISSING=""
      for dn in $(seq 1 27); do
        if ! printf '%s\n' "$DEVICE_SUITE_SEEN" | grep -qx "D$dn"; then
          DEVICE_SUITE_MISSING="$DEVICE_SUITE_MISSING D$dn"
        fi
      done
      fail "$DEVICE_SUITE_LABEL (observed: $DEVICE_SUITE_OK_COUNT of 27 distinct D-assertions reported ok in the root stage; missing:${DEVICE_SUITE_MISSING:- <none>} -- the device suite failed, or was (partly) unplugged and never ran)"
    fi

    # M5 cardinality contract, browser half (briefs/M5-codex-final1.json,
    # M5-R1-1) -- see ROOT_CARDINALITY_LABEL's comment above. Only
    # meaningful on full fixture inputs: under --skip-content the stages
    # lawfully run fewer assertions (check 17's fallback), so the floor is
    # skipped conspicuously there -- via skip(), TOTAL unchanged -- and CI,
    # which forbids skips, still gets the binding floor on every gate run.
    if [ "$SKIP_CONTENT" -eq 1 ]; then
      skip "$ROOT_CARDINALITY_LABEL (only enforced on full fixture inputs -- --skip-content lawfully runs fewer browser assertions)"
      skip "$SUBPATH_CARDINALITY_LABEL (only enforced on full fixture inputs -- --skip-content lawfully runs fewer browser assertions)"
    else
      browser_stage_assertion_floor "${ROOT_BROWSER_STAGE_LOG:-}" "$ROOT_CARDINALITY_LABEL"
      browser_stage_assertion_floor "${SUBPATH_BROWSER_STAGE_LOG:-}" "$SUBPATH_CARDINALITY_LABEL"
    fi

    # Check 23 (M6 W4): the JA course floor -- see JA_COURSE_LABEL's
    # comment above. Scoped exactly like the cardinality floors: the
    # UI-language JA flow (and therefore these five assertions) only
    # runs when the stages got --exercise-fixture, so --skip-content
    # skips it conspicuously via skip() with TOTAL unchanged.
    if [ "$SKIP_CONTENT" -eq 1 ]; then
      skip "$JA_COURSE_LABEL (only enforced on full fixture inputs -- the UI-language JA flow runs only with --exercise-fixture)"
    else
      JA_COURSE_ROOT_OK="$(ja_course_ok_count "${ROOT_BROWSER_STAGE_LOG:-}")"
      JA_COURSE_SUB_OK="$(ja_course_ok_count "${SUBPATH_BROWSER_STAGE_LOG:-}")"
      if [ "$JA_COURSE_ROOT_OK" -eq "$JA_COURSE_ASSERT_COUNT" ] && [ "$JA_COURSE_SUB_OK" -eq "$JA_COURSE_ASSERT_COUNT" ]; then
        ok "$JA_COURSE_LABEL (observed: root $JA_COURSE_ROOT_OK/$JA_COURSE_ASSERT_COUNT, sub-path $JA_COURSE_SUB_OK/$JA_COURSE_ASSERT_COUNT distinct ja course assertions reported ok)"
      else
        fail "$JA_COURSE_LABEL (observed: root $JA_COURSE_ROOT_OK/$JA_COURSE_ASSERT_COUNT, sub-path $JA_COURSE_SUB_OK/$JA_COURSE_ASSERT_COUNT -- a JA course assertion failed, or the JA course block was unplugged and never ran)"
      fi
    fi
  fi
fi

# ===========================================================================
# M5 CARDINALITY CONTRACT, self half (briefs/M5-codex-final1.json, finding
# M5-R1-1): check-site's own final TOTAL -- with this very check counted --
# must equal the pinned M5_CHECK_TOTAL (see the pin's comment near the
# reporting helpers). CI checks exit status, result=complete, zero skips
# and zero FAIL lines, but the total itself was only ever dynamically
# accumulated -- so a deleted check produced a smaller all-green run. This
# is the LAST check on every path, unconditional (never skipped: skip()
# increments TOTAL exactly like ok()/fail(), so the pin holds -- and is
# enforced -- on --skip-browser/--skip-content runs too, which is the
# skip-axis TOTAL-preservation property made load-bearing).
# ===========================================================================
M5_FINAL_TOTAL_WITH_THIS=$((TOTAL + 1))
if [ "$M5_FINAL_TOTAL_WITH_THIS" -eq "$M5_CHECK_TOTAL" ]; then
  ok "M5 cardinality contract: check-site's own final check total is exactly the pinned M5_CHECK_TOTAL=$M5_CHECK_TOTAL (this check included; adding or removing ANY check requires a visible edit to the pin)"
else
  fail "M5 cardinality contract: check-site's own final check total is exactly the pinned M5_CHECK_TOTAL=$M5_CHECK_TOTAL (observed: $M5_FINAL_TOTAL_WITH_THIS with this check included -- a check was added or removed without a visible edit to the pin)"
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
