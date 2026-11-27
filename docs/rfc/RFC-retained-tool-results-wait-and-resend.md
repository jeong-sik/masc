---
rfc: "retained-tool-results-wait-and-resend"
title: "Retained tool results: read the outbox once per turn entry, and stop resending results a resumed session already holds"
status: Draft
created: 2026-11-26
updated: 2026-11-26
author: claude-main
related: ["tool-results-age-out-of-context", "uncollected-provider-turn-is-not-resumed"]
---

# RFC: 턴 시작은 남은 도구 결과를 한 번만 읽고, 이어 쓰는 세션에는 이미 받은 결과를 다시 싣지 않는다

- 관련: #54930(대시보드가 대기 행을 종류별로 묶음)
- 결정(운영자, 2026-11-26): 두 문제를 한 RFC 에 담는다. 턴 시작 읽기(5.1)는 RFC 뒤 바로 구현하고, 재전송(5.2·5.3)은 이 RFC 의 측정을 채운 뒤 구현한다.
- 범위:
  - 턴 시작 때 쓴 `Tool_result_ready` 행을 지우는 자리(`keeper_heartbeat_stimulus_intake.ml`).
  - ACP 실행이 남은 결과 묶음(carrier)을 요청에 붙이는 자리(`keeper_acp_runtime.ml`).
  - host receipt 파일 형식(어느 세션에서 보냈는지).
- 건드리지 않는다: receipt 를 정리(acknowledge)하는 규칙(`Completed` 만 정리), queue 행을 receipt 마다 하나 두는 구조, 소유된 receipt 경로(`Keeper_receipt_wait_resolution`).

## 1. 사건

2026-11-26 18:56(KST)에 대시보드가 Keeper `code-reviewer` 의 대기 항목을 133건으로 보여 줬다.
그중 123건이 `tool_result_ready` 였고, 모두 「이전 실행 결과 회수」 행이었다.

기록으로 다시 센 흐름이다(`turns.jsonl`, `official-client-runtime/consumed-tool-results/` 의 파일 시각).

| 시각 | 일 | 정리된 receipt |
|---|---|---|
| 18:02~18:11 | 턴이 `cancelled` 로 끝남 | 0 |
| 18:16~18:26 | 턴 `completed` | 77 |
| 18:26~18:49 | 리뷰 중 위임 답을 기다리려 `keeper_receipt_wait` 를 부르고 넘김(`agent yielded … elapsed_s=1339`) | 0 |
| 18:50~19:00 | 위임 답 도착으로 깨어난 턴 `completed` | 134 |
| 19:02 | 다음 턴 시작, 남은 행을 한 줄씩 지움 | — |

- receipt 는 새지 않았다. 오늘까지 정리된 것이 6,896건이다. 이 RFC 를 쓰는 동안(20:18) queue 의 `tool_result_ready` 행은 0건이다.
- 같은 날 서버 로그에 「turn entry: retired inactive tool result hint」 가 434줄 있다(`system_log_2026-11-26.jsonl`).
- 18:50 턴의 첫 요청에 남은 결과 묶음이 440,734 바이트 텍스트로 실렸다(`raw-traces/turn-1795686652699-4448-000059.jsonl` 0번 줄). 19:00 에 정리된 134건의 receipt 파일은 합쳐 488,361 바이트다.

## 2. 왜 문제인가

- **턴 시작이 N² 에 가깝게 읽는다.** 남은 행 하나를 지울 때마다 Keeper meta 와 outbox 전체를 다시 읽고, queue 를 따로 저장한다. 123행이면 outbox 를 최대 123번 읽는다.
- **이미 받은 결과를 다시 보낸다.** 이어 쓰는(resume) 세션도 남은 결과 묶음 전체를 요청에 붙인다. 그 세션이 같은 턴에서 직접 받은 host 결과까지 포함한다. 비용을 재지 못한다. Kimi ACP 는 요청마다 usage 를 보내지 않는다(`context_ratio = null`).
- **세션이 왜 바뀌었는지 남지 않는다.** resume 이 지원되지 않거나 실패하면 새 세션을 열고 아무 기록도 남기지 않는다. 그래서 2번의 비용이 얼마나 자주 생기는지 셀 수 없다.

## 3. 지금 일어나는 일

### 3.1 receipt 하나의 일생

1. ACP host 가 도구를 실행하고 결과를 vendor 에 돌려준다. 같은 결과를 receipt 파일로 남긴다(`retain_host_result_with_delivery`, `keeper_client_tool_outbox.mli:71-77`). 실행 중인 턴의 receipt 는 producer lease 가 잡혀 있어서 다른 읽기가 건너뛴다(`mli:59-68`).
2. 턴이 `Completed` 로 끝나야 그 턴이 읽은 receipt 를 정리한다(`settle_after_turn`, `mli:370-374`). checkpoint, 넘김(yield), 입력 대기, 취소, 실패는 남긴다.
3. 남은 receipt 는 다음 실행이 전부 읽는다(`load ~viewer:Unowned_only`). 그리고 한 개의 System 메시지로 모델에 싣는다(`developer_context`, `keeper_client_tool_outbox.ml:518-531`).

