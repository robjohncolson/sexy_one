#!/usr/bin/env bash
# install-toolchain.sh -- Scripted, pinned, non-Nix install of the GHC
# WebAssembly toolchain used to build the SXC-1 Trainer.
#
# Why not the upstream one-liner?
#   ghc-wasm-meta's own README documents fetching its bootstrap script straight off of
#   gitlab.haskell.org's raw-file endpoint and feeding it directly to a shell
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

# Stamp file recording what got installed, one key=value per line. Recomputed
# once PREFIX has been canonicalised and validated, below.
STAMP_FILE="$PREFIX/.sxc1-toolchain-stamp"

# Minimum free space required on the filesystem holding $PREFIX, in GiB.
MIN_FREE_GIB=12

# Environment variables the pinned setup.sh itself reads to redirect downloads away
# from the pinned/hashed sources in autogen.json, or to silently skip installing the
# compiler (M2). Re-check this list against setup.sh whenever GHC_WASM_META_COMMIT is
# bumped:
#   UPSTREAM_WASI_SDK_PIPELINE_ID                 (~line 104: redirects wasi-sdk to an
#                                                    unpinned, unhashed GitLab artifact)
#   UPSTREAM_GHC_PIPELINE_ID / UPSTREAM_GHC_PROJECT_ID / UPSTREAM_GHC_JOB_NAME
#                                                  (~lines 206-211: same, for GHC itself)
#   SKIP_GHC                                      (~line 199: wipes PREFIX, installs no
#                                                    compiler, and exits 0)
#   PLAYWRIGHT                                    (~line 126: triggers an unrelated,
#                                                    unhashed download+install)
#   NIX_SYSTEM                                    (~line 48: only affects host detection
#                                                    on Darwin, but we scrub it too since
#                                                    it is one more ambient input)
# setup.sh is always invoked with every one of these explicitly unset via `env -u`,
# regardless of what this script's own caller happened to export.
UPSTREAM_CONTROL_VARS=(
  UPSTREAM_WASI_SDK_PIPELINE_ID
  UPSTREAM_GHC_PIPELINE_ID
  UPSTREAM_GHC_PROJECT_ID
  UPSTREAM_GHC_JOB_NAME
  SKIP_GHC
  PLAYWRIGHT
  NIX_SYSTEM
)

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
Usage: $(basename -- "$0") [--check] [--force] [--verify-sri-selftest] [--help]

Install the pinned GHC WebAssembly toolchain (ghc-wasm-meta @
${GHC_WASM_META_COMMIT}, FLAVOUR=${FLAVOUR}) into \$PREFIX
(currently: ${PREFIX}).

Options:
  --check
      Run only the runtime health probe: does a working, correctly-pinned
      install already exist? Performs no downloads, no network access, and
      does not require any install-only prerequisite (git, unzip, a C
      compiler, ...) to be on PATH. Exits 0 if installed and healthy
      (stamp matches the pinned commit/flavour, the live compiler version
      matches the stamp, and cabal runs), non-zero otherwise, naming the
      specific mismatch.
  --force
      Reinstall even if --check would already succeed. WARNING: the
      upstream setup.sh begins with 'rm -rf "\$PREFIX"'. This never
      overrides the prefix safety checks below -- it only permits
      reinstalling over what is already a recognized toolchain install.
  --verify-sri-selftest
      Regression-test the SRI digest comparator (sha256 and sha512, one
      known-good and one known-bad value each) against an in-memory fixture
      and exit non-zero if it misclassifies any of them. No network access,
      no PREFIX involved. Exists so the download-integrity control can be
      tested in about one second instead of via a full reinstall.
  --help
      Show this message and exit.

