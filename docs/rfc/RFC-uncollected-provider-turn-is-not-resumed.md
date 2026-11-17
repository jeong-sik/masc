---
rfc: "uncollected-provider-turn-is-not-resumed"
title: "After a restart, the claim closes a turn cut before collection instead of resuming it"
status: Draft
created: 2026-11-16
updated: 2026-11-17
author: claude-main
related: ["restart-resumes-running-chat-operations"]
---

# RFC: 응답을 모으기 전에 끊긴 턴은 재기동 뒤 그 작업을 집은 claim 이 닫는다

- 관련: #52341, #42073, #47059
- 결정(운영자, 2026-11-16): 끊긴 메시지는 이어 한다. 닫은 뒤 호출 전 체크포인트에서 새 호출로 잇는다. 두 재시작 경로를 함께 바꾸는 일은 `restart-resumes-running-chat-operations` 가 다룬다.
- 결정(2026-11-17): 닫는 자리는 기동 정리가 아니라 그 작업을 집은 claim 이다. 근거와 닫은 뒤의 순서는 `restart-resumes-running-chat-operations` §4.4 다.
- 범위:
  - agent_core: 실행 기록(journal)을 읽고, 모으기 전에 끊긴 턴이면 닫는 함수 하나.
  - masc: claim 이 native 호출을 열기 직전의 준비(`Keeper_direct_native_continuation.prepare`).
  - 기록 구조, 체크포인트 형식, `Agent.run` 안의 다시 잇기(`Pipeline_execution_resume`)는 바꾸지 않는다.

## 1. 사건

2026-11-15 15:42 UTC 에 운영 서버가 종료 절차 없이 끝났다.
17:00 과 17:06 에 다시 띄우자 Keeper 메시지 8건이 아래 오류로 끝났다(`chat-operations.sqlite3` 에서 `failed / Turn_exception`).

```
Internal error: restored checkpoint turn counter differs from the owning durable turn
```

- 같은 때 `masc restart` 로 끊긴 메시지 3건은 `Interrupted_by_restart` 로 닫혔다.
- 10-09 의 #42073 도 같은 상태로 보인다. 그때는 `provider response authority is not materialized` 로 끝났다.
- #47059(11-02)가 턴 번호 검사를 더한 뒤로 문구만 바뀌었다.

## 2. 왜 문제인가

- provider 호출 중 끊긴 같은 사건을 두 경로가 다르게 끝낸다. 다른 구간에서 끊긴 경우는 4.3 에서 따로 다룬다.
  - 종료 절차를 거치면 Owner 가 `Interrupted_by_restart` 를 남긴다.
  - 거치지 않으면 다음 기동이 다시 잇기를 시도하다 `Turn_exception` 으로 끝난다.
  - `keeper_owner.ml:1865-1868` 주석은 「이 기록 없이 죽은 행도 다음 기동에서 같은 종류로 정리된다」고 적는다. 두 번째 경로가 이 주석과 어긋난다.
- 이 실패가 깨진 기록과 구별되지 않는다. 운영자도 masc 도 `Error.Internal` 문구만 본다.
- 헛된 다시 잇기에 몇 분을 쓴다. 작업을 다시 큐에 넣고, Owner 가 집고, 입력을 조립한 뒤에야 실패한다. 11-15 사례는 기동 뒤 2~4분이 걸렸다.
- provider 호출은 턴에서 긴 구간이다. Tool 실행도 몇 분 걸릴 수 있다. 끊긴 지점별 비율은 재지 않았다.

## 3. 지금 일어나는 일

### 3.1 한 턴의 기록 순서

`packages/agent_core/lib/pipeline/pipeline.ml` 기준이다.

1. provider 시도를 연다. `Pipeline_execution_scope.before_provider_attempt`(`pipeline_execution_scope.ml:116`)가 턴마다 한 번 연다(`~ordinal:0`, 120행).
2. provider 에 HTTP 호출을 한다.
3. 받아들인 응답을 기록한다(`record_provider_response`, 292행).
4. `turn_count` 를 턴 번호 + 1 로 올리고 체크포인트를 `After_assistant_collected` 로 저장한다(456~463행).
5. Tool 을 실행한다(`stage_execute`, 532행). Tool invocation 은 여기서 열린다(`agent_tools.ml:1033`).

