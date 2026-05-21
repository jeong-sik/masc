#!/usr/bin/env bash
# Timeout env knob ceiling ratchet.
#
# RFC-0138 §7 acceptance criterion: "All 14 timeout env variables enumerated
# in §4 marked deprecated with a sunset date". This guard freezes the current
# `MASC_*_TIMEOUT*` distinct-name count in lib/ as a monotone-decrease ceiling.
# New knobs cannot accumulate silently — every addition forces an explicit
# baseline update + commit-msg `RFC-WAIVED:` marker.
#
# Anti-pattern §1 (telemetry-as-fix) self-check: this is *enforcement* at the
# config-knob surface, not a counter. Reducing the knob count requires deleting
# code paths; the ratchet only fails forward growth.
#
# Usage:
#   bash scripts/lint/timeout-env-ceiling.sh
#   bash scripts/lint/timeout-env-ceiling.sh --print
#   bash scripts/lint/timeout-env-ceiling.sh --regenerate

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASELINE="${ROOT}/scripts/lint/timeout-env-ceiling.baseline"
PATTERN='MASC_[A-Z_]+_TIMEOUT[A-Z_]*'
SCOPE=(lib)

for tool in rg sort wc tr; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "[timeout-env-ceiling] required tool missing: $tool" >&2
    exit 1
  }
done

current_count() {
  (
    set +o pipefail
    cd "$ROOT"
    rg --no-filename --no-line-number -No "$PATTERN" "${SCOPE[@]}" 2>/dev/null \
      | sort -u \
      | wc -l \
      | tr -d ' '
  )
}

current_names() {
  cd "$ROOT"
  rg --no-filename --no-line-number -No "$PATTERN" "${SCOPE[@]}" 2>/dev/null \
    | sort -u
}

baseline_count() {
  if [ ! -f "$BASELINE" ]; then
    echo "[timeout-env-ceiling] baseline file missing: $BASELINE" >&2
    echo "Run --regenerate to create it." >&2
    exit 1
  fi
  # Strip comments and blank lines; first non-empty token is the count.
  awk '
    /^[[:space:]]*#/ { next }
    NF == 0 { next }
    { print $1; exit }
  ' "$BASELINE"
}

case "${1:-}" in
  --print)
    current_names
    exit 0
    ;;
  --regenerate)
    count="$(current_count)"
    {
      echo "# Distinct MASC_*_TIMEOUT* env var names in lib/ (production).
# Regenerated $(date -u +%Y-%m-%dT%H:%M:%SZ).
# RFC-0138 §7 acceptance ceiling — see scripts/lint/timeout-env-ceiling.sh."
      echo "$count"
    } > "$BASELINE"
    echo "[timeout-env-ceiling] baseline regenerated: $count"
    exit 0
    ;;
  "")
    ;;
  *)
    echo "[timeout-env-ceiling] unknown arg: $1" >&2
    echo "Usage: $0 [--print|--regenerate]" >&2
    exit 2
    ;;
esac

current="$(current_count)"
baseline="$(baseline_count)"

echo "[timeout-env-ceiling] distinct MASC_*_TIMEOUT names in lib/: current=$current baseline=$baseline"

if [ "$current" -gt "$baseline" ]; then
  echo
  echo "FAIL: MASC_*_TIMEOUT distinct env var count grew from $baseline to $current"
  echo
  echo "RFC-0138 §7 acceptance criterion: limit timeout env knob proliferation."
  echo "Adding a new MASC_*_TIMEOUT knob is allowed when justified by an RFC or"
  echo "by retirement of an older knob in the same PR. To proceed:"
  echo "  1. Run: bash scripts/lint/timeout-env-ceiling.sh --regenerate"
  echo "  2. Commit the updated baseline."
  echo "  3. Add 'RFC-WAIVED: <rfc-id-or-1-line-reason>' to the commit message."
  echo
  echo "Current distinct names (lib/ only):"
  current_names | sed 's/^/  /'
  exit 1
fi

echo "PASS"
