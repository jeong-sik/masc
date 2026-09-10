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
  - fails on Request_priority type erasure (priority : () patterns in .ml/.mli)
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

# What this pull request added is "reachable from HEAD and not from the base",
# which is what `--not "$BASE_REF"` asks. The merge-base this used to compute
# is not needed for that question, and on a shallow clone it cannot answer it:
#
#   - it returns a grafted boundary and exits 0, so the range spans everything
#     that was fetched and base commits are reported as this pull request's --
#     #35012 saw a main commit, bfc1d630, reported as an empty commit of
#     PR #34929, which never contained it
#   - or it finds no common ancestor at all and exits 1, and under `set -e`
#     this script then died before printing anything, so the lint reported a
#     failure with no line saying why (reproduced in a --depth=2 clone of a
#     branch that merged its base)
#
# Excluding the base directly has neither failure. It also drops the deepening
# loop that stood here, which only recovered when the merge-base came back as
# a commit listed in .git/shallow and not when the graft named another.
RANGE="${HEAD_REF} --not ${BASE_REF}"

RANGE_COMMITS=()
while IFS= read -r commit; do
  RANGE_COMMITS+=("$commit")
done < <(git rev-list --reverse "$HEAD_REF" --not "$BASE_REF")

if [[ ${#RANGE_COMMITS[@]} -eq 0 ]]; then
  echo "No commits in range ${RANGE}"
  exit 0
fi

empty_failures=0
duplicate_hits=0
NON_MERGE_COMMITS=()

BASE_PATCH_FILE="$(mktemp)"
SEEN_PATCH_FILE="$(mktemp)"
cleanup() {
  rm -f "$BASE_PATCH_FILE" "$SEEN_PATCH_FILE"
}
trap cleanup EXIT

git rev-list --no-merges --max-count "$RECENT_MAIN" "$BASE_REF" | while read -r commit; do
  patch_id="$(git show --format=medium --patch "$commit" | git patch-id --stable | awk 'NR == 1 { print $1; exit }')"
  if [[ -n "$patch_id" ]]; then
    subject="$(git show -s --format=%s "$commit")"
    printf '%s\t%s\t%s\n' "$patch_id" "$commit" "$subject" >> "$BASE_PATCH_FILE"
  fi
done

for commit in "${RANGE_COMMITS[@]}"; do
  parents_line="$(git rev-list --parents -n 1 "$commit")"
  parent_count="$(awk '{print NF - 1}' <<<"$parents_line")"
  if [[ "$parent_count" -gt 1 ]]; then
    continue
  fi
  NON_MERGE_COMMITS+=("$commit")

  parent="$(awk '{print $2}' <<<"$parents_line")"
  if [[ -n "$parent" ]]; then
    tree="$(git rev-parse "${commit}^{tree}")"
    parent_tree="$(git rev-parse "${parent}^{tree}")"
    if [[ "$tree" == "$parent_tree" ]]; then
      subject="$(git show -s --format=%s "$commit")"
      echo "::error title=Empty commit detected::${commit} ${subject}"
      empty_failures=1
    fi
  fi

  patch_id="$(git show --format=medium --patch "$commit" | git patch-id --stable | awk 'NR == 1 { print $1; exit }')"
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

if [[ "$empty_failures" -ne 0 ]]; then
  echo "PR hygiene check failed: empty commits detected." >&2
  exit 1
fi

if [[ "$duplicate_hits" -ne 0 && "$DUPLICATE_POLICY" == "fail" ]]; then
  echo "PR hygiene check failed: duplicate patches detected." >&2
  exit 1
fi

# Guard: detect Request_priority type erasure (priority : () or ~priority:())
# See #4186 — a bulk rewrite once replaced Request_priority.t with () across AGENT_CORE files.
priority_erasure=0
while IFS= read -r line; do
  echo "::error title=Priority type erasure::Added line matches erased priority pattern: ${line}"
  priority_erasure=1
# The patches of this pull request's own commits, rather than a two-point diff
# against a merge-base. Same added lines, and no merge-base to be wrong about
# on a shallow clone. Merge commits are left out: their combined diff carries
# whatever the merge brought in, which this pull request did not write.
done < <(
  for pr_commit in ${NON_MERGE_COMMITS+"${NON_MERGE_COMMITS[@]}"}; do
    git show --format= --patch "$pr_commit" -- '*.ml' '*.mli'
  done \
    | grep '^+' | grep -v '^+++' \
    | grep -E 'priority\s*:\s*\(\)|~priority:\(\)' || true)
if [[ "$priority_erasure" -ne 0 ]]; then
  echo "PR hygiene check failed: Request_priority type erasure detected. See #4186." >&2
  exit 1
fi

echo "PR hygiene check passed."
