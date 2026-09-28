#!/usr/bin/env bash
# queue-ledger.sh — one read-only row per open PR: whose decision it waits on, and for how long.
#
# R4 of the leader's queue ruling (board p-9e1306c18b34ea2cbe240dae22a998e1,
# c-e5a7d9bb; revised R1 in c-e6f570d0). It never writes to GitHub.
#
# Each Ready PR is walked through the green-lane (R1) conditions in order; the
# first one that fails is the `waits_on` value:
#   parent #N / parent <ref>  stacked: base is not main (condition 5)
#   cr:<logins>               an account's newest decision review is CHANGES_REQUESTED (4)
#   ci:<state>                the head's checks are not green (1)
#   stale:<files>             main changed PR files after the head's checks started (3)
#   dependency:<files>        shared check inputs changed after the run started
#   review                    no PASS verdict line on the current head (2),
#                             or no trusted formal approval on it yet
#   merge                     all five hold, plus a trusted formal approval
#   unknown:<step>            a read failed; never treated as green (fail-closed)
#
# Condition 2 reads only the verdict line the leader fixed in R1 §1, as the first
# line of a PR comment or review body:
#   verdict: PASS|FAIL head: <40-hex sha> run: <PR check run id> by: <name>
# The newest structured verdict naming the current head decides. HOLD, COMMENT,
# unknown states and incomplete PASS lines cannot leave an older PASS in force.
# Free-text comments are not parsed as decisions. A PASS counts only if its run
# is a completed+success run on that head that was not a pull_request run while
# the PR was a Draft (R1 §3): all-skipped Draft runs conclude "success" too, so a
# run whose jobs were all skipped does not count.
# Not checked: R1 §2's "the verdict's author did not write or push the PR". The
# ledger cannot map `by:` names to pushers, so a reviewer has to check it.
#
# Checks (condition 1): per check name, skipped/cancelled rows are ignored (a
# Draft-time suite is all-skipped, and its ids can be newer than the real run's;
# see approve-guard §3 / #39046) and the newest remaining row by startedAt must be
# SUCCESS. A name with only skipped rows is not green.
#
# Cancelled rows are ignored too: two runs on one head can start in the same
# second and the loser is cancelled (#39049), so a cancelled row says nothing.
#
# Freshness is evaluated by ci-freshness.py using the cited PR-check creation
# time and immutable live main identity. No test/dune or clean-merge exemption.
#
# Usage:
#   queue-ledger.sh --git-dir DIR [--repo O/R] [--limit N] [--format tsv|md]
#   queue-ledger.sh --git-dir DIR --pairs      # open PR pairs whose hunks overlap (R1 §6)
# --git-dir is a clone of the repo and is required: without it the stale check
# cannot run, and a ledger that cannot see staleness must not print `merge`.
# Needs bash + gh + git. All JSON goes through gh --jq.
set -u
GH="${LEDGER_GH:-gh}"
repo="jeong-sik/masc"; limit=200; gitdir=""; fmt="tsv"; mode="ledger"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--limit|--git-dir|--format)
      if [ $# -lt 2 ] || [ -z "${2-}" ] || [[ "${2-}" == --* ]]; then
        echo "queue-ledger: $1 requires a value" >&2
        exit 1
      fi ;;
  esac
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --git-dir) gitdir="$2"; shift 2 ;;
    --format) fmt="$2"; shift 2 ;;
    --pairs) mode="pairs"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done
[ -n "$gitdir" ] || { echo "--git-dir is required" >&2; exit 1; }
git -C "$gitdir" fetch -q origin main || { echo "git fetch origin main failed" >&2; exit 1; }
main_sha=$(git -C "$gitdir" rev-parse origin/main) || exit 1
now=$(date -u +%s)
tab=$(printf '\t')

epoch() { date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s; }

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

