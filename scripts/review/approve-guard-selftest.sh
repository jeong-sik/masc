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
if [ "$method" = GET ] && [ "$paged" = 0 ]; then
  echo "fake gh: GET $ep without --paginate" >&2; exit 1
fi
if [ -n "${FAKE_FAIL:-}" ]; then
  case "$ep" in $FAKE_FAIL) echo "HTTP 502: Bad Gateway (fake)" >&2; exit 1 ;; esac
fi
case "$ep" in
  */check-runs/*/annotations*) f=annotations ;;
  */check-runs*) f=checkruns ;;
  */actions/runs/*/jobs*)
    rid="${ep#*/actions/runs/}"; rid="${rid%%/*}"
    if [ -f "$d/jobs-$rid.json" ]; then f="jobs-$rid"; else f=jobs; fi ;;
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
# gh api --paginate runs --jq once per response page and concatenates outputs.
if [ -f "$d/$f-page2.json" ]; then
  "$FAKE_JQ" -r "$jqf" "$d/$f.json" || exit 1
  "$FAKE_JQ" -r "$jqf" "$d/$f-page2.json"
else
  "$FAKE_JQ" -r "$jqf" "$d/$f.json"
fi
EOF
chmod +x "$work/gh"

H=0123456789abcdef0123456789abcdef01234567
H2=fedcba9876543210fedcba9876543210fedcba98
pass=0; fail=0

setup() { # setup <casedir>: default happy fixtures
  local d="$1"; mkdir -p "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"feature/task-1786\"}}" >"$d/pull.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":11},{"name":"lint suite","status":"completed","conclusion":"success","id":12}]}' >"$d/checkruns.json"
  echo '{"workflow_runs":[{"workflow_id":1,"run_number":10,"name":"PR Check","status":"completed","conclusion":"success","id":900}]}' >"$d/actions.json"
  echo '{"login":"pangyo-preachers"}' >"$d/user.json"
  echo '[]' >"$d/reviews.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/postresp.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
  printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\nLGTM, file:line evidence\n' "$H" >"$d/body.md"
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


d="$work/happy"; setup "$d"
run_case happy 0 "APPROVED #5 head $H review 777" 1 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/happy-footer"; setup "$d"
FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --body "$d/body.md" >/dev/null 2>&1
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
# A review's commit_id can be retargeted by GitHub after a main merge.
# Only the immutable verdict and final guard footer identify what was reviewed.
approved_review() { # id commit_id footer_head verdict_head
  local id="$1" commit="$2" footer="$3" verdict="$4" tick
  tick="$(printf '\x60')"
  "$JQ" -n --argjson id "$id" --arg commit "$commit" \
    --arg body "verdict: PASS head: $verdict run: 900 by: selftest-keeper

---
approve-guard: head $tick$footer$tick · 2 check-runs completed+success" \
    '[{id:$id,user:{login:"pangyo-preachers"},state:"APPROVED",commit_id:$commit,body:$body}]'
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
    {workflow_id:1,run_number:11,name:"PR check",status:"completed",conclusion:"success",id:901,check_suite_id:66,event:"pull_request",path:".github/workflows/pr-check.yml",head_sha:$h}]}' >"$1/actions.json"
  "$JQ" -n --arg h "$H" '
    ["TLA model check","lint suite","dune build @check","dune build --profile release @check","dashboard typecheck","PR required success"] |
    to_entries | {jobs:map({name:("Draft snapshot / "+.value),status:"completed",conclusion:"skipped",id:(200+.key),run_id:901,head_sha:$h})}' >"$1/jobs-901.json"
  "$JQ" '{check_runs:([.jobs[] | {name:(.name|ltrimstr("Draft snapshot / ")),status:"completed",conclusion:"success",id:(.id-100),check_suite:{id:55}}] + [.jobs[] | {name,status,conclusion,id,check_suite:{id:66}}])}' "$1/jobs-901.json" >"$1/checkruns.json"
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
for fault in missing duplicate extra success pending head run id; do
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
  race_case "ready-$fault-not-hidden-by-draft" 2 'requires six successful checks'
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
race_case latest-failed-check-in-ready-suite 2 'requires six successful checks'
d="$work/race-transport"; race_setup "$d"
FAKE_FAIL='*/jobs*' race_case draft-jobs-transport-is-infra-error 1 'gh api repos/o/r/actions/runs/901/jobs'
d="$work/race-nojq"; race_setup "$d"
PATH="$work/nojq:$PATH" race_case draft-selection-needs-no-standalone-jq 0 'WOULD APPROVE'

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
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"feature/task-1786\"}}" >"$d/pull.json"
  echo "{\"workflow_runs\":[{\"workflow_id\":1,\"run_number\":10,\"name\":\"PR check\",\"status\":\"completed\",\"conclusion\":\"success\",\"id\":900,\"check_suite_id\":55,\"event\":\"$ev\",\"path\":\"$p\"}]}" >"$d/actions.json"
  echo '{"check_runs":[{"name":"dune build @check","status":"completed","conclusion":"success","id":60,"check_suite":{"id":55}},{"name":"compare-tui","status":"completed","conclusion":"skipped","id":61,"check_suite":{"id":55}}]}' >"$d/checkruns.json"
  echo '{"login":"pangyo-preachers"}' >"$d/user.json"
  echo '[]' >"$d/reviews.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/postresp.json"
  echo "{\"id\":777,\"state\":\"APPROVED\",\"commit_id\":\"$H\"}" >"$d/reviewget.json"
  printf 'verdict: PASS head: %s run: 900 by: selftest-keeper\nLGTM, file:line evidence\n' "$H" >"$d/body.md"
}
d="$work/dispatchskip"; mkcase "$d" pull_request ".github/workflows/pr-check.yml"
out="$(GUARD_REPO_ROOT="$wfroot" FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$d/posted.json" ] && "$JQ" -e '.body|endswith(" · dispatch-only skipped: compare-tui")' "$d/posted.json" >/dev/null; then pass=$((pass+1)); echo "ok   dispatch-only-job-skipped-approves"; else fail=$((fail+1)); echo "FAIL dispatch-only-job-skipped-approves (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; cat "$d/posted.json" 2>/dev/null; fi
d="$work/requiredskip"; mkcase "$d" pull_request ".github/workflows/other.yml"
run_case required-job-skipped-refuses 2 "check 'compare-tui' is completed/skipped (check-run 61)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"
d="$work/dispatchskip-dispatch-suite"; mkcase "$d" workflow_dispatch ".github/workflows/pr-check.yml"
run_case dispatch-suite-skipped-still-refuses 2 "check 'compare-tui' is completed/skipped (check-run 61)" 0 "$d" --repo o/r --pr 5 --head "$H" --body "$d/body.md"

