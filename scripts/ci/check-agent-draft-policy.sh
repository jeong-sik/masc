#!/usr/bin/env bash
set -euo pipefail

title_re="${AGENT_DRAFT_GUARD_TITLE_RE:-^\[codex\]}"
branch_re="${AGENT_DRAFT_GUARD_BRANCH_RE:-^(codex[/-]|keeper[/-])}"
bypass_labels_csv="${AGENT_DRAFT_GUARD_BYPASS_LABELS:-human-approved-ready}"

event_name="${GITHUB_EVENT_NAME:-}"
if [[ "$event_name" != "pull_request" ]]; then
  echo "agent draft policy: skipped for event ${event_name:-unknown}"
  exit 0
fi

pr_is_draft="${PR_LIVE_IS_DRAFT:-${PR_IS_DRAFT:-false}}"
pr_title="${PR_TITLE:-}"
pr_head_ref="${PR_HEAD_REF:-}"
pr_labels_csv="${PR_LIVE_LABELS:-${PR_LABELS:-}}"

if [[ -n "${PR_LIVE_IS_DRAFT:-}" ]]; then
  echo "agent draft policy: using live PR draft state ${PR_LIVE_IS_DRAFT}"
fi
if [[ -n "${PR_LIVE_LABELS:-}" ]]; then
  echo "agent draft policy: using live PR labels ${PR_LIVE_LABELS}"
fi

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

csv_has_label() {
  local csv="$1"
  local wanted
  wanted="$(lower "$2")"
  local item
  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(lower "$(printf '%s' "$item" | xargs)")"
    if [[ "$item" == "$wanted" ]]; then
      return 0
    fi
  done
  return 1
}

looks_agent_authored=0
if [[ "$pr_title" =~ $title_re || "$pr_head_ref" =~ $branch_re ]]; then
  looks_agent_authored=1
elif csv_has_label "$pr_labels_csv" "agent-pr" || csv_has_label "$pr_labels_csv" "codex"; then
  looks_agent_authored=1
fi

if [[ "$looks_agent_authored" -eq 0 ]]; then
  echo "agent draft policy: skipped for non-agent PR"
  exit 0
fi

if [[ "$(lower "$pr_is_draft")" == "true" ]]; then
  echo "agent draft policy: pass, agent PR remains draft"
  exit 0
fi

bypass_present=0
IFS=',' read -r -a bypass_labels <<<"$bypass_labels_csv"
for label in "${bypass_labels[@]}"; do
  label="$(printf '%s' "$label" | xargs)"
  [[ -n "$label" ]] || continue
  if [[ "$(lower "$label")" == "allow-auto-merge" ]]; then
    echo "agent draft policy: ignoring automation-prone bypass label ${label}"
    continue
  fi
  if csv_has_label "$pr_labels_csv" "$label"; then
    bypass_present=1
    echo "agent draft policy: pass, bypass label present: ${label}"
    break
  fi
done

if [[ "$bypass_present" -eq 1 ]]; then
  exit 0
fi

echo "::error title=Agent draft policy violation::agent-like PR '${pr_head_ref}' is ready without an approved bypass label (${bypass_labels_csv}). Keep it draft or add an approved human bypass label."
exit 1
