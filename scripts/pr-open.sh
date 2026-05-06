#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/pr-open.sh [options]

Options:
  -r, --repo <owner/repo>     GitHub repository (default: gh repo view)
  -b, --base <branch>         Base branch (default: main)
  -t, --title <title>         PR title (default: gh --fill)
  -B, --body-file <path>      PR body markdown file
  -l, --labels <a,b,c>        Extra labels to add
      --no-watch              Skip `gh pr checks --watch`
  -h, --help                  Show help

Behavior:
  1) push current branch
  2) create draft PR if absent
  3) auto-label agent-pr plus docs/enhancement by changed files
  4) add extra labels
  5) optionally watch checks
USAGE
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}

validate_pr_body_file() {
  local path="$1"
  local missing=()
  local heading

  if [[ ! -f "$path" ]]; then
    echo "body file not found: $path" >&2
    exit 1
  fi

  for heading in \
    "## Summary" \
    "## Product impact" \
    "## Evidence" \
    "## Review evidence" \
    "## Linked issue"
  do
    if ! grep -Fq -- "$heading" "$path"; then
      missing+=("$heading")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "body file is missing required PR hygiene sections:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "expected headings from .github/pull_request_template.md" >&2
    exit 1
  fi
}

validate_no_staged_changes() {
  if ! git diff --cached --quiet --exit-code; then
    echo "staged changes detected; commit or unstage them before opening a PR" >&2
    git diff --cached --name-only >&2
    exit 1
  fi
}

is_doc_path() {
  case "$1" in
    docs/*|examples/trpg-mvp/*|README.md|*.md) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_agent_pr_label() {
  local exists

  exists="$(gh label list --repo "$repo" --search agent-pr --json name --jq 'any(.[]; .name == "agent-pr")' 2>/dev/null || true)"
  if [[ "$exists" == "true" ]]; then
    return 0
  fi

  gh label create agent-pr \
    --repo "$repo" \
    --color "5319E7" \
    --description "Agent-authored draft PR; requires human-approved-ready before ready/merge" \
    >/dev/null 2>&1 || true
}

ensure_pr_is_draft() {
  local pr_number="$1"
  local phase="$2"
  local live
  local live_state
  local live_is_draft

  live="$(
    gh pr view "$pr_number" --repo "$repo" --json state,isDraft \
      --jq '.state + " " + (.isDraft | tostring)'
  )"
  live_state="${live%% *}"
  live_is_draft="${live##* }"

  if [[ "$live_state" != "OPEN" ]]; then
    echo "refusing to continue: PR #$pr_number is $live_state after $phase; expected OPEN draft" >&2
    exit 1
  fi

  if [[ "$live_is_draft" == "true" ]]; then
    return 0
  fi

  echo "PR #$pr_number is ready after $phase; restoring draft state" >&2
  gh pr ready "$pr_number" --repo "$repo" --undo >/dev/null

  live_is_draft="$(
    gh pr view "$pr_number" --repo "$repo" --json isDraft --jq '.isDraft'
  )"
  if [[ "$live_is_draft" != "true" ]]; then
    echo "failed to restore draft state for PR #$pr_number after $phase" >&2
    exit 1
  fi
}

repo=""
base="main"
title=""
body_file=""
extra_labels=""
watch_checks=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--repo) repo="$2"; shift 2 ;;
    -b|--base) base="$2"; shift 2 ;;
    -t|--title) title="$2"; shift 2 ;;
    -B|--body-file) body_file="$2"; shift 2 ;;
    -l|--labels) extra_labels="$2"; shift 2 ;;
    --no-watch) watch_checks=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_cmd git
require_cmd gh
require_cmd jq

load_changed_files() {
  local range="$1"
  changed_files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    changed_files+=("$file")
  done < <(git diff --name-only "$range" 2>/dev/null || true)
}

branch="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$branch" == "main" || "$branch" == "master" ]]; then
  echo "refusing to open PR from branch '$branch'" >&2
  exit 1
fi

validate_no_staged_changes

if [[ -n "$body_file" ]]; then
  validate_pr_body_file "$body_file"
fi

if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi

git push -u origin "$branch"

existing_pr="$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty')"

if [[ -n "$existing_pr" ]]; then
  pr_number="$existing_pr"
else
  create_args=(pr create --repo "$repo" --draft --base "$base" --head "$branch")
  if [[ -n "$title" ]]; then
    create_args+=(--title "$title")
  else
    create_args+=(--fill)
  fi
  if [[ -n "$body_file" ]]; then
    create_args+=(--body-file "$body_file")
  fi

  pr_url="$(gh "${create_args[@]}")"
  pr_number="$(gh pr view "$pr_url" --repo "$repo" --json number --jq .number)"
fi

ensure_pr_is_draft "$pr_number" "create/reuse"
ensure_agent_pr_label

load_changed_files "origin/$base...HEAD"
if [[ ${#changed_files[@]} -eq 0 ]]; then
  load_changed_files "HEAD~1..HEAD"
fi

docs_only=1
has_docs=0
for f in "${changed_files[@]}"; do
  if [[ -z "$f" ]]; then
    continue
  fi
  if is_doc_path "$f"; then
    has_docs=1
  else
    docs_only=0
  fi
done

labels=("agent-pr")
if [[ $has_docs -eq 1 ]]; then
  labels+=("docs")
fi
if [[ $docs_only -eq 0 || ${#changed_files[@]} -eq 0 ]]; then
  labels+=("enhancement")
fi

if [[ -n "$extra_labels" ]]; then
  IFS=',' read -r -a extra <<< "$extra_labels"
  for lb in "${extra[@]}"; do
    lb="$(echo "$lb" | xargs)"
    [[ -n "$lb" ]] && labels+=("$lb")
  done
fi

if [[ ${#labels[@]} -gt 0 ]]; then
  label_json="$(printf '%s\n' "${labels[@]}" | awk 'NF' | sort -u | jq -R . | jq -s '{labels: .}')"
  gh api "repos/$repo/issues/$pr_number/labels" --method POST --input - <<< "$label_json" >/dev/null
  ensure_pr_is_draft "$pr_number" "label application"
fi

pr_url="$(gh pr view "$pr_number" --repo "$repo" --json url --jq .url)"
echo "PR: $pr_url"

if [[ $watch_checks -eq 1 ]]; then
  gh pr checks "$pr_number" --repo "$repo" --watch || true
  echo "PR status:"
  gh pr view "$pr_number" --repo "$repo" \
    --json state,isDraft,mergeStateStatus,headRefOid,url \
    --jq '"state=\(.state) draft=\(.isDraft) mergeState=\(.mergeStateStatus) head=\(.headRefOid)\nurl=\(.url)"' \
    || true
fi
