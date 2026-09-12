---
rfc: "0448"
title: "manual keeper 는 부팅 없인 돌지 않고, 대기 작업은 보인다"
status: Draft
created: 2026-09-12
updated: 2026-09-12
author: claude
supersedes: []
superseded_by: null
related: ["0356", "0380", "event-queue-admit-all-ready", "0362", "0445"]
implementation_prs: []
---

# RFC-0448: manual keeper 는 부팅 없인 돌지 않고, 대기 작업은 보인다 (manual-keeper-durable-demand)

## 0. Summary

`activation_mode = manual` 인 keeper 는 운영자가 부팅하기 전에는 돌지 않는다. 지금은 그 keeper 앞으로 오는 durable demand(스케줄·HITL 승인·fusion 결과·connector 입력)를 큐에 넣고 `succeeded` 라고 적는다. 아무도 큐를 비우지 않는다. 이 RFC 는 keeper 의 가용성을 닫힌 합타입 하나로 정하고, 생산자마다 그 값을 어떻게 처분하는지를 표로 고정한다. 요점은 셋이다. 스케줄은 큐 대신 `Paused` 로 간다. 승인은 기록되고 `Held` 로 승인자에게 돌아간다. 멈춘 keeper 의 대기 작업 수·나이·다음 행동이 모든 표면에 보인다. #34633 이전처럼 durable demand 가 manual keeper 를 깨우는 일은 없다. 스케줄 등록 자체는 거부하지 않는다 (2026-09-12 결정 1).

기존 RFC 와의 관계:
- RFC-0356 (approval owns the effect) 을 **확장**한다. 승인 페이로드가 durable 하다는 전제 위에 `approval_progress` 단계를 얹는다. Held 승인이 부팅 뒤 재개될 수 있는 근거가 0356 의 저장 페이로드다.
- RFC-0380 (queue age needs the holder cycle) 을 **좁힌다**. 0380 은 도는 keeper 의 stale 판정을 다뤘다. 이 RFC 는 멈춘 keeper 의 행에 `held` 상태와 다음 행동을 붙여, 그 행이 `operator_action_required` 의 stale 로 오르지 않게 한다.
- RFC-event-queue-admit-all-ready 를 **확장**한다. 그 RFC 는 같은 `schedule_id` 의 occurrence 를 턴 컨텍스트에서 한 행으로 투영한다. 이 RFC 는 멈춘 manual keeper 에게는 occurrence 를 만들지 않는다. 도는 keeper 에는 그 규칙이 그대로 적용된다.
- RFC-0362 (goal owner and intake contract) 의 "책임자 없는 작업은 아무도 안 한다" 를 durable demand 에 **확장**한다. 대기 항목마다 `next_actor` 를 붙인다.

## 1. 배경 (실측)

창은 `<base-path>/.masc/logs/system_log_*.jsonl` 2026-09-08..09-12 UTC, main `e763050689` 기준. 상세 근거는 §6.

- sangsu 는 09-08T08:50Z 이전에 manual 로 바뀌었고, 그 뒤 약 17시간을 durable demand wake 로 돌았다. #34633 (09-09T01:56Z 머지) 이 그 wake 를 지웠다. 02:07Z 재부팅 뒤 sangsu 턴 0. 09-12T04:11Z 큐 pending 192 (schedule_due 151, connector_attention 40, hitl_resolved 1), 가장 오래된 행 97.8h.
- 스케줄러는 매 occurrence 를 큐에 커밋한 뒤 activation 을 `unregistered` 로 적고 `dispatch=succeeded` 로 끝낸다. `schedule stimulus retained without owner activation … keeper=sangsu` 151줄. `dispatch=succeeded` 2,105줄 (창 전체).
- 활성화 분류기가 둘이다. autoboot 는 `keeper_runtime.ml:autoboot_exclusion_reason` 에서 Manual → `Declarative_autoboot_disabled`. 스케줄러는 `keeper_activation_readiness.ml:classify_durable_demand_execution` 이 `~requested:true` 라서 Manual 이 `Retained_autoboot_disabled` arm 에 못 가고 `Recoverable` → `unregistered`. 같은 keeper 를 두 이름으로 부른다.
- 사람이 approve 한 HITL (appr_01a083ca, connector_post, 09-09T02:09:06Z 결정) 이 부팅마다 재생됐다. `HITL_APPROVAL_RESOLVED` 52회, `signal=deferred_unregistered` 52회, `audit-approvals` 에 같은 결정이 1 + 52행. 승인자는 `ok:true` 를 받았다. 게시는 없었다.
- taskmaster 는 TOML 도 meta 도 없는데 일일 스케줄이 `scheduled` 로 남아 하루 한 행씩 쌓인다 (09-10, 09-11, 09-12 00:00Z). owner-absent drain 은 #34633 이 지웠고 `drain_owner_absent_pending_result` 는 호출자 0. PR #35361 이 이 경우만 `Terminal_dispatch_rejection` 으로 바꾼다.
- imp (manual) 는 fusion 실패 결과를 09-11T02:24:03Z 턴 입구에서 소비했고, 02:33:47Z 운영자 stop 으로 ack 전에 멈췄다. 큐에 `interrupted` 전이 없이 25.7h 방치. 09-12T04:00Z 운영자 부팅으로만 배출됐다.
- 대시보드 keeper 카드는 sangsu 를 `중지 / 시작 시 부팅 안 함 / recover` 로 보여준다. `queue_depth` 는 running 일 때만 wire 에 실린다. 대기 작업 수·나이는 어떤 표면에도 없다.

