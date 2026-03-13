#!/usr/bin/env bash
set -euo pipefail

BASE_REF=""
HEAD_REF="HEAD"
RECENT_MAIN=50
DUPLICATE_POLICY="warn"

usage() {
  cat <<'EOF'
Usage: scripts/check-pr-hygiene.sh --base <git-ref> [--head <git-ref>] [--recent-main N] [--duplicate-policy warn|fail]

Checks:
  - fails on empty commits in the PR range
  - warns or fails on duplicate patch-ids already present in recent base history
  - fails when dashboard source/config changes without refreshed assets/dashboard output
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      BASE_REF="${2:-}"
      shift 2
      ;;
    --head)
      HEAD_REF="${2:-}"
      shift 2
      ;;
    --recent-main)
      RECENT_MAIN="${2:-}"
      shift 2
      ;;
    --duplicate-policy)
      DUPLICATE_POLICY="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BASE_REF" ]]; then
  echo "--base is required" >&2
  usage >&2
  exit 2
fi

if [[ "$DUPLICATE_POLICY" != "warn" && "$DUPLICATE_POLICY" != "fail" ]]; then
  echo "--duplicate-policy must be warn or fail" >&2
  exit 2
fi

MERGE_BASE="$(git merge-base "$BASE_REF" "$HEAD_REF")"
RANGE="${MERGE_BASE}..${HEAD_REF}"

RANGE_COMMITS=()
while IFS= read -r commit; do
  RANGE_COMMITS+=("$commit")
done < <(git rev-list --reverse "$RANGE")

if [[ ${#RANGE_COMMITS[@]} -eq 0 ]]; then
  echo "No commits in range ${RANGE}"
  exit 0
fi

empty_failures=0
duplicate_hits=0
asset_contract_failures=0

BASE_PATCH_FILE="$(mktemp)"
SEEN_PATCH_FILE="$(mktemp)"
cleanup() {
  rm -f "$BASE_PATCH_FILE" "$SEEN_PATCH_FILE"
}
trap cleanup EXIT

git rev-list --no-merges --max-count "$RECENT_MAIN" "$BASE_REF" | while read -r commit; do
  patch_id="$(git show --format=medium --patch "$commit" | git patch-id --stable | awk '{print $1}')"
  if [[ -n "$patch_id" ]]; then
    subject="$(git show -s --format=%s "$commit")"
    printf '%s\t%s\t%s\n' "$patch_id" "$commit" "$subject" >> "$BASE_PATCH_FILE"
  fi
done

for commit in "${RANGE_COMMITS[@]}"; do
  parent="$(git rev-list --parents -n 1 "$commit" | awk '{print $2}')"
  if [[ -n "$parent" ]]; then
    tree="$(git rev-parse "${commit}^{tree}")"
    parent_tree="$(git rev-parse "${parent}^{tree}")"
    if [[ "$tree" == "$parent_tree" ]]; then
      subject="$(git show -s --format=%s "$commit")"
      echo "::error title=Empty commit detected::${commit} ${subject}"
      empty_failures=1
    fi
  fi

  patch_id="$(git show --format=medium --patch "$commit" | git patch-id --stable | awk '{print $1}')"
  [[ -z "$patch_id" ]] && continue

  seen_commit="$(awk -F '\t' -v patch="$patch_id" '$1 == patch { print $2; exit }' "$SEEN_PATCH_FILE")"
  if [[ -n "$seen_commit" ]]; then
    subject="$(git show -s --format=%s "$commit")"
    echo "::warning title=Duplicate patch in PR::${commit} ${subject} duplicates ${seen_commit} in the same PR range"
    duplicate_hits=1
    continue
  fi
  printf '%s\t%s\n' "$patch_id" "$commit" >> "$SEEN_PATCH_FILE"

  base_row="$(awk -F '\t' -v patch="$patch_id" '$1 == patch { print $2 "\t" $3; exit }' "$BASE_PATCH_FILE")"
  if [[ -n "$base_row" ]]; then
    base_commit="$(printf '%s' "$base_row" | cut -f1)"
    base_subject="$(printf '%s' "$base_row" | cut -f2-)"
    subject="$(git show -s --format=%s "$commit")"
    if [[ "$DUPLICATE_POLICY" == "fail" ]]; then
      echo "::error title=Duplicate patch against base::${commit} ${subject} duplicates ${base_commit} ${base_subject}"
      duplicate_hits=1
    else
      echo "::warning title=Duplicate patch against base::${commit} ${subject} duplicates ${base_commit} ${base_subject}"
      duplicate_hits=1
    fi
  fi
done

dashboard_source_changed=0
dashboard_assets_changed=0
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  case "$path" in
    dashboard/src/*|dashboard/vite.config.ts|dashboard/package.json|dashboard/tsconfig.json)
      dashboard_source_changed=1
      ;;
    assets/dashboard/*)
      dashboard_assets_changed=1
      ;;
  esac
done < <(git diff --name-only "$RANGE")

if [[ "$dashboard_source_changed" -eq 1 && "$dashboard_assets_changed" -eq 0 ]]; then
  echo "::error title=Dashboard assets missing::dashboard source or Vite config changed but assets/dashboard was not updated"
  asset_contract_failures=1
fi

if [[ "$empty_failures" -ne 0 ]]; then
  echo "PR hygiene check failed: empty commits detected." >&2
  exit 1
fi

if [[ "$asset_contract_failures" -ne 0 ]]; then
  echo "PR hygiene check failed: dashboard assets are out of sync." >&2
  exit 1
fi

if [[ "$duplicate_hits" -ne 0 && "$DUPLICATE_POLICY" == "fail" ]]; then
  echo "PR hygiene check failed: duplicate patches detected." >&2
  exit 1
fi

echo "PR hygiene check passed."
