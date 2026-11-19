---
rfc: "restart-resumes-running-chat-operations"
title: "A server restart resumes running chat operations from their last record instead of failing them"
status: Draft
created: 2026-11-16
updated: 2026-11-17
author: claude
related: ["uncollected-provider-turn-is-not-resumed", "last-path-resumes-after-progress"]
---

# RFC: 서버를 다시 띄워도 돌던 채팅 작업은 마지막 기록부터 이어 한다

- 상태: 초안. L1~L3 과 L4.1 의 코드는 main 에 있다(§9).
- 이슈: #46505(재시작이 Keeper 턴을 끊는다). 앞선 RFC: `uncollected-provider-turn-is-not-resumed`(#52359).
- 결정(운영자, 2026-11-16): 정상 재기동과 비정상 종료 모두 돌던 채팅 작업을 이어 한다. #52359 §10 의 「끊긴 메시지를 이어 할지」에 대한 답이다.
- 리뷰 보강(2026-11-16): #52453 리뷰의 보류 네 가지를 4.2·4.4·4.5·4.6·8 에 반영했다. 보강 부분의 코드는 `origin/main` `83461169d090` 에서 읽었다.
- L4 결정(2026-11-17): 4.7(「재기동 뒤」 근거). 코드는 `origin/main` `f51362a745d9` 에서 읽었다.
- L4 다시 정함(2026-11-17): 이어 한 횟수나 진전으로 작업을 끝내지 않는다(4.6). 모으기 전에 끊긴 턴은 기동 정리가 아니라 그 작업을 집은 claim 이 닫는다(4.4). 기동 정리가 기록을 읽지 못한 호출은 실패로 끝낸다(4.8). 4.5 의 미루기 서술과 4.7 의 집합 범위를 고쳤다. 고친 부분의 코드는 `origin/main` `467cfe8e8373` 에서 읽었다.
- L4.3 결정(운영자, 2026-11-17): 자식이 `Active` 호출을 둔 채 실패로 끝나면, Owner 가 멈추는 중이 아닌 한 호출을 닫고 작업을 실패로 끝낸다(4.3). §10 에 두었던 「claim 이 호출을 `Active` 로 둔 채 실패한 경우」의 답이다. 고친 부분의 코드는 L4.2 스택 맨 위 `c0ce36993b06` 에서 읽었다.
- 근거: 코드는 `origin/main` `4a8a9920776a` 에서 읽었다. §1 수치는 Keeper 마다 `chat-operations.sqlite3` 를 읽기 전용으로 한 번 열어 셌다. 입력 문장은 열지 않았다. 시각은 KST 다.

## 0. 요약

서버를 내렸다 올리면 그때 돌던 채팅 작업은 실패로 끝나고 입력이 지워진다. 위임한 Keeper 와 MCP 에이전트는 그 일을 다시 보내지 않는다. 일은 그대로 사라진다.

Owner 는 이미 「멈춘 작업의 native 호출은 열어 두고 다음 기동이 이어 하게 한다」고 정해 두었다. 그런데 agent_core 가 취소를 받으면 실행 기록을 먼저 닫는다. 그래서 Owner 의 의도가 닿지 않는다.

이 RFC 는 재기동이 실행을 멈추기만 하고 기록은 닫지 않게 한다. 정상 재기동과 비정상 종료는 같은 기록 모양을 남긴다. 다음 기동이 둘을 같은 규칙으로 판정한다.

- provider 응답을 모으기 전에 끊긴 턴은 #52359 의 함수로 닫는다. 그 호출이 남긴 마지막 체크포인트에서 새 native 호출을 연다.
- 실행 중 끊긴 Tool 은 다시 실행하지 않는다. 「결과를 모른다」는 typed 결과를 모델에게 주고 턴을 잇는다.
- 이어 한 횟수나 진전을 세어 작업을 끝내지 않는다. 같은 작업이 서버를 계속 죽이는 고리(3.5)는 운영자가 그 작업을 취소해 끊는다(4.6).
- 이어 하기는 조건이 맞을 때만 일어난다. 정상 재기동이 작업을 언제나 보존한다고 약속하지 않는다(4.1).
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

- 종료 절차에 끊긴 채팅 작업이 118건이다. 모두 SIGTERM 60초 안에 끝났다.
- 다른 Keeper 의 위임 39건과 MCP 에이전트 50건은 같은 입력으로 다시 들어온 적이 한 번도 없다.
- 대시보드에서 사람이 보낸 29건 가운데 7건만 다시 들어왔다.
- 끊긴 작업 118건의 `input_json` 이 모두 비어 있다.

## 2. 왜 문제인가

- 위임과 MCP 요청은 보낸 쪽이 다시 보내지 않는다. 끊기면 일이 사라진다. 보낸 쪽은 실패를 받지만, 그 일을 다시 맡을 주체가 없다.
- 운영자가 배포하려고 정상적으로 내리는 쪽이 비정상 종료보다 일을 더 많이 잃는다. 같은 사건인데 경로에 따라 결과가 갈린다.
- 입력이 지워져서 무엇을 잃었는지도 남지 않는다.
- 종료를 더 오래 기다리는 방법은 얻는 몫이 작다. 60초를 더 기다려도 끝나는 턴은 상한이 8.2% 다(evidence README「종료를 기다리면」).
- 「작업을 실패로 끝내야 한다」는 근거를 적은 문서는 찾지 못했다. `Interrupted_by_restart` 라는 이름을 정한 #49333 과 SIGKILL 을 고른 #49923 은 이름과 종료 속도만 다룬다.

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
- 다시 큐에 넣은 행은 `queued` 이고 호출은 `Active` 로 남는다. 이 행을 큐에서 취소하면 거절된다. 운영자 화면과 Keeper Tool 표면의 취소가 같은 명령을 탄다(`keeper_owner_registry.ml:1007-1009`). 취소는 semantic 실행을 `Settle` 로 닫는데(`keeper_chat_operation_store.ml:3401-3426`, 3461-3471), `Active` 호출이 있으면 `Settle` 이 `Native_call_unsettled` 로 거절된다(`keeper_semantic_execution.ml:858-861`). 코드로 읽은 흐름이고 재현하지 않았다.

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

> 재기동은 실행을 멈출 뿐 실행 기록을 닫지 않는다. 다음 기동이 기록을 읽고 판정한다. 이어 한 횟수나 진전을 세어 작업을 끝내지 않는다.