Environment:
  GHC_WASM_PREFIX   Override the install prefix (default: \$HOME/.ghc-wasm).
                     Rejected outright if it is empty, "/", exactly \$HOME,
                     the repository root (or inside it), an ancestor of
                     either, contains "..", or already exists as a non-empty
                     directory that is not a recognized toolchain install.
                     There is no override for any of these checks.

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
    --verify-sri-selftest)
      MODE="selftest"
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
# SRI digest comparator -- shared by the curl-interception shim (M1), by
# --verify-sri-selftest, and by nothing else. Defined early so both can use
# it; the shim gets its own copy embedded via `declare -f` (see
# generate_curl_shim), since it runs as a separate process.
# ---------------------------------------------------------------------------

# Reads base64 on stdin, writes lowercase hex (no trailing newline) on stdout.
b64_to_hex() {
  if command -v xxd >/dev/null 2>&1; then
    base64 -d 2>/dev/null | xxd -p -c256 | tr -d '\n'
  else
    base64 -d 2>/dev/null | od -An -tx1 -v | tr -d ' \n'
  fi
}

# sri_verify_digest <sri-value> <file>
#   sri-value is "sha256-<base64>" or "sha512-<base64>" (npm/W3C SRI style, as used
#   verbatim by autogen.json). Returns 0 on match, 1 on a verified mismatch (prints
#   the expected and actual hex digests to stderr), 2 if the SRI value itself is
#   unusable (bad prefix / undecodable base64).
sri_verify_digest() {
  local sri="$1" file="$2"
  local algo b64 want_hex actual_hex
  case "$sri" in
    sha256-*) algo=sha256; b64="${sri#sha256-}" ;;
    sha512-*) algo=sha512; b64="${sri#sha512-}" ;;
    *)
      echo "sri-verify: unrecognized SRI hash format (want sha256-... or sha512-...): $sri" >&2
      return 2
      ;;
  esac

  want_hex="$(printf '%s' "$b64" | b64_to_hex)"
  if [ -z "$want_hex" ]; then
    echo "sri-verify: could not base64-decode SRI value: $sri" >&2
    return 2
  fi
  want_hex="$(printf '%s' "$want_hex" | tr '[:upper:]' '[:lower:]')"

  case "$algo" in
    sha256) actual_hex="$(sha256sum -- "$file" | awk '{print $1}')" ;;
    sha512) actual_hex="$(sha512sum -- "$file" | awk '{print $1}')" ;;
  esac
  actual_hex="$(printf '%s' "$actual_hex" | tr '[:upper:]' '[:lower:]')"

  if [ "$want_hex" = "$actual_hex" ]; then
    return 0
  fi
  echo "sri-verify: DIGEST MISMATCH ($algo)" >&2
  echo "  expected: $want_hex" >&2
  echo "  actual:   $actual_hex" >&2
  return 1
}

# ---------------------------------------------------------------------------
# --verify-sri-selftest: exercise sri_verify_digest against known values.
# Fixture text and its precomputed correct SRI hashes are fixed constants
# (computed once, offline, with sha256sum/sha512sum/base64 -- not derived at
# runtime) so this mode needs no hex<->base64 round trip beyond the one
# sri_verify_digest itself performs, and no network access.
# ---------------------------------------------------------------------------
run_sri_selftest() {
  local fixture
  fixture="$(mktemp)"

  printf 'sxc1-toolchain-installer-sri-selftest-fixture\n' > "$fixture"

  local good256="sha256-JJXDI9y9RLmrDqR8YAcAHN/7+wdzBxM/ZbKkn2u6V6w="
  local good512="sha512-2DKNDwCpWHGxds/zncMwjSmy4KW4lu1/gXpZKArdfQs5UztN/UXhGjNbncMEfuhgt7s3z9bugkUdpZloUYo5uQ=="
  # Same length/alphabet as the good values, single leading byte flipped: still
  # valid base64, guaranteed-wrong digest.
  local bad256="sha256-AJXDI9y9RLmrDqR8YAcAHN/7+wdzBxM/ZbKkn2u6V6w="
  local bad512="sha512-ADKNDwCpWHGxds/zncMwjSmy4KW4lu1/gXpZKArdfQs5UztN/UXhGjNbncMEfuhgt7s3z9bugkUdpZloUYo5uQ=="

  local failures=0

  if sri_verify_digest "$good256" "$fixture" >/dev/null 2>&1; then
    echo "selftest: ok   - sha256 known-good digest accepted"
  else
    echo "selftest: FAIL - sha256 known-good digest was rejected" >&2
    failures=$((failures + 1))
  fi

  if sri_verify_digest "$bad256" "$fixture" >/dev/null 2>&1; then
    echo "selftest: FAIL - sha256 known-bad digest was accepted" >&2
    failures=$((failures + 1))
  else
    echo "selftest: ok   - sha256 known-bad digest rejected"
  fi

  if sri_verify_digest "$good512" "$fixture" >/dev/null 2>&1; then
    echo "selftest: ok   - sha512 known-good digest accepted"
  else
    echo "selftest: FAIL - sha512 known-good digest was rejected" >&2
    failures=$((failures + 1))
  fi

  if sri_verify_digest "$bad512" "$fixture" >/dev/null 2>&1; then
    echo "selftest: FAIL - sha512 known-bad digest was accepted" >&2
    failures=$((failures + 1))
  else
    echo "selftest: ok   - sha512 known-bad digest rejected"
  fi

  rm -f "$fixture"

  if [ "$failures" -gt 0 ]; then
    echo "install-toolchain.sh --verify-sri-selftest: FAILED ($failures problem(s))" >&2
    return 1
  fi
  echo "install-toolchain.sh --verify-sri-selftest: ok (sha256 + sha512, good + bad correctly classified)"
  return 0
}

