# Type-check required rollout — 2026-11-10 record and stage-2 plan

## The gap this closes

On 2026-11-10 three merges reached `main` without a green PR-side type-check:

- #51157 merged 16:56:24Z with no type-check context at all (check-runs total=1).
- #51161 merged 17:32:38Z with `type-check` still `in_progress`.
- #51155 merged 17:40:58Z with a red `type-check` (stale merge ref — the failure
  coordinates were the two main compile errors already closed by #51159/#51161).

All three were possible because `main` had **no required status checks**: a red
or missing check never blocked a merge that had two approvals.

## Stage 1 (landed in #51155)

`.github/workflows/pr-type-check.yml` moved its `paths:` filter from the
workflow trigger to the job level, so every pull request gets both contexts:

- `changes` — captures the changed-file list. Fail-closed: an API failure fails
  the job rather than yielding a quiet skip. `pull-requests: read` granted;
  `changed_files >= 3000` folds to `src=true` (over-limit counts as source).
- `type-check` — skipped when `changes.outputs.src` is false, but the context
  still exists on every PR.

## Stage 2 (this document is the probe)

Order, per operator answer c1 (ask `aske1aa44782fd05693`):

1. This docs-only PR observes the contexts: `changes` success with `src=false`,
   `type-check` skipped.
2. Ruleset 26823705 ("Two approvals for main") then registers
   `changes` + `type-check` **as a pair**.
3. This PR's mergeability after that registration measures whether a skipped
   check satisfies `required` — the property stage 1 exists to provide.

## Known adjacent gap (tracked separately)

`github-actions[bot]` merges do not fire the push-triggered Main minimal build
(human-account merges fire it in 3–5 s; same-instant queue was empty). Interim
rule: any keeper observing a bot merge dispatches the build immediately
(`workflow_dispatch`, ref=main — run 42867165587 is the worked example). A
separate PR will make `approval-auto-merge` do this itself.

## 2026-11-10 19:38Z — 등록 완료와 측정 이월

- ruleset 26823705 "Two approvals for main"에 `required_status_checks`(컨텍스트 `changes`·`type-check`) 등록(19:38:57Z, history version 57184716). `do_not_enforce_on_create=false`, `strict_required_status_checks_policy=false`.
- 등록 API 422 원인: 현행 스키마는 parameters 에 `strict_required_status_checks_policy`(필수 boolean)와 `required_status_checks` 배열(`{context}`)을 요구. 구세대 `strict` 키·`checks` 배열 키는 oneOf 불일치.
- 프로브 #51167(docs-only): `changes` 첫 시도는 설치 토큰 레이트리밋으로 fail-closed 실패(18:23:55Z), 재실행 success(19:14:11Z). `type-check` skipped(19:14:16Z). #51167 은 등록 전 19:29:51Z 병합되어, "skipped 가 required 를 통과하는가"의 종단 측정은 등록 뒤 개봉되는 docs-only PR(본 PR)에서 한다.
- 근거 사건: #50746·#51157·#51161·#51149 — 전부 required status check 부재가 원인.
