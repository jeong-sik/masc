#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v rg >/dev/null 2>&1; then
  echo "[no-keeper-behavior-hardcoding] required tool missing: rg" >&2
  exit 1
fi

targets=(
  "lib/keeper"
  "lib/task"
  "lib/workspace"
)

patterns=(
  'is_verifier_agent_name'
  'keeper-verifier-agent'
  'String[.]equal[^\n]*"verifier"'
  '"verifier"[^\n]*String[.]equal'
)

tmp="$(mktemp -t keeper-behavior-hardcoding.XXXXXX)"
trap 'rm -f "$tmp"' EXIT

for pattern in "${patterns[@]}"; do
  (cd "$ROOT" && rg -n --glob '*.ml' --glob '*.mli' "$pattern" "${targets[@]}") \
    >>"$tmp" || true
done

if [[ -s "$tmp" ]]; then
  echo "[no-keeper-behavior-hardcoding] hardcoded keeper identity behavior found" >&2
  cat "$tmp" >&2
  echo "[no-keeper-behavior-hardcoding] encode keeper-specific behavior in config/meta policy instead" >&2
  exit 1
fi

echo "[no-keeper-behavior-hardcoding] OK"