### 3.2 queue 의 행은 outbox 의 사본이다

- `notify` 는 남은 receipt 마다 queue 행을 하나 넣는다. 이 행의 `post_id` 는 `keeper-tool-result:<receipt_id>` 다(`keeper_client_tool_outbox_wake.ml:45-75`).
- maintenance 가 60초마다 `reconcile → notify` 를 다시 돈다(`server_bootstrap_maintenance.ml:14`). 그래서 잃어버린 행은 outbox 에서 다시 만들어진다.
- 턴은 받아들이는 행 수에 상한이 있다(`remaining`, `keeper_heartbeat_stimulus_intake.ml:1006-1015`). `Completed` 턴은 자기가 받아들인 행만 정리한다. outbox 는 전부 정리했어도 나머지 행은 남는다.
- 다음 턴 시작 때 남은 행을 `reconcile_spent_selection` 이 한 줄씩 본다(`:600-627`). 그때마다 outbox 를 읽고, receipt 가 없으면 그 행 하나를 따로 저장해 지운다(`:1050-1052`).

### 3.3 resume 도 묶음을 다시 싣는다

- `is_resume` 은 직전 settlement 가 있고 계획된 rollover 가 아닐 때 참이다(`keeper_acp_runtime.ml:2222-2231`).
- resume 이어도 남은 결과 묶음을 요청 끝에 붙인다(`:2304`, `:2311`, `:2323`).
- host receipt 파일에는 어느 vendor 세션에 보냈는지가 없다. 필드는 `arguments, call_id, host_invocation_index, host_producer_id, host_turn_count, response, runtime_label, tool_name` 이다.
- resume 이 `Unsupported` 거나 `Failed` 면 새 세션을 연다(`:2777-2790`, `:2807-2814`). 이 갈래에는 로그가 없다. 코드에 있는 새 세션 로그 네 가지(「did not settle against current canonical history」, 「reached the rollover threshold」, 「typed context overflow」, 「ACP start range passed max context」)는 오늘 `code-reviewer` 에 0건이다.
- Kimi ACP 로 바꾼 뒤 `code-reviewer` 의 ACP client 턴은 14번이고, 세션은 5개였다. 세션 하나가 1·1·3·4·5턴을 이었다(`client-turns.jsonl`). 표본이 작다.
- 지금 진행 중인 턴도 직전 settlement(`session_f4999…:3`)가 있는데 새 세션(`session_0efd9b99…`)을 열었다(`session.json`).

## 4. 토론한 대안

두 검토자가 같은 코드를 따로 읽었다. 한쪽은 구조를 새로 설계했고, 다른 쪽은 그 설계를 깨뜨리려 했다.

| 안 | 내용 | 결론 |
|---|---|---|
| A | 지금처럼 receipt 마다 행 하나 | 유지. 5.1 로 정리 비용만 고친다 |
| B | Keeper 마다 행 하나(receipt id 없음) | 탈락 |
| C | queue 행 없이 outbox 만 보고 깨운다 | 탈락 |
| D | 넘긴 턴에서도 vendor 에 보낸 host 결과를 정리한다 | 탈락. 5.2 로 바꿔 받는다 |

- **B 가 깨지는 곳.** 행이 이미 있으면 새 receipt 는 「이미 있음」으로 무시된다(`keeper_registry_event_queue.ml:488-496`).
  - 턴 도중 들어온 결과가 모델의 「Arrived While This Turn Ran」 목록에 안 나온다(`keeper_arrived_stimuli.ml:73-74`, `:157-160`).
  - 턴이 끝난 뒤에도 그 결과로 바로 깨어나지 않고 다음 maintenance(최대 60초)를 기다린다.
  - 「receipt 묶음 digest」를 id 로 쓰면 결과마다 행이 다시 생겨서 A 로 돌아간다.
  - queue 저장 형식(v19), 멈춘 작업 처리 기록(v7), 턴 기록 codec 이 함께 바뀐다.
- **C 가 깨지는 곳.** 쉬고 있는 Keeper 를 깨우는 턴 이유가 이 행에서 나온다(`Tool_result_ready_stimulus → Tool_result_ready_pending`). 종료 중 보류(`Stimulus_shutdown_reserved`)와 다른 일과의 순서 조정도 이 행에 기댄다. 모두 새로 만들어야 한다.
- **D 가 깨지는 곳.** vendor 세션을 기억의 원본으로 삼는다. MASC 는 그 세션을 갖고 있지 않다. 3.3 대로 세션이 자주 바뀌고, 바뀐 세션은 MASC 가 다시 싣는 것만 안다. 정리하면 결과를 잃는다.

