#!/usr/bin/env bash
# harness-connector-env-ratchet.sh — no harness boots the server with the
# operator's real Slack/Discord credentials still in its environment (#28807).
#
# Why this gate exists:
#   lib/config/env_config_slack.ml and env_config_discord.ml read UNPREFIXED
#   env vars (SLACK_APP_TOKEN, SLACK_BOT_TOKEN, DISCORD_BOT_TOKEN). A harness
#   that only isolates MASC_BASE_PATH inherits those tokens, and an eval/smoke
#   server then joins the real Slack workspace / Discord server. This exact
#   hole shipped: harness_dashboard_execution_smoke.sh connected to production
#   (issue #28807, "[Slack] slack socket mode connected" in a mktemp base).
#
# How the guard works (hole ratchet, not allowlist):
#   Any scripts/harness shell file whose CODE boots the server (main_eio.exe
#   or start-masc.sh) must either source the shared bootstrap
#   (scripts/harness/lib/server_bootstrap.sh — harness_start_server unsets
#   the connector tokens) or carry an explicit `unset ... SLACK_BOT_TOKEN ...`
#   coverage. Judgments run on comment- and quote-stripped text so prose can
#   never look like code (and code hidden in prose never excuses a hole).
#   Tokens match whole-word so SOME_PREFIX_SLACK_BOT_TOKEN never counts.
#
# Exit codes:
#   0 — all server-booting harness files are covered
#   1 — at least one file boots the server with no connector-env coverage
#
# --self-test: run against a synthetic sandbox tree (covered / uncovered /
# non-booting fixtures) instead of the live scripts/ tree. The lint suite
# runs the self-test form because the ratchet's live fixtures change with the
# harness tree itself (run_self_test_when_changed rationale).

set -euo pipefail

ROOT="${HARNESS_RATCHET_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
# Same mis-root hazard as the wire gate: a wrong ROOT scans nothing and
# reports "0 violations" from a tree that has no harness at all. Verify the
# tree looks like the masc checkout, else fail loudly (exit 2).
if [ ! -d "${ROOT}/scripts/harness" ] || [ ! -f "${ROOT}/scripts/lint/harness-connector-env-ratchet.sh" ]; then
  echo "harness-connector-env-ratchet ERROR: ROOT '${ROOT}' is not the masc checkout (set HARNESS_RATCHET_ROOT explicitly)" >&2
  exit 2
fi

if [[ "${1:-}" == "--self-test" ]]; then
  exec bash "${ROOT}/scripts/lint/harness-connector-env-ratchet-selftest.sh"
fi

BOOT_PATTERN='main_eio\.exe|start-masc\.sh'
REQUIRED_VARS='SLACK_BOT_TOKEN|SLACK_APP_TOKEN|DISCORD_BOT_TOKEN'

# Strip comments and quoted spans. State machine over each line: inside
# single/double quotes, # is literal (a boot line like *_exe --url
# "http://host/#frag" still counts as code). \047 is a single quote, \042 a
# double quote (portable POSIX awk escapes).
strip_sh_comments() {
  awk '
    {
      out = ""
      in_s = 0; in_d = 0
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") { out = out c; if (i < n) { i++; out = out substr($0, i, 1) }; continue }
        if (in_s) { if (c == "\047") in_s = 0 }
        else if (in_d) { if (c == "\042") in_d = 0 }
        else {
          if (c == "\047") in_s = 1
          else if (c == "\042") in_d = 1
          else if (c == "#") break
        }
        out = out c
      }
      print out
    }' "$1"
}

violations=0
report=()

# Candidate files: the shared lib tree plus flat harness_*.sh scripts.
while IFS= read -r file; do
  rel="${file#"${ROOT}"/}"
  code="$(strip_sh_comments "$file")"

  # Boot detection on code only — prose mentions of main_eio.exe (a README or
  # a comment) do not make a file a server-booting harness.
  printf '%s\n' "$code" | grep -qE "${BOOT_PATTERN}" || continue

  # Sanitization at one remove: the shared bootstrap's harness_start_server
  # unsets the connector tokens, so sourcing it is coverage by construction.
  if printf '%s\n' "$code" | grep -qE 'server_bootstrap\.sh'; then
    continue
  fi

  # Direct coverage: an unset or env -u of at least one connector token var,
  # matched as a whole token so a differently-prefixed sibling
  # (SOME_SLACK_BOT_TOKEN) never counts.
  if printf '%s\n' "$code" | grep -Eq "(^|[^A-Za-z0-9_])(unset|env -u)( -[a-zA-Z]+)*( [A-Za-z_][A-Za-z0-9_]*)*.*[^A-Za-z0-9_](${REQUIRED_VARS})" \
    || printf '%s\n' "$code" | grep -Eq "(^|[^A-Za-z0-9_])env -u( [A-Za-z_][A-Za-z0-9_]*)*.*[^A-Za-z0-9_](${REQUIRED_VARS})"; then
    continue
  fi

  report+=("${rel}")
  violations=$((violations + 1))
done < <({ rg --files --color=never -g '*.sh' "${ROOT}/scripts/harness" 2>/dev/null || true;
           rg --files --color=never -g 'harness_*.sh' "${ROOT}/scripts" 2>/dev/null || true; } \
         | sort -u)

if [[ ${violations} -gt 0 ]]; then
  echo "::error title=Harness connector env ratchet::${violations} server-booting harness file(s) without connector-token unset"
  printf '  %s\n' "${report[@]}"
  echo
  echo "Fix: source scripts/harness/lib/server_bootstrap.sh and boot via"
  echo "harness_start_server (it unsets SLACK_BOT_TOKEN/SLACK_APP_TOKEN/"
  echo "DISCORD_BOT_TOKEN), or add an explicit"
  echo "'unset SLACK_BOT_TOKEN SLACK_APP_TOKEN DISCORD_BOT_TOKEN' before the"
  echo "server launch. See issue #28807 — base-path isolation does not cover"
  echo "these unprefixed env reads."
  exit 1
fi

echo "harness-connector-env-ratchet: ${violations} violations"
