# Shared exact-head decision reader. Caller supplies GH and repo; read-only.
# The authenticated GitHub author owns each decision, not its `by:` label.
verdict_for() { # pr head [validated own CR id] [actor filter] [verdict|json]
  local lines value exclude_review="${3:-}" actor="${4:-}" format="${5:-verdict}"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  [ -z "$exclude_review" ] || [[ "$exclude_review" =~ ^[1-9][0-9]*$ ]] || {
    echo "approve-guard: invalid replacement review id" >&2; return 1;
  }
  lines=$( { "$GH" api --paginate "repos/$repo/issues/$1/comments" --jq '.[] | {kind:"comment",record:.} | @json' &&
             "$GH" api --paginate "repos/$repo/pulls/$1/reviews" --jq '.[] | {kind:"review",record:.} | @json'; } ) || {
    echo "approve-guard: verdict read failed: comments/reviews of PR $1" >&2; return 1;
  }
  local args=(--head "$2" --format "$format")
  [ -z "$exclude_review" ] || args+=(--exclude-review "$exclude_review")
  [ -z "$actor" ] || args+=(--actor "$actor")
  value=$(printf '%s\n' "$lines" | python3 "$script_dir/review-decisions.py" "${args[@]}") || {
    echo "approve-guard: verdict read failed: invalid decision records for PR $1" >&2; return 1;
  }
  printf '%s\n' "$value"
}
