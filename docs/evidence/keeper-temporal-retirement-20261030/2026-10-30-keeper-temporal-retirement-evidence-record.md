# Candidate continuity and native TUI observations

## 공통 헤더

- 날짜(ISO8601): `2026-10-30T19:50:00+09:00`
- 작성자: `Codex implementation session`
- 결정 ID: `keeper-temporal-retirement-20261030`
- 적용 대상: `PR #46971; isolated candidate; temporal measurement TUI`
- 결정 상태: `실측 기록 완료; 일반화와 운영 설치는 별도`

## 근거 (Evidence)

- 항목: Compiled candidate and helper identities.
- 출처: [Native run 41038850459](https://github.com/jeong-sik/masc/actions/runs/41038850459), source `0639b9da27c8c535b9c9c47154ef752a716b8a3f`; receipt/executable hashes in [measurement-summary.json](measurement-summary.json). Server SHA-256 `62bc791c87bf45f8261bf1599b18c31ca7ba58cdebbabac3b0faf694043b37c9`; TUI SHA-256 `b222496c3e49364c5b13c5a2e2ccf706d715c9c0eae5cf23f9c5450813141320`. Both are Mach-O arm64 with embedded candidate commit. Actual capture/assessment helper SHA is `aad42389b7d6f63802ab8f1d85995b0c101257655a08a787b238da7f32f520d7`. Final helper at `bed1ac6dcb8290ca38c920fb726a93a25fffe460` has SHA `c2b2d21772adee05f559c298f990dbe51811dc95264f485f8fe9bb50cf905c72`; its later missing-Add-on preflight was fixture-tested, not exercised by this live run. Compiled `lib`, `bin`, `test`, `config` and `addons` are unchanged between those commits.
- 확인일시: `2026-10-30T19:54:00.106167+09:00`
- 신뢰도: `High`
- 제한조건: Candidate evidence is not installed-main or rewritten-head evidence. No formal independent approval, installation or merge is implied.

- 항목: Focused CI and native build, including the failed attempt.
- 출처: [Test 41037292864](https://github.com/jeong-sik/masc/actions/runs/41037292864), source `23a1529aa956b7f214b774c946eaba0a42689f5c`, completed/success: provider-input 14, dispatch 5, HTTP 171, TUI 5, total 195 cases. Tested paths are unchanged in compiled candidate 0639. [Minimal manual checks 41037289306](https://github.com/jeong-sik/masc/actions/runs/41037289306) failed compiling the renderer with warning 4. Explicit closed-variant cases fixed it; native retry 41038850459 completed/success at 0639 and produced the verified server/TUI pair. Its four additional suites/exit codes are in the summary.
- 확인일시: `2026-10-30T19:45:43+09:00`
- 신뢰도: `High`
- 제한조건: The 195-case run did not compile the renderer; native retry covers that boundary. Neither is full regression or installed-runtime evidence.

- 항목: Original-history request omission after retained lane restarts.
- 출처: Private `artifacts/temporal-continuity-retirement-20261030/live-03/report.json`, SHA `52ee4a1c602fa58b2fe92258425c2f0acd1658e2957abf9e5ba11aeebce212f2`; selected observations, final W and original reply in the summary. There were 12 successful exact operations/turns, 15 timeline steps, two retained lane restarts and one readiness wait. All 1,272 raw event digests and ordered owner-response joins were revalidated. Target turn 11 has generation start boundary line 2, completed boundary line 12, exclusive end_atom 34. Turn 12 has one attributed prepared request: W end 34, organic first 34, body SHA `6bd1b03c48f8ff7ab73db894aede6a49ea35f6ff8689f57b9e7d56f5e26fdb86`, 88,654 bytes, capture `wr-1a18c6018db-e415-0000`. Its SDK body multiset and last canonical input join. Exact turn record has zero tool invocations.
- 확인일시: `2026-10-30T19:54:00.106167+09:00`
- 신뢰도: `High` for retained local observations/joins.
- 제한조건: Omission concerns attributed organic prepared-request ranges. Durable originals remain. Preparation does not prove remote receipt or body/response binding. Other injected context is not isolated.

- 항목: Librarian bootstrap intervention and semantic observation.
- 출처: W was absent in turns 1–11. At `2026-10-30T19:33:47.173+09:00`, the candidate Add-on was installed into the isolated workspace through ordinary declaration reconciliation; existing unread work drained, the wait completed and turn 12 used W. Candidate package and shared image-worker file hashes were checked. A unique image tag referenced `sha256:ccafc76f0a45817c404e936e654e579f36e97b516d2369f3a6018f246b4b33a7`. Offline assessment SHA `cfaed49c76175a63414c11dcc99d1c3e7ba94d8bb7f29d2a40acec57f3e0fdd5` retains frozen requests/raw responses: 11 measured propositions, actual model `jev-1.14.0`, two earlier W propositions unavailable. Late W probabilities: constraint 0.89, latest investigation 0.92, reconnect rejection 0.94; late reply investigation 0.94. All propositions/values are retained in the summary.
- 확인일시: `2026-10-30T19:54:00.106167+09:00`
- 신뢰도: `High` for recorded identity/data; semantic probabilities are model observations, not retention rates.
- 제한조건: Late bootstrap/catch-up, not steady-state or a matched main/candidate comparison. No direct Librarian invocation, cursor/W edit, context-cap change or destructive history deletion occurred. No probability threshold or continuity pass is used.

- 항목: Actual TUI and production boundary.
- 출처: Actual native 160×48 PTY with the candidate pair above. Assessment view artifact SHA `b626b608759d22112780a18e3498295ed04eff726ce632c431fe075f2973c59d`, 30,871 bytes. [Omission/W](06-retired-probe.png), [original reply/judgments](07-late-answer-and-judgments.png), [provider failure](04-failure-measurement.png) are byte-identical selected PNG copies, manually inspected. Original ANSI/text/receipts remain private. Verified candidate PID 58389 exited 0; its owned Docker worker was removed by the server. Production health before/after cleanup retained binary `bac52cac7934ce3f75c315d474cc23f2561268c9`, executable SHA `21067bda7e1d38de044567a60a3575d7dfee80161ba34630742a4000828aa391` and runtime instance `01a18bc6-19f4-7000-be2c-d9f7a0ade50c`.
- 확인일시: `2026-10-30T19:46:47.210694+09:00` for cleanup/production; frame times retained individually.
- 신뢰도: `High`
- 제한조건: Actual candidate UI observations, not screenshot assertions or production installation. The selected artifact is immutable and does not update automatically.

## 검증 (Verification)

- 1차: Session-separated source review covered serialization attribution, completed boundaries/generations, exact body multiset joins, Admin authorization, import ordering and TUI ownership/decode/render. Reported P2 findings were patched and reread. These are source checks, not formal independent GitHub approval.
- 2차: Final Python HTTP/MCP/assessment fixture suite: 11 tests passed. Pyright zero errors; Ruff lint/format passed. Focused CI 195 cases and native retry are scoped above. Full suite was not run locally.
- 3차: `python3 artifacts/temporal-continuity-retirement-20261030/select_evidence.py` reran `validate_source_capture`, frozen judge request/response checks, compiled-path equality, frame/publication hashes, probe tool count and production identity. Source digests are in the summary. Selected synthetic text and PNGs were inspected. Saved W readiness alone is never promoted to omission evidence.
- 재현 결과: In this campaign, the prepared organic prefix through atom 34 was absent in the late probe. W and the original reply preserved the read-only constraint, both rejected hypotheses, latest notification-order investigation, causal uncertainty and remaining work. `continuity_pass` remains null. W-only causality, remote receipt and a general continuity rate remain unestablished.

## 불확실성 (Uncertainty)

- 미확인 항목: Steady-state scheduling across N…N+M, broader runtimes/scenarios, full server restart, isolated W/Recall/Memory treatments, and matched installed-main comparison.
- 영향: Correct answers and observed organic-prefix omission can coexist with other retained/injected context. Semantic probabilities are evidence to inspect, not a product verdict.
- 추가 확인 필요: Start future retirement campaigns with the Add-on already declared. The final preflight rejects known `addon_unattached` before Keeper creation only for summary-readiness scenarios; it is not a global serving gate.
- 실패 기록: GLM five-hour quota and Ollama Cloud weekly quota blocked the first two distinct Keepers; their original captures remain and the same operations were not resubmitted. The initial offline assessment failed before judging because assignment persistence appended a subtable to a sealed inline `runtime` table. [Issue #46981](https://github.com/jeong-sik/masc/issues/46981) records it. Assessment used only the verified unchanged TypeSafe table from the byte-identical initial config prefix in a separate file. No live config repair or silent exclusion removal occurred.

## 적용범위 (Scope)

- 영향 받는 영역: Keeper diagnostic attribution/read-only Admin export, experimental runner/report/view and existing TUI `/measurement` reader. [Runbook](../../guides/KEEPER-TEMPORAL-CONTINUITY.md) documents lifecycle/reproduction.
- 제약/배제: No production restart/installation, Apple service/guest/volume action, destructive history deletion, forced per-turn Librarian, semantic string matching or runtime probability gate. Memory/Recall/pinned context remain possible contributors.
- 롤백 조건: Candidate identity mismatch or known missing required Add-on refuses creation. Unknown projection, unread holes, changed history generation or missing serialization evidence cannot become observed omission. Readiness timeout ends an incomplete capture before the late probe. No production rollback is required: the dedicated campaign is stopped and its files retained.
