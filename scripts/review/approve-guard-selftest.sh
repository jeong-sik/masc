#!/usr/bin/env bash
# Self-test for approve-guard.sh with a fake gh. No network.
# Each case builds fixtures, runs the guard, and checks exit code + a stderr/stdout needle
# + whether a POST happened.
# Native/Dune callers run API cases only. Lint explicitly adds workflow checks:
#   approve-guard-selftest.sh --workflow .github/workflows/pr-check.yml
set -u
workflow=""
if [ "$#" -ne 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != --workflow ]; then
    echo "usage: approve-guard-selftest.sh [--workflow FILE]" >&2
    exit 1
  fi
  workflow="$2"
  if [ ! -f "$workflow" ]; then
    echo "selftest: requested workflow file is missing: $workflow" >&2
    exit 1
  fi
fi
here="$(cd "$(dirname "$0")" && pwd)"
guard="$here/approve-guard.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/agtest.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The harness itself uses jq (fixtures, payload check); the GUARD must not.
JQ="$(command -v jq)" || { echo "selftest needs jq for fixtures" >&2; exit 1; }
export FAKE_JQ="$JQ"
# A PATH entry whose jq always fails: runs the guard as if the lane had no jq.
mkdir -p "$work/nojq"
printf '#!/bin/sh\necho "jq: not installed on this lane" >&2\nexit 127\n' >"$work/nojq/jq"
chmod +x "$work/nojq/jq"

cat >"$work/gh" <<'EOF'
#!/usr/bin/env bash
# fake gh: api [--paginate] [-X POST] <endpoint> [--jq F] [-f k=v] [-F k=@-]
# FAKE_FAIL=<glob>: endpoints matching it fail like a transport error.
d="$FAKE_DIR"; jqf="."; method=GET; ep=""; ev=""; cid=""; body_src=""; paged=0
shift # "api"
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) paged=1; shift ;;
    -X) method="$2"; shift 2 ;;
    --jq) jqf="$2"; shift 2 ;;
    --input) echo "fake gh: --input is not how the guard posts" >&2; exit 1 ;;
    -f|-F) case "$2" in
             merge_method=*|sha=*) : ;;
             event=*) ev="${2#event=}" ;;
             commit_id=*) cid="${2#commit_id=}" ;;
             body=@-) body_src=stdin ;;
             *) echo "fake gh: unexpected field $2" >&2; exit 1 ;;
           esac; shift 2 ;;
    *) ep="$1"; shift ;;
  esac
done
# A GET that reads only the first page would miss the newest reviews on a PR
# with more than 100 of them (API order is oldest first).
echo "$method $ep" >> "$d/api_reads"
if [ "$method" = GET ] && [ "$paged" = 0 ]; then
  case "$ep" in
    */commits/main) : ;; # The SHA does not need paginated commit files.
    *) echo "fake gh: GET $ep without --paginate" >&2; exit 1 ;;
  esac
fi
if [ -n "${FAKE_FAIL:-}" ]; then
  case "$ep" in $FAKE_FAIL) echo "HTTP 502: Bad Gateway (fake)" >&2; exit 1 ;; esac
