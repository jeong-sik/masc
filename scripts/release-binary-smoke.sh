#!/usr/bin/env bash
# Verify a release-shaped binary actually boots and does not lie about its
# CLI surface relative to the repo README.
#
# Usage:
#   scripts/release-binary-smoke.sh [PATH_TO_BINARY]
#
# Default binary path: _build/default/bin/main_eio.exe
#
# Exit codes:
#   0  smoke + doc drift OK
#   2  binary printed FATAL during boot
#   3  binary did not reach `MASC MCP Server listening` within timeout
#   4  README references a subcommand that --help does not list
#   5  argument / setup error

set -euo pipefail

BINARY="${1:-_build/default/bin/main_eio.exe}"
PORT="${SMOKE_PORT:-18935}"
BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-5}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

[ -x "$BINARY" ] || { echo "smoke: binary not executable: $BINARY" >&2; exit 5; }
[ -f config/tool_policy.toml ] || { echo "smoke: config/tool_policy.toml missing" >&2; exit 5; }

tmp=$(mktemp -d -t masc-smoke.XXXXXX)
trap 'rm -rf "$tmp"; [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null || true' EXIT

mkdir -p "$tmp/.masc/config"
cp config/tool_policy.toml "$tmp/.masc/config/tool_policy.toml"

log="$tmp/boot.log"
echo "smoke: booting $BINARY on :$PORT under $tmp"
"$BINARY" --base-path "$tmp" --port "$PORT" >"$log" 2>&1 &
PID=$!

# Poll for either a FATAL line or the listening line. Bound by BOOT_WAIT_SEC.
deadline=$(( $(date +%s) + BOOT_WAIT_SEC ))
state=pending
while [ "$(date +%s)" -lt "$deadline" ]; do
  if grep -q '\[FATAL\]\|Fatal ' "$log"; then state=fatal; break; fi
  if grep -q 'MASC MCP Server listening' "$log"; then state=listening; break; fi
  sleep 0.2
done
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true
PID=""

case "$state" in
  fatal)
    echo "smoke: FATAL during boot:" >&2
    grep -B2 -A2 -E 'FATAL|Fatal ' "$log" >&2 || true
    exit 2
    ;;
  pending)
    echo "smoke: did not reach listening within ${BOOT_WAIT_SEC}s" >&2
    tail -30 "$log" >&2
    exit 3
    ;;
  listening) echo "smoke: boot OK" ;;
esac

# --- README ↔ CLI subcommand drift -------------------------------------------
help_txt="$tmp/help.txt"
TERM=dumb "$BINARY" --help=plain >"$help_txt" 2>/dev/null || true

# cmdliner Cmd.group prints subcommands under the "COMMANDS" section, with
# 7-space indent (subcommand name) followed by deeper indent (description).
# A blank line, an outdented bare-name token, or another ALL-CAPS section
# header ends the block.
actual_subcmds=$(awk '
  /^COMMANDS$/ { in_block=1; next }
  in_block && /^[A-Z][A-Z ]+$/ { in_block=0; next }
  in_block && /^       [a-z][a-z0-9_-]*/ {
    name=$1; sub(/[^a-z0-9_-].*/, "", name); print name
  }
' "$help_txt" | sort -u)

# Subcommands the README claims exist (matches `main_eio.exe SUBCMD` and
# `masc-mcp SUBCMD` where SUBCMD is a bare lowercase token, not a flag).
readme_subcmds=$(grep -hoE '(main_eio\.exe|masc-mcp) +[a-z][a-z0-9_-]*' README.md \
  | awk '{print $2}' | sort -u)

drift=0
for sub in $readme_subcmds; do
  # ignore obvious noise (config sample words that match the regex by accident)
  case "$sub" in
    install|build|run|on|off|via|in|to|of|the|a|an) continue ;;
  esac
  if ! echo "$actual_subcmds" | grep -qx "$sub"; then
    echo "drift: README references '$sub' subcommand but binary --help lists no such command" >&2
    drift=1
  fi
done

if [ "$drift" -ne 0 ]; then
  echo "" >&2
  echo "Binary subcommands actually present:" >&2
  echo "$actual_subcmds" | sed 's/^/  /' >&2
  echo "" >&2
  echo "Either the README is ahead of this build (release was cut before merge)," >&2
  echo "or the README claims a subcommand that no longer exists." >&2
  exit 4
fi

echo "smoke: doc drift check OK"
echo "smoke: release binary contract upheld"