- 정상 재기동이 남기는 기록 모양을 비정상 종료와 같게 만든다. 그러면 두 경로가 같은 판정을 받는다. 기동 정리가 3.2 의 표로 판정하고, 그 작업을 집은 claim 이 끊긴 구간을 판정한다(4.4, 4.5).
- 운영자 중단(`Operator_interrupt`)은 지금처럼 기록을 닫는다. 운영자가 끝내라고 한 일이다.
- 작업의 새 실패 종류와 횟수 한도는 더하지 않는다. 기동 정리가 끝내는 작업은 지금처럼 `Interrupted_by_restart` 로 끝난다. claim 에서 실패한 작업은 지금 있는 실패 종류로 끝난다(4.3).
- 저장 상태는 하나를 더한다. 4.5 의 「끊긴 Tool 결과」다. 없으면 기록이 사실과 다르게 남는다.
- 「끊긴 Tool 결과」는 Core journal 에 생성자를 더하기만 한다. 이미 있는 journal 은 그대로 읽힌다. 작업 저장소의 형식은 바꾸지 않는다.
- 이어 하기는 조건이 맞을 때만 일어난다. 아래 모양은 이어지지 않는다. 정상 재기동이 작업을 언제나 보존한다고 약속하지 않는다.
  - 기록에 terminal 이 이미 있다(3.2). 호스트 멈춤이 아닌 취소는 지금처럼 기록을 닫는다(4.2).
  - writer 종료가 증명되지 않았다(4.7).
  - 기동 정리가 기록을 읽지 못했다(4.8).
  - 끊긴 Tool 이 terminal Tool 이거나 하위 실행 안에 있다(4.5).
  - 4.4 의 retire 뒤 새 호출을 묶기 전에 claim 이 끝났다.
  - claim 이 호출을 `Active` 로 둔 채 실패했다. Owner 가 호출을 닫고 작업을 실패로 끝낸다(4.3).
  - 묶인 runtime 이 재기동 뒤 설정에 없다(§6).
  - 공식 클라이언트 레인이다(3.4).
  - native 호출이 묶이기 전에 끊겼고 continuation 이 없다(§7).

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
- Owner 가 호출을 `Active` 로 남기는 때는 Owner 가 멈추는 중일 때뿐이다. 자식이 멈춤으로 끝났거나(`Child_stopped_by_owner`), 멈추는 중에 실패를 돌려준 경우다.
- 그 밖에 자식이 `Active` 호출을 둔 채 실패로 끝나면, Owner 가 호출을 「효과 모름」 영수증으로 닫는다. 작업은 자식이 돌려준 실패 종류로 끝난다(운영자 결정, 2026-11-17).
  - 이 프로세스가 그 호출을 Bind 했는지는 보지 않는다. claim 이 물려받은 호출을 열지 못한 경우도 같다(4.4, 4.8).
  - 그 Keeper 는 다음 작업을 집는다. 실패가 잠깐이었어도 그 작업은 잃는다.
  - 닫는 이유: 이 프로세스에는 그 호출을 이어 할 재기동이 오지 않는다. 남겨 두면 자식 없는 `running` 행이 다음 기동까지 그 Keeper 의 채팅 큐를 막는다(`keeper_chat_operation_store.ml:2016-2020`). 같은 프로세스에서는 운영자도 그 행을 끊지 못한다(4.6).
  - 영수증은 journal 을 읽지 않고 적는다. Owner 는 운영자 중단과 자식 예외(`Child_raised`) 뒤에도 이미 같은 영수증으로 닫는다. 효과가 끝났다고 주장하지 않는다.
  - 닫는 쓰기가 거절되면 작업을 끝낸 것으로 보지 않는다. 지금처럼 오류를 남기고 행을 둔다. 저장소를 다시 열면 `After_store_recovery` 정리가 같은 영수증으로 닫고 작업을 `Store_unavailable` 로 끝낸다(`keeper_owner.ml:1174-1213`).
- 공식 클라이언트 레인의 멈춤은 바꾸지 않는다(§10).

### 4.4 모으기 전에 끊긴 턴은 남은 체크포인트에서 새 호출로 잇는다

#52359 의 `retire_uncollected_turn` 을 그 작업을 집은 claim 이 부른다. 기동 정리는 retire 를 부르지 않는다. 지금처럼 기록을 읽어 판정만 한다(3.2, 4.8).

**기동 정리가 아니라 claim 인 이유**

- 기동 정리는 Owner 의 명령 안에서 돈다(`keeper_owner.ml:2033-2094`). 그 안에서는 그 Owner 의 mailbox 를 부를 수 없다(`keeper_direct_native_continuation.ml:165-167`). 기동 정리에서 닫으려면 호출 terminal·`Suspend`·다시 큐를 한 번에 쓰는 store transaction 과, retained 체크포인트를 가리키는 continuation 의 저장 모양을 새로 만들어야 한다.
- claim 은 Owner 의 자식 fiber 에서 돈다. 이미 있는 Owner 명령 둘이면 된다. 호출에 terminal 을 적는 명령(`keeper_direct_native_continuation.ml:159-162`)과, `Retire` 로 끝난 호출을 새 호출로 바꾸는 Bind(`:387-419`)다.
- 기동 정리에서 닫으면 journal 을 쓰는 동안 Owner 가 다른 명령을 받지 못한다. 예외가 새면 registry 가 그 Owner 를 멈춘다(`keeper_owner.ml:2092-2094`, `keeper_owner_registry.ml:274-277`). claim 에서 닫으면 retire 가 실패해도 Owner 는 계속 돈다. 그 작업은 실패로 끝나고 Keeper 는 다음 작업을 집는다(4.3).
- 새 저장 필드, 새 store transaction, 스키마 변경이 없다.

**순서**

claim 이 native 호출을 열기 직전의 준비(`keeper_direct_native_continuation.ml:295`)에서 한다. 준비는 지금도 `Active` 호출을 복원하고(`:308-309`), writer 종료를 Owner 에 묻는다(`:346-356`).

1. writer 종료가 증명된 호출(4.7)이면 `retire_uncollected_turn` 을 부른다. `checkpoint_turn_count` 는 `call.checkpoint` 참조의 `turn_count` 다(`keeper_checkpoint_ref.mli:4-8`). 증명이 없는 호출에는 부르지 않는다.
2. `Not_uncollected` 면 지금처럼 같은 호출을 이어 한다(5.2).
3. `Retired` 면 그 disposition 을 호출의 terminal 로 적는다. 호출은 `Terminal_unacknowledged(Retire)` 가 된다. recovery 는 기록 전체에서 나온다. 결과 없는 Tool attempt 가 다른 곳에 남아 `Retire` 가 아니면 새 호출을 열지 않는다. Bind 가 거절하고(`keeper_direct_native_continuation.ml:409-412`) 작업은 실패로 끝난다.
4. 끊긴 호출의 `call.checkpoint` 에서 새 실행을 연다. 실행이 준비되면 Bind 가 앞 호출을 새 호출로 바꾼다.
5. 새 호출이 끊긴 턴 k 의 provider 호출을 다시 낸다.