fi
case "$ep" in
  */commits/main)
    n=$(cat "$d/main_reads" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$d/main_reads"
    if [ -f "$d/late_cr" ]; then
      "$FAKE_JQ" -n --arg h "$FAKE_HEAD" '[{id:999,state:"CHANGES_REQUESTED",commit_id:$h,user:{login:"pangyo-preachers"}}]' > "$d/reviews.json"
    fi
    if { [ -f "$d/late_hold" ] && [ "$n" -ge 3 ]; } || [ -f "$d/late_approval_hold" ]; then
      "$FAKE_JQ" -n --arg h "$FAKE_HEAD" '[{created_at:"2026-01-01T00:55:00Z",body:("verdict: HOLD head: "+$h+" run: 900 by: keeper")}]' > "$d/comments.json"
    fi
    printf '{"sha":"%s"}\n' "$FAKE_MAIN" | "$FAKE_JQ" -r "$jqf"
    if [ "${FAKE_PAGINATED_MAIN:-0}" = 1 ] && [ "$paged" = 1 ]; then
      printf '{"sha":"%s"}\n' "$FAKE_MAIN" | "$FAKE_JQ" -r "$jqf"
    fi
    exit ;;
  */files\?*) echo '[{"filename":"pr.ml"}]' | "$FAKE_JQ" -r "$jqf"; exit ;;
  */actions/runs/*/jobs*)
    rid="${ep#*/actions/runs/}"; rid="${rid%%/*}"
    if [ -f "$d/jobs-$rid.json" ]; then f="jobs-$rid"
    elif [ "$rid" = 900 ]; then f=prjobs
    elif [ -f "$d/jobs.json" ]; then f=jobs; else f=prjobs; fi ;;
  */actions/runs/[0-9]*)
    id="${ep##*/}"
    "$FAKE_JQ" --argjson id "$id" --arg h "$FAKE_HEAD" '
      .workflow_runs[] | select(.id==$id) |
      . + {head_sha:$h,head_branch:"pr",pull_requests:[{number:5}],created_at:"2026-01-01T00:30:00Z",event:"pull_request",path:".github/workflows/pr-check.yml"}' "$d/actions.json" | "$FAKE_JQ" -r "$jqf"; exit ;;
  */comments*) f=comments ;;
  */merge-async)
    [ "$method" = PUT ] || exit 1
    echo called > "$d/merged"
    echo '{"uuid":"fixture-merge"}'
    exit ;;
  */check-runs/*/annotations*) f=annotations ;;
  */check-runs*) f=checkruns ;;
  */actions/runs*) f=actions ;;
  user) f=user ;;
  */reviews/*)
    # A merge check reads the selected review itself, including later-page
    # reviews and mutations during the final CI read. Posted review 777 falls
    # back to the dedicated readback fixture used by the approval tests.
    pages=("$d/reviews.json")
    for page in "$d/reviews-page-2.json" "$d/reviews-page2.json"; do
      [ ! -f "$page" ] || pages+=("$page")
    done
    row=$("$FAKE_JQ" -s --argjson id "${ep##*/}" '[.[][] | select(.id==$id)] | first // empty' "${pages[@]}")
    if [ -n "$row" ]; then
      printf '%s\n' "$row" | "$FAKE_JQ" -r "$jqf"; exit
    fi
    f=reviewget ;;
  */reviews*) if [ "$method" = POST ]; then
                [ "$body_src" = stdin ] || { echo "fake gh: POST without body=@-" >&2; exit 1; }
                cat >"$d/posted.body"
                "$FAKE_JQ" -n --arg e "$ev" --arg c "$cid" --rawfile b "$d/posted.body" \
                  '{event:$e, commit_id:$c, body:$b}' >"$d/posted.json"
                f=postresp
              else f=reviews; fi ;;
  */pulls/*) f=pull ;;
  *) echo "fake gh: no fixture for $ep" >&2; exit 1 ;;
esac
[ -f "$d/$f.json" ] || { echo "fake gh: missing $f.json" >&2; exit 1; }
if [ "$f" = checkruns ] && [ -f "$d/after_checks_verdict" ] && [ "$(cat "$d/main_reads" 2>/dev/null || echo 0)" -ge "${FAKE_LATE_PR_AFTER_MAIN_READS:-4}" ]; then
  # All CI still succeeds; a reviewer posts only while the final check read is
  # in flight, after the guard's earlier verdict read has already accepted PASS.
  "$FAKE_JQ" -n --arg h "$FAKE_HEAD" --arg state "$(cat "$d/after_checks_verdict")" \
    '[{created_at:"2026-01-01T00:55:00Z",author_association:"COLLABORATOR",
       body:("verdict: "+$state+" head: "+$h+" run: 900 by: keeper")}]' > "$d/comments.json"
  touch "$d/verdict_arrived_during_checks"
fi
if [ "$f" = checkruns ] && [ -f "$d/after_checks_review" ] && [ ! -f "$d/review_arrived_during_checks" ] && [ "$(cat "$d/main_reads" 2>/dev/null || echo 0)" -ge "${FAKE_LATE_PR_AFTER_MAIN_READS:-4}" ]; then
  case "$(cat "$d/after_checks_review")" in
    new-cr)
      "$FAKE_JQ" --arg h "$FAKE_HEAD" '. + [{id:999,state:"CHANGES_REQUESTED",commit_id:$h,
        author_association:"COLLABORATOR",user:{login:"another-reviewer"}}]' "$d/reviews.json" > "$d/reviews.next.json" ;;
    new-own-cr)
      "$FAKE_JQ" --arg h "$FAKE_HEAD" '. + [{id:999,state:"CHANGES_REQUESTED",commit_id:$h,
        author_association:"COLLABORATOR",user:{login:"pangyo-preachers"},body:"Please fix this"}]' "$d/reviews.json" > "$d/reviews.next.json" ;;
    dismiss-approval)
      "$FAKE_JQ" 'map(if .id == 888 then .state = "DISMISSED" else . end)' \
        "$d/reviews.json" > "$d/reviews.next.json" ;;
    remove-footer)
      "$FAKE_JQ" 'map(if .id == 888 then .body |= split("\n")[0] else . end)' \
        "$d/reviews.json" > "$d/reviews.next.json" ;;
    *) echo "fake gh: unknown late review mutation" >&2; exit 1 ;;
  esac
  mv "$d/reviews.next.json" "$d/reviews.json"
  touch "$d/review_arrived_during_checks"
fi
if [ "$f" = checkruns ] && [ -f "$d/after_checks_pull.json" ] && [ "$(cat "$d/main_reads" 2>/dev/null || echo 0)" -ge "${FAKE_LATE_PR_AFTER_MAIN_READS:-4}" ]; then
  cp "$d/after_checks_pull.json" "$d/pull.json"
fi
if [ "$f" = pull ] && [ -f "$d/late_pull.json" ] && [ "$(cat "$d/main_reads" 2>/dev/null || echo 0)" -ge "${FAKE_LATE_PR_AFTER_MAIN_READS:-4}" ]; then
  # The last freshness PR read precedes its last main read. Inject only after
  # both have completed, so these cases exercise the final write-boundary read.
  "$FAKE_JQ" -r "$jqf" "$d/late_pull.json"
elif [ "$f" = actions ] && [ -f "$d/late_workflow" ] && [ "$(cat "$d/main_reads" 2>/dev/null || echo 0)" -ge "${FAKE_LATE_AFTER_MAIN_READS:-3}" ]; then
  # The first check read succeeded. Register a newer same-head run while the
  # merge guard is reading freshness, without changing the PR head or old run.
  status=$(cat "$d/late_workflow")
  "$FAKE_JQ" --arg status "$status" '.workflow_runs |= map(. + {event:(.event//"pull_request"),path:(.path//".github/workflows/pr-check.yml"),head_branch:(.head_branch//"pr"),pull_requests:(.pull_requests//[{number:5}])}) | .workflow_runs += [{workflow_id:1,run_number:11,
    name:"PR Check",status:$status,conclusion:(if $status=="queued" then null else "failure" end),
    id:901,event:"pull_request",path:".github/workflows/pr-check.yml",
    head_branch:"pr",pull_requests:[{number:5}]}]' "$d/$f.json" | "$FAKE_JQ" -r "$jqf"
elif [ "$f" = checkruns ] && [ -f "$d/late_check" ] && [ "$(cat "$d/main_reads" 2>/dev/null || echo 0)" -ge "${FAKE_LATE_AFTER_MAIN_READS:-3}" ]; then
  "$FAKE_JQ" '.check_runs += [{name:"lint suite",status:"completed",conclusion:"failure",id:99}]' "$d/$f.json" | "$FAKE_JQ" -r "$jqf"
elif [ "$f" = actions ]; then
  "$FAKE_JQ" '.workflow_runs |= map(. + {event:(.event//"pull_request"),path:(.path//".github/workflows/pr-check.yml"),head_branch:(.head_branch//"pr"),pull_requests:(.pull_requests//[{number:5}])})' "$d/$f.json" | "$FAKE_JQ" -r "$jqf"
# gh api --paginate runs --jq once per response page and concatenates outputs.
elif [ "$f" = reviews ] && [ -f "$d/reviews-page-2.json" ]; then
  "$FAKE_JQ" -r "$jqf" "$d/reviews.json"
  "$FAKE_JQ" -r "$jqf" "$d/reviews-page-2.json"
elif [ -f "$d/$f-page2.json" ]; then
  "$FAKE_JQ" -r "$jqf" "$d/$f.json" || exit 1
  "$FAKE_JQ" -r "$jqf" "$d/$f-page2.json"
else
  "$FAKE_JQ" -r "$jqf" "$d/$f.json"
fi
EOF
chmod +x "$work/gh"

# A real immutable graph backs freshness; API fixtures only name its objects.
git init -q -b main "$work/repo"
git -C "$work/repo" config core.hooksPath "$work/no-hooks"
git -C "$work/repo" config commit.gpgSign false
git -C "$work/repo" config user.name fixture
git -C "$work/repo" config user.email fixture@example.invalid
echo base > "$work/repo/base"
# Workflow policy belongs to the immutable candidate; later cases deliberately
# edit/delete these working files without changing the API-named commit.
mkdir -p "$work/repo/.github/workflows"
cat >"$work/repo/.github/workflows/pr-check.yml" <<'EOF'
name: PR check
on:
  pull_request:
  workflow_dispatch:
jobs:
  compare-tui:
    if: ${{ github.event_name == 'workflow_dispatch' && inputs.compare_tui }}
    runs-on: macos-14
    steps: []
  required-test:
    if: ${{ false }}
    runs-on: ubuntu-latest
    steps: []
EOF
cat >"$work/repo/.github/workflows/other.yml" <<'EOF'
name: Other
on:
  pull_request:
jobs:
  compare-tui:
    runs-on: ubuntu-latest
    steps: []
EOF
git -C "$work/repo" add .
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git -C "$work/repo" commit -qm base
export FAKE_MAIN="$(git -C "$work/repo" rev-parse HEAD)"
git -C "$work/repo" checkout -qb pr
echo changed > "$work/repo/pr.ml"
git -C "$work/repo" add .
GIT_AUTHOR_DATE=2026-01-01T00:10:00Z GIT_COMMITTER_DATE=2026-01-01T00:10:00Z git -C "$work/repo" commit -qm pr
H="$(git -C "$work/repo" rev-parse HEAD)"
export FAKE_HEAD="$H" GUARD_REPO_ROOT="$work/repo"
git init -q --bare "$work/remote.git"
git -C "$work/repo" remote add origin "$work/remote.git"
git -C "$work/repo" push -q origin main pr
H2=fedcba9876543210fedcba9876543210fedcba98
pass=0; fail=0

# An explicitly requested workflow must never turn into an implicit skip.
out="$(bash "$here/approve-guard-selftest.sh" --workflow "$work/missing.yml" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | grep -qF 'requested workflow file is missing'; then
  pass=$((pass+1)); echo 'ok   missing-requested-workflow-refuses'
else fail=$((fail+1)); echo 'FAIL missing-requested-workflow-refuses'; fi

setup() { # setup <casedir>: default happy fixtures
  local d="$1"; mkdir -p "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"changed_files\":1,\"user\":{\"login\":\"jeong-sik\"},\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"pr\"}}" >"$d/pull.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":11},{"name":"lint suite","status":"completed","conclusion":"success","id":12}]}' >"$d/checkruns.json"
  echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900}]}' >"$d/actions.json"
  "$JQ" -n '{jobs: ["lint suite", "dune build @check", "dune build --profile release @check", "dashboard typecheck", "TLA model check"] | map({name:.,status:"completed",conclusion:"success"})}' >"$d/prjobs.json"
  echo '{"login":"pangyo-preachers"}' >"$d/user.json"
  echo '[]' >"$d/reviews.json"
  echo '[]' >"$d/comments.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/postresp.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
  printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\nLGTM, file:line evidence\n' "$H" >"$d/body.md"
}

run_case() { # run_case <name> <want_rc> <needle> <want_post 0|1> <casedir> [guard args...]
  local name="$1" want="$2" needle="$3" wpost="$4" d="$5"; shift 5
  local out rc posted=0
  out="$(FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --git-dir "$work/repo" "$@" 2>&1)"; rc=$?
  [ -f "$d/posted.json" ] && posted=1
  local masked=0
  [ "$want" = 1 ] && printf '%s' "$out" | grep -qF -- "REFUSED" && masked=1
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qF -- "$needle" && [ "$posted" = "$wpost" ] && [ "$masked" = 0 ]; then
    pass=$((pass+1)); echo "ok   $name"
  else
    fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want posted=$posted want=$wpost masked=$masked)"; printf '%s\n' "$out" | sed 's/^/     /'
  fi
}


for required_name in "lint suite" "dune build @check" "dune build --profile release @check" "dashboard typecheck" "TLA model check"; do
  d="$work/missing-required-$required_name"; setup "$d"
  "$JQ" --arg name "$required_name" '.jobs |= map(select(.name != $name))' "$d/prjobs.json" > "$d/next.json"
  mv "$d/next.json" "$d/prjobs.json"
  run_case "missing-required-$required_name" 2 "required PR-check job '$required_name' missing" 0 "$d" --check --repo o/r --pr 5 --head "$H"
done

d="$work/happy"; setup "$d"
run_case happy 0 "APPROVED #5 head $H review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# Truncated/empty option values must finish without reaching even a GET. A
# subprocess deadline makes the historical shift-2 loop a deterministic failure.
d="$work/missing-values"; setup "$d"
if FAKE_DIR="$d" GUARD_GH="$work/gh" python3 - "$guard" "$d" <<'PY'
from pathlib import Path
import subprocess
import sys
guard, directory = sys.argv[1:]
for option in ("--run", "--git-dir", "--repo", "--pr", "--head", "--body", "--replace-own-cr"):
    for tail in ([option], [option, ""], [option, "--check"]):
        # File-backed stderr avoids buffering the broken parser's infinite
        # shift-error stream in memory while proving that it terminates.
        with open(Path(directory) / "option.stderr", "w+") as error:
            try:
                result = subprocess.run(["bash", guard, *tail], timeout=2,
                    stdout=subprocess.DEVNULL, stderr=error)
            except subprocess.TimeoutExpired:
                raise SystemExit(f"option parser did not terminate: {tail!r}")
            error.seek(0)
            if result.returncode != 1 or f"{option} requires a value" not in error.read():
                raise SystemExit(f"option parser did not reject: {tail!r}")
assert not list(Path(directory).glob("posted*"))
assert not (Path(directory) / "api_reads").exists()
PY
then pass=$((pass+1)); echo "ok   missing-option-values-terminate"
else fail=$((fail+1)); echo "FAIL missing-option-values-terminate"; fi
d="$work/happy-footer"; setup "$d"
FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --git-dir "$work/repo" --repo o/r --pr 5 --head "$H" --body "$d/body.md" >/dev/null 2>&1
if jq -e --arg h "$H" '.event=="APPROVE" and .commit_id==$h and (.body|contains("run")) and (.body|contains("approve-guard: head"))' "$d/posted.json" >/dev/null; then pass=$((pass+1)); echo "ok   posted-payload"; else fail=$((fail+1)); echo "FAIL posted-payload"; cat "$d/posted.json"; fi

d="$work/check"; setup "$d"
run_case check-mode-no-write 0 "WOULD APPROVE #5" 0 "$d" --check --repo o/r --pr 5 --head "$H"
# A commit response can paginate its files while repeating the same SHA.
d="$work/paginated-main"; setup "$d"
FAKE_PAGINATED_MAIN=1 run_case paginated-main-identity 0 "WOULD APPROVE #5" 0 "$d" --check --repo o/r --pr 5 --head "$H"
d="$work/sha41"; setup "$d"
run_case sha-41-chars 2 "40 lowercase hex" 0 "$d" --repo o/r --pr 5 --head "${H}0" --body "$d/body.md"
d="$work/emptybody"; setup "$d"; : >"$d/body.md"
run_case empty-body 2 "body file missing or empty" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/draft"; setup "$d"; jq '.draft=true' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case draft 2 "PR is Draft" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/moved"; setup "$d"; jq --arg h "$H2" '.head.sha=$h' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case head-moved 2 "head moved" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/base"; setup "$d"; jq '.base.ref="feat/x"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case base-not-main 2 "not main" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/merged"; setup "$d"; jq '.state="closed"|.merged=true' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case merged 2 "merged=true" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/pending"; setup "$d"; jq '.check_runs[1].status="in_progress"|.check_runs[1].conclusion=null' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case check-pending 2 "lint suite' is in_progress/none" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/failed"; setup "$d"; jq '.check_runs[0].conclusion="failure"' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case check-failed 2 "completed/failure" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/cancelled"; setup "$d"; jq '.check_runs[0].conclusion="cancelled"' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case check-cancelled 2 "completed/cancelled" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/checksuperseded"; setup "$d"; echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"skipped","id":11},{"name":"lint suite","status":"completed","conclusion":"skipped","id":12},{"name":"dune build @check","status":"completed","conclusion":"success","id":21},{"name":"lint suite","status":"completed","conclusion":"success","id":22}]}' >"$d/checkruns.json"
run_case check-superseded-skipped-ignored 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/checknewestfails"; setup "$d"; echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":11},{"name":"lint suite","status":"completed","conclusion":"success","id":12},{"name":"dune build @check","status":"completed","conclusion":"failure","id":21}]}' >"$d/checkruns.json"
run_case check-newest-run-failed 2 "check-run 21" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/nochecks"; setup "$d"; echo '{"check_runs":[]}' >"$d/checkruns.json"
run_case checks-empty 2 "empty is not green" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/wfqueued"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900},{"workflow_id":2,"run_number":3,"name":"Test","status":"queued","conclusion":null,"id":901}]}' >"$d/actions.json"
run_case workflow-queued 2 "run 901 is queued/none" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/wfsuperseded"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":11,"name":"PR Check","status":"completed","conclusion":"success","id":902},{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"cancelled","id":900}]}' >"$d/actions.json"
printf 'verdict: PASS head: %s run: 902 by: selftest-keeper\n' "$H" >"$d/body.md"
run_case workflow-superseded-run-ignored 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/wfnewestfails"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900},{"workflow_id":1,"run_number":11,"name":"PR Check","status":"completed","conclusion":"failure","id":902}]}' >"$d/actions.json"
run_case workflow-newest-run-failed 2 "run 902 is completed/failure" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# A review's commit_id can be retargeted by GitHub after a main merge.
# Only the immutable verdict and final guard footer identify what was reviewed.
approved_review() { # id commit_id footer_head verdict_head
  local id="$1" commit="$2" footer="$3" verdict="$4" tick
  tick="$(printf '\x60')"
  "$JQ" -n --argjson id "$id" --arg commit "$commit" \
    --arg body "verdict: PASS head: $verdict run: 900 by: selftest-keeper

---
approve-guard: head $tick$footer$tick · 2 check-runs completed+success" \
    '[{id:$id,user:{login:"pangyo-preachers"},state:"APPROVED",commit_id:$commit,body:$body,author_association:"COLLABORATOR"}]'
}
d="$work/dup"; setup "$d"; approved_review 42 "$H" "$H" "$H" >"$d/reviews.json"
run_case already-approved 0 "already APPROVED" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dupold"; setup "$d"; approved_review 42 "$H2" "$H2" "$H2" >"$d/reviews.json"
run_case approved-older-head-still-posts 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dup-retargeted"; setup "$d"; approved_review 42 "$H" "$H2" "$H2" >"$d/reviews.json"
run_case retargeted-commit-would-approve 0 "WOULD APPROVE #5" 0 "$d" --check --repo o/r --pr 5 --head "$H"
run_case retargeted-commit-posts 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dup-old-commit"; setup "$d"; approved_review 42 "$H2" "$H" "$H" >"$d/reviews.json"
run_case footer-head-deduplicates 0 "already APPROVED" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dup-no-footer"; setup "$d"; approved_review 42 "$H" "$H" "$H" | "$JQ" '.[0].body |= split("\n")[0]' >"$d/reviews.json"
run_case missing-footer-still-posts 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dup-old-verdict"; setup "$d"; approved_review 42 "$H" "$H" "$H2" >"$d/reviews.json"
run_case older-verdict-still-posts 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

# Merge approval counting uses the same immutable body binding. A moved
# commit_id must not make an older approval count for a new head.
d="$work/merge-valid"; setup "$d"; "$JQ" '.user.login="jeong-sik"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H2" "$H" "$H" >"$d/reviews.json"; "$JQ" '.[0]' "$d/reviews.json" >"$d/reviewget.json"
run_case merge-footer-head-counts 0 "MERGE-CHECK PASS #5 head $H approvals: 42" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
d="$work/merge-retargeted"; setup "$d"; "$JQ" '.user.login="jeong-sik"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H" "$H2" "$H2" >"$d/reviews.json"; "$JQ" '.[0]' "$d/reviews.json" >"$d/reviewget.json"
run_case merge-retargeted-commit-refuses 2 "no non-author APPROVED review has this head" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
d="$work/merge-no-footer"; setup "$d"; "$JQ" '.user.login="jeong-sik"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H" "$H" "$H" | "$JQ" '.[0].body |= split("\n")[0]' >"$d/reviews.json"; "$JQ" '.[0]' "$d/reviews.json" >"$d/reviewget.json"
run_case merge-missing-footer-refuses 2 "no non-author APPROVED review has this head" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
d="$work/merge-author"; setup "$d"; "$JQ" '.user.login="pangyo-preachers"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H" "$H" "$H" >"$d/reviews.json"; "$JQ" '.[0]' "$d/reviews.json" >"$d/reviewget.json"
run_case merge-author-approval-refuses 2 "no non-author APPROVED review has this head" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
d="$work/merge-later-cr"; setup "$d"; "$JQ" '.user.login="jeong-sik"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H" "$H" "$H" | "$JQ" '. + [{id:43,user:{login:"pangyo-preachers"},state:"CHANGES_REQUESTED",commit_id:$h}]' --arg h "$H" >"$d/reviews.json"
run_case merge-later-cr-refuses 2 "open CHANGES_REQUESTED from pangyo-preachers (review 43) takes precedence" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
d="$work/merge-page2-cr"; setup "$d"; "$JQ" '.user.login="jeong-sik"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H" "$H" "$H" | "$JQ" --arg h "$H" '. + [range(43;142) | {id:., user:{login:"spectator"}, state:"COMMENTED", commit_id:$h}]' >"$d/reviews.json"
"$JQ" -n --arg h "$H" '[{id:142,user:{login:"pangyo-preachers"},state:"CHANGES_REQUESTED",commit_id:$h}]' >"$d/reviews-page2.json"
run_case merge-page2-cr-refuses 2 "open CHANGES_REQUESTED from pangyo-preachers (review 142) takes precedence" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
d="$work/merge-cross-cr"; setup "$d"; "$JQ" '.user.login="jeong-sik"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
approved_review 42 "$H" "$H" "$H" | "$JQ" '.[0].user.login="reviewer-a" | . + [{id:43,user:{login:"reviewer-b"},state:"CHANGES_REQUESTED",commit_id:$h}]' --arg h "$H" >"$d/reviews.json"; "$JQ" '.[0]' "$d/reviews.json" >"$d/reviewget.json"
run_case merge-cross-user-cr-refuses 2 "open CHANGES_REQUESTED from reviewer-b (review 43) takes precedence" 0 "$d" --merge-check --repo o/r --pr 5 --head "$H"
# ---- open change requests (leader, #38810): another account's CR refuses ----
rv() { echo "{\"id\":$1,\"user\":{\"login\":\"$2\"},\"state\":\"$3\",\"commit_id\":\"$H2\"}"; }
d="$work/cr-other"; setup "$d"; echo "[$(rv 50 jeong-sik CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-other-account-refuses 2 "open CHANGES_REQUESTED from jeong-sik (review 50)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
run_case cr-other-account-refuses-check 2 "open CHANGES_REQUESTED from jeong-sik" 0 "$d" --check --repo o/r --pr 5 --head "$H"
d="$work/cr-comment"; setup "$d"; echo "[$(rv 50 jeong-sik CHANGES_REQUESTED),$(rv 60 jeong-sik COMMENTED)]" >"$d/reviews.json"
run_case cr-not-lifted-by-later-comment 2 "review 50" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/cr-lifted"; setup "$d"; echo "[$(rv 60 jeong-sik APPROVED),$(rv 50 jeong-sik CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-lifted-by-later-approve 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/cr-dismissed"; setup "$d"; echo "[$(rv 50 jeong-sik DISMISSED)]" >"$d/reviews.json"
run_case cr-dismissed-does-not-block 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# ---- this account's own CR (operator P2 on #38928): replaced only when named ----
d="$work/cr-own"; setup "$d"; echo "[$(rv 50 pangyo-preachers CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-own-refuses-unless-named 2 "pass --replace-own-cr 50" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
run_case cr-own-refuses-unless-named-check 2 "pass --replace-own-cr 50" 0 "$d" --check --repo o/r --pr 5 --head "$H"
d="$work/cr-own-named"; setup "$d"; echo "[$(rv 50 pangyo-preachers CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-own-replaced-when-named 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md" --replace-own-cr 50
if jq -e '.body|endswith(" · replaces own CHANGES_REQUESTED 50")' "$d/posted.json" >/dev/null 2>&1; then pass=$((pass+1)); echo "ok   cr-own-replaced-footer"; else fail=$((fail+1)); echo "FAIL cr-own-replaced-footer"; cat "$d/posted.json" 2>/dev/null; fi
d="$work/cr-own-wrong-id"; setup "$d"; echo "[$(rv 50 pangyo-preachers CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-own-named-wrong-id 2 "--replace-own-cr 51 does not name" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md" --replace-own-cr 51
d="$work/cr-own-stale-flag"; setup "$d"; echo "[$(rv 60 pangyo-preachers APPROVED),$(rv 50 pangyo-preachers CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-own-named-but-already-lifted 2 "--replace-own-cr 50 does not name" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md" --replace-own-cr 50
d="$work/cr-own-plus-other"; setup "$d"; echo "[$(rv 50 pangyo-preachers CHANGES_REQUESTED),$(rv 52 jeong-sik CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-own-named-other-still-refuses 2 "from jeong-sik (review 52)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md" --replace-own-cr 50
d="$work/cr-flag-junk"; setup "$d"
run_case replace-own-cr-not-digits 2 "must be a review id" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md" --replace-own-cr 5306112777x
# ---- verdict line (#38975, 2026-09-26): the body's first line is the PASS the merge relies on ----
# review 5325206074 carried `head: $(gh api ...)` from a quoted heredoc; the
# APPROVE landed on the right commit, so only the body shows the missing head.
d="$work/vl-unexpanded"; setup "$d"; printf 'verdict: PASS head: $(gh api repos/o/r/pulls/5 --jq .head.sha) run: 900 by: selftest-keeper\n' >"$d/body.md"
run_case verdict-unexpanded-substitution 2 "not a literal verdict line" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-missing"; setup "$d"; printf 'LGTM, file:line evidence\n' >"$d/body.md"
run_case verdict-line-missing 2 "not a literal verdict line" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-second-line"; setup "$d"; printf 'Looks good.\nverdict: PASS head: %s run: 900 by: selftest-keeper\n' "$H" >"$d/body.md"
run_case verdict-line-not-first 2 "not a literal verdict line" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-fail"; setup "$d"; printf 'verdict: FAIL head: %s run: 900 by: selftest-keeper\n' "$H" >"$d/body.md"
run_case verdict-fail-is-not-approvable 2 "not a literal verdict line" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-head"; setup "$d"; printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\n' "$H2" >"$d/body.md"
run_case verdict-head-not-this-head 2 "verdict line head $H2 is not --head $H" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-run"; setup "$d"; printf 'verdict: PASS head: %s run: 123 by: selftest-keeper\n' "$H" >"$d/body.md"
run_case verdict-run-not-on-head 2 "verdict line run 123 is not a workflow run on $H" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-by"; setup "$d"; printf 'verdict: PASS head: %s run: 900 by: pangyo-preachers\n' "$H" >"$d/body.md"
run_case verdict-by-is-account-login 2 "by: is the account login 'pangyo-preachers'" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/vl-crlf"; setup "$d"; printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\r\nLGTM\r\n' "$H" >"$d/body.md"
run_case verdict-line-crlf-accepted 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/readback"; setup "$d"; echo "{\"id\":777,\"state\":\"COMMENTED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
run_case readback-mismatch 1 "reads back as COMMENTED" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/multi"; setup "$d"; jq '.draft=true|.base.ref="dev"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case reports-all-reasons 2 "not main" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

# ---- Draft -> Ready: which run is "newest" (#39046, #39049, 2026-09-25) ----
# A PR opened as Draft and marked Ready carries two suites on one SHA. On
# #39046 the Draft-time skipped check-run of 'dune build @check' got id
# 108051996594, higher than the Ready-time success 108051995088, although its
# suite (97836272095) is older than the success suite (97836300496). Check-run
# ids do not follow suite order; the suite id does.
d="$work/draftsuite"; setup "$d"; echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"skipped","id":30,"check_suite":{"id":1}},{"name":"lint suite","status":"completed","conclusion":"skipped","id":31,"check_suite":{"id":1}},{"name":"dune build @check","status":"completed","conclusion":"success","id":21,"check_suite":{"id":2}},{"name":"lint suite","status":"completed","conclusion":"success","id":22,"check_suite":{"id":2}}]}' >"$d/checkruns.json"
run_case check-draft-suite-with-higher-id-ignored 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# The same ordering must still refuse when the NEWER suite failed but its
# check-run id is the lower one; an id-order guard approves this.
d="$work/newsuitefails"; setup "$d"; echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":30,"check_suite":{"id":1}},{"name":"lint suite","status":"completed","conclusion":"success","id":31,"check_suite":{"id":1}},{"name":"dune build @check","status":"completed","conclusion":"failure","id":21,"check_suite":{"id":2}},{"name":"lint suite","status":"completed","conclusion":"success","id":22,"check_suite":{"id":2}}]}' >"$d/checkruns.json"
run_case check-newer-suite-failed-with-lower-id 2 "check-run 21" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# #39049: two PR check runs of one workflow started in the same second; the
# concurrency group cancelled the higher-numbered one and the other passed.
# The twin owned the newest check suite, and every check-run in it was skipped
# (suite 97837801954 on #39049); those rows must not count either.
d="$work/wfcancelledtwin"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":14708,"name":"PR Check","status":"completed","conclusion":"success","id":900,"check_suite_id":2},{"workflow_id":1,"run_number":14709,"name":"PR Check","status":"completed","conclusion":"cancelled","id":901,"check_suite_id":3}]}' >"$d/actions.json"
echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":40,"check_suite":{"id":2}},{"name":"lint suite","status":"completed","conclusion":"success","id":41,"check_suite":{"id":2}},{"name":"dune build @check","status":"completed","conclusion":"skipped","id":20,"check_suite":{"id":3}},{"name":"lint suite","status":"completed","conclusion":"skipped","id":21,"check_suite":{"id":3}}]}' >"$d/checkruns.json"
run_case workflow-cancelled-twin-ignored 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# Cancelled only counts as noise when a run of that workflow reached a verdict.
d="$work/wfallcancelled"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"cancelled","id":900},{"workflow_id":1,"run_number":11,"name":"PR Check","status":"completed","conclusion":"cancelled","id":902}]}' >"$d/actions.json"
run_case workflow-all-cancelled-refuses 2 "run 902 is completed/cancelled" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# A newer run still in progress outranks an older finished one.
d="$work/wfnewerrunning"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900},{"workflow_id":1,"run_number":11,"name":"PR Check","status":"in_progress","conclusion":null,"id":902}]}' >"$d/actions.json"
run_case workflow-newer-run-in-progress-refuses 2 "run 902 is in_progress/none" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"


# ---- Late Draft delivery must neither cancel nor shadow Ready evidence ----
race_setup() {
  setup "$1"
  "$JQ" -n --arg h "$H" '{workflow_runs:[
    {workflow_id:1,run_number:10,name:"PR check",status:"completed",conclusion:"success",id:900,check_suite_id:55,event:"pull_request",path:".github/workflows/pr-check.yml",head_sha:$h},
    {workflow_id:1,run_number:11,name:"PR check",status:"completed",conclusion:"success",id:901,check_suite_id:66,event:"pull_request",path:".github/workflows/pr-check.yml",head_sha:$h}]}' >"$1/actions.json" || {
    echo "selftest: fixture jq failed" >&2
    exit 1
  }
  # Keep the captured job names/statuses, rebinding only IDs/head for the
  # synthetic race variants below. A separate case replays the unmodified jobs.
  "$JQ" --arg h "$H" '.jobs |= (to_entries | map(.value + {id:(200+.key),run_id:901,head_sha:$h}))' \
    "$here/fixtures/pr-check-draft-jobs-39834.json" >"$1/jobs-901.json" || {
    echo "selftest: fixture jq failed" >&2
    exit 1
  }
  "$JQ" '{check_runs:((
    ["TLA model check","lint suite","dune build @check","dune build --profile release @check","dashboard typecheck","PR required success"] | to_entries | map({name:.value,status:"completed",conclusion:"success",id:(100+.key),check_suite:{id:55}})) + [.jobs[] | {name,status,conclusion,id,check_suite:{id:66}}])}' "$1/jobs-901.json" >"$1/checkruns.json" || {
    echo "selftest: fixture jq failed" >&2
    exit 1
  }
}
mutate() { "$JQ" "$2" "$1" >"$1.tmp" && mv "$1.tmp" "$1"; }
race_case() { run_case "$1" "$2" "$3" 0 "$d" --check --repo o/r --pr 5 --head "$H"; }
d="$work/race-late"; race_setup "$d"
race_case late-draft-does-not-shadow-ready 0 'WOULD APPROVE'
d="$work/race-early"; race_setup "$d"; mutate "$d/actions.json" '.workflow_runs[1].run_number=9'
race_case early-draft-does-not-shadow-ready 0 'WOULD APPROVE'
d="$work/race-skipped-run"; race_setup "$d"; mutate "$d/actions.json" '.workflow_runs[1].conclusion="skipped"'
race_case complete-skipped-draft-run 0 'WOULD APPROVE'
d="$work/race-current-draft"; race_setup "$d"; mutate "$d/pull.json" '.draft=true'
race_case current-draft-still-refused 2 'PR is Draft'
d="$work/race-cancelled"; race_setup "$d"; mutate "$d/actions.json" '.workflow_runs[1].conclusion="cancelled"'
mutate "$d/checkruns.json" '.check_runs |= map(select(.check_suite.id != 66 or .id == 200))'
race_case cancelled-incomplete-draft-loses-to-ready 0 'WOULD APPROVE'
d="$work/race-only-cancelled"; race_setup "$d"; mutate "$d/actions.json" '.workflow_runs |= map(select(.id == 901) | .conclusion="cancelled")'
race_case cancelled-draft-only-refused 2 'invalid Draft snapshot'
for fault in missing duplicate extra success pending head run id name; do
  d="$work/race-jobs-$fault"; race_setup "$d"
  case "$fault" in
    missing) change='.jobs |= .[0:5]' ;;
    duplicate) change='.jobs[5] = .jobs[0]' ;;
    extra) change='.jobs += [(.jobs[0] | .id=999 | .name="unexpected")]' ;;
    success) change='.jobs[0].conclusion="success"' ;;
    pending) change='.jobs[0].status="queued"' ;;
    head) change='.jobs[0].head_sha="wrong"' ;;
    run) change='.jobs[0].run_id=999' ;;
    id) change='.jobs[0].id=999' ;;
    name) change='.jobs[0].name |= sub("== true"; "== false")' ;;
  esac
  mutate "$d/jobs-901.json" "$change"
  race_case "draft-jobs-$fault-refused" 2 'Draft snapshot'
done
for fault in path event head suite missing-meta all-success; do
  d="$work/race-binding-$fault"; race_setup "$d"
  case "$fault" in
    path) mutate "$d/actions.json" '.workflow_runs[1].path=".github/workflows/other.yml"' ;;
    event) mutate "$d/actions.json" '.workflow_runs[1].event="workflow_dispatch"' ;;
    head) mutate "$d/actions.json" '.workflow_runs[1].head_sha="wrong"' ;;
    suite) mutate "$d/actions.json" '.workflow_runs[1].check_suite_id=0' ;;
    missing-meta) mutate "$d/actions.json" '.workflow_runs |= .[0:1]' ;;
    all-success)
      mutate "$d/jobs-901.json" '.jobs[].conclusion="success"'
      mutate "$d/checkruns.json" '.check_runs[].conclusion="success"' ;;
  esac
  race_case "draft-binding-$fault-refused" 2 'invalid Draft snapshot'
done
for fault in fail pending missing split other-workflow; do
  d="$work/race-ready-$fault"; race_setup "$d"
  case "$fault" in
    fail) mutate "$d/checkruns.json" '.check_runs[0].conclusion="failure"' ;;
    pending) mutate "$d/actions.json" '.workflow_runs += [(.workflow_runs[0] | .id=902 | .run_number=12 | .check_suite_id=77 | .status="in_progress" | .conclusion=null)]' ;;
    missing) mutate "$d/checkruns.json" '.check_runs |= map(select(.id != 105))' ;;
    split) mutate "$d/checkruns.json" '.check_runs[0].check_suite.id=77' ;;
    other-workflow) mutate "$d/actions.json" '.workflow_runs[0].workflow_id=2 | .workflow_runs[0].path=".github/workflows/other.yml"' ;;
  esac
  race_case "ready-$fault-not-hidden-by-draft" 2 'requires the complete successful check set'
done
# A ROLL scope is a seventh exact job, with the same Draft/Ready isolation.
scope_race_setup() {
  race_setup "$1"
  "$JQ" --arg h "$H" '.jobs += [{
    name:"github.event.pull_request.draft == true && '\''Draft snapshot / PR inspection scope'\'' || '\''PR inspection scope'\''",
    status:"completed",conclusion:"skipped",id:299,run_id:901,head_sha:$h
  }]' "$1/jobs-901.json" >"$1/p" && mv "$1/p" "$1/jobs-901.json"
  "$JQ" --slurpfile jobs "$1/jobs-901.json" '.check_runs |=
    (map(select(.check_suite.id==55)) +
    [{name:"PR inspection scope",status:"completed",conclusion:"success",id:199,check_suite:{id:55}}] +
    [$jobs[0].jobs[] | {name,status,conclusion,id,check_suite:{id:66}}])' "$1/checkruns.json" >"$1/p" && mv "$1/p" "$1/checkruns.json"
}
d="$work/race-scope"; scope_race_setup "$d"
race_case exact-scoped-draft-with-ready 0 'WOULD APPROVE'
for fault in missing failure skipped pending split unexpected; do
  d="$work/race-scope-ready-$fault"; scope_race_setup "$d"
  case "$fault" in
    missing) change='.check_runs |= map(select(.id!=199))' ;;
    failure|skipped) change='.check_runs[] |= if .id==199 then .conclusion="'$fault'" else . end' ;;
    pending) change='.check_runs[] |= if .id==199 then .status="queued" else . end' ;;
    split) change='.check_runs[] |= if .id==199 then .check_suite.id=77 else . end' ;;
    unexpected) change='.check_runs[] |= if .id==199 then .name="unexpected" else . end' ;;
  esac
  mutate "$d/checkruns.json" "$change"
  race_case "scope-ready-$fault-refused" 2 'requires the complete successful check set'
done
for fault in duplicate success pending wrong-name wrong-head; do
  d="$work/race-scope-draft-$fault"; scope_race_setup "$d"
  case "$fault" in
    duplicate) change='.jobs += [.jobs[-1] | .id=399]' ;;
    success) change='.jobs[-1].conclusion="success"' ;;
    pending) change='.jobs[-1].status="queued"' ;;
    wrong-name) change='.jobs[-1].name="PR inspection scope"' ;;
    wrong-head) change='.jobs[-1].head_sha="wrong"' ;;
  esac
  mutate "$d/jobs-901.json" "$change"
  race_case "scope-draft-$fault-refused" 2 'invalid Draft snapshot'
done
# Pagination must be aggregated before checking six: three + three is valid;
# six + an extra seventh row is invalid, including a duplicate name.
for page in split extra duplicate; do
  d="$work/race-page-$page"; race_setup "$d"
  case "$page" in
    split)
      "$JQ" '{jobs:.jobs[3:]}' "$d/jobs-901.json" >"$d/jobs-901-page2.json"
      mutate "$d/jobs-901.json" '.jobs |= .[0:3]'
      race_case paginated-draft-six-accepted 0 'WOULD APPROVE' ;;
    extra|duplicate)
      "$JQ" '{jobs:[.jobs[0]]}' "$d/jobs-901.json" >"$d/jobs-901-page2.json"
      if [ "$page" = extra ]; then mutate "$d/jobs-901-page2.json" '.jobs[0].name="extra"'; fi
      race_case "paginated-draft-$page-refused" 2 'invalid Draft snapshot' ;;
  esac
done
# Ready check evidence follows the latest check row per name in the SAME suite,
# including reruns; it must not synthesize a green set across different suites.
d="$work/race-rerun"; race_setup "$d"
mutate "$d/checkruns.json" '.check_runs += [(.check_runs[0] | .id=99 | .conclusion="failure")]'
race_case earlier-failed-check-in-same-ready-suite 0 'WOULD APPROVE'
d="$work/race-rerun-failed"; race_setup "$d"
mutate "$d/checkruns.json" '.check_runs += [(.check_runs[0] | .id=999 | .conclusion="failure")]'
race_case latest-failed-check-in-ready-suite 2 'requires the complete successful check set'
d="$work/race-transport"; race_setup "$d"
FAKE_FAIL='*/jobs*' race_case draft-jobs-transport-is-infra-error 1 'gh api repos/o/r/actions/runs/901/jobs'
d="$work/race-nojq"; race_setup "$d"
PATH="$work/nojq:$PATH" race_case draft-selection-needs-no-standalone-jq 0 'WOULD APPROVE'


