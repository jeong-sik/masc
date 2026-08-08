#!/usr/bin/env bash
# Shared CI dependency setup: pin fork packages and install with retries.
#
# Used by `.github/workflows/ci.yml` jobs that share identical pin+install
# logic (build-and-test, lint). Extracted to keep the two job definitions
# from drifting when fork SHAs or retry policy change.
#
# Pre-conditions:
#   - opam initialised, switch active (handled by ocaml/setup-ocaml@v3)
#   - scripts/mcp-sdk-pin.sh present at repo-relative path
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=mcp-sdk-pin.sh
source "${repo_root}/scripts/mcp-sdk-pin.sh"

opam pin add bisect_ppx \
  git+https://github.com/patricoferris/bisect_ppx.git#5.2 \
  --no-action --yes
opam pin add mcp_protocol \
  "git+${MCP_SDK_URL}#${MCP_SDK_SHA}" \
  --no-action --yes

for attempt in 1 2 3; do
  if opam install . --deps-only --with-test --yes; then
    exit 0
  fi
  if [ "$attempt" -eq 3 ]; then
    echo "opam install failed after ${attempt} attempts" >&2
    exit 1
  fi
  echo "opam install failed (attempt ${attempt}); retrying in 15s..." >&2
  sleep 15
done