## 2. 설계

### 2.1 가용성 분류기는 하나다

`Keeper_activation_readiness` 에 아래 타입을 두고, autoboot·스케줄러·HITL·fusion·connector·대시보드·TUI 가 전부 이 값만 읽는다. `keeper_runtime.ml:autoboot_exclusion_reason` 과 `classify_owner_execution_with ~requested` 는 지운다.

```ocaml
type owner_availability =
  | Running of Keeper_activation_mode.t          (* registry 에 live fiber. Manual 도 여기 *)
  | Bootable                                     (* On_demand | Autonomous, 미등록. wake 가 부팅 *)
  | Manual_stopped                               (* Manual, 미등록 *)
  | Paused of Keeper_lifecycle_admission.autonomous_denial
  | Stopping of Keeper_shutdown_types.Operation_id.t   (* shutdown fence 보유 *)
  | Profile_absent                               (* TOML 없음 또는 meta 없음 *)
  | Profile_invalid of Keeper_types_profile.load_error

type hold_reason = Owner_manual_stopped | Owner_paused | Owner_stopping of Operation_id.t
type reject_reason = Owner_profile_absent | Owner_profile_invalid of Keeper_types_profile.load_error

type demand_disposition =
  | Deliver                    (* Running | Bootable *)
  | Hold of hold_reason        (* Manual_stopped | Paused | Stopping *)
  | Reject of reject_reason    (* Profile_absent | Profile_invalid *)

val availability : config -> keeper_name:string -> owner_availability
val disposition_of_availability : owner_availability -> demand_disposition   (* total, catch-all 없음 *)
```

입력은 셋이다. keeper meta (`paused`, `latched_reason`, `activation_mode`), registry 항목(live fiber), shutdown store(`shutdown_operation_id`). 판정은 순서가 있다. shutdown fence → paused → profile → registry. `Running of Manual` 은 Manual 이라도 `Deliver` 다. 운영자가 부팅한 manual keeper 는 도는 동안 모든 demand 를 정상 수신한다 (Codex 반론 답, §5).

### 2.2 생산자별 처분 표

| 생산자 | Deliver | Hold | Reject |
|---|---|---|---|
| 스케줄 (`Schedule_due`) | 큐 커밋 + wake. `Dispatch_succeeded` | 큐 행 없음. 스케줄 상태 → `Paused { reason; since; held_occurrences }`. 결과 `Dispatch_held reason` | `Terminal_dispatch_rejection`. 스케줄 → `Failed`. PR #35361 의 owner-absent 가 이 칸의 한 행 |
| HITL 승인 | 결정 기록 → `hitl_resolved` 큐 커밋 → wake | 결정 기록. 큐 행 없음. delivery 레코드 `Delivery_held availability`. approve 응답에 `delivery = Held` | 결정 기록 후 delivery 폐기 (`Hitl_recipient_absent` 기존 경로) |
| fusion 결과 (`Fusion_completed`) | 큐 커밋 + wake | 큐 커밋 (keeper 가 요청한 결과라 행은 남긴다). wake 없음. 영수증 `Committed_held reason` | 결과는 board post 로만 남고 큐 커밋 없음. 영수증 `Rejected reason` |
| connector 입력 (`Connector_attention`) | 큐 커밋 + wake | 큐 커밋. wake 없음. 영수증 `Committed_held reason` | 큐 커밋 없음. 영수증 `Rejected reason`. 발신 connector 에 typed 회신 |
| 스케줄 등록 (`masc_schedule_create`) | `Scheduled` | 등록 성공, 즉시 `Paused { reason }` 로 응답 | 등록 거부 `Owner_profile_absent` |

