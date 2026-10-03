# v0.49.0 RC failure repair evidence

## 공통 헤더

- 날짜(ISO8601): 2026-10-02T10:13:00Z
- 작성자: Codex root
- 결정 ID: masc-v0490-rc36977593924-repair
- 적용 대상: release/v0.49.0-repair-20261002
- 결정 상태: 추적 필요

## 근거 (Evidence)

- 항목: repair the failed behavioral RC and verify a new frozen candidate before publication
- 출처: https://github.com/jeong-sik/masc/actions/runs/36977593924 ; `gh run view 36977593924 --json jobs,headSha`; artifact11215911917 full test-suite.log
- 확인일시: 2026-10-02T10:13:00Z
- 신뢰도: High
- 제한조건: failed run atddefaf49506633619afb79f43ef5137c82063381; compile and installation passed, behavior failed33 suites

## 검증 (Verification)

- 1차: source and producer/consumer inspection with independent subagent reviews. Selected source heads:40812@3a67d8a05a5f933d47b174971387577d607e66a1,40820@a65d10bd99ea63d0dd283d5994836484c80cced5,40829@daaf0c970510e51ba1a4d31c92252f247ecef0f0,40831@d0efe1bc13348b93c3dfe002c9c7bb4669c0fcd9,40833@99006c7f83750a52d7f83e56bbb4db1076b52190,40834@11c2ac7467582e4327556177894024e259b3c6a1,40838@0f965018b2.
- 2차: native RC macOS ARM TUI SHA256b70afc6772a393584544bedce226ddef9076b91039227779387ab1a3472b7b95 matches artifact provenance. Python lint and whitespace checks pass for root changes. Existing shared fixture Pyright errors57/27/4 have no added diagnostic messages. No local Dune build performed.
- 3차: exact failed-RC binary replay passes repaired Workspace, Answering, Client/Connector, Chat clarity, Tools identity, Dashboard first-use and recorded-HTTP equipped portrait scenarios. Subagents additionally observed Activity, Task metadata, remote task withdrawal, chat safety, Metrics, Candle9, foreign Home4 and scoped Home8 scenarios pass on the same identified RC binary. This is fixture PTY evidence, not new-source or production evidence.
- 재현 결과: repaired typed Librarian capacity and Candle refusal handling, local chat draft/original-root retention, authoritative Item revision admission/completion, chat progress/span preservation and narrow Work backlog wrapping. New compiled-source behavior remains unverified until the exact integrated head's Full RC completes.

## 불확실성 (Uncertainty)

- 미확인 항목: complete Full RC on the final integration head, independent Release approval, publication and live installation. Item and Home failure source repairs need the new artifact.
- 영향: no tag or published release is authorized by old fixture replays or source PASS.
- 추가 확인 필요: inspect the exact new run at a work boundary; if successful obtain exact-head Release review and run normal release/publication/deployment preflight. Do not weaken tests or change timeouts if RC fails.

## 적용범위 (Scope)

- 영향 받는 영역: RC behavioral failures and their source/fixture consumers, release notes and isolated integration.
- 제약/배제: main and canonical release/v0.49.0-recut-12z unchanged. No live data rewrite, stop/restart or tag performed. Public latest release remainsv0.48.0. Read-only live health currently reports an existing0.49.0 binary6458f92ef3d407bd9bacfbfcf25548c06fb0be27; it is not this candidate.
- 롤백 조건: failed or cancelled exact-head Full RC prevents publication and live replacement. Read-only schedule validation on both current live ledger files passes with failed-RC helperddefaf; repeat full deployment preflight with the final verified artifact and stopped writers where required.

## Local artifacts

Raw failed job/artifact logs, native provenance, receipt replays and type-check comparisons are retained under `/tmp/masc-rc-36977593924/`. These local files are supplemental; the immutable original RC logs/artifacts remain at the run URL above.