# Captured API job names, IDs, run IDs and statuses; only head is rebound
# to the fixture Git commit that the freshness gate can inspect. The green
# Ready run is synthetic, not live qualification proof.
d="$work/race-captured"; race_setup "$d"
captured="$here/fixtures/pr-check-draft-jobs-39834.json"
captured_head="$H"
captured_run=$("$JQ" -r '.jobs[0].run_id' "$captured")
"$JQ" --arg h "$captured_head" '.jobs[].head_sha=$h' "$captured" >"$d/jobs-$captured_run.json"
"$JQ" --arg h "$captured_head" '.head.sha=$h' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
"$JQ" --arg h "$captured_head" --argjson run "$captured_run" '.workflow_runs[].head_sha=$h | .workflow_runs[1].id=$run | .workflow_runs[1].conclusion="skipped"' "$d/actions.json" >"$d/p" && mv "$d/p" "$d/actions.json"
"$JQ" --slurpfile captured "$captured" '.check_runs |= (map(select(.check_suite.id==55)) + [$captured[0].jobs[] | {name,status,conclusion,id,check_suite:{id:66}}])' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case captured-api-draft-with-synthetic-ready 0 'WOULD APPROVE' 0 "$d" --check --repo o/r --pr 5 --head "$captured_head"
mutate "$d/actions.json" '.workflow_runs |= .[1:]'
run_case captured-api-draft-alone-not-green 2 'requires the complete successful check set' 0 "$d" --check --repo o/r --pr 5 --head "$captured_head"
# Even an older noncancelled malformed expression must refuse before generic
# lost-suite filtering, including all-success markers and a changed else arm.
for expression_fault in else-arm condition all-success wrapped wrapped-success; do
  d="$work/race-expression-$expression_fault"; race_setup "$d"
  mutate "$d/actions.json" '.workflow_runs[1].run_number=9'
  case "$expression_fault" in
    else-arm) change='.jobs[0].name += " tampered"' ;;
    condition) change='.jobs[0].name |= sub("== true";"== false")' ;;
    all-success) change='.jobs[].conclusion="success"' ;;
    wrapped) change='.jobs[].name |= ("${{ " + . + " }}")' ;;
    wrapped-success) change='.jobs[].name |= ("${{ " + . + " }}") | .jobs[].conclusion="success"' ;;
  esac
  mutate "$d/jobs-901.json" "$change"
  "$JQ" --slurpfile jobs "$d/jobs-901.json" '.check_runs |= (map(select(.check_suite.id==55)) + [$jobs[0].jobs[] | {name,status,conclusion,id,check_suite:{id:66}}])' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
  race_case "older-malformed-expression-$expression_fault" 2 'invalid Draft snapshot'
