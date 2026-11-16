---
rfc: "restart-resumes-running-chat-operations"
title: "A server restart resumes running chat operations from their last record instead of failing them"
status: Draft
created: 2026-11-16
updated: 2026-11-16
author: claude
related: ["uncollected-provider-turn-is-not-resumed", "last-path-resumes-after-progress"]
---

# RFC: 서버를 다시 띄워도 돌던 채팅 작업은 마지막 기록부터 이어 한다

- 상태: 초안. 코드는 바꾸지 않았다.
- 이슈: #46505(재시작이 Keeper 턴을 끊는다). 앞선 RFC: `uncollected-provider-turn-is-not-resumed`(#52359).
- 결정(운영자, 2026-11-16): 정상 재기동과 비정상 종료 모두 돌던 채팅 작업을 이어 한다. #52359 §10 의 「끊긴 메시지를 이어 할지」에 대한 답이다.
- 리뷰 보강(2026-11-16): #52453 리뷰의 보류 네 가지를 4.2·4.4·4.5·4.6·8 에 반영했다. 보강 부분의 코드는 `origin/main` `83461169d090` 에서 읽었다.
- 근거: 코드는 `origin/main` `4a8a9920776a` 에서 읽었다. §1 수치는 Keeper 마다 `chat-operations.sqlite3` 를 읽기 전용으로 한 번 열어 셌다. 입력 문장은 열지 않았다. 시각은 KST 다.

## 0. 요약

서버를 내렸다 올리면 그때 돌던 채팅 작업은 실패로 끝나고 입력이 지워진다. 위임한 Keeper 와 MCP 에이전트는 그 일을 다시 보내지 않는다. 일은 그대로 사라진다.

Owner 는 이미 「멈춘 작업의 native 호출은 열어 두고 다음 기동이 이어 하게 한다」고 정해 두었다. 그런데 agent_core 가 취소를 받으면 실행 기록을 먼저 닫는다. 그래서 Owner 의 의도가 닿지 않는다.

이 RFC 는 재기동이 실행을 멈추기만 하고 기록은 닫지 않게 한다. 정상 재기동과 비정상 종료는 같은 기록 모양을 남긴다. 다음 기동의 정리 하나가 둘을 같은 규칙으로 판정한다.

- provider 응답을 모으기 전에 끊긴 턴은 #52359 의 함수로 닫는다. 그 호출이 남긴 마지막 체크포인트에서 새 native 호출을 연다.
- 실행 중 끊긴 Tool 은 다시 실행하지 않는다. 「결과를 모른다」는 typed 결과를 모델에게 주고 턴을 잇는다.
- 진전 없이 다시 끊긴 작업은 이어 하지 않고 끝낸다. 서버를 자동으로 다시 띄우는 감시자 아래에서 같은 작업이 서버를 계속 죽이는 고리를 끊는다.
- 공식 클라이언트(CLI) 레인은 이 RFC 의 구현 범위 밖이다. CLI 마다 죽은 세션을 다시 열었을 때 무엇이 남는지 먼저 잰다(§10).

## 1. 사건

### 1.1 11-16 (00:00~14:39)