**수락 경계.** "전달이 수락됐다" 는 keeper 의 event queue 에 행이 커밋된 순간 하나뿐이다 (`Keeper_registry_event_queue.enqueue_durable_result` 의 `Ok`). Hold 의 스케줄과 HITL 은 그 경계를 넘지 않는다. 대신 각자의 저장소(`schedules.json`, `gate/pending.json`)에 `Paused`/`Delivery_held` 가 durable 로 남는다. fusion 과 connector 는 경계를 넘되 wake 를 보내지 않는다. 어느 경우도 "받았는데 사라짐" 은 없다 (invariant `failure_keeps_evidence`).

**스케줄 Paused 는 occurrence 를 만들지 않는다.** interval 스케줄이 멈춘 동안 지나간 시각은 `held_occurrences` 카운트로만 남는다. 재개 시 `due_at` 은 재개 시각부터 다시 계산한다. 밀린 occurrence 를 한꺼번에 발행하지 않는다 (B7 의 73건 연속 소비 재발 방지).

### 2.3 승인은 네 단계로 나뉜다

delivery 레코드의 `grant_consumed : bool` 을 아래로 바꾼다. 단조 증가하며 뒤로 가지 않는다.

```ocaml
type approval_progress =
  | Approval_recorded                                (* 결정 durable + audit 행 1회 *)
  | Delivery_held of owner_availability              (* 큐 행 없음. 부팅을 기다림 *)
  | Delivery_accepted of { stimulus_id : string }    (* hitl_resolved 행 커밋 *)
  | Grant_consumed of { turn_id : string }           (* 턴이 grant 를 소비. RFC-0356 재생 시작 *)
  | Effect_applied of { receipt : Effect_receipt.t } (* 도구 실행 + readback *)
  | Delivery_acknowledged                            (* 큐 행 ack (source terminal) *)
```

- audit 행은 `Approval_recorded` 에서 한 번만 쓴다. 부팅 재생은 `resolve_entry` 를 다시 부르지 않는다.
- 부팅 재생 대상은 `Delivery_accepted` 뿐이다. wake 만 다시 보낸다. `Delivery_held` 는 재생하지 않고 기다린다. `Grant_consumed` 이후는 큐 행이 소유한다.
- **운영자 부팅은 Held 승인을 재개한다.** `masc_keeper_up` / TUI boot / 대시보드 boot 가 fiber 를 등록하기 전에, 그 keeper 의 `Delivery_held` 전부를 `Delivery_accepted` 로 옮긴다 (큐 커밋). 근거는 둘이다. 결정은 사람이 내렸고 durable 하다. 페이로드는 RFC-0356 대로 저장돼 있어 재현이 필요 없다. 승인자는 Held 상태를 보고 있으므로 재개 전 취소할 수 있다 (기존 gate cancel).
- 멱등성. 같은 approval_id 로 부팅을 두 번 해도 큐 행은 하나, 효과는 한 번이다. `stimulus_identity_equal` 이 `hitl_resolution_post_id` 로 같은 행을 잡는다.

### 2.4 활성화 모드가 바뀔 때

권위는 가용성의 입력 셋(meta·registry·shutdown store)이고, 처분은 그 파생값이다. 그래서 모드 변경은 저장소 간 트랜잭션이 아니라 **재파생** 이다.

