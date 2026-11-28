---
rfc: "agui-1-0-conformance"
title: "Keeper 대화 스트림을 AG-UI 1.0 에 맞추고 외부 AG-UI 클라이언트가 붙는 길을 연다"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: claude
related: []
---

# Keeper 대화 스트림을 AG-UI 1.0 에 맞추고 외부 AG-UI 클라이언트가 붙는 길을 연다

- 상태: 초안.
- 계기: 2026-11-28 운영자가 CopilotKit 같은 외부 AG-UI 클라이언트도 masc Keeper 와 대화할 수 있게 하기로 정했다.
- 먼저 있는 결정:
  - 네이티브 앱 RFC(#55393, 스택 #55396)는 AG-UI frame 을 `lib/keeper_chat_wire/keeper_chat_wire.atd` 하나에 적는다. 서버와 Swift·Kotlin 이 그 파일에서 만든 타입으로 쓰고 읽는다. 이 RFC 는 그 스택이 main 에 들어간 뒤 구현한다.
  - 그 RFC 의 열린 질문 Q5(AG-UI 1.0 과 얼마나 맞출지)를 이 RFC 가 이어받는다.
- 출처:
  - AG-UI 1.0 문서 `docs.ag-ui.com/spec/1.0/*`. 2026-11-28 에 읽었다. 아래에서 `lifecycle.md` 처럼 파일 이름만 쓰면 이 문서의 page 다.
  - 1.0 strict JSON Schema `https://ag-ui.com/spec/1.0/schema.json`. 2026-11-28 에 받았다. 92 KB, sha256 `4b5c93226838a0e72d88e6c5df20633c686c49fcb75d9be2815c6cbf9e48e71a`, JSON Schema draft 2020-12.
- 코드 좌표: main `65737a88b03e` 와 스택 #55396 의 맨 위 `e2c3ba60`. 스택에만 있는 파일은 그렇다고 적는다.

## 읽기 전에 — 말의 뜻

- 1.0 클라이언트: AG-UI 1.0 규격대로 이벤트를 읽는 클라이언트다. 공식 TypeScript SDK `@ag-ui/client` 를 쓰는 CopilotKit 이 예다.
- masc 클라이언트: Dashboard, TUI, 네이티브 앱이다. masc 가 직접 만든다.
- masc 확장: 1.0 에 없는데 masc 클라이언트가 쓰는 필드와 이벤트다.
- run: 1.0 의 실행 단위다. `RUN_STARTED` 로 열고 `RUN_FINISHED` 나 `RUN_ERROR` 로 닫는다.
- operation: masc 가 받은 대화 요청 하나다. id 는 요청의 `request_id` 다. 큐에서 기다리다 턴으로 실행된다.
- 턴: operation 을 한 번 실행하는 구간이다. continuation 이 있으면 operation 하나가 턴 여럿으로 실행된다.
- journal: operation 마다 쓰는 내부 이벤트 기록(`keeper_chat_event_log`)이다. AG-UI frame 이 아니다. wire frame 은 journal 을 projection 해서 만든다.

## 0. 요약

- 지금 masc frame 은 1.0 클라이언트와 맞지 않는다. fixture 21개 중 20개가 1.0 스키마에서 거절된다. 통과한 1개도 timestamp 단위가 달라 날짜가 틀리게 읽힌다(§1.1).
- run 의 단위를 operation 으로 정한다. 턴의 시작과 끝은 `masc.` CUSTOM 으로 보낸다(D2).
- 바꾸는 것:
  - timestamp 를 정수 ms 로 쓴다.
  - masc 확장 필드를 이벤트의 `metadata.masc` 로 옮긴다.
  - message·tool call 의 id 를 서버가 만든다.
  - CUSTOM 이름 앞에 `masc.` 를 붙인다.
  - 응답을 `RUN_STARTED` 로 시작하고, operation 이 끝날 때 run 을 닫는다.
  - thinking 글을 `REASONING_*` 이벤트로 보낸다.
- 더하는 것:
  - `RunAgentInput` 을 받는 길. 외부 클라이언트는 이 길로 붙는다.
  - 1.0 스키마 사본으로 서버 출력을 검사하는 시험.
- 그대로 두는 것:
  - 이어 받기(`id: <journal seq>`, `since_seq`). masc 클라이언트가 계속 쓴다.
  - `chat/stream` 요청 본문.
  - journal 의 턴 경계와 `content_generation`.
- wire 는 한 번에 바꾼다. 옛 모양을 읽는 reader 를 두지 않는다. 서버와 masc 클라이언트 셋을 같은 스택에서 바꾼다.

## 1. 지금 동작

### 1.1 스키마 검사 결과

- 입력: 스택 #55396 의 `apps/fixtures/keeper_chat/agui_frames.json`. 서버 encoder 가 쓴 frame 21개다.
- 방법: frame 마다 1.0 스키마의 자기 `type` 정의(`#/$defs/<Type>Event`)와 전체 `Event` 로 검사했다. 검사기는 Python `jsonschema` 4.26.0(`Draft202012Validator`)이다.

| 위반 | frame 수 |
|---|---|
| `timestamp` 가 정수가 아님(`1795821563.25`) | 20 |
| 정의에 없는 필드가 있음 | 20 |
| 필수 `messageId` 없음 | 2 |
| 필수 `toolCallId` 없음 | 1 |
| `TOOL_CALL_ARGS` 에 필수 `delta` 없음 | 1 |

- `Event` 를 통과한 frame 은 1개다. timestamp 가 마침 정수 초 `13` 인 `RUN_FINISHED` 다. 1.0 SDK 는 이 값을 ms 로 읽는다(`schema.json` BaseEvent: "every SDK ... uses milliseconds since the Unix epoch"). 그래서 이 frame 도 날짜가 틀리게 읽힌다.
- 정의에 없는 필드는 다음과 같다.

| 이벤트 | 필드 |
|---|---|
| `TEXT_MESSAGE_*`, `TOOL_CALL_*`, `CUSTOM`, `RUN_ERROR` | `threadId`, `runId` |
| `TEXT_MESSAGE_CONTENT` | `textStreamScope`, `textResponse` |
| `TOOL_CALL_*` | `toolStreamScope`, `providerMessageId`, `toolCallBlockIndex` |
| `TOOL_CALL_ARGS` | `snapshot` |

- `threadId`·`runId` 는 1.0 에서 `RUN_STARTED`·`RUN_FINISHED` 에만 있다. `RUN_ERROR` 에는 둘 다 없다.
- 1.0 클라이언트는 정의에 없는 필드 때문에 run 을 멈추지 않는다. 경고를 남기고 그 필드를 지운다(`processing.md`: "A consumer MUST NOT let a stripped property survive into the value application code receives"). 그래서 위 값은 1.0 클라이언트에게 보이지 않는다.

### 1.2 1.0 규칙과 다른 곳

| 규칙 | 1.0 | masc 지금 | 1.0 클라이언트가 겪는 일 |
|---|---|---|---|
| 시각 | `timestamp` 정수. SDK 는 ms | 초 단위 float. `Time_compat.now ()` | 스키마가 거절한다. 숫자로 받는 SDK 는 1970-01-21 로 읽는다 |
| 확장 자리 | `metadata`. key 로 열려 있고 지우지 않는다. `ag-ui` key 는 예약 | 이벤트 최상위 필드 | 경고와 함께 지운다 |
| 필수 id | `TEXT_MESSAGE_CONTENT`·`END` 의 `messageId`, `TOOL_CALL_*` 의 `toolCallId` | 빠질 수 있다. provider 가 준 id 를 쓴다 | 거절한다 |
| 인자 조각 | `TOOL_CALL_ARGS` 는 `delta` 만 | `delta` 또는 지금까지의 인자 전문 `snapshot` | 거절한다 |
| 스트림 시작 | "A stream MUST begin with RUN_STARTED or RUN_ERROR"(`lifecycle.md`) | `chat/stream` 은 CUSTOM 수락 frame 을 먼저 보낸다(`lib/server/server_routes_http_keeper_stream.ml:3687`). 큐에 든 operation 은 턴이 시작할 때 `RUN_STARTED` 가 온다 | 첫 이벤트부터 규격 밖이다 |
| run 의 끝 | `RUN_FINISHED` 로 닫힌 run 뒤에는 새 `RUN_STARTED` 만 온다(`lifecycle.md`) | 턴마다 `RUN_FINISHED` 를 쓴다. continuation 이 남아도 첫 턴 끝에서 stream 이 닫힌다(§1.4) | 첫 턴의 답만 받는다 |
| CUSTOM 이름 | vendor·application prefix 를 SHOULD 로 붙인다. prefix 없는 이름은 protocol 예약이다. 예시는 `com.example.cart-updated` 하나다(`passthrough.md`) | 30개 모두 prefix 없음 | 지금은 모르는 이름이라 무시한다. 1.0 이 같은 이름을 정하면 겹친다 |
| 이어 받기 | 없다. "SSE's Last-Event-ID mechanism is not used", 클라이언트는 `id:` 를 무시한다(`http-sse.md`) | `chat/stream` 은 `id:` + `since_seq`, `/ag-ui/events` 는 `Last-Event-ID` 재생 | `id:` 를 무시한다. 끊기면 새 run 이다 |
| run 시작 요청 | `POST` + `RunAgentInput`(`threadId`, `runId`, `messages`, `tools`, `context`, `state`, `forwardedProps`, `resume`, `protocolVersion`) | `chat/stream` 자체 본문(`request_id`, `name`, `message`, `admission_intent`, `since_seq` …) | 붙을 길이 없다 |
| 승인 | run 을 `RUN_FINISHED` outcome `interrupt` 로 끝내고, 새 run 의 `resume` 으로 답한다(`interrupt-resume.md`) | 턴이 그 호출에서 멈추고 운영자 답을 기다린다(`lib/keeper/keeper_chat_events.mli:233-246`) | 승인 요청을 모른다. CUSTOM 이라 무시한다 |
| 대화 기록 | `messages` 를 "the complete history" 로 MUST 취급한다(`run-input.md`) | 서버가 기록을 가진다 | D3 이 이 규칙을 따르지 않는다고 적는다 |

- 서버의 `Ag_ui.protocol_version` 은 `"0.1.0"` 이고 부르는 곳이 없다(`lib/ag_ui/ag_ui.ml:187`). `RUN_STARTED` 에는 `protocolVersion` 이 없다.
- `TEXT_MESSAGE_START` 의 role 은 1.0 에서 `developer`·`system`·`assistant`·`user` 다. 서버가 이 frame 에 쓰는 role 은 `User`·`Assistant` 뿐이다(`lib/keeper/keeper_chat_events.mli:27`). 스택의 ATD `role` 에는 `tool` 이 더 있다.
- provider message·call id 는 "may be blank or reused" 다(`lib/keeper/keeper_chat_events.mli:79-81`). 1.0 은 `messageId` 가 thread 안에서 하나뿐이어야 한다고 정한다(`basic/index.md`).

### 1.3 CUSTOM 30개와 1.0 이벤트

이름과 `keeper_chat_events.mli` 주석으로 묶었다. 「1.0 에서 같은 뜻」 칸은 필드와 규칙을 맞대 본 결과다.

| CUSTOM | 하는 일 | 1.0 에서 같은 뜻 | 판정 |
|---|---|---|---|
| `KEEPER_CHAT_OPERATION_ACCEPTED` | operation 을 받았다 | run 의 시작 | `RUN_STARTED.metadata.masc` 로 옮기고 지운다(D2) |
| `KEEPER_THINKING_DELTA` | thinking 글 조각 | `REASONING_MESSAGE_CONTENT`. 앞뒤로 `REASONING_START`·`REASONING_MESSAGE_START`·`_END`·`REASONING_END` | 옮긴다(D2) |
| `KEEPER_THINKING_SNAPSHOT` | 지금까지의 thinking 전문 | 없다. reasoning 에는 snapshot 이 없다 | `masc.` |
| `KEEPER_THINKING_SIGNATURE_DELTA` | 서명 바이트 수(`signature_bytes : int`) | `REASONING_ENCRYPTED_VALUE` 는 값 자체를 싣고, 클라이언트가 다음 run 입력에 그대로 돌려준다 | 다르다. masc 는 서명을 서버에 둔다. `masc.` |
| `KEEPER_TOOL_RESULT_READY` | 결과가 tool-call 저장소에 기록됐다. 내용은 없다 | `TOOL_CALL_RESULT` 는 `content` 가 필수다 | 다르다. Q2 |
| `KEEPER_TOOL_APPROVAL_REQUESTED`·`_SETTLED` | 턴 안에서 운영자 답을 기다린다 | interrupt 는 run 을 끝낸다 | 다르다. Q1 |
| `KEEPER_NATIVE_TOOL_START`·`_END`·`_PROGRESS` | provider 가 직접 도는 도구(검색 등)의 진행 | `ACTIVITY_*`: "structured progress that is not conversation content"(`activity.md`) | 가깝다. Q3 |
| `KEEPER_STREAM_MESSAGE_START`·`_DELTA` | provider 메시지의 model, stop reason, usage | `RUN_FINISHED.usage`·`RUN_ERROR.usage`(`TokenUsage[]`)는 usage 만 받는다 | usage 는 run 끝에도 싣는다. 이벤트는 `masc.` |
| `KEEPER_CONNECTED`, `KEEPER_RUNTIME_ATTEMPT_STARTED`, `KEEPER_PROVIDER_RETRY`, `KEEPER_STREAM_MESSAGE_STOP`, `KEEPER_STREAM_PING`, `KEEPER_CONTENT_BLOCK_START`·`_STOP`, `KEEPER_MODEL_CONTENT_ACTIVITY`, `KEEPER_STREAM_PROTOCOL_ERROR`, `KEEPER_MEDIA_DELTA` | provider 스트림과 runtime 관찰 | 없다 | `masc.` |
| `KEEPER_CHAT_BATCH_BOUND`, `KEEPER_CONTINUATION_CHECKPOINT`, `KEEPER_EXTERNAL_EFFECT_COMPLETED`, `KEEPER_REPLY_DETAILS`, `KEEPER_TOOL_CALL_ADMITTED`, `KEEPER_TOOL_TRANSCRIPT_COMMITTED`, `KEEPER_ATTACHMENT` | masc 대화 operation 과 저장 사실 | 없다 | `masc.` |
| `MASC_EVENT` | `/ag-ui/events` 의 masc 이벤트 | 없다 | `masc.` |

- 마지막 세 묶음은 이벤트마다 뜻을 하나씩 맞대 보지 않았다. 단계 2 에서 이름을 바꿀 때 하나씩 본다.

### 1.4 run, operation, 턴

- operation 하나는 턴 여럿으로 실행될 수 있다. continuation 을 남기면 operation 은 `Running → Queued(Operation_deferred) → Running` 을 거친다. 턴마다 journal 에 `Run_started` 와 `Run_finished` 를 쓰고, runId 는 늘 `keeper-operation-run-<operation>` 이다.
- 턴 경계는 journal 계약이다. `Keeper_chat_event_log.next_sequence` 는 남은 continuation 의 마지막 이벤트가 `Run_finished` 나 `Event_error` 이길 요구한다.
- 턴의 `Run_started` seq 가 응답 식별자 `content_generation` 의 원천이다. 이 값이 `textResponse` 와 thinking 의 `response_generation` 으로 나간다.
- `chat/stream` 은 `RUN_FINISHED`·`RUN_ERROR` 를 쓰면 stream 을 닫는다(`ag_ui_terminal_event`, `server_routes_http_keeper_stream.ml:44`).
- 끝 이벤트:
  - 실패: settle 이 journal 에 `Event_error` 를 쓰고 그 seq 로 `RUN_ERROR` 를 보낸다(`synthesize_wire_terminal_on_settle`, `:3409`). seq 없이 보내면 live 클라이언트와 이어 받는 클라이언트가 어긋난다(같은 곳 주석, #41687).
  - 성공: 마지막 턴의 `Run_finished` 가 끝이다. connector 길은 전달이 끝날 때까지 wire `RUN_FINISHED` 를 잡아 둔다(`:2940`).
  - 큐에서 취소: `cancel_queued` 는 journal 에 쓰지 않는다. 재접속 보정(`missed_terminal`)은 `Failed` 에만 `RUN_ERROR` 를 만든다(`:3605`). heartbeat 가 끝 frame 없이 stream 을 닫는다.
- 묶인 턴: `Keeper_chat_operation_batch.event_for_member` 가 member operation 마다 runId 를 바꿔 각자의 journal 에 쓴다. 지금도 run 은 operation 마다다.
- masc 클라이언트는 `RUN_STARTED` 를 「턴이 시작됐다」로 읽는다. Dashboard `lib/keeper-response-state.ts` 의 `started` 와 TUI `fleet_store.ml` 의 `Chunk_run_started` 처리(text·thinking·대기 도구를 비운다)다.

## 2. 제안

### D1. 1.0 스키마 사본으로 서버 출력을 시험한다

- 사본: `apps/fixtures/agui-1.0/schema.json`. 옆의 `SOURCE` 에 URL, 받은 날, sha256 을 적는다.
- 사본 규칙: 사람만 바꾼다. 바꾸는 PR 은 따르는 upstream 판을 본문에 적는다. 리뷰어는 `curl -sL https://ag-ui.com/spec/1.0/schema.json | shasum -a 256` 로 값을 다시 잰다. masc 가 따를 1.x 새 판이 나오면 다시 받는다.
- 사본 확인: 시험이 사본의 sha256 을 `SOURCE` 값과 비교한다. 이 비교는 실수로 고친 사본을 잡는다. 사본과 값을 같이 고친 변경은 잡지 못하고, 위 리뷰 규칙이 막는다.
- fixture: frame 생성자마다, CUSTOM 이름마다 하나 이상 둔다. fixture 표는 생성자를 받아 fixture 를 돌려주는 빠짐없는 `match` 로 만든다. 생성자를 더하고 fixture 를 더하지 않으면 컴파일이 실패한다.
- 시험은 둘이다.
  - frame 시험: frame 마다 자기 `type` 정의와 `Event` 로 검사한다.
  - 순서 시험: 녹화한 응답이 `lifecycle.md` 를 지키는지 본다. 스키마는 순서를 보지 못하기 때문이다.
    - 첫 이벤트는 `RUN_STARTED` 나 `RUN_ERROR` 다.
    - message·tool call·reasoning 은 열고 닫는다. 열지 않은 id 에 content·end 를 보내지 않는다. 같은 id 를 두 번 열지 않는다.
    - 닫힌 run 뒤에는 `RUN_STARTED` 만 온다. `RUN_FINISHED` 뒤의 늦은 `RUN_ERROR` 는 예외다.
  - 녹화하는 응답: 턴 하나, continuation 으로 턴 둘, 큐에서 취소, 턴 중 provider 재시도, 턴 중 실패.
- 도는 곳: 필수 `type-check`(`dune build --root . @check`)다.
  - fixture 어긋남 규칙(스택의 `apps/fixtures/keeper_chat/dune`)은 지금 `runtest` alias 라 PR 마다 돌지 않는다. 네이티브 생성물 규칙처럼 `check` alias 로 옮긴다.
  - 스키마 검사기는 Q4 다.
- `schema-files.md` 는 strict 스키마를 받는 쪽 검사에 쓰지 말고 작성과 시험에 쓰라고 한다. 이 RFC 는 서버 출력 시험에만 쓴다.

### D2. wire 를 1.0 모양으로 한 번에 바꾼다

#### run 의 단위

- run 은 operation 하나다. 클라이언트가 보낸 요청 하나가 run 하나고, 턴은 그 run 안의 구간이다.
- 이유: 1.0 클라이언트는 `RUN_FINISHED` 에서 run 이 끝났다고 본다. 턴마다 run 을 닫으면 continuation 뒤의 답을 받지 못한다.
- 턴마다 새 runId 로 run 을 여럿 보내는 방법은 쓰지 않는다. 1.0 은 한 응답에 run 여럿을 실을 수 있다고 하지만, 요청한 run 앞에 기록을 재생하는 경우다(`http-sse.md`). 요청한 run 뒤에 오는 run 은 1.0 클라이언트가 기다리지 않는다.

#### 응답 머리

- 응답은 `RUN_STARTED` 로 시작한다. route 가 응답마다 operation 기록으로 만들고, journal 에는 쓰지 않는다. SSE `retry:` frame 처럼 응답의 머리다.
  - runId: `chat/stream` 은 지금의 operation run id 다. D3 길은 클라이언트가 보낸 runId 다.
  - `protocolVersion` 은 `"1.0"` 이다.
  - 수락 frame `KEEPER_CHAT_OPERATION_ACCEPTED` 의 값은 `metadata.masc` 로 옮긴다. 그 CUSTOM 은 지운다.
- 큐에서 기다리는 동안 run 은 열려 있고, 서버는 지금처럼 SSE comment 를 보낸다. 1.0 클라이언트는 comment 를 받아 넘겨야 한다(`http-sse.md`: "MUST tolerate SSE comment lines").
- journal 에 쓰지 않으므로 수락 때 새 writer 가 생기지 않는다. 업그레이드 전 journal 도 응답마다 같은 머리를 받는다.

#### 턴 경계

- journal 은 그대로다. 턴의 `Run_started`·`Run_finished` 를 wire 에서는 `masc.KEEPER_TURN_STARTED`·`masc.KEEPER_TURN_FINISHED` 로 보낸다.
- `next_sequence` 의 경계 조건, settle 보정, `content_generation` 의 원천은 바뀌지 않는다.
- masc 클라이언트는 「대기」를 `RUN_STARTED` 로, 「실행 시작」을 `masc.KEEPER_TURN_STARTED` 로 구분한다. Dashboard 의 `started` 와 TUI 의 `Chunk_run_started` 처리를 턴 CUSTOM 으로 옮긴다.
- 묶인 턴(`masc.KEEPER_CHAT_BATCH_BOUND`)은 지금처럼 member operation 마다 run 이다.

#### run 의 끝

- run 의 끝은 operation 의 끝이다. operation 이 끝 상태가 되면 journal 에 끝 이벤트 하나를 쓰고, wire 는 그것을 projection 한다.

| operation 의 끝 | journal 끝 이벤트 | wire |
|---|---|---|
| 성공 | 새 `Operation_succeeded` | `RUN_FINISHED`, outcome `success` |
| 취소 | 새 `Operation_cancelled` | `RUN_FINISHED`, outcome `cancelled`(`lifecycle.md`: 실패가 아닌 이유로 멈춘 run 은 MUST) |
| 실패 | 지금의 `Event_error` | `RUN_ERROR` |

- 쓰는 곳:
  - 성공과 실패는 settle hook(`on_operation_execution_settled`)이 쓴다. 이 hook 이 불릴 때 턴과 그 publisher 는 이미 끝났다(`:3395` 주석). writer 는 하나다.
  - 큐에서 취소는 HTTP cancel 길과 도구 길 모두 `cancel_queued` 가 성공한 뒤 쓴다. claim 전이라 publisher 가 없다.
- 한 journal 에 끝 이벤트는 하나다. `record_terminal_error` 가 이미 있는 끝을 돌려주는 방식(`Existing_terminal_error`)을 세 끝에 넓힌다. 같은 settle 이 다시 불려도 두 번 쓰지 않는다.
- operation 은 끝났는데 journal 에 끝이 없으면 재시작 정산이 그 끝을 쓴다. operation 을 저장한 뒤 journal 에 쓰기 전에 프로세스가 죽은 경우다.
- stream 은 끝 이벤트를 보내고 닫는다. 턴의 `Run_finished` 로는 닫지 않는다.
- 끝을 journal 에 쓰는 이유:
  - 이어 받기와 live 중복 제거가 journal seq 로 맞춘다. seq 없는 끝은 두 길을 어긋나게 한다(#41687).
  - wire 가 journal 의 함수가 되어, 순서 시험을 journal 녹화로 돌릴 수 있다.
  - 단점: 내부 이벤트가 둘 늘고, 취소 길에 journal 쓰기가 생긴다. 끝을 그때그때 operation 기록에서 만들면 둘 다 없지만, 끝에 seq 가 없다.
- 업그레이드 전 journal 에는 성공·취소 끝이 없다. 재생하면 끝 없는 run 이 되고, heartbeat 가 operation 기록을 보고 stream 을 닫는다. 지금 「끝 frame 없이 닫힌 stream」과 같은 경우다. 옛 journal 을 위한 reader 는 더하지 않는다.

#### frame 모양

- timestamp: 정수 ms 로 쓴다. 생성 타입은 `int` 다(Swift `Int`, Kotlin `Long`). 서버는 `Time_compat.now ()` 의 초를 ms 로 바꿔 쓴다.
- 확장 필드: 이벤트의 `metadata.masc` 객체로 옮긴다. ATD 에서는 종류마다 `metadata` record 를 적는다. masc 는 `metadata` 에서 `masc` key 하나만 쓴다.
  - 옮길 필드: `TEXT_MESSAGE_*`·`TOOL_CALL_*`·`CUSTOM` 의 `threadId`·`runId`, `textStreamScope`, `textResponse`, `toolStreamScope`, `providerMessageId`, `toolCallBlockIndex`.
  - `RUN_ERROR` 의 `threadId`·`runId` 는 지운다. `RunErrorEvent` 에 그 자리가 없고, stream 에 열린 run 이 곧 그 run 이다.
- id: 서버가 occurrence 로 만든다. provider id 는 쓰지 않고 `metadata.masc.providerMessageId` 로만 싣는다.
  - `messageId`: `keeper-message-<operation>-<content_generation>-<textStreamScope>`.
  - `toolCallId`: `keeper-tool-<operation>-<content_generation>-<toolStreamScope>-<toolCallBlockIndex>`.
  - reasoning 의 `messageId` 도 thinking 의 response 식별자로 같은 꼴을 쓴다.
  - operation id 는 thread 안에서 하나뿐이다. 나머지는 operation 안의 occurrence 다. 이 조합이 겹치지 않는지는 순서 시험이 본다.
- 끊긴 item: projection 은 응답마다 열린 message·tool call·reasoning 을 들고 있다가 닫는다.
  - 닫는 때: 턴 끝(`masc.KEEPER_TURN_FINISHED` 앞), provider 재시도(`masc.KEEPER_PROVIDER_RETRY` 앞), run 끝 앞.
  - 재시도 뒤 item 은 앞과 다른 id 를 쓴다. 지금 occurrence 가 재시도마다 바뀌는지는 단계 2 에서 확인한다. 바뀌지 않으면 runtime attempt 를 id 에 넣는다.
- `snapshot`: Q5 를 정한 뒤 옮긴다.
- role: ATD `role` 을 1.0 의 네 값으로 좁힌다. `tool` 이 빠지고 `developer` 가 생긴다. 서버는 이 frame 에 `User`·`Assistant` 만 쓰므로(§1.2) 빠지는 값을 쓰는 곳이 없다.
- CUSTOM 이름: `masc.` 를 앞에 붙인다. 예: `masc.KEEPER_CONNECTED`.
  - `passthrough.md` 는 prefix 꼴을 정하지 않는다. 예시 `com.example.cart-updated` 처럼 `.` 으로 나눈다. reverse-DNS 이름은 masc 가 가진 domain 이 없어 쓰지 않는다.
  - 스택의 생성기 `atd-native-gen` 은 wire 이름을 ASCII 영문·숫자·`_` 만 받는다(`native_ir.ml` `plain_name`). 이 단계에서 `.` 도 받게 한다. `.` 은 Swift·Kotlin 문자열 literal 에서 escape 가 필요 없어 `naming.ml` 의 전제가 그대로다. 거절 시험은 `x-y` 를 계속 거절하고 `masc.x` 를 받는지 본다.
- thinking: `KEEPER_THINKING_DELTA` 를 `REASONING_*` 로 보낸다. provider content block 하나가 reasoning 하나다. block 이 열릴 때 `REASONING_START`·`REASONING_MESSAGE_START` 를, 닫힐 때 `_END` 둘을 보낸다. thinking 의 `response` 는 `metadata.masc` 로 간다.
- usage: provider 메시지마다 `TokenUsage` 를 만들어 run 끝에 싣는다. `RUN_FINISHED.usage` 와 `RUN_ERROR.usage` 둘 다다. 토큰을 쓴 뒤 실패한 run 도 usage 를 남긴다.
- `Ag_ui.protocol_version` 은 `"1.0"` 으로 바꾸고 `RUN_STARTED.protocolVersion` 에 쓴다.

#### 이어 받기

- 그대로 둔다. `id:` 는 1.0 클라이언트가 무시하므로 해가 없다.
- `since_seq` 로 이어 받은 응답도 `RUN_STARTED` 로 시작한다. 다만 앞 응답에서 연 item 의 content 가 이어서 올 수 있어 1.0 순서 규칙을 지키지 않는다. masc 클라이언트만 쓰고, 순서 시험 대상이 아니다. D3 길은 `since_seq` 를 받지 않는다.

#### `/ag-ui/events`

- 이 길(`server_mcp_transport_http_agui.ml`, `keeper_chat_broadcast.ml`)은 여러 operation 의 frame 을 섞어 보낸다. run stream 이 아니다.
- frame 은 같은 projection 으로 만들어 frame 시험을 지킨다. 순서 시험 대상은 아니다.
- `dashboard/src` 와 `lib/masc_tui` 에서 이 경로를 부르는 곳은 없다(`rg 'ag-ui/events'`).

#### 함께 바꿀 곳

- 옛 모양 reader 는 두지 않는다(hard cut). 아래는 CUSTOM 이름, `RUN_STARTED`, `timestamp` 를 읽는 곳을 `rg` 로 모은 목록이다. 시험 파일은 뺐다.
- 서버: `lib/ag_ui/ag_ui.ml`·`.mli`, `lib/server/server_keeper_chat_agui_projection.ml`, `lib/server/server_routes_http_keeper_stream.ml`, `lib/server/server_mcp_transport_http_agui.ml`, `lib/keeper/keeper_chat_events.mli`, `lib/keeper/keeper_chat_types.ml`, `lib/keeper_chat_operations/keeper_chat_operation.mli`.
- Dashboard(`dashboard/src/`): `api/attachments.ts`, `api/keeper.ts`(`:417` 수락 이름 비교), `config/constants.ts`, `keeper-message.ts`, `keeper-state.ts`, `keeper-stream.ts`, `lib/keeper-chat-stream-contract.ts`, `lib/keeper-response-state.ts`, `lib/sse-event-type.ts`, `schemas/sse.ts`(`:1059` timestamp 검사), `types/core.ts`, `workspaces/keepers/keeper-chat-tab.ts`, `workspaces/keepers/keepers-api.ts`, `workspaces/keepers/types.ts`.
- TUI: `lib/masc_tui/protocol/wire_fleet.ml`·`.mli`, `lib/masc_tui/screens_ops/keeper_dive.ml`, `lib/masc_tui/store/fleet_store.ml`·`.mli`.
- 스크립트: `scripts/keeper-first-turn-smoke.py:214-229`.
  - 지금은 수락 → `RUN_STARTED` → `KEEPER_REPLY_DETAILS` → `RUN_FINISHED` 순서를 단언한다.
  - 새 순서는 `RUN_STARTED` → `masc.KEEPER_TURN_STARTED` → `masc.KEEPER_REPLY_DETAILS` → `masc.KEEPER_TURN_FINISHED` → `RUN_FINISHED` 다.
  - `scripts/install-smoke.sh` 와 `.github/workflows/kata-volume-smoke.yml` 이 이 스크립트를 쓴다.
- 네이티브 앱: ATD 를 바꾸고 생성물을 다시 만든다.
- 시험: 같은 이름을 쓰는 `test/` 파일 목록은 단계 2 의 PR 본문에 남긴다.

### D3. `RunAgentInput` 을 받는 길을 더한다

- `POST /api/v1/ag-ui/keepers/:keeper`. 경로 이름은 단계 3 에서 정한다.
  - 요청: `Accept: text/event-stream`, `Content-Type: application/json`, 본문은 `RunAgentInput` 하나다.
  - 응답: 200 과 `text/event-stream` 이다. 본문이 `RunAgentInput` 이 아니거나 아래 표의 400 이면 이벤트 스트림 없는 HTTP 오류 상태다(`http-sse.md`).
- 인증: `chat/stream` 과 같은 bearer 다. 1.0 은 인증을 정하지 않는다(`transports/index.md`).
- 브라우저: CORS 헤더는 same-origin 과 허용된 dev origin 에만 붙는다(`lib/server/server_auth.ml:795`). 첫 버전은 서버 쪽 runtime(CopilotKit runtime, Node 의 `HttpAgent`)이 중계하는 구성만 쓴다.

#### 대화 기록은 masc 가 가진다

- 1.0 은 `messages` 를 producer 가 보는 "the complete history" 로 MUST 취급하라고 한다(`run-input.md`). 이 길은 이 규칙을 따르지 않는다.
- 모델이 보는 기록은 masc 기록이다. 클라이언트가 보낸 `messages` 에서는 마지막 user 메시지 하나만 쓴다.
- 클라이언트에서 지우기·고치기·다시 만들기를 해도 반영되지 않는다. run 의 `MESSAGES_SNAPSHOT` 이 클라이언트 화면을 masc 기록으로 되돌린다(`state.md`: snapshot 에 없는 메시지는 버린다).

#### 입력 해석

| 필드 | 받는 값과 하는 일 | 그 밖의 값 |
|---|---|---|
| `threadId` | `keeper:<경로의 keeper>` | 400. Keeper 하나에 대화는 하나라 새 thread 를 만들 수 없다. 클라이언트 설정으로 threadId 를 정해야 한다 |
| `runId` | 아무 문자열. 이 응답의 `RUN_*` 에 그대로 쓰고 저장하지 않는다 | — |
| `messages` 의 마지막 | user 메시지. 그 id 로 operation 을 찾거나 만든다(아래) | user 가 아니면 턴을 만들지 않는다. `RUN_STARTED` → `MESSAGES_SNAPSHOT` → `RUN_FINISHED` 로 닫는다 |
| 그 메시지의 content part | text part 를 이어 붙여 입력으로 쓴다 | 다른 part 는 건너뛰고 `masc.KEEPER_INPUT_PART_SKIPPED` 를 보낸다(`run-input.md`: 쓸 수 없는 part 로 run 을 실패시키지 MUST NOT). text 가 하나도 없으면 턴을 만들지 않고 위처럼 닫는다 |
| `protocolVersion` | 없음, `1.x`, 해석할 수 없는 값. 그대로 진행하고 응답에는 `"1.0"` 을 쓴다. `1.0` 이 아니면 서버 로그에 경고한다 | 다른 major 만 `RUN_STARTED` 전에 400 이다(`versioning.md`) |
| `tools` | 무시한다. 첫 버전 Keeper 는 클라이언트 도구를 부르지 않는다 | — |
| `context` | 첫 버전은 모델에 넘기지 않는다. `run-input.md` 의 SHOULD 를 따르지 않는 곳이다(Q6) | — |
| `state`, `forwardedProps`, `parentRunId` | 무시한다 | — |
| `resume` | 없거나 비어 있음 | 400. masc 는 interrupt 를 내지 않는다 |

#### operation 찾기와 중복 전송

- operation id: (보낸 주체, keeper, 마지막 user 메시지 id)의 sha256 앞 32자에 `agui-` 를 붙인다. `Keeper_operation_id` 규칙(영문·숫자·`_`·`-`·`.`, 128 byte 이하)을 늘 지킨다.
- operation 저장소는 같은 id 를 다시 받으면 있는 operation 을 돌려준다. 같은 id 에 다른 입력이면 `Idempotency_conflict` 를 낸다(`lib/keeper_chat_operations/keeper_chat_operation_store.mli:14`). 판정은 Keeper 의 Owner 안에서 하므로, 동시에 온 요청 둘이 operation 둘을 만들지 않는다.

| 경우 | 동작 |
|---|---|
| 끊긴 뒤 다시 보냄(새 runId, 같은 messages) | 같은 operation 에 붙는다. 그 journal 을 처음부터 보내고 live 로 잇는다. 끝난 operation 이면 끝까지 보내고 닫는다 |
| 큐에서 기다리는 중 다시 보냄 | 같은 operation 에 붙는다. 턴은 한 번만 돈다 |
| 앞 메시지가 operation 이 되기 전에 거절됨(400, `Keeper_not_started`, paused) | 그 메시지에는 operation 이 없다. 새 마지막 user 메시지가 입력이 된다. 거절된 메시지는 쓰지 않고, snapshot 이 화면에서 지운다 |
| 끝난 operation 의 메시지를 다시 보냄 | 그 끝을 다시 보낸다. 같은 말을 다시 시도하려면 클라이언트가 새 메시지로 보내야 한다 |
| 같은 id 의 메시지를 고쳐 보냄 | `Idempotency_conflict`. 응답은 `RUN_ERROR` 하나다(code `masc.idempotency_conflict`). 스트림은 `RUN_ERROR` 로 시작해도 된다(`lifecycle.md`) |

- 클라이언트 메시지 id 는 수락 때 operation source 에 저장한다. user 행은 턴이 실행될 때 쓰이므로(`append_queued_user_row_once`, `server_routes_http_keeper_stream.ml:1711`), 그때 이 id 를 행에 옮긴다.
- 이 저장은 새 필드다. 없으면 snapshot 이 방금 보낸 메시지를 다른 id 로 바꾼다. 클라이언트는 그 메시지를 지웠다가 다른 id 로 다시 붙인다.

#### 이벤트 순서

- `RUN_STARTED` → `MESSAGES_SNAPSHOT` → operation journal 의 projection → 끝 이벤트.
- snapshot 은 masc 기록에 이번 operation 의 user 메시지를 더한 것이다. user 행이 아직 없으면 operation source 의 메시지로 채운다.
- snapshot 의 id:
  - user 메시지는 클라이언트 id 가 있으면 그것을, 없으면 masc 행 id 를 쓴다.
  - assistant 메시지는 stream 이 쓴 `messageId`(D2)와 같다.
  - 기록 행과 stream message 가 1:1 로 맞는지는 단계 3 의 첫 확인이다.

#### 첫 버전에서 1.0 클라이언트가 못 하는 것

- 큐 대기와 승인 대기 동안 run 은 열려 있고 SSE comment 만 온다. 무엇을 기다리는지는 `masc.` CUSTOM 이라 보이지 않는다(Q1, Q3).
- 승인은 Dashboard·TUI 에서 한다.
- 연결을 끊어도 operation 은 취소되지 않는다. 다시 보내면 붙는다. 외부 클라이언트의 취소는 없다.

### D4. 외부 클라이언트로 확인한다

- `@ag-ui/client` 의 `HttpAgent` 를 Node 에서 띄워 로컬 서버에 붙는다. 확인할 것:
  - run 하나를 끝까지 받는다.
  - 중간에 끊고 같은 messages 로 다시 보내 같은 답을 받는다.
  - 큐에서 기다리는 중 다시 보내도 턴이 한 번 돈다.
- 받은 이벤트와 SDK 경고를 PR 본문에 남긴다.
- CopilotKit 화면에서 대화가 보이는지는 사람이 확인한다.

## 3. 하지 않는 것

- 클라이언트가 보내는 도구(frontend tools), `STATE_*`, `SUBAGENT_*`, protobuf binding.
- 승인을 interrupt 로 바꾸기(Q1).
- 외부 클라이언트의 취소와 새 thread.
- image part 를 masc 첨부로 받기.
- Dashboard·TUI 를 `@ag-ui/client` 나 CopilotKit 으로 바꾸기.
- 이어 받기를 없애기. masc 클라이언트가 계속 쓴다.

## 4. 단계

- 순서:
  1. 네이티브 앱 RFC 의 단계 1 스택 #55396 이 main 에 들어간다. 이 RFC 는 그 스택의 ATD 와 생성기를 쓴다.
  2. 이 RFC 의 단계 1·2.
  3. 네이티브 앱 RFC 의 단계 2(기록 쪽, 요청 본문, 첨부 meta, CUSTOM payload, 목록 행). CUSTOM payload 를 새 이름 위에서 타입으로 적는다.
  4. 이 RFC 의 단계 3. `MESSAGES_SNAPSHOT` 의 `Message` 를 ATD 에 더한다.
  5. 네이티브 앱 RFC 의 단계 3(Apple 앱).
- 3 과 4 는 서로 기다리지 않는다. 같은 ATD 를 고치므로 나중 것을 먼저 들어간 것 위에 다시 얹는다. 네이티브 단계 2 가 기록 쪽을 `Message` 모양으로 받을지는 그쪽에서 정한다.
- 네이티브 앱 RFC 의 단계 번호는 #55489(그 RFC 의 단계 나누기, 아직 병합 전)의 것이다.

1. **스키마 사본과 검사기**
   - 사본, `SOURCE`, 검사기를 넣는다. fixture 어긋남 규칙을 `check` alias 로 옮긴다. 시험은 모든 fixture 가 통과하는 층에서 켠다. 그 전 층은 위반 수를 PR 본문에 남긴다.
   - 확인: 검사기가 지금 fixture 에서 §1.1 과 같은 수를 낸다.
2. **wire 를 1.0 모양으로**
   - 층마다 서버, masc 클라이언트 셋, fixture 를 같이 바꾼다. 각 층의 CI 가 깨지지 않게 하기 위해서다.
   - 층 2-a: timestamp, `metadata.masc`, id, role.
   - 층 2-b: 응답 머리, 턴 CUSTOM, journal 끝 이벤트, CUSTOM 이름과 생성기의 `.`, thinking, usage, smoke 스크립트.
   - 층 2-c: fixture 를 생성자마다 채우고 frame 시험과 순서 시험을 켠다.
   - 확인: 두 시험 통과, Dashboard·TUI 기존 시험 통과, 네이티브 생성물 decode 시험 통과, smoke 스크립트 로컬 실행.
3. **`RunAgentInput` 길**
   - 확인: 입력 해석 표의 행마다 시험, 중복 전송 표의 행마다 시험, `MESSAGES_SNAPSHOT` 을 포함한 응답이 순서 시험을 통과.
4. **외부 클라이언트 확인**(D4)

## 5. 열린 질문

- **Q1. 승인과 interrupt.** masc 는 턴을 그 호출에서 멈추고 운영자 답을 기다린다. 1.0 은 run 을 interrupt 로 끝내고 클라이언트가 새 run 으로 답한다. 외부 클라이언트가 승인하게 하려면 run 의 끝과 턴의 끝을 나눠야 한다. 운영자가 승인할 곳(TUI, Dashboard, 외부 클라이언트)을 먼저 정한다.
- **Q2. 도구 결과.** `TOOL_CALL_RESULT` 는 `content` 가 필수다. tool-call 저장소에서 결과를 읽어 실을지 정한다. 결과 크기와, 결과에 든 비밀값을 가리는 규칙이 같이 정해져야 한다.
- **Q3. provider native 도구, 큐 대기와 `ACTIVITY_*`.** `ACTIVITY_*` 는 `messages` 로 되돌아가지 않는 진행 표시다. native 도구의 진행과 큐 대기가 그 뜻에 맞는지 이벤트마다 본다.
- **Q4. 검사기.** 2026-11-28 `opam search` 로 JSON Schema 2020-12 검사기를 찾지 못했다. Dashboard 의존성에도 없다. Python `jsonschema`(측정에 쓴 것)를 쓰면 `type-check` job 에 설치가 는다. 헌장은 운영자 요청 없이 PR 마다 도는 검사를 늘리지 않게 하므로, 고른 도구와 job 변경을 운영자에게 확인받는다.
- **Q5. 인자 `snapshot`.** `snapshot` 이 오는 경우 그 call 에 `delta` 를 보낸 적이 있는지 본다. 없으면 `snapshot` 을 그대로 `delta` 로 보내면 된다. 있으면 1.0 에는 담을 자리가 없다.
- **Q6. CopilotKit 이 기본으로 보내는 값.** 단계 3 전에 실제 요청으로 본다. 볼 것은 `tools`·`context`·`forwardedProps` 의 값, threadId 를 정하는 설정, `protocolVersion` 이다. `context` 를 모델에 넘길지는 이 측정 뒤 정한다.