| | 건수 |
|---|---:|
| 끝난 채팅 작업 | 201 |
| 성공 | 129 |
| 실패 | 72 |
| └ `Interrupted_by_restart` | 39 |
| └ `Turn_exception` 중 turn counter 불일치(#52341) | 12 |

- `Interrupted_by_restart` 39건 가운데 38건이 종료 절차 경로다. 실패 문구가 「Keeper owner stopped the active turn」이다. 9개 Keeper 에서 나왔고, 시작 뒤 버린 실행 시간이 15.1시간이다.
- 그 38건 가운데 30건은 native 호출 기록이 있는 Agent API 레인이다. runtime 은 모두 GLM 이다. 나머지 8건은 semantic 기록이 없어 레인을 가르지 못했다.
- 나머지 1건은 기동 정리 경로다(「process restarted before terminal operation commit」).
- 이날 종료 절차를 거친 재기동은 02:06·12:28·13:12·13:23·14:01·14:32 이다. 14:01 한 번에 9건이 끊겼다.
- turn counter 불일치는 이어 하던 `Active` 호출이 provider 응답을 모으기 전에 끊긴 턴을 만날 때 난다(#52359 §3).
- code-reviewer-uncle 은 이날 끝난 채팅 작업 9건이 모두 실패였다. 8건이 재기동에 끊겼고, 1건이 turn counter 불일치다. 14:39 에 대기 11건 가운데 가장 오래된 것이 12.3시간째 기다린다. 재기동이 이어지는 날에는 이 Keeper 가 채팅을 하나도 끝내지 못한다.

### 1.2 11-01~11-05 (UTC)

`docs/evidence/restart-cancelled-turns-2026-11/README.md` 가 이미 셌다.

- 종료 절차에 끊긴 채팅 작업이 118건이다. 모두 SIGTERM 60초 안에 끝났다.
- 다른 Keeper 의 위임 39건과 MCP 에이전트 50건은 같은 입력으로 다시 들어온 적이 한 번도 없다.
- 대시보드에서 사람이 보낸 29건 가운데 7건만 다시 들어왔다.
- 끊긴 작업 118건의 `input_json` 이 모두 비어 있다.

## 2. 왜 문제인가

- 위임과 MCP 요청은 보낸 쪽이 다시 보내지 않는다. 끊기면 일이 사라진다. 보낸 쪽은 실패를 받지만, 그 일을 다시 맡을 주체가 없다.
- 운영자가 배포하려고 정상적으로 내리는 쪽이 비정상 종료보다 일을 더 많이 잃는다. 같은 사건인데 경로에 따라 결과가 갈린다.
- 입력이 지워져서 무엇을 잃었는지도 남지 않는다.
- 종료를 더 오래 기다리는 방법은 얻는 몫이 작다. 60초를 더 기다려도 끝나는 턴은 상한이 8.2% 다(evidence README「종료를 기다리면」).
- 설계 문서는 지금 동작만 적는다(`docs/design/keeper-repetition-scope-boundaries.md:13`). 「작업을 실패로 끝내야 한다」는 근거를 적은 문서는 찾지 못했다. `Interrupted_by_restart` 라는 이름을 정한 #49333 과 SIGKILL 을 고른 #49923 은 이름과 종료 속도만 다룬다.

## 3. 지금 일어나는 일

### 3.1 종료 절차

1. SIGTERM·SIGINT 가 `request_shutdown` 에 닿는다(`bin/main_eio.ml:645-656`).
2. 종료 hook 이 `begin_stopping_all` 을 부른다(`lib/server/server_bootstrap_loops.ml:1924-1926`, `lib/keeper/keeper_owner_registry.ml:1062-1095`).
3. Owner 는 도는 턴이 있으면 바로 `Switch.fail child_sw Stop_active_child` 를 부른다(`lib/keeper/keeper_owner.ml:1858`, 3114-3130). 도구 경계나 체크포인트를 기다리지 않는다.
4. `Stop_active_child` 는 프로세스 층의 `Stop_without_grace` 를 다시 묶은 예외다(`lib/keeper/keeper_owner_signals.ml:22`). 자식 프로세스는 TERM 없이 SIGKILL 을 받는다(`lib/process/posix_spawn_process_mgr.ml:179-193`, #49684).
5. agent_core 는 `Eio.Cancel.Cancelled _` 를 받으면 실행을 `Cancelled` 로 닫는다(`packages/agent_core/lib/agent/agent_execution_runner.ml:173-196`). 열린 노드를 모두 닫는다(`execution_journal.ml:1881-1930`).
6. 닫은 결과(terminal disposition)는 취소 보호 아래에서 masc 의 `on_terminal_disposition` 로 간다(`agent_execution_runner.ml:300-319` → `keeper_direct_native_continuation.ml:422-435`). Owner 가 멈추는 중에도 이 기록은 받아들여진다(`keeper_owner_registry.ml:426-449`). 영수증은 `Terminal_unacknowledged` 가 된다. 이 callback 이 실패하면 `reconcile_after_dispatch` 가 기록에서 다시 옮긴다(`keeper_direct_native_continuation.ml:189-216`).
7. Owner 의 정책은 반대를 말한다. 멈춘 턴이면 native 호출을 열어 두고 다음 기동이 이어 하게 한다(`Leave_active_call_for_restart`, `keeper_owner.ml:951-960`). 그러나 정책은 `Active` 호출에만 적용된다(`keeper_owner.ml:1657-1691`). 6 에서 영수증이 이미 바뀌었으므로 정책에 닿지 않는다.
8. 작업은 `failed / Interrupted_by_restart` 로 끝나고 `input_json` 이 지워진다(`keeper_chat_operation_store.ml:3488-3509`).

1.1 의 30건이 이 경로다. native 호출 기록이 있는데도 실패로 끝났다.

### 3.2 비정상 종료 뒤 기동 정리

`settle_running_without_executor_with_journal_terminal`(`keeper_chat_operation_store.ml:3586-3726`)이 `running` 행을 판정한다. 기동은 두 번 정리한다. Owner 가 뜰 때 관측 없이 한 번(`keeper_owner.ml:1394-1398`), runtime 이 준비된 뒤 기록을 읽어 한 번이다(`keeper_owner.ml:2016-2044`).

| 증거 | 결과 |
|---|---|
| `Active` 호출, 아직 관측 없음(첫 정리) | `running` 으로 둔다 |
| `Active` 호출, 기록에 terminal 있음 | `failed / Interrupted_by_restart` |
| `Active` 호출, terminal 없음 | 다시 큐에 넣는다. 다음 claim 이 `call.checkpoint` 에서 이어 한다 |
| `Active` 호출, 기록 읽기 오류 | 다시 큐에 넣는다 |
| `Terminal_unacknowledged` | `failed / Interrupted_by_restart` |
| 호출 없음, 공식 클라이언트 체크포인트 준비 중 | 준비 대기로 막고 다시 큐에 넣는다 |
| 호출 없음, 체크포인트·재시도·Gate continuation 있음 | 다시 큐에 넣는다 |
| 호출 없음, continuation 없음 | `failed / Interrupted_by_restart` |

- 다시 큐에 넣은 행은 새 순번을 받아 큐 맨 뒤로 간다(`requeue_continuation_with_db`, `:2507-2521`). 입력은 남는다.
- `Active` 호출을 이어 할 때, 끊긴 구간이 provider 응답을 모으기 전이면 turn counter 불일치로 실패한다(#52341, RFC #52359 §3).

### 3.3 Tool 이 도는 중에 끊기면

- Tool 실행 기록은 invocation → attempt → 결과 순서로 쌓인다. 결과와 닫기는 한 번에 쓴다(`packages/agent_core/lib/execution_tool_settlement.ml:160-187`). 핸들러 실행은 취소 보호 밖이다.
- 종료 절차(3.1 의 5): `abort` 가 열린 attempt 와 invocation 을 결과 없이 `Cancelled` 로 닫는다. recovery 는 `Operator_repair_required Effect_outcome_unknown` 이 된다(`execution_agent_scope.ml:846-875`).
- 비정상 종료: attempt 와 invocation 이 열린 채 결과 없이 남는다.
- 이어 하면 settlement 가 `Outcome_unknown` 을 읽는다(`execution_tool_settlement.ml:127-131`). `Error Effect_outcome_unknown` → `Durability_failure` → `Abort_tool_dispatch` 로 Agent 호출이 실패한다(`packages/agent_core/lib/agent/agent_tools.ml:1157-1166`). 공개 계약도 「결과 없는 attempt 는 닫힌 채 실패한다」고 적는다(`agent.mli:320-326`).
- 모델은 이 사실을 받지 못한다. 작업이 실패로 끝날 뿐이다.

### 3.4 공식 클라이언트 레인

- Claude Code·Codex·Antigravity·Muse 레인은 native 호출 기록을 만들지 않는다. 묶는 곳은 Agent API 경로 한 곳이다(`keeper_direct_native_continuation.ml:407`).
- 종료 절차: 어댑터가 멈춤을 `Owner_stopped_turn` 으로 옮긴다. claim 은 풀리고 작업은 `Interrupted_by_restart` 로 끝난다.
- 비정상 종료: 작업은 3.2 의 「호출 없음, continuation 없음」으로 끝난다. 세션 저장소는 옛 프로세스의 미완 claim 을 `Recovery_required / Process_restarted` 로 바꾼다(`keeper_official_client_session_store.ml:2103-2121`). 이 실패는 `Ambiguous` 다(`:50-66`).

### 3.5 서버를 다시 띄우는 감시자

저장소가 내는 설치 틀은 서버가 비정상으로 끝나면 다시 띄운다.

- launchd: `KeepAlive` 의 `SuccessfulExit=false`, `ThrottleInterval` 30초(`infrastructure/launchd/com.example.masc.plist.template:38-45`).
- systemd: `Restart=on-failure`, `RestartSec=30s`(`infrastructure/systemd/masc.service:66-67`).
- docker compose: `restart: unless-stopped`(`docker-compose.yml:26`).

작업 하나가 서버를 죽이고, 다음 기동이 그 작업을 다시 집으면, 감시자 아래에서 30초마다 같은 일이 되풀이된다. 지금도 `Active` 호출이 다시 큐에 드는 경로(3.2)에서 이 고리가 생길 수 있다.

## 4. 제안

### 4.1 규칙

> 재기동은 실행을 멈출 뿐 실행 기록을 닫지 않는다. 다음 기동의 정리가 기록을 읽고 판정한다. 진전 없이 다시 끊긴 작업은 이어 하지 않는다.

- 정상 재기동이 남기는 기록 모양을 비정상 종료와 같게 만든다. 그러면 3.2 의 표 하나가 두 경로를 판정한다.
- 운영자 중단(`Operator_interrupt`)은 지금처럼 기록을 닫는다. 운영자가 끝내라고 한 일이다.
- 새 실패 종류와 횟수 한도는 더하지 않는다.
- 저장 상태는 두 가지를 더한다. 4.5 의 「끊긴 Tool 결과」와 4.6 의 「재기동으로 이어 한 지점」이다. 둘 다 없으면 기록이 사실과 다르게 남거나(4.5), 같은 작업이 서버를 계속 죽인다(4.6). masc 는 1.0 전이라 저장 형식을 hard cut 으로 바꾼다.

### 4.2 agent_core: 호스트가 멈춘 실행은 닫지 않는다

`abort_after_exception` 이 취소 이유를 typed 로 가른다.

- 호스트가 「멈춤」이라고 한 취소면 `abort` 를 부르지 않는다. terminal 을 쓰지 않고, `on_terminal_disposition` 도 부르지 않는다. writer 는 terminal 없이 놓는다. writer 의 닫기와 잠금 해제는 terminal 을 요구하지 않는다(`execution_lane_writer.ml:849-912`).
- 그 밖의 취소와 예외는 지금처럼 닫는다.
- 멈춘 기록은 비정상 종료와 모양이 같다. root·턴·provider 시도·attempt 가 열린 채 남는다.

agent_core 는 masc 의 예외를 모른다. 의존 순서가 agent_core 아래에 `lib/process` 를 두지 않기 때문이다. 그래서 실행을 시작할 때 호스트가 취소 이유를 가르는 함수를 넘긴다. 이름과 모양은 L2 에서 정한다.

- 판정은 생성자로 한다. 문자열로 가르지 않는다.
- 멈춤은 `Stop_active_child` 하나다. `Keeper_owner_signals.is_owner_cancel_reason` 은 운영자 중단도 참으로 보므로 그대로 쓰지 않는다(`keeper_owner_signals.ml:24-32`).
- 감싼 모양(`Cancelled`, `Finally_raised`, `Eio.Exn.Multiple`)은 안의 이유가 모두 멈춤일 때만 멈춤이다. 지금 runner 는 맨 바깥 `Cancelled _` 만 본다(`agent_execution_runner.ml:175-178`).
- 멈춤과 운영자 중단이 함께 오면 운영자 중단이 이긴다. Owner 도 운영자 표시를 먼저 본다(`keeper_owner.ml:1922-1925`). 멈춤이 먼저 닿아 기록이 열린 채 남아도, Owner 는 호출을 닫는다(`Close_active_call`). 작업은 지금처럼 `Turn_cancelled` 로 끝나고, 열린 기록은 아무도 이어 하지 않는다.

**같은 프로세스에서 terminal 을 기대하는 곳**

멈춘 실행은 같은 프로세스 안에서 terminal 없이 끝난다. 지금 terminal 을 받는 곳이 그때 하는 일은 아래와 같다.

| 받는 곳 | 멈춘 실행에서 하는 일 |
|---|---|
| runner 의 terminal 전달(`agent_execution_runner.ml:300-303`) | 받은 terminal 이 없으면 아무것도 보내지 않고 성공한다 |
| writer 닫기와 잠금 해제(`execution_lane_writer.ml:849-912`) | terminal 을 요구하지 않는다 |
| `abort_after_exception` 을 부르는 다른 두 곳(`prepare_scope` `:277-287`, `settle_success_after_run` `:251-259`) | 같은 함수를 거치므로 같은 판정을 받는다 |
| Owner 의 native 호출 처리(`keeper_owner.ml:957-976`) | `Child_stopped_by_owner` 는 `Leave_active_call_for_restart` 다. 호출은 `Active` 로 남는다 |
| Owner 의 멈춤 대기(`keeper_owner.ml:3114-3130`) | 자식 fiber 가 끝나기를 기다린다. 기록의 terminal 은 보지 않는다 |
| 멈춘 뒤의 claim 과 `Bind` | 멈추는 Owner 는 자식을 시작하지 않고(`keeper_owner.ml:1814-1821`), `Bind` 를 거절한다(`:2373-2378`). `stopping` 은 다시 꺼지지 않는다(`keeper_owner_reducer.ml:452-453`) |

그래서 같은 프로세스에서 멈춘 기록을 다시 여는 길은 기동 정리뿐이다. 다음 프로세스의 기동이든, 같은 Keeper 에 새로 만든 Owner 의 기동이든 같은 정리를 거친다.

### 4.3 masc Owner: 멈춘 작업은 `running` 으로 남는다

- 4.2 가 들어가면 3.1 의 6 이 일어나지 않는다. 호출은 `Active` 로 남고, `Leave_active_call_for_restart` 가 실제로 쓰인다. 작업은 `running` 으로 남고 입력도 남는다.
- 남은 행은 다음 기동에서 3.2 의 「`Active` 호출, terminal 없음」으로 간다. 비정상 종료와 같은 경로다.
- 공식 클라이언트 레인의 멈춤은 바꾸지 않는다(§10).

### 4.4 모으기 전에 끊긴 턴은 남은 체크포인트에서 새 호출로 잇는다

#52359 §4.2 의 3 단계를 바꾼다. 기동 정리가 `retire_uncollected_turn` 으로 기록을 닫은 뒤의 일이다.

**쓰기는 두 번이다**

1. `retire_uncollected_turn` 이 journal 을 닫는다. journal 파일에 쓴다(#52359 L1).
2. 한 store transaction 이 아래를 쓴다. semantic 실행과 작업 행은 같은 sqlite 파일에 있다(`keeper_chat_operation_store.ml:95`, 121).

두 쓰기는 저장소가 달라 한 transaction 으로 묶이지 않는다. 그 사이에서 죽은 모양은 다음 기동이 이렇게 판정한다.

| 죽은 때 | 남은 모양 | 다음 기동 |
|---|---|---|
| 1 전 | 호출 `Active`, journal 열림 | 같은 판정을 처음부터 한다 |
| 1 과 2 사이 | 호출 `Active`, journal 에 `Cancelled` terminal | 3.2 의 「`Active` 호출, 기록에 terminal 있음」. 작업은 `Interrupted_by_restart` 로 끝난다. 일은 사라지지만 끝난 일을 다시 돌리지는 않는다 |
| 2 뒤 | 호출은 내려가고 행은 큐에 있음 | 보통 claim 이다 |

1 과 2 사이도 이어 하려면 journal terminal 이 「기동 정리가 닫았다」를 typed 로 담아야 한다(§10).

2 의 store transaction 은 아래를 쓴다.

- 호출에 terminal(`Retire`)을 기록한다.
- semantic 실행을 `Suspend` 로 옮긴다. 이 전이는 `Terminal_unacknowledged(Retire)` 인 호출을 함께 내린다(`keeper_semantic_execution.ml:672-675`, 870-876). 영수증 의무는 그대로 남는다(`:896-930`).
- 행을 다시 큐에 넣는다.
- Owner mailbox 를 부르지 않는다. 기동 정리는 그 Owner 의 명령 안에서 돌기 때문이다(`keeper_owner.ml:2016-2060`, `keeper_direct_native_continuation.ml:166-168`). 그래서 cooperative 미루기의 `defer` 는 쓸 수 없다.

**관측은 typed 로 나눈다**

기동 정리가 받는 관측에 「이번 정리가 닫았다」를 따로 둔다. 「기록에 terminal 이 이미 있다」와 같은 값으로 두지 않는다. `Succeeded` 로 끝난 실행도 recovery 가 `Retire` 이고, 그 `call.checkpoint` 는 마지막 체크포인트다(`keeper_direct_native_continuation.ml:422-431`). `Retire` 로 가르면 끝난 작업을 다시 돌린다.

**다음 claim 은 retained 체크포인트에서 연다**

- 새 native 호출의 시작점은 끊긴 호출의 `call.checkpoint` 다. 그 호출이 마지막으로 옮긴 retained 체크포인트이고, 끊긴 턴 k 의 provider 호출 전이다(#52359 §4.2 의 1).
- 새 호출은 `Continue_from_checkpoint` 로 연다. 체크포인트로 시작하는 native 호출이 이미 쓰는 경로다(`keeper_turn_driver_try_provider.ml:2716`).
- 기존 `Bound_checkpoint` loader 는 쓸 수 없다. loader 는 canonical head 에서 이어 하고, 저장된 참조는 접두어 확인에만 쓴다(`keeper_direct_checkpoint_continuation.ml:43-79`). native 호출의 seed 와 그 뒤 체크포인트는 retained 영역에만 있다. canonical 은 keeper sink 가 native 진행 뒤에 쓴다(`keeper_agent_run.ml:1371-1406`, `keeper_direct_native_continuation.ml:461-462`).
  - 작업의 첫 provider 호출에서 끊기면 `call.checkpoint` 는 seed 다(`keeper_native_call.ml:30-38`). seed 에는 새 입력이 있고 canonical 에는 없다. loader 의 접두어 확인이 실패하고 작업은 `Turn_continuation_unpersisted` 로 끝난다(`keeper_turn.ml:497-501`).
  - native 진행과 canonical 저장 사이에서 끊겨도 같다.
- continuation 의 이름과 저장 모양은 L4 에서 정한다.
- 새 호출은 레인 후보 선택과 문맥 준비를 처음부터 거친다. 같은 턴에서 provider 를 다시 부르지 않는다는 #52359 의 기록 규칙은 그대로다. 닫힌 실행과 새 실행이 따로 있다.

### 4.5 결과를 모르는 Tool 은 다시 실행하지 않고 모델에게 알린다

이어 한 실행이 3.3 의 「attempt 는 열렸고 결과가 없는 invocation」을 만나면:

- 핸들러를 부르지 않는다.
- 새 journal transaction 하나로 끊긴 attempt 를 닫는다. 지금 결과를 쓰는 transaction 은 attempt 를 언제나 `Succeeded` 로 닫으므로 쓰지 않는다(`execution_journal.ml:1812`). 끊긴 attempt 를 `Succeeded` 로 적으면 사실과 다르다.
  - attempt 는 성공이 아닌 terminal 로 닫는다.
  - invocation 에 「결과 모름」 결과를 typed 로 적는다. `Types.tool_result_outcome` 에는 이 값을 담을 생성자가 없다(`packages/agent_core/lib/llm_provider/types.mli:69`). 생성자를 더하고 journal·체크포인트 codec 을 함께 바꾼다.
  - attempt 아래에 열린 하위 실행(child run)이 있으면 같은 transaction 에서 `Cancelled` 로 닫는다. 열린 하위 노드가 있으면 결과를 쓸 수 없다(`execution_journal.ml:805-807`, 1107-1110). 하위 실행이 낸 효과는 부모의 「결과 모름」에 포함된다.
- recovery 판정은 이 결과를 「결과 모름」으로 센다. 그래야 그 실행의 terminal 이 `Operator_repair_required Effect_outcome_unknown` 를 잃지 않는다(`execution_agent_scope.ml:846-875`).
- 턴은 계속된다. 다음 provider 호출이 이 결과를 본다. 결과 문구에는 사실만 쓴다. 「호출이 서버 재기동으로 끊겼다」, 「효과가 일어났는지 모른다」, 「다시 실행하지 않았다」.
- 이 처리는 호스트가 「재기동 뒤 이어 한다」고 알린 실행에서만 한다. 호스트는 `execution_store` 의 resume 에 typed 원인(재기동 뒤 / 같은 프로세스 안)을 넘긴다. 이름은 L3 에서 정한다.
  - `with_resume_once`(`agent_execution_runner.ml:407`)로는 가를 수 없다. 같은 프로세스 안에서도 resume 이 있다. Owner 는 미룬 작업(`Operation_deferred`)의 호출을 `Active` 로 두고(`keeper_owner.ml:964`), 다음 claim 이 그 호출을 resume 한다(`keeper_direct_native_continuation.ml:232-240`, 471).
  - 같은 프로세스 안에서는 이 모양이 생기지 않는다. 핸들러가 값을 돌려주면 settle 이 돈다. 예외를 던지면 settle 을 건너뛰고 `abort` 가 실행을 닫는다(`execution_tool_settlement.ml:176-188`). 4.2 뒤에 닫지 않는 경우는 멈춤뿐이고, 멈춘 Owner 는 다시 claim 하지 않는다(4.2 의 표).
  - 그래도 같은 프로세스 resume 에서 이 모양을 만나면 지금처럼 `Effect_outcome_unknown` 으로 실패한다. 위 근거가 틀려도 「결과 모름」을 지어 쓰지 않는다.
  - masc 는 기동 정리가 다시 큐에 넣은 행의 첫 claim 에만 「재기동 뒤」를 넘긴다. 4.6 의 기록이 그 행을 가른다.
- terminal Tool(`Terminal_after_success`)은 바꾸지 않는다. 결과를 모르면 지금처럼 `TerminalToolEffectFailed` 로 실행이 끝난다(`pipeline/pipeline_terminal_tool.ml:22-40`). 실행을 끝내는 Tool 이라 「턴을 잇는다」가 성립하지 않는다.
- 공개 계약 `agent.mli:320-326` 과 resume 의 거절 갈래 `agent_tools.ml:443-447` 를 바꾼다.

이 방법은 지금보다 모르는 채로 다시 실행하는 일을 줄인다. 지금은 작업이 실패한다. 사람이 같은 요청을 다시 보내면, 새 실행은 앞 시도가 있었다는 사실도 모른 채 모든 Tool 을 다시 실행한다. 이 RFC 뒤에는 모델이 끊긴 호출 하나를 알고 상태를 먼저 확인할 수 있다. 무엇을 할지는 Keeper 가 고른다.

닫힌 모양(옛 `abort` 가 결과 없이 `Cancelled` 로 닫은 invocation)은 바꾸지 않는다. 4.2 뒤에는 재기동이 이 모양을 새로 만들지 않는다.

### 4.6 진전 없이 다시 끊기면 끝낸다

3.5 의 고리를 끊는다. 횟수나 시간이 아니라 진전으로 판정한다.

- 기동 정리가 작업을 이어 하려고 다시 큐에 넣을 때, 그때의 체크포인트 참조를 「재기동으로 이어 한 지점」으로 함께 저장한다. 4.4 처럼 새 호출을 열면 새 호출의 seed 가 그 지점이다.
- 다음 기동 정리에서 그 작업의 체크포인트가 저장된 지점에서 한 번도 나아가지 않았으면 이어 하지 않는다. 작업은 지금처럼 `Interrupted_by_restart` 로 끝난다.
- 체크포인트가 나아갔으면 이어 하고, 지점을 새 체크포인트로 바꾼다.
- 끝나는 이유: 재기동 뒤 이어 하기 한 번에 체크포인트가 적어도 한 칸 나아가야 다음에 또 이어 한다. 체크포인트는 앞으로만 간다(`Keeper_native_call.advance`). 그래서 이어 하기 횟수는 작업이 실제로 한 단계 수를 넘지 못한다.
- 대가: 사람이 provider 호출 하나보다 짧은 간격으로 두 번 재기동하면, 그 사이 진전이 없던 작업은 두 번째에 끝난다. 지금은 첫 번째에 끝난다.
- 저장 위치(native 호출 기록이나 semantic 실행)는 L4 에서 정한다. 두 경로(같은 호출을 잇는 5.2, 새 호출을 여는 5.1)가 같은 값을 쓴다.

**작업별 관측**

- 「재기동으로 이어 한 지점」은 값 하나가 아니라 목록으로 둔다. 기동 정리가 이어 할 때마다 그때의 지점을 뒤에 붙인다.
- 판정은 마지막 지점만 본다. 목록 길이는 그 작업을 재기동 뒤 이어 한 횟수다.
- Dashboard·TUI 는 이 목록을 읽어 작업마다 보여 준다. 횟수로 판정하지 않는다.
- 목록은 체크포인트가 나아갈 때만 늘어난다. 그래서 길이가 그 작업의 단계 수를 넘지 않는다.

## 5. 순서와 상태

Keeper 하나, Agent API 레인, 채팅 작업 하나의 틱이다.

### 5.1 provider 호출 중에 정상 재기동

| 틱 | 일 | 지금 | 제안 |
|---|---|---|---|
| N | 턴 k 의 provider 호출 중 SIGTERM | 기록 `Cancelled` 로 닫힘, 작업 `failed`, 입력 지움 | 기록 열린 채, 작업 `running`, 입력 남음 |
| N+1 | 기동 정리 | 정리할 행 없음 | #52359 retire → 호출 terminal·`Suspend`·다시 큐, 이어 한 지점 = `call.checkpoint` |
| N+2 | Owner 가 작업을 집는다 | — | retained `call.checkpoint` 에서 `Continue_from_checkpoint` 로 새 native 호출, 턴 k 를 다시 한다 |
| N+3 | 작업이 끝난다 | 보낸 쪽은 N 에 실패를 받음 | 보낸 쪽은 N+3 에 답을 받음 |

### 5.2 Tool 실행 중에 정상 재기동

| 틱 | 일 | 지금 | 제안 |
|---|---|---|---|
| N | 턴 k 의 Tool 실행 중 SIGTERM | 기록 닫힘, `Operator_repair_required`, 작업 `failed` | 기록 열린 채, 작업 `running` |
| N+1 | 기동 정리 | — | terminal 없음 → 다시 큐, 이어 한 지점 = `call.checkpoint` |
| N+2 | Owner 가 작업을 집는다 | — | 같은 호출을 `call.checkpoint`(모은 체크포인트)에서 이어 함. 끊긴 invocation 에 「결과 모름」을 쓰고, 끝난 invocation 은 기록에서 다시 쓰고, 시작 안 한 invocation 은 실행 |
| N+3 | 다음 provider 호출 | — | 모델이 「결과 모름」을 보고 다음 일을 고른다 |

비정상 종료는 N 의 「제안」 열과 같은 모양으로 시작한다. 그래서 N+1 부터 같은 표를 따른다. 지금은 5.2 의 비정상 종료가 N+2 에서 `Durability_failure` 로 실패한다.

### 5.3 N..N+M: 이어 하는 도중 다시 재기동

- 이어 하기는 작업마다 재기동 한 번에 provider 호출 하나를 잃는다. 끊긴 호출 하나다.
- 진전이 남으면 다음 재기동은 그 뒤에서 잇는다.
- 진전 없이 다시 끊기면 4.6 에 따라 끝난다. 감시자가 30초마다 서버를 다시 띄워도 같은 작업은 두 번째 기동에서 끝난다. 그 작업 때문에 서버가 죽는 경우도 여기서 멈춘다.
- 작업마다 native 호출 기록과 실행 디렉터리가 이어 하기 한 번에 하나씩 는다. 4.6 이 그 수를 진전 수 안으로 묶는다.

### 5.4 Keeper 여럿

- Owner 마다 따로 판정한다. Keeper 사이에 순서가 없다.
- 기동 직후 이어 하는 작업들이 한꺼번에 provider 를 부른다. 11-16 14:01 재기동이면 9건이다. 레인의 속도 제한 처리가 지금처럼 받는다.
- 다시 큐에 든 작업은 그 Keeper 의 큐 맨 뒤로 간다(#52408). 기동 전에 이미 기다리던 작업이 먼저 돈다. 먼저 도는 작업이 canonical 기록을 바꿔도, 4.4 의 새 호출은 retained 체크포인트에서 열리므로 영향을 받지 않는다.

## 6. runtime 바꿈·문맥 창·계정·위임·전달

- **같은 호출을 잇는 경우(5.2)**: native 호출에 묶인 `runtime_id` 로 잇는다. 문맥 창과 계정이 끊기기 전과 같다.
- **새 호출을 여는 경우(5.1)**: 레인 후보를 처음부터 고른다. 재기동 사이에 레인 설정이나 계정이 바뀌었으면 새 설정을 따른다. 문맥 창이 다른 runtime 이 고르면, 체크포인트는 그 runtime 의 문맥 준비(크기 판정·압축)를 거친다.
- **Official → API → Official**: Agent API 체크포인트를 공식 클라이언트로 옮기는 규칙을 이 RFC 가 새로 만들지 않는다. 체크포인트로 시작하는 새 native 호출이 지금 따르는 규칙을 쓴다.
- **저장된 runtime 이 사라진 경우**: 5.2 에서 묶인 `runtime_id` 나 모델이 재기동 뒤 설정에 없으면 `Agent.run` 전에 거절된다. 그 뒤 동작은 #52359 §10 셋째 항목이고 재현하지 않았다. §10 에 둔다.
- **계정과 지출**: 끊긴 provider 호출은 provider 가 청구했어도 masc 가 사용량을 본 적이 없다. 이 RFC 는 그 사용량을 되살리지 않는다(#52359 §6 과 같다). 이어 하기는 그 호출 하나를 다시 낸다. 지금은 작업 전체를 잃고, 다시 보내면 모든 턴을 다시 낸다.
- **provider 쪽에서 도는 Tool**: provider 가 요청 안에서 직접 돌리는 Tool(서버 쪽 검색 등)은 5.1 의 새 호출에서 다시 돈다. masc 는 그 실행을 기록하지 않으므로 막을 수 없다.
- **위임**: 위임받은 Keeper 의 작업도 같은 규칙으로 이어 한다. 위임한 Keeper 의 Tool 호출이 끊겼으면 그쪽은 4.5 의 「결과 모름」을 받는다. 위임받은 작업의 상태는 `masc_keeper_delegate_status` 로 따로 읽을 수 있다.
- **전달**: 최종 답은 `Operation operation_id` 키로 한 번만 쓴다(`lib/server/server_keeper_operation_transcript.ml:35-56`). 이어 해도 답이 두 번 쌓이지 않는다. 재기동이 실패 행을 먼저 쓰지 않으므로 답이 실패 행에 막히지도 않는다.
  - 멈출 때 stream route 는 그때까지의 Tool 행을 `Operation` 키로 쓴다(`server_routes_http_keeper_stream.ml:2128`, 1695-1699). 쓰기는 (키, 칸)마다 한 번이다(`keeper_chat_store_append_once.ml:164-185`). 5.2 처럼 같은 호출을 이으면 `resumed_from` 이 없어 같은 칸의 나중 결과가 쓰이지 않을 수 있다. 시험으로 확인한다(§8).
  - 재기동 때 끊긴 SSE 연결은 다시 붙지 않는다. 답은 transcript 에 남는다.

## 7. 하지 않는 것

- 종료 대기 시간을 늘리지 않는다. 얻는 몫이 작다(§2).
- 도구 경계까지 기다렸다 멈추지 않는다. 종료가 그만큼 늦어지고, 4.5 가 끊긴 Tool 을 다룬다.
- SIGKILL 정책(#49923)을 바꾸지 않는다.
- 결과를 모르는 Tool 을 호스트가 다시 실행하지 않는다.
- 같은 턴에서 provider 를 다시 부르지 않는다(#52359 의 기록 규칙).
- 오류 문구로 상태를 가르지 않는다.
- 이어 하기 횟수·시간 한도를 두지 않는다. 진전으로 판정한다(4.6).
- 공식 클라이언트 레인의 동작을 바꾸지 않는다(§10).
- native 호출이 묶이기 전에 끊긴 행(3.2 의 「호출 없음, continuation 없음」)은 바꾸지 않는다. 11-16 에 1건이다.

## 8. 시험

agent_core:
- 호스트 멈춤으로 provider 시도 중 취소 → root·턴·시도가 열린 채, terminal 없음, `on_terminal_disposition` 0회.
- 호스트 멈춤으로 Tool 핸들러 중 취소 → attempt 열림, 결과 없음, terminal 없음.
- 멈춤이 `Multiple`·`Finally_raised` 로 감싸여 와도 같다. 멈춤과 운영자 중단이 섞이면 닫힌다.
- 운영자 중단 생성자로 취소 → 지금처럼 `Cancelled` 로 닫힘.
- 열린 attempt·결과 없음으로 이어 하기 → 핸들러 0회, attempt 는 성공이 아닌 terminal, invocation 에 「결과 모름」, 다음 provider 요청에 그 결과가 실림, 실행 terminal 의 recovery 는 `Operator_repair_required`.
- 같은 모양에 열린 하위 실행이 있음 → 하위 실행도 `Cancelled` 로 닫히고 결과가 쓰인다.
- terminal Tool 이 끊긴 모양 → 지금처럼 `TerminalToolEffectFailed`.
- 이어 하지 않는 실행(fresh)에서 같은 처리가 일어나지 않는다.
- 결과 없이 `Cancelled` 로 닫힌 invocation 으로 이어 하기 → 지금과 같음.
- 같은 프로세스 원인으로 이어 하는 실행이 열린 attempt·결과 없음을 만남 → 지금처럼 `Effect_outcome_unknown` 으로 실패, 결과를 쓰지 않음.
- 멈춘 실행 뒤 runner 의 terminal 전달 0회, writer 는 terminal 없이 닫히고 잠금이 풀림.

masc:
- Agent API 레인, provider 호출 중 정상 재기동 → 작업 `running`, 입력 남음. 다음 기동 → 새 호출 1회, 작업 `succeeded`.
- 위 경우를 작업의 **첫** provider 호출에서 → 같은 결과. canonical 에 입력이 없어도 retained seed 에서 연다.
- native 진행 뒤 canonical 저장 전에 끊김 → 같은 결과.
- `Succeeded` terminal 이 기록에 있는 `Active` 호출 → 다시 돌리지 않는다(지금처럼 실패 정리).
- Agent API 레인, Tool 실행 중 정상 재기동 → 다음 기동 → Tool 핸들러 다시 실행 0회, 모델이 「결과 모름」을 받음, 작업 `succeeded`.
- 같은 경우들을 비정상 종료로 → 결과가 위 시험과 같다. 이 RFC 의 핵심 시험이다.
- 연속 재기동 둘, 그 사이 진전 없음 → 두 번째 기동에서 `Interrupted_by_restart`. 진전 있음 → 두 번째에도 이어 한다.
- 같은 Keeper 의 다른 작업이 먼저 돌아 canonical 을 바꾼 뒤 → 이어 하는 작업은 retained 체크포인트에서 연다.
- 멈춤과 운영자 중단이 두 순서로 → `Turn_cancelled`.
- 멈춘 Owner → 새 자식 0개, `Bind` 거절. 같은 Keeper 에 새 Owner 를 만들면 기동 정리부터 돈다.
- 4.4 의 두 쓰기 앞·사이·뒤에서 죽음을 주입 → 다음 기동이 4.4 표대로 판정한다. 사이에서 죽으면 `Interrupted_by_restart`, 끝난 일은 다시 돌지 않는다.
- 미룬 작업을 같은 프로세스에서 다시 claim → 「재기동 뒤」를 넘기지 않는다.
- 이어 하기 두 번 → 작업의 이어 한 지점 목록 길이 2, 화면에 같은 값.
- 공식 클라이언트 레인 정상 재기동 → 지금과 같다.
- transcript: 작업마다 최종 행 하나, 재기동 때 실패 행 없음. 5.2 로 이어 한 뒤 Tool 행이 빠짐없이 남는다.

## 9. 단계

| 층 | 내용 | 앞 층 | 바뀌는 운영 동작 |
|---|---|---|---|
| L0 | 이 RFC, #52359 에 결정 기록 | — | 없음 |
| L1 | agent_core `retire_uncollected_turn` (#52359 L1) | — | 없음. 부르는 곳이 없다 |
| L2 | agent_core: 호스트 멈춤은 기록을 닫지 않는다(4.2) | — | 없음. masc 가 함수를 넘기기 전이다 |
| L3 | agent_core: 끊긴 Tool 을 typed 결과로(4.5), codec | — | 비정상 종료 뒤 Tool 이 끊긴 작업이 `Durability_failure` 대신 「결과 모름」으로 이어진다 |
| L4 | masc 기동 정리: retire 뒤 retained 체크포인트에서 새 호출(4.4), 이어 한 지점(4.6), #52359 L2 를 대신함 | L1 | 비정상 종료 뒤 모으기 전에 끊긴 작업이 turn counter 불일치 대신 이어진다. 진전 없이 다시 끊긴 작업은 끝난다 |
| L5 | masc Owner: 멈출 때 4.2 의 함수를 넘긴다(4.3) | L2·L3·L4 | 정상 재기동도 위 두 경로를 탄다 |

- L3 과 L4 는 비정상 종료 경로만 바꾼다. 둘 다 지금 실패로 끝나는 작업을 잇는 쪽이다.
- L5 가 마지막이다. L5 를 먼저 넣으면 끊긴 provider 호출과 Tool 이 각각 turn counter 불일치와 `Durability_failure` 로 실패한다. 실패 종류만 바뀌고 일은 여전히 사라진다.
- 층마다 거짓이 되는 문서·주석을 같은 층에서 고친다.
  - L2: `agent.mli:350-363`.
  - L3: `agent.mli:320-326`.
  - L5: `docs/design/keeper-repetition-scope-boundaries.md:13`, `keeper_owner_registry.ml:426-434`, `keeper_owner.ml:951-956`·1862-1868.

## 10. 정할 것

- **공식 클라이언트 레인**. 같은 CLI 세션을 다시 열어 잇는 방법이 후보다.
  - CLI 마다 SIGKILL 뒤 세션을 다시 열었을 때 끊긴 Tool 호출이 모델에게 어떻게 보이는지 먼저 잰다.
  - 비정상 종료 뒤 `Process_restarted` 가 `Ambiguous` 로 남는 동작도 같이 정한다. 세션 저장소 주석은 이런 상태가 그 Keeper 의 다음 턴을 모두 막았다고 적는다(`keeper_official_client_session_store.ml:54-59`, #28012).
  - 이 RFC 와 따로 쓴다.
- **저장된 runtime·계정이 재기동 뒤 없는 경우**(6). #52359 §10 셋째 항목과 같다. 재현한 뒤, 4.4 처럼 호출을 내리고 retained 체크포인트에서 새 호출을 열지 정한다.
- **retire 와 다시 큐에 넣기 사이에 죽는 경우**. 판정은 4.4 의 표다. 다음 기동은 terminal 을 읽고 `Interrupted_by_restart` 로 끝낸다(#52359 §5). terminal 증거에 retire 원인을 남기면(#52359 §10 첫 항목) 이 구간도 이어 할 수 있다. 좁은 구간이라 이 RFC 는 지금 경로를 두고, 시험(§8)으로 판정을 고정한다.
- **「결과 모름」 문구에 자식 프로세스 상태를 적을지**. 정상 재기동은 자식을 SIGKILL 로 끝낸다(3.1 의 4). 비정상 종료 뒤 자식이 남는지는 확인하지 않았다.
- **retained 체크포인트를 canonical 로 먼저 설치하는 방법**. 4.4 대신 `call.checkpoint` 를 canonical 로 설치하고 기존 loader 를 쓰는 길도 있다. canonical 저장은 turn 번호가 엄격히 작을 때만 낡은 것으로 막는다(`keeper_checkpoint_store_save.ml:94`). 이 길은 먼저 돈 다른 작업이 canonical 을 앞으로 옮긴 경우(5.4)에 막히므로 4.4 를 고른다.
