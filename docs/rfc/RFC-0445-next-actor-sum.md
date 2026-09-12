---
rfc: "0445"
title: "'deferred' 대신 다음 행위자를 말한다 — 누가 다시 움직이는지가 닫힌 합으로 기록에 남는다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0127", "0136", "0356", "0444", "0446", "0448", "0449", "turn-failure-visible-stop"]
implementation_prs: []
---

# RFC-0445: 'deferred' 대신 다음 행위자를 말한다 (next-actor-sum)

## 0. Summary

지금 masc 는 "나중에 된다" 를 `deferred` 한 단어로 적는다. 생산자가 9곳이고 뜻은 4가지다.
런타임이 60초 뒤 다시 보는 것, 운영자가 keeper 를 켜야 하는 것, 아무도 다시 안 보는 것,
거절인데 이름만 deferred 인 것이 같은 글자로 로그·대시보드·Board 에 나온다.

이 RFC 는 닫힌 합 하나를 둔다.

```
next_actor = Runtime_will_retry of retry_when
           | Operator_must_act of operator_action
           | Nobody_will_retry of stop_reason
           | Rejected of rejection
```

"deferred" 라는 wire 문자열과 로그 단어는 사라진다. 모든 표면은 생성자 이름을 찍는다.

관계: RFC-0127(종료 provenance) 을 **확장**한다 — 0127 은 *왜* 끝났는지를 typed 로 실었고, 이 RFC 는
*누가 다음에 움직이는지*를 싣는다. RFC-turn-failure-visible-stop 을 **확장**한다 — 실패를 상태로
보이게 한 것처럼 실패 뒤의 행위자도 상태로 보인다. 재시도 예산은 여기서도 만들지 않는다.
RFC-0136 을 **확장**한다 — `keeper_unified_turn_types` 의 실패 레코드에 필드가 붙는다.
RFC-0356(승인이 효과를 소유한다) 과는 **충돌하고 해소**한다 — 0356 은 승인된 효과를 서버가
실행한다고 했지만 keeper 가 manual 이면 실행할 주체가 없다. 그 경우를 `Operator_must_act` 로
승인자에게 돌려준다 (결정 1).

PR #35354(`stop_cause`) 와 #35352(`stall_disposition`) 는 이 합의 앞선 조각이다. §2.4 에서 두 타입이
어떻게 접히는지 적는다. 어휘가 둘이 되지 않는다.

같은 날 초안인 형제 RFC 넷이 이 합을 쓴다. RFC-0448(manual keeper durable demand) 은 대기 항목마다
`next_actor` 를 붙이는데 자기 합을 따로 두지 않고 이 타입을 쓴다 (§2.5). RFC-0449(hard-quota 402 rotation) 는
`Operator_must_act (Provider_quota)` 만 가져간다. RFC-0446(contract-absent submit refusal) 의 거절은
`Rejected (Contract_absent)` 로 들어온다. RFC-0444(goal store typed unavailable) 는 이 합과 무관하다 — 부팅 상태이지
행위자가 아니다. Codex 순서(`rfc_order[1]`)대로 이 RFC 가 먼저 머지되고 나머지가 이 타입을 읽는다.

## 1. 배경 (실측)

09-08..09-12 UTC 로그 620,735줄과 main `19efff1d47` 기준. 상세는 §6.

