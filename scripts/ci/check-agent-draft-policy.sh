#!/usr/bin/env bash
# check-agent-draft-policy.sh — CI gate: enforces human-approval bypass-label policy.
#
# CREDENTIAL BOUNDARY (see issue #9733):
#   Simply checking who applied a bypass label cannot prove the actor was a
#   human when agents share the owner's GitHub credentials — the label event
#   actor appears identical for both.
#
#   Use the credential-separated approval workflow instead:
#     .github/workflows/approve-agent-pr.yml
#
#   That workflow requires interactive approval through the `human-approval`
#   GitHub Environment (Settings → Environments → human-approval → Required
#   reviewers).  An agent holding the owner token cannot self-approve an
#   environment deployment, so the resulting bypass label carries a
#   non-forgeable credential boundary.
set -euo pipefail

title_re="${AGENT_DRAFT_GUARD_TITLE_RE:-^\[codex\]}"
branch_re="${AGENT_DRAFT_GUARD_BRANCH_RE:-^(codex[/-]|keeper[/-])}"
bypass_labels_csv="${AGENT_DRAFT_GUARD_BYPASS_LABELS:-human-approved-ready}"
hard_stop_labels_csv="${AGENT_DRAFT_GUARD_HARD_STOP_LABELS:-do-not-merge}"

event_name="${GITHUB_EVENT_NAME:-}"
if [[ "$event_name" != "pull_request" ]]; then
  echo "agent draft policy: skipped for event ${event_name:-unknown}"
  exit 0
fi

pr_is_draft="${PR_LIVE_IS_DRAFT:-${PR_IS_DRAFT:-false}}"
pr_title="${PR_TITLE:-}"
pr_head_ref="${PR_HEAD_REF:-}"
pr_labels_csv="${PR_LIVE_LABELS:-${PR_LABELS:-}}"
pr_live_state="${PR_LIVE_STATE:-}"

if [[ -n "${PR_LIVE_IS_DRAFT:-}" ]]; then
  echo "agent draft policy: using live PR draft state ${PR_LIVE_IS_DRAFT}"
fi
if [[ -n "${PR_LIVE_LABELS:-}" ]]; then
  echo "agent draft policy: using live PR labels ${PR_LIVE_LABELS}"
fi

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# #10192: CI Gate runs that fire after auto-merge (observed
# 12 min post-merge) sometimes query live PR labels AFTER
# post-merge automation has cleaned the bypass label.  The
# gate then evaluates an already-merged PR as ready-without-
# bypass and fails — a red check on a PR that has already
# shipped (PR #10181, run 24924336433).  Skip when the live
# state says the PR is no longer open: the policy is moot
# for closed/merged PRs and the merge-time CI Gate already
# gated the merge itself.
case "$(lower "${pr_live_state}")" in
  merged|closed)
    echo "agent draft policy: skipped, PR live state is ${pr_live_state} (post-merge gate race, see #10192)"
    exit 0
    ;;
esac

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

IFS=',' read -r -a hard_stop_labels <<<"$hard_stop_labels_csv"
for label in "${hard_stop_labels[@]}"; do
  label="$(printf '%s' "$label" | xargs)"
  [[ -n "$label" ]] || continue
  if csv_has_label "$pr_labels_csv" "$label"; then
    echo "::error title=Do-not-merge policy violation::PR '${pr_head_ref}' has hard-stop label ${label}. Remove the hard-stop label before ready/merge."
    exit 1
  fi
done

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

echo "::error title=Agent draft policy violation::agent-like PR '${pr_head_ref}' lacks an approved human bypass label (${bypass_labels_csv}). Keep the required gate red until a human adds an approved bypass label."
exit 1
