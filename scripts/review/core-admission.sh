#!/usr/bin/env bash
# Admit one source-approved bottom PR for an explicitly requested Core build.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
GH="${GUARD_GH:-gh}"
repo=""; pr=""; head=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--pr|--head)
      [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || exit 2;;
    *) echo "core-admission: unknown argument $1" >&2; exit 2;;
  esac
  case "$1" in
    --repo) repo="$2";; --pr) pr="$2";; --head) head="$2";;
  esac
  shift 2
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ &&
   "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || exit 2
[ "${GITHUB_REF:-}" = refs/heads/main ] || {
  echo "core-admission: dispatch the trusted main workflow" >&2; exit 2;
}
source "$here/ci-checks.sh"
read_current_pr
[ "$pr_base" = main ] && [ "$review_policy" = source ] || {
  echo "core-admission: require an ordinary bottom PR targeting main" >&2; exit 2;
}
approval=$(bash "$here/approve-guard.sh" --merge-check --receipt-json \
  --repo "$repo" --pr "$pr" --head "$head")
# Preserve the identity observed before the shared approval guard ran.
read_current_pr
python3 -c '
import json, sys
approval = json.loads(sys.argv[1])
print(json.dumps({"schema": "masc.core-admission.v1", "repository": sys.argv[2],
                  "pr": approval["pr"], "head": approval["head"],
                  "base": sys.argv[3], "approval_ids": approval["approval_ids"],
                  "merge_authorized": False}))
' "$approval" "$repo" "$pr_base_sha"