| 자리 | 지금 찍히는 말 | 실제 뜻 | 건수 |
|---|---|---|---|
| L1 완료 판정자 | `completion authority deferred` WARN | 219건은 아무도 다시 안 봄, 67건은 60초마다 재시도 | 286 |
| L5 broadcast mention | `delivery deferred` ERROR | 분마다 재시도, 만료 없음, 6h 뒤 `rejected`. 둘 다 '미정착' 이라 fleet 투영이 영영 안 돎 | 359 → 1 |
| L6 HITL 결과 신호 | `signal=deferred_unregistered` INFO | 승인은 됐고 keeper 가 안 떠서 아무도 적용 안 함. 부팅마다 재생 52회 | 148 |
| L11 스케줄 dispatch | `dispatch=failed error=retryable …shutdown fence` WARN | 부팅 없인 안 풀리는 fence 를 15초마다 'retryable' 로 | 10,446 |
| L8 turn 실패 | `deferred_next_runtime=none` | 형제 없음·힌트 없음·suffix 소진·형제도 막힘 넷을 한 글자로 | 2,886 / 3,404 |
| U1 MCP producer 거절 | `completion repair remains pending` ERROR | producer 가 keeper 가 아니라 깨울 수 없음. 영원히 pending | 9 task, 2,057줄/일 |
| U2 Board | "review will not retry" | 21쌍 중 18쌍이 60초 뒤 재시도, 18쌍 판정 확정 | 27 post |

공통점: 타입은 상류에 있다(`process_outcome`, `wakeup_outcome`, `mention_delivery`, `dispatch_status`).
소비자가 문자열로 납작하게 만들면서 "누가 다음에 움직이는가" 가 사라진다.

## 2. 설계

### 2.1 타입 (lib/types/next_actor.ml)

```ocaml
type actor =
  | Runtime of subsystem           (* Completion_authority | Broadcast_outbox | Schedule_runner
                                      | Keeper_cycle of keeper_name | Approval_queue *)
  | Operator
  | Producer of producer           (* Keeper of keeper_name | Mcp_session of agent_id *)

type retry_when =
  | After_interval of { interval_sec : float; slot : runtime_id option }   (* 완료 판정자의 retry_interval_sec *)
  | Next_keepalive_cycle of { keeper : keeper_name; blocked_by : cycle_block option }
  | Next_reconciliation_tick of { outbox : outbox_id }
  | When_predecessor_settles of { request_id : string; seq : int }

and cycle_block =
  | Owner_lane_held of { holder_lane : lane; since : float; deferral_count : int }  (* 결정 5: 표시만 *)
  | Durable_checkpoint_observed

type operator_action =
  | Start_keeper of { keeper : keeper_name; mode : Manual }
  | Resume_keeper of { keeper : keeper_name; phase : Keeper_state_machine.phase }
  | Finalize_shutdown of { keeper : keeper_name
                         ; operation_id : Keeper_shutdown_types.Operation_id.t
                         ; since : float }                  (* Blocked fence 가 부팅을 넘겼다 *)
  | Fix_keeper_record of { keeper : keeper_name; detail : string }
  | Repair_verification_root of { path : string; stage : Verification_run_registry.infrastructure_stage }
  | Commit_hitl_verdict of { task_id : string; verification_id : string }
  | Provider_quota of { provider : provider_id; lane : lane }     (* 생성자 자리만. 내용은 RFC-0449 *)

type stop_reason =
  | Verdict_rejected of { verification_id : string; reason : string; delivered_via : Task_record }
  | Verdict_not_reviewed of { gate : string; detail : string }
  | Commit_failed of { detail : string }
  | Authority_raised of { detail : string }

type rejection =
  | Mention_target of Workspace_broadcast.mention_delivery_rejected
  | Schedule_owner_absent of { schedule_id : string }
  | Schedule_lifecycle_denied of Keeper_lifecycle_admission.autonomous_denial
  | Contract_absent of { task_id : string }                       (* RFC-0446 의 거절 *)

type t =
  | Runtime_will_retry of retry_when
  | Operator_must_act of operator_action
  | Nobody_will_retry of { reason : stop_reason; recipient : producer }
  | Rejected of { reason : rejection; sender : actor }
```

Codex 가 못 박으라 한 다섯 가지:

- **소유(ownership)**: 생성자가 곧 소유자다. `Runtime_will_retry` 는 `retry_when` 이 이름 댄 subsystem,
  `Operator_must_act` 는 운영자, `Nobody_will_retry` 는 `recipient`, `Rejected` 는 `sender`. `actor` 를 따로
  저장하지 않는다. 파생값이다.