if [ "$MODE" = "selftest" ]; then
  if run_sri_selftest; then
    exit 0
  else
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# B1: prefix safety guard. Runs before anything else that touches $PREFIX --
# in particular strictly before any preflight check and strictly before the
# git clone, so a refusal never touches the network or the filesystem
# destructively. There is NO --force override for anything in this
# function: --force only ever means "reinstall over an existing toolchain",
# never "wipe whatever happens to be at this path".
#
# Deliberately NOT implemented: installing into a fresh staging directory
# and renaming it into place. That is unsafe for this toolchain specifically
# -- $PREFIX/env bakes in 21 hard-coded absolute paths (e.g.
# "export PATH=$PREFIX/wasm-run/bin:$PATH", "CC=$PREFIX/wasi-sdk/bin/..."),
# so a rename after the fact would leave every one of them dangling. Do not
# re-add a staging/rename scheme; canonicalise-and-refuse is the fix.
# ---------------------------------------------------------------------------

# path_is_ancestor_or_self <anc> <desc>
#   True if <anc> and <desc> are the same path, or <desc> is (transitively)
#   inside <anc>. Both arguments must already be absolute, canonical paths.
path_is_ancestor_or_self() {
  local anc="$1" desc="$2"
  if [ "$anc" = "$desc" ]; then
    return 0
  fi
  case "$anc" in
    /)
      case "$desc" in
        /*) return 0 ;;
      esac
      ;;
    *)
      case "$desc" in
        "$anc"/*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# validate_prefix <raw-prefix>
#   On success: sets RESOLVED_PREFIX to the canonicalised, safe path and
#   returns 0. On refusal: prints why to stderr and returns 1 (never calls
#   `exit` itself -- it may be invoked from contexts where that would only
#   terminate a subshell).
validate_prefix() {
  local raw="$1"
  RESOLVED_PREFIX=""

  case "$raw" in
    *..*)
      echo "install-toolchain.sh: refusing prefix containing '..': $raw" >&2
      return 1
      ;;
  esac
  if [ -z "$raw" ]; then
    echo "install-toolchain.sh: refusing empty toolchain prefix" >&2
    return 1
  fi

  local resolved home_resolved repo_resolved
  resolved="$(realpath -m -- "$raw")"
  home_resolved="$(realpath -m -- "$HOME")"
  repo_resolved="$(realpath -m -- "$REPO_ROOT")"

  if [ "$resolved" = "/" ]; then
    echo "install-toolchain.sh: refusing '/' as the toolchain prefix" >&2
    return 1
  fi

  if [ "$resolved" = "$home_resolved" ]; then
    echo "install-toolchain.sh: refusing \$HOME ($resolved) as the toolchain prefix" >&2
    return 1
  fi

  if path_is_ancestor_or_self "$resolved" "$home_resolved"; then
    echo "install-toolchain.sh: refusing prefix that is an ancestor of \$HOME" \
         "($home_resolved): $resolved" >&2
    return 1
  fi

  if path_is_ancestor_or_self "$repo_resolved" "$resolved"; then
    echo "install-toolchain.sh: refusing prefix at or inside the repository root" \
         "($repo_resolved): $resolved" >&2
    return 1
  fi

  if path_is_ancestor_or_self "$resolved" "$repo_resolved"; then
    echo "install-toolchain.sh: refusing prefix that is an ancestor of the" \
         "repository root ($repo_resolved): $resolved" >&2
    return 1
  fi

  if [ -e "$resolved" ]; then
    if [ ! -d "$resolved" ]; then
      echo "install-toolchain.sh: refusing prefix that exists and is not a directory: $resolved" >&2
      return 1
    fi
    if [ -n "$(ls -A -- "$resolved" 2>/dev/null)" ]; then
      if [ -f "$resolved/.sxc1-toolchain-stamp" ]; then
        : # recognized as one of our toolchain installs
      elif [ -f "$resolved/env" ] && [ -d "$resolved/wasm32-wasi-ghc" ]; then
        : # recognized as one of our toolchain installs
      else
        echo "install-toolchain.sh: refusing existing non-empty directory that is not a" >&2
        echo "  recognized toolchain install: $resolved" >&2
        echo "  (looked for .sxc1-toolchain-stamp, or both an 'env' file and a" >&2
        echo "  'wasm32-wasi-ghc/' directory). Pick an empty or new directory for" >&2
        echo "  GHC_WASM_PREFIX. --force does not override this." >&2
        return 1
      fi
    fi
  fi

  RESOLVED_PREFIX="$resolved"
  return 0
}

if ! validate_prefix "$PREFIX"; then
  exit 1
fi
PREFIX="$RESOLVED_PREFIX"
STAMP_FILE="$PREFIX/.sxc1-toolchain-stamp"

# ---------------------------------------------------------------------------
# Preflight for a real install: build/download prerequisites plus free disk
# space. NOT run for --check (m4) -- a health probe over an already-complete
# install has no business requiring unzip, a C compiler, or 12 GiB free.
# ---------------------------------------------------------------------------
preflight_install() {
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
# M3: strict runtime health check. No downloads, no network access, no
# install-only prerequisites (m4). A toolchain is healthy only if the stamp
# file exists, parses cleanly, its pinned commit and flavour match this
# script's constants, the live compiler's version matches what the stamp
# recorded, and cabal actually runs -- so a stale toolchain restored from a
# cache under an old pin reads as unhealthy and gets reinstalled instead of
# silently passing.
# ---------------------------------------------------------------------------
health_check() {
  local quiet="${1:-0}"
  local reason=""
  local st_commit="" st_flavour="" st_ghc_version=""

  if [ ! -f "$STAMP_FILE" ] || [ ! -r "$STAMP_FILE" ]; then
    reason="stamp file missing or unreadable: $STAMP_FILE"
  else
    local line key value parse_ok=1
    while IFS= read -r line || [ -n "$line" ]; do
      [ -z "$line" ] && continue
      case "$line" in
        *=*)
          key="${line%%=*}"
          value="${line#*=}"
          ;;
        *)
          parse_ok=0
          break
          ;;
      esac
      case "$key" in
        ghc_wasm_meta_commit) st_commit="$value" ;;
        flavour) st_flavour="$value" ;;
        ghc_version) st_ghc_version="$value" ;;
      esac
    done < "$STAMP_FILE"

    if [ "$parse_ok" != "1" ]; then
      reason="stamp file is not valid key=value lines: $STAMP_FILE"
    elif [ "$st_commit" != "$GHC_WASM_META_COMMIT" ]; then
      reason="stamp ghc_wasm_meta_commit ('$st_commit') != pinned commit ($GHC_WASM_META_COMMIT)"
    elif [ "$st_flavour" != "$FLAVOUR" ]; then
      reason="stamp flavour ('$st_flavour') != pinned flavour ($FLAVOUR)"
    else
      local ghc_bin="$PREFIX/wasm32-wasi-ghc/bin/wasm32-wasi-ghc"
      local cabal_bin="$PREFIX/wasm32-wasi-cabal/bin/wasm32-wasi-cabal"
      local live_version
      if [ ! -x "$ghc_bin" ]; then
        reason="$ghc_bin not found or not executable"
      elif ! live_version="$("$ghc_bin" --numeric-version 2>/dev/null)"; then
        reason="$ghc_bin --numeric-version failed"
      elif [ "$live_version" != "$st_ghc_version" ]; then
        reason="live wasm32-wasi-ghc version ($live_version) != stamp ghc_version ($st_ghc_version)"
      elif [ ! -x "$cabal_bin" ]; then
        reason="$cabal_bin not found or not executable"
      elif ! "$cabal_bin" --version >/dev/null 2>&1; then
        reason="$cabal_bin --version failed"
      fi
    fi
  fi

  if [ -n "$reason" ]; then
    [ "$quiet" = "1" ] || echo "install-toolchain.sh --check: UNHEALTHY: $reason" >&2
    return 1
  fi

  if [ "$quiet" != "1" ]; then
    echo "install-toolchain.sh --check: installed and healthy"
    echo "  wasm32-wasi-ghc version : $st_ghc_version"
    echo "  PREFIX                  : $PREFIX"
    echo "  recorded pin:"
    sed 's/^/    /' "$STAMP_FILE"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# --check mode entry point: health check only (m4). No preflight_install.
# ---------------------------------------------------------------------------
if [ "$MODE" = "check" ]; then
  if health_check 0; then
    exit 0
  else
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Normal (install) mode
# ---------------------------------------------------------------------------
preflight_install

if [ "$FORCE" != "1" ] && health_check 1; then
  echo "toolchain already installed and healthy (use --force to reinstall)"
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

# ---------------------------------------------------------------------------
# M1: intercept every `curl ... -o <file>` setup.sh performs with a shim that
# resolves the real curl by absolute path (captured now, before PATH is
# touched -- never by a later PATH lookup, which would recurse into itself),
# and verifies the downloaded file's SRI digest from the pinned clone's own
# autogen.json before letting setup.sh proceed to extract/install it.
# Fails closed: any -o download whose URL is not listed in autogen.json
# aborts the install.
# ---------------------------------------------------------------------------
real_curl="$(command -v curl)"
if [ -z "$real_curl" ]; then
  echo "install-toolchain.sh: curl not found (should have been caught by preflight)" >&2
  exit 1
fi

shim_dir="$tmp/curl-sri-shim"
sri_count_file="$tmp/.sri-verified-count"
: > "$sri_count_file"

generate_curl_shim() {
  local shim_dir="$1" real_curl="$2" autogen_json="$3" count_file="$4"
  mkdir -p "$shim_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'REAL_CURL=%q\n' "$real_curl"
    printf 'AUTOGEN_JSON=%q\n' "$autogen_json"
    printf 'COUNT_FILE=%q\n' "$count_file"
    echo
    # Embed the exact digest-comparison code this script already validated via
    # --verify-sri-selftest -- one source of truth, textually copied in.
    declare -f b64_to_hex
    declare -f sri_verify_digest
    echo
    cat <<'SHIM_BODY'
# Forward everything to the real curl first. Under `set -e` a failing
# download aborts this shim (and therefore setup.sh) with curl's own exit
# code, same as if no shim were present.
"$REAL_CURL" "$@"

# Find "-o <file>" and an http(s) URL among our own argv. All seven
# downloads in the pinned setup.sh pass the URL positionally and "-o <file>"
# after it; this loop does not depend on that order.
outfile=""
url=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then
    outfile="$arg"
    prev=""
    continue
  fi
  case "$arg" in
    -o)
      prev="-o"
      continue
      ;;
    http://*|https://*)
      url="$arg"
      ;;
  esac
  prev=""
done

if [ -z "$outfile" ]; then
  # Not a file download (e.g. a GitLab API call whose output is piped to
  # jq). Nothing to verify. With UPSTREAM_* scrubbed (M2) this path is not
  # expected to be hit at all on this host.
  exit 0
fi

if [ -z "$url" ]; then
  echo "curl-sri-shim: refusing: '-o $outfile' download with no discernible http(s) URL among curl arguments" >&2
  exit 1
fi

expected_sri="$(jq -r --arg u "$url" 'to_entries[] | select(.value.url == $u) | .value.hash' "$AUTOGEN_JSON" 2>/dev/null | head -n1)"
if [ -z "$expected_sri" ] || [ "$expected_sri" = "null" ]; then
  echo "curl-sri-shim: FAIL CLOSED: no pinned SRI hash found for $url in $AUTOGEN_JSON" >&2
  echo "  ($outfile was downloaded but will not be trusted; aborting the install)" >&2
  exit 1
fi

if sri_verify_digest "$expected_sri" "$outfile"; then
  echo "curl-sri-shim: verified $url"
  printf '%s\n' "$url" >> "$COUNT_FILE"
  exit 0
else
  echo "curl-sri-shim: aborting: $url failed SRI verification (pinned: $expected_sri)" >&2
  exit 1
fi
SHIM_BODY
  } > "$shim_dir/curl"
  chmod +x "$shim_dir/curl"
}

generate_curl_shim "$shim_dir" "$real_curl" "$tmp/ghc-wasm-meta/autogen.json" "$sri_count_file"

# ---------------------------------------------------------------------------
# M2: run setup.sh with every upstream control variable explicitly unset,
# regardless of what this script's caller has ambiently exported, plus the
# SRI-verifying curl shim prepended to PATH.
# ---------------------------------------------------------------------------
env_unset_args=()
for v in "${UPSTREAM_CONTROL_VARS[@]}"; do
  env_unset_args+=(-u "$v")
done

echo "install-toolchain.sh: running setup.sh (FLAVOUR=$FLAVOUR PREFIX=$PREFIX)"
echo "install-toolchain.sh: all curl downloads are SRI-verified against the pinned autogen.json"
env "${env_unset_args[@]}" \
    FLAVOUR="$FLAVOUR" \
    PREFIX="$PREFIX" \
    PATH="$shim_dir:$PATH" \
    bash "$tmp/ghc-wasm-meta/setup.sh"

sri_verified_downloads="$(wc -l < "$sri_count_file" | tr -d ' ')"
echo "install-toolchain.sh: SRI-verified $sri_verified_downloads download(s)"

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
# Stamp file: pinned commit, flavour, resolved GHC version, ISO-8601 UTC
# timestamp, and (M1) how many downloads the SRI verifier actually checked.
# ---------------------------------------------------------------------------
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
  echo "ghc_wasm_meta_commit=$GHC_WASM_META_COMMIT"
  echo "flavour=$FLAVOUR"
  echo "ghc_version=$ghc_version"
  echo "installed_at=$timestamp"
  echo "sri_verified_downloads=$sri_verified_downloads"
} > "$STAMP_FILE"

echo ""
echo "install-toolchain.sh: install complete."
echo "  wasm32-wasi-ghc version : $ghc_version"
echo "  wasm32-wasi-cabal       : $cabal_version_line"
echo "  wasm-opt on PATH        : $have_wasm_opt"
echo "  wasm-tools on PATH      : $have_wasm_tools"
echo "  SRI-verified downloads  : $sri_verified_downloads"
echo "  stamp file              : $STAMP_FILE"
echo ""
echo "Next: source the toolchain env for manual work:"
echo "  . \"$PREFIX/env\""
echo "Then build the site with:"
echo "  ./scripts/build-site.sh"
