#!/usr/bin/env bash
# Build site/public/ from site/app (Haskell/Miso, compiled to WebAssembly) and
# site/static (the HTML shell, boot loader, and vendored WASI shim).
#
# Usage: ./scripts/build-site.sh [--optimize] [--update] [--help]
set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the repo root from BASH_SOURCE so this works from any cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd)"

OPTIMIZE=0
CABAL_UPDATE=0

print_help() {
  cat <<'EOF'
build-site.sh - build the SXC-1 Trainer WASM app and assemble site/public/

Usage: ./scripts/build-site.sh [options]

Options:
  --optimize   Run wasm-opt -O2 and wasm-tools strip on app.wasm after the
               JSFFI post-link step. Off by default: binaryen is the one
               step in this pipeline that can silently miscompile GHC
               output, so M0's definition of done must not depend on it.
  --update     Run `wasm32-wasi-cabal update` before building. Not needed
               normally: scripts/install-toolchain.sh already refreshes the
               package index, and the pinned index-state in
               site/cabal.project makes resolution deterministic without it.
               This flag is an escape hatch for a stale/corrupt local index.
  --help       Show this message and exit.

Environment:
  GHC_WASM_PREFIX   Toolchain root (default: $HOME/.ghc-wasm). Must contain
                     an `env` script written by scripts/install-toolchain.sh.
  SXC1_JOBS         Parallel GHC jobs for `cabal build -j` (default: 2).
                     This machine has 4 cores but limited RAM/swap, so the
                     default deliberately undercuts the toolchain's usual
                     $ncpus default to avoid the OOM killer. Try
                     SXC1_JOBS=1 if a build gets OOM-killed.

Output:
  site/public/  containing index.html, index.js, app.wasm,
                ghc_wasm_jsffi.js, .nojekyll and vendor/browser_wasi_shim/
EOF
}

for arg in "$@"; do
  case "$arg" in
    --optimize) OPTIMIZE=1 ;;
    --update)   CABAL_UPDATE=1 ;;
    --help|-h)  print_help; exit 0 ;;
    *)
      echo "build-site.sh: unrecognized option: $arg" >&2
      print_help >&2
      exit 1
      ;;
  esac
done

# ---------------------------------------------------------------------------
# 1. Activate the GHC WebAssembly toolchain.
# ---------------------------------------------------------------------------
PREFIX="${GHC_WASM_PREFIX:-$HOME/.ghc-wasm}"
if [ ! -f "$PREFIX/env" ]; then
  echo "GHC WebAssembly toolchain not found - run ./scripts/install-toolchain.sh" >&2
  exit 1
fi
# shellcheck disable=SC1091
. "$PREFIX/env"

# ---------------------------------------------------------------------------
# 2. Parallelism: deliberately conservative default (see --help above).
# ---------------------------------------------------------------------------
JOBS="${SXC1_JOBS:-2}"

START_TIME=$(date +%s)

# ---------------------------------------------------------------------------
# 3. Build the wasm32-wasi executable.
# ---------------------------------------------------------------------------
cd "$REPO_ROOT/site"

if [ "$CABAL_UPDATE" -eq 1 ]; then
  wasm32-wasi-cabal update
fi

wasm32-wasi-cabal build -j"$JOBS" exe:app

# ---------------------------------------------------------------------------
# 4. Locate the built binary.
# ---------------------------------------------------------------------------
WASM="$(wasm32-wasi-cabal list-bin exe:app | tail -n1)"
if [ ! -f "$WASM" ]; then
  echo "build-site.sh: expected a built binary at '$WASM' but found none" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Assemble site/public/ from the static shell.
# ---------------------------------------------------------------------------
rm -rf "$REPO_ROOT/site/public"
mkdir -p "$REPO_ROOT/site/public"
cp -R "$REPO_ROOT/site/static/." "$REPO_ROOT/site/public/"

# ---------------------------------------------------------------------------
# 6. Run the JSFFI post-link step BEFORE any stripping: stripping removes
#    the custom wasm section post-link.mjs reads to emit ghc_wasm_jsffi.js.
# ---------------------------------------------------------------------------
"$(wasm32-wasi-ghc --print-libdir)/post-link.mjs" --input "$WASM" \
    --output "$REPO_ROOT/site/public/ghc_wasm_jsffi.js"

# ---------------------------------------------------------------------------
# 7. Copy the wasm binary under its canonical name.
# ---------------------------------------------------------------------------
cp "$WASM" "$REPO_ROOT/site/public/app.wasm"

# ---------------------------------------------------------------------------
# 8. Optional optimisation pass (opt-in only).
# ---------------------------------------------------------------------------
if [ "$OPTIMIZE" -eq 1 ]; then
  if command -v wasm-opt >/dev/null 2>&1 && command -v wasm-tools >/dev/null 2>&1; then
    wasm-opt -all -O2 "$REPO_ROOT/site/public/app.wasm" -o "$REPO_ROOT/site/public/app.opt.wasm"
    wasm-tools strip -o "$REPO_ROOT/site/public/app.wasm" "$REPO_ROOT/site/public/app.opt.wasm"
    rm -f "$REPO_ROOT/site/public/app.opt.wasm"
  else
    echo "build-site.sh: --optimize requested but wasm-opt/wasm-tools not on PATH; skipping" >&2
  fi
fi

# ---------------------------------------------------------------------------
# 9. Summary.
# ---------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

GHC_VERSION="$(wasm32-wasi-ghc --numeric-version)"

wasm_size() {
  local f="$1"
  local raw gz
  raw=$(wc -c < "$f")
  gz=$(gzip -c "$f" | wc -c)
  echo "$raw bytes raw, $gz bytes gzipped"
}

echo "build-site: done in ${DURATION}s (GHC ${GHC_VERSION})"
echo "build-site: app.wasm            -> $(wasm_size "$REPO_ROOT/site/public/app.wasm")"
echo "build-site: ghc_wasm_jsffi.js    -> $(wasm_size "$REPO_ROOT/site/public/ghc_wasm_jsffi.js")"