- `Set_activation_mode` (`keeper_owner_reducer.ml`) 가 meta 를 쓴 직후 같은 호출 안에서 `redisposition ~keeper_name` 을 돌린다. 스케줄(`Scheduled|Due` ↔ `Paused`)과 delivery(`Delivery_held` ↔ `Delivery_accepted`)를 `disposition_of_availability` 로 다시 놓는다. 중간에 프로세스가 죽으면 부팅 복구가 전 keeper 에 대해 같은 함수를 돌린다. 입력이 같으면 결과가 같으므로 몇 번 돌아도 상태는 하나다.
- Autonomous → Manual 로 바꿔도 **도는 동안은 아무것도 바뀌지 않는다** (`Running of Manual` = Deliver). 백로그와 진행 중 턴은 그대로다. 변경은 keeper 가 멈추는 전이(`stop_requested` → `drain_complete`, 또는 프로세스 재시작 뒤 미등록)에서 재파생된다.
- 멈추는 전이에서 소비했지만 ack 하지 않은 행에는 `Interrupted { turn_id; at }` 전이를 쓴다 (Q4). 행은 pending 으로 남고 다음 턴이 다시 본다.
- 스케줄 dispatch 는 자기가 읽은 owner registry revision 을 커밋에 실어 CAS 한다. 분류와 커밋 사이에 모드가 바뀌면 커밋이 거부되고 dispatch 는 다시 분류한다. 낡은 분류로 큐에 들어가는 행은 없다.
- approve, fusion 영수증, connector 커밋도 같은 규칙이다. 분류 시점의 revision 을 실어 커밋하고, 거부되면 다시 분류한다. approve 는 결정 기록(`Approval_recorded`)을 먼저 durable 로 쓰고 그 뒤 처분을 CAS 하므로, 재분류가 몇 번 돌아도 audit 행은 하나다. 진행 중인 백로그 행은 어느 경우에도 지우거나 옮기지 않는다. 행의 소유자는 큐이고, 처분은 새로 들어오는 demand 에만 적용된다.

### 2.5 표면

| 표면 | 보이는 것 |
|---|---|
| 로그 | Hold **전이 시점** 에 WARN 한 줄: `schedule paused keeper=%s schedule_id=%s reason=%s`, `hitl delivery held keeper=%s approval=%s availability=%s`. tick 마다 반복하지 않는다. `schedule stimulus retained without owner activation`, `signal=deferred_*` 템플릿은 삭제 |
| keeper wire (`/api/v1/gate/keepers`, `masc_keeper_status`) | 모든 상태의 행에 `durable_demand : { availability; pending; immediate; oldest_age_s; held_schedules; held_approvals; next_actor }`. `availability` 가 멈춘 이유(`manual_stopped`, `paused`, `stopping`, `profile_absent`, `profile_invalid`)를 그대로 싣는다. `next_action` 은 Manual_stopped 에 `Boot` (지금은 `Recover`) |
| 대시보드 | keeper 카드 gloss: `대기 작업 N · 가장 오래된 Xh · 다음 행동: 부팅`. 스케줄 패널: `큐 대기` 대신 `일시정지 (keeper 수동 모드, 부팅하면 재개)`. 승인 이력에 `approval_progress` 열 |
| TUI | roster 에 대기 작업 수 열. 승인 상세에 `Held: keeper 꺼짐, 부팅하면 적용` 한 줄 |
| MCP 도구 결과 | `masc_schedule_create` → `status = paused, reason`. approve → `delivery = held { availability }`. `masc_keeper_waiting_inventory` 에 멈춘 keeper 도 포함 |
| board | 변경 없음. Hold 는 board 에 글을 올리지 않는다 |

`next_actor` 는 RFC-0445 (next-actor-sum) 의 합 `Runtime_will_retry | Operator_must_act of operator_action | Nobody_will_retry of stop_reason` 을 그대로 쓴다. 여기서 새 합을 만들지 않는다. `owner_availability` 에서 `next_actor` 로 가는 함수는 total 이다.

| availability | next_actor |
|---|---|
| `Running _` / `Bootable` | 해당 없음 (Deliver 는 대기가 아니다) |
| `Manual_stopped` | `Operator_must_act (Start_keeper { keeper; mode = Manual })` |
| `Paused denial` | `Operator_must_act (Resume_keeper { keeper; phase })` |
| `Stopping op` | `Operator_must_act (Finalize_shutdown { keeper; operation = op })` — RFC-0445 에 없는 생성자. 이 RFC 가 요구하고 RFC-0445 가 싣는다 |
| `Profile_absent` / `Profile_invalid _` | `Nobody_will_retry (Owner_profile_rejected { keeper; detail })` — Reject 는 terminal 이라 아무도 다시 보지 않는다. `Fix_keeper_record` 는 프로필을 고친 뒤 스케줄을 다시 등록하는 운영자 몫이고, 이미 Reject 된 demand 의 next_actor 가 아니다 |