# A failed/cancelled early refusal from the manual Release workflow is not
# release evidence on this exact feature PR ref. Its suite is excluded and the
# ignored run id is visible in the approval footer. A release/v* dispatch still
# participates in the ordinary green-run gate.
for release_conclusion in failure cancelled; do
  d="$work/manual-release-refused-$release_conclusion"; setup "$d"
  echo "{\"state\":\"open\",\"draft\":false,\"merged\":false,\"base\":{\"ref\":\"main\"},\"head\":{\"sha\":\"$H\",\"ref\":\"feature/task-1786\"}}" >"$d/pull.json"
  echo "{\"workflow_runs\":[{\"workflow_id\":1,\"run_number\":10,\"name\":\"PR Check\",\"status\":\"completed\",\"conclusion\":\"success\",\"id\":900,\"check_suite_id\":55},{\"workflow_id\":2,\"run_number\":1,\"name\":\"Release\",\"status\":\"completed\",\"conclusion\":\"$release_conclusion\",\"id\":901,\"check_suite_id\":66,\"event\":\"workflow_dispatch\",\"path\":\".github/workflows/release.yml\",\"head_branch\":\"feature/task-1786\"}]}" >"$d/actions.json"
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
cp "$here/pr-check-run-contract.sh" "$work/pr-check-run-contract.sh"
sed 's/\[ "$marker" = "1" \] || continue/: # red-control marker removed/' "$guard" >"$work/no-marker-guard.sh"
d="$work/manual-release-unrelated-missing-marker"
out="$(FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$work/no-marker-guard.sh" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
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
out="$(PATH="$work/nojq:$PATH" FAKE_DIR="$d" GUARD_GH="$work/gh" bash "$guard" --repo o/r --pr 5 --head "$H" --body "$d/body.md" 2>&1)"; rc=$?
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


