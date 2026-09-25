#!/usr/bin/env bash
# queue-ledger.sh — one read-only row per open PR: whose decision it waits on, and for how long.
#
# R4 of the leader's queue ruling (board p-9e1306c18b34ea2cbe240dae22a998e1,
# comment c-e5a7d9bba28b56ad339e8b2d838be52d). It never writes to GitHub.
#
# Each Ready PR is run through the green-lane conditions (R1) in order, and the
# first one that fails names who it is waiting on:
#   base!=main          -> parent #N    (stacked; the parent must land first)
#   open CR             -> cr:<login>   (only the CR's author can clear it)
#   head checks != all success -> ci    (pending or failing on the current head)
#   main touched PR files after the head's checks started -> stale:<n files>
#   no APPROVED on the current head -> review
#   otherwise           -> merge        (green lane: ready to merge)
# "Decision" per reviewer is their newest APPROVED/CHANGES_REQUESTED/DISMISSED
# review. A later COMMENTED does not clear a CR (GitHub computes it the same way).
#
# Not covered: a Keeper PASS verdict posted as a COMMENT with a run number (R1
# condition 2) is free text, so this ledger reports it as "review" until an
# APPROVE lands.
#
# Usage: queue-ledger.sh [--repo O/R] [--limit N] [--git-dir DIR] [--format tsv|md]
#   --git-dir: a clone of the repo; used for `git log origin/main` (stale check).
#              Without it the stale column reads "?".
# Needs bash + gh (+ git for the stale check). All JSON goes through gh --jq.
set -u
GH="${LEDGER_GH:-gh}"
repo="jeong-sik/masc"; limit=200; gitdir=""; fmt="tsv"
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="${2-}"; shift 2 ;;
    --limit) limit="${2-}"; shift 2 ;;
    --git-dir) gitdir="${2-}"; shift 2 ;;
    --format) fmt="${2-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

now=$(date -u +%s)

# One row per PR: number, author, base, head sha, head-branch, draft,
# checks-verdict, oldest check start, open-CR logins, approved-on-head logins,
# head committed date, files (comma list).
# shellcheck disable=SC2016
rows=$("$GH" pr list --repo "$repo" --state open --limit "$limit" \
  --json number,author,baseRefName,headRefOid,headRefName,isDraft,createdAt,statusCheckRollup,files,latestReviews \
  --jq '.[] | select(.isDraft|not) |
    [ .number, .author.login, .baseRefName, .headRefOid, .headRefName,
      ( if (.statusCheckRollup|length)==0 then "none"
        elif all(.statusCheckRollup[]; (.conclusion//.state)=="SUCCESS" or (.conclusion//"")=="SKIPPED" or (.conclusion//"")=="NEUTRAL") then "ok"
        elif any(.statusCheckRollup[]; (.conclusion//.state)=="FAILURE" or (.conclusion//"")=="TIMED_OUT" or (.conclusion//"")=="CANCELLED") then "fail"
        else "pending" end ),
      ( [.statusCheckRollup[] | .startedAt // empty] | min // "" ),
      .createdAt,
      ( [.files[]?.path] | join(",") )
    ] | @tsv') || { echo "gh pr list failed" >&2; exit 1; }

# Per-reviewer newest decision needs the full review list (latestReviews may end
# on a COMMENTED). One REST call per PR.
decisions() { # pr head -> "cr=<a,b>\tapproved_head=<a,b>"
  "$GH" api --paginate "repos/$repo/pulls/$1/reviews" \
    --jq '.[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED") | [.user.login, .state, .commit_id, .submitted_at] | @tsv' \
  | awk -F'\t' -v head="$2" '
      { if (!($1 in t) || $4 > t[$1]) { t[$1]=$4; s[$1]=$2; c[$1]=$3 } }
      END { cr=""; ap="";
            for (u in s) { if (s[u]=="CHANGES_REQUESTED") cr=cr (cr?",":"") u;
                           if (s[u]=="APPROVED" && c[u]==head) ap=ap (ap?",":"") u }
            printf "%s\t%s\n", cr, ap }'
}

stale_count() { # since files -> number of PR files touched on main after since
  [ -n "$gitdir" ] && [ -n "$1" ] || { echo "?"; return; }
  git -C "$gitdir" log origin/main --since="$1" --name-only --format= 2>/dev/null \
    | sort -u | grep -Fxf <(tr ',' '\n' <<<"$2") | wc -l | tr -d ' '
}

[ -n "$gitdir" ] && git -C "$gitdir" fetch -q origin main 2>/dev/null

age_h() { local t; t=$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s); echo $(( (now - t) / 3600 )); }

heads=$(printf '%s\n' "$rows" | awk -F'\t' '{print $5"\t"$1}')

[ "$fmt" = md ] && { echo "| PR | author | waits on | age h | checks | stale files |"; echo "|---|---|---|---|---|---|"; }
[ "$fmt" = tsv ] && printf 'pr\tauthor\twaits_on\tage_h\tchecks\tstale_files\n'

printf '%s\n' "$rows" | while IFS=$'\t' read -r num author base head _branch checks started created files; do
  [ -n "$num" ] || continue
  age=$(age_h "$created")
  stale="-"
  if [ "$base" != "main" ]; then
    parent=$(awk -F'\t' -v b="$base" '$1==b{print $2}' <<<"$heads")
    waits="parent ${parent:+#$parent}${parent:-$base}"
  else
    IFS=$'\t' read -r cr approved < <(decisions "$num" "$head")
    if [ -n "$cr" ]; then waits="cr:$cr"
    elif [ "$checks" != ok ]; then waits="ci:$checks"
    else
      stale=$(stale_count "$started" "$files")
      if [ "$stale" != "?" ] && [ "$stale" -gt 0 ]; then waits="stale:$stale"
      elif [ -z "$approved" ]; then waits="review"
      else waits="merge"; fi
    fi
  fi
  if [ "$fmt" = md ]; then printf '| #%s | %s | %s | %s | %s | %s |\n' "$num" "$author" "$waits" "$age" "$checks" "$stale"
  else printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$author" "$waits" "$age" "$checks" "$stale"; fi
done