- 응답 기록은 #47059 전에도 체크포인트 전에 있었다. #47059 는 기록을 collect 안, admission 뒤로 옮기고 `validate_collected_counter` 를 더했다.
- Tool invocation 은 provider 시도가 바인딩된 뒤에만 열린다(`Execution_context.provider_attempt`). 바인딩은 collect 뒤에만 일어난다(`pipeline.ml:870`, `pipeline_execution_resume.ml:285`·`311`). 그래서 모으기 전의 턴에는 invocation 이 없다.

### 3.2 `Agent.run` 안의 다시 잇기

- `Pipeline_execution_scope.resume_current` 는 열린 턴 아래의 열린 provider 시도를 `Active` 로 돌려준다.
- `Execution_agent_scope.resume_provider_attempt`(`execution_agent_scope.ml:430`)는 응답이 기록됐는지 보지 않는다.
- `Pipeline_execution_resume.dispatch` 는 `Active` 에서 먼저 `validate_collected_counter`(185행)를 부른다(448행). 이 검사는 `turn_count = 턴 번호 + 1` 을 요구한다.
- 1~4 사이에서 끊기면 마지막 체크포인트는 호출 전 것이다. `turn_count` 가 턴 번호와 같아서 검사에 걸린다. 3 과 4 사이(응답은 기록, 체크포인트는 전)도 같다.
- 실패하면 runner 가 실행 root 를 `Failed` 로 닫는다(`abort_error`, `agent_execution_runner.ml:261-270`). invocation 이 없으니 recovery 는 `Retire` 로 나온다(`execution_agent_scope.ml:846-889`).

