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

check_current_ci() {
  read_current_pr || return $?
  release_run=""
  [ "$review_policy" = release ] || return 0
  local rows selected status conclusion sha branch path jobs required
  rows=$(ci_gh_json "repos/$repo/actions/runs?head_sha=$head&per_page=100" '.workflow_runs[] | select(.path == ".github/workflows/release-candidate.yml" or .path == ".github/workflows/release.yml") | [.id, .status, (.conclusion // "none"), .head_sha, .head_branch, .path] | @tsv') || return 1
  selected=$(printf '%s\n' "$rows" | awk -F '\t' -v sha="$head" -v branch="$pr_branch" '$4==sha && $5==branch' | sort -t "$(printf '\t')" -k1,1nr | head -n 1)
  IFS=$'\t' read -r release_run status conclusion sha branch path <<<"$selected"
  if [ -z "$release_run" ] || [ "$status" != completed ] || [ "$conclusion" != success ] ||
     { [ -n "${run:-}" ] && [ "$run" != "$release_run" ]; }; then
    echo "REFUSED #$pr: release requires the latest completed successful exact-head Release/RC run" >&2
    return 2
  fi
  case "$path" in
    .github/workflows/release-candidate.yml)
      required="compile / Release checks passed|behavior / test suite|installation / release|Record candidate verification";;
    .github/workflows/release.yml)
      required="verification / Release checks passed|behavior / test suite|release";;
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
    echo "REFUSED #$pr: full Release/RC verification jobs are missing or not successful" >&2
    return 2
  fi
  read_current_pr
}