### 2.6 이 RFC 밖: paused / stopping 의 생명주기 결함 (Q5 / B2)

`Stopping of operation_id` 는 이 분류기의 한 생성자이고, 그 처분은 `Hold (Owner_stopping op)` 다. 스케줄은 tick 마다 재시도하는 대신 `Paused` 로 간다. 그래서 analyst 의 15초 재시도 폭풍(10,446 WARN)은 이 RFC 로 멎는다. 그러나 **왜 Blocked fence 가 부팅마다 재장착되고 종료 분기가 없는가** 는 이 RFC 가 풀지 않는다. `keeper_shutdown_runtime.ml:recover_operation` 의 `Blocked _ -> Ok operation` 에 terminal 분기(Finalize | Resume 를 운영자 결정으로)를 두는 일은 별도 RFC (synthesis §5 "셧다운 lifecycle vs 스케줄러 계약") 다. 이 RFC 의 `Shutdown_finalize` next_actor 는 그 RFC 의 진입점만 가리킨다.

## 3. 판정 기준

각 항목은 테스트 하나 또는 로그 grep 하나로 확인한다. 하나라도 실패하면 미완이다.

1. 분류기 하나. `rg -n 'autoboot_exclusion_reason|classify_durable_demand_execution|~requested' lib/` 가 0건. autoboot 제외 로그와 스케줄러 처분 로그가 같은 keeper 에 같은 `owner_availability` wire 값을 적는다 (테스트: Manual 미등록 keeper 에 두 경로가 모두 `manual_stopped`).
2. 스케줄. manual 미등록 keeper 를 대상으로 `masc_schedule_create` → 응답 `status=paused reason=owner_manual_stopped`. 24시간 뒤 그 keeper 의 `event-queue-v19.json` 에 `schedule_due` 행 증가 0. `rg -c 'schedule stimulus retained without owner activation' system_log_*.jsonl` = 0.
3. 승인. manual 미등록 keeper 에 approve → HTTP/MCP 응답 `delivery.kind = "held"`, `availability = "manual_stopped"`. 부팅 3회 뒤 `audit-approvals/*.jsonl` 에서 그 approval_id 의 `event=resolved` 행 = 1. `rg -c 'signal=deferred_unregistered'` = 0.
4. 재개. Held 승인 1건을 둔 채 `masc_keeper_up` → 첫 턴 전에 큐에 `hitl_resolved` 행 1. 부팅을 두 번 해도 행 1, 효과 1 (RFC-0356 재생 영수증 1).
5. 표면. `GET /api/v1/gate/keepers?detailed=true` 의 모든 행에 `durable_demand` 키. offline 행의 `next_action = "boot"`. 대시보드 스케줄 패널 텍스트에 `큐 대기` 0건 (manual 대상).
6. 모드 변경. 도는 keeper 를 Manual 로 바꾸면 스케줄 상태 불변. stop 뒤 `Paused`. 다시 Autonomous 로 바꾸면 `Scheduled` 이고 `due_at >= now`, 밀린 occurrence 발행 0.
7. 중단 증거. 소비 후 ack 전에 stop → 큐 파일 `last_transition.kind = "interrupted"`, 행은 pending.
8. 닫힌 합. `lib/server/server_schedule_consumers.ml` 에 `| _ -> Ok ()` 0건. `Keeper_wake_activation_deferred` 심볼 0건. `owner_availability`, `demand_disposition`, `approval_progress`, `next_actor` 는 `.mli` 에 생성자를 그대로 노출하고 wire 파서는 unknown 에 `None`.
9. 부작용 확인. `rg -c 'rejected by shutdown fence'` 가 배포 뒤 창에서 0. (Q5 자체의 해소는 §2.6 별도 RFC 로 판정.)

## 4. 단계

