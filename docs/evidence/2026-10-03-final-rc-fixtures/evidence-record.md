# Final RC fixture repair evidence

## 공통 헤더
- 날짜(ISO8601): 2026-10-03T03:05:00Z
- 작성자: Codex root
- 결정 ID: masc-v0490-final-fixtures
- 적용 대상: release/v0.49.0-verified-fixtures-20261003
- 결정 상태: 추적 필요

## 근거 (Evidence)
- 항목: reconcile six remaining behavioral failures before final release verification
- 출처: https://github.com/jeong-sik/masc/actions/runs/37037420526 ; full test-suite-log artifact11243381075
- 확인일시: 2026-10-03T03:05:00Z
- 신뢰도: High
- 제한조건: failed run87573926149e68b3de0d207e6c90159e148bc12c; currentce7 has the same product sources and only notes/base reconciliation changes

## 검증 (Verification)
- 1차: independently reviewed Item/private-account authority, actual chat return/selection, Gate settings readiness, startup-followup scoped ledger and focused chat exit components. Source fixes were already present in final preparationce7; this recut changes fixture contracts and release notes only.
- 2차: native macOS ARM artifact11240978742 source875; TUI SHA25698c4727ba2d242bb0d80b709dcc4ff970babe0234a1ff411bfd30779946e8924 matches native-preflight.json. Diff checks pass; Ruff reports only pre-existing scoped unused re and remote two E701 diagnostics; metadata Pyright0; scoped remains101, remote244 and Item12 baseline Pyright diagnostics; shared keyboard remains57 baseline diagnostics. Other existing fixture diagnostics are compared separately, not represented as a clean repository type check.
- 3차: full latest875native Item, scopedHome8, metadata and Chat clarity suites pass. Root general suite passes on b996native, whose inspected cursor/visibility product consumers are unchanged in this scope. Latest875native live identity chat/pause/boot-recovery scenarios pass; remote Schedule, Ask and GitHub focused replays pass after observing their actual refusal surfaces and avoiding redundant Escape; full remote replay is pending. No-write and stale-response assertions are unchanged.
- 재현 결과: latest failed RC and old compiled artifact support fixture root causes; current final integrated SHA still requires full compilation/behavior/installation verification. No local Dune run or test exclusions.

## 불확실성 (Uncertainty)
- 미확인 항목: exact final integration Full RC, independent Release approval, tag/publication and live installation
- 영향: old native replays cannot authorize publication
- 추가 확인 필요: explicit final-head Full RC and completion readback at a work boundary; no watch/poll loops

## 적용범위 (Scope)
- 영향 받는 영역: remaining RC fixture failures and factual release notes
- 제약/배제: no runtime writes, current server stop, tag or main merge. Existing latest published releasev0.48.0. Livehealth8935 reports existing0.49.0 binary83d23c96c01f2505fe0bad39c699b330a3f9df93 under/Users/dancer/me/.masc, distinct from candidate.
- 롤백 조건: any failed exact-head Full RC prevents publication. Read-only full deployment preflight using installedhelper stops at currently owned writer leasepid49101; repeat with final artifact at authorized replacement boundary, without changing live data to evade validation.

## Supplemental local evidence

Raw full CI log/native provenance under/tmp/masc-rc-37037420526; replays/tmp/masc-chat-latest-fixed.log,/tmp/masc-metadata-latest-fixed.log,/tmp/masc-scoped-ledger-full-latest.log,/tmp/rc-875-item-public.log,/tmp/rc-875-live-identity.log. Immutable original artifact/run remains linked above. Source support PRs40851,40852,40853,40854. Two independent reviewers passed all composition and supplemental tuple/remote deltas. Unrelated stale Ask action footer recorded at https://github.com/jeong-sik/masc/issues/40856.
