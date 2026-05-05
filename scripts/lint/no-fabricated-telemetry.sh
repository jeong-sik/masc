#!/usr/bin/env bash
# Detect Math.random() inside dashboard React components (.jsx/.tsx).
#
# Why this gate exists:
#   `fundamental_roadmap.md` Phase 4-1 cites Math.random() driving fake
#   sparklines and TPS values in the dashboard. PR #12986 (chore:
#   remove fabricated telemetry placeholders) removed those, but the
#   pattern is easy to reintroduce when stubbing UI in isolation.
#
# Why .jsx/.tsx only:
#   Plain .ts files legitimately use Math.random() for ephemeral IDs
#   (e.g. dashboard/src/sse.ts:53 SSE client id,
#   dashboard/src/components/common/command-bar.ts:61 listId). Restricting
#   to component files (.jsx/.tsx) keeps the signal precise.
#
# Allowed (never flagged):
#   - Lines marked `// real-randomness-needed: <reason>`
#   - Entries listed in scripts/lint/no-fabricated-telemetry.allowlist
#     ("path:line")
#
# Exit codes:
#   0 — clean
#   1 — new violations

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALLOWLIST="${ROOT}/scripts/lint/no-fabricated-telemetry.allowlist"

ROOTS=("${ROOT}/dashboard/src" "${ROOT}/oas-public")

ALLOW_TMP="$(mktemp -t no-fab-tele.XXXXXX)"
trap 'rm -f "${ALLOW_TMP}"' EXIT
if [[ -f "${ALLOWLIST}" ]]; then
  sed -E 's/#.*//; s/[[:space:]]//g; /^$/d' "${ALLOWLIST}" >"${ALLOW_TMP}"
fi

violations=0
report=()

for root in "${ROOTS[@]}"; do
  [[ -d "${root}" ]] || continue
  while IFS= read -r match; do
    rel="${match%%:*}"
    rest="${match#*:}"
    line_no="${rest%%:*}"
    content="${rest#*:}"
    rel="${rel#${ROOT}/}"
    key="${rel}:${line_no}"

    if grep -qE 'real-randomness-needed' <<<"${content}"; then
      continue
    fi
    if [[ -s "${ALLOW_TMP}" ]] && grep -Fxq "${key}" "${ALLOW_TMP}"; then
      continue
    fi

    report+=("${key}: ${content}")
    violations=$((violations + 1))
  done < <(rg --no-heading --line-number --color=never -g '*.jsx' -g '*.tsx' 'Math\.random' "${root}" 2>/dev/null || true)
done

if [[ ${violations} -gt 0 ]]; then
  echo "::error title=Fabricated telemetry::${violations} Math.random() in component file(s)"
  printf '  %s\n' "${report[@]}"
  echo
  echo "Replace with real metric data (WebSocket / metric endpoint)."
  echo "If real randomness is genuinely needed (e.g. UI animation seed),"
  echo "annotate '// real-randomness-needed: <reason>' or add to"
  echo "${ALLOWLIST#${ROOT}/}."
  exit 1
fi

echo "no-fabricated-telemetry: clean"
exit 0
