# Dashboard integrated fixture evidence — 2026-10-04

## 공통 헤더

- 날짜(ISO8601): 2026-10-04T21:17:57.360034+09:00
- 작성자: Codex
- 결정 ID: pr40996-integrated-fixture-evidence
- 적용 대상: #40996 Dashboard source-status and decision-receipt fixtures
- 결정 상태: 확정

## 근거 (Evidence)

- 항목: Preserve the successful integrated fixture results separately from the earlier failures.
- 출처: [focused results](focused-results.txt), [first-use result](first-use-results.txt), [Health-barrier result](health-barrier-results.txt), [build log](focused-build.log), [manifest](manifest.json).
- 확인일시: 2026-10-04T21:17:57.360034+09:00
- 신뢰도: High for the recorded scenario outcomes and source-tree comparison; Medium for the retrospective binary association.
- 제한조건: These are local integrated-worktree fixture executions after a focused build. No execution-time binary hash was captured, so they are not exact-artifact or Full RC proof. No tests were rerun for this record.

## 검증 (Verification)

- 1차: The owner recorded focused build handle 50195 PASS, seven-scenario handle 10907 PASS, Dashboard first-use handle 96355 PASS, and final Health-barrier handle 80697 PASS. The retained logs contain their scenario markers; the build log alone does not stamp its process exit.
- 2차: The seven-scenario source tree was `581dd86d15b0798ab27e49d82d8c596d881dc07d`. Final commit `de6b2592a35c35a92cde74a5bf35f398dcb9df0d` has tree `12745cb8052512cee019bd557f7f051ba3b772da`. Their complete diff is one added `Health: ok` wait in `each_failed_source_keeps_other_cards`; no product bytes changed. Its four variants were then rerun.
- 3차: Current binary identity and selected source hashes were read retrospectively and stored in the manifest. Its embedded build commit is the earlier checkout `f31288fbd874888fdadccd2332f7e08a8d3740ac`, not the final integration commit. Present build copies of `bin/masc_tui_home.ml` and `bin/masc_tui.ml` match committed source; this does not create a missing run-time binary receipt.
- 재현 결과: The existing logs report PASS for the seven affected scenarios and first-use frames, followed by PASS for four source-isolation variants after the final Health barrier. Ruff passed in the original work; [Pyright report readback](typecheck-summary.json) confirms 63 errors in both retained reports and equal multisets of file basename, severity, message and rule (positions excluded). This is not a clean type check; #40984 remains tracked.

The [preserved runner](focused-runner.py.txt) names four top-level calls. They account for seven scenarios:

| Logged group | Actual entrypoint | Cases |
| --- | --- | --- |
| `failed_source` | `failed_source_keeps_known_cards` | 1 |
| `each_failed_source` | `each_failed_source_keeps_other_cards` | 4: confirm queue, held calls, Gate queue, questions |
| `receipt` | `accepted_but_pending` | 1 |
| `receipt_held` | `accepted_but_pending(..., followed_by_held=True)` | 1 |

The separate first-use result covers `test_tui_keyboard_overview_pty.first_use_frames`, not that file's complete entrypoint. The later four-variant result covers only source isolation. Small result files preserve exact PASS lines; the manifest records original full-log hashes, sizes, retained line numbers and excerpt hashes. Original PTY payloads were not relabelled as current browser screenshots.

## 불확실성 (Uncertainty)

- 미확인 항목: Exact execution-time binary hash, whole Overview suite on this integration, current browser replay, installed runtime, production and Full RC.
- 영향: The source-tree and local fixture evidence cannot certify a release artifact or all Dashboard behavior. Broader #40989 remains tracked.
- 추가 확인 필요: Capture a binary hash with future executions when exact-artifact attribution is needed. Do not infer it from this retrospective hash.

## 적용범위 (Scope)

- 영향 받는 영역: Aggregate unread labels, retained decision cards under one failed source, pending/held receipts, and first-use frames in the stated fixtures.
- 제약/배제: No full runtime or production claim; no product, fixture or test execution changes in this evidence repair.
- 롤백 조건: Narrow the audit claim if the associated source or execution scope changes.

## Historical evidence remains unchanged

The parent directory's [checks.txt](../checks.txt), [2026-10-03 record](../2026-10-03-dashboard-reading-evidence-record.md), [manifest](../manifest.json) and screen files describe the earlier 2026-10-03 candidate rooted at `43f24e914de2a529b6d8a8ae61c3adc860327e61`, with binary hash `b4168d4376dd317fcfb18d199da0aae56192377700f8d0220bd916da765db669`. Its two FAIL lines are real historical outcomes. They have not been rewritten into PASS and are not the evidence source for the integrated seven-scenario result above.
