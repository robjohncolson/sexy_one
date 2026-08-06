#!/usr/bin/env bash
# install-toolchain.sh -- Scripted, pinned, non-Nix install of the GHC
# WebAssembly toolchain used to build the SXC-1 Trainer.
#
# Why not the upstream one-liner?
#   ghc-wasm-meta's own README documents fetching its bootstrap script straight off of
#   gitlab#dot#haskell#dot#org's raw-file endpoint and feeding it directly to a shell
#   interpreter. Do not do that here. That host is behind an "Anubis" proof-of-work
#   anti-bot wall: from this machine, both that raw-file URL and its -/archive/master
#   tarball endpoint return HTTP 200 with Content-Type text/html -- an HTML challenge
#   page -- for both a plain curl user-agent and a spoofed browser user-agent. Feeding
#   that response to an interpreter would execute a web page, not a script.
#   Instead we clone the GitHub read-only mirror at a pinned commit and let git verify
#   integrity by commit hash. The actual binary distributions ghc-wasm-meta's setup.sh
#   downloads (GHC wasm bindist, wasi-sdk, binaryen, node, wasm-tools, cabal) live on
#   GitHub Releases and downloads.haskell.org, both of which ARE reachable from here.
#
# This script never pipes a download into a shell.

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned constants for milestone M0 -- do not substitute.
# ---------------------------------------------------------------------------

# GitHub read-only mirror of ghc-wasm-meta (gitlab.haskell.org is walled off, see above).
GHC_WASM_META_URL="https://github.com/haskell-wasm/ghc-wasm-meta.git"
# Pinned commit on that mirror. HEAD is asserted against this after checkout.
GHC_WASM_META_COMMIT="c75985a1b58fb0376eea9149ba5c7b933b3c7455"
# GHC wasm bindist flavour (base 4.22.0.0, template-haskell 2.24.0.0, text 2.1.3,
# bytestring 0.12.2.0, containers 0.8, mtl 2.3.1, transformers 0.6.1.2,
# ghc-experimental 9.1401.0).
FLAVOUR=9.14
# Toolchain install root. Override with GHC_WASM_PREFIX for testing.
PREFIX="${GHC_WASM_PREFIX:-$HOME/.ghc-wasm}"

# Stamp file recording what got installed, one key=value per line.
STAMP_FILE="$PREFIX/.sxc1-toolchain-stamp"

# Minimum free space required on the filesystem holding $PREFIX, in GiB.
MIN_FREE_GIB=12

# ---------------------------------------------------------------------------
# Repo root, resolved from BASH_SOURCE so this works from any cwd.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
MODE="install"
FORCE=0

usage() {
  cat <<EOF
Usage: $(basename -- "$0") [--check] [--force] [--help]

Install the pinned GHC WebAssembly toolchain (ghc-wasm-meta @
${GHC_WASM_META_COMMIT}, FLAVOUR=${FLAVOUR}) into \$PREFIX
(currently: ${PREFIX}).

Options:
  --check    Report whether a working install already exists. Performs no
             downloads. Exits 0 if installed and healthy, non-zero otherwise.
  --force    Reinstall even if --check would already succeed. WARNING: the
             upstream setup.sh begins with 'rm -rf "\$PREFIX"'.
  --help     Show this message and exit.

Environment:
  GHC_WASM_PREFIX   Override the install prefix (default: \$HOME/.ghc-wasm).

After install, activate the toolchain in any shell with:
  . "${PREFIX}/env"
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --check)
      MODE="check"
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    *)
      echo "install-toolchain.sh: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight: required commands and disk space.