- **자동 재시도 트리거**: `retry_when` 네 생성자뿐이다. 시각·사이클·tick·선행 요청 넷 중 하나를 이름 댄다.
  "곧" 은 없다. 횟수 상한도 없다 (budget_gate).
- **운영자 행동**: `operator_action` 은 행동과 대상을 함께 든다. 표면은 이 값에서 안내 문장을 만든다.
  `Start_keeper` → `masc_keeper_up`, `Commit_hitl_verdict` → `masc_transition`. 문장을 상수로 두지 않는다.
- **종결(terminal disposition)**: `Nobody_will_retry` 와 `Rejected` 는 런타임에게 끝이다. 레코드는 지우지 않고
  대상도 소비하지 않는다 (failure_keeps_evidence). 닫히는 길은 새 사건(재제출·새 요청)뿐이다. 시간으로 닫히지
  않는다.
- **재생 identity**: `next_actor` 는 그것이 붙은 레코드의 키(verification_id / request_id+seq / approval_id /
  occurrence_id / cycle_id) 로 식별한다. 부팅 재생이 같은 키에 같은 생성자를 계산하면 **아무것도 쓰지 않는다** —
  로그 줄도, audit 행도, Board post 도. 생성자가 바뀔 때만 사건이다.

### 2.2 생산자 → 저장 → 소비자 → 호출자

| 자리 | 생산자 (file:function) | 저장 | 소비자 | 호출자에게 |
|---|---|---|---|---|
| 완료 판정 | `completion_authority_agent.ml:process_task` | `Verification_run_registry` 행에 `next_actor` | 로그 템플릿, Board stalled post, dashboard verification-runs, TUI Task Review, producer 관측 fragment(S6) | `masc_tasks` 행의 `verification.next_actor` |
| MCP producer 거절 | `completion_authority_wakeup.ml:wake_rejected_producer` | `Workspace_task_rejection_outbox` 항목 | reconcile 로그, verify queue | `masc_check` / `masc_messages` 결과에 호출자 identity 앞 `verification_rejections` |
| broadcast mention | `workspace_broadcast.ml:durable_delivery_status` | `mention_delivery` 옆 `next_actor` | outbox reconciliation 로그, dashboard message row | `masc_broadcast` 결과 |
| HITL 신호 | `keeper_approval_queue.ml:signal_resolution_after_commit` | delivery record (`grant_consumed` 옆) | 로그, dashboard/TUI approval detail | approve 를 부른 도구 결과 |
| 스케줄 dispatch | `server_schedule_consumers.ml:dispatch` | `schedule_runner.dispatch_status` payload | `schedule_runner` 로그, `masc_schedule_list` | `masc_schedule_create` 결과 |
| turn 실패 | `keeper_unified_turn_types.ml:keeper_cycle_failed_runtime_attribution` | cycle failed 레코드 | `keeper cycle FAILED` 로그, dashboard keeper card, TUI mark | — |

매핑 규칙 (모두 exhaustive match, 두 번째 어휘 없음):

- `process_outcome`: `Retryable_deferred {slot}` → `Runtime_will_retry (After_interval {retry_interval_sec; slot})`.
  `Deferred (Infrastructure_unavailable stage)` → `Operator_must_act (Repair_verification_root)`.
  `Deferred (Not_reviewed gate)` → `Nobody_will_retry {Verdict_not_reviewed; recipient = producer}`.
  `Deferred Commit_failed | Deferred Raised` → `Nobody_will_retry`. `Operator_routed` → `Operator_must_act (Commit_hitl_verdict)`.
- **MCP producer (U1)**: `producer` 는 제출 시점에 `Keeper | Mcp_session` 으로 typed. `Mcp_session` 이면
  거절 전달 채널은 task record 자체다(이미 `handoff_context` 에 쓴다). outbox 항목은 그 write 가 commit 되는 순간
  acknowledge 된다. 결과는 `Nobody_will_retry {Verdict_rejected {delivered_via = Task_record}; recipient = Mcp_session id}`.
  회수 계약: `masc_tasks` 행과 `masc_check` 결과가 그 identity 의 미열람 거절을 싣는다. 열람 표시는 그 producer 의
  다음 `submit_for_verification`(새 verification_id 가 대체) 이다. 책임 행위자는 producer 다. 운영자 화면에는
  "rejected · producer <id> (MCP)" 로 보이고 repair 의무는 남지 않는다. `Unroutable_producer` 생성자는 지운다 —
  producer 종류가 typed 이면 도달 못 할 arm 이다.