# Workflow names/group are the scheduler half of the contract. Execute the
# actual summary shell for each unsuccessful needs result, not a copied gate.
workflow="$here/../../.github/workflows/pr-check.yml"
expected_names="$work/workflow-names"
: >"$expected_names"
for check_name in 'TLA model check' 'lint suite' 'dune build @check' 'dune build --profile release @check' 'dashboard typecheck' 'PR required success'; do
  printf "    name: \${{ github.event.pull_request.draft == true && 'Draft snapshot / %s' || '%s' }}\n" "$check_name" "$check_name" >>"$expected_names"
done
if diff -u <(LC_ALL=C sort "$expected_names") <(grep '^    name:' "$workflow" | LC_ALL=C sort) &&
   grep -qFx "  group: pr-check-\${{ github.event.pull_request.number }}-\${{ github.event.pull_request.draft == true && 'draft' || 'ready' }}" "$workflow" &&
   grep -qFx '  cancel-in-progress: true' "$workflow" &&
   [ "$(grep -cFx '    if: github.event.pull_request.draft == false' "$workflow")" = 5 ] &&
   grep -qFx '    if: ${{ always() && github.event.pull_request.draft == false }}' "$workflow" &&
   grep -qFx '    needs: [tla, lint, check, release-check, dashboard-types]' "$workflow"; then
  pass=$((pass+1)); echo 'ok   workflow-ready-names-and-draft-isolation'
else fail=$((fail+1)); echo 'FAIL workflow-ready-names-and-draft-isolation'; fi
sed -n '/^  required-success:/,$p' "$workflow" | sed -n '/^        run: |/,$p' | tail -n +2 | sed 's/^          //' >"$work/summary.sh"
for field in PR_DRAFT TLA_RESULT LINT_RESULT CHECK_RESULT RELEASE_RESULT DASHBOARD_RESULT; do
  for result in failure cancelled skipped pending ''; do
    if env PR_DRAFT=false TLA_RESULT=success LINT_RESULT=success CHECK_RESULT=success RELEASE_RESULT=success DASHBOARD_RESULT=success \
      "$field=$result" bash "$work/summary.sh" >"$work/summary.out" 2>&1; then
      fail=$((fail+1)); echo "FAIL summary-accepted-$field-$result"
    else pass=$((pass+1)); echo "ok   summary-refuses-$field-$result"; fi
  done
done
if env PR_DRAFT=false TLA_RESULT=success LINT_RESULT=success CHECK_RESULT=success RELEASE_RESULT=success DASHBOARD_RESULT=success \
  bash "$work/summary.sh" >"$work/summary.out" 2>&1; then
  pass=$((pass+1)); echo 'ok   ready-summary-five-successes'
else fail=$((fail+1)); echo 'FAIL ready-summary-five-successes'; fi
if env PR_DRAFT=true TLA_RESULT=success LINT_RESULT=success CHECK_RESULT=success RELEASE_RESULT=success DASHBOARD_RESULT=success \
  bash "$work/summary.sh" >"$work/summary.out" 2>&1; then
  fail=$((fail+1)); echo 'FAIL summary-accepted-current-draft'
else pass=$((pass+1)); echo 'ok   summary-refuses-current-draft'; fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