# ---------------------------------------------------------------- ledger mode
rows=$("$GH" pr list --repo "$repo" --state open --limit "$limit" \
  --json number,author,baseRefName,headRefOid,headRefName,isDraft,createdAt,statusCheckRollup,files \
  --jq '.[] | select(.isDraft|not) |
    ( [.statusCheckRollup[] | select((.conclusion//"") != "SKIPPED" and (.conclusion//"") != "CANCELLED")]
      | group_by(.name) | map(sort_by(.startedAt // "") | last) ) as $latest |
    ( [.statusCheckRollup[].name] | unique | length ) as $names |
    [ .number, .author.login, .baseRefName, .headRefOid, .headRefName,
      ( if $names == 0 then "none"
        elif ($latest|length) < $names then "skipped"
        elif any($latest[]; (.conclusion//.state) == "FAILURE" or (.conclusion//"") == "TIMED_OUT") then "fail"
        elif all($latest[]; (.conclusion//.state) == "SUCCESS" or (.conclusion//"") == "NEUTRAL") then "ok"
        else "pending" end ),
      ( [$latest[] | .startedAt // empty] | min // "" ),
      .createdAt,
      ( [.files[]?.path] | join(",") )
    ] | @tsv') || { echo "gh pr list failed" >&2; exit 1; }

# Materialize missing candidates in one network read before per-row freshness.
# The evaluator keeps its SHA fetch fallback for standalone use and a head
# that moved between this list and fetch; a batch failure must not fan out into
# up to --limit separate fetches or print a partially evaluated queue.
pr_refs=()
while IFS=$'\t' read -r num _author _base head _rest; do
  [ -n "$num" ] || continue
  if ! git -C "$gitdir" cat-file -e "$head^{commit}" 2>/dev/null; then
    pr_refs+=("refs/pull/$num/head")
  fi
done <<<"$rows"
if [ ${#pr_refs[@]} -gt 0 ]; then
  git -C "$gitdir" fetch -q --no-tags origin "${pr_refs[@]}" || {
    echo "git fetch PR heads failed" >&2; exit 1;
  }
fi

# Newest decision per account (a later COMMENTED does not clear a CR).
# Review IDs preserve order even when submitted_at has the same second.
open_crs() {
  "$GH" api --paginate "repos/$repo/pulls/$1/reviews" \
    --jq '.[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED") | [.user.login, (.id|tostring), .state] | @tsv' \
  | awk -F'\t' 'NF && (!($1 in id) || $2+0 > id[$1]) { id[$1]=$2+0; s[$1]=$3 }
      END { cr=""; for (u in s) if (s[u]=="CHANGES_REQUESTED") cr=cr (cr?",":"") u; print cr }'
  return "${PIPESTATUS[0]}"
}

# Trusted formal approval on this head? -> yes/no. The merge guard refuses a
# PR no participant APPROVED on its head, so a structured PASS alone must not
# route to merge: the outstanding decision still belongs to a reviewer.
formally_approved() { # pr head
  local footer_prefix approval_head_jq
  footer_prefix="$(printf 'approve-guard: head \x60%s\x60 · ' "$2")"
  approval_head_jq="((.body // \"\" | split(\"\\n\") | first) | startswith(\"verdict: PASS head: ${2} run: \")) and ((.body // \"\" | split(\"\\n\") | map(select(length > 0)) | (last // \"\")) | startswith(\"${footer_prefix}\"))"
  "$GH" api --paginate "repos/$repo/pulls/$1/reviews" \
    --jq ".[] | select(.state==\"APPROVED\" or .state==\"CHANGES_REQUESTED\" or .state==\"DISMISSED\") | [.user.login, (.id|tostring), .state, (($approval_head_jq)|tostring), (.author_association//\"UNKNOWN\")] | @tsv" \
  | awk -F'\t' '
      NF && (!($1 in id) || $2+0 > id[$1]) { id[$1]=$2+0; s[$1]=$3; bound[$1]=$4; a[$1]=$5 }
      END { for (u in s)
        if (s[u]=="APPROVED" && bound[u]=="true" &&
            (a[u]=="OWNER" || a[u]=="MEMBER" || a[u]=="COLLABORATOR")) ok=1
        print (ok ? "yes" : "no") }'
  return "${PIPESTATUS[0]}"
}

source "$(dirname "$0")/review-verdict.sh"

# Is run <id> a finished, successful, non-all-skipped run on <head>? -> yes/no
run_counts() { # run head
  local meta jobs
  meta=$("$GH" api "repos/$repo/actions/runs/$1" --jq '[.head_sha, .status, (.conclusion//"none")] | @tsv') || return 1
  IFS=$'\t' read -r rs rst rc <<<"$meta"
  [ "$rs" = "$2" ] && [ "$rst" = completed ] && [ "$rc" = success ] || { echo no; return 0; }
  jobs=$("$GH" api --paginate "repos/$repo/actions/runs/$1/jobs" --jq '.jobs[] | .conclusion // "none"') || return 1
  printf '%s\n' "$jobs" | grep -qx success && echo yes || echo no
}

heads=$(printf '%s\n' "$rows" | awk -F'\t' '{print $5"\t"$1}')
[ "$fmt" = md ] && { printf '| PR | author | waits on | age h | checks | stale files | verdict |\n|---|---|---|---|---|---|---|\n'; }
[ "$fmt" = tsv ] && printf 'pr\tauthor\twaits_on\tage_h\tchecks\tstale_files\tverdict\n'

printf '%s\n' "$rows" | while IFS=$'\t' read -r num author base head _branch checks started created files; do
  [ -n "$num" ] || continue
  age=$(( (now - $(epoch "$created")) / 3600 ))
  stale="-"; verdict="-"; dependencies=""
  if [ "$base" != main ]; then
    parent=$(awk -F'\t' -v b="$base" '$1==b{print $2}' <<<"$heads")
    waits="parent ${parent:+#$parent}${parent:-$base}"
  elif ! cr=$(open_crs "$num"); then waits="unknown:reviews"
  elif [ -n "$cr" ]; then waits="cr:$cr"
  elif [ "$checks" != ok ]; then waits="ci:$checks"
  else
    # Diagnose obsolete CI before requesting review. The final PASS below
    # still validates its own cited run, never substitutes this selected one.
    freshness=$(GUARD_GH="$GH" python3 "$(dirname "$0")/ci-freshness.py" \
      --repo "$repo" --pr "$num" --head "$head" --git-dir "$gitdir" --format ledger) || freshness=$'unknown:freshness\t?'
    IFS=$'\t' read -r waits stale <<<"$freshness"
    if [ "$waits" != fresh ]; then :
    elif ! v=$(verdict_for "$num" "$head"); then waits="unknown:verdict"
    else
    read -r vstate vrun vby <<<"$v"
    verdict="${vstate:--}"
    [ -z "${vby:-}" ] || [ "$vby" = - ] || verdict="$verdict by $vby"
    if [ "${vstate:-}" != PASS ]; then waits="review"
    elif ! ok=$(run_counts "$vrun" "$head"); then waits="unknown:run"
    elif [ "$ok" != yes ]; then waits="review"; verdict="PASS run $vrun not countable"
    else
      freshness=$(GUARD_GH="$GH" python3 "$(dirname "$0")/ci-freshness.py" \
        --repo "$repo" --pr "$num" --head "$head" --run "$vrun" --git-dir "$gitdir" --format ledger) || freshness=$'unknown:freshness\t?'
      IFS=$'\t' read -r waits stale <<<"$freshness"
      if [ "$waits" = fresh ]; then
        if ! ok=$(formally_approved "$num" "$head"); then waits="unknown:reviews"
        elif [ "$ok" = yes ]; then waits="merge"
        else waits="review"
        fi
      fi
    fi
    fi
  fi
  if [ "$fmt" = md ]; then printf '| #%s | %s | %s | %s | %s | %s | %s |\n' "$num" "$author" "$waits" "$age" "$checks" "$stale" "$verdict"
  else printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$author" "$waits" "$age" "$checks" "$stale" "$verdict"; fi
done
echo "# main $main_sha" >&2
