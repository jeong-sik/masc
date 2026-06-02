#!/usr/bin/env bash
set -euo pipefail

current_graph=${LIB_DEP_CURRENT_GRAPH:-reports/lib-dependency-graph.json}
baseline_graph=${LIB_DEP_BASELINE_GRAPH:-reports/lib-dependency-graph.baseline.json}
summary_md=${LIB_DEP_SUMMARY_MD:-reports/lib-dependency-summary.md}
summary_json=${LIB_DEP_SUMMARY_JSON:-reports/lib-dependency-summary.json}

root=$(git rev-parse --show-toplevel)
cd "$root"

mkdir -p "$(dirname "$current_graph")"

# Fail loudly if module discovery is broken.  Pre-2026-05 the analyzer parsed a
# `(modules ...)` stanza from `lib/dune`; after that stanza was replaced with
# `(include_subdirs unqualified)` it silently returned 0 modules and this whole
# step produced an empty graph for weeks.
python3 scripts/analyze_lib_deps.py --self-test

python3 scripts/analyze_lib_deps.py --json

baseline_args=()
baseline_tree=""
if [[ -n "${GITHUB_BASE_REF:-}" && "${GITHUB_EVENT_NAME:-}" == "pull_request" ]]; then
  baseline_tree=$(mktemp -d)
  rm -rf "$baseline_tree"
  bash scripts/ci/git-fetch-retry.sh origin "$GITHUB_BASE_REF" --depth=200
  base_ref="origin/$GITHUB_BASE_REF"
  if ! git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    base_ref="FETCH_HEAD"
  fi
  git worktree add --detach "$baseline_tree" "$base_ref" >/dev/null
  cleanup() {
    git worktree remove --force "$baseline_tree" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT

  (
    cd "$baseline_tree"
    python3 scripts/analyze_lib_deps.py --json
  )
  cp "$baseline_tree/reports/lib-dependency-graph.json" "$baseline_graph"
  baseline_args=(--baseline "$baseline_graph")
elif [[ -f "$baseline_graph" ]]; then
  baseline_args=(--baseline "$baseline_graph")
fi

summary_args=(--graph "$current_graph")
if [[ ${#baseline_args[@]} -gt 0 ]]; then
  summary_args+=("${baseline_args[@]}")
fi

python3 scripts/lib_dep_report.py \
  "${summary_args[@]}" \
  --output "$summary_md"

python3 scripts/lib_dep_report.py \
  "${summary_args[@]}" \
  --format json \
  --output "$summary_json"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "## Lib Dependency Delta"
    echo
    cat "$summary_md"
  } >> "$GITHUB_STEP_SUMMARY"
fi