done

# ---- dispatch-only skipped job (#38873): workflow file decides, never the row alone ----
# A job whose `if:` requires workflow_dispatch is skipped in every pull_request
# run by design; the newest pull_request suite may still be green. The guard
# reads the condition from the API-named commit in the fixture Git repository.
mkcase() { # mkcase <dir> <suite-event> <suite-path>
  local d="$1" ev="$2" p="$3"; mkdir -p "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"changed_files\":1,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"pr\"}}" >"$d/pull.json"
  echo "{\"workflow_runs\":[{\"workflow_id\":1,\"run_number\":10,\"name\":\"PR check\",\"status\":\"completed\",\"conclusion\":\"success\",\"id\":900,\"check_suite_id\":55,\"event\":\"$ev\",\"path\":\"$p\"}]}" >"$d/actions.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":60,"check_suite":{"id":55}},{"name":"compare-tui","status":"completed","conclusion":"skipped","id":61,"check_suite":{"id":55}}]}' >"$d/checkruns.json"
  "$JQ" -n '{jobs: ["lint suite", "dune build @check", "dune build --profile release @check", "dashboard typecheck", "TLA model check"] | map({name:.,status:"completed",conclusion:"success"})}' >"$d/prjobs.json"
  echo '{"login":"pangyo-preachers"}' >"$d/user.json"
  echo '[]' >"$d/reviews.json"
  echo '[]' >"$d/comments.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/postresp.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
  printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\nLGTM, file:line evidence\n' "$H" >"$d/body.md"
}
d="$work/dispatchskip"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
out="$(FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --git-dir "$work/repo" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$d/posted.json" ] && "$JQ" -e '.body|endswith(" · dispatch-only skipped: compare-tui")' "$d/posted.json" >/dev/null; then pass=$((pass+1)); echo "ok   dispatch-only-job-skipped-approves"; else fail=$((fail+1)); echo "FAIL dispatch-only-job-skipped-approves (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; cat "$d/posted.json" 2>/dev/null; fi
d="$work/requiredskip"; mkcase "$d" pull_request ".github/workflows/other.yml"
run_case required-job-skipped-refuses 2 "check 'compare-tui' is completed/skipped (check-run 61)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dispatchskip-dispatch-suite"; mkcase "$d" workflow_dispatch ".github/workflows/pr-check.yml"
run_case dispatch-suite-skipped-still-refuses 2 "check 'compare-tui' is completed/skipped (check-run 61)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

