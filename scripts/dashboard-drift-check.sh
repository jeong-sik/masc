#!/usr/bin/env bash
# Dashboard styling-drift ratchet gate.
#
# Scans dashboard/src for forbidden Tailwind patterns whose canonical
# replacement already exists (CSS vars in styles/variables.css, or tokens
# in styles/tokens.css). Compares per-pattern counts against the
# committed baseline at scripts/dashboard-drift-baseline.json.
#
# Pattern policy:
#   - zero-tolerance = new occurrences always fail the gate (baseline: 0)
#   - ratchet = existing drift frozen; new occurrences above baseline fail
#
# Usage:
#   scripts/dashboard-drift-check.sh              # check; exit 0 ok / 2 drift up / 1 error
#   scripts/dashboard-drift-check.sh --regenerate # rewrite baseline from current counts
#   scripts/dashboard-drift-check.sh --print      # print current counts, no compare

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/scripts/dashboard-drift-baseline.json"
SCAN_ROOT="${REPO_ROOT}/dashboard/src"

# Pattern definitions: name|regex|policy|hint
# policy: zero|ratchet
PATTERNS=(
  "bg-white-alpha|bg-white/[0-9]+|ratchet|Use bg-[var(--white-N)] (N in variables.css)"
  "border-white-alpha|border-white/[0-9]+|ratchet|Use border-[var(--border-*)] or border-[var(--white-N)]"
  "text-zinc|text-zinc-[0-9]+|zero|Use text-text-muted / text-text-dim / text-text-strong"
  "bg-zinc|bg-zinc-[0-9]+|zero|Use bg-[var(--white-N)]"
  "border-zinc|border-zinc-[0-9]+|zero|Use border-[var(--border-*)]"
  "rounded-px-literal|rounded-\\[[0-9]+px\\]|ratchet|Use rounded-{xs,sm,md,lg,xl,card} (tokens.css)"
  "text-9px|text-\\[9px\\]|zero|Use text-3xs (10px) or text-2xs (11px)"
  "text-px-literal|text-\\[[0-9]+px\\]|ratchet|Use text-{4xs,3xs,2xs,xs,sm,base,md,lg} (tokens.css)"
)

count_pattern() {
  local regex="$1"
  # rg exits 1 on zero matches under pipefail — tolerate via || true.
  # Scan source only. Exclude: test files, styles/ (token definitions), docs.
  local output
  output=$(rg --count-matches \
     --glob '!*.test.ts' \
     --glob '!**/styles/**' \
     --glob '!**/*.md' \
     -e "$regex" \
     "$SCAN_ROOT" 2>/dev/null || true)
  echo "$output" | awk -F: '{sum += $NF} END { print (sum ? sum : 0) }'
}

current_counts_json() {
  local out='{'
  local first=1
  for spec in "${PATTERNS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local regex="${rest%%|*}"
    local count
    count=$(count_pattern "$regex")
    if [[ $first -eq 1 ]]; then first=0; else out+=','; fi
    out+="\"$name\":$count"
  done
  out+='}'
  echo "$out"
}

baseline_value() {
  local name="$1"
  if [[ -f "$BASELINE_FILE" ]]; then
    python3 -c "
import json, sys
with open('$BASELINE_FILE') as f:
    data = json.load(f)
print(data.get('$name', 0))
"
  else
    echo 0
  fi
}

print_counts() {
  echo "pattern                    current  baseline  policy"
  echo "-----------------------------------------------------"
  for spec in "${PATTERNS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local regex="${rest%%|*}"
    local policy_rest="${rest#*|}"
    local policy="${policy_rest%%|*}"
    local current
    current=$(count_pattern "$regex")
    local baseline
    baseline=$(baseline_value "$name")
    printf "%-26s %7d  %8d  %s\n" "$name" "$current" "$baseline" "$policy"
  done
}

regenerate() {
  local tmpfile
  tmpfile=$(mktemp)
  {
    echo '{'
    echo '  "_comment": "Dashboard styling-drift baseline. Regenerate with scripts/dashboard-drift-check.sh --regenerate.",'
    echo '  "_patterns": "See scripts/dashboard-drift-check.sh PATTERNS array.",'
    local first=1
    for spec in "${PATTERNS[@]}"; do
      local name="${spec%%|*}"
      local rest="${spec#*|}"
      local regex="${rest%%|*}"
      local count
      count=$(count_pattern "$regex")
      if [[ $first -eq 1 ]]; then first=0; else echo ','; fi
      printf '  "%s": %s' "$name" "$count"
    done
    echo
    echo '}'
  } > "$tmpfile"
  mv "$tmpfile" "$BASELINE_FILE"
  echo "Baseline written to $BASELINE_FILE"
  print_counts
}

check() {
  if [[ ! -f "$BASELINE_FILE" ]]; then
    echo "ERROR: baseline file not found: $BASELINE_FILE" >&2
    echo "Run: $0 --regenerate" >&2
    exit 1
  fi

  local drift=0
  local drift_up=0
  local drift_down=0

  for spec in "${PATTERNS[@]}"; do
    local name="${spec%%|*}"
    local rest="${spec#*|}"
    local regex="${rest%%|*}"
    local policy_rest="${rest#*|}"
    local policy="${policy_rest%%|*}"
    local hint="${policy_rest#*|}"
    local current
    current=$(count_pattern "$regex")
    local baseline
    baseline=$(baseline_value "$name")

    if [[ "$policy" == "zero" && "$current" -gt 0 ]]; then
      echo "❌ $name: $current occurrences (zero-tolerance)" >&2
      echo "   Fix: $hint" >&2
      drift_up=$((drift_up + 1))
    elif [[ "$current" -gt "$baseline" ]]; then
      echo "❌ $name: $current > baseline $baseline (ratchet)" >&2
      echo "   Fix: $hint" >&2
      drift_up=$((drift_up + 1))
    elif [[ "$current" -lt "$baseline" ]]; then
      echo "✅ $name: $current < baseline $baseline — baseline can be lowered" >&2
      drift_down=$((drift_down + 1))
    fi
  done

  if [[ $drift_up -gt 0 ]]; then
    echo >&2
    echo "Drift gate: $drift_up pattern(s) exceeded baseline." >&2
    echo "Fix the occurrences, or (if intentional) run: $0 --regenerate" >&2
    exit 2
  fi

  if [[ $drift_down -gt 0 ]]; then
    echo >&2
    echo "Hint: $drift_down pattern(s) have dropped below baseline. Consider: $0 --regenerate" >&2
  fi

  echo "Dashboard drift gate: OK"
  exit 0
}

case "${1:-check}" in
  --regenerate) regenerate ;;
  --print)      print_counts ;;
  check|"")     check ;;
  -h|--help)
    sed -n '1,22p' "$0"
    exit 0
    ;;
  *)
    echo "Unknown arg: $1" >&2
    exit 1
    ;;
esac