결정론 재현(#52341 댓글):
- `test_active_terminal_resumes_committed_checkpoint` fixture 를 본떴다.
- `turn_count = 7` 체크포인트를 기록하고, 턴 7 과 provider 시도를 연 채 `Agent.resume` → `Agent.run` 을 불렀다.
- 응답이 없을 때와 있을 때 모두 provider 호출 0번, 위 오류, 실행 root 는 성공이 아닌 종료였다.

### 3.3 agent_core 가 약속한 범위

`packages/agent_core/lib/agent/agent.mli` 는 이 상태를 resume 이 이어 준다고 약속하지 않는다.

- 322~327행: resume 은 정리된 ToolResult 를 다시 쓰고, terminal 응답과 모은 체크포인트가 저장된 경우를 잇는다.
- 315~317행: `Retire` 는 writer 를 잃을 때 열려 있던 provider 요청에 대해 아무것도 말하지 않는다. 잃은 실행이 host 의 일에 무엇을 뜻하는지는 host 가 정한다.

masc 는 이 결정을 하지 않고 같은 기록을 resume 에 넘긴다.
agent_core 는 약속 밖의 상태를 깨진 기록과 같은 `Error.Internal` 로 돌려준다.

### 3.4 masc 의 기동 정리

- 기동 때 `settle_running_without_executor_with_journal_terminal`(`keeper_chat_operation_store.ml:3539`)이 돌던 채팅 작업을 정리한다.
- native 호출이 `Active` 인 작업은 Owner 가 실행 기록의 terminal 을 읽는다(`Keeper_direct_native_continuation.journal_terminal`, 168행). 이 함수는 기록을 바꾸지 않는다.
  - terminal 이 있으면 그 disposition 을 native 호출에 기록하고, 작업을 `Interrupted_by_restart` 로 닫는다(store 3587~3611행, 종류는 `running_settlement_failure`).
  - terminal 이 없거나 읽기에 실패하면 작업을 다시 큐에 넣는다(3612~3613행). 「active native call 은 재시작 뒤에만 다시 잇는다」는 결정이다(3572~3577행).
- 이 정리는 Owner 가 작업을 집기 전에 돈다. 도는 턴이 있으면 Owner 가 정리를 거절한다(`keeper_owner.ml:2017-2020`). 이 거절은 작업 store 를 지킨다.
- 실행 기록은 writer 잠금과 경로 claim 으로 writer 를 하나로 지킨다(`execution_event_store.ml:544-591`). 같은 프로세스의 `observe_execution` 도 잠깐 claim 을 쥔다.
- 종료 절차 중에는 Owner 의 두 멈춤 갈래가 모두 `Interrupted_by_restart` 를 남긴다(`keeper_owner.ml:1865-1883`).
- `Agent.run` 을 거쳐 실패하면 결과는 runner 의 실패 분류를 거쳐 `Turn_exception` 이 된다(`server_routes_http_keeper_stream.ml:2047-2053`, 1197~1198행). 이 사슬에는 「중단」 갈래가 없다.

## 4. 제안

### 4.1 agent_core: 모으기 전에 끊긴 턴을 닫는 함수

`open_execution_projection` 옆에 진입점 하나를 둔다. 이름과 오류 타입은 L1 에서 정한다. 여기서는 `retire_uncollected_turn` 으로 부른다.

```ocaml
type uncollected_retirement =
  | Not_uncollected
  | Retired of execution_terminal_evidence

val retire_uncollected_turn :
  runtime:execution_runtime ->
  dir:Eio.Fs.dir_ty Eio.Path.t ->
  execution_locator ->
  agent_name:string ->
  checkpoint_turn_count:int ->
  (uncollected_retirement, retire_error) result
```

- `Execution_projection` 에 넣지 않는다. projection 은 「append·cancel·terminate 를 할 수 없는」 읽기 전용 값이라고 약속한다(`agent.mli:268-270`).
- 기록을 쓰려면 resume 과 같은 writer 잠금을 잡는다(`Execution_lane_writer.resume`). 잠금 아래에서 기록을 새로 읽고 판정한다. `observe_execution` 이 writer 를 잃었다고 판정할 때와 같은 조건이다(`with_writer_absent`, `agent_execution_projection.ml:897`).
- `agent_name` 은 resume 과 같이 기록의 `Agent_run` 이름과 견준다(`execution_agent_scope.ml:222-239`). 다르면 오류다. masc 는 seed 체크포인트의 이름을 넘긴다.
- 읽고, 판정하고, 닫는 순서는 `Cancel.protect` 아래에서 한다. `with_writer_lifetime` 과 같다.
- 오류는 잠금·입출력·이름 불일치·writer 닫기 실패뿐이다. writer 경로가 던지는 예외(`Callback_failed_after_scope_failure` 등, `execution_lane_writer.ml:887-912`)도 오류 값으로 바꾼다. 취소만 다시 던진다.
- 잠금을 못 잡으면 오류다. 살아 있는 writer 이거나 같은 프로세스의 관찰이 claim 을 쥔 것이라 `Retired` 도 `Not_uncollected` 도 아니다.

새 기록 종류나 writer 기본 동작은 필요 없다. `Execution_lane_writer.resume`, `Execution_agent_scope.resume_running`·`resume_current_turn`·`resume_provider_attempt`·`provider_invocations`·`abort (Cancelled _)`, `recovery_evidence_from_tree` 를 잇는다. 다만 이 함수들은 모양이 다를 때 오류를 돌려준다(이미 끝난 root, 열린 턴 여럿, 시도 여럿). L1 은 이 경우를 `Not_uncollected` 로 옮긴다.

`Retired` 는 아래가 모두 맞을 때만 낸다.
- 실행 root 와 턴 하나가 열려 있다.
- 열린 턴의 번호가 `checkpoint_turn_count` 와 같다.
- 그 턴의 provider 시도가 열려 있다. 응답이 기록됐는지는 따지지 않는다.
- 그 턴 아래에 Tool invocation 이 없다.

`Retired` 일 때 하는 일:
- provider 시도, 턴, root 를 `Cancelled` 로 닫는다. runner 를 거치지 않는다. `abort` 가 열린 아래 노드를 한 번에 닫는다(`execution_journal.ml:1881-1930`).
- recovery 는 기록에서 나온다. invocation 이 없으니 `Retire` 다.
- 닫은 뒤의 terminal 증거를 돌려준다. `read_execution_terminal` 이 같은 값을 읽는다.
- `on_terminal_disposition` callback, bus 발행, raw trace 는 없다. 「terminal 을 기록한 뒤 callback 전에 죽은 경우」와 같은 모양이라 agent.mli 가 이미 다룬다.

그 밖의 모든 경우는 `Not_uncollected` 이고 기록된(commit 된) 사건을 더하지 않는다. 모은 체크포인트(`턴 번호 + 1`), 어긋난 번호, 열린 시도 없음, invocation 있음이 여기에 든다. 이 경우들은 지금처럼 resume 이 판정한다.
- writer 를 열면 commit 되지 않은 WAL 꼬리를 잘라 내고 fsync 한다(`execution_event_store.ml:2005-2014`). 그래서 retire 를 부르는 단계는 terminal 이 없는 기록에 한해 쓰는 단계다. 이 단계는 claim 의 준비에 있다(4.2). 기동 정리는 지금처럼 읽기만 한다.

기록된 응답(3 과 4 사이)은 쓰지 않는다.
- 응답만으로는 모은 메시지를 다시 만들 수 없다.
- 받아들이지 못한 tool 호출은 응답에서 빠지고 따로 답한다(`pipeline.ml:283-287`). 그 답은 응답에 없다.

`Pipeline_execution_resume.resolve` 는 바꾸지 않는다. writer 종료가 증명된 호출은 claim 의 준비가 이 모양을 먼저 닫는다(4.2). 증명되지 않은 호출은 닫지 않는다. 그 호출은 `Agent.run` 에서 같은 모양을 만나고 지금처럼 `Error.Internal` 로 실패한다.

### 4.2 masc: 그 작업을 집은 claim 이 닫는다

claim 이 native 호출을 열기 직전의 준비(`Keeper_direct_native_continuation.prepare`)에 한 단계를 더한다. 자리를 claim 으로 둔 근거와 닫은 뒤의 순서는 `restart-resumes-running-chat-operations` §4.4 다. 기동 정리(`journal_terminal`)는 바꾸지 않는다. 지금처럼 기록을 읽기만 한다.

1. native 호출의 최신 체크포인트 참조(`call.checkpoint`)에서 `turn_count` 를 읽는다. 참조가 이 값을 이미 담는다(`keeper_checkpoint_ref.mli:4-8`). 체크포인트를 열 필요가 없다.
   - Owner 는 체크포인트를 쓸 때마다 이 참조를 옮긴다. 순서는 내용 보관 → Owner store commit → agent_core 진행이다(`keeper_direct_native_continuation.ml:375-386`, 446-474). store 는 `synchronous=EXTRA` 다(`keeper_chat_operation_store.ml:802-806`).
   - 그래서 턴 k 의 provider 시도가 열렸으면, 참조는 턴 k-1 의 마지막 체크포인트(`turn_count = k`)이거나 그 뒤의 것이다.
2. writer 가 끝났다고 증명된 호출이면 `retire_uncollected_turn` 을 부른다(`restart-resumes-running-chat-operations` §4.7). 준비가 그 호출을 복원할 때 쓰는 것과 같은 runtime·디렉터리·locator 와 seed 체크포인트의 Agent 이름을 넘긴다.
3. `Retired` 면 그 disposition 을 호출의 terminal 로 적는다. 같은 claim 이 `call.checkpoint` 에서 새 native 호출을 연다.
4. `Not_uncollected` 면 지금처럼 같은 호출을 이어 한다.
5. 오류면 `read_execution_terminal` 로 기록을 한 번 더 읽는다.
   - 닫기는 commit 됐는데 writer 닫기가 실패했을 수 있다(`execution_lane_writer.ml:870-877`).
   - terminal 이 있으면 3 으로 간다. 없으면 그 claim 은 실패하고 호출은 `Active` 로 남는다. 행은 `running` 으로 남고 다음 기동이 다시 판정한다(`restart-resumes-running-chat-operations` §4.4).

- 기동 정리 안에서 닫지 않으므로, 닫다가 난 실패가 그 Keeper 의 Owner 를 멈추지 않는다. 다만 호출이 `Active` 로 남으면 그 Keeper 는 다음 기동까지 다른 채팅 작업을 집지 않는다.
- 새 실패 종류가 필요 없다.
- 기록을 두 번 읽는다(terminal 읽기, 잠금 아래 다시 읽기). Owner 의 자식 fiber 에서 읽으므로 그동안에도 Owner 는 다른 명령을 받는다.

### 4.3 「같은 결과」가 맞는 범위

이 제안으로 같아지는 것은 「provider 시도가 열린 동안 끊긴 경우」와 종료 절차를 거친 재시작이다. `keeper_owner.ml:1865-1868` 주석과도 맞는다.

종료 절차 없이 끊긴 다른 구간은 지금처럼 다시 이어 하고 provider 를 부른다.
- root 만 열림, 또는 턴은 열렸고 provider 시도는 아직 → `Fresh` 로 그 턴부터 다시 한다(`pipeline_execution_scope.ml:82`).
- 마지막 턴이 성공으로 닫힘 → `Settled` 로 응답을 다시 쓰고 이어 간다.
- 모은 체크포인트 뒤 Tool 실행 중 → `Active` 로 이어 간다.

그래서 provider 시도를 열기 1ms 전에 죽으면 메시지가 이어지고, 1ms 뒤에 죽으면 실패한다. 이 차이는 기록 규칙에서 온다.
- 열린 provider 시도가 있으면 기록은 「요청이 나갔을 수 있다」고 말한다. 턴마다 시도는 하나라서, 같은 턴에서 다시 부를 수 없다.
- 열리기 전이면 기록에 나간 요청이 없다. 그 턴을 처음부터 하는 것이 기록과 맞다.

운영자는 이어 하기로 정했다(2026-11-16, 머리말의 결정). 같은 턴에서 provider 를 다시 부르지 않는 규칙은 그대로다. 닫힌 실행과 새 호출이 따로 있다. 두 재시작 경로를 함께 바꾸는 일은 `restart-resumes-running-chat-operations` 가 다룬다.

## 5. 순서와 상태

Keeper 하나가 채팅 작업 하나를 돌리는 동안의 틱이다.

| 틱 | 일 | 지금 | 제안 |
|---|---|---|---|
| N | 턴 k 의 provider 호출 중 프로세스가 죽는다 | 작업 `running`, 턴 k·provider 시도 열림, 체크포인트 `turn_count = k` | 같음 |
| N+1 | 기동 정리 | terminal 없음 → 다시 큐에 넣는다 | 같음 |
| N+2 | Owner 가 작업을 집는다 | 입력을 조립하고 `Agent.run` 에서 `Error.Internal` | 기록을 `Cancelled`·`Retire` 로 닫고, 호출 전 체크포인트에서 새 native 호출을 연다 |
| N+3 | 작업이 끝난다 | `failed / Turn_exception` | 새 호출의 결과로 끝난다 |

- 다른 Keeper 가 그 메시지를 보냈다면 실패 대신 답을 받는다.
- 기록을 닫은 뒤 새 호출을 묶기 전에 다시 죽으면, 다음 기동은 3.4 의 기존 경로로 `Interrupted_by_restart` 를 남긴다. 호출에 terminal 을 적기 전이면 기록의 terminal 을 읽어서, 적은 뒤면 호출의 영수증으로 판정한다. terminal 이 있는 호출에는 retire 를 부르지 않는다.
- 재시도 횟수나 시간 한도가 없다. 재기동 한 번에 새 호출 하나다. 연속 재기동은 `restart-resumes-running-chat-operations` §5.3 이 다룬다.
- 종료 절차를 거친 재시작이 같은 기록을 남기게 하는 일도 `restart-resumes-running-chat-operations` 가 다룬다.

## 6. runtime 바꿈·문맥 창·계정·위임

- runtime 과 문맥 창: 닫는 일은 provider 를 부르지 않는다. 닫은 뒤 여는 새 호출의 runtime 과 문맥은 `restart-resumes-running-chat-operations` §6 이 정한다.
- 계정(Provider Runtime 소유):
  - 응답이 기록된 경우, masc 의 after_turn hook 이 지출을 기록했을 수 있다(`keeper_hooks_agent_core.ml:421-436`). 응답 기록(`pipeline.ml:292`)이 after_turn(356행)보다 먼저라서, 그 사이에 죽었으면 지출 기록이 없다.
  - 응답이 없는 경우, provider 가 요청을 청구했어도 masc 는 그 사용량을 본 적이 없다. 이 RFC 는 그것을 되살리지 않는다.
- 위임(하위 Agent): 하위 실행은 부모 턴의 Tool 안에서 돈다. 부모 턴에 invocation 이 있으니 `Not_uncollected` 다. 지금처럼 `Operator_repair_required Effect_outcome_unknown` 로 간다.
- 공식 클라이언트(CLI) 레인과 다른 실행: `?resume` 을 넘기는 곳은 `keeper_direct_native_continuation.ml:471` 하나다. 그 밖의 실행은 다시 잇지 않으므로 범위 밖이다.

## 7. 하지 않는 것

- `Agent.run` 안(`resolve`)에 갈래를 더하지 않는다. 같은 실행은 그 턴을 이을 수 없고(4.3), 새 호출을 여는 일은 host 가 한다. `resolve` 의 결과가 재시도·미루기 갈래로 가면 다음 후보가 새 native 호출로 메시지를 다시 돌린다.
- 같은 턴에서 provider 를 다시 부르지 않는다. 턴마다 provider 시도가 하나라는 기록 규칙을 그대로 둔다.
- 기록된 응답으로 메시지를 다시 만들지 않는다(4.1).
- `validate_collected_counter` 를 지우지 않는다. 어긋난 기록은 그대로 막는다.
- 오류 문구로 상태를 가르지 않는다.
- 모은 체크포인트가 있는 `Active` 호출의 다시 잇기는 바꾸지 않는다. 그 호출이 `Agent.run` 전에 거절되는 경우(저장된 runtime·model 이 바뀜, 체크포인트 복원 실패 등)도 이 RFC 에 넣지 않는다.
  - 그 claim 이 실패하면 Owner 가 호출을 「효과 모름」 영수증으로 닫고 작업을 실패로 끝낸다(`restart-resumes-running-chat-operations` 4.3, 운영자 결정 2026-11-17).

## 8. 시험

agent_core(`retire_uncollected_turn`):
- #52341 재현 fixture 두 경우(응답 없음·있음) → `Retired`, provider 0회, root `Cancelled`·`Retire`. 이어서 `read_execution_terminal` 이 같은 증거를 읽는다.
- 같은 기록에 두 번 부르면 두 번째는 `Not_uncollected` 이고 commit 된 사건과 cursor 가 그대로다.
- 다른 writer 가 잠금을 쥔 동안 부르면 오류이고 commit 된 사건이 그대로다.
- Agent 이름이 다르면 오류이고 commit 된 사건이 그대로다.
- writer 닫기 실패를 넣은 시험에서도 결과가 오류 값이고 예외가 새지 않는다.
- `turn_count = 턴 번호 + 1` → `Not_uncollected`, 기록 그대로, 이어서 resume 이 지금처럼 잇는다.
- `turn_count = 턴 번호 + 2` → `Not_uncollected`, resume 은 지금처럼 `Error.Internal`.
- 열린 provider 시도가 없음, Tool invocation 있음 → 각각 `Not_uncollected`.
- 조건 넷 중 하나를 빼면 위 시험 가운데 하나가 실패한다.

masc: `restart-resumes-running-chat-operations` §8 의 4.4 시험이 맡는다.

## 9. 단계

| 층 | 내용 |
|---|---|
| L0 | 이 RFC |
| L1 | agent_core: `retire_uncollected_turn`, 시험 |
| L2 | masc: claim 의 준비에서 부르기, 시험. `restart-resumes-running-chat-operations` 의 L4.3 이다 |

## 10. 정할 것

- 닫힌 기록에 「재기동 뒤 모으기 전이라 닫음」이라는 원인을 남길지.
  - 기록은 이미 `Event.Cancelled {reason; data}` 로 원인을 담을 수 있다(`execution_agent_scope.ml:65-70`).
  - 공개 terminal 증거는 outcome 과 recovery 만 내보내서, 종료 절차의 멈춤·운영자 중단과 같은 모양이다. 남기려면 공개 증거 타입에 필드가 하나 생긴다.
