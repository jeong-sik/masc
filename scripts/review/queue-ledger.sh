#!/usr/bin/env bash
# Source-review queue; native stacks admit every open downstack PR.
set -euo pipefail
GH="${LEDGER_GH:-gh}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="jeong-sik/masc"; limit=200; fmt="tsv"; mode="ledger"
while [ $# -gt 0 ]; do
  case "$1" in --repo|--limit|--format) [ $# -ge 2 ] && [ -n "$2" ] && [[ "$2" != --* ]] || exit 1;; esac
  case "$1" in
    --repo) repo="$2"; shift 2;; --limit) limit="$2"; shift 2;;
    --format) fmt="$2"; shift 2;; --pairs) mode=pairs; shift;;
    *) echo "queue-ledger: unknown argument $1" >&2; exit 1;;
  esac
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$limit" =~ ^[1-9][0-9]*$ ]] || exit 2
case "$fmt" in tsv|md);; *) exit 2;; esac
tab=$(printf '\t')
# ---------------------------------------------------------------- pairs mode
if [ "$mode" = pairs ]; then
  # file \t start \t end \t pr, from each PR's diff against its merge base.
  nums=$("$GH" pr list --repo "$repo" --state open --limit "$limit" --json number,isDraft \
    --jq '.[] | select(.isDraft|not) | .number') || exit 1
  hunks=$(for n in $nums; do
    "$GH" pr diff "$n" --repo "$repo" 2>/dev/null | awk -v pr="$n" '
      /^--- a\// { f=substr($0,7) } /^--- \/dev\/null/ { f="" }
      /^@@ / && f!="" { split($2,a,","); s=substr(a[1],2)+0; l=(a[2]==""?1:a[2]+0);
                        printf "%s\t%d\t%d\t%s\n", f, s, s+(l>0?l-1:0), pr }'
  done | sort -t "$tab" -k1,1 -k2,2n)
  printf 'file\tpr_a\tpr_b\tlines\n'
  printf '%s\n' "$hunks" | awk -F'\t' '
    NF { if ($1==f) for (i=1;i<=k;i++) if (e[i]>=$2 && p[i]!=$4) printf "%s\t#%s\t#%s\t%d-%d\n", $1, p[i], $4, $2, (e[i]<$3?e[i]:$3)
         if ($1!=f) { f=$1; k=0 } k++; e[k]=$3; p[k]=$4 }' | sort -u
  exit 0
fi

source "$here/ci-checks.sh"
rows=$("$GH" pr list --repo "$repo" --state open --limit "$limit" \
  --json number,author,baseRefName,headRefOid,headRefName,isDraft \
  --jq '.[] | [.number, .author.login, .baseRefName, .headRefOid, .headRefName, (.isDraft|tostring)] | @tsv')
[ "$fmt" != md ] || printf '| PR | author | waits on | evidence | verdict |\n|---|---|---|---|---|\n'
[ "$fmt" != tsv ] || printf 'pr\tauthor\twaits_on\tevidence\tverdict\n'
while IFS=$'\t' read -r pr author base head branch draft; do
  [ -n "$pr" ] || continue
  review_identity=""; run=""; verdict="-"; evidence="GitHub reviews"; waits="review"
  if [ "$draft" = true ]; then waits=draft
  else
    review_exit=0
    value=$(python3 "$here/github-reviews.py" --repo "$repo" --pr "$pr" --head "$head" --gh "$GH") || review_exit=$?
    if [ -n "$value" ]; then
      verdict=$(printf '%s' "$value" | jq -r 'if (.approval_ids | length) > 0 then "APPROVED " + (.approval_ids | map(tostring) | join(",")) else "-" end')
      earlier=$(printf '%s' "$value" | jq -r '[.superseded_change_requests[]? | (.id | tostring)] | join(",")')
      [ -z "$earlier" ] || verdict="$verdict; earlier CR $earlier"
      requests=$(printf '%s' "$value" | jq -r '[.change_requests[] | "open CHANGES_REQUESTED from \(.login) (review \(.id))"] | join("; ")')
      [ -z "$requests" ] || waits="$requests"
    fi
    if [ "$review_exit" -eq 0 ]; then
      # Ordinary source reviews do not wait for CI. Release verification is
      # checked separately, without changing whether an approval may be sent.
      if read_current_pr && { [ "$review_policy" != release ] || check_current_ci; }; then
        [ "$review_policy" != release ] || evidence="release run $release_run"
        if [ "$pr_base" != "$base" ] || [ "$pr_branch" != "$branch" ]; then
          waits="unknown:PR base or branch changed during read"
        elif [ "${pr_stack:-null}" != null ]; then
          if accepted_scope=$(MASC_REVIEW_GH="$GH" python3 "$here/stack-scope.py" "$repo" "$pr" "$head"); then
            target=$(printf '%s' "$accepted_scope" | jq -r 'if .stack != null then .stack.base.ref else .scope[0].identity.base.ref end')
            if [ "$(printf '%s' "$accepted_scope" | jq -r '.stack != null')" = true ]; then
              waits="review native stack through #$pr into $target"
            else waits="review scope into $target"; fi
          else waits="unknown:native stack scope changed or is unavailable"; fi
        elif [ "$base" != main ]; then
          parent=$(printf '%s\n' "$rows" | awk -F '\t' -v base="$base" '$5==base {print $1; exit}')
          waits="parent ${parent:+#}${parent:-$base}"
        else waits=merge; fi
      else
        ci_exit=$?
        if [ "$ci_exit" -eq 2 ]; then waits="release CI or changed PR"
        else waits="unknown:CI or PR read failed"; fi
      fi
    elif [ "$review_exit" -ne 2 ] || [ -z "$value" ]; then
      waits="unknown:review state unavailable or PR changed"
    fi
  fi
  if [ "$fmt" = md ]; then
    waits=$(printf '%s' "$waits" | python3 -c 'import sys; print(sys.stdin.read().replace("\\", "\\\\").replace("|", "\\|").replace("\n", " "), end="")')
    printf '| #%s | %s | %s | %s | %s |\n' "$pr" "$author" "$waits" "$evidence" "$verdict"
  else printf '%s\t%s\t%s\t%s\t%s\n' "$pr" "$author" "$waits" "$evidence" "$verdict"; fi
done <<<"$rows"