| PR | 내용 | 관측 가능한 변화 |
|---|---|---|
| PR-1 | `owner_availability` + `disposition_of_availability` + `next_actor` 추가. `autoboot_exclusion_reason`, `~requested` 삭제. autoboot·스케줄러·HITL·fusion·connector 가 새 함수를 읽는다 | 두 경로의 로그가 같은 wire 값. §3-1 |
| PR-2 | 스케줄 `Paused of { reason; since; held_occurrences }` 상태. dispatch 가 `Dispatch_held` 를 반환. `| _ -> Ok ()`, `Keeper_wake_activation_deferred`, 낡은 drain 주석, `drain_owner_absent_pending_result` 삭제. #35361 의 Reject 행 포함 | §3-2, §3-8. `schedule stimulus retained` 0건 |
| PR-3 | `approval_progress` 로 `grant_consumed` 하드컷. approve 응답에 delivery. 부팅 재생은 `Delivery_accepted` 만, audit 행 1회. 리셋 절차 동봉 (옛 `gate/pending.json` 은 부팅이 typed 로 거부하고 리셋 명령을 안내) | §3-3 |
| PR-4 | `durable_demand` 를 모든 keeper 행에 투영. 대시보드 카드·스케줄 패널·승인 이력, TUI roster, `masc_keeper_waiting_inventory`, `next_action = Boot` | §3-5 |
| PR-5 | `Set_activation_mode` 뒤 `redisposition`, 부팅 복구의 재파생, 운영자 부팅 시 Held 승인 재개, dispatch 의 revision CAS, stop 전이의 `Interrupted` | §3-4, §3-6, §3-7 |
| PR-6 | fusion/connector 영수증 `Committed_held | Rejected`. 로그 템플릿 교체 | `signal=deferred_*` 0건, §3-9 |

PR-1 이 먼저다. PR-2·PR-3·PR-4 는 PR-1 위에서 서로 독립이다. PR-5 는 PR-2·PR-3 뒤다.

## 5. 반론과 답

**Codex: "큐에 넣지 마라" 는 이미 수락한 HITL 결정·connector 입력·fusion 결과를 조용히 버릴 수 있다. 그리고 manual 이 곧 멈춤은 아니다.**
버리지 않는다. §2.2 표의 Hold 열은 전부 durable 이다. 스케줄은 `Paused` 레코드, 승인은 `Delivery_held` 레코드, fusion·connector 는 큐 행 자체가 남는다. 사라지는 것은 "받았다" 는 거짓 영수증뿐이다. 두 번째 지적은 맞다. sangsu 는 manual 인 채 17시간을 돌았다. 그래서 분류기의 첫 생성자가 `Running of Keeper_activation_mode.t` 이고 Manual 이 그 안에 있다. 모드는 부팅 정책이지 현재 상태가 아니다.

**"Held 승인이 며칠 뒤 부팅으로 갑자기 실행되면 위험하지 않나."**
승인자는 approve 순간 `held` 를 받고, 대시보드·TUI 승인 이력에 그 상태가 계속 보인다. 취소는 기존 gate cancel 로 가능하다. 시간으로 자동 폐기하지 않는다 (forbidden `budget_gate`). 페이로드는 저장된 것 그대로라 재현 오차가 없다 (RFC-0356). 실행 시점의 TOCTOU 검증도 0356 그대로다.

**"스케줄 등록을 아예 거부하는 게 단순하지 않나."**
결정 1 이 등록은 허용한다고 정했다. 운영자가 keeper 를 잠깐 부팅해 쓰는 흐름에서 스케줄을 매번 다시 만들게 하지 않기 위해서다. 대신 등록 응답이 즉시 `paused` 를 말한다.

**헌법 forbidden 점검.**
- `magic_number`: 새 숫자 0. 나이·개수 임계 없음. `held_occurrences` 는 세는 값이지 판정 기준이 아니다.
- `string_matching`: 처분은 `owner_availability` 의 exhaustive match 다. wire 문자열은 경계에서만 만들고 파서는 unknown 에 `None` (`strict_parse_no_default`).
- `budget_gate`: Held 항목에 만료 없음. 재개는 운영자 행동으로만.
- `greedy_shortcut`: `| _ -> Ok ()` 를 지우고 `Dispatch_held` 를 반환한다. `Deferred_*` 를 INFO 로 접던 경로도 지운다.
- `hardcoded_path` / `env_var_sprawl`: 새 경로·환경변수 0.
- `legacy_residue`: `grant_consumed`, `Keeper_wake_activation_deferred` 계열, 두 번째 분류기, 죽은 drain, 틀린 주석을 전부 지운다. 마이그레이션 코드 없음. 리셋 절차만 PR 에 동봉.
- `closed_sum_over_string`: 새 타입 넷 모두 닫힌 합. `failure_keeps_evidence`: Hold 는 저장소에 남고, stop 은 `Interrupted` 를 쓴다.

## 6. 근거