# A stale/dirty checkout says the opposite of the candidate in both directions.
# It must neither exempt a required skipped job nor veto a dispatch-only one.
cp "$work/repo/.github/workflows/pr-check.yml" "$work/original-workflow"
cat >"$work/repo/.github/workflows/pr-check.yml" <<'EOF'
jobs:
  required-test:
    if: ${{ github.event_name == 'workflow_dispatch' }}
  compare-tui:
    if: ${{ false }}
EOF
for mode in write check; do
  set --; [ "$mode" = check ] && set -- --check
  d="$work/head-required-checkout-dispatch-$mode"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
  "$JQ" '.check_runs[1].name="required-test"' "$d/checkruns.json" > "$d/p"
  mv "$d/p" "$d/checkruns.json"
  run_case "head-required-ignores-checkout-exemption-$mode" 2 "check 'required-test' is completed/skipped" 0 "$d" \
    --repo o/r --pr 5 --head "$H" --body "$d/body.md" "$@"
done
d="$work/head-dispatch-checkout-required"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
run_case head-dispatch-ignores-checkout-refusal 0 "review 777" 1 "$d" \
  --repo o/r --pr 5 --head "$H" --body "$d/body.md"
rm "$work/repo/.github/workflows/pr-check.yml"
d="$work/head-dispatch-checkout-missing"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
run_case head-dispatch-ignores-missing-working-file 0 "review 777" 1 "$d" \
  --repo o/r --pr 5 --head "$H" --body "$d/body.md"
