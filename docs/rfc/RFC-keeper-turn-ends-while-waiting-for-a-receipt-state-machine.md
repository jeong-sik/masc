---
rfc: "keeper-turn-ends-while-waiting-for-a-receipt-state-machine"
title: "영수증을 기다리며 턴이 끝나는 상태 기계"
status: Draft
created: 2026-11-11
updated: 2026-11-12
author: claude
supersedes: []
superseded_by: null
related: ["a-keeper-works-while-a-long-execute-runs", "execute-background-through-the-tool-outbox", "retained-results-carrier-shrinks-to-an-address", "keeper-wakes-when-a-pr-check-finishes", "0225"]
implementation_prs: []
---

# RFC: 영수증을 기다리며 턴이 끝나는 상태 기계

줄 번호는 `60cfd89ce917` 기준이에요. 코드는 쓰지 않았어요.
표시: **[사실]** 은 코드나 측정에서 직접 확인한 것(파일:줄, 명령, 수치)이에요. **[제안]** 은 이 RFC 가 정하려는 것이에요. **[확인 필요]** 는 아직 모르는 것이에요.

`RFC-a-keeper-works-while-a-long-execute-runs`(#51303, 이하 부모 RFC)의 후보 (나)를 사용자가 골랐어요. (나)는 모델이 영수증 하나를 기다리겠다고 부르면 턴이 끝나고, 그 영수증이 올 때까지 작업을 claim 하지 않는 설계예요. 부모 RFC 8절은 코드보다 상태 기계 RFC 와 TLA+ 모델이 먼저라고 했어요. 이 글과 `specs/bug-models/KeeperReceiptWait.tla` 가 그 둘이에요.

## 0. 요약

- **[제안]** 채팅 작업의 상태는 일곱이에요. queued, waiting, ready, running, succeeded, failed, cancelled 예요. 새 상태는 waiting 과 ready 둘이고, 둘 다 reducer 에서는 지금처럼 `Queued` 예요(3.2).
- **[제안]** 영수증은 기다리기로 한 작업이 소유해요. 소유는 작업이 끝날 때까지 이어지고, 끝나면(성공, 실패, 취소, 재시작 실패) 같은 전이에서 풀려요. 소유 기록은 실행 기록(semantic record)의 새 필드예요(4절). 이어받는 길은 지금 있는 체크포인트 재개예요(6절).
- **[사실]** 영수증을 읽는 곳은 처음 센 여섯보다 많아요. 구현(L1)에서 `load` 호출처는 열이에요(2.7). 모델은 소유를 안 보는 run 하나만 있어도 기다리는 작업의 영수증이 그 run 에 지워지는 반례를 내요(8.4).
- **[사실]** TLC 는 정상 설정에서 위반을 찾지 못했어요(생성 75,517 상태, 서로 다른 26,970 상태, 깊이 20). 버그·가드 설정 13개는 모두 의도한 불변식이나 속성을 깨는 반례를 내요(8.4). 재개한 작업의 재시작(소유를 지킨 채 ready 로 돌아가는 길)도 모델에 들어 있어요.
- **[제안]** hard cut 은 둘이에요. 실행 기록 형식이 `v2` 에서 `v3` 로 바뀌어요. 부모 RFC 가 둘로 센 저장소 스키마와 소유 기록이 같은 필드 하나로 모여요. 영수증의 `arguments` 를 모를 때 빈 값으로 채우지 않고 typed 부재로 적는 선택(9절 3) 때문에 outbox 영수증 형식도 바뀌어요(7절). 옛 형식을 읽는 코드는 없어요.
- 사용자가 정할 것은 9절에 있어요.

## 1. 이 글이 정하는 것

**정하는 것.**
- 작업 하나와 영수증 하나의 상태와 전이(3절). 모든 쌍을 적어요.
- 영수증의 소유자와 소유가 풀리는 때(4절).
- 서버 재시작, worker 종료, 영수증 중복, 취소 뒤 도착(5절).
- 체크포인트 재개가 있는 길을 쓰는 방법(6절), hard cut(7절), 하네스(8절).

**정하지 않는 것.**
- 도구 이름과 도구 설명 문장. Keeper 프롬프트 문장.
- 호스트가 도는 턴을 끊는 규칙. 이 설계에서 턴을 끝내는 쪽은 모델이에요. 모델이 wait 도구를 부를 때만 끝나요.
- 시간 임계, 횟수 상한, 최근성 기준. 이 설계의 상태는 「영수증이 있다」「소유자가 있다」 같은 사실로만 갈라요. 모델 상수 `MaxRestarts` 와 `MaxPatrols` 는 TLC 탐색 범위일 뿐 제품 값이 아니에요.

**부모 RFC 와 달라진 것 둘.**
1. **[사실]** #51221(`b25e45be056e`)이 순찰 턴의 채팅 슬롯 인계를 지웠어요. `rg 'chat_handoff|autonomous_chat_handoff' lib` 는 아무것도 찾지 못해요. 부모 RFC 3.2 와 4.2 의 순찰 턴 슬롯 인계 설명은 지금 코드와 달라요. 이 글은 순찰 턴을 「슬롯을 쥔 다른 lane」으로만 다뤄요.
2. **[제안]** 부모 RFC 6절은 「깨움을 놓쳤는가」 상태 검사가 시간 임계 없이 정확히 가려진다고 했어요. 이 설계에서는 영수증이 쓰인 뒤 `waiting` 이 `ready` 가 되기 전에 한 단계가 있어요. 그 상태는 정상이에요. 검사는 owner 가 그 단계를 끝낸 뒤에 해야 해요(8.3).

## 2. 지금 코드가 하는 일

### 2.1 슬롯

- **[사실]** Keeper 마다 도는 턴의 칸이 하나예요. `turn_in_flight` 이고 lane 은 `Autonomous | Chat_operation | Maintenance` 예요(`keeper_owner.ml:84-93`, 필드 `:451`).
- **[사실]** 채팅 작업 child 는 문이 열려 있고, claim 할 작업이 있고, 도는 작업이 없을 때만 시작해요(`keeper_owner.ml:1802-1829`, 문 `:1805-1813`, claim 조건 `:1820-1823`). 턴이 끝나면 칸을 비우고 `start_child_if_needed` 를 불러요(`:3046`, `:3056`).
- **[사실]** 저장소도 같은 것을 막아요. `running` 행은 하나(`operations_single_running`, `keeper_chat_operation_store.ml:128-129`)이고 실행 기록의 `running` 도 하나(`semantic_single_running`, `:97`)예요. `claim_next` 는 `running` 이 있으면 claim 하지 않아요(`:1890-1895`).

### 2.2 작업

- **[사실]** reducer 상태는 `Queued | Running | Succeeded | Failed | Cancelled` 다섯이고 명령은 일곱이에요. 모든 쌍이 이름으로 적혀 있고 catch-all 이 없어요(`keeper_chat_operation_reducer.ml:3-19`, `:53-100`).
- **[사실]** 끝난 행은 trigger 로 바꿀 수 없어요(`keeper_chat_operation_store.ml:99-103`, `:132-138`).
- **[사실]** 취소는 `cancel_queued` 예요. 실행 기록을 같은 transaction 에서 settle 하고 행을 `cancelled` 로 바꿔요(`:3199-3231`, `settle_direct_semantic` `:3160-3186`).
- **[사실]** Running 행을 끝내는 명령은 `Succeed_running` 과 `Fail_running` 뿐이에요(reducer `:3-19`). operator interrupt 는 `Operation_failed` 로 끝나요(`keeper_owner.ml:1878`).

### 2.3 실행 기록

- **[사실]** 작업마다 실행 기록이 하나예요. `phase` 는 `Preparing | Ready | Running | Preparing_checkpoint | Preparation_wait | Resuming_runtime_retry | Resuming_gate | Recovering | Suspended | Settled` 이고, `Recovering` 은 `recovery_origin` 아홉 가지를 가져요(`keeper_semantic_execution.mli:117-142`). 저장소 표의 `phase` 열은 여섯 값만 허용해요(`keeper_chat_operation_store.ml:93-109`).
- **[사실]** `Input_wait` 는 막힌 원래 continuation 이에요. 재개할 수 있는 체크포인트가 아니고, 시간이 지나면 끝나는 기록도 아니라고 문서가 적어요(`keeper_semantic_execution.mli:249-274`).
- **[사실]** `gate_obligations` 는 phase 와 따로 있는 필드예요. `Settle Completed` 는 이 필드가 비어 있을 때만 받고(`keeper_semantic_execution.ml:836`), `Settle Cancelled | Failed` 는 `Settled` 가 아닌 아무 phase 에서나 받고(`:838-841`) 필드를 비워요(`:885`). 같은 동작을 같은 액션으로 두 번 하면 revision 을 쓰지 않고 같은 기록을 돌려주는 선례도 있어요(`.mli:249-274`의 `Require_reconciliation` 설명).
- **[사실]** 기록 형식은 `masc.keeper_semantic_execution.v2` 예요. 읽을 때 필드 목록과 `schema` 문자열이 모두 맞아야 해요(`keeper_semantic_execution.ml:1022`, `:1362-1367`).

### 2.4 claim 못 하는 이유

- **[사실]** 다섯이에요. 해결이 없는 Gate 대기, `Gate_binding`, `Preparation_wait`, `Input_wait`, `not_before` 가 아직 오지 않은 runtime retry 예요(`blocked_queued_scopes`, `keeper_chat_operation_store.ml:1731-1753`). 이 이유가 있는 행은 `Queued` 로 남아요.
- **[사실]** Owner 는 폴링하지 않아요. 깨움이 필요하면 밖에서 와요(`:1775-1781`). `Wake_operation_drain` 이 다시 claim 가능 여부를 계산해요(`keeper_owner.ml:2806-2826`).
- **[사실]** 도중에 미룬 작업은 continuation 이 다섯 중 하나 있어야 해요. checkpoint, runtime_retry, gate_state, gate_binding, input_wait 예요. 하나도 없으면 `Integrity_error` 예요(`keeper_owner.ml:1696-1735`, 목록 `:1727-1731`).

### 2.5 턴이 끝나는 길과 이어받는 길

- **[사실]** `keeper_turn.ml:1057-1081` 은 두 갈래예요. `InputRequired` 는 `defer_direct_input_wait` 로 가요. `Yielded_to_durable_stimulus` 이고 결과가 `Continuation_checkpoint` 이면 `Keeper_direct_checkpoint_continuation.defer` 나 `defer_official` 로 가요(`keeper_direct_checkpoint_continuation.ml:85-104`).
- **[사실]** `Generic_deferred` 도구 결과는 턴을 이 체크포인트 길로 끝내요(`keeper_tools_agent_core_bundle.ml:248-257` 주석, `keeper_tool_terminal_boundary.ml:1-5`). `Owned_job_result_wait` 와 `Composition_result_wait` 는 콜백을 부르지 않아요(`keeper_tools_agent_core_handler.ml:124-136`).
- **[사실]** `defer_direct_checkpoint` 는 한 transaction 에서 세 가지를 해요. 실행 기록을 `Suspend` 하고, 작업을 큐로 되돌리고(`requeue_continuation_with_db`), 순서를 새 입력 뒤로 옮겨요(`keeper_chat_operation_store.ml:2616-2670`).
- **[사실]** `defer_direct_input_wait` 도 같은 모양이에요. 한 transaction 에서 `Suspend_input` 하고 큐로 되돌려요(`:2404-2444`).
- **[사실]** 다시 시작할 때 연속 기록을 gate, checkpoint, runtime 순으로 찾아요(`keeper_turn.ml:481-493`). checkpoint 의 load 와 consume 은 `keeper_direct_checkpoint_continuation.ml:43-83` 이고, 저장소 쪽은 `resume_direct_checkpoint` 예요(`keeper_chat_operation_store.ml:2672-2704`).

### 2.6 백그라운드 실행과 영수증

- **[사실]** worker 는 서버 수명 switch 위에서 돌아요(`keeper_execute_background.ml:253-272`). 프로세스 메모리는 active request 의 worker 만 쥐어요(`keeper_msg_async.ml:7-10`). request 하나는 끝날 때 영수증 하나를 쓰게 돼 있어요.
  - 정상 종료와 worker 의 raise 는 `Finished`, `Unfinished` 영수증이에요(`:188-226`).
  - worker 취소는 abort 영수증이에요(`:231-243`).
  - 서버가 죽으면 다음 부팅의 `deliver_unfinished_runs` 가 쓰고(`:334-353`), `recover_lost_disk_records` 보다 먼저 불려요(`server_bootstrap_maintenance.ml:373-376`).
- **[사실]** 예외가 하나 있어요. active 목록을 못 읽으면 경고만 하고 영수증을 쓰지 않아요(`keeper_execute_background.ml:336-339`).
- **[사실]** 영수증의 `call_id` 는 request_id 예요(`keeper_execute_background.ml:109-129`). 파일 이름은 내용에서 나와요(`keeper_client_tool_outbox.ml:61-63`, `:80-97`).
- **[사실]** 이미 영수증이 있으면 `Unfinished` 를 또 쓰지 않아요. 가드가 outbox 를 읽어 `call_id` 를 찾아요(`holds_receipt`, `keeper_execute_background.ml:155-167`).

### 2.7 영수증을 읽는 곳

**[사실]** `rg` 로 처음 센 호출처예요. 여섯이에요. 구현에서 `load` 를 부르는 곳은 열이에요(표 아래).

| # | 호출처 | 무엇을 해요 |
|---|---|---|
| 1 | `keeper_codex_runtime.ml:1263` | `run_carrier_load`. run 의 carrier |
| 2 | `keeper_turn_driver_try_provider.ml:2620` | `run_carrier_load`. run 의 carrier |
| 3 | `keeper_claude_code_runtime.ml:986` | `run_carrier_load`. run 의 carrier |
| 4 | `keeper_client_tool_outbox_wake.ml:44` | `notify`. 영수증마다 `Tool_result_ready` stimulus 를 큐에 넣고 깨움 |
| 5 | `keeper_heartbeat_stimulus_intake.ml:617` | 대기 중인 `Tool_result_ready` 가 아직 영수증을 가리키는지 확인 |
| 6 | `keeper_execute_background.ml:158` | `holds_receipt` 가드 |

- **[사실]** 위 표는 run 의 carrier 를 셋으로 셌지만, 구현(L1)에서는 `run` 을 가진 runtime 이 넷(codex, antigravity, muse, claude_code)이고 `keeper_turn_driver_try_provider.ml` 이 따로 읽어요. 표에 없던 호출처가 둘 더 있어요. `keeper_official_client_host.ml` 과 `keeper_run_tools_hooks.ml` 이에요. 그래서 `load` 호출처는 열이에요. 필수 인자 `~viewer`(4.3)가 이 숫자를 컴파일러가 세게 해요.
- **[사실]** run 하나는 첫 호출에서 outbox 를 한 번 읽고 그 snapshot 을 끝까지 써요(`keeper_client_tool_outbox.mli:243-248`, `.ml:545-555`).
- **[사실]** snapshot 은 `Completed` 로 끝난 턴만 지워요. 체크포인트, 입력 대기로 끝나면 지우지 않아요. 지울 때는 읽은 내용과 같은 파일만 지워요(`.ml:592-607`).
- **[사실]** `notify` 는 시작할 때와 maintenance tick 마다 모든 Keeper 에게 불려요(`keeper_client_tool_outbox_wake.ml:70-100`, `server_bootstrap_maintenance.ml:775-803`). ACK 될 때까지 같은 stimulus 를 다시 알려요(`keeper_client_tool_outbox_wake.ml:52-54`, `:62-63` 주석).

### 2.8 재시작과 취소

- **[사실]** 재시작 때 `Running` 행은 continuation 이 없으면 `Failed` 예요(`keeper_chat_operation_store.ml:3456-3459`). continuation(체크포인트, runtime retry, gate 상태)이 있으면 `Queued` 로 돌아가 재개해요(같은 파일 `requeue_continuation_with_db`). `Queued` 행은 막힌 것도 그대로 남아요.
- **[사실]** 실행 기록 쪽에서는 `Running` 이던 기록이 재시작에서 `Recovering` 의 origin `Interrupted_execution` 으로 가는 길이 있어요(`keeper_semantic_execution.ml` `recovery_origin`). 영수증 소유는 `Settle` 이 비우고, origin 이 `Interrupted_execution` 인 `Require_reconciliation` 도 비워요. 다른 origin 의 `Require_reconciliation` 은 비우지 않아요.
- **[사실]** 작업 취소는 요청을 건드리지 않아요. 요청을 취소하는 길은 Keeper 가 부르는 도구 하나뿐이에요. `rg 'Keeper_msg_async\.cancel' lib` 의 호출처가 `keeper_tool_composition_surface_request_control.ml:126` 하나예요. `Cancel_queued_operation` 의 처리(`keeper_owner.ml:2740-2748`)는 저장소만 써요.

## 3. 상태 기계

모델의 변수예요. `task` 는 작업 상태, `awaiting` 은 기다리는 request, `owns` 는 소유 기록, `req` 는 request 상태, `slot` 은 슬롯 주인, `loaded` 는 슬롯 주인의 run 이 읽은 영수증이에요.

### 3.1 슬롯

**[제안]** 슬롯 값은 `free`, 작업 하나, `other` 예요. `other` 는 순찰과 유지보수 같은 작업 아닌 lane 이에요. 지금 코드와 같은 칸 하나예요(2.1).

| 슬롯＼사건 | Claim(t) | 턴 끝(Wait, Complete, Fail) | 다른 lane 시작 | 다른 lane 끝 | Restart |
|---|---|---|---|---|---|
| free | → t | 거절 | → other | 거절 | 그대로 |
| t | 거절 | → free | 거절 | 거절 | → free |
| other | 거절 | 거절 | 거절 | → free | → free |

### 3.2 작업

| 상태 | 뜻 | reducer 상태 |
|---|---|---|
| queued | 영수증을 기다린 적이 없고 claim 할 수 있어요 | `Queued` |
| waiting | 턴이 끝났고 기다리는 영수증이 아직 없어요. claim 못 해요 | `Queued` |
| ready | 기다리던 영수증이 모두 왔어요. claim 할 수 있어요 | `Queued` |
| running | 슬롯을 쥐고 돌아요 | `Running` |
| succeeded, failed, cancelled | 끝났어요 | 같은 이름 |

**[제안]** 새 저장 필드는 `receipt_obligations` 하나예요(4절). 세 상태는 거기서 읽어요. waiting 은 `Pending` 항목이 있는 `Queued` 작업이고, ready 는 항목이 있고 모두 `Arrived` 인 `Queued` 작업이고, queued 는 항목이 없는 `Queued` 작업이에요. 파생 상태라서 따로 저장하지 않아요.

**[제안]** 전이예요. 모든 칸을 적었어요. `거절` 은 호출한 쪽에 에러를 돌려주고 아무것도 바꾸지 않아요. `그대로` 는 정상이고 아무것도 바꾸지 않아요.

| 상태＼사건 | Claim | Wait(r) | Resolve | Complete | Fail | Cancel | Restart |
|---|---|---|---|---|---|---|---|
| queued | → running | 거절 | 그대로 | 거절 | 거절 | → cancelled | 그대로 |
| waiting | 거절 | 거절 | → ready | 거절 | 거절 | → cancelled | 그대로 |
| ready | → running | 거절 | 그대로 | 거절 | 거절 | → cancelled | 그대로 |
| running | 거절 | → waiting 또는 → ready | 그대로 | → succeeded | → failed | 거절 | continuation 없으면 → failed, 있으면 → 항목 상태대로 queued, waiting, ready |
| succeeded | 거절 | 거절 | 그대로 | 거절 | 거절 | 거절 | 그대로 |
| failed | 거절 | 거절 | 그대로 | 거절 | 거절 | 거절 | 그대로 |
| cancelled | 거절 | 거절 | 그대로 | 거절 | 거절 | 거절 | 그대로 |

사건의 조건이에요.
- **Claim** 은 슬롯이 `free` 일 때만 해요. waiting 은 claim 하지 않아요.
- **Wait(r)** 은 슬롯을 쥔 작업만 불러요. request r 에 영수증이 이미 있으면 ready 가 되고, worker 가 도는 중이면 waiting 이 돼요. 도구를 부를 때 r 의 request 기록이 없으면 거절이고 턴은 이어져요. 다른 작업이 소유한 r 은 도구가 호출한 실행을 몰라서 호출 때 못 가려요. 턴 끝 저장 transaction 이 거절하고(`Turn_continuation_unpersisted`), 모델은 거절 문구를 받지 못해요. 턴이 끝나고 슬롯이 비는 것과 소유 기록은 같은 transaction 이에요.
- **Resolve** 는 영수증이 outbox 에 쓰였다는 통지예요. waiting 만 ready 로 바꿔요. 통지는 request 를 가리킬 뿐이라 안 기다린 queued 작업과 끝난 작업을 가르지 못해요. 같은 통지가 또 오거나, 그 request 를 기다리지 않는 작업이나 이미 끝난 작업에 오면 그대로예요(4.4).
- **Fail** 은 도는 턴이 오류나 operator interrupt 로 끝난 거예요(2.2). 영수증은 지우지 않아요(2.7).
- **Cancel** 은 도는 작업에는 없어요(2.2). 도는 작업은 Fail 로 끝나요.
- **Restart** 는 행과 영수증이 남아요. 도는 턴과 worker 는 사라져요(2.8). running 작업이 continuation 을 쥐고 있으면(체크포인트에서 claim 한 작업) failed 가 아니라 `Queued` 로 돌아가고 항목은 그대로예요. 항목이 모두 `Arrived` 면 ready, `Pending` 이 있으면 waiting 이에요.

`waiting` 과 `ready` 는 reducer 에 새 상태를 더하지 않아요. **[사실]** 부모 RFC 가 말한 「claim 못 함의 새 이유」는 reducer 가 아니라 `blocked_queued_scopes` 와 실행 기록의 일이에요(2.4).

### 3.3 영수증

**[제안]** request 하나의 상태예요. worker 가 영수증을 쓰는 한 단계(`Retain`)는 정상 종료, raise, abort 를 모두 덮어요. 셋 다 영수증 하나로 끝나기 때문이에요(2.6).

| 상태＼사건 | StartRun | Retain | Restart | RecoverUnfinished | Ack |
|---|---|---|---|---|---|
| idle | → running | 거절 | 그대로 | 거절 | 거절 |
| running | 거절 | → written | → orphaned | 거절 | 거절 |
| orphaned | 거절 | 거절 | 그대로 | → written | 거절 |
| written | 거절 | 거절 | 그대로 | 거절 | → acked |
| acked | 거절 | 거절 | 그대로 | 거절 | 거절 |

- **running** 은 worker 가 도는 request 예요.
- **orphaned** 는 request 기록은 남았고 worker 는 죽은 상태예요. 부팅의 `deliver_unfinished_runs` 가 `Unfinished` 영수증을 써서 written 이 돼요(2.6).
- **Ack** 는 영수증을 읽은 run 이 `Completed` 로 끝날 때만 일어나요. 읽은 것만 지워요(2.7).

### 3.4 소유 기록

**[제안]** `owns[t]` 는 작업 t 가 소유한 request 의 집합이에요. 규칙은 넷이에요.
1. Wait(r) 이 r 을 더해요. 이미 다른 작업의 `owns` 에 든 r 이면 Wait 은 거절이에요.
2. 작업이 waiting, ready, running 을 오가도 빼지 않아요. 재개한 턴이 다시 Wait 해서 슬롯을 놓아도 앞서 받은 영수증은 아직 지워지면 안 되기 때문이에요.
3. 작업이 끝나면(Complete, Fail, Cancel, continuation 없는 running 의 Restart) 같은 전이에서 비워요. 실행 기록에서는 `Settle`, 또는 origin 이 `Interrupted_execution` 인 `Require_reconciliation` 이 비워요(2.8). continuation 이 있는 running 의 Restart 는 비우지 않아요.
4. 영수증을 읽을 때 소유자가 아닌 run 은 소유된 영수증을 읽지 않아요(4.3).

### 3.5 불변식

모델의 `Safety` 는 아래 여덟과 `TypeOK` 의 논리곱이에요. 마지막 줄은 liveness 속성이에요.

| 이름 | 뜻 | 단독으로 깨는 버그 설정 |
|---|---|---|
| `SlotMatchesTask` | 슬롯이 가리키는 작업만 running 이고, running 작업은 슬롯을 쥐어요 | duplicate-resolve |
| `OneOwner` | request 하나의 소유자는 많아야 하나예요 | duplicate-wait |
| `OwnerIsLive` | 끝난 작업은 아무것도 소유하지 않아요 | cancel-keeps-owner |
| `WaitingHasRequest` | waiting, ready 작업은 자기가 소유한 request 하나를 가리켜요 | 없음. 다른 불변식이 먼저 걸려요 |
| `WaitingHasSource` | waiting 작업의 request 에는 worker, 부팅이 영수증을 쓸 기록, 영수증 중 하나가 있어요 | restart-loses-request |
| `ReadyHasReceipt` | ready 작업의 영수증은 outbox 에 있어요 | unfiltered-load |
| `ClaimedHasReceipt` | claim 된 작업이 소유한 영수증은 모두 outbox 에 있어요 | claim-while-waiting |
| `TerminalIsFinal` | 끝난 작업의 상태는 바뀌지 않아요 | revive-cancelled |
| `WaiterResolves` | waiting 은 언젠가 waiting 이 아니게 돼요(`Retain`, `RecoverUnfinished`, `Resolve` 가 공정할 때) | wake-never-delivered |

## 4. 영수증의 소유

### 4.1 누가 소유하나

**[제안]** wait 를 부른 채팅 작업이 소유해요. 소유 단위는 Keeper 도, outbox 파일도, 순찰 턴도 아니에요. 키는 request_id 예요(영수증의 `call_id`, 2.6). 소유는 Wait 의 transaction 에서 생기고 작업이 끝나는 전이에서 풀려요. 다른 작업으로 넘어가지 않아요.

**[사실]** 소유가 필요한 이유는 지금 규칙에서 나와요. 영수증은 Keeper 단위이고 `Completed` 로 끝난 어떤 run 이든 자기가 읽은 영수증을 지워요(2.7). 순찰 턴이 먼저 읽고 끝나면 기다리던 작업이 재개했을 때 받을 영수증이 없어요. 모델 반례 `unfiltered-load` 가 이 순서예요. 작업이 wait 를 부르고, 순찰 run 이 영수증을 읽고, `Completed` 로 지워서, ready 작업의 영수증이 없어져요(반례 7단계).

### 4.2 어디에 적나

| 안 | 어디에 | 장점 | 대가 |
|---|---|---|---|
| (i) **[제안·추천]** | 실행 기록의 새 필드 `receipt_obligations`. 이어받는 길은 지금 있는 checkpoint continuation 이에요(origin 변경 없음) | `Settle` 이 필드를 비워서 cancel, fail, succeed, 재시작 settle 이 한 전이로 풀어요. `gate_obligations` 가 같은 모양이에요(2.3). 표 DDL 은 그대로예요(`phase` 열 여섯 값, 2.3) | 기록 형식 `v3`(7절). request 하나에 소유자 하나인지는 DB 가 아니라 Owner 가 한 transaction 에서 확인해요. Owner 는 Keeper 마다 하나이고 명령을 하나씩 처리해요(`keeper_owner.ml:2740-2748` 처럼 명령마다 `loop state`) |
| (ii) | `recovery_origin` 의 새 variant `Receipt_wait` | 상태가 phase 에 드러나요 | `Input_wait` 가 든 줄이 lib/ 에서 7개 파일 51줄이에요(`rg -c Input_wait lib` 합). 같은 크기의 갱신이 `Receipt_wait` 에 필요해요. `Input_wait` 는 체크포인트 재개가 아니라고 문서가 말하는데(2.3), 여기서는 체크포인트로 재개해야 해요 |
| (iii) | 새 표 `receipt_waits(request_id PRIMARY KEY, operation_id)` | DB 가 `OneOwner` 를 막아요 | 표가 늘어서 DB 스키마가 `v4` 예요. 끝나는 길마다(`persist_terminal`, 재시작 settle, 취소) 지우기를 따로 넣어야 해요. 한 곳을 빠뜨리면 `OwnerIsLive` 가 깨져요 |
| (iv) | outbox 영수증 파일에 `owner` 필드 | 읽는 쪽이 파일만 보면 돼요 | 파일 이름이 내용에서 나오고(`keeper_client_tool_outbox.ml:61-63`) 지울 때 내용이 같은지 비교해요(`:592-601`). 소유를 적으면 이름과 비교가 깨져요. 쓰지 않아요 |

**[제안]** (i)을 써요. 근거는 둘이에요. 끝나는 길이 여럿인데 `Settle` 하나가 소유를 푸는 구조가 N곳 패치를 막아요. 그리고 재개가 지금 있는 checkpoint continuation 이라서 `finish_operation_child` 의 continuation 확인(2.4)에 새 probe 가 필요 없어요. 대가는 7절에 있어요.

**[사실]** 부모 RFC 9절이 열어 둔 질문 둘의 답이에요. 소유는 작업 기록에 둬요(outbox 영수증이 아니에요, (iv)). 새 상태는 `recovery_origin` 의 새 variant 없이 되고(i), (ii)는 되지만 비싸요.

### 4.3 읽는 곳이 소유를 보게 하는 방법

**[제안]** `Keeper_client_tool_outbox.load` 에 필수 인자 `~viewer` 를 더해요. 값은 닫힌 타입이에요.

```
type viewer =
  | Unowned_only
  | Owner_and_unowned of Keeper_execution_scope_id.t
  | Every_receipt
```

필수 인자라서 호출처가 값을 적지 않으면 컴파일이 안 돼요. 열한 번째 호출처가 생겨도 소유를 건너뛸 수 없어요.

| 호출처(2.7) | viewer | 이유 |
|---|---|---|
| 1, 2, 3 run 의 carrier(runtime 넷의 `run`, `try_provider`) | `keeper_turn_driver.ml` 이 정해요. 직접 턴이면 `Owner_and_unowned` 에 자기 작업, 그 밖은 `Unowned_only` | 재개한 작업은 자기 영수증과 주인 없는 영수증을 받아요. 순찰 run 은 주인 없는 것만 받아요 |
| 공식 클라이언트 host, 도구 hook | `Unowned_only` | 소유자가 아닌 곳이라 주인 없는 것만 봐요 |
| 4 `notify` | stimulus 용으로는 `Unowned_only`. 소유된 영수증은 stimulus 를 만들지 않고 `Receipt_arrived` 로 Owner 에게 알려요(4.4) | 소유된 영수증으로 `Tool_result_ready` 를 계속 쌓으면 읽을 run 이 없는 stimulus 가 남아요 |
| 5 stimulus 점검 | `Unowned_only` | 영수증이 stimulus 를 큐에 넣은 뒤 소유됐으면 점검이 「없음」으로 답하고 stimulus 를 거둬요 |
| 6 `holds_receipt` | `Every_receipt` | 가드는 「이 request 의 영수증이 있나」를 물어요. 소유자가 숨기면 가드가 없다고 답해서 `Unfinished` 가 하나 더 쓰여요. 가드 주석이 막으려던 일이에요(`keeper_execute_background.ml:155-157`) |

### 4.4 통지와 Resolve

**[제안]** `notify` 는 주인 없는 영수증만 stimulus 로 만들어요(`Unowned_only`). 소유된 영수증은 `Keeper_receipt_wait_resolution.arrived` 가 Owner 에게 `Receipt_arrived request_id` 로 알려요. Owner 는 그 request 를 가진 `Pending` 항목을 `Arrived` 로 바꾸고(실행 기록의 revision 비교), `start_child_if_needed` 를 불러요. 이미 `Arrived` 이거나 없으면 아무것도 안 해요.
- **[사실]** 지금 `notify` 와 `pulse` 는 시작할 때와 tick 마다 불려요(2.7).
- **[제안]** 소유된 영수증의 통지도 같은 길로 보내요. 통지 하나를 놓쳐도 다음 tick 에 다시 와서 지연이 되고, 영영 안 오지는 않아요. 모델에서는 `Resolve` 가 공정하다는 가정이에요. 가정을 빼면 `WaiterResolves` 가 깨져요(`wake-never-delivered`).
- **[제안]** `Pending` 항목이 하나라도 있는 실행 기록은 claim 못 해요. `blocked_queued_scopes` 의 여섯째 이유예요. 기존 다섯 이유와 같은 closed match 에 넣어요(2.4).
- **[제안]** 영수증이 턴이 끝나는 동안 도착하면 통지를 받을 `Pending` 항목이 아직 없어요. 이 틈은 기다림을 저장한 직후 한 번 부르는 `Keeper_receipt_wait_sweep.after_wait` 가 막아요. 도착한 영수증을 `Arrived` 로 바꾸고 `settle_lost`(5.2)도 해요. 이 호출이 실패하면 경고만 남기고 다음 maintenance 에 맡겨요.
- Owner 는 폴링하지 않아요. 통지는 `notify` 가 보내요(2.4).

## 5. 실패

### 5.1 서버 재시작

- **[사실]** `Queued` 행과 outbox 는 남아요. worker 는 서버 수명 switch 라서 죽어요(2.6, 2.8).
- **[제안]** waiting, ready 작업은 재시작 뒤에도 그대로예요(전이표 Restart 열). 소유 기록은 실행 기록에 있어서 같이 남아요.
- **[사실]** worker 가 죽은 request 는 부팅이 `Unfinished` 영수증을 써요. `RecoverUnfinished` 예요(2.6).
- **[제안]** 영수증이 쓰이면 `notify` 가 소유 작업에 알리고, waiting 이 ready 가 돼요.
- **[제안]** 재개한 작업은 `Unfinished` 영수증을 보통 영수증처럼 받아요. 무엇을 할지는 모델이 정해요.
- **[사실]** 재시작 때 running 이던 작업은 continuation 이 없으면 `Failed` 예요. continuation 이 있으면 `Queued` 로 돌아가요(2.8).
- **[제안]** `Failed` 가 된 작업의 소유는 `Settle`(또는 origin 이 `Interrupted_execution` 인 `Require_reconciliation`)이 풀어요. `Queued` 로 돌아간 작업은 소유 항목이 그대로 남아요. Wait 의 소유 기록과 체크포인트 defer 를 한 transaction 으로 하면 둘 사이에 재시작이 끼어들 틈이 없어요(6절 3단계).
- 모델: `Restart`, `RecoverUnfinished`. `orphan-wait-reachable` 이 「waiting 인데 worker 가 죽은 상태」에 이르는 길이 있다는 것을 보여요(반례 5단계). 이 상태에서 `WaitingHasSource` 는 지켜져요.

### 5.2 worker 종료

- **[사실]** worker 의 raise 는 `Unfinished` 영수증, worker 취소는 abort 영수증이에요(2.6). 정상이든 아니든 영수증 하나가 outbox 에 남고, 모델의 `Retain` 한 단계가 이 셋을 덮어요.
- **[제안]** waiting 작업은 이 영수증을 받고 ready 가 돼요. 특별한 길이 없어요.
- **[사실]** 영수증이 아예 안 쓰이는 경우가 하나 있어요. 부팅 때 active 목록을 읽지 못하면 영수증을 쓰지 않아요(2.6). 그 request 를 기다리는 작업은 영영 waiting 이에요. 모델 반례 `restart-loses-request` 예요(5단계, `WaitingHasSource` 위반).
- **[제안]** 두 길이 있어요.
  - (a) 소유 기록이 request 를 알고 있어요. `Pending` 항목의 request 가 끝났거나 끊겼는데 영수증이 outbox 에 없으면 typed 해결 `Source_lost` 로 `Arrived` 처리하고, 같은 request_id 로 `Unfinished` 영수증을 한 번 써서 재개한 작업이 받게 해요. 영수증은 `retain_source_lost_receipt`(새 함수)가 써요. 이미 영수증이 있으면 쓰지 않아요.
    - 판정은 목록이 아니라 request 하나를 찾는 읽기로 해요. 못 읽은 것이 바로 active 목록이기 때문이에요. 읽기는 `Keeper_msg_async.load_canonical_request` 예요(`Found | Absent | Unreadable | Rejected`). worker 가 아직 있을 수 있는 request 상태는 계속 기다려요.
    - 실행은 `Keeper_receipt_wait_sweep.settle_lost` 예요. maintenance 의 `reconcile` 이 Keeper 마다 `notify` 다음에 불러요. `Keeper_client_tool_outbox_wake` 가 sweep 을 직접 부르면 모듈 순환이 생겨서 `create ~settle_lost_waits` 로 주입해요.
  - (b) 부팅 때 active 목록을 못 읽으면 Keeper lane 을 시작하지 않아요.
  - 추천은 (a)예요. (b)는 파일 하나를 못 읽은 일이 Keeper 하나의 정지로 번져요. (a)의 대가는 owner 쪽에 request 기록을 읽는 길이 하나 늘어나는 거예요.
- **[사실·결정]** `Unfinished` 영수증의 `arguments` 는 request 기록이 남겨 둔 인자를 그대로 실어요(`Known`). request 기록이 `Absent` 이거나 Execute 백그라운드 요청의 기록이 아니면 인자를 알 길이 없어요. 읽은 범위에서 request_id 로 인자를 찾는 기록은 request 기록(`request_context` 의 `execute_background.arguments`) 하나뿐이에요. 실행 기록의 `input` 은 채팅 입력이고, 채팅 턴의 Execute 는 도구 실행 journal 에 request_id 로 남지 않아요. 빈 객체로 채우면 모델은 「인자 없이 Execute 를 불렀다」는 거짓 사실을 읽어요. 사용자가 typed 부재를 골랐어요(9절 3). 영수증 `arguments` 가 `Known | Unknown` 이 되고, `Unknown` 이면 메시지도 그렇게 말해요. outbox 형식이 바뀌어요(7절).
- **[제안]** `Source_lost` 판정은 시간 임계 없이 상태로만 해요. 「소유된 request 가 끝났거나 끊겼고, 영수증이 outbox 에 없다」예요. 4.3 의 `viewer` 가 있으면 소유된 영수증은 소유자만 지워요. 그래서 다른 run 이 소유된 영수증을 지워서 이 판정이 잘못 나오는 경우는 없어요.

### 5.3 영수증 중복

- **같은 영수증의 통지가 여럿.** **[사실]** `notify` 는 ACK 될 때까지 tick 마다 같은 stimulus 를 다시 알려요(2.7). **[제안]** Resolve 는 같은 request 에 대해 한 번만 상태를 바꿔요. ready 나 running 인 작업에 오는 통지는 그대로예요(3.2). 모델 `duplicate-resolve` 는 이 가드를 빼고, 통지가 running 작업을 ready 로 되돌려서 `SlotMatchesTask` 가 깨지는 반례를 내요(7단계).
- **같은 request 의 영수증 둘.** **[사실]** `holds_receipt` 가드가 `Unfinished` 의 중복을 막아요(2.6). **[확인 필요]** 가드는 읽고 쓰는 두 단계라서, worker 의 정상 종료와 abort 경로가 동시에 오면 둘이 쓰일 수 있는지는 읽지 않았어요. 모델에는 request 당 영수증이 하나예요.
- **다른 작업이 소유한 request 를 또 기다림.** **[제안]** 소유 기록을 쓰는 턴 끝 저장 transaction 이 거절해요(3.2). 도구는 호출한 실행을 몰라서 호출 때는 못 가려요. 모델 `duplicate-wait` 는 거절을 빼고, 영수증 하나를 두 작업이 소유하는 반례를 내요(6단계, `OneOwner` 위반).
- **다른 run 이 소유된 영수증을 읽음.** **[제안]** 4.3 의 `viewer` 가 막아요.

### 5.4 취소된 작업에 영수증이 늦게 옴

- **[사실]** 작업 취소는 worker 를 멈추지 않아요(2.8). 영수증은 나중에 써져요.
- **[제안]** 취소는 소유를 같은 transaction 에서 풀어요. `cancel_queued` 가 `Settle Cancelled` 를 같은 transaction 에서 해요(2.2, 2.3). 영수증은 주인 없는 영수증이 돼서 다음 run 이 보통 영수증처럼 받아요. 작업은 되살아나지 않아요.
- 모델: `late-receipt-reachable` 은 「취소된 작업이 기다리던 영수증이 outbox 에 있는」 상태가 닿을 수 있다는 것을 보여요(반례 6단계). 이 경로가 도달 가능해야 아래 두 버그 설정이 의미가 있어요.
  - `revive-cancelled`: 늦은 영수증이 취소된 작업을 ready 로 되살려요. `TerminalIsFinal` 이 깨져요(7단계).
  - `cancel-keeps-owner`: 취소가 소유를 풀지 않아요. 영수증을 아무도 못 읽고 `OwnerIsLive` 가 깨져요(5단계).
- **[제안·결정 필요]** 작업을 취소하면 worker 도 취소할지는 이 설계가 정하지 않아요. 추천은 취소하지 않는 거예요(9절 4).

## 6. 체크포인트 재개가 지금 있는 길을 쓰는 방법

| 단계 | 지금 코드(2절) | 이 설계가 더하는 것 |
|---|---|---|
| 1. 모델이 wait 도구를 부름 | `Generic_deferred` 도구 결과가 턴을 체크포인트 길로 끝내요(`keeper_tools_agent_core_bundle.ml:248-257`, `keeper_tool_terminal_boundary.ml:1-5`) | 도구 하나. `Generic_deferred` 가 아니라 일반 도구예요. `Terminal` 서술자는 Agent Core 가 결과를 `Completed` 로 끝내서 못 써요. 도구 결과의 `terminal_effect_receipt` 에 `Receipt_wait_requested {request_id}` 를 실어 `keeper_turn.ml` 의 `defer` 까지 나르고, 왼쪽 줄 번호는 그 사이 바뀌었어요. 직접 작업이 아닌 턴(순찰, 자율, 검증)에는 `Keeper_run_tools_setup.descriptors_for_run` 이 도구를 빼서 모델이 보지 못해요 |
| 2. 턴이 체크포인트로 끝남 | `keeper_turn.ml:1057-1081` 의 checkpoint 갈래 → `defer`, `defer_official`(`keeper_direct_checkpoint_continuation.ml:85-104`) | 없음. 새 갈래가 아니에요. `InputRequired` 갈래는 안 써요. 입력 대기는 체크포인트 재개가 아니에요(2.3). 기다림을 요청했는데 턴이 체크포인트로 끝나지 않거나 `InputRequired` 와 겹치면 기다림을 버리지 않고 에러로 끝내요 |
| 3. 저장 | `defer_direct_checkpoint` 한 transaction: Suspend, 큐로 되돌림, 순서 이동(`keeper_chat_operation_store.ml:2616-2670`) | 같은 transaction 에 `receipt_obligations` 에 request 를 `Pending` 으로 더하는 한 단계. 다른 실행 기록이 이미 소유한 request 면 transaction 이 거절 |
| 4. claim 못 함 | `blocked_queued_scopes`(`:1731-1753`) | 여섯째 이유: `Pending` 항목이 있다 |
| 5. 영수증 도착 | `notify`, `pulse`(`keeper_client_tool_outbox_wake.ml:36-100`) | 소유된 영수증은 `Receipt_arrived` 로 Owner 에 알려요. `Pending` 이 `Arrived` 가 돼요(4.4) |
| 6. claim 과 재개 | `claim_next`(`:1881-1947`), `resume_direct_checkpoint`(`:2672-2704`), `Keeper_direct_checkpoint_continuation.load` 와 consume(`:43-83`) | 없음. 재개한 run 의 carrier 만 `Owner_and_unowned` 로 영수증을 읽어요(4.3) |
| 7. 끝 | `settle_after_turn` 이 `Completed` 일 때만 지워요(`keeper_client_tool_outbox.ml:603-607`). `Settle` | `Settle` 이 `receipt_obligations` 를 비워요(`keeper_semantic_execution.ml:885` 의 `gate_obligations` 와 같은 자리) |

- **[사실]** 공식 클라이언트는 `defer_official` 이 이미 있어요. 긴 기다림 뒤에 벤더 세션을 Resume 할 수 있는지는 읽지 않았어요(10절).
- **[사실]** 재개 뒤 첫 요청의 입력은 체크포인트와 영수증 carrier 예요. 도는 중 입력은 바뀌지 않아요(부모 RFC 4.2).

## 7. hard cut

**[제안]** 하나의 형식 변경이고 둘로 읽어요. 부모 RFC 4.2 비용 (2) 저장소 스키마와 (4) 영수증 소유 기록이에요. (i)에서는 같은 필드에 모여요.

- 변경 1: 실행 기록 `masc.keeper_semantic_execution.v2` 가 `v3` 가 돼요. 필드 `receipt_obligations` 가 더해지고, 읽을 때 필드 목록과 `schema` 문자열이 `v3` 와 맞아야 해요(현재 `v2` 는 `keeper_semantic_execution.ml:1022`, `:1362-1367`).
- 변경 2: outbox 영수증의 `arguments` 가 `Known | Unknown` 이 돼요(5.2). 소유 기록은 outbox 에 안 적지만, 출처가 없어진 request 의 영수증이 인자를 모른다고 적을 자리가 필요해서 영수증 형식이 바뀌어요. 사용자가 이 방식을 골랐어요(9절 3).
- **안 바뀌는 것.** SQLite DDL(`database_schema` `:85`, `semantic_table_sql` `:93-109`)이에요.
- **Fresh state contract.** 이 빌드는 자기가 쓴 형식만 읽어요. `v2` 기록과 옛 모양의 영수증은 읽지도, 변환하지도, 옮기지도 않아요(`docs/guides/DURABLE-STORE-HARD-CUT.md:32-37`). 구현 PR 은 `changelog.d/` 에 `Fresh state required` 항목을 둬요. 항목이 말하는 것은 둘이에요. 지울 것은 Keeper 마다 `chat-operations.sqlite3` 와 sidecar, 그리고 Keeper 마다 `<base-path>/.masc/keepers/<keeper>/official-client-runtime/undelivered-tools/*.json` 이에요. 지우면 사라지는 것은 큐, 실행 기록, 입력 이력(같은 문서 `:55-85`)과 아직 어떤 run 도 읽지 않은 영수증이에요.
- **코드 없음.** `v2` reader, converter, migration, 옛 영수증을 `Known` 으로 읽는 길을 만들지 않아요. 옛 빌드로 되돌리면 `v3` 기록과 새 영수증을 옛 빌드가 거절해서 마찬가지로 fresh state 가 필요해요.
- 영수증 형식은 `arguments` 가 `{"known": 값}` 이나 `{"unknown": true}` 두 모양일 때만 받고, 값이 그대로인 옛 영수증은 거절해요. 이 검사는 모양 검사예요. 옛 파일의 `arguments` 가 우연히 정확히 그 두 모양이었다면 새 형식으로 읽혀요. 실제 Execute 나 벤더 인자에서 나올 일은 없어 보이지만(확신 Medium) 막혀 있지는 않아요. 구조로 막으려면 필드 이름을 바꿔야 하고, 그러면 모델이 읽는 JSON 이 바뀌어요.
- **[사실]** 이 hard cut 이 바꾸는 것이 아닌데 눈에 띈 것이 둘이에요. 이 RFC 는 같은 모양의 코드를 더하지 않아요.
  - `keeper_semantic_execution.ml:1359-1360` 은 `gate_obligations` 가 없는 옛 기록에 `[]` 를 채워 읽어요.
  - `prepare_v2_copy` 는 v2 저장소를 v3 로 옮기는 오프라인 복사예요(`keeper_chat_operation_store.ml:1346-1383`).
  - 정책과 어긋나 보여요. 이슈로 남길지는 9절 7 에 있어요.

## 8. 하네스

### 8.1 전후 측정(고정)

**[사실]** 값은 부모 RFC 1절과 6절에서 가져와요. 이 글이 새로 잰 값이 아니에요. 측정 스크립트와 그 시험은 구현 PR 과 다른 변경에 두고, 구현이 기준을 못 바꾸게 해요.

- 기준 스크립트: `queue_wait_overlap.py --hold-s 60`, 72시간 창. W1 은 2026-11-08T05:40Z ~ 11-11T05:40Z 예요.
- 기준값: 겹침 15.519 h(Keeper 시간), 작업별 합 42.457 h, 큐 대기 합 196.34 h. 60초 이상 Execute 1,183번(74.214 h).
- 분할 행: 「직접 · `sleep` 있음 · `gh` 확인」 286번, 기다림 10.629 h. 같은 창을 다시 재면 값이 달라지는 범위는 0.432 h 예요.
- 큐 대기 분위수: 중앙값 7.8초, p90 1,527.6초. 60초 임계가 측정의 일부라서 임계 아래로 쪼갠 호출은 겹침만 줄이고 대기는 그대로이기 때문에 이 값을 같이 고정해요.
- 새 호출의 쓰임: `masc_schedule_create until_github_run` 255번(직접 턴 55), 같은 기다림을 `sleep` 으로 한 60초 이상 호출 683번(직접 턴 286). 두 값을 함께 읽어요.

### 8.2 지우는 조건

- 도입 뒤 같은 길이 창에서 「직접 · `sleep` 있음 · `gh` 확인」 행이 잡음(0.432 h) 밖으로 줄지 않으면 모델이 새 도구를 쓰지 않은 거예요. 이 설계를 지워요.
- 줄었는데 큐 대기 합과 p90 이 줄지 않으면 겹침이 대기의 원인이 아니에요.
- 재개한 작업의 첫 요청에 기다리던 request 의 영수증이 한 번이라도 없으면 소유 규칙이 틀린 거예요.

### 8.3 상태 검사

시간 임계 없이 상태로 가려요. 아래 넷은 모두 0 이어야 해요.

1. **소유된 영수증이 다른 run 의 snapshot 에 든 경우.** 모델 `OneOwner`, `ReadyHasReceipt` 의 구현 쪽 검사예요. run 마다 snapshot 의 request 목록과 소유 기록을 대조해요.
2. **재개한 작업의 첫 요청에 기다리던 영수증이 없는 경우.** 모델 `ClaimedHasReceipt` 의 구현 쪽 검사예요.
3. **`Tool_result_ready` 로 시작한 순찰 턴의 첫 요청이 영수증을 0개 싣는 경우.** 부모 RFC 6절과 같아요. 깨움 하나와 턴 시작은 같지 않아요(`keeper_client_tool_outbox_wake.ml:52-54` 주석). 4.3 의 4번과 5번이 막는 일이에요.
4. **깨움을 놓친 경우.** 부모 RFC 6절 검사를 고쳐요. 「`Pending` 항목이 있고, 그 request 의 영수증이 outbox 에 있고, owner 가 한 번의 `pulse` 와 drain 을 끝낸 뒤에도 그대로」인 상태예요. 영수증이 쓰인 직후 그 항목이 `Pending` 인 것은 정상이에요(1절 2). owner 시험은 모든 drain 단계와 재시작 직후에 이 상태를 확인하고, 스크립트는 저장소와 outbox 를 같이 읽어요.

### 8.4 TLA+ 모델

**[사실]** 파일은 `specs/bug-models/KeeperReceiptWait.tla` 와 cfg 열네 개예요. `Spec` 은 정상(`Next`)이에요. 버그 설정은 행동 하나를 `Next` 에 더한 `NextBuggy == Next \/ BugAction` 이고, 각 버그 cfg 는 그 버그를 혼자 잡을 불변식이나 속성 하나만 켜요(기존 규칙: `specs/bug-models/` 의 다른 모델과 같아요). 모델 머리말에 코드 대응표와 추상화가 있어요.

**[사실]** 모델 크기는 작업 2개, request 2개, 재시작 최대 1번, 순찰 run 최대 2번이에요. 표의 값은 `tla2tools-1.8.0.jar`(TLC2 Version 2026.05.26.235334)를 `specs/Makefile` 과 같은 옵션(`-XX:+UseParallelGC -Xmx2g`, `-Dtlc2.TLC.stopAfter=180`)에 `-workers 1` 로 돌려서 cfg 마다 한 번씩 읽은 거예요. 반례 길이는 초기 상태를 포함한 상태 수예요. 한 cfg 를 다시 돌리는 명령은 이래요.

```
cd specs && java -XX:+UseParallelGC -Xmx2g -cp ~/.local/lib/tla/tla2tools-1.8.0.jar tlc2.TLC -workers 1 -config bug-models/KeeperReceiptWait.cfg bug-models/KeeperReceiptWait.tla
```

| cfg(`KeeperReceiptWait` 뒤) | 모델링한 실패 | 결과 | 생성 | 서로 다른 | 깊이·반례 길이 |
|---|---|---|---:|---:|---:|
| (없음) | 정상 | 위반 없음(`Safety`, `WaiterResolves`) | 75,517 | 26,970 | 깊이 20 |
| `-claim-while-waiting-buggy` | B1. waiting 인 작업을 claim | `ClaimedHasReceipt` 위반 | 175 | 130 | 5 |
| `-duplicate-wait-buggy` | B2. 소유된 request 를 또 기다림 | `OneOwner` 위반 | 615 | 388 | 6 |
| `-unfiltered-load-buggy` | B3. 소유를 안 보고 읽는 run | `ReadyHasReceipt` 위반 | 1,960 | 1,013 | 7 |
| `-revive-cancelled-buggy` | B4. 늦은 영수증이 취소된 작업을 되살림 | `TerminalIsFinal` 위반 | 1,765 | 991 | 7 |
| `-cancel-keeps-owner-buggy` | B5. 취소가 소유를 안 풀음 | `OwnerIsLive` 위반 | 213 | 130 | 5 |
| `-restart-loses-request-buggy` | B6. 재시작이 request 의 출처를 잃음 | `WaitingHasSource` 위반 | 199 | 137 | 5 |
| `-duplicate-resolve-buggy` | B7. 같은 통지가 running 작업을 되돌림 | `SlotMatchesTask` 위반 | 1,756 | 983 | 7 |
| `-wake-never-delivered-buggy` | B8. 통지가 영영 안 옴(공정성 제거) | `WaiterResolves` 위반(liveness) | 71,709 | 25,906 | 깊이 17, 반례 13 |
| `-buggy` | B1~B7 한꺼번에 | `Safety` 위반 | 252 | 137 | 5 |
| `-resume-reachable-buggy` | 가드. 기다린 작업이 재개해 성공함 | 도달함(위반이 맞아요) | 1,752 | 979 | 7 |
| `-orphan-wait-reachable-buggy` | 가드. worker 가 죽은 request 를 기다림 | 도달함 | 174 | 129 | 5 |
| `-late-receipt-reachable-buggy` | 가드. 취소된 작업의 영수증이 도착함 | 도달함 | 589 | 369 | 6 |
| `-restart-requeue-reachable-buggy` | 가드. 재개한 작업이 재시작으로 큐에 돌아가 다시 claim 되어 성공함 | 도달함 | 9,382 | 4,205 | 9 |

- **[사실]** `Restart` 는 두 갈래예요. 대기를 한 번 거쳐 claim 된 running 작업(모델의 `lastwait` 가 있는 작업)은 continuation 을 쥔 것으로 보고 소유를 지킨 채 ready 로 돌려요. 대기한 적 없는 running 작업은 continuation 이 없다고 보고 failed 로 만들고 소유를 비워요(3.2, 2.8). 돌려보낼 때 모델이 끝난 작업의 이력 변수 `requeued` 에 적어요. 소유를 비우는 쪽으로 바꾼 변이를 임시로 돌려 보면 `Safety` 가 위반돼요(저장소에 없어요).
- 표의 가드 넷(`-resume-reachable`, `-orphan-wait-reachable`, `-late-receipt-reachable`, `-restart-requeue-reachable`)은 정상 모델이 그 길에 닿는다는 것을 보여요. 길이 막히면 불변식이 아무것도 안 지키는데 통과해요. 가드가 먼저 빨개져요.
- 종료 코드는 정상 0, 버그 cfg 는 12(불변식 위반) 또는 13(속성 위반)이에요. `specs/Makefile` 의 `check-buggy` 가 같은 규칙으로 읽어요.
- **[사실]** `specs/Makefile` 의 `check-others` 샤드가 `bug-models/` 를 포함해요(`:143-149`). `.github/workflows` 에서 `check-others` 를 부르는 곳은 없어요. `model-check.yml` 은 `workflow_dispatch` 로만 돌고 `scripts/tla-check.sh` 를 부르는데, 그 스크립트는 `bug-models/` 를 다루지 않아요. 이 모델은 사람이 `make -C specs check-others` 를 돌릴 때만 돌아요. 구현 PR 이 모델과 어긋나도 CI 가 알려 주지 않아요. 모델을 PR 검사로 돌리는 일은 이 RFC 범위 밖이에요.
- 이 모델이 못 보는 것은 10절에 있어요.

## 9. 사용자가 정할 것

정석 쪽을 근거와 대가를 달아 먼저 써요.

**결정(사용자, 2026-11-12, AskUserQuestion 응답).** 1, 2, 3, 5번은 아래 추천대로 정했어요: 소유 기록은 실행 기록의 새 필드(`receipt_obligations`), `load` 의 `~viewer` 는 필수 인자, 출처 없는 request 는 typed `Source_lost`, wait 는 별도 도구예요. 3번에서 영수증의 `arguments` 를 모를 때는 typed 부재(`Known | Unknown`)로 적기로 했어요. 4, 6, 7번은 아직 정하지 않았고 추천이 기본이에요.

1. **소유 기록을 어디에 적나.**
   - 추천: (i) 실행 기록의 새 필드(4.2).
   - 근거: 끝나는 길이 `Settle` 하나로 모여요. `gate_obligations` 선례가 있어요. 재개가 지금 있는 checkpoint continuation 이에요.
   - 대가: 기록 형식 `v3` 의 fresh state(7절). 요청 하나에 소유자 하나인지를 DB 가 아니라 Owner 가 확인해요. (iii)은 DB 가 막지만 표가 늘고 끝나는 길마다 지우기를 넣어야 해요.
2. **`load` 에 필수 인자 `~viewer` 를 더할지.**
   - 추천: 더해요(4.3).
   - 근거: 읽는 곳이 열이에요(2.7). 한 곳이라도 소유를 건너뛰면 모델 `unfiltered-load` 의 반례가 현실이 돼요. N곳을 손으로 고치는 대신 컴파일러가 빠진 곳을 짚어요.
   - 대가: 호출처 열과 이 모듈을 쓰는 시험이 같이 바뀌어요.
3. **출처가 없어진 request 를 어떻게 하나(5.2).**
   - 추천: (a) typed `Source_lost` 로 해결하고 `Unfinished` 영수증을 한 번 써요.
   - 근거: 파일 하나를 못 읽은 일이 Keeper 하나의 정지로 번지지 않아요.
   - 대가: owner 쪽에 request 기록을 읽는 길이 하나 늘어요(`load_canonical_request`).
   - 인자를 모르는 request(기록이 `Absent` 이거나 Execute 백그라운드 요청의 기록이 아님): 영수증 `arguments` 를 빈 객체로 채우지 않고 typed 부재로 적어요. 선택지 중 인자를 기다림 항목에도 같이 적는 안은 실행 기록이 Execute 명령 본문을 한 부 더 들게 돼서, 영수증 없이 `Source_lost` 로만 닫는 안은 사용자가 정한 「`Unfinished` 영수증 하나」와 달라서 택하지 않았어요.
   - 대가: outbox 영수증 형식이 바뀌어 fresh state 가 하나 더 생겨요(7절).
4. **작업을 취소하면 worker 도 취소할지.**
   - 추천: 취소하지 않아요(5.4).
   - 근거: Execute 는 부작용이 있을 수 있어요. 지금도 worker 취소는 모델이 부르는 별도 도구예요(2.8).
   - 대가: 취소한 작업의 worker 가 끝까지 돌고, 그 영수증은 다음 run 이 받아요.
5. **wait 를 별도 도구로 둘지, `Execute` 의 모드로 합칠지.**
   - 추천: 별도 도구예요. 앞서 시작한 background 호출의 영수증도 기다릴 수 있어요. 이미 영수증이 있을 때는 Wait 이 바로 ready 로 돼요(3.2).
   - 근거: 한 도구는 한 뜻이에요. 합치면 시작과 기다림이 한 호출이라 영수증이 먼저 오는 경우가 없지만, `Execute` 의 뜻이 하나 늘어요.
   - 대가: `config/tools/` 정의 하나. 모델이 두 호출을 이어 불러야 해요. 부모 RFC 가 모르는 것으로 남긴 「모델이 새 호출을 쓸까」는 그대로예요(8.2).
6. **#51302(`keeper-wakes-when-a-pr-check-finishes`)와의 순서.**
   - 두 설계가 같은 기다림을 노려요. 이 설계의 기다림은 request 영수증이고, #51302 는 GitHub check 예요.
   - 그 RFC 의 감시가 영수증을 쓰는 모양이면 이 상태 기계를 그대로 써요. 직접 작업을 열어 두는 모양이면 이 설계와 같은 상태를 둘이 만들어요. 어느 쪽인지 읽지 않았어요(10절).
   - 추천: 한 측정 기준(8.1)에서 먼저 간 쪽을 잰 뒤 다른 쪽의 상한을 다시 재요.
7. **7절에서 눈에 띈 기존 코드 둘을 이슈로 남길지.** 추천: 남겨요. 증상은 hard cut 정책과 어긋난 reader 와 복사 경로, 재현 조건은 `rg` 두 줄이에요. 이 RFC 범위 밖이라 파일은 안 만들었어요.

## 10. 확인하지 못한 것

**읽지 않은 코드.**
- `recover_lost_disk_records` 의 동작은 자세히 읽지 않았어요(5.2).
- 공식 클라이언트에서 긴 기다림 뒤 벤더 세션 Resume 이 되는지. Muse 와 Antigravity 의 resume 은 읽지 않았어요(6절).
- `finish_operation_child` 와 `start_child_if_needed` 가 `blocked_queued_scopes` 를 읽는 비용. drain 마다 실행 기록 전체를 읽어요(`keeper_chat_operation_store.ml:1731-1753`). 이 설계는 항목 하나를 더할 뿐이라고 보지만 재지 않았어요.
- #51302 RFC 가 직접 작업을 열어 두는지(9절 6).
- `rg -c Input_wait` 의 51줄은 줄 수예요. 고쳐야 할 match 갈래의 수가 아니에요.

**모델이 못 보는 것.**
- 크기: 작업 2, request 2, 재시작 1, 순찰 run 2. 이 범위의 통과는 더 큰 범위의 증명이 아니에요.
- 한 request 에 영수증 둘이 쓰이는 경우(5.3). 영수증은 모델에서 id 이고 내용이 없어요.
- request 확인과 outbox 쓰기가 둘인 코드를 모델은 한 단계로 봐요. `Retain` 과 `Resolve` 사이만 한 단계로 떼어 놨어요. `Complete` 는 ACK 와 settle 을 한 단계로 해요.
- Claim 이 아무 claim 가능한 작업을 골라요. FIFO 순서, `defer_direct_checkpoint` 의 순서 이동, 편집, batch member 는 없어요.
- continuation 은 모델에서 「대기를 한 번 거쳐 claim 된 running 작업」으로 근사해요. 대기 없이 체크포인트나 runtime retry 로 끝난 작업의 continuation 은 모델에 없어요.
- 영수증을 받은 작업이 Gate 나 입력 대기 같은 다른 이유(2.4)로 다시 막히는 경우는 모델에 없어요. 3.2 의 ready 는 그런 이유가 없을 때의 뜻이에요.
- 부팅 복구가 영수증을 쓴다고 가정해요. 안 쓰는 경우는 B6 이에요.
- 재시작 직후 orphaned request 에 Wait 을 부르는 경우는 모델이 거절해요. 코드에서 그런 호출이 가능한지 읽지 않았어요.
- 시간, 여러 Keeper, 벤더 세션, 체크포인트 payload, stimulus 큐.
- 구현은 이 모델의 증명이 아니에요. 8.3 의 상태 검사와 owner 시험이 같은 불변식을 구현 쪽에서 확인해요.