# ---------------------------------------------------------------------------
preflight() {
  local required=(git curl tar xz unzip unzstd jq make cc sed realpath)
  local missing=()
  local c
  for c in "${required[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "install-toolchain.sh: missing required commands: ${missing[*]}" >&2
    echo "Install these and re-run." >&2
    exit 1
  fi

  # Disk space check: at least MIN_FREE_GIB free on the filesystem holding $PREFIX.
  # $PREFIX itself may not exist yet, so check its parent (walking up if necessary).
  local check_dir="$PREFIX"
  while [ ! -d "$check_dir" ] && [ "$check_dir" != "/" ]; do
    check_dir="$(dirname -- "$check_dir")"
  done
  if [ ! -d "$check_dir" ]; then
    check_dir="/"
  fi

  local avail_kib
  avail_kib="$(df -Pk "$check_dir" | awk 'NR==2 { print $4 }')"
  if [ -z "$avail_kib" ]; then
    echo "install-toolchain.sh: could not determine free disk space for $check_dir" >&2
    exit 1
  fi
  local avail_gib=$((avail_kib / 1024 / 1024))
  if [ "$avail_gib" -lt "$MIN_FREE_GIB" ]; then
    echo "install-toolchain.sh: need at least ${MIN_FREE_GIB} GiB free on the filesystem" \
         "holding $PREFIX (found ${avail_gib} GiB at $check_dir)" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# --check mode / idempotency probe. No downloads. No network access.
# ---------------------------------------------------------------------------
# Prints a short report and returns 0 if a healthy install is found, 1 otherwise.
check_installed() {
  local quiet="${1:-0}"

  if [ ! -r "$PREFIX/env" ]; then
    [ "$quiet" = "1" ] || echo "install-toolchain.sh --check: $PREFIX/env not found or not readable"
    return 1
  fi

  local ghc_bin="$PREFIX/wasm32-wasi-ghc/bin/wasm32-wasi-ghc"
  if [ ! -x "$ghc_bin" ]; then
    [ "$quiet" = "1" ] || echo "install-toolchain.sh --check: $ghc_bin not found"
    return 1
  fi

  local version
  if ! version="$("$ghc_bin" --numeric-version 2>/dev/null)"; then
    [ "$quiet" = "1" ] || echo "install-toolchain.sh --check: wasm32-wasi-ghc --numeric-version failed"
    return 1
  fi

  if [ "$quiet" != "1" ]; then
    echo "install-toolchain.sh --check: installed and healthy"
    echo "  wasm32-wasi-ghc version : $version"
    echo "  PREFIX                  : $PREFIX"
    if [ -r "$STAMP_FILE" ]; then
      echo "  recorded pin:"
      sed 's/^/    /' "$STAMP_FILE"
    else
      echo "  (no stamp file at $STAMP_FILE)"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --check mode entry point
# ---------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  preflight
  if check_installed; then
    exit 0
  else
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Normal (install) mode
# ---------------------------------------------------------------------------
preflight

if [ "$FORCE" != "1" ] && check_installed 1; then
  echo "toolchain already installed (use --force to reinstall)"
  exit 0
fi

if [ "$FORCE" = "1" ] && [ -e "$PREFIX" ]; then
  echo "install-toolchain.sh: --force given. ghc-wasm-meta's setup.sh begins with" >&2
  echo "  rm -rf \"$PREFIX\"" >&2
  echo "About to remove and reinstall: $PREFIX" >&2
fi

tmp=""
cleanup() {
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    rm -rf -- "$tmp"
  fi
}
trap cleanup EXIT

tmp="$(mktemp -d)"

echo "install-toolchain.sh: cloning ghc-wasm-meta (this is git+GitHub, not gitlab.haskell.org)"
git clone "$GHC_WASM_META_URL" "$tmp/ghc-wasm-meta"
git -C "$tmp/ghc-wasm-meta" checkout --detach "$GHC_WASM_META_COMMIT"

resolved_head="$(git -C "$tmp/ghc-wasm-meta" rev-parse HEAD)"
if [ "$resolved_head" != "$GHC_WASM_META_COMMIT" ]; then
  echo "install-toolchain.sh: checked-out HEAD ($resolved_head) does not match the pinned" >&2
  echo "  commit ($GHC_WASM_META_COMMIT). Aborting." >&2
  exit 1
fi
echo "install-toolchain.sh: verified HEAD == pinned commit $GHC_WASM_META_COMMIT"

echo "install-toolchain.sh: running setup.sh (FLAVOUR=$FLAVOUR PREFIX=$PREFIX)"
FLAVOUR="$FLAVOUR" PREFIX="$PREFIX" bash "$tmp/ghc-wasm-meta/setup.sh"

# ---------------------------------------------------------------------------
# Post-install verification.
# ---------------------------------------------------------------------------
ghc_version=""
cabal_version_line=""
have_wasm_opt="no"
have_wasm_tools="no"

(
  set +u
  # shellcheck disable=SC1091
  . "$PREFIX/env"
  set -u

  if ! command -v wasm32-wasi-ghc >/dev/null 2>&1; then
    echo "install-toolchain.sh: wasm32-wasi-ghc not on PATH after sourcing $PREFIX/env" >&2
    exit 1
  fi
  if ! command -v wasm32-wasi-cabal >/dev/null 2>&1; then
    echo "install-toolchain.sh: wasm32-wasi-cabal not on PATH after sourcing $PREFIX/env" >&2
    exit 1
  fi

  echo "wasm32-wasi-ghc --numeric-version:"
  wasm32-wasi-ghc --numeric-version | tee "$tmp/ghc-version.txt"

  echo "wasm32-wasi-cabal --version | head -1:"
  wasm32-wasi-cabal --version | head -1 | tee "$tmp/cabal-version.txt"

  if command -v wasm-opt >/dev/null 2>&1; then
    echo "wasm-opt: found on PATH ($(command -v wasm-opt))"
  else
    echo "wasm-opt: NOT found on PATH (optional; used only by --optimize builds)"
  fi

  if command -v wasm-tools >/dev/null 2>&1; then
    echo "wasm-tools: found on PATH ($(command -v wasm-tools))"
  else
    echo "wasm-tools: NOT found on PATH (optional; used only by --optimize builds)"
  fi
)

ghc_version="$(cat "$tmp/ghc-version.txt" 2>/dev/null || true)"
cabal_version_line="$(cat "$tmp/cabal-version.txt" 2>/dev/null || true)"

if [ -z "$ghc_version" ]; then
  echo "install-toolchain.sh: could not determine wasm32-wasi-ghc version; aborting" >&2
  exit 1
fi
if [ -z "$cabal_version_line" ]; then
  echo "install-toolchain.sh: could not determine wasm32-wasi-cabal version; aborting" >&2
  exit 1
fi

(
  set +u
  . "$PREFIX/env"
  set -u
  command -v wasm-opt >/dev/null 2>&1 && have_wasm_opt="yes" || have_wasm_opt="no"
  command -v wasm-tools >/dev/null 2>&1 && have_wasm_tools="yes" || have_wasm_tools="no"
  echo "$have_wasm_opt" > "$tmp/have-wasm-opt.txt"
  echo "$have_wasm_tools" > "$tmp/have-wasm-tools.txt"
)
have_wasm_opt="$(cat "$tmp/have-wasm-opt.txt" 2>/dev/null || echo no)"
have_wasm_tools="$(cat "$tmp/have-wasm-tools.txt" 2>/dev/null || echo no)"

# ---------------------------------------------------------------------------
# Stamp file: pinned commit, flavour, resolved GHC version, ISO-8601 UTC timestamp.
# ---------------------------------------------------------------------------
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "ghc_wasm_meta_commit=$GHC_WASM_META_COMMIT"
  echo "flavour=$FLAVOUR"
  echo "ghc_version=$ghc_version"
  echo "installed_at=$timestamp"
} > "$STAMP_FILE"

echo ""
echo "install-toolchain.sh: install complete."
echo "  wasm32-wasi-ghc version : $ghc_version"
echo "  wasm32-wasi-cabal       : $cabal_version_line"
echo "  wasm-opt on PATH        : $have_wasm_opt"
echo "  wasm-tools on PATH      : $have_wasm_tools"
echo "  stamp file              : $STAMP_FILE"
echo ""
echo "Next: source the toolchain env for manual work:"
echo "  . \"$PREFIX/env\""
echo "Then build the site with:"
echo "  ./scripts/build-site.sh"
