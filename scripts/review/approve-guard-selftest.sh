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
d="$FAKE_DIR"; jqf="."; method=GET; ep=""; ev=""; cid=""; body_src=""
shift # "api"
while [ $# -gt 0 ]; do
  case "$1" in
    --paginate) shift ;;
    -X) method="$2"; shift 2 ;;
    --jq) jqf="$2"; shift 2 ;;
    --input) echo "fake gh: --input is not how the guard posts" >&2; exit 1 ;;
    -f|-F) case "$2" in
             event=*) ev="${2#event=}" ;;
             commit_id=*) cid="${2#commit_id=}" ;;
             body=@-) body_src=stdin ;;
             *) echo "fake gh: unexpected field $2" >&2; exit 1 ;;
           esac; shift 2 ;;
    *) ep="$1"; shift ;;
  esac
done
if [ -n "${FAKE_FAIL:-}" ]; then
  case "$ep" in $FAKE_FAIL) echo "HTTP 502: Bad Gateway (fake)" >&2; exit 1 ;; esac
fi
case "$ep" in
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
"$FAKE_JQ" -r "$jqf" "$d/$f.json"
EOF
chmod +x "$work/gh"

H=0123456789abcdef0123456789abcdef01234567
H2=fedcba9876543210fedcba9876543210fedcba98
pass=0; fail=0

setup() { # setup <casedir>: default happy fixtures
  local d="$1"; mkdir -p "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\"}}" >"$d/pull.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":11},{"name":"lint suite","status":"completed","conclusion":"success","id":12}]}' >"$d/checkruns.json"
  echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900}]}' >"$d/actions.json"
  echo '{"login":"pangyo-preachers"}' >"$d/user.json"
  echo '[]' >"$d/reviews.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/postresp.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
  printf 'LGTM, file:line evidence\n' >"$d/body.md"
}

run_case() { # run_case <name> <want_rc> <needle> <want_post 0|1> <casedir> [guard args...]
  local name="$1" want="$2" needle="$3" wpost="$4" d="$5"; shift 5
  local out rc posted=0
  out="$(FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" "$@" 2>&1)"; rc=$?
  [ -f "$d/posted.json" ] && posted=1
  local masked=0
  [ "$want" = 1 ] && printf '%s' "$out" | grep -qF -- "REFUSED" && masked=1
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qF -- "$needle" && [ "$posted" = "$wpost" ] && [ "$masked" = 0 ]; then
    pass=$((pass+1)); echo "ok   $name"
  else
    fail=$((fail+1)); echo "FAIL $name (rc=$rc want=$want posted=$posted want=$wpost masked=$masked)"; printf '%s\n' "$out" | sed 's/^/     /'
  fi
}

args() { echo --repo o/r --pr 5 --head "$1" --slot "$2" --body "$3"; }

d="$work/happy"; setup "$d"
run_case happy 0 "APPROVED #5 head $H review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/happy-footer"; setup "$d"
FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md" >/dev/null 2>&1
if jq -e --arg h "$H" '.event=="APPROVE" and .commit_id==$h and (.body|contains("run")) and (.body|contains("SLOT: #5 head"))' "$d/posted.json" >/dev/null; then pass=$((pass+1)); echo "ok   posted-payload"; else fail=$((fail+1)); echo "FAIL posted-payload"; cat "$d/posted.json"; fi

