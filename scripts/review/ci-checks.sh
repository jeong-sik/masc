# Live PR identity and release evidence shared by approval and merge.
# Ordinary stacks are reviewed from source; only release/v* heads require CI.
ci_gh_json() {
  "$GH" api --paginate "$1" --jq "$2"
}

read_current_pr() {
  local row
  row=$(ci_gh_json "repos/$repo/pulls/$pr" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring), .head.ref, .user.login, .base.sha, ((.stack // null)|tojson)] | @tsv') || return 1
  IFS=$'\t' read -r pr_state pr_draft pr_base pr_current pr_branch_merged pr_branch pr_author pr_base_sha pr_stack <<<"$row"
  if [ "$pr_state" != open ] || [ "$pr_draft" != false ] || [ "$pr_branch_merged" != false ] ||
     [ "$pr_current" != "$head" ] || [ -z "$pr_base" ] || [ -z "$pr_branch" ] || [ -z "$pr_author" ]; then
    echo "REFUSED #$pr: require open, ready PR on exact head $head" >&2
    return 2
  fi
  if [ -n "${review_identity:-}" ] && [ "$review_identity" != "$row" ]; then
    echo "REFUSED #$pr: PR head, base or identity moved during review" >&2
    return 2
  fi
  review_identity="$row"
  review_policy=source
  case "$pr_branch" in release/v*) review_policy=release;; esac
}

# A leader-selected CI run in flight pins the member heads it verifies.
# The status lives on the member PR head commit, so it moves with the head
# and disappears from stale heads on its own. Missing status means no
# leader-selected run is currently pinning this head.
#
# merge-compile is stricter: every merge needs a successful four-executable
# build record for the exact merge head (top head for stacks, PR head for
# singles). Reviews certify source, not compilation, and restacked code
# predating a lint rule broke main twice in two days (#43137, #43146).
# Missing record means the merged result was never compiled — refuse.
check_leader_selected_ci() {
  local rows status context target_url
  rows=$(ci_gh_json "repos/$repo/commits/$head/status" '[.statuses[] | select(.context == "leader-selected-ci") | [.state, .target_url, .description] | @tsv] | last // empty') || return 1
  [ -n "$rows" ] || return 0
  IFS=$'\t' read -r status context target_url <<<"$rows"
  case "$status" in
    pending)
      echo "MERGE ON HOLD #$pr: leader-selected CI is in progress ($target_url) — wait for it to finish before merging" >&2
      return 2;;
    failure|error)
      echo "REFUSED #$pr: leader-selected CI failed ($target_url)" >&2
      return 2;;
    success)
      return 0;;
    *)
      echo "REFUSED #$pr: leader-selected CI has unknown state '$status'" >&2
      return 2;;
  esac
}

# Merge admission requires a successful merge-compile record for the exact
# merge head (top head for stacks, PR head for singles): the four operator
# executables built from these exact inputs. Unlike leader-selected CI, a
# missing record refuses — the merged result was never compiled. Dispatch
# merge-compile.yml on the head right after review (fire-and-forget, never
# watch); merge once this status reads success. A new head invalidates the
# record; docs-only heads settle instantly by input identity.
check_merge_compile() {
  local rows status target_url
  # Take the LAST merge-compile status: the API returns them oldest-first, so
  # `last` is the current verdict. A head whose verdict was overwritten keeps
  # the newest one, which is exactly what the merge decision must read.
  rows=$(ci_gh_json "repos/$repo/commits/$selected_head/status" '[.statuses[] | select(.context == "merge-compile") | [.state, .target_url] | @tsv] | last // empty') || return 1
  [ -n "$rows" ] || { echo "REFUSED #$selected_pr: no merge-compile record for exact head $selected_head — dispatch merge-compile.yml on this head (gh workflow run merge-compile.yml --ref main -f sha=$selected_head -f pr=$selected_pr) and merge after it succeeds" >&2; return 2; }
  IFS=$'\t' read -r status target_url <<<"$rows"
  case "$status" in
    success)
      return 0;;
    pending)
      echo "MERGE ON HOLD #$selected_pr: merge-compile is building $selected_head ($target_url) — merge after it succeeds" >&2
      return 2;;
    failure|error)
      echo "REFUSED #$selected_pr: merge-compile failed for $selected_head ($target_url) — repair the head and dispatch again" >&2
      return 2;;
    *)
      echo "REFUSED #$selected_pr: merge-compile has unknown state '$status'" >&2
      return 2;;
  esac
}

check_current_ci() {
  read_current_pr || return $?
  check_leader_selected_ci || return $?
  release_run=""
  [ "$review_policy" = release ] || return 0
  local rows selected status conclusion sha branch path jobs required
  rows=$(ci_gh_json "repos/$repo/actions/runs?head_sha=$head&per_page=100" '.workflow_runs[] | select(.path == ".github/workflows/release-candidate.yml") | [.id, .status, (.conclusion // "none"), .head_sha, .head_branch, .path] | @tsv') || return 1
  selected=$(printf '%s\n' "$rows" | awk -F '\t' -v sha="$head" -v branch="$pr_branch" '$4==sha && $5==branch' | sort -t "$(printf '\t')" -k1,1nr | head -n 1)
  IFS=$'\t' read -r release_run status conclusion sha branch path <<<"$selected"
  if [ -z "$release_run" ] || [ "$status" != completed ] || [ "$conclusion" != success ] ||
     { [ -n "${run:-}" ] && [ "$run" != "$release_run" ]; }; then
    echo "REFUSED #$pr: release requires the latest completed successful exact-head RC run" >&2
    return 2
  fi
  case "$path" in
    .github/workflows/release-candidate.yml)
      required="compile / Release checks passed|behavior / test suite|installation / release|Record candidate verification";;
    *) return 2;;
  esac
  jobs=$(ci_gh_json "repos/$repo/actions/runs/$release_run/jobs?per_page=100" '.jobs[] | [.name, .status, (.conclusion // "none"), .id] | @tsv') || return 1
  jobs=$(printf '%s\n' "$jobs" | sort -t "$(printf '\t')" -k1,1 -k4,4nr | awk -F '\t' 'NF && !seen[$1]++')
  # Reusable workflows deliberately skip publishing-only branches during an
  # RC. Require the full verification summaries, not every optional job.
  if ! printf '%s\n' "$jobs" | awk -F '\t' -v required="$required" '
    BEGIN {n=split(required,names,"[|]"); for(i=1;i<=n;i++) wanted[names[i]]=1}
    NF {
      if ($2!="completed" || ($3!="success" && $3!="skipped")) bad=1
      if ($1 in wanted && $2=="completed" && $3=="success") passed[$1]=1
    }
    END {for(name in wanted) if(!(name in passed)) bad=1; exit bad}'; then
    echo "REFUSED #$pr: full RC verification jobs are missing or not successful" >&2
    return 2
  fi
  read_current_pr
}
