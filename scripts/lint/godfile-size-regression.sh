#!/usr/bin/env bash
# Block regression on .ml file size:
#   - New files added in this PR may not exceed 600 lines.
#   - Any .ml file may not exceed 3100 lines (absolute Godfile cap).
#
# Why this gate exists:
#   `fundamental_roadmap.md` Phase 5 targets six Godfiles (env_config_keeper,
#   keeper_unified_turn, keeper_turn, cascade_catalog_runtime, backend_openai,
#   keeper_prompt). Outright decomposition is out of scope for the
#   re-scoped 10-week plan (see ~/me/planning/claude-plans/joyful-tumbling-dragon.md
#   §9), but the trend must not worsen.
#
# Limits chosen from the audit baseline (HEAD 5806519c0b, 2026-05-05):
#   - Largest existing file: lib/prometheus.ml @ 2,326 lines.
#     3000 left headroom for one round of additions before the cap forced split.
#     Main reached 3,052 lines on 2026-05-07; issue #14161 tracks the proper
#     Prometheus metric-name split. 3100 is a narrow temporary exception, not
#     a new growth budget.
#   - 40+ files are already over 600 lines. New files start clean.
#
# Modes:
#   bash godfile-size-regression.sh                 # absolute-cap only
#   BASE=origin/main bash godfile-size-regression.sh   # adds new-file 600 cap
#
# Exit codes:
#   0 — clean
#   1 — at least one violation

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE="${BASE:-}"
ABSOLUTE_CAP="${ABSOLUTE_CAP:-3100}"
NEW_FILE_CAP="${NEW_FILE_CAP:-600}"

cd "${ROOT}"

violations=0

# Absolute cap: any tracked .ml under lib/ or oas/lib/ exceeding the cap
absolute_offenders=$(find lib oas/lib -type f -name '*.ml' \
  -not -name '*_test.ml' \
  -not -path '*/_build/*' 2>/dev/null \
  | xargs -I{} sh -c '
      lines=$(wc -l <"{}")
      if [ "$lines" -gt '"${ABSOLUTE_CAP}"' ]; then echo "$lines {}"; fi
    ' 2>/dev/null \
  | sort -rn || true)

if [[ -n "${absolute_offenders}" ]]; then
  echo "::error title=Absolute file-size cap exceeded::limit ${ABSOLUTE_CAP} lines"
  echo "${absolute_offenders}" | sed 's/^/  /'
  echo
  echo "Either split the file or, if a one-time exception is justified,"
  echo "raise ABSOLUTE_CAP in this script with explicit RFC reference."
  violations=$((violations + 1))
fi

# New-file cap: only if BASE is set (PR context)
if [[ -n "${BASE}" ]]; then
  if ! git rev-parse --verify --quiet "${BASE}" >/dev/null 2>&1; then
    git fetch --depth=1 origin "${BASE#origin/}" 2>/dev/null || true
  fi
  added=$(git diff --name-only --diff-filter=A "${BASE}...HEAD" -- '*.ml' 2>/dev/null || true)
  new_offenders=()
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    [[ -f "${f}" ]] || continue
    case "${f}" in
      lib/*|oas/lib/*) ;;
      *) continue ;;
    esac
    [[ "${f}" == *_test.ml ]] && continue
    lines=$(wc -l <"${f}")
    if [[ "${lines}" -gt "${NEW_FILE_CAP}" ]]; then
      new_offenders+=("${lines} ${f}")
    fi
  done <<<"${added}"

  if [[ ${#new_offenders[@]} -gt 0 ]]; then
    echo "::error title=New file exceeds size cap::limit ${NEW_FILE_CAP} lines for newly added .ml files"
    printf '  %s\n' "${new_offenders[@]}"
    echo
    echo "Split the new module or, for measurement files, suffix _test.ml."
    violations=$((violations + 1))
  fi
fi

if [[ ${violations} -gt 0 ]]; then
  exit 1
fi

echo "godfile-size-regression: clean (absolute_cap=${ABSOLUTE_CAP}, new_file_cap=${NEW_FILE_CAP}${BASE:+, base=${BASE}})"
exit 0