cp "$work/original-workflow" "$work/repo/.github/workflows/pr-check.yml"
# A normal main-only clone can read the exact head after an object fetch;
# unavailable objects fail closed without consulting a plausible local file.
git clone -q --no-local --single-branch --branch main "$work/remote.git" "$work/main-only"
if git -C "$work/main-only" cat-file -e "$H^{commit}" 2>/dev/null; then
  echo "FAIL main-only fixture already has candidate"; fail=$((fail+1))
fi
d="$work/head-dispatch-fetch"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
run_case head-workflow-fetches-missing-candidate 0 "review 777" 1 "$d" \
  --repo o/r --pr 5 --head "$H" --body "$d/body.md" --git-dir "$work/main-only"
git init -q "$work/no-object"
d="$work/head-workflow-unavailable"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
run_case head-workflow-object-unavailable-no-post 1 "candidate workflow object unavailable" 0 "$d" \
  --repo o/r --pr 5 --head "$H" --body "$d/body.md" --git-dir "$work/no-object"

# A token inside a negated/OR expression, step or comment does not prove a
# dispatch-only job. These are different committed candidates, not dirty files.
policy_base="$H"
for policy in negated disjunction step-mention comment-mention multiline; do
  git -C "$work/repo" checkout -q --detach "$policy_base"
  python3 - "$work/repo/.github/workflows/pr-check.yml" "$policy" <<'PYCASE'
from pathlib import Path
import sys
conditions = {
    "negated": "    if: ${{ github.event_name != 'workflow_dispatch' && false }}\n",
    "disjunction": "    if: ${{ github.event_name == 'workflow_dispatch' || false }}\n",
    "step-mention": "    if: ${{ false }}\n    steps:\n      - run: echo workflow_dispatch\n",
    "comment-mention": "    if: ${{ false }} # workflow_dispatch is mentioned, not required\n",
    "multiline": "    if: >-\n      github.event_name == 'workflow_dispatch'\n",
}
Path(sys.argv[1]).write_text("name: PR check\non: [pull_request, workflow_dispatch]\njobs:\n  compare-tui:\n" + conditions[sys.argv[2]])
PYCASE
  git -C "$work/repo" add .github/workflows/pr-check.yml
  git -C "$work/repo" commit -qm "candidate skip policy $policy"
  H="$(git -C "$work/repo" rev-parse HEAD)"; export FAKE_HEAD="$H"
  for mode in write check; do
    set --; [ "$mode" = check ] && set -- --check
    d="$work/skip-policy-$policy-$mode"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
    run_case "skip-policy-$policy-refuses-$mode" 2 "check 'compare-tui' is completed/skipped" 0 "$d" \
      --repo o/r --pr 5 --head "$H" --body "$d/body.md" "$@"
  done
done
git -C "$work/repo" checkout -q pr
H="$policy_base"; export FAKE_HEAD="$H"

# A failed/cancelled early refusal from the manual Release workflow is not
# release evidence on this exact PR ref. Its suite is excluded and the
# ignored run id is visible in the approval footer. A release/v* dispatch still
# participates in the ordinary green-run gate.
for release_conclusion in failure cancelled; do
  d="$work/manual-release-refused-$release_conclusion"; setup "$d"
  echo "{\"workflow_runs\":[{\"workflow_id\":1,\"run_number\":10,\"name\":\"PR Check\",\"status\":\"completed\",\"conclusion\":\"success\",\"id\":900,\"check_suite_id\":55,\"event\":\"pull_request\",\"path\":\".github/workflows/pr-check.yml\",\"head_branch\":\"pr\"},{\"workflow_id\":2,\"run_number\":1,\"name\":\"Release\",\"status\":\"completed\",\"conclusion\":\"$release_conclusion\",\"id\":901,\"check_suite_id\":66,\"event\":\"workflow_dispatch\",\"path\":\".github/workflows/release.yml\",\"head_branch\":\"pr\"}]}" >"$d/actions.json"
  echo "{\"check_runs\":[{\"name\":\"dune build @check\",\"status\":\"completed\",\"conclusion\":\"success\",\"id\":60,\"check_suite\":{\"id\":55}},{\"name\":\"Validate manual Release ref\",\"status\":\"completed\",\"conclusion\":\"failure\",\"id\":61,\"check_suite\":{\"id\":66}}]}" >"$d/checkruns.json"
  echo '{"jobs":[{"id":61,"name":"Validate manual Release ref","status":"completed","conclusion":"failure","steps":[{"name":"Set up job","status":"completed","conclusion":"success"},{"name":"Refuse unsupported manual ref","status":"completed","conclusion":"failure"}]},{"id":62,"name":"release-body","status":"completed","conclusion":"skipped"},{"id":63,"name":"build","status":"completed","conclusion":"skipped"},{"id":64,"name":"release","status":"completed","conclusion":"skipped"}]}' >"$d/jobs.json"
  echo '[{"annotation_level":"failure","title":"MASC_RELEASE_REF_REJECTED","message":"Manual Release is limited to tags and release/v* branches."}]' >"$d/annotations.json"
  out="$(FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
  if [ "$rc" = 0 ] && [ -f "$d/posted.json" ] && "$JQ" -e '.body|contains("ignored refused manual Release dispatch run/suite:901/66")' "$d/posted.json" >/dev/null; then
    pass=$((pass+1)); echo "ok   refused-manual-release-$release_conclusion-is-ignored-and-recorded"
  else
    fail=$((fail+1)); echo "FAIL refused-manual-release-$release_conclusion-is-ignored-and-recorded (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'
  fi
done

# Same ref and same failed Release metadata do not prove an intended refusal.
# A setup failure never reaches the validator step; even a failed validator
# step without its named annotation must remain a failing Release workflow.
for fault in setup missing-marker; do
  d="$work/manual-release-unrelated-$fault"; setup "$d"
  cp "$work/manual-release-refused-failure/actions.json" "$d/actions.json"
  cp "$work/manual-release-refused-failure/checkruns.json" "$d/checkruns.json"
  cp "$work/manual-release-refused-failure/jobs.json" "$d/jobs.json"
  cp "$work/manual-release-refused-failure/annotations.json" "$d/annotations.json"
  if [ "$fault" = setup ]; then
    "$JQ" '(.jobs[] | select(.name == "Validate manual Release ref") | .steps) = [{"name":"Set up job","status":"completed","conclusion":"failure"},{"name":"Refuse unsupported manual ref","status":"completed","conclusion":"skipped"}]' "$d/jobs.json" >"$d/new.json" && mv "$d/new.json" "$d/jobs.json"
  else
    echo '[]' >"$d/annotations.json"
  fi
  run_case "unrelated-manual-release-$fault-still-blocks" 2 "workflow 'Release' run 901 is completed/failure" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
done

# Red control: removing the marker predicate must turn the negative fixture
# into an approval, proving the fixture distinguishes the safety check.
mkdir -p "$work/no-marker-review"
cp "$here/approve-guard.sh" "$here/ci-checks.sh" "$here/ci-freshness.py" "$here/review-verdict.sh" "$here/pr-check-run-contract.sh" "$work/no-marker-review/"
sed 's/\[ "$marker" = "1" \] || continue/: # red-control marker removed/' "$here/ci-checks.sh" >"$work/no-marker-review/ci-checks.sh"
d="$work/manual-release-unrelated-missing-marker"
out="$(FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$work/no-marker-review/approve-guard.sh" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$d/posted.json" ]; then
  pass=$((pass+1)); echo "ok   missing-marker-red-control-approves-only-with-predicate-removed"
else
  fail=$((fail+1)); echo "FAIL missing-marker-red-control (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'
fi

d="$work/manual-release-annotation-api-error"; setup "$d"
cp "$work/manual-release-refused-failure/actions.json" "$d/actions.json"
cp "$work/manual-release-refused-failure/checkruns.json" "$d/checkruns.json"
cp "$work/manual-release-refused-failure/jobs.json" "$d/jobs.json"
out="$(FAKE_FAIL='*/annotations*' FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 1 ] && [ ! -f "$d/posted.json" ] && printf '%s' "$out" | grep -q 'annotations.*failed'; then
  pass=$((pass+1)); echo "ok   annotation-read-error-stops-without-approval"
else
  fail=$((fail+1)); echo "FAIL annotation-read-error (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'
fi

d="$work/manual-release-still-running"; setup "$d"
echo '{"workflow_runs":[{"workflow_id":2,"run_number":1,"name":"Release","status":"in_progress","conclusion":null,"id":903,"check_suite_id":68,"event":"workflow_dispatch","path":".github/workflows/release.yml","head_branch":"feature/task-1786"}]}' >"$d/actions.json"
run_case in-progress-manual-release-still-blocks 2 "workflow 'Release' run 903 is in_progress/none" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

d="$work/manual-release-release-branch"; setup "$d"
echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"release/v0.42.1\"}}" >"$d/pull.json"
echo '{"workflow_runs":[{"workflow_id":2,"run_number":1,"name":"Release","status":"completed","conclusion":"failure","id":902,"check_suite_id":67,"event":"workflow_dispatch","path":".github/workflows/release.yml","head_branch":"release/v0.42.1"}]}' >"$d/actions.json"
echo '{"check_runs":[{"name":"Validate manual Release ref","status":"completed","conclusion":"failure","id":62,"check_suite":{"id":67}}]}' >"$d/checkruns.json"
run_case release-ref-manual-release-failure-still-refuses 2 "workflow 'Release' run 902 is completed/failure" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