d="$work/check"; setup "$d"
run_case check-mode-no-write 0 "WOULD APPROVE #5" 0 "$d" --check --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H"
d="$work/sha41"; setup "$d"
run_case sha-41-chars 2 "40 lowercase hex" 0 "$d" --repo o/r --pr 5 --head "${H}0" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/slotpr"; setup "$d"
run_case slot-other-pr 2 "SLOT names #6" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #6 head $H" --body "$d/body.md"
d="$work/slotprefix"; setup "$d"
run_case slot-pr-prefix 2 "SLOT names #55" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #55 head $H" --body "$d/body.md"
d="$work/slothead"; setup "$d"
run_case slot-other-head 2 "SLOT head $H2" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H2" --body "$d/body.md"
d="$work/slotjunk"; setup "$d"
run_case slot-trailing-text 2 "not exactly" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H (after #38557)" --body "$d/body.md"
d="$work/emptybody"; setup "$d"; : >"$d/body.md"
run_case empty-body 2 "body file missing or empty" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/draft"; setup "$d"; jq '.draft=true' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case draft 2 "PR is Draft" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/moved"; setup "$d"; jq --arg h "$H2" '.head.sha=$h' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case head-moved 2 "head moved" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/base"; setup "$d"; jq '.base.ref="feat/x"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case base-not-main 2 "not main" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/merged"; setup "$d"; jq '.state="closed"|.merged=true' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case merged 2 "merged=true" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/pending"; setup "$d"; jq '.check_runs[1].status="in_progress"|.check_runs[1].conclusion=null' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case check-pending 2 "lint suite' is in_progress/none" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/failed"; setup "$d"; jq '.check_runs[0].conclusion="failure"' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case check-failed 2 "completed/failure" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/cancelled"; setup "$d"; jq '.check_runs[0].conclusion="cancelled"' "$d/checkruns.json" >"$d/p" && mv "$d/p" "$d/checkruns.json"
run_case check-cancelled 2 "completed/cancelled" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/checksuperseded"; setup "$d"; echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"skipped","id":11},{"name":"lint suite","status":"completed","conclusion":"skipped","id":12},{"name":"dune build @check","status":"completed","conclusion":"success","id":21},{"name":"lint suite","status":"completed","conclusion":"success","id":22}]}' >"$d/checkruns.json"
run_case check-superseded-skipped-ignored 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/checknewestfails"; setup "$d"; echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":11},{"name":"lint suite","status":"completed","conclusion":"success","id":12},{"name":"dune build @check","status":"completed","conclusion":"failure","id":21}]}' >"$d/checkruns.json"
run_case check-newest-run-failed 2 "check-run 21" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/nochecks"; setup "$d"; echo '{"check_runs":[]}' >"$d/checkruns.json"
run_case checks-empty 2 "empty is not green" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/wfqueued"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900},{"workflow_id":2,"run_number":3,"name":"Test","status":"queued","conclusion":null,"id":901}]}' >"$d/actions.json"
run_case workflow-queued 2 "run 901 is queued/none" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/wfsuperseded"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":11,"name":"PR Check","status":"completed","conclusion":"success","id":902},{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"cancelled","id":900}]}' >"$d/actions.json"
run_case workflow-superseded-run-ignored 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/wfnewestfails"; setup "$d"; echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900},{"workflow_id":1,"run_number":11,"name":"PR Check","status":"completed","conclusion":"failure","id":902}]}' >"$d/actions.json"
run_case workflow-newest-run-failed 2 "run 902 is completed/failure" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/dup"; setup "$d"; echo "[{\"id\":42,\"user\":{\"login\":\"pangyo-preachers\"},\"state\":\"APPROVED\",\"commit_id\":\"$H\"}]" >"$d/reviews.json"
run_case already-approved 0 "already APPROVED" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/dupold"; setup "$d"; echo "[{\"id\":42,\"user\":{\"login\":\"pangyo-preachers\"},\"state\":\"APPROVED\",\"commit_id\":\"$H2\"}]" >"$d/reviews.json"
run_case approved-older-head-still-posts 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
# ---- open change requests (leader, #38810): another account's CR refuses ----
rv() { echo "{\"id\":$1,\"user\":{\"login\":\"$2\"},\"state\":\"$3\",\"commit_id\":\"$H2\"}"; }
d="$work/cr-other"; setup "$d"; echo "[$(rv 50 jeong-sik CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-other-account-refuses 2 "open CHANGES_REQUESTED from jeong-sik (review 50)" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
run_case cr-other-account-refuses-check 2 "open CHANGES_REQUESTED from jeong-sik" 0 "$d" --check --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H"
d="$work/cr-comment"; setup "$d"; echo "[$(rv 50 jeong-sik CHANGES_REQUESTED),$(rv 60 jeong-sik COMMENTED)]" >"$d/reviews.json"
run_case cr-not-lifted-by-later-comment 2 "review 50" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/cr-lifted"; setup "$d"; echo "[$(rv 60 jeong-sik APPROVED),$(rv 50 jeong-sik CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-lifted-by-later-approve 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/cr-dismissed"; setup "$d"; echo "[$(rv 50 jeong-sik DISMISSED)]" >"$d/reviews.json"
run_case cr-dismissed-does-not-block 0 "review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/cr-own"; setup "$d"; echo "[$(rv 50 pangyo-preachers CHANGES_REQUESTED)]" >"$d/reviews.json"
run_case cr-own-account-notes-and-posts 0 "this approval replaces it" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/readback"; setup "$d"; echo "{\"id\":777,\"state\":\"COMMENTED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
run_case readback-mismatch 1 "reads back as COMMENTED" 1 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/multi"; setup "$d"; jq '.draft=true|.base.ref="dev"' "$d/pull.json" >"$d/p" && mv "$d/p" "$d/pull.json"
run_case reports-all-reasons 2 "not main" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"

# ---- lane without jq: the guard must still post (code-reviewer P1 on #38625) ----
d="$work/nojq-case"; setup "$d"
out="$(PATH="$work/nojq:$PATH" FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$d/posted.json" ] && "$JQ" -e --arg h "$H" '.event=="APPROVE" and .commit_id==$h and (.body|startswith("LGTM")) and (.body|contains("SLOT: #5 head"))' "$d/posted.json" >/dev/null; then
  pass=$((pass+1)); echo "ok   no-jq-still-posts"
else fail=$((fail+1)); echo "FAIL no-jq-still-posts (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; fi

# ---- transport errors: exit 1, one message, no refusal list, no write ----
d="$work/pullfail"; setup "$d"
FAKE_FAIL='*/pulls/5' run_case gh-pull-fails 1 "gh api repos/o/r/pulls/5 failed" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/checkfail"; setup "$d"
FAKE_FAIL='*/check-runs*' run_case gh-checkruns-fails 1 "check-runs?per_page=100 failed" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/userfail"; setup "$d"
FAKE_FAIL='user' run_case gh-user-fails-no-post 1 "gh api user failed" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"
d="$work/userempty"; setup "$d"; echo '{"login":""}' >"$d/user.json"
run_case user-empty-no-post 1 "returned no login" 0 "$d" --repo o/r --pr 5 --head "$H" --slot "SLOT: #5 head $H" --body "$d/body.md"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