- `wakeup_outcome` (HITL): `Deferred_unregistered` → `Operator_must_act (Start_keeper Manual)` (결정 1).
  `Deferred_not_running phase` → `Operator_must_act (Resume_keeper)`. `Deferred_lifecycle d` → `Rejected (Schedule_lifecycle_denied d)`.
  approve 도구 결과가 이 값을 그대로 돌려준다. 부팅 재생은 §2.1 의 identity 규칙을 따른다 — 52행이 1행이 된다.
- `mention_delivery`: `Deferred Predecessor_pending` → `Runtime_will_retry (When_predecessor_settles)`.
  `Deferred (Handler_unavailable | Intake_store_unavailable | Workspace_status_unavailable | Handler_failed | Recovery_unavailable)`
  → `Runtime_will_retry (Next_reconciliation_tick)`. `Deferred Target_state_unavailable` 은 스캔이 keeper 하나에서
  멈춰서 생긴다 — `persisted_keeper_for_mention_target` 이 오류를 모으며 끝까지 스캔하고, 대상이 없으면 `Rejected`,
  대상은 있는데 다른 keeper 레코드가 깨졌으면 `Operator_must_act (Fix_keeper_record)`. `Rejected` 에서도 fleet
  투영은 돈다(알림은 mention 이 아니다). `expires_at` 은 그대로 `None`.
- `dispatch`: `Keeper_wake_activation_not_running` → `Operator_must_act (Resume_keeper)`.
  `unregistered | autoboot_disabled` (manual) → `Operator_must_act (Start_keeper)` + 스케줄당 pending 1건, 나머지는
  `Superseded` 기록 (결정 5). `owner_absent` → `Rejected (Schedule_owner_absent)` (Q3 종결). `lifecycle_denied` → `Rejected`.
  `Intake_shutdown_reserved op` → `Operator_must_act (Finalize_shutdown {keeper; operation_id = op; since})`.
  fence 는 tick 마다 다시 두드릴 것이 아니다. 실측(Q5/B2)에서 이 fence 를 푼 것은 15초 재시도 10,446회가 아니라
  운영자의 TUI 부팅 한 번이었다. 스케줄은 RFC-0448 의 `Paused` 로 가고 이 값이 그 사유다. `since` 는 fence 가
  처음 관측된 시각이라 33h 가 표면에 보인다. Blocked fence 에 종료 분기(Finalize | Resume)를 두는 일은 별도 RFC
  (synthesis §5 "셧다운 lifecycle vs 스케줄러 계약", 아직 번호 없음) 의 몫이고, 이 생성자는 그 진입점만 가리킨다.
  `server_schedule_consumers.ml:1213` 의 `| _ -> Ok ()` 는 사라진다. `Retryable_dispatch_failure of string` 은
  `Dispatch_blocked of next_actor` 가 된다.
- `deferred_next_runtime_id : string` → `next_runtime = Next of runtime_id | No_sibling | No_hint_for of wire_kind
  | Suffix_exhausted | Sibling_blocked of {runtime_id; route_class}`. cycle failed 레코드의 `next_actor` 는
  `Next _ | No_sibling | Suffix_exhausted` 모두 `Runtime_will_retry (Next_keepalive_cycle)` — 재시도 권한은 레인에
  있고 Failing 상태가 보인다(turn-failure-visible-stop). `Hard_quota` 만 `Operator_must_act (Provider_quota)`.
  `reported_runtime_id` 는 시도 목록의 마지막 후보에서 가져온다(L3).