감사 디렉터리: `/Users/dancer/me/.masc/evidence/audit-adversarial-20260912/` (`merged.md`, `synthesis-adversarial.md`, `codex-roadmap.json` decision_critiques[0]). 창 2026-09-08..09-12 UTC.

| 항목 | 수치 | 출처 |
|---|---|---|
| sangsu 큐 | pending 192 (schedule_due 151 / connector_attention 40 / hitl_resolved 1), oldest 97.8h, revision 882 @ 09-12T04:11:52Z | Q1, U3 |
| sangsu manual 전환 | `recovery retained keeper=sangsu reason=autoboot_disabled` 첫 줄 09-08T08:50:44Z. 마지막 턴 09-09T02:06:29Z. #34633 = 71d0711ada 09-09T01:56:24Z | Q1 extra, B3 |
| 스케줄 retained 로그 | `schedule stimulus retained … keeper=sangsu reason=unregistered` 151 (09-09..12). taskmaster `owner_absent` 4. edgar.a.poe `lifecycle_denied` 52 | S7, Q missed |
| `dispatch=succeeded` | 2,105줄 (창 전체) | S7 |
| HITL 재생 | `HITL_APPROVAL_RESOLVED appr_01a083ca` 27/5/19/1 = 52. `signal=deferred_unregistered` 148 (64 approval id). audit `event=resolved` 1 + 52행 | Q2, S1, U4 |
| `gate/pending.json` | deliveries 2,049, `grant_consumed=false` 5 (sangsu 1, goo-yang-bong 4) | Q2 extra |
| taskmaster | TOML 없음, meta 없음, sched-0e2f95c9 `scheduled`, pending 3 (09-10/11/12 00:00Z). 마지막 drain 09-09T00:00:39Z | Q3, PR #35361 |
| imp 중단 | 소비 09-11T02:24:03Z, stop 02:33:47Z, 배출 09-12T04:04:35Z (운영자 부팅). 25.7h | Q4 |
| analyst fence | `rejected by shutdown fence` 10,446 (09-08T06:14Z..09-09T15:27Z), occurrence id 2개, 부팅 재장착 43회 | Q5, B2 |
| 채팅 점유 뒤 몰림 | 해제 뒤 21Z 한 시간에 schedule_due 73건 연속 | B7 |

코드 사이트 (main `e763050689`):
- `lib/keeper/keeper_runtime.ml:autoboot_exclusion_reason` — Manual → `Declarative_autoboot_disabled`.
- `lib/keeper/keeper_activation_readiness.ml:classify_owner_execution_with` — `Some Autoboot_disabled when not requested` 만 `Retained_autoboot_disabled`; `classify_durable_demand_execution` 은 `~requested:true`.
- `lib/server/server_schedule_consumers.ml:activation_outcome_for_required_wake` — 모든 비실행을 `Keeper_wake_activation_deferred` 로. `log_activation_outcome` INFO. `dispatch_keeper_wake` 의 `| _ -> Ok ()`. `Intake_shutdown_reserved` → `retryable_dispatch_failure`.
- `lib/keeper_runtime/keeper_event_queue.ml:stimulus_identity_equal` — `Schedule_due` identity 는 occurrence `post_id`.
- `lib/keeper/keeper_approval_queue.ml:signal_resolution_after_commit` (unit 반환, INFO), `complete_delivery` (`Hitl_recipient_absent` 만 폐기, Ok 경로가 `resolve_entry` 재호출), `install_persistence_internal` 재생 루프, `delivery_wake_was_observed`.
- `lib/fusion/fusion_sink.ml:wake_keeper_on_fusion_completion` — 커밋 뒤 wake 는 best-effort, 결과 미반환.
- `lib/server/server_dashboard_http_delete_actions.ml` → `Server_schedule_consumers.cancel_keeper_schedules` — DELETE 에서만 호출. 모드 변경 경로(`keeper_owner_reducer.ml:Set_activation_mode`)는 부르지 않음.
- `lib/keeper/keeper_registry_event_queue.ml:drain_owner_absent_pending_result` — 호출자 0. `lib/server/server_bootstrap_maintenance.ml` 의 #34633 제거 주석.
- `lib/keeper/keeper_status_runtime.ml` — `KH_offline` / `Proactive_disabled` → `Recover`.
- `lib/schedule/schedule_domain.ml` — status 에 `Paused` 없음 (`Scheduled|Due|Running|Succeeded|Failed|Cancelled|Expired`).
