#!/usr/bin/env bash
# Verify that the GitHub Environment used by approve-agent-pr.yml is protected.
#
# Usage:
#   scripts/check-human-approval-env.sh --repo owner/name
#   scripts/check-human-approval-env.sh --repo owner/name --environment staging
#   scripts/check-human-approval-env.sh --repo owner/name --require-reviewer jeong-sik
#   scripts/check-human-approval-env.sh --repo owner/name --require-prevent-self-review

set -euo pipefail

REPO="${GITHUB_REPOSITORY:-}"
ENVIRONMENT="human-approval"
REQUIRE_REVIEWER=""
REQUIRE_PREVENT_SELF_REVIEW=0

usage() {
  awk '
    NR == 1 { next }
    /^[[:space:]]*$/ {
      if (started) print ""
      next
    }
    /^#/ {
      line = $0
      sub(/^# ?/, "", line)
      print line
      started = 1
      next
    }
    started { exit }
  ' "$0"
}

die() {
  echo "error: $*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || die "--repo requires owner/name"
      REPO="$2"
      shift 2
      ;;
    --environment)
      [ "$#" -ge 2 ] || die "--environment requires a name"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --require-reviewer)
      [ "$#" -ge 2 ] || die "--require-reviewer requires a GitHub login or team slug"
      REQUIRE_REVIEWER="$2"
      shift 2
      ;;
    --require-prevent-self-review)
      REQUIRE_PREVENT_SELF_REVIEW=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown arg: $1"
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh CLI is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

if [ -z "$REPO" ]; then
  if ! REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"; then
    die "repository not found; pass --repo owner/name"
  fi
fi

[ -n "$REPO" ] || die "repository not found; pass --repo owner/name"
case "$REPO" in
  */*) ;;
  *) die "--repo must be owner/name" ;;
esac

ENVIRONMENT_ENCODED="$(jq -nr --arg value "$ENVIRONMENT" '$value | @uri')"
environment_json="$(
  gh api "repos/$REPO/environments/$ENVIRONMENT_ENCODED"
)" || die "could not read environment '$ENVIRONMENT' in $REPO"

environment_summary="$(
  printf '%s' "$environment_json" |
    jq --arg reviewer "$REQUIRE_REVIEWER" '{
      name,
      deployment_branch_policy,
      required_rule_count:
        ([.protection_rules[]? | select(.type == "required_reviewers")] | length),
      required_reviewer_count:
        ([.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length),
      prevent_self_review:
        ([.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review][0] // false),
      reviewer_present:
        (if $reviewer == "" then true
         else
           ([.protection_rules[]?
             | select(.type == "required_reviewers")
             | .reviewers[]?
             | select(((.reviewer.login // .reviewer.slug // "") == $reviewer))]
            | length) > 0
         end),
      reviewers: [
        .protection_rules[]?
        | select(.type == "required_reviewers")
        | .reviewers[]?.reviewer
        | (.login // .slug // .name // .id // empty)
      ]
    }'
)"

summary_fields="$(
  printf '%s' "$environment_summary" |
    jq -r '[.required_rule_count, .required_reviewer_count, .prevent_self_review, .reviewer_present] | @tsv'
)"
IFS="$(printf '\t')" read -r required_rule_count reviewer_count prevent_self_review reviewer_present <<EOF
$summary_fields
EOF

if [ "$required_rule_count" -eq 0 ] || [ "$reviewer_count" -eq 0 ]; then
  echo "human approval environment check: FAIL"
  echo "required reviewer protection rule missing or empty for $REPO/$ENVIRONMENT"
  printf '%s\n' "$environment_json" |
    jq '{name, protection_rules, deployment_branch_policy}'
  exit 1
fi

if [ -n "$REQUIRE_REVIEWER" ]; then
  if [ "$reviewer_present" != "true" ]; then
    echo "human approval environment check: FAIL"
    echo "required reviewer '$REQUIRE_REVIEWER' is not configured for $REPO/$ENVIRONMENT"
    printf '%s\n' "$environment_json" |
      jq '{name, protection_rules, deployment_branch_policy}'
    exit 1
  fi
fi

if [ "$REQUIRE_PREVENT_SELF_REVIEW" -eq 1 ] && [ "$prevent_self_review" != "true" ]; then
  echo "human approval environment check: FAIL"
  echo "prevent_self_review is not enabled for $REPO/$ENVIRONMENT"
  printf '%s\n' "$environment_json" |
    jq '{name, protection_rules, deployment_branch_policy}'
  exit 1
fi

echo "human approval environment check: PASS"
printf '%s\n' "$environment_summary" |
  jq '{
    name,
    deployment_branch_policy,
    required_reviewer_count,
    prevent_self_review,
    reviewers
  }'

if [ "$prevent_self_review" != "true" ]; then
  echo "warning: prevent_self_review is false; pass --require-prevent-self-review when a second reviewer/team is available."
fi