- `Tool_result.disposition` 의 `Deferred of 'deferred` 는 `Pending_output of 'pending` 으로 이름을 바꾼다.
  뜻이 "출력이 나중에 온다" 이지 행위자가 아니다. `dashboard/src/sse.ts:504` 의 `' DEFERRED'` 는 `' PENDING OUTPUT'`.
- "Keeper Owner deferred autonomous work" 와 "same-run runtime retry deferred" 는
  `Runtime_will_retry (Next_keepalive_cycle {blocked_by = Some (Owner_lane_held | Durable_checkpoint_observed)})`
  한 줄로 접힌다. 점유 시각과 연기 횟수는 값에 실려 표시된다. 상한은 없다.

### 2.3 표면별 라벨

| 생성자 | 로그 (`next=`) | dashboard chip | TUI mark | Board 문장 | MCP tool result |
|---|---|---|---|---|---|
| `Runtime_will_retry` | `Runtime_will_retry{After_interval sec=60.0 slot=…}` | `재시도 예정 · 60s` / `다음 사이클 · 점유 2h13m` | `R` + 남은 조건 | "retry scheduled: <when>" | `{"next_actor":"runtime_will_retry","when":{…}}` |
| `Operator_must_act` | `Operator_must_act{Start_keeper sangsu}` | `운영자 조치 · sangsu 시작` (붉은 칩) | `O` + 행동 | "operator: start keeper sangsu (masc_keeper_up)" | `{"next_actor":"operator_must_act","action":{…}}` |
| `Nobody_will_retry` | `Nobody_will_retry{Verdict_not_reviewed gate=…}→producer=…` | `종결 · producer 재제출` | `S` | "stopped: <reason>. producer <id> owns the next move" | `{"next_actor":"nobody_will_retry",…}` |
| `Rejected` | `Rejected{Schedule_owner_absent}` | `거절 · <reason>` | `X` | "rejected: <reason>" | `{"next_actor":"rejected",…}` |

로그 레벨: `Runtime_will_retry` INFO(첫 계산 1회), 나머지 셋 WARN(생성자 변경 시 1회). routine/Debug 강등 없음.

### 2.4 #35354 · #35352 접기

