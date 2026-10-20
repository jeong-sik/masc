# Live PR identity and release evidence shared by approval and merge.
# Ordinary stacks are reviewed from source; only release/v* heads require CI.
# Collection endpoints (statuses, workflow runs): --paginate runs --jq once per
# page, so the expression must be safe to repeat per page.
ci_gh_json() {
  "$GH" api --paginate "$1" --jq "$2"
}

# Single-object endpoints (one PR, one commit, one compare). GitHub pages the
# embedded file/commit lists of a large commit, and --paginate would then run
# --jq and print the scalar once per page (two newline-separated shas for the
# 183-file backport 159809c803cb). The scalars read here live on the first
# page, so ask for exactly one page.
ci_gh_object() {
  "$GH" api "$1" --jq "$2"
}

# Newest row of a paginated oldest-first collection: the last non-empty line
# across pages, not one line per page.
ci_gh_last_row() {
  local out
  out=$(ci_gh_json "$1" "$2") || return 1
  printf '%s\n' "$out" | awk '$0 != "" { row = $0 } END { if (row != "") print row }'
}

read_current_pr() {
  local row
  row=$(ci_gh_object "repos/$repo/pulls/$pr" '[.state, (.draft|tostring), .base.ref, .head.sha, (.merged|tostring), .head.ref, .user.login, .base.sha, ((.stack // null)|tojson)] | @tsv') || return 1
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
# merge-compile reports more: a successful four-executable build record for
# the exact merge head (top head for stacks, PR head for singles) plus
# freshness of that head against the merge target. Reviews certify source,
# not compilation, and restacked code predating a lint rule broke main
# twice in two days (#43137, #43146). Refusal is pending convention
# adoption; until then the guard reports the verdict and merges proceed on
# operator judgment (MASC_MERGE_COMPILE_ENFORCE=1 opts a single invocation
# into fail-close).
check_leader_selected_ci() {
  local rows status context target_url
  rows=$(ci_gh_last_row "repos/$repo/commits/$head/status" '[.statuses[] | select(.context == "leader-selected-ci") | [.state, .target_url, .description] | @tsv] | last // empty') || return 1
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

# Merge-compile verdict for the frozen scope: the record certifies the head
# tree, and only a head containing the merge-target tip merges to that same
# tree — so both the exact-head success record and behind_by == 0 against
# the target are required. $target is the frozen merge target
# (stack.base.ref for native stacks, base.ref for singles); its tip is read
# live so a target that moved mid-admission refuses instead of certifying a
# merge that no longer applies. Dispatch merge-compile.yml on the head
# right after review (fire-and-forget, never watch). A new head
# invalidates the record; docs-only heads settle instantly by input
# identity. Advisory until convention adoption: prints the verdict and
# returns 0 unless MASC_MERGE_COMPILE_ENFORCE=1, which fail-closes.
check_merge_compile() {
  local rows status target_url base_tip behind verdict
  base_tip=$(ci_gh_object "repos/$repo/commits/$target" '.sha') ||
    { echo "merge-compile check failed: cannot read the tip of $target" >&2; return 1; }
  [[ "$base_tip" =~ ^[0-9a-f]{40}$ ]] ||
    { echo "merge-compile check failed: tip of $target is not one 40-hex sha: '$base_tip'" >&2; return 1; }
  behind=$(ci_gh_object "repos/$repo/compare/${base_tip}...${selected_head}" '.behind_by') ||
    { echo "merge-compile check failed: cannot compare $selected_head with $target" >&2; return 1; }
  [[ "$behind" =~ ^[0-9]+$ ]] ||
    { echo "merge-compile check failed: behind_by is not a number: '$behind'" >&2; return 1; }
  if [ "$behind" != 0 ]; then
    verdict="head is $behind behind $target ($base_tip) — restack onto the current $target tip, dispatch merge-compile.yml on the new head, and merge after it succeeds"
    merge_compile_verdict refused "$verdict"
    return $?
  fi
  # Take the LAST merge-compile status: the API returns them oldest-first, so
  # `last` is the current verdict. A head whose verdict was overwritten keeps
  # the newest one, which is exactly what the merge decision must read.
  rows=$(ci_gh_last_row "repos/$repo/commits/$selected_head/status" '[.statuses[] | select(.context == "merge-compile") | [.state, .target_url] | @tsv] | last // empty') || return 1
  [ -n "$rows" ] || { merge_compile_verdict refused "no merge-compile record for exact head $selected_head — dispatch merge-compile.yml on this head (gh workflow run merge-compile.yml --ref main -f sha=$selected_head -f pr=$selected_pr) and merge after it succeeds"; return $?; }
  IFS=$'\t' read -r status target_url <<<"$rows"
  case "$status" in
    success)
      merge_compile_verdict pass "head $selected_head is fresh on $target with a merge-compile success record ($target_url)"
      return $?
      ;;
    pending)
      merge_compile_verdict hold "merge-compile is building $selected_head ($target_url) — merge after it succeeds"
      return $?
      ;;
    failure|error)
      merge_compile_verdict refused "merge-compile failed for $selected_head ($target_url) — repair the head and dispatch again"
      return $?
      ;;
    *)
      merge_compile_verdict refused "merge-compile has unknown state '$status'"
      return $?
      ;;
  esac
}

# Single choke point for merge-compile enforcement. Advisory (default)
# reports the would-be verdict on stderr and returns 0; enforcement
# fail-closes with the keeper-lane REFUSED/HOLD vocabulary.
merge_compile_verdict() {
  local level="$1" message="$2"
  if [ "${MASC_MERGE_COMPILE_ENFORCE:-0}" = 1 ]; then
    case "$level" in
      pass) return 0;;
      hold) echo "MERGE ON HOLD #$selected_pr: $message" >&2; return 2;;
      *) echo "REFUSED #$selected_pr: $message" >&2; return 2;;
    esac
  fi
  case "$level" in
    pass) echo "ADVISORY #$selected_pr: merge-compile PASS — $message" >&2;;
    hold) echo "ADVISORY #$selected_pr: merge-compile would HOLD — $message" >&2;;
    *) echo "ADVISORY #$selected_pr: merge-compile would REFUSE — $message" >&2;;
  esac
  return 0
}

check_current_ci() {
  read_current_pr || return $?
  check_leader_selected_ci || return $?
  release_run=""
  [ "$review_policy" = release ] || return 0
  # A failing gh read must not end as a bare exit 1: under set -e that silent
  # death becomes an unreadable evidence_read_failed one level up (run
  # 39404586810 died exactly here, without naming the failed call).
  local rows selected status conclusion sha branch path jobs required
  rows=$(ci_gh_json "repos/$repo/actions/runs?head_sha=$head&per_page=100" '.workflow_runs[] | select(.path == ".github/workflows/release-candidate.yml") | [.id, .status, (.conclusion // "none"), .head_sha, .head_branch, .path] | @tsv') || { echo "approve-guard: RC run read failed: repos/$repo/actions/runs?head_sha=$head" >&2; return 1; }
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
  jobs=$(ci_gh_json "repos/$repo/actions/runs/$release_run/jobs?per_page=100" '.jobs[] | [.name, .status, (.conclusion // "none"), .id] | @tsv') || { echo "approve-guard: RC jobs read failed: repos/$repo/actions/runs/$release_run/jobs" >&2; return 1; }
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