# The SLOT queue ended with the green lane (2026-09-25); an old caller that
# still passes --slot stops with an infra error instead of posting.
d="$work/oldslotarg"; setup "$d"
run_case old-slot-argument-stops 1 "unknown argument: --slot" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"

# ---- lane without jq: the guard must still post (code-reviewer P1 on #38625) ----
d="$work/nojq-case"; setup "$d"
out="$(PATH="$work/nojq:$PATH" FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --git-dir "$work/repo" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$d/posted.json" ] && "$JQ" -e --arg h "$H" '.event=="APPROVE" and .commit_id==$h and (.body|startswith("verdict: PASS head: "+$h)) and (.body|contains("approve-guard: head"))' "$d/posted.json" >/dev/null; then
  pass=$((pass+1)); echo "ok   no-jq-still-posts"
else fail=$((fail+1)); echo "FAIL no-jq-still-posts (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; fi

# ---- transport errors: exit 1, one message, no refusal list, no write ----
d="$work/pullfail"; setup "$d"
FAKE_FAIL='*/pulls/5' run_case gh-pull-fails 1 "gh api repos/o/r/pulls/5 failed" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/checkfail"; setup "$d"
FAKE_FAIL='*/check-runs*' run_case gh-checkruns-fails 1 "check-runs?per_page=100 failed" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/userfail"; setup "$d"
FAKE_FAIL='user' run_case gh-user-fails-no-post 1 "gh api user failed" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/userempty"; setup "$d"; echo '{"login":""}' >"$d/user.json"
run_case user-empty-no-post 1 "returned no login" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

# The merge boundary executes only against this fake API. Its write marker
# proves a later HOLD and stale evidence cannot reach merge-async.
merge_case() {
  local name="$1" want="$2" write="$3" d="$4" rc out actual=0; shift 4
  out="$(cd "${MERGE_CASE_CWD:-$PWD}" && FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$here/merge-guard.sh" --repo o/r --pr 5 \
    --head "$H" --run 900 --git-dir "$work/repo" "$@" 2>&1)"; rc=$?
  [ -f "$d/merged" ] && actual=1
  if [ "$rc" = "$want" ] && [ "$actual" = "$write" ]; then
    pass=$((pass+1)); echo "ok   $name"
  else fail=$((fail+1)); echo "FAIL $name rc=$rc write=$actual"; echo "$out"; fi
}
merge_setup() {
  setup "$1"
  approved_review 888 "$H" "$H" "$H" | "$JQ" \
    'map(.user.login="reviewer" | .submitted_at="2026-01-01T00:40:00Z")' > "$1/reviews.json"
}
d="$work/merge-fresh"; merge_setup "$d"
merge_case merge-fresh 0 1 "$d"
# The required wrapper must preserve the shared merge-check contract. Keep a
# separate current PASS so these failures cannot be hidden by verdict parsing.
for mode in write check; do
  set --; [ "$mode" = check ] && set -- --check
  for mutation in missing-footer retargeted author split-authority; do
    d="$work/merge-binding-$mutation-$mode"; merge_setup "$d"
    "$JQ" '[.[] | {created_at:"2026-01-01T00:41:00Z",body,author_association}]' "$d/reviews.json" > "$d/comments.json"
    case "$mutation" in
      missing-footer) expression='map(.body |= split("\n")[0])' ;;
      retargeted) expression='map(.body |= gsub($head; $old))' ;;
      author) expression='map(.user.login="jeong-sik")' ;;
      split-authority)
        expression='.[0] as $bound | map(.body |= split("\n")[0]) +
          [($bound | .id=889 | .user.login="outsider" | .author_association="NONE")]' ;;
    esac
    "$JQ" --arg head "$H" --arg old "$H2" "$expression" "$d/reviews.json" > "$d/p"
    mv "$d/p" "$d/reviews.json"
    merge_case "merge-binding-$mutation-$mode" 2 0 "$d" "$@"
  done
  d="$work/merge-binding-old-commit-$mode"; merge_setup "$d"
  "$JQ" --arg old "$H2" 'map(.commit_id=$old)' "$d/reviews.json" > "$d/p"
  mv "$d/p" "$d/reviews.json"
  expected_write=1; [ "$mode" != check ] || expected_write=0
  merge_case "merge-binding-current-body-old-commit-$mode" 0 "$expected_write" "$d" "$@"
done
# Correcting explanatory text on an old PASS cannot resurrect it over a newer
# refusal. Exercise approval/merge and both --check/write paths with a formal
# approval still present, so only the structured decision blocks the write.
for verdict in HOLD FAIL; do
  for mode in write check; do
    set --; [ "$mode" = check ] && set -- --check
    d="$work/merge-edited-old-pass-$verdict-$mode"; merge_setup "$d"
    "$JQ" -n --arg h "$H" --arg state "$verdict" '[
      {id:1,created_at:"2026-01-01T00:41:00Z",updated_at:"2026-01-01T00:59:00Z",author_association:"COLLABORATOR",
       body:("verdict: PASS head: "+$h+" run: 900 by: keeper\nCorrected explanation")},
      {id:2,created_at:"2026-01-01T00:50:00Z",author_association:"COLLABORATOR",
       body:("verdict: "+$state+" head: "+$h+" run: 900 by: keeper")} ]' > "$d/comments.json"
    merge_case "merge-edited-old-pass-keeps-$verdict-$mode" 2 0 "$d" "$@"
    run_case "approval-edited-old-pass-keeps-$verdict-$mode" 2 "latest structured verdict is $verdict" 0 "$d" \
      --repo o/r --pr 5 --head "$H" --body "$d/body.md" "$@"
  done
done
# The final CI read itself can receive a later decision. Exercise both dry-run
# returns and real write paths; every refusal must occur after the injected read.
for verdict in HOLD FAIL; do
  for mode in write check; do
    set --; [ "$mode" = check ] && set -- --check
    d="$work/merge-final-check-$verdict-$mode"; merge_setup "$d"
    echo "$verdict" > "$d/after_checks_verdict"
    merge_case "merge-$verdict-during-final-check-$mode" 2 0 "$d" "$@"
    [ -f "$d/verdict_arrived_during_checks" ] || { echo "FAIL late merge verdict was not injected"; fail=$((fail+1)); }
    d="$work/approval-final-check-$verdict-$mode"; setup "$d"
    echo "$verdict" > "$d/after_checks_verdict"
    FAKE_LATE_PR_AFTER_MAIN_READS=2 run_case "approval-$verdict-during-final-check-$mode" 2 \
      "latest structured verdict is $verdict" 0 "$d" --repo o/r --pr 5 --head "$H" \
      --body "$d/body.md" "$@"
    [ -f "$d/verdict_arrived_during_checks" ] || { echo "FAIL late approval verdict was not injected"; fail=$((fail+1)); }
  done
done
# A formal review can change during the final check read without a new
# structured verdict. The last review-state read must refuse both cases.
for review_mutation in new-cr dismiss-approval remove-footer; do
  for mode in write check; do
    set --; [ "$mode" = check ] && set -- --check
    d="$work/merge-final-review-$review_mutation-$mode"; merge_setup "$d"
    echo "$review_mutation" > "$d/after_checks_review"
    merge_case "merge-$review_mutation-during-final-check-$mode" 2 0 "$d" "$@"
    [ -f "$d/review_arrived_during_checks" ] || { echo "FAIL late formal review was not injected"; fail=$((fail+1)); }
  done
done
# The approval account must also re-read formal requests after final CI.
# Bodies deliberately carry no structured verdict, including our shared account.
for review_mutation in new-cr new-own-cr; do
  for mode in write check; do
    set --; [ "$mode" = check ] && set -- --check
    d="$work/approval-final-review-$review_mutation-$mode"; setup "$d"
    echo "$review_mutation" > "$d/after_checks_review"
    FAKE_LATE_PR_AFTER_MAIN_READS=2 run_case "approval-$review_mutation-during-final-check-$mode" 2 "CHANGES_REQUESTED" 0 "$d" \
      --repo o/r --pr 5 --head "$H" --body "$d/body.md" "$@"
    [ -f "$d/review_arrived_during_checks" ] || { echo "FAIL late approval formal review was not injected"; fail=$((fail+1)); }
  done
done
# Every late change keeps the branch ref and old checks green. Only the live
# PR-state read can prevent an old-head approval/merge request from being sent.
for mutation in head draft closed base merged; do
  case "$mutation" in
    head) expression='.head.sha=$h' ;;
    draft) expression='.draft=true' ;;
    closed) expression='.state="closed"' ;;
    base) expression='.base.ref="release"' ;;
    merged) expression='.merged=true' ;;
  esac
  d="$work/merge-late-pr-$mutation"; merge_setup "$d"
  "$JQ" --arg h "$H2" "$expression" "$d/pull.json" > "$d/late_pull.json"
  merge_case "merge-late-pr-$mutation-no-write" 2 0 "$d"
  d="$work/approval-late-pr-$mutation"; setup "$d"
  "$JQ" --arg h "$H2" "$expression" "$d/pull.json" > "$d/late_pull.json"
  FAKE_LATE_PR_AFTER_MAIN_READS=2 run_case "approval-late-pr-$mutation-no-post" 2 "REFUSED" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
done
# Also move head after the final gate has begun reading green checks.
d="$work/merge-pr-moves-during-checks"; merge_setup "$d"
"$JQ" --arg h "$H2" '.head.sha=$h' "$d/pull.json" > "$d/after_checks_pull.json"
merge_case merge-pr-moves-during-checks-no-write 2 0 "$d"
d="$work/approval-pr-moves-during-checks"; setup "$d"
"$JQ" --arg h "$H2" '.head.sha=$h' "$d/pull.json" > "$d/after_checks_pull.json"
FAKE_LATE_PR_AFTER_MAIN_READS=2 run_case approval-pr-moves-during-checks-no-post 2 "head moved" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# Passing --git-dir must not depend on the caller already being in a repo.
d="$work/merge-outside-repo"; merge_setup "$d"
GUARD_REPO_ROOT= MERGE_CASE_CWD="$work" merge_case merge-explicit-git-dir-outside-repo 0 1 "$d"
for late_status in queued completed; do
  d="$work/merge-late-workflow-$late_status"; merge_setup "$d"
  echo "$late_status" > "$d/late_workflow"
  merge_case "merge-later-$late_status-workflow-no-write" 2 0 "$d"
