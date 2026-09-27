#!/usr/bin/env bash
# Self-test for approve-guard.sh with a fake gh. No network.
# Each case builds fixtures, runs the guard, and checks exit code + a stderr/stdout needle
# + whether a POST happened.
set -u
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
  echo "fake gh: GET $ep without --paginate" >&2; exit 1
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
    printf '{"sha":"%s"}\n' "$FAKE_MAIN" | "$FAKE_JQ" -r "$jqf"; exit ;;
  */files\?*) echo '[{"filename":"pr.ml"}]' | "$FAKE_JQ" -r "$jqf"; exit ;;
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
  */check-runs*) f=checkruns ;;
  */actions/runs*) f=actions ;;
  user) f=user ;;
  */reviews/*) f=reviewget ;;
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
    dismiss-approval)
      "$FAKE_JQ" --arg h "$FAKE_HEAD" '. + [{id:999,state:"DISMISSED",commit_id:$h,
        author_association:"COLLABORATOR",user:{login:"reviewer"}}]' "$d/reviews.json" > "$d/reviews.next.json" ;;
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
elif [ "$f" = reviews ] && [ -f "$d/reviews-page-2.json" ]; then
  "$FAKE_JQ" -r "$jqf" "$d/reviews.json"
  "$FAKE_JQ" -r "$jqf" "$d/reviews-page-2.json"
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

setup() { # setup <casedir>: default happy fixtures
  local d="$1"; mkdir -p "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"changed_files\":1,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"pr\"}}" >"$d/pull.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":11},{"name":"lint suite","status":"completed","conclusion":"success","id":12}]}' >"$d/checkruns.json"
  echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900}]}' >"$d/actions.json"
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
d="$work/dup"; setup "$d"; echo "[{\"id\":42,\"user\":{\"login\":\"pangyo-preachers\"},\"state\":\"APPROVED\",\"commit_id\":\"$H\"}]" >"$d/reviews.json"
run_case already-approved 0 "already APPROVED" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dupold"; setup "$d"; echo "[{\"id\":42,\"user\":{\"login\":\"pangyo-preachers\"},\"state\":\"APPROVED\",\"commit_id\":\"$H2\"}]" >"$d/reviews.json"
run_case approved-older-head-still-posts 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
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

# ---- dispatch-only skipped job (#38873): workflow file decides, never the row alone ----
# A job whose `if:` requires workflow_dispatch is skipped in every pull_request
# run by design; the newest pull_request suite may still be green. The guard
# reads the condition from the workflow file at GUARD_REPO_ROOT, so the
# fixtures point it at a small tree instead of the working repo.
wfroot="$work/wftree"; mkdir -p "$wfroot/.github/workflows"
cat >"$wfroot/.github/workflows/pr-check.yml" <<'EOF'
name: PR check
on:
  pull_request:
  workflow_dispatch:
jobs:
  compare-tui:
    if: ${{ github.event_name == 'workflow_dispatch' && inputs.compare_tui }}
    runs-on: macos-14
    steps: []
EOF
cat >"$wfroot/.github/workflows/other.yml" <<'EOF'
name: Other
on:
  pull_request:
jobs:
  compare-tui:
    runs-on: ubuntu-latest
    steps: []
EOF
mkcase() { # mkcase <dir> <suite-event> <suite-path>
  local d="$1" ev="$2" p="$3"; mkdir -p "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"changed_files\":1,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"pr\"}}" >"$d/pull.json"
  echo "{\"workflow_runs\":[{\"workflow_id\":1,\"run_number\":10,\"name\":\"PR check\",\"status\":\"completed\",\"conclusion\":\"success\",\"id\":900,\"check_suite_id\":55,\"event\":\"$ev\",\"path\":\"$p\"}]}" >"$d/actions.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":60,"check_suite":{"id":55}},{"name":"compare-tui","status":"completed","conclusion":"skipped","id":61,"check_suite":{"id":55}}]}' >"$d/checkruns.json"
  echo '{"login":"pangyo-preachers"}' >"$d/user.json"
  echo '[]' >"$d/reviews.json"
  echo '[]' >"$d/comments.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/postresp.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
  printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\nLGTM, file:line evidence\n' "$H" >"$d/body.md"
}
d="$work/dispatchskip"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
out="$(GUARD_REPO_ROOT="$wfroot" FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --git-dir "$work/repo" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$d/posted.json" ] && "$JQ" -e '.body|endswith(" · dispatch-only skipped: compare-tui")' "$d/posted.json" >/dev/null; then pass=$((pass+1)); echo "ok   dispatch-only-job-skipped-approves"; else fail=$((fail+1)); echo "FAIL dispatch-only-job-skipped-approves (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; cat "$d/posted.json" 2>/dev/null; fi
d="$work/requiredskip"; mkcase "$d" pull_request ".github/workflows/other.yml"
run_case required-job-skipped-refuses 2 "check 'compare-tui' is completed/skipped (check-run 61)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dispatchskip-dispatch-suite"; mkcase "$d" workflow_dispatch ".github/workflows/pr-check.yml"
run_case dispatch-suite-skipped-still-refuses 2 "check 'compare-tui' is completed/skipped (check-run 61)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

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
  "$JQ" -n --arg h "$H" '[{id:888,state:"APPROVED",commit_id:$h,
    submitted_at:"2026-01-01T00:40:00Z",author_association:"COLLABORATOR",user:{login:"reviewer"},
    body:("verdict: PASS head: "+$h+" run: 900 by: keeper")} ]' > "$1/reviews.json"
}
d="$work/merge-fresh"; merge_setup "$d"
merge_case merge-fresh 0 1 "$d"
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
for review_mutation in new-cr dismiss-approval; do
  for mode in write check; do
    set --; [ "$mode" = check ] && set -- --check
    d="$work/merge-final-review-$review_mutation-$mode"; merge_setup "$d"
    echo "$review_mutation" > "$d/after_checks_review"
    merge_case "merge-$review_mutation-during-final-check-$mode" 2 0 "$d" "$@"
    [ -f "$d/review_arrived_during_checks" ] || { echo "FAIL late formal review was not injected"; fail=$((fail+1)); }
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
  "$JQ" '[.[] | {created_at:.submitted_at,body,author_association}]' "$d/reviews.json" > "$d/comments.json"
  "$JQ" --arg a "$authority" 'map(.body="LGTM" | .author_association=(if $a=="null" then null else $a end))' "$d/reviews.json" > "$d/p"
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

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