## 5. 제안

### 5.1 턴 시작 때 outbox 를 한 번만 읽는다

- 턴 시작은 meta 와 unowned outbox 를 한 번 읽고, 그 결과로 모든 `Tool_result_ready` 행을 본다. 지금은 행마다 둘을 다시 읽는다.
- 순서가 이 읽기를 안전하게 만든다. 행은 receipt 를 남긴 뒤에 들어가고(`notify`), 턴 시작은 행 목록을 읽은 뒤에 outbox 를 읽는다. 그래서 각 행의 receipt 는 「남아 있음」 아니면 「이미 정리됨」이다. 읽은 뒤에 정리된 receipt 는 남은 것으로 보이고, 그 행은 턴에 들어갔다가 다음 턴 시작에 지워진다.
- receipt 가 없는 행은 지금처럼 행마다 하나씩 queue 에 저장해 지운다. queue 는 transition 기록 칸이 하나뿐이라(`keeper_registry_event_queue.ml` 의 single-slot transition outbox), 여러 행을 한 번에 지우려면 queue 저장 형식을 바꿔야 한다. 이 RFC 는 그것을 하지 않는다.
- 행 구조, receipt id, 깨우기 규칙, 저장 형식은 그대로다.

확인: 같은 읽기를 쓰는 동안 receipt 를 정리하면 그 행이 지워지지 않고, 새 읽기는 그 행을 지우는지 시험한다. 이것이 「한 번 읽어 같이 쓴다」를 보여 준다.

### 5.2 resume 하는 세션에는 그 세션이 받은 host 결과를 싣지 않는다

- host receipt 에 결과를 보낸 vendor 세션 id 를 함께 남긴다. `mark_response_sent` 가 지금은 메모리만 바꾸는데, 이 사실을 receipt 파일에 적는다.
- resume 할 때는 「이 세션에 이미 보낸 host receipt」를 묶음에서 뺀다. 새 세션을 열 때는 지금처럼 전부 싣는다.
- receipt 정리 규칙은 그대로다. 빼는 것은 싣는 일뿐이라 결과를 잃지 않는다. 세션이 바뀌면 다시 실린다.
- receipt 파일 형식이 바뀐다. 보낸 세션은 닫힌 variant 로 둔다: 「보내기 전에 남김」(retain 뒤 응답을 쓰기 전에 멈춘 경우) 또는 「이 세션에 보냄」. 앞의 것은 언제나 싣는다.

확인: 같은 세션을 resume 하는 실행의 묶음에 그 세션의 host receipt 가 없고, 새 세션 실행에는 있는지 시험한다.

### 5.3 새 세션을 연 이유를 남긴다

- resume 이 `Unsupported`·`Failed` 로 새 세션을 열 때, 그 이유를 세션 저장소 기록과 로그에 남긴다. 이유는 문자열이 아니라 닫힌 variant 로 둔다(지원 안 함 / resume 거절 / load 거절 / child 재시작).
- 이것은 고침이 아니라 5.2 의 효과를 재는 근거다. 이 기록으로 「새 세션 비율」과 「새 세션마다 실린 묶음 바이트」를 하루 단위로 센다. 그 수가 크면 세션이 바뀌는 원인을 별도 RFC 로 다룬다.

확인: resume 실패를 흉내 낸 시험에서 이유가 세션 기록에 남는지 본다.

## 6. 측정 계획

구현 전후로 같은 Keeper(`code-reviewer`)에서 하루씩 잰다.

| 값 | 원본 |
|---|---|
| 「retired inactive tool result hint」 줄 수 | `system_log_*.jsonl` |
| resume / 새 세션 수와 새 세션 이유 | 5.3 의 기록 |
| 요청마다 실린 묶음 바이트 | `raw-traces/*.jsonl` 의 `MASC dynamic-tool receipts retained` 텍스트 |

## 7. 열린 질문

- Kimi ACP 가 `initialize` 에서 `loadSession`·resume 을 지원한다고 알리는지 아직 보지 못했다(확인 필요). f4999 세션이 3턴 동안 이어졌으니 resume 은 적어도 가끔 된다.
- 5.2 의 형식 변경을 hard cut 으로 할지 정해야 한다. 업그레이드 때 남아 있는 receipt 는 읽히지 않는 결과가 된다. 업그레이드 전 「남은 receipt 0건」을 확인하는 절차로 갈지, migration 으로 갈지 운영자가 정한다.
- 넘긴 턴(yield)이 receipt 를 남기는 규칙은 바꾸지 않는다. 5.2 가 들어간 뒤에도 넘긴 턴이 많아 묶음이 크게 남으면, 그때 다시 다룬다.
