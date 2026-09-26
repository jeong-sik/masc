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
#   dependency:<files>        OCaml check inputs changed after the run started
#   review                    no PASS verdict line on the current head (2)
#   merge                     all five hold
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
# Stale (condition 3) is counted from the earliest createdAt of this head's
# non-skipped, non-cancelled pull_request workflow runs, and against the PR's
# full file list (re-read past gh's 100-file cap).
# test/dune exception (R1 §5): test/dune does not
# count when the PR's own change to it and every main change to it since the
# check start only add lines, `git merge-tree` of PR head and main is clean, and
# the merged tree's test/dune declares no test name twice (leader c-f17dc594:
# add-only + clean merge still breaks dune when both sides add the same name).
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
    --repo) repo="${2-}"; shift 2 ;;
    --limit) limit="${2-}"; shift 2 ;;
    --git-dir) gitdir="${2-}"; shift 2 ;;
    --format) fmt="${2-}"; shift 2 ;;
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

# Newest decision per account (a later COMMENTED does not clear a CR).
open_crs() {
  "$GH" api --paginate "repos/$repo/pulls/$1/reviews" \
    --jq '.[] | select(.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED") | [.user.login, .state, .submitted_at] | @tsv' \
  | awk -F'\t' '{ if (!($1 in t) || $3 > t[$1]) { t[$1]=$3; s[$1]=$2 } }
      END { cr=""; for (u in s) if (s[u]=="CHANGES_REQUESTED") cr=cr (cr?",":"") u; print cr }'
  return "${PIPESTATUS[0]}"
}

# Newest structured verdict for this head; malformed evidence never grants PASS.
verdict_for() { # pr head
  local lines
  lines=$( { "$GH" api --paginate "repos/$repo/issues/$1/comments" --jq '.[] | [(.updated_at // .created_at), .body] | @tsv' &&
             "$GH" api --paginate "repos/$repo/pulls/$1/reviews" --jq '.[] | [.submitted_at, .body] | @tsv'; } ) || return 1
  printf '%s\n' "$lines" | awk -F'\t' -v head="$2" '
    { body=$2; sub(/\\n.*/, "", body); sub(/\\r$/, "", body)
      n=split(body, w, " ")
      names_head=0; head_fields=0
      for (i=3; i<n; i++) if (w[i]=="head:") {
        head_fields++; if (w[i+1]==head) names_head=1
      }
      if (w[1]=="verdict:" && names_head) {
        state=w[2]; run="-"; by="-"
        if (state=="PASS" || state=="FAIL") {
          if (body ~ /^verdict: (PASS|FAIL) head: [0-9a-f]+ run: [1-9][0-9]* by: [A-Za-z0-9._-]+$/ &&
              n==8 && head_fields==1 && w[3]=="head:" && w[4]==head &&
              w[5]=="run:" && w[6] ~ /^[1-9][0-9]*$/ &&
              w[7]=="by:" && w[8] ~ /^[A-Za-z0-9._-]+$/) { run=w[6]; by=w[8] }
          else state="INVALID"
        } else if (state!="HOLD" && state!="COMMENT") state="UNKNOWN"
        # Conflicting decisions in the same API timestamp cannot grant PASS.
        if ($1 > t || ($1==t && state!="PASS")) {
          t=$1; v=state" "run" "by
        }
      } }
    END { print v }'
}

# Is run <id> a finished, successful, non-all-skipped run on <head>? -> yes/no
run_counts() { # run head
  local meta jobs
  meta=$("$GH" api "repos/$repo/actions/runs/$1" --jq '[.head_sha, .status, (.conclusion//"none")] | @tsv') || return 1
  IFS=$'\t' read -r rs rst rc <<<"$meta"
  [ "$rs" = "$2" ] && [ "$rst" = completed ] && [ "$rc" = success ] || { echo no; return 0; }
  jobs=$("$GH" api --paginate "repos/$repo/actions/runs/$1/jobs" --jq '.jobs[] | .conclusion // "none"') || return 1
  printf '%s\n' "$jobs" | grep -qx success && echo yes || echo no
}

# stdin: a dune file. Succeeds when no name from `(name X)` or `(names a b c)`
# appears twice. Comments (`;` to end of line) are dropped; a stanza may span lines.
# `(alias (name runtest) ...)` stanzas are skipped: dune merges aliases, so a
# repeated alias name is legal. Names inside `(include x.inc)` files are not read.
# An empty name list fails: a tree we could not read must not grant the exemption.
dune_names_unique() {
  local names
  names=$(sed 's/;.*//' | tr '\n' ' ' |
    sed -E 's/\(alias[[:space:]]+\(name[[:space:]]+[^()]*\)//g' |
    grep -oE '\((name|names)[[:space:]]+[^()]*\)' |
    sed -E 's/^\((name|names)[[:space:]]+//; s/\)$//' | tr -s ' \t' '\n' | grep .) || return 1
  [ -z "$(sort <<<"$names" | uniq -d)" ]
}

# These are inputs consumed by pr-check.yml: the setup action hashes the root
# opam manifests, lock, dune-project and pin script; pin/install actions execute
# their own scripts, and setup invokes the cache-freshness script. A change to
# these inputs invalidates earlier OCaml evidence even without a shared .ml file.
# Keep docs-only PRs separate: this is dependency coverage, not a global gate.
stale_dependencies() ( # changed-main-paths pr-files
  set -o pipefail
  printf '%s\n' "$2" | tr ',' '\n' | grep -E '\.(ml|mli)$' >/dev/null || return 0
  printf '%s\n' "$1" | awk '
    /^(masc\.opam\.locked|dune-project|[^\/]+\.opam)$/ ||
    /^scripts\/(opam-pin-external-deps\.sh|ci\/opam-cache-freshness\.sh)$/ ||
    /^\.github\/actions\/(setup-ocaml-toolchain|pin-ocaml-deps|install-ocaml-deps)\// ||
    /^\.github\/workflows\/pr-check\.yml$/ { print }
  ' | sort -u | paste -sd, -
)

