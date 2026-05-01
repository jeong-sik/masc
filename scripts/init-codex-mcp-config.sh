#!/usr/bin/env bash
# init-codex-mcp-config.sh — write the canonical [mcp_servers.masc] TOML stanza.
#
# Usage:
#   scripts/init-codex-mcp-config.sh [--base-path PATH] [--host HOST] [--port PORT] [--dry-run]
#
# This script generates the correct [mcp_servers.masc] Codex config entry that
# the MASC auth doctor (doctor auth) expects:
#   - bearer_token_env_var = "MASC_MCP_TOKEN"   (no hardcoded Authorization header)
#   - http_headers with Accept and X-MASC-Agent  (no Authorization header)
#
# After writing the stanza, mint a codex-mcp-client bearer token (if missing):
#   BASE_PATH="${MASC_BASE_PATH:-$HOME}"
#   eval "$(./_build/default/bin/main_eio.exe login \
#     --base-path "$BASE_PATH" --agent codex-mcp-client --role worker --shell)"
#   export MASC_MCP_TOKEN  # export to Codex's shell environment
#
# Security notes:
#   - Never write the raw bearer token into ~/.codex/config.toml.
#   - Use bearer_token_env_var so Codex reads the token from the environment
#     at runtime; this avoids persisting the literal token in the config file.
#   - Run `masc-mcp doctor auth` to verify the config is correct.

set -euo pipefail

BASE_PATH="${MASC_BASE_PATH:-$HOME}"
HOST="127.0.0.1"
PORT="8935"
DRY_RUN=0
CODEX_CONFIG_PATH="${MASC_CODEX_CONFIG_PATH:-${HOME}/.codex/config.toml}"

usage() {
  sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-path) BASE_PATH="$2"; shift 2 ;;
    --host)      HOST="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   usage ;;
    *) echo "Unknown flag: $1 (try --help)" >&2; exit 1 ;;
  esac
done

MCP_URL="http://${HOST}:${PORT}/mcp"

# The canonical [mcp_servers.masc] stanza.
# bearer_token_env_var is used instead of a hardcoded Authorization header.
# This is what `masc-mcp doctor auth` checks for in codex_mcp.config.stages.
MASC_STANZA=$(cat <<EOF
[mcp_servers.masc]
url = "${MCP_URL}"
bearer_token_env_var = "MASC_MCP_TOKEN"
http_headers = { "Accept" = "application/json, text/event-stream", "X-MASC-Agent" = "codex-mcp-client" }
EOF
)

if [ "$DRY_RUN" = "1" ]; then
  echo "==> Dry run: would write to ${CODEX_CONFIG_PATH}" >&2
  echo ""
  echo "--- canonical [mcp_servers.masc] stanza ---"
  printf '%s\n' "$MASC_STANZA"
  echo "---"
  echo ""
  echo "Next steps:"
  echo "  1. Check ${CODEX_CONFIG_PATH} for an existing [mcp_servers.masc] stanza."
  echo "  2. If the file has 'Authorization = ...' inside [mcp_servers.masc],"
  echo "     remove that line — use bearer_token_env_var instead."
  echo "  3. Add or replace the stanza with the output above."
  echo "  4. Mint a codex-mcp-client token and export it:"
  echo "     eval \"\$(masc-mcp login --base-path '${BASE_PATH}' --agent codex-mcp-client --role worker --shell)\""
  echo "  5. Run: masc-mcp doctor auth --base-path '${BASE_PATH}'"
  exit 0
fi

# Ensure parent directory exists.
mkdir -p "$(dirname "$CODEX_CONFIG_PATH")"

if [ ! -f "$CODEX_CONFIG_PATH" ]; then
  # Config file does not exist; write it.
  printf '%s\n' "$MASC_STANZA" > "$CODEX_CONFIG_PATH"
  echo "==> Created ${CODEX_CONFIG_PATH} with [mcp_servers.masc] stanza." >&2
elif grep -qF '[mcp_servers.masc]' "$CODEX_CONFIG_PATH" 2>/dev/null; then
  # Stanza already present.
  echo "==> [mcp_servers.masc] already present in ${CODEX_CONFIG_PATH}." >&2
  echo "    Run: MASC_SYNC_CODEX_MCP_CONFIG=1 masc-mcp --base-path '${BASE_PATH}'" >&2
  echo "    Or:  masc-mcp doctor auth --base-path '${BASE_PATH}'" >&2
  echo "    to check and repair bearer_token_env_var / Authorization drift." >&2
else
  # Append the stanza to the existing config.
  printf '\n%s\n' "$MASC_STANZA" >> "$CODEX_CONFIG_PATH"
  echo "==> Appended [mcp_servers.masc] stanza to ${CODEX_CONFIG_PATH}." >&2
fi

echo "" >&2
echo "==> Security reminder:" >&2
echo "    Do NOT add 'Authorization = \"Bearer ...\"' to [mcp_servers.masc]." >&2
echo "    Use bearer_token_env_var = \"MASC_MCP_TOKEN\" and export the token" >&2
echo "    in the shell that starts Codex — never write the raw token to disk." >&2
echo "" >&2
echo "==> Mint / verify codex-mcp-client bearer token:" >&2
echo "    eval \"\$(masc-mcp login --base-path '${BASE_PATH}' --agent codex-mcp-client --role worker --shell)\"" >&2
echo "    export MASC_MCP_TOKEN" >&2
echo "" >&2
echo "==> Verify config with auth doctor:" >&2
echo "    masc-mcp doctor auth --base-path '${BASE_PATH}'" >&2
