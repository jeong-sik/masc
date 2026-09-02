# Constitution ↔ Code 정합성 매트릭스

- 생성: 2026-08-20 (14개 영역 스웜 검증 기반)
- Goal verifier 갱신: 2026-08-21 (#29221, #29240 병합 기준)
- 상태 값: `대기` / `진행중` / `완료` / `보류`
- 방향: `문서←코드` (코드에 있고 문서에 없음, 문서 보충) / `코드←문서` (문서에 있고 코드에 없음, 코드 구현) / `코드 정리` (헌법 위반 잔여 제거)

## A. 문서 보충 (코드가 앞서 나감)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| A1 | reclaim claim gate 폐지 (RFC-0323). reclaim_policy는 claim을 막지 않고 release/cancel 데이터 파이프라이닝 용도 | `workspace_task_claim.ml:103-104`, `types_core.ml:654-659` | PR #29140 |
| A2 | karma 예외: 자기투표·삭제 콘텐츠는 이벤트 미생성. "upvote 1건당 1건" → "타인 콘텐츠 upvote당 1건"으로 정정 | `board_votes.ml:904-907,921` | PR #29140 |
| A3 | karma ledger는 비영속, vote_log에서 재구축. delta 보존은 wire 계약 수준 | `board_votes.ml:924-932` | PR #29140 |
| A4 | AwaitingVerification 재시도: 지수 backoff가 아니라 고정 간격 + `retryable` boolean + 전역 동시성 세마포어 | `completion_authority_agent.ml:296-319,619-626,658` | PR #29140 |
| A5 | Fusion 구현 확장: `Bridge_error`/`Invalid_max_output_tokens`/`Invalid_timeout_s` variant, `web_tools` 필드, topology 확장(RFC-0283/0284) | `fusion_types.ml:64-71,329-338` | PR #29140 |
| A6 | RFC 경로 표기: `docs/rfc/` (설계서의 `docs/rfcs`는 오기) | — | PR #29140 |
| A7 | keeper.env는 OCaml 런타임이 읽지 않음. `scripts/deploy.sh` 전용 API 키 env 파일 | `deploy.sh:125`, lib/ 참조 0건 | PR #29140 |
| A8 | 명칭 매핑 정리: Cross-Verification→`verifier_exact` exact-output lane, GithubCredential→`keeper_github_identity`, CoT→thinking trajectory, MultiTurn→stream bridge | `runtime_toml.ml:1314`, `keeper_github_identity.ml` | PR #29140 |
| A9 | Goal drop 사유는 전용 필드 없이 공용 `note` | `workspace_goals.ml:399` | PR #29140 |
| A10 | visibility 시맨틱은 타입 강제가 아니라 docstring 선언 ("enforced by callers") | `board_types.mli:7,72-76` | PR #29140 |

## B. 코드 보충 (문서가 앞서 나감 — 미구현 주장)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| B1 | Goal 생성 시 정량 성공조건 필수화 — 생성 경로가 non-blank `metric`+`target_value` 요구 | `goal_store.mli`, `workspace_goals.ml` | PR #29152 |
| B2 | Goal Verifier 검증 게이트 — 생성 시 `Criterion_pending` durable 기록, `request_complete` 시 `Proof_pending` 기록과 `Verifying` 진입 | `lib/goal/goal_verification.ml`, `lib/workspace_goals.ml` | #29152, #29221 병합 |
| B3 | Goal 완료 = 독립 Verifier의 proof proven — 공개 lifecycle API에서 verifier verdict 제거, 고정 `verifier_exact` typed authority만 `Completed` 전이 가능. 인간 최종 확인/`Awaiting_confirmation`은 현행 계약이 아님 | `lib/goal/goal_phase.mli`, `lib/workspace_goals.ml`, RFC-0387 | #29240 병합 |
| B4 | ParallelTool — read 툴 4종 Concurrent 승격 + fail-closed admission (fan-out 엔진은 기존 `Agent_tool_batch_plan`이 커버) | `keeper_tool_descriptor.ml` | PR #29146 |
| B5 | 스트리밍 문자열 의미 — 일반 `TextDelta`는 append-only이며, producer가 명시한 `TextSnapshot`만 canonical state에서 suffix/replay를 정규화한다. 실제 비준수 endpoint capability 연결은 #30782에서 추적한다. | `packages/agent_core/lib/llm_provider/complete_stream_state.ml` | PR #29149, #30782 |
| B6 | tool_kind 닫힌 합타입 선언 (실행 기계는 기존 plan IR/executor가 커버) | RFC-0386, `keeper_tool_descriptor.mli:69-82` | PR #29148 |
| B7 | Goal Verifier standalone worker — durable criterion/proof pending ledger를 `verifier_exact` lane으로 drain하고 typed verifier boundary에 verdict를 commit. artifact lookup surface와 live 동일-run 증거는 후속 | `lib/goal_verification_agent.ml`, `lib/workspace_goals.ml`, RFC-0387 | #29221, #29240 병합; live 증거 대기 |

## C. 코드 정리 (헌법 금지 패턴 잔여)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| C1 | 연속 실패 예산 숫자 게이트 (3, 5) — crash accounting 전환 | `keeper_unified_turn_failure.ml` 에 threshold 없음 (2026-09-02 재확인, RFC turn-failure-visible-stop #32105) | 완료 |
| C2 | 반복 툴 호출 threshold=3 → 턴 yield. 2026-09-02 재확인: tool 축(`:156`)에 assistant-text 축(`:169`)이 더해져 둘. 둘 다 "입력+출력 지문 동일" typed 조건 위의 count 이며 예외 주석을 달고 있다. #32472 배포 24h 뒤 `yielded_after_repeated_*` 발화 비중을 재서 제거 여부를 정한다 | `keeper_agent_run.ml:156,169,215,244` | 재측정 대기 |
| C3 | `"SKIP:"` 접두사 문자열 매칭으로 turn_mode 분류 | `keeper_unified_metrics_support.ml` 에 `"SKIP` 리터럴 없음 (2026-09-02 재확인) | 완료 |
| C4 | provider 에러 detail 자유 텍스트 접두사 검사 — 뿌리는 agent_core 가 typed `stop_reason` 을 문자열로 납작하게 만든 것 | `Llm_provider.Error.EmptyCompletion` variant 로 재타입, `keeper_error_classify.ml` 은 variant 매치 | PR (empty-completion-is-a-variant) |

## D. SSOT 문서 stale (RFC-0252 갱신)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| D1 | `per_hour_budget`/`Over_hourly_budget` 제거 미반영 (PR #22051) | `fusion_types.ml:340-344` | PR #29142 |
| D2 | `Budget_exhausted` variant, `confidence` 필드, `max_fibers` 다이어그램 잔재 | `docs/rfc/RFC-0252` §4-5 | PR #29142 |

## 요약

| 구분 | 건수 | 상태 |
|---|---|---|
| A. 문서 보충 | 10 | PR #29140 |
| B. 코드 보충 | 7 | B1-B3 및 B7 source 구현 병합; B4 #29146 / B5 #29149 / B6 #29148. Goal verifier artifact lookup·배포·동일-run 증거는 대기 |
| C. 코드 정리 | 4 | C1·C3 완료, C4 typed PR, C2 는 재측정 뒤 판정 |
| D. RFC stale | 2 | PR #29142 |
| 후속 검증 | — | Goal verifier artifact lookup surface, 실제 배포, ledger/event/browser 동일-run 증거는 living matrix의 미완료 셀로 추적 |