done
d="$work/merge-late-check"; merge_setup "$d"; touch "$d/late_check"
merge_case merge-later-failed-check-no-write 2 0 "$d"
# A newer other-PR run cannot hide a candidate failure or block its success,
# even when GitHub associates the other run with both same-SHA PRs.
for association in other both; do
  for candidate_conclusion in failure success; do
    d="$work/merge-cross-pr-$association-$candidate_conclusion"; merge_setup "$d"
    "$JQ" --arg candidate "$candidate_conclusion" --arg association "$association" '
      .workflow_runs |= map(. + {check_suite_id:200}) |
      .workflow_runs += [
        {workflow_id:1,run_number:11,name:"PR Check",status:"completed",conclusion:$candidate,
         id:901,check_suite_id:201,head_branch:"pr",pull_requests:[{number:5}]},
        {workflow_id:1,run_number:12,name:"PR Check",status:"completed",
         conclusion:(if $candidate=="failure" then "success" else "failure" end),
         id:902,check_suite_id:202,head_branch:"other-pr",
         pull_requests:(if $association=="both" then [{number:5},{number:6}] else [{number:6}] end)}]' "$d/actions.json" > "$d/p"
    mv "$d/p" "$d/actions.json"
    "$JQ" -n --arg candidate "$candidate_conclusion" '{check_runs:[
      {name:"lint suite",status:"completed",conclusion:"success",id:10,check_suite:{id:200}},
      {name:"lint suite",status:"completed",conclusion:$candidate,id:11,check_suite:{id:201}},
      {name:"lint suite",status:"completed",conclusion:(if $candidate=="failure" then "success" else "failure" end),id:12,check_suite:{id:202}}]}' > "$d/checkruns.json"
    if [ "$candidate_conclusion" = failure ]; then
      merge_case "merge-cross-pr-$association-cannot-hide-failure" 2 0 "$d"
    else
      merge_case "merge-cross-pr-$association-cannot-block-success" 0 1 "$d"
    fi
  done
done
for candidate_conclusion in failure success check_failure; do
  d="$work/merge-mixed-event-$candidate_conclusion"; merge_setup "$d"
  "$JQ" --arg candidate "$candidate_conclusion" '
    .workflow_runs |= map(. + {check_suite_id:200}) |
    .workflow_runs += [
      {workflow_id:1,run_number:11,name:"PR Check",status:"completed",conclusion:(if $candidate=="check_failure" then "success" else $candidate end),
       id:901,check_suite_id:201,event:"pull_request",head_branch:"pr"},
      {workflow_id:1,run_number:12,name:"PR Check",status:"completed",conclusion:"success",
       id:902,check_suite_id:202,event:"workflow_dispatch",head_branch:"pr"}]' "$d/actions.json" > "$d/p"
  mv "$d/p" "$d/actions.json"
  "$JQ" -n --arg candidate "$candidate_conclusion" '{check_runs:[
    {name:"lint suite",status:"completed",conclusion:(if $candidate=="check_failure" then "failure" else $candidate end),id:11,check_suite:{id:201}},
    {name:"lint suite",status:"completed",conclusion:"success",id:12,check_suite:{id:202}}]}' > "$d/checkruns.json"
  if [ "$candidate_conclusion" != success ]; then
    merge_case "merge-dispatch-cannot-hide-pr-$candidate_conclusion" 2 0 "$d"
  else
    merge_case merge-successful-pr-and-dispatch 0 1 "$d"
  fi
done
# Trusted comment PASS does not authorize an unrelated outsider's APPROVED.
# All three repository participant classes can provide the formal approval.
for authority in NONE CONTRIBUTOR UNKNOWN null OWNER MEMBER COLLABORATOR; do
  d="$work/merge-approval-$authority"; merge_setup "$d"
  "$JQ" '[.[] | {created_at:"2026-01-01T00:41:00Z",body,author_association}]' "$d/reviews.json" > "$d/comments.json"
  "$JQ" --arg a "$authority" 'map(.author_association=(if $a=="null" then null else $a end))' "$d/reviews.json" > "$d/p"
  mv "$d/p" "$d/reviews.json"
  case "$authority" in
    OWNER|MEMBER|COLLABORATOR) merge_case "merge-trusted-approval-$authority" 0 1 "$d" ;;
    *) merge_case "merge-untrusted-approval-$authority-no-write" 2 0 "$d" ;;
  esac
done
d="$work/merge-paginated"; merge_setup "$d"
cp "$d/reviews.json" "$d/reviews-page-2.json"
"$JQ" -n --arg h "$H" '[range(1;101) | {id:.,state:"COMMENTED",commit_id:$h,user:{login:"reviewer"},body:"earlier review",submitted_at:"2026-01-01T00:20:00Z"}]' > "$d/reviews.json"
merge_case merge-paginated-latest-approval 0 1 "$d"
d="$work/merge-late-hold"; merge_setup "$d"; touch "$d/late_hold"
merge_case merge-hold-arrives-during-freshness 2 0 "$d"
d="$work/merge-hold"; merge_setup "$d"
"$JQ" -n --arg h "$H" '[{created_at:"2026-01-01T00:50:00Z",
 body:("verdict: HOLD head: "+$h+" run: 900 by: keeper")}]' > "$d/comments.json"
merge_case merge-later-hold 2 0 "$d"
d="$work/merge-no-approval"; setup "$d"
"$JQ" -n --arg h "$H" '[{created_at:"2026-01-01T00:40:00Z",author_association:"COLLABORATOR",
 body:("verdict: PASS head: "+$h+" run: 900 by: keeper")}]' > "$d/comments.json"
merge_case merge-no-approval 2 0 "$d"
d="$work/approval-late-cr"; setup "$d"; touch "$d/late_cr"
run_case approval-cr-arrives-during-freshness 2 "--replace-own-cr 999" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/approval-late-hold"; setup "$d"; touch "$d/late_approval_hold"
run_case approval-hold-arrives-during-freshness 2 "latest structured verdict is HOLD" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
for late_status in queued completed; do
  d="$work/approval-late-workflow-$late_status"; setup "$d"
  echo "$late_status" > "$d/late_workflow"
  FAKE_LATE_AFTER_MAIN_READS=1 run_case "approval-later-$late_status-workflow-no-post" 2 "run 901 is $late_status" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
done
d="$work/approval-late-check"; setup "$d"; touch "$d/late_check"
FAKE_LATE_AFTER_MAIN_READS=1 run_case approval-later-failed-check-no-post 2 "check-run 99" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
# Main now touches a PR file after the cited run; both write boundaries refuse.
git -C "$work/repo" checkout -q main
echo integration > "$work/repo/pr.ml"
git -C "$work/repo" add .
GIT_AUTHOR_DATE=2026-01-01T01:00:00Z GIT_COMMITTER_DATE=2026-01-01T01:00:00Z git -C "$work/repo" commit -qm integration
export FAKE_MAIN="$(git -C "$work/repo" rev-parse HEAD)"
git -C "$work/repo" push -q origin main
d="$work/stale-approval"; setup "$d"
run_case stale-approval-no-post 2 '"status": "stale"' 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/stale-merge"; merge_setup "$d"
merge_case stale-merge-no-write 2 0 "$d"


if [ -n "$workflow" ]; then
  # Workflow names/group are the scheduler half of the contract. Execute the
  # actual summary shell for each unsuccessful needs result, not a copied gate.
  expected_names="$work/workflow-names"
  : >"$expected_names"
  source "$here/pr-check-run-contract.sh"
  while IFS= read -r check_name; do
    printf "    name: \${{ github.event.pull_request.draft == true && 'Draft snapshot / %s' || '%s' }}\n" "$check_name" "$check_name" >>"$expected_names"
  done < <(pr_check_names scope)
  if diff -u <(LC_ALL=C sort "$expected_names") <(grep '^    name:' "$workflow" | LC_ALL=C sort) &&
     grep -qFx "  group: pr-check-\${{ github.event.pull_request.number }}-\${{ github.event.pull_request.draft == true && 'draft' || 'ready' }}" "$workflow" &&
     grep -qFx '  cancel-in-progress: true' "$workflow" &&
     [ "$(grep -cFx '    if: github.event.pull_request.draft == false' "$workflow")" = 6 ] &&
     grep -qFx '    if: ${{ always() && github.event.pull_request.draft == false }}' "$workflow" &&
     grep -qFx '    needs: [scope, tla, lint, check, release-check, dashboard-types]' "$workflow"; then
    pass=$((pass+1)); echo 'ok   workflow-ready-names-and-draft-isolation'
  else fail=$((fail+1)); echo 'FAIL workflow-ready-names-and-draft-isolation'; fi
  sed -n '/^  required-success:/,$p' "$workflow" | sed -n '/^        run: |/,$p' | tail -n +2 | sed 's/^          //' >"$work/summary.sh"
  for field in PR_DRAFT SCOPE_RESULT TLA_RESULT LINT_RESULT CHECK_RESULT RELEASE_RESULT DASHBOARD_RESULT; do
    for result in failure cancelled skipped pending ''; do
      if env PR_DRAFT=false SCOPE_RESULT=success TLA_RESULT=success LINT_RESULT=success CHECK_RESULT=success RELEASE_RESULT=success DASHBOARD_RESULT=success \
        "$field=$result" bash "$work/summary.sh" >"$work/summary.out" 2>&1; then
        fail=$((fail+1)); echo "FAIL summary-accepted-$field-$result"
      else pass=$((pass+1)); echo "ok   summary-refuses-$field-$result"; fi
    done
  done
  if env PR_DRAFT=false SCOPE_RESULT=success TLA_RESULT=success LINT_RESULT=success CHECK_RESULT=success RELEASE_RESULT=success DASHBOARD_RESULT=success \
    bash "$work/summary.sh" >"$work/summary.out" 2>&1; then
    pass=$((pass+1)); echo 'ok   ready-summary-five-successes'
  else fail=$((fail+1)); echo 'FAIL ready-summary-five-successes'; fi
  if env PR_DRAFT=true SCOPE_RESULT=success TLA_RESULT=success LINT_RESULT=success CHECK_RESULT=success RELEASE_RESULT=success DASHBOARD_RESULT=success \
    bash "$work/summary.sh" >"$work/summary.out" 2>&1; then
    fail=$((fail+1)); echo 'FAIL summary-accepted-current-draft'
  else pass=$((pass+1)); echo 'ok   summary-refuses-current-draft'; fi
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
