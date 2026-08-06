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
# Final machine-readable marker (last line before the exit code, see check
# 8 below):
#   check-site: result=complete         every axis (including the browser
#                                        axis) actually ran.
#   check-site: result=structural-only  the browser axis was skipped via
#                                        --skip-browser / SXC1_SKIP_BROWSER=1.
# CI must assert result=complete so a silently skipped browser axis cannot
# masquerade as a full gate.
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
                   CI asserts result=complete.
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
  echo "check-site: serving '$serve_dir' at $run_url (browser: $browser_path)"
  set +e
  "$NODE" "$REPO_ROOT/scripts/browser-check.mjs" --url "$run_url"
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
# m2 fix: a skipped browser axis is counted in the total (as SKIPPED, not
# PASS) so "16/16 checks passed" can never be printed for a run that only
# exercised the structural checks -- and the result= marker below lets a
# caller that only records this one line (as CI does) tell a full gate from
# a structural-only run apart, without having to parse the fraction.
# ===========================================================================
if [ "$SKIPPED" -gt 0 ]; then
  echo "check-site: ${PASS}/${TOTAL} checks passed (${SKIPPED} skipped)"
else
  echo "check-site: ${PASS}/${TOTAL} checks passed"
fi

if [ "$SKIP_BROWSER" -eq 1 ]; then
  echo "check-site: result=structural-only"
else
  echo "check-site: result=complete"
fi

if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
exit 0