# Files the PR touches that main changed after <since>; test/dune dropped per R1 §5.
stale_files() { # since files head changed-main-paths
  local changed hit
  changed="$4"
  hit=$(printf '%s\n' "$changed" | sort -u | grep -Fx -f <(tr ',' '\n' <<<"$2") || true)
  if printf '%s\n' "$hit" | grep -qx 'test/dune'; then
    # Every git read must succeed and be non-empty: an empty revision would make
    # `git diff` fail, the grep see nothing, and the exemption be granted.
    local base_c mb pr_diff main_diff
    base_c=$(git -C "$gitdir" rev-list -1 --before="$1" origin/main) && [ -n "$base_c" ] || return 1
    git -C "$gitdir" cat-file -e "$3^{commit}" 2>/dev/null || return 1
    mb=$(git -C "$gitdir" merge-base "$3" origin/main) && [ -n "$mb" ] || return 1
    pr_diff=$(git -C "$gitdir" diff "$mb" "$3" -- test/dune) || return 1
    main_diff=$(git -C "$gitdir" diff "$base_c" origin/main -- test/dune) || return 1
    local tree merged
    if ! grep -q '^-[^-]' <<<"$pr_diff" && ! grep -q '^-[^-]' <<<"$main_diff" &&
       tree=$(git -C "$gitdir" merge-tree --write-tree "$3" origin/main 2>/dev/null) &&
       merged=$(git -C "$gitdir" show "${tree%%$'\n'*}:test/dune") &&
       dune_names_unique <<<"$merged"; then
      hit=$(printf '%s\n' "$hit" | grep -vx 'test/dune' || true)
    fi
  fi
  printf '%s\n' "$hit" | grep -c . || true
}

# R1 counts overlap from the run's createdAt, not a job's startedAt (later).
# Earliest createdAt among this head's pull_request runs that did not end
# skipped/cancelled; falls back to the rollup start only if that is earlier.
window_start() { # head started -> ISO time
  local t
  t=$("$GH" api "repos/$repo/actions/runs?head_sha=$1&event=pull_request&per_page=100" \
      --jq '[.workflow_runs[] | select(.conclusion != "cancelled" and .conclusion != "skipped") | .created_at] | min // ""') || return 1
  [ -n "$t" ] || return 1
  if [ -n "$2" ] && [[ "$2" < "$t" ]]; then echo "$2"; else echo "$t"; fi
}

# gh pr list --json files stops at 100 per PR; re-read the full list past that.
full_files() { # pr files -> comma list
  local n
  n=$(tr ',' '\n' <<<"$2" | grep -c . || true)
  if [ "$n" -lt 100 ]; then echo "$2"; return 0; fi
  "$GH" api --paginate "repos/$repo/pulls/$1/files?per_page=100" --jq '.[].filename' | paste -sd, -
  return "${PIPESTATUS[0]}"
}

heads=$(printf '%s\n' "$rows" | awk -F'\t' '{print $5"\t"$1}')
# Heads of the base=main PRs in one fetch, so the test/dune check can diff and
# merge-tree them. A failed fetch leaves those rows unknown:stale, not green.
refspecs=$(printf '%s\n' "$rows" | awk -F'\t' '$3=="main"{printf "+refs/pull/%s/head:refs/remotes/pr/%s\n", $1, $1}')
[ -z "$refspecs" ] || git -C "$gitdir" fetch -q origin $refspecs || echo "PR head fetch failed" >&2
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
  elif ! since=$(window_start "$head" "$started"); then stale="?"; waits="unknown:run"
  elif ! files=$(full_files "$num" "$files"); then stale="?"; waits="unknown:files"
  elif ! changed=$(git -C "$gitdir" log origin/main --since="$since" --name-only --format=); then stale="?"; waits="unknown:stale"
  elif ! stale=$(stale_files "$since" "$files" "$head" "$changed"); then stale="?"; waits="unknown:stale"
  elif [ "$stale" -gt 0 ]; then waits="stale:$stale"
  elif ! dependencies=$(stale_dependencies "$changed" "$files"); then waits="unknown:dependencies"
  elif [ -n "$dependencies" ]; then waits="dependency:$dependencies"
  elif ! v=$(verdict_for "$num" "$head"); then waits="unknown:verdict"
  else
    read -r vstate vrun vby <<<"$v"
    verdict="${vstate:--}"
    [ -z "${vby:-}" ] || [ "$vby" = - ] || verdict="$verdict by $vby"
    if [ "${vstate:-}" != PASS ]; then waits="review"
    elif ! ok=$(run_counts "$vrun" "$head"); then waits="unknown:run"
    elif [ "$ok" != yes ]; then waits="review"; verdict="PASS run $vrun not countable"
    else waits="merge"; fi
  fi
  if [ "$fmt" = md ]; then printf '| #%s | %s | %s | %s | %s | %s | %s |\n' "$num" "$author" "$waits" "$age" "$checks" "$stale" "$verdict"
  else printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$num" "$author" "$waits" "$age" "$checks" "$stale" "$verdict"; fi
done
echo "# main $main_sha" >&2
