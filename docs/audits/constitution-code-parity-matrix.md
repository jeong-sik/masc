# Constitution ↔ Code 정합성 매트릭스

- 생성: 2026-08-20 (14개 영역 스웜 검증 기반)
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
| A8 | 명칭 매핑 정리: Cross-Verification→`cross_verifier` lane, GithubCredential→`keeper_github_identity`, CoT→thinking trajectory, MultiTurn→stream bridge | `runtime_toml.ml:1314`, `keeper_github_identity.ml` | PR #29140 |
| A9 | Goal drop 사유는 전용 필드 없이 공용 `note` | `workspace_goals.ml:399` | PR #29140 |
| A10 | visibility 시맨틱은 타입 강제가 아니라 docstring 선언 ("enforced by callers") | `board_types.mli:7,72-76` | PR #29140 |

## B. 코드 보충 (문서가 앞서 나감 — 미구현 주장)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| B1 | Goal 생성 시 정량 성공조건 필수화 (현재 `metric`/`target_value`는 option) | `goal_store.mli:41-42`, `workspace_goals.ml:238-248` | 대기 |
| B2 | Goal Verifier 검증 게이트 (생성 시 실재성·도달가능성 체크) — goal 경로에 verifier 와이어링 전무 | `lib/goal/` | 대기 |
| B3 | Goal 완료 = Verifier 증명 + 인간 최종 확인 (현재 `Request_complete → Completed` 즉시 전이) | `goal_phase.ml:132` | 대기 |
| B4 | ParallelTool 실행 모듈 (현재 `disable_parallel_tool_use` 억제 플래그만 존재) | `keeper_context_core_accessors.ml:61` | 대기 |
| B5 | 스트리밍 문자열 dedup (현재 텍스트 델타 pass-through) | `keeper_chat_agent_core_stream_bridge.ml:255-261` | 대기 |
| B6 | Batch/Multitool 실행 개념 (tool 타입 부재) | `keeper_tool_composition_catalog.ml` | 대기 |
| B7 | Verifier를 keeper급 standalone agent로 (현재 프로토콜+도구 수준) | `keeper_unified_metrics_support.ml:400` | 대기 |

## C. 코드 정리 (헌법 금지 패턴 잔여)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| C1 | 연속 실패 예산 숫자 게이트 (3, 5) — crash accounting 전환 | `keeper_unified_turn_failure.ml:14,26,43,62` | PR #29141 |
| C2 | 반복 툴 호출 threshold=3 → 턴 yield 직접 결정 | `keeper_agent_run.ml:135,165,776` | PR #29141 |
| C3 | `"SKIP:"` 접두사 문자열 매칭으로 turn_mode 분류 (dead branch 추정) | `keeper_unified_metrics_support.ml:347` | PR #29141 |
| C4 | provider 에러 detail 자유 텍스트 접두사 검사 잔여 (RFC-0371 §3.7 인정됨) | `keeper_error_classify.ml:172` | PR #29141 |

## D. SSOT 문서 stale (RFC-0252 갱신)

| ID | 항목 | 근거 | 상태 |
|---|---|---|---|
| D1 | `per_hour_budget`/`Over_hourly_budget` 제거 미반영 (PR #22051) | `fusion_types.ml:340-344` | PR #29142 |
| D2 | `Budget_exhausted` variant, `confidence` 필드, `max_fibers` 다이어그램 잔재 | `docs/rfc/RFC-0252` §4-5 | PR #29142 |

## 요약

| 구분 | 건수 | 상태 |
|---|---|---|
| A. 문서 보충 | 10 | PR #29140 |
| B. 코드 보충 | 7 | 진행중 (B1-B3/B4/B5/B6 에이전트 작업 중, B7은 B1-B3 후속) |
| C. 코드 정리 | 4 | PR #29141 |
| D. RFC stale | 2 | PR #29142 |
| PR 열림 | 16 / 23 | B 그룹 7건 남음 |