- retire 가 오류를 내면 기록을 한 번 더 읽는다(#52359 §4.2 의 5).
  - terminal 이 생겼으면 읽은 terminal 의 disposition 을 호출의 terminal 로 적고 4 로 간다. 준비 앞의 `load` 가 지금 하는 일과 같다(`keeper_direct_native_continuation.ml:154-163`). 이 claim 의 `load` 가 읽었을 때는 terminal 이 없었고(`:236-240`) 앞 writer 는 끝났으므로, 그 terminal 은 이번 retire 가 쓴 것이다.
  - 없으면 그 claim 은 실패한다. Owner 가 호출을 「효과 모름」 영수증으로 닫고 작업을 실패로 끝낸다(4.3). 그 Keeper 는 다음 작업을 집는다.

**새 호출을 여는 근거는 이번 retire 의 결과다**

- 근거는 이번 retire 가 기록을 닫았다는 사실이다. 1 이 돌려준 `Retired` 값이거나, 오류 뒤 다시 읽어 새로 생긴 terminal 이다. 영수증의 `Retire` 로 가르지 않는다. recovery 는 실행이 어떻게 끝났는지가 아니라 Tool attempt 마다 결과가 있는지로 정해진다(`packages/agent_core/lib/agent/agent.mli:326-330`). `Succeeded` 로 끝난 실행도 `Retire` 다. `Retire` 로 가르면 끝난 작업을 다시 돌린다.
- claim 이 처음 본 호출이 이미 `Terminal_unacknowledged` 이거나 기록에 terminal 이 있으면 지금처럼 거절한다(`keeper_direct_native_continuation.ml:232-244`, `keeper_turn.ml:478-479`).

**죽는 구간**

| 죽은 때 | 남은 모양 | 다음 기동 |
|---|---|---|
| claim 뒤, retire 전 | 행 `running`, 호출 `Active`, journal 열림 | 다시 큐에 넣는다. 다음 claim 이 1 부터 한다 |
| retire 뒤, 3 전 | 호출 `Active`, journal 에 `Cancelled` terminal | 3.2 의 「`Active` 호출, 기록에 terminal 있음」. 작업은 `Interrupted_by_restart` 로 끝난다 |
| 3 뒤, Bind 전 | 호출 `Terminal_unacknowledged(Retire)`. 새 실행 디렉터리가 만들어졌으면 묶이지 않은 채 남는다 | 3.2 의 「`Terminal_unacknowledged`」. 작업은 `Interrupted_by_restart` 로 끝난다 |
| Bind 뒤 | 새 호출 `Active`, 새 journal | 새 호출을 같은 규칙으로 판정한다 |

- 둘째·셋째 구간에서는 일이 사라진다. 끝난 일을 다시 돌리지는 않는다.
- 정상 종료가 3 과 Bind 사이에 와도 셋째 줄과 같다. 멈추는 Owner 는 호출 terminal 은 받고 Bind 는 거절한다(`keeper_owner.ml:2406-2412`).
- 두 구간도 이어 하려면 journal terminal 이 「재기동 뒤 정리가 닫았다」를 typed 로 담아야 한다(§10).
- 3 과 Bind 사이에 준비가 실패하면 작업을 실패로 끝낸다. 다음 후보로 넘어가거나 미루지 않는다. `Suspend` 계열 전이는 `Retire` 로 끝난 호출을 내리면서 다른 continuation 을 받는다(`keeper_semantic_execution.ml:872-877`). 그 continuation 의 loader 는 retained 체크포인트를 모른다.

**새 호출은 retained 체크포인트에서 연다**

- 새 native 호출의 시작점은 끊긴 호출의 `call.checkpoint` 다. 그 호출이 마지막으로 옮긴 retained 체크포인트이고, 끊긴 턴 k 의 provider 호출 전이다(#52359 §4.2 의 1).
- 새 호출은 `Continue_from_checkpoint` 로 연다. 체크포인트로 시작하는 native 호출이 이미 쓰는 경로다(`keeper_turn_driver_try_provider.ml:2748`).
- 새 호출의 runtime 은 끊긴 호출에 묶인 `runtime_id` 다. 준비는 호출을 복원할 때 runtime 과 모델이 같은지 이미 확인한다(`keeper_direct_native_continuation.ml:318-322`). 5.2 와 같은 준비 경로를 쓴다. 이 경로로 새 호출을 여는 코드는 아직 읽지 않았다(§10).
- 새 호출의 seed 는 `call.checkpoint` 의 이력을 줄이거나 바꾸지 않고 그대로 쓴다. Bind 는 지금 검증을 그대로 하지만 이 조건을 다 확인하지는 않는다.
  - Bind 는 새 seed 가 앞 호출이 settle 한 Tool 결과를 모두 가졌는지 본다. 앞 호출에 Tool 시도가 있었으면 앞 호출의 마지막 체크포인트 이력이 새 seed 의 접두어인지도 본다(`keeper_direct_native_continuation.ml:393-407`).
  - 앞 호출에 Tool 시도가 없었으면 Bind 는 이력을 보지 않는다(`keeper_direct_native_continuation.ml:404-407`). 작업의 첫 provider 호출에서 끊긴 경우가 그렇다. 이 경우는 시험이 seed 를 `call.checkpoint` 와 대조한다(§8).
- canonical loader(`Bound_checkpoint`)는 쓰지 않는다. loader 는 canonical head 에서 이어 하고, 저장된 참조는 접두어 확인에만 쓴다(`keeper_direct_checkpoint_continuation.ml:43-79`). native 호출의 seed 와 그 뒤 체크포인트는 retained 영역에만 있다. canonical 은 keeper sink 가 native 진행 뒤에 쓴다(`keeper_agent_run.ml:1371-1406`, `keeper_direct_native_continuation.ml:472-474`).
  - 작업의 첫 provider 호출에서 끊기면 `call.checkpoint` 는 seed 다(`keeper_native_call.ml:30-38`). seed 에는 새 입력이 있고 canonical 에는 없다.
  - native 진행과 canonical 저장 사이에서 끊겨도 canonical 이 뒤처진다.
- 같은 턴에서 provider 를 다시 부르지 않는다는 #52359 의 기록 규칙은 그대로다. 닫힌 실행과 새 실행이 따로 있다.

### 4.5 결과를 모르는 Tool 은 다시 실행하지 않고 모델에게 알린다

이어 한 실행이 3.3 의 「attempt 는 열렸고 결과가 없는 invocation」을 만나면:

- 핸들러를 부르지 않는다.
- 새 journal transaction `Settle_unreturned_tool_attempt` 하나로 끊긴 attempt 를 닫는다(#52568). 지금 결과를 쓰는 transaction 은 attempt 를 언제나 `Succeeded` 로 닫으므로 쓰지 않는다. 끊긴 attempt 를 `Succeeded` 로 적으면 사실과 다르다.
  - attempt 는 `Cancelled` 로 닫는다.
  - invocation 에 「결과 모름」 결과를 typed 로 적는다. 실패 종류 `Writer_exited_tool_error` 를 `Types.tool_failure_kind` 에 더한다(#52565). `tool_result_outcome` 은 그대로 둔다. 「결과 모름」도 실패이고, 실패의 종류를 가르는 자리가 이미 있다.
  - attempt 아래에 열린 하위 실행(child run)이 있으면 같은 transaction 에서 `Cancelled` 로 닫는다. 열린 하위 노드가 있으면 결과를 쓸 수 없다(`Tool_result_while_children_open`). 하위 실행이 낸 효과는 부모의 「결과 모름」에 포함된다.
  - 하위 Tool invocation 에 attempt 가 있고 결과가 없으면 transaction 이 거절한다. 하위 실행을 이미 취소로 닫은 경우도 전체 자식 이력에서 확인한다. 이 결과를 부모 결과로 대신하면 recovery 는 여전히 `Operator_repair_required` 다. 거절하지 않으면 이어 한 실행이 provider 를 다시 부르고 성공으로 끝난 뒤에야 `Turn_invariant` 실패로 드러난다. 결과를 기록한 하위 호출은 허용한다. 거절하면 `Resume_writer_exit_unproven` 과 같이 실패로 끝난다(§10).
- 닫은 attempt 에는 결과가 있으므로 recovery 판정은 `Retire` 다. 「결과 모름」은 결과의 실패 종류로만 남는다.
  - recovery 를 `Operator_repair_required` 로 두면 이어 한 작업이 성공할 수 없다. Owner 는 성공과 `Effect_outcome_unknown` 이 같이 오면 `Turn_invariant` 실패로 적는다(`keeper_owner.ml` `native_call_unknown_effect_success_detail`).
  - `Operator_repair_required` 는 「결과 없는 attempt 가 남았다」는 뜻이다. 여기서는 결과를 적었으니 그 상태가 아니다. 다음 행동은 결과를 본 Keeper 가 고른다.
- 턴은 계속된다. 다음 provider 호출이 이 결과를 본다. 결과 문구에는 사실만 쓴다. 「호출이 서버 재기동으로 끊겼다」, 「효과가 일어났는지 모른다」, 「다시 실행하지 않았다」.
- 이 처리는 호스트가 「실행을 마지막으로 쓴 프로세스가 끝났다」고 알린 실행에서만 한다. 호스트는 `execution_store` 의 resume 으로 `Resume_after_writer_exit` 를 넘긴다. 아무 주장도 하지 않으면 `Resume_writer_exit_unproven` 이다(#52567).
  - `with_resume_once`(`agent_execution_runner.ml:462`)로는 가를 수 없다. resume 이 다른 프로세스에서 왔다는 사실을 Core 는 알 수 없다. 한 프로세스가 pool 을 다시 설치하면 같은 프로세스 안에서 resume 한다(4.7).
  - masc 의 Owner 는 지금 같은 프로세스에서 `Active` 호출을 다시 집지 않는다. 미루기 전이는 `Active` 호출이 있으면 `Native_call_unsettled` 로 거절된다(`keeper_semantic_execution.ml:858-869`, 시험 `test_keeper_native_call_store.ml:462-481`). 자식이 `Active` 호출을 남긴 채 끝나면, Owner 는 멈추는 중이 아닌 한 그 호출을 닫는다(4.3). 멈추는 Owner 는 다시 claim 하지 않는다.
  - 같은 프로세스 안에서는 이 모양이 생기지 않는다. 핸들러가 값을 돌려주면 settle 이 돈다. 예외를 던지면 settle 을 건너뛰고 `abort` 가 실행을 닫는다(`execution_tool_settlement.ml:176-188`). 4.2 뒤에 닫지 않는 경우는 멈춤뿐이고, 멈춘 Owner 는 다시 claim 하지 않는다(4.2 의 표).
  - 그래도 같은 프로세스 resume 에서 이 모양을 만나면 지금처럼 `Effect_outcome_unknown` 으로 실패한다. 위 근거가 틀려도 「결과 모름」을 지어 쓰지 않는다.
  - 같은 프로세스에서는 핸들러가 바깥 switch 에 띄운 fiber 가 아직 돌 수 있다. 프로세스가 끝났다면 그런 코드가 남지 않는다. 이 차이가 원인을 타입으로 받는 이유다.
  - masc 는 끝난 이미지가 마지막으로 쓴 호출을 이 이미지가 처음 열 때만 「재기동 뒤」를 넘긴다. 그 호출을 가르는 근거는 4.7 이다.
- terminal Tool(`Terminal_after_success`)은 바꾸지 않는다. 결과를 모르면 지금처럼 `Durability_failure` 로 실패하고, 실행은 `TerminalToolDurabilityFailed` 로 끝난다(`pipeline/pipeline_terminal_tool.ml` `durability_failure`). 실행을 끝내는 Tool 이라 「턴을 잇는다」가 성립하지 않는다.
  - terminal Tool 결과에 `Writer_exited_tool_error` 가 오면 `Terminal_failed` 이고 효과 구분은 `Effect_outcome_unknown` 이다. Tool 이 선언한 효과 구분은 핸들러가 돌려준 실패에만 맞는다.
- 공개 계약 `Agent.execution_store` 문서를 바꾼다. resume 의 거절 갈래(`agent_tools.ml` `Invocation_attempted_or_settled`)는 그대로 둔다. 닫은 attempt 는 settle 된 결과로 다시 쓰인다(`Replayed`).

이 방법은 지금보다 모르는 채로 다시 실행하는 일을 줄인다. 지금은 작업이 실패한다. 사람이 같은 요청을 다시 보내면, 새 실행은 앞 시도가 있었다는 사실도 모른 채 모든 Tool 을 다시 실행한다. 이 RFC 뒤에는 모델이 끊긴 호출 하나를 알고 상태를 먼저 확인할 수 있다. 무엇을 할지는 Keeper 가 고른다.

닫힌 모양(옛 `abort` 가 결과 없이 `Cancelled` 로 닫은 invocation)은 바꾸지 않는다. 4.2 뒤에는 재기동이 이 모양을 새로 만들지 않는다.

### 4.6 이어 한 횟수나 진전으로 작업을 끝내지 않는다

3.5 의 고리를 호스트의 판정으로 끊지 않는다. 운영자가 그 작업을 취소해 끊는다.

**진전을 판정하지 않는 이유**

- 체크포인트가 나아갔는지를 대조해도 고리는 끊기지 않는다. 이어 한 실행은 끊긴 Tool 에 「결과 모름」을 붙이고 체크포인트를 저장한다(`packages/agent_core/lib/pipeline/pipeline.ml:600`). masc 의 sink 가 그때 `call.checkpoint` 를 옮긴다(`keeper_direct_native_continuation.ml:375-386`, 470-471). 서버를 죽인 Tool 을 모델이 다시 부르면, 기동마다 체크포인트가 나아간 채 같은 일이 되풀이된다.
- 범용 Keeper 에서 「진전」을 사실 대조만으로 정하는 방법을 찾지 못했다. Tool 호출·응답·문장이 되풀이된 횟수는 정체나 중단의 근거가 아니다(`docs/constitution.xml` 의 `magic_number`). 재기동·실패 횟수는 관측에만 쓴다(`budget_gate`).
- 다음 행동은 「결과 모름」을 받은 Keeper 가 고른다(4.5).

**운영자가 끊는 길**

- 도는 중: 운영자 중단은 지금처럼 기록을 닫고 작업을 `Turn_cancelled` 로 끝낸다(4.2). Core 가 닫은 기록의 영수증이 호출에 남는다. 그래도 호출이 `Active` 로 남으면 Owner 가 「효과 모름」 영수증으로 닫는다(`keeper_owner.ml:973-975`, 1687-1708).
- 큐에 있는 중: 기동 정리가 다시 넣은 작업은 호출이 `Active` 라서 지금은 취소가 거절된다(3.2). 취소를 받게 고친다. 큐 취소 transaction 이 그 안에서 호출을 「효과 모름」 영수증(`Keeper_native_call.unknown_effect_disposition`)으로 닫고 작업을 `cancelled` 로 끝낸다(`keeper_chat_operation_store.ml:3401-3426`). Owner 의 호출 terminal 명령은 `queued` 행을 받지 않아 쓸 수 없다(`:3252-3253`). 도는 중의 운영자 중단에서 호출이 `Active` 로 남았을 때 Owner 가 남기는 영수증과 같다. 「효과 모름」 영수증은 `Settle Cancelled` 를 막지 않는다(`keeper_semantic_execution.ml:883-896`).
- Keeper 가 일시 정지(`paused`)면 Owner 는 작업을 집지 않는다(`keeper_owner.ml:1369-1373`, 1835). `paused` 는 저장된 Keeper 메타의 필드이고(`keeper_meta_contract.ml:137`, `keeper_meta_json_parse.ml:263`), Owner 는 뜰 때 받은 메타로 첫 상태를 만든다(`keeper_owner.ml:1395-1397`). 그래서 일시 정지한 Keeper 는 재기동 뒤에도 작업을 집지 않는다. 코드로 읽은 흐름이고 재현하지 않았다.
- 자식 없이 `running` 으로 남은 행: 같은 프로세스에서는 운영자가 끊을 길이 없다. 중단은 도는 자식이 없으면 받지 않는다(`keeper_owner.ml:1983-1985`, 2001-2016). 큐 취소는 `queued` 행만 받는다(`keeper_chat_operation_store.ml:3461-3471`).
  - 자식이 실패로 끝나면 Owner 가 호출을 닫고 작업을 끝낸다(4.3). 그래서 이 행은 Owner 가 멈추는 중, 기동 정리가 기록을 읽기 전, 정산 쓰기가 거절된 뒤에만 남는다.
  - 셋 다 운영자 없이 정리된다. 기동 정리, 저장소 복구 뒤 정리, 다음 기동 정리 가운데 하나가 그 행을 다시 큐에 넣거나 끝낸다. 코드로 읽은 흐름이고 재현하지 않았다.

**남는 위험**

- #52587 뒤로 main 은 비정상 종료로 Tool 실행 중 끊긴 호출을 이미 이어 한다(5.2). 서버를 죽인 Tool 을 모델이 다시 부르는 작업은 감시자(3.5) 아래에서 되풀이된다.
- 작업이 claim 직후 서버를 죽이면 운영자가 끼어들 틈이 좁다.
- L5 뒤에는 고리가 정상 종료로도 생긴다. `masc restart` 는 서버에 종료를 요청하고 다음 서버를 띄운다(`bin/masc_cli_restart.ml:361-388`). Keeper 의 Tool 이 이 명령을 부를 수 있는 환경이면, 비정상 종료 뒤에만 잇지 않는 규칙으로는 이 고리가 남는다.
- 비정상 종료 뒤에도 이을지는 L5 에서 관측값을 보고 다시 정한다(§10).

**기동마다 남기는 관측**

- 기동 정리가 끝나면 Keeper 마다 로그를 남긴다. 다시 큐에 넣은 작업의 id, 실패로 정리한 작업의 id, journal 을 읽지 못한 호출 수다.
  - 지금 Owner 의 로그는 둘이다. 뜰 때 끝낸 작업의 수(`keeper_owner.ml:1422-1428`)와 기동 정리 명령의 읽기 실패(`:2048-2051`)다. 뜰 때의 정리는 `Active` 호출이 있는 행을 그대로 둔다(`keeper_chat_operation_store.ml:3632-3634`).
  - 기동 정리 명령이 끝낸 작업의 수와 다시 큐에 넣은 작업은 Owner 의 로그에 없다.
- 다시 큐에 넣은 작업의 끝 상태는 작업 저장소가 가진다. 같은 id 가 다음 기동 로그에 또 나오면 다시 끊긴 작업이다.
- 작업마다 이어 한 횟수는 저장하지 않는다.
- 관측값으로 작업을 끝내지 않는다. 운영자의 판단과 L5 의 결정(§10)에 쓴다.

### 4.7 「재기동 뒤」는 프로세스 이미지 단위로 증명한다

`Resume_after_writer_exit` 는 「그 실행을 마지막으로 쓴 코드가 이제 하나도 돌지 않는다」는 주장이다. Owner 가 아니라 프로세스 이미지에 대한 주장이다. 같은 이미지 안에서는 핸들러가 바깥 switch 에 띄운 fiber 가 Owner 보다 오래 살 수 있다(4.5).

**지금 성립하는 사실**

- 서버는 프로세스가 사는 동안 base path 임대(커널 `lockf`)를 쥔다(`server_startup_takeover.mli` `acquire_base_path_lock`). 다음 프로세스는 앞 프로세스의 descriptor 가 닫힌 뒤에야 임대를 얻는다(`acquire_base_path_lock_after_owner_exits`). exec 은 임대를 넘기지만 앞 이미지의 코드는 남지 않는다.
- pool 은 base path 마다 하나다. 두 번째 설치는 `Inventory_already_installed` 로 거절된다(`keeper_owner_registry.ml` `install_from_store`).
- 한 pool 안에서 `Keeper_owner.start` 는 Keeper 마다 한 번 돈다. 첫 적재(`start_all` → `ensure_in_pool`)와 런타임 생성(`ensure_empty_in_pool`)만 Owner 를 만든다. 런타임 생성은 이미 있는 Owner 를 돌려준다. 기동 정리에 실패해 빠진 Keeper 는 `unavailable` 로 거절한다(`:280`, `:340`).
- 그래서 한 이미지의 첫 pool 에서 Owner 가 첫 작업을 집기 전에 저장소에 있는 `Active` 호출은 이미 끝난 이미지가 마지막으로 썼다.

**코드 모양에 기대는 부분을 타입으로 고정한다**

- 셋째 사실은 지금 코드 모양일 뿐이고 타입이 막지 않는다. 같은 이미지에서 앞 pool 의 switch 가 끝난 뒤 pool 을 다시 설치하면 깨진다. 시험 프로세스 하나가 pool 을 여러 번 설치한다(`test/test_keeper_native_reconcile_after_dispatch.ml` 126·326·396·481).
- registry 가 base path 마다 「이 이미지에서 기동 정리를 했다」를 프로세스 메모리에 적는다. 첫 pool 의 Owner 에만 `Prior_writers_exited` 를 넘긴다. 그 밖에는 `Prior_writers_unproven` 이다.
- Owner 는 뜰 때, 첫 작업을 집기 전에 저장소의 `Active` 호출 id 를 모두 읽어 둔다(`Keeper_chat_operation_store.active_native_calls`). 행이 `queued` 든 `running` 이든 같다. `Prior_writers_exited` 면 첫 기동 정리 명령이 끝날 때, 읽어 둔 호출 가운데 그 정리가 닫지 않았고 claim 이 묶지 않은 것을 메모리 집합에 둔다. 이번 기동이 다시 큐에 넣은 호출과, 앞선 기동이 다시 넣었는데 아직 집히지 않은 호출이 함께 든다.
  - 지금 코드(#52587)는 이번 기동에 `running` 이던 행의 호출만 넣는다(`keeper_owner.ml:1436`, `keeper_chat_operation_store.ml:3557-3580`). 기동 정리가 다시 큐에 넣은 작업이 claim 되기 전에 서버가 또 재기동하면, 그 행은 `queued` 이고 호출은 `Active` 다. 다음 기동은 그 호출을 집합에 넣지 않는다. claim 은 `Resume_writer_exit_unproven` 을 넘기고, 끊긴 Tool 이 있는 작업은 `Effect_outcome_unknown` 으로 실패한다. 모으기 전에 끊긴 턴은 retire 를 받지 못한다(4.4).
  - 집합은 이때 한 번 정하고 그 뒤로는 더하지 않는다. 기동 정리 명령을 다시 불러도 더하지 않는다. 나중에 읽은 `Active` 목록으로 채우면 이 이미지가 묶은 호출이 든다.
  - 집합은 기동 순서에 기대지 않는다. Owner 가 뜬 뒤에 이 이미지가 묶은 새 호출은 읽어 둔 목록에 없다. 읽어 둔 호출을 claim 이 기동 정리보다 먼저 묶으면 Bind 가 그 id 를 목록에서 지운다. 서버는 기동 정리를 끝낸 뒤에 Keeper 를 띄우지만(`server_runtime_bootstrap.ml:1021-1025`, 1155-1164), 그 순서가 바뀌어도 집합에 이 이미지가 묶은 호출은 들지 않는다. 시험으로 고정한다(§8).
- claim 이 그 집합의 호출을 열면 `Resume_after_writer_exit` 를 넘긴다(`keeper_direct_native_continuation.ml:346-356`). 4.4 의 retire 도 그 집합의 호출에만 한다. 같은 호출을 이어 하는 Bind 에서 그 id 를 지운다(`keeper_owner.ml:2416-2417`). 그 뒤로는 이 이미지가 writer 다. 이 이미지가 같은 호출을 다시 열면 `Resume_writer_exit_unproven` 이다.
- 집합은 저장하지 않는다. 이미지가 끝나면 같이 사라지고, 다음 이미지의 기동 정리가 처음부터 다시 판정한다.
- 이 근거는 이미지 안의 코드만 다룬다. journal 을 쓸 수 있는 것은 그 코드뿐이다. Tool 이 띄운 자식 프로세스는 비정상 종료 뒤에 남을 수 있다(§10). 남아도 「결과 모름」 문구는 사실이다.

**하지 않는 것**

- native 호출 기록에 writer 이미지 식별자를 저장하지 않는다. 저장하면 같은 호출의 Bind 가 기록을 바꾸는 일이 되고 호출 codec 이 바뀐다. 「writer 가 끝났다」는 이미지 단위 사실이라 이미지 메모리가 맞는 자리다.

### 4.8 기록을 읽지 못한 호출은 이어 하지 않는다

기동 정리가 `Active` 호출의 journal 을 읽지 못하면 그 작업 하나를 실패로 끝낸다. 다시 큐에 넣지 않는다(운영자 결정, 2026-11-17).

- 지금은 읽기 실패를 「terminal 없음」과 같게 다시 큐에 넣는다(`keeper_chat_operation_store.ml:3659-3662`). 읽기 실패는 로그에만 남는다(`keeper_owner.ml:2046-2051`).
- 그 뒤 claim 도 기록을 못 읽으면 실패한다(`keeper_turn.ml:496-501`). 지금은 호출이 `Active` 라 행이 `running` 으로 남고, 그 Keeper 는 다음 기동까지 다른 채팅 작업을 집지 못한다. 기록이 계속 안 읽히면 기동마다 되풀이된다.
- 읽지 못한 기록을 두고 실행을 다시 허락하는 일이기도 하다. 권위 있는 저장소를 읽지 못하면 변경을 승인하지 않는다(`docs/constitution.xml` 의 `authoritative_read_only`).
- 고친 동작: 호출을 「효과 모름」 영수증으로 닫고 작업을 `Interrupted_by_restart` 로 끝낸다. 저장소 복구 뒤의 정리(`After_store_recovery`)가 `Active` 호출을 닫는 방식과 같다(`keeper_chat_operation_store.ml:3663-3679`). 새 상태나 실패 종류를 더하지 않는다.
- Keeper 는 계속 돈다. 기록 파일은 그대로 둔다. 읽기 실패가 잠깐이었어도 그 작업은 잃는다.
- claim 이 기록을 읽지 못해 실패하면 Owner 가 그 자리에서 같은 영수증으로 닫는다(4.3).
- 읽기 실패를 그 Owner 의 기동 정리 실패로 올리는 길은 고르지 않았다. 잃는 일은 없지만, 기록 하나가 안 읽히면 그 Keeper 가 기동마다 빠진다(`keeper_owner_registry.ml:274-277`).

## 5. 순서와 상태

Keeper 하나, Agent API 레인, 채팅 작업 하나의 틱이다.

### 5.1 provider 호출 중에 정상 재기동

| 틱 | 일 | 지금 | 제안 |
|---|---|---|---|
| N | 턴 k 의 provider 호출 중 SIGTERM | 기록 `Cancelled` 로 닫힘, 작업 `failed`, 입력 지움 | 기록 열린 채, 작업 `running`, 입력 남음 |
| N+1 | 기동 정리 | 정리할 행 없음 | terminal 없음 → 다시 큐 |
| N+2 | Owner 가 작업을 집는다 | — | #52359 retire → 호출 terminal → retained `call.checkpoint` 에서 `Continue_from_checkpoint` 로 새 native 호출을 묶고 턴 k 를 다시 한다 |
| N+3 | 작업이 끝난다 | 보낸 쪽은 N 에 실패를 받음 | 보낸 쪽은 N+3 에 답을 받음 |

### 5.2 Tool 실행 중에 정상 재기동

| 틱 | 일 | 지금 | 제안 |
|---|---|---|---|
| N | 턴 k 의 Tool 실행 중 SIGTERM | 기록 닫힘, `Operator_repair_required`, 작업 `failed` | 기록 열린 채, 작업 `running` |
| N+1 | 기동 정리 | — | terminal 없음 → 다시 큐 |
| N+2 | Owner 가 작업을 집는다 | — | 같은 호출을 `call.checkpoint`(모은 체크포인트)에서 이어 한다. 끊긴 invocation 에 「결과 모름」을 쓰고, 끝난 invocation 은 기록에서 다시 쓰고, 시작 안 한 invocation 은 실행 |
| N+3 | 다음 provider 호출 | — | 모델이 「결과 모름」을 보고 다음 일을 고른다 |

비정상 종료는 N 의 「제안」 열과 같은 모양으로 시작한다. 그래서 N+1 부터 같은 표를 따른다. #52587 뒤로 main 은 5.2 의 비정상 종료를 이미 이렇게 잇는다. 5.1 의 비정상 종료는 4.4 가 들어가기 전까지 N+2 에서 turn counter 불일치로 실패한다.

### 5.3 N..N+M: 이어 하는 도중 다시 재기동

- 이어 하기는 작업마다 재기동 한 번에 provider 호출 하나를 잃는다. 끊긴 호출 하나다.
- 다음 재기동은 그때의 `call.checkpoint` 에서 잇는다. 그 사이 체크포인트가 나아갔으면 그 뒤에서, 그대로면 같은 자리에서 잇는다.
- 재기동이 몇 번 이어져도 같은 규칙이다. 횟수로 끝내지 않는다(4.6).
- 기동 정리가 다시 넣은 작업이 claim 되기 전에 또 재기동해도 같다. 행은 `queued`, 호출은 `Active` 로 남고, 다음 기동의 집합이 그 호출을 담는다(4.7).
- 5.1 의 경로는 이어 하기 한 번에 native 호출 기록과 실행 디렉터리가 하나씩 는다. 상한은 없다. 그 작업이 도는 중에 맞은 재기동 수만큼 는다.

### 5.4 Keeper 여럿

- Owner 마다 따로 판정한다. Keeper 사이에 순서가 없다.
- 기동 직후 이어 하는 작업들이 한꺼번에 provider 를 부른다. 11-16 14:01 재기동이면 9건이다. 레인의 속도 제한 처리가 지금처럼 받는다.
- 다시 큐에 든 작업은 그 Keeper 의 큐 맨 뒤로 간다(#52408). 기동 전에 이미 기다리던 작업이 먼저 돈다. 먼저 도는 작업이 canonical 기록을 바꿔도, 4.4 의 새 호출이 여는 자리는 retained 체크포인트라 영향을 받지 않는다. 이어 한 작업이 그 뒤 canonical 에 저장할 때의 일은 §10 에 둔다(#52663).

## 6. runtime 바꿈·문맥 창·계정·위임·전달

- **같은 호출을 잇는 경우(5.2)**: native 호출에 묶인 `runtime_id` 로 잇는다. 문맥 창과 계정이 끊기기 전과 같다.
- **새 호출을 여는 경우(5.1)**: 새 호출도 끊긴 호출에 묶인 `runtime_id` 로 연다(4.4). 문맥 창과 계정이 끊기기 전과 같다. 새 호출은 이력을 줄이는 문맥 준비를 거치지 않고 `call.checkpoint` 를 그대로 seed 로 쓴다. Bind 는 앞 호출에 Tool 시도가 있었을 때만 이 조건을 확인한다(4.4).
- **Official → API → Official**: Agent API 체크포인트를 공식 클라이언트로 옮기는 규칙을 이 RFC 가 새로 만들지 않는다. 체크포인트로 시작하는 새 native 호출이 지금 따르는 규칙을 쓴다.
- **저장된 runtime 이 사라진 경우**: 5.1·5.2 에서 묶인 `runtime_id` 나 모델이 재기동 뒤 설정에 없으면 `Agent.run` 전에 거절된다. 그 claim 은 실패하고, Owner 가 호출을 닫고 작업을 실패로 끝낸다(4.3). 재현하지 않았다. 다른 runtime 으로 새 호출을 열지는 §10 에 둔다.
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
- 이어 한 횟수·시간·진전으로 작업을 끝내지 않는다(4.6).
- 작업마다 이어 한 횟수를 저장하지 않는다. 기동 로그가 관측을 남긴다(4.6).
- 정상 재기동과 비정상 종료를 가르는 저장 상태를 더하지 않는다. 가를지는 L5 에서 정한다(§10).
- 공식 클라이언트 레인의 동작을 바꾸지 않는다(§10).
- native 호출이 묶이기 전에 끊긴 행(3.2 의 「호출 없음, continuation 없음」)은 바꾸지 않는다. 11-16 에 1건이다.

## 8. 시험

agent_core:
- 호스트 멈춤으로 provider 시도 중 취소 → root·턴·시도가 열린 채, terminal 없음, `on_terminal_disposition` 0회.
- 호스트 멈춤으로 Tool 핸들러 중 취소 → attempt 열림, 결과 없음, terminal 없음.
- 멈춤이 `Multiple`·`Finally_raised` 로 감싸여 와도 같다. 멈춤과 운영자 중단이 섞이면 닫힌다.
- 운영자 중단 생성자로 취소 → 지금처럼 `Cancelled` 로 닫힘.
- 열린 attempt·결과 없음으로 `Resume_after_writer_exit` 이어 하기 → 핸들러·gate·hook 0회, attempt 는 `Cancelled`, invocation 에 `Writer_exited_tool_error` 결과, 다음 provider 요청에 그 결과가 실림, 실행은 성공하고 recovery 는 `Retire`.
- 이미 결과가 있는 invocation 을 `Resume_after_writer_exit` 로 이어 하기 → 지금처럼 결과를 다시 쓴다.
- 같은 모양에 열린 하위 실행이 있음 → 하위 실행도 `Cancelled` 로 닫히고 결과가 쓰인다.
- 하위 실행 안에 열린 Tool attempt 가 있음 → transaction 이 거절하고 아무것도 쓰지 않는다.
- 하위 Tool 을 결과 없이 취소로 닫은 뒤 부모를 settle → transaction 이 거절하고 아무것도 쓰지 않으며 부모 attempt 는 열린 채 남는다.
- 하위 Tool 에 결과를 기록하고 하위 실행을 닫은 뒤 부모를 settle → 허용하며 하위 결과를 보존한다.
- terminal Tool 이 끊긴 모양 → 지금처럼 `TerminalToolDurabilityFailed`.
- 이어 하지 않는 실행(fresh)에서 같은 처리가 일어나지 않는다.
- 결과 없이 `Cancelled` 로 닫힌 invocation 으로 이어 하기 → 지금과 같음.
- `Resume_writer_exit_unproven` 으로 이어 하는 실행이 열린 attempt·결과 없음을 만남 → 지금처럼 `Effect_outcome_unknown` 으로 실패, 결과를 쓰지 않음.
- 멈춘 실행 뒤 runner 의 terminal 전달 0회, writer 는 terminal 없이 닫히고 잠금이 풀림.

masc:
- Agent API 레인, provider 호출 중 정상 재기동 → 작업 `running`, 입력 남음. 다음 기동 → 새 호출 1회, 작업 `succeeded`.
- 위 경우를 작업의 **첫** provider 호출에서 → 같은 결과. canonical 에 입력이 없어도 retained seed 에서 연다.
- native 진행 뒤 canonical 저장 전에 끊김 → 같은 결과.
- `Succeeded` terminal 이 기록에 있는 `Active` 호출 → 다시 돌리지 않는다(지금처럼 실패 정리).
- claim 이 처음 본 호출이 이미 `Terminal_unacknowledged(Retire)` → 새 호출을 열지 않는다.
- retire 가 `Retired` → 앞 호출은 `Terminal_unacknowledged(Retire)`, 새 호출이 묶이고 새 seed 는 앞 호출의 `call.checkpoint` 이력을 그대로 가진다. runtime 은 앞 호출과 같다.
- 앞 호출에 Tool 시도가 없던 경우(첫 provider 호출에서 끊김)도 새 seed 를 `call.checkpoint` 와 대조한다. Bind 는 이 경우 이력을 보지 않는다.
- retire 가 오류를 냈고 다시 읽은 기록에 terminal 이 있음 → 그 disposition 이 호출의 terminal 이 되고 새 호출이 묶인다.
- retire 가 오류를 냈고 terminal 이 없음 → claim 실패, 호출은 「효과 모름」 영수증, 작업 `failed`. 그 Keeper 의 다음 작업이 돈다.
- retire 가 `Not_uncollected` → 같은 호출을 이어 한다.
- writer 종료가 증명되지 않은 호출 → retire 를 부르지 않는다.
- Agent API 레인, Tool 실행 중 정상 재기동 → 다음 기동 → Tool 핸들러 다시 실행 0회, 모델이 「결과 모름」을 받음, 작업 `succeeded`.
- 같은 경우들을 비정상 종료로 → 결과가 위 시험과 같다. 이 RFC 의 핵심 시험이다.
- 연속 재기동 둘, 그 사이 체크포인트가 그대로 → 두 번째 기동도 이어 한다.
- 기동 정리가 다시 넣은 작업이 claim 전에 다시 재기동 → 다음 기동의 첫 claim 도 `Resume_after_writer_exit`.
- claim 이 기동 정리보다 먼저 묶은 호출 → 기동 정리 뒤에도 `Resume_writer_exit_unproven`.
- 같은 Keeper 의 다른 작업이 먼저 돌아 canonical 을 바꾼 뒤 → 이어 하는 작업은 retained 체크포인트에서 연다. 이어 한 작업이 끝난 뒤 canonical 이 담는 턴은 §10 의 결정 뒤에 고정한다.
- 멈춤과 운영자 중단이 두 순서로 → `Turn_cancelled`.
- 멈춘 Owner → 새 자식 0개, `Bind` 거절. 같은 Keeper 에 새 Owner 를 만들면 기동 정리부터 돈다.
- 4.4 의 retire 전, retire 와 호출 terminal 사이, 호출 terminal 과 Bind 사이, Bind 뒤에 죽음을 주입 → 다음 기동이 4.4 표대로 판정한다. 둘째·셋째는 `Interrupted_by_restart` 이고 끝난 일은 다시 돌지 않는다.
- retire 뒤 Bind 전에 준비가 실패 → 작업 `failed`. 다음 후보로 넘어가거나 미루지 않는다.
- 기동 정리가 다시 넣은 호출의 첫 claim → `Resume_after_writer_exit`. Bind 뒤 같은 호출을 다시 열면 → `Resume_writer_exit_unproven`. 이 이미지가 4.4 로 묶은 새 호출도 같다.
- 같은 이미지에서 pool 을 다시 설치 → Owner 는 `Prior_writers_unproven`, claim 은 `Resume_writer_exit_unproven`.
- 다시 큐에 든 작업(`queued`, 호출 `Active`)을 운영자가 취소 → 호출은 「효과 모름」 영수증, 작업 `cancelled`, 그 작업의 claim 0회.
- 서버를 죽이는 Tool 을 모델이 되풀이해 부르는 작업 → 기동마다 이어 한다. 운영자가 취소한 뒤의 기동은 잇지 않는다.
- 일시 정지한 Keeper 를 재기동 → 작업을 집지 않는다. 큐에 든 작업을 취소하면 `cancelled` 로 끝난다.
- 기동 정리가 기록을 읽지 못한 호출 → 호출은 「효과 모름」 영수증, 작업은 `Interrupted_by_restart`. 다시 큐에 넣지 않는다. 그 Keeper 의 다음 작업이 돈다.
- 기동 정리가 다시 넣은 작업의 claim 이 물려받은 호출을 묶지 못하고 실패 → 호출은 「효과 모름」 영수증, 작업은 claim 이 돌려준 실패 종류로 `failed`. 그 Keeper 의 다음 작업이 돈다.
- 자식이 호출을 Bind 한 뒤 실패를 돌려줌, Owner 는 멈추지 않음 → 같은 결과.
- 멈추는 Owner 에서 자식이 끝남 → 호출 `Active`, 행 `running`.
- 기동 정리 로그에 다시 넣은 작업 id, 실패로 정리한 작업 id, 읽지 못한 호출 수가 남는다.
- 작업 저장소의 스키마 판은 v3 그대로다.
- 공식 클라이언트 레인 정상 재기동 → 지금과 같다.
- transcript: 작업마다 최종 행 하나, 재기동 때 실패 행 없음. 5.2 로 이어 한 뒤 Tool 행이 빠짐없이 남는다.

## 9. 단계

| 층 | 내용 | 앞 층 | 바뀌는 운영 동작 |
|---|---|---|---|
| L0 | 이 RFC, #52359 에 결정 기록 | — | 없음 |
| L1 | agent_core `retire_uncollected_turn` (#52359 L1, #52473) | — | 없음. 부르는 곳이 없다 |
| L2 | agent_core: 호스트 멈춤은 기록을 닫지 않는다(4.2, #52550) | — | 없음. masc 가 함수를 넘기기 전이다 |
| L3 | agent_core: 끊긴 Tool 을 typed 결과로(4.5). 실패 종류 #52565, resume 원인 #52567, journal transaction #52568, 연결 #52570 | — | 없음. masc 는 `Resume_writer_exit_unproven` 만 넘긴다 |
| L4.1 | masc: 끝난 이미지가 쓴 호출의 첫 claim 에 `Resume_after_writer_exit`(4.7, #52587) | L3 | 비정상 종료 뒤 Tool 이 끊긴 작업이 `Durability_failure` 대신 「결과 모름」으로 이어진다 |
| L4.2 | masc 기동: 집합에 기동 정리 뒤 남은 `Active` 호출을 모두 넣는다(4.7). 다시 큐에 든 작업의 취소를 받는다. 큐 취소 transaction 이 `Active` 호출을 닫는다(4.6). 기록을 읽지 못한 호출을 실패로 끝낸다(4.8). 기동 관측(4.6) | L4.1 | 연속 재기동 뒤에도 이어 하기가 실패하지 않는다. 운영자가 다시 큐에 든 작업을 취소할 수 있다. 기록을 읽지 못한 작업이 Keeper 의 큐를 막지 않는다 |
| L4.3 | masc Owner: 자식이 `Active` 호출을 둔 채 실패하면 닫는다(4.3). masc claim: retire 뒤 retained 체크포인트에서 새 호출(4.4). #52359 L2 다 | L1·L4.2 | 실패한 턴이 그 Keeper 의 큐를 다음 기동까지 막지 않는다. 비정상 종료 뒤 모으기 전에 끊긴 작업이 turn counter 불일치 대신 이어진다 |
| L5 | masc Owner: 멈출 때 4.2 의 함수를 넘긴다(4.3) | L2·L3·L4.3 | 정상 재기동도 위 두 경로를 탄다 |

- L3 은 운영 동작을 바꾸지 않는다. 「재기동 뒤」 근거(4.7)가 L4 에 생기므로, `Resume_after_writer_exit` 를 넘기는 일도 L4 다.
- L4.2 가 L4.3 보다 먼저다. L4.3 과 L5 는 이어 하는 작업을 늘린다. 그 전에 운영자가 다시 큐에 든 작업을 취소할 수 있어야 하고, 연속 재기동이 이어 하기를 실패로 바꾸지 않아야 한다.
  - #52587 병합 뒤 main 은 5.2 경로를 이미 잇는다. 서버를 죽인 Tool 을 모델이 다시 부르는 작업은 지금 도는 중의 운영자 중단으로만 멈춘다(4.6).
- L4.1 과 L4.3 은 비정상 종료 경로만 바꾼다. 지금 실패로 끝나는 작업을 잇는 쪽이다. L4.2 는 큐 취소(4.6)도 바꾸고, 지금 다시 큐에 넣는 읽지 못한 기록을 실패로 끝낸다(4.8).
- L5 가 마지막이다. L5 를 L4.3 보다 먼저 넣으면 끊긴 provider 호출이 turn counter 불일치로 실패한다. 실패 종류만 바뀌고 일은 여전히 사라진다. 비정상 종료 뒤에도 이을지는 L5 에서 다시 정한다(§10).
- 층마다 거짓이 되는 문서·주석을 같은 층에서 고친다.
  - L2: `agent.mli:350-363`.
  - L3: `Agent.execution_store` 문서.
  - L4.2: `keeper_direct_native_continuation.ml:349-350` 주석. 미룬 작업이 같은 프로세스에서 호출을 잇는다고 적는데, 미루기는 `Active` 호출을 둔 채 못 한다(4.5).
  - L4.3: `packages/agent_core/lib/agent/agent.mli:353` 과 `agent_uncollected_turn.ml:24`. 닫는 때를 「restart settlement」라고 적는다. masc 에서 그 말은 기동 정리를 가리킨다.
  - L4.3: `keeper_owner.ml` 의 `active_native_call_policy` 주석. 불러온 호출을 열지 못하면(「a resumed call failed to load」) 호출을 남긴다고 적는다. #52359 §4.2 의 5 와 §10 의 둘째 항목, `a-keeper-takes-every-waiting-message-in-one-turn` 4.1 의 1 도 같은 동작을 적는다.
  - L5: `keeper_owner_registry.ml:426-434`, `keeper_owner.ml:951-956`·1862-1868.

## 10. 정할 것

- **공식 클라이언트 레인**. 같은 CLI 세션을 다시 열어 잇는 방법이 후보다.
  - CLI 마다 SIGKILL 뒤 세션을 다시 열었을 때 끊긴 Tool 호출이 모델에게 어떻게 보이는지 먼저 잰다.
  - 비정상 종료 뒤 `Process_restarted` 가 `Ambiguous` 로 남는 동작도 같이 정한다. 세션 저장소 주석은 이런 상태가 그 Keeper 의 다음 턴을 모두 막았다고 적는다(`keeper_official_client_session_store.ml:54-59`, #28012).
  - 이 RFC 와 따로 쓴다.
- **저장된 runtime·계정이 재기동 뒤 없는 경우**(6). #52359 §10 둘째 항목과 같다. 재현한 뒤, 4.4 처럼 호출을 닫고 다른 runtime 으로 새 호출을 열지 정한다.
- **retire 와 Bind 사이에 claim 이 끝나는 경우**. 판정은 4.4 의 표다. 다음 기동은 작업을 `Interrupted_by_restart` 로 끝낸다. 호출이 `Active` 면 기록의 terminal 을 읽어서, `Terminal_unacknowledged` 면 호출의 영수증으로 판정한다(#52359 §5). terminal 증거에 retire 원인을 남기면(#52359 §10 첫 항목) 두 구간도 이어 할 수 있다. 좁은 구간이라 이 RFC 는 지금 경로를 두고, 시험(§8)으로 판정을 고정한다.
- **새 호출을 묶인 runtime 으로 여는 준비 경로**(4.4). 준비가 복원한 호출의 runtime 으로 새 호출을 여는 코드는 읽지 않았다. L4.3 에서 확인한다. 새 호출의 첫 provider 시도가 실패한 뒤의 두 길도 그때 정하고 시험으로 고정한다.
  - 미뤄지는 길: 어느 continuation 으로 이어 하는지.
  - 같은 claim 에서 다음 후보로 넘어가는 길: claim 은 `Retire` 로 닫힌 새 호출을 「이어 할 호출 없음」으로 읽는다(`keeper_turn_driver.ml:2689-2694`). 다음 후보의 준비는 그 턴의 체크포인트와 입력으로 또 새 호출을 연다(`keeper_direct_native_continuation.ml:308-316`). Bind 는 방금 닫힌 새 호출만 대조한다. 그 호출에는 Tool 시도가 없어서 이력을 보지 않는다(`:404-407`). 끊긴 호출이 settle 한 결과가 retained 체크포인트에만 있으면 다음 후보의 seed 에서 빠질 수 있다. 다음 후보가 실제로 받는 seed 는 읽지 않았다.
- **이어 한 작업이 canonical 에 저장할 때**(#52663). 다시 큐에 든 작업은 큐 맨 뒤로 간다(5.4). 먼저 돈 작업이 canonical 을 앞으로 옮긴 뒤에, 이어 한 작업이 retained 계보의 체크포인트를 canonical 에 저장한다(`keeper_direct_native_continuation.ml:472-474`, `keeper_agent_run.ml:1371-1413`).
  - canonical 저장은 `turn_count` 만 견준다. 들어온 값이 작으면 저장하지 않고 경고만 남긴다(`keeper_checkpoint_store_save.ml:95-107`). sink 는 이 결과를 성공으로 넘긴다(`keeper_agent_run.ml:1451-1458`). 작지 않으면 head 를 통째로 바꾼다. 앞 head 를 잇는 계보인지는 보지 않는다(`keeper_checkpoint_store_save.ml:108-140`).
  - 그래서 이어 한 작업의 턴이 canonical 에 닿지 않거나, 먼저 돈 작업의 턴이 canonical 에서 빠질 수 있다. #52587 뒤로 main 의 5.2 경로도 같다.
  - 코드로 읽은 흐름이고 재현하지 않았다. 작업 사이에서 `turn_count` 가 어떻게 움직이는지와, 입력 체크포인트 쪽 검증이 이 저장을 먼저 막는지는 읽지 않았다. 재현한 뒤 정한다.
- **비정상 종료 뒤에도 이을지**. 이 RFC 는 정상 재기동과 비정상 종료를 같게 잇는다(운영자 결정, 2026-11-16). 4.6 의 남는 위험 때문에 L5 에서 다시 정한다.
  - 같게 잇는 쪽: 코드가 더 들지 않는다. 서버를 죽이는 작업은 운영자 취소로만 멈춘다.
  - 비정상 종료 뒤에는 실패로 끝내는 쪽: 돌던 작업이 프로세스를 직접 죽이는 고리가 한 번에 끝난다. 정상 종료로 생기는 고리(4.6)는 남는다. 멈춘 원인을 typed 로 남기는 저장 상태가 필요하다. 지금 `Child_stopped_by_owner` 는 일반 취소도 담고(`keeper_owner.ml:1915-1921`), 기동 정리 실패도 Owner 를 멈춘다(`keeper_owner_registry.ml:274-277`).
  - 판단에 쓸 값: 기동 관측(4.6)에서 비정상 종료 뒤 이어 한 작업의 수와 끝 상태.
- **실패로 끝난 작업의 입력**. 이어 하지 못해 실패한 작업은 지금처럼 입력이 지워진다(3.1 의 8). 입력을 남기려면 끝난 행의 `input_json IS NULL` 제약(`keeper_chat_operation_store.ml:121`)과 묶음 구성원 정리(`:3429-3438`)를 함께 바꿔야 한다. 이 RFC 는 다루지 않는다.
- **「결과 모름」 문구에 자식 프로세스 상태를 적을지**. 정상 재기동은 자식을 SIGKILL 로 끝낸다(3.1 의 4). 비정상 종료 뒤 자식이 남는지는 확인하지 않았다.
- **하위 실행 안에서 끊긴 Tool**. 4.5 는 지금 거절한다. 끊긴 하위 invocation 마다 같은 「결과 모름」 결과를 적으면 이어 할 수 있다. 하위 Tool 의 `provider_tool_use_id` 가 없을 수 있고, 하위 terminal Tool 도 다뤄야 한다. Tool 핸들러 안에서 하위 실행을 여는 호출처가 생기면 정한다.
- **retained 체크포인트를 canonical 로 먼저 설치하는 방법**. 4.4 대신 `call.checkpoint` 를 canonical 로 설치하고 기존 loader 를 쓰는 길도 있다. canonical 저장은 turn 번호가 엄격히 작을 때만 낡은 것으로 막는다(`keeper_checkpoint_store_save.ml:95`). 이 길은 먼저 돈 다른 작업이 canonical 을 앞으로 옮긴 경우(5.4)에 막히므로 4.4 를 고른다.
