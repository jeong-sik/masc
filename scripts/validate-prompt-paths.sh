#!/usr/bin/env bash
# validate-prompt-paths.sh — keeper prompt/config drift gate for #6527.
#
# Invariant: every `.worktrees/<...>` reference in config/ must be inside a
# keeper sandbox repo path.  The model-facing canonical form is now
# `repos/<repo>/.worktrees/...`; legacy `.masc/playground/.../repos/...`
# remains accepted as a compatibility form.  A bare `.worktrees/...` string
# teaches keepers a server-root relative path that the harness blocks.
#
# Re-run locally:
#   bash scripts/validate-prompt-paths.sh
#
# Exit codes:
#   0 — all .worktrees/ references are sandbox-repo rooted (OK)
#   1 — bare .worktrees/... reference found (drift)
#   2 — required tool missing

set -u
set -o pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "validate-prompt-paths: ripgrep (rg) is required" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SEARCH_ROOTS=(
  "config/prompts"
  "config/keepers"
  "config/personas"
)

# If any of the search roots has been removed by a future refactor, skip
# with a clear message instead of letting ripgrep fail with a generic
# "No such file or directory" that masks the actual state.
for d in "${SEARCH_ROOTS[@]}"; do
  if [ ! -d "$d" ]; then
    echo "validate-prompt-paths: $d not found (skipping drift check)" >&2
    exit 0
  fi
done

# Detection is strictly per-line: the first rg emits one output line per
# source line that mentions `.worktrees/`, and the second rg filters each
# of those output lines independently. A drifted bare `.worktrees/...`
# line is caught even if the line immediately above or below contains
# the playground prefix.
drift_hits="$(
  rg --no-heading --with-filename --line-number --color=never \
     '\.worktrees/' "${SEARCH_ROOTS[@]}" \
    | rg -v 'repos/[^[:space:]]*\.worktrees/|\.masc/playground/' \
    || true
)"

if [ -n "$drift_hits" ]; then
  cat <<'EOF' >&2
✗ validate-prompt-paths: bare `.worktrees/...` reference found in config/

Keepers see every config/prompts, config/keepers/*.toml, and config/personas/*
as part of their system prompt. A bare `.worktrees/<branch>` path is relative
to the server root, not the keeper sandbox — the harness rejects it as outside
the sandbox boundary.

Every .worktrees reference in config/ MUST be rooted in a sandbox repo path,
for example:
  repos/<REPO_NAME>/.worktrees/<branch-or-task>/

Offending lines:
EOF
  echo "$drift_hits" >&2
  echo "" >&2
  echo "Fix the lines above, then re-run this script." >&2
  exit 1
fi

echo "✓ validate-prompt-paths: all .worktrees/ references are sandbox-repo rooted"
exit 0