- `stop_cause` (#35354: `Infrastructure_unavailable | Commit_failed | Not_reviewed | Raised`) 는 없애지 않고
  `next_actor` 의 **payload** 가 된다 — 위 매핑에서 `Repair_verification_root` 와 `stop_reason` 이 그것이다.
  `stopped: <cause>; producer or operator must act` 템플릿은 `next=<생성자>` 하나로 바뀐다.
- `stall_disposition` (#35352: `Retry_scheduled | Terminal`) 은 `next_actor` 의 **투영**이다.
  `Runtime_will_retry _ → Retry_scheduled`, 나머지 → `Terminal`. 타입은 삭제하고 Board metadata `disposition` 필드
  값은 생성자 라벨이 된다. 중복 판정 키도 그 라벨이다. 저장은 한 곳, 어휘는 하나.

### 2.5 형제 RFC 의 어휘 접기

RFC-0448 초안은 `next_actor = Operator_boot | Operator_resume | Shutdown_finalize | Operator_fix_profile | Nobody`
를 자기 합으로 적었다. 두 합이 같이 머지되면 어휘가 둘이다. 이 RFC 의 타입이 그 자리에 들어간다.

| RFC-0448 초안 생성자 | 이 RFC 의 값 |
|---|---|
| `Operator_boot k` | `Operator_must_act (Start_keeper {keeper = k; mode = Manual})` |
| `Operator_resume k` | `Operator_must_act (Resume_keeper {keeper = k; phase})` |
| `Shutdown_finalize op` | `Operator_must_act (Finalize_shutdown {keeper; operation_id = op; since})` |
| `Operator_fix_profile k` | `Operator_must_act (Fix_keeper_record {keeper = k; detail})` |
| `Nobody` (Reject 는 terminal) | `Rejected {reason; sender}` — 무엇이 거절했는지가 값에 남는다 |

RFC-0448 의 `durable_demand.next_actor` wire 필드는 §2.3 의 MCP tool result 인코더를 그대로 쓴다.
RFC-0449 의 `masc_keeper_status.quota_held` 는 `Operator_must_act (Provider_quota)` 를 같은 인코더로 낸다.
RFC-0446 의 거절은 `Rejected (Contract_absent {task_id})` 로 `masc_transition` 결과에 실린다.
셋 다 이 RFC 의 PR-1 이 머지된 뒤에만 필드를 낸다.

## 3. 판정 기준

- `rg '"[^"]*deferred[^"]*"' lib bin --type ocaml` = 0 (지금 120). `dashboard/src` 비테스트 파일 `deferred|DEFERRED` = 0 (지금 78).
- `rg 'deferred_next_runtime=none' lib` = 0. 09-08..09-12 재생 시 `keeper cycle FAILED` 3,404줄 전부 `next=` 를 갖는다.
- `rg '\| _ -> Ok \(\)' lib/server/server_schedule_consumers.ml` = 0.
- `rg 'Unroutable_producer' lib` = 0. 재현 fixture: Mcp_session producer 의 REJECT 1건 → `completion repair remains pending` 0줄, outbox pending 0, task record 에 `next_actor=Nobody_will_retry`.
- 부팅 2회 사이 같은 approval_id 의 audit `Resolved` 행 증가 0 (지금 부팅당 +1). 테스트: 같은 키·같은 생성자 재계산 → 쓰기 0.
- broadcast fixture: 대상 없는 mention 1건 → `Rejected` 1줄, fleet 투영 1회 실행.
- 스케줄 fixture: owner_absent 1건 → `Rejected` 1줄, 재시도 0. manual keeper 스케줄 3 occurrence → pending 1, `Superseded` 2.
- fence fixture: 부팅을 넘긴 Blocked fence 1건 → `Operator_must_act{Finalize_shutdown}` 1행, 이후 tick 에서 쓰기 0.
  `rg 'rejected by shutdown fence' lib` = 0 (지금 로그 10,446줄의 템플릿).
- `rg 'Operator_boot|Shutdown_finalize|Operator_fix_profile' lib` = 0 — RFC-0448 이 자기 합을 만들지 않았다는 증거.
- 각 표면(로그·dashboard normalizer·TUI mark·Board 문장·tool result JSON)에 네 생성자 exhaustive 테스트. 없는 arm 은 컴파일 실패.
- `retry_when`·`operator_action` 에 정수 상한·시도 횟수 필드 없음 (deferral_count 는 표시값, 분기 입력 아님) — 코드 리뷰 항목.

## 4. 단계

1. **PR-1 타입**: `lib/types/next_actor.ml(i)` + 네 표면 인코더(로그·JSON·Board 문장·TUI mark) + exhaustive 테스트. 소비자 없음.
2. **PR-2 완료 판정자**: #35354 `stop_cause` 를 payload 로, #35352 `stall_disposition` 삭제, registry 행에 `next_actor`, S6 producer fragment. 판정: §3 첫·다섯 번째 항목의 완료 판정자 몫.
3. **PR-3 MCP producer**: `producer` typed, `Unroutable_producer` 삭제, outbox 를 record write 에서 ack, `masc_tasks`/`masc_check` 회수. 판정: `completion repair remains pending` 0줄.
4. **PR-4 HITL**: `signal_resolution_after_commit` 이 `next_actor` 를 delivery record 에 쓰고 approve 도구 결과로 돌려줌. 재생 identity 규칙. 판정: audit 행 증가 0.
5. **PR-5 broadcast**: 끝까지 스캔, `Fix_keeper_record`, `Rejected` 에서 fleet 투영. 판정: broadcast fixture.
6. **PR-6 스케줄**: catch-all 제거, `Dispatch_blocked of next_actor`, owner_absent 종결, fence → `Finalize_shutdown`, manual 스케줄 coalesce + `Superseded`. 판정: 스케줄 fixture + fence fixture. RFC-0448 PR-2 와 같은 파일을 만지므로 먼저 들어간 쪽 위에 다른 쪽이 rebase 한다.
7. **PR-7 turn 실패**: `next_runtime` 합, `reported_runtime_id` 후보 귀속, Owner_lane_held/checkpoint 접기. 판정: `deferred_next_runtime=none` 0.
8. **PR-8 도구 결과**: `Pending_output` rename + dashboard suffix. 판정: dashboard `DEFERRED` 0.

각 PR 은 §3 의 grep 하나를 0 으로 만든다. 순서는 2→3 만 고정(3 이 2 의 registry 행을 쓴다).

## 5. 반론과 답

- **Codex missing[0]: "ownership·재시도 트리거·운영자 행동·종결·재생 identity 가 없다"** — §2.1 다섯 항목으로 각각 답했다.
  소유는 생성자에서 파생, 트리거는 `retry_when` 네 개, 행동은 `operator_action`, 종결은 두 생성자와 "새 사건으로만 닫힘",
  identity 는 레코드 키와 "같은 값이면 쓰기 0".
- **Codex missing[4]: "MCP producer 에게 durable 회수/알림 계약과 책임 행위자가 없다"** — §2.2 U1 항목. 채널은 task record,
  ack 는 record write commit, 회수는 `masc_tasks`/`masc_check`, 책임은 producer, 열람 표시는 다음 제출. "모든 producer 는
  깨울 수 있는 keeper" 라는 가정을 `producer` 합으로 없앴다.
- **Codex missing[5]: "승인은 적용이 아니다"** — 이 RFC 는 delivery receipt 를 만들지 않는다. 승인 레코드에 `next_actor` 가
  붙어 "적용 안 됨·누가 해야 함" 이 보이고, 재생이 사실을 복제하지 않는 것까지다. 효과 readback 과 idempotent replay 는
  RFC-0356 의 몫이다.
- **Codex missing[6]: "재장착되는 shutdown fence 와 영구 owner-absent 스케줄은 manual activation 정의로 안 풀린다"** —
  이 RFC 는 둘을 typed 로 종결 또는 운영자 몫으로 돌린다. owner_absent 는 `Rejected (Schedule_owner_absent)` 라 tick 이
  다시 안 본다. fence 는 `Operator_must_act (Finalize_shutdown)` 라 tick 이 다시 안 두드리고 `since` 가 보인다. fence 가
  부팅마다 재장착되는 원인(`keeper_shutdown_runtime.ml:recover_operation` 의 `Blocked _ -> Ok operation`)은 여기서
  안 고친다 — 그건 셧다운 lifecycle RFC 다. 이 RFC 가 고치는 것은 "그 상태를 retryable 이라 부르는 것" 이다.
- **"RFC-0448 이 이미 자기 `next_actor` 합을 적었다"** — §2.5 표대로 그 다섯 생성자는 이 합의 부분집합이다. 0448 은
  타입을 만들지 않고 읽는다. `Nobody` 는 누가 거절했는지를 버리는 생성자라 `Rejected {sender}` 로 바꾼다.
- **"L5 처럼 시도 횟수 상한을 두면 간단하다"** — 두지 않는다 (budget_gate). Deferred→Operator 전환은 typed 원인(keeper 레코드
  decode 실패)에서 나온다. 횟수는 표시값이다.
- **magic_number** — `retry_interval_sec` 는 이미 있는 runtime 필드를 값으로 실을 뿐이다. 새 숫자 비교 없음. `since` 는 관측 시각이지 임계값이 아니다.
- **string_matching** — 표면은 생성자에 match 한다. `"deferred"`·`"retryable "` 접두사·`"none"` 센티널을 지운다. wire decoder 는 strict 다.
- **budget_gate / greedy_shortcut** — 상한·타임아웃·기본값 arm 을 추가하지 않는다. `| _ -> Ok ()` 를 지운다.
- **hardcoded_path / env_var_sprawl** — 경로·환경변수를 새로 만들지 않는다. `Repair_verification_root` 의 path 는 registry 가 이미 든 값이다.
- **legacy_residue** — `stall_disposition`, `Unroutable_producer`, `deferred_next_runtime_id`, routine 강등 줄은 삭제한다. alias·호환 reader 없음.
- **closed_sum_over_string / strict_parse_no_default** — 네 표면의 decoder 는 모르는 라벨에 `Error`. 기본 생성자 없음.
- **failure_keeps_evidence** — `Nobody_will_retry`·`Rejected` 는 레코드를 지우거나 대상을 소비하지 않는다. `Superseded` 도 기록이다.
- **"8개 PR 은 크다"** — 각 PR 이 grep 하나를 0 으로 만든다. 한 PR 이 안 들어가도 나머지 표면이 어긋나지 않는다 — 타입은 PR-1 에 있고 소비자는 자기 자리만 바꾼다.

## 6. 근거

- 종합: `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/synthesis-adversarial.md` §2 L, §3 항목 3·4·5.
- finding: `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/merged.md` `## L1` `## L5` `## L6` `## L7` `## L8` `## L11` `## U1` `## U2` `## S6` `## S7` `## Q5` `## Q7` `## B2`.
- Codex: `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/codex-roadmap.json` `.missing[0]`, `.missing[4]`, `.missing[5]`, `.missing[6]`; `.rfc_order[1]` ("small shared disposition contract before dependent delivery integrations").
- 결정 메모: `~/.claude/projects/-Users-dancer-me-workspace-yousleepwhen-masc/memory/masc-runtime-decisions-2026-09-12.md` 결정 1·5.
- 실측 (UTC): `completion authority deferred` 219 (09-09T02:56..09-12T03:09, root unreadable) + 67 (09-09T01:31..09-10T02:32, Payment);
  `settled without retry` 1,024 (09-08..09-09T02:57, 이후 0); `delivery deferred keeper=codex-mcp-client` 359 (09-09T08:11..14:16) → `rejected` 1 (14:17:47);
  `signal=deferred_unregistered` 148 (09-08T02:50..09-11T18:54), appr_01a083ca 재생 52행; `dispatch=failed error=retryable …shutdown fence` 10,446 (09-08T06:14..09-09T15:27);
  `deferred_next_runtime=none` 2,886 / 3,404 FAILED; `completion repair remains pending` 9 task, 09-12 2,057줄 (03:36..); "review will not retry" 27 post / 21쌍 중 18쌍 재시도.
- 코드 (main 19efff1d47, 이 worktree e763050689 에서 재확인): `lib/completion_authority_agent.ml:process_outcome` (:481-498), `:process_task` retry arm (:890);
  `lib/completion_authority_wakeup.ml:wake_rejected_producer` (:20-50), `:reconcile_pending` (:95-145, `Unroutable_producer → Error`);
  `lib/workspace/workspace_broadcast.ml:durable_delivery_status` (:363-367), `:157` `Deferred _ -> "deferred"`, `:868` `expires_at = None`;
  `lib/keeper/keeper_approval_queue.ml:signal_resolution_after_commit` (:3529-3556); `lib/server/server_schedule_consumers.ml` (:1191-1213 `| _ -> Ok ()`, :1258-1266 fence);
  `lib/schedule/schedule_store.ml:99` `Retryable_dispatch_failure` 접두사; `lib/keeper/keeper_unified_turn_types.ml:keeper_cycle_failed_runtime_attribution` (:37-50 `"none"`);
  `lib/tool_types/tool_result.mli:75` `Deferred of 'deferred`; `dashboard/src/sse.ts:501-504` `' DEFERRED'`.
- 앞선 PR: #35354 (L1, `stop_cause`), #35352 (U2, `stall_disposition`) — 둘 다 OPEN, §2.4 대로 접는다.
- 형제 초안: RFC-0444 (goal store), RFC-0446 (contract absent), RFC-0447 (port), RFC-0448 (manual keeper, §2.5 의 자기 합은 그 초안 §2 기준), RFC-0449 (hard quota), RFC-0450 (witness). 번호는 2026-09-12 renumbering map 기준.
