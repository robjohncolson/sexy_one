#!/usr/bin/env bash
# serve-site.sh -- serve a static directory over plain HTTP on localhost.
#
# Usage:
#   ./scripts/serve-site.sh [--dir DIR] [--port N] [--help]
#
# Defaults:
#   DIR   <repo>/site/public
#   PORT  8123 (override the default with the SXC1_PORT env var, or --port)
#
# Binds to 127.0.0.1 only -- never 0.0.0.0 -- so the dev server is not
# reachable from the network.
set -euo pipefail

# Resolve the repo root from this script's location so it works from any cwd.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"

DIR="$REPO_ROOT/site/public"
PORT="${SXC1_PORT:-8123}"

usage() {
  cat <<EOF
Usage: $(basename -- "${BASH_SOURCE[0]}") [--dir DIR] [--port N] [--help]

Serve a static directory over plain HTTP on 127.0.0.1 using Python's
built-in http.server (its mimetypes module maps .wasm to
application/wasm, which is required for WebAssembly.instantiateStreaming).

Options:
  --dir DIR    Directory to serve (default: <repo>/site/public)
  --port N     TCP port to bind (default: 8123, env SXC1_PORT overrides)
  --help       Show this help and exit

Examples:
  $(basename -- "${BASH_SOURCE[0]}")
  $(basename -- "${BASH_SOURCE[0]}") --dir site/public --port 9000
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)
      [ "$#" -ge 2 ] || { echo "error: --dir requires an argument" >&2; exit 1; }
      DIR="$2"
      shift 2
      ;;
    --dir=*)
      DIR="${1#--dir=}"
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
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "error: unrecognised argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ ! -d "$DIR" ]; then
  echo "error: directory '$DIR' does not exist - run ./scripts/build-site.sh first" >&2
  exit 1
fi

DIR="$(cd -- "$DIR" >/dev/null 2>&1 && pwd -P)"

echo "Serving $DIR at http://127.0.0.1:${PORT}/"
exec python3 -m http.server --bind 127.0.0.1 --directory "$DIR" "$PORT"
