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

## 0. 요약

- 지금 masc frame 은 1.0 클라이언트와 맞지 않는다. fixture 21개 중 20개가 1.0 스키마에서 거절된다. 통과한 1개도 timestamp 단위가 달라 날짜가 틀리게 읽힌다(§1.1).
- 바꾸는 것:
  - timestamp 를 정수 ms 로 쓴다.
  - masc 확장 필드를 이벤트의 `metadata.masc` 로 옮긴다.
  - 1.0 이 필수로 정한 id 를 늘 채운다.
  - CUSTOM 이름 앞에 `masc.` 를 붙인다.
  - 스트림을 `RUN_STARTED` 로 시작한다.
  - thinking 글을 `REASONING_*` 이벤트로 보낸다.
- 더하는 것:
  - `RunAgentInput` 을 받는 길. 외부 클라이언트는 이 길로 붙는다.
  - 1.0 스키마 사본으로 서버 출력을 검사하는 시험.
- 그대로 두는 것:
  - 이어 받기(`id: <journal seq>`, `since_seq`). 1.0 클라이언트는 SSE `id:` 를 무시하므로 해가 없다. masc 클라이언트는 계속 쓴다.
  - `chat/stream` 요청 본문.
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

- `threadId`·`runId` 는 1.0 에서 `RUN_STARTED`·`RUN_FINISHED` 에만 있다.
- 1.0 클라이언트는 정의에 없는 필드 때문에 run 을 멈추지 않는다. 경고를 남기고 그 필드를 지운다(`processing.md`: "A consumer MUST NOT let a stripped property survive into the value application code receives"). 그래서 위 값은 1.0 클라이언트에게 보이지 않는다.

### 1.2 1.0 규칙과 다른 곳

| 규칙 | 1.0 | masc 지금 | 1.0 클라이언트가 겪는 일 |
|---|---|---|---|
| 시각 | `timestamp` 정수. SDK 는 ms | 초 단위 float. `Time_compat.now ()` | 스키마가 거절한다. 숫자로 받는 SDK 는 1970-01-21 로 읽는다 |
| 확장 자리 | `metadata`. key 로 열려 있고 지우지 않는다. `ag-ui` key 는 예약 | 이벤트 최상위 필드 | 경고와 함께 지운다 |
| 필수 id | `TEXT_MESSAGE_CONTENT`·`END` 의 `messageId`, `TOOL_CALL_*` 의 `toolCallId` | 빠질 수 있다 | 거절한다 |
| 인자 조각 | `TOOL_CALL_ARGS` 는 `delta` 만 | `delta` 또는 지금까지의 인자 전문 `snapshot` | 거절한다 |
| 스트림 시작 | "A stream MUST begin with RUN_STARTED or RUN_ERROR"(`lifecycle.md`) | `chat/stream` 은 CUSTOM 수락 frame 을 먼저 보낸다(`lib/server/server_routes_http_keeper_stream.ml:3687`). 큐에 든 턴은 턴이 시작할 때 `RUN_STARTED` 가 온다 | 첫 이벤트부터 규격 밖이다 |
| CUSTOM 이름 | vendor·application prefix 를 SHOULD 로 붙인다. prefix 없는 이름은 protocol 예약(`passthrough.md`) | 30개 모두 prefix 없음 | 지금은 모르는 이름이라 무시한다. 1.0 이 같은 이름을 정하면 겹친다 |
| 이어 받기 | 없다. "SSE's Last-Event-ID mechanism is not used", 클라이언트는 `id:` 를 무시한다(`http-sse.md`) | `chat/stream` 은 `id:` + `since_seq`, `/ag-ui/events` 는 `Last-Event-ID` 재생 | `id:` 를 무시한다. 끊기면 새 run 이다 |
| run 시작 요청 | `POST` + `RunAgentInput`(`threadId`, `runId`, `messages`, `tools`, `context`, `state`, `forwardedProps`, `resume`, `protocolVersion`) | `chat/stream` 자체 본문(`request_id`, `name`, `message`, `admission_intent`, `since_seq` …) | 붙을 길이 없다 |
| 승인 | run 을 `RUN_FINISHED` outcome `interrupt` 로 끝내고, 새 run 의 `resume` 으로 답한다(`interrupt-resume.md`) | 턴이 그 호출에서 멈추고 운영자 답을 기다린다(`lib/keeper/keeper_chat_events.mli:233-246`) | 승인 요청을 모른다. CUSTOM 이라 무시한다 |
| 대화 기록 | `messages` 를 "the complete history" 로 본다(`run-input.md`) | 서버가 기록을 가진다 | 설계할 것(D3) |

- 서버의 `Ag_ui.protocol_version` 은 `"0.1.0"` 이고 부르는 곳이 없다(`lib/ag_ui/ag_ui.ml:187`). `RUN_STARTED` 에는 `protocolVersion` 이 없다.
- `TEXT_MESSAGE_START` 의 role 은 1.0 에서 `developer`·`system`·`assistant`·`user` 다. 서버가 이 frame 에 쓰는 role 은 `User`·`Assistant` 뿐이다(`lib/keeper/keeper_chat_events.mli:27`). 스택의 ATD `role` 에는 `tool` 이 더 있다.

### 1.3 CUSTOM 30개와 1.0 이벤트

이름과 `keeper_chat_events.mli` 주석으로 묶었다. 「1.0 에서 같은 뜻」 칸은 필드와 규칙을 맞대 본 결과다.

| CUSTOM | 하는 일 | 1.0 에서 같은 뜻 | 판정 |
|---|---|---|---|
| `KEEPER_THINKING_DELTA` | thinking 글 조각 | `REASONING_MESSAGE_CONTENT`. 앞뒤로 `REASONING_START`·`REASONING_MESSAGE_START`·`_END`·`REASONING_END` | 옮긴다(D2) |
| `KEEPER_THINKING_SNAPSHOT` | 지금까지의 thinking 전문 | 없다. reasoning 에는 snapshot 이 없다 | `masc.` |
| `KEEPER_THINKING_SIGNATURE_DELTA` | 서명 바이트 수(`signature_bytes : int`) | `REASONING_ENCRYPTED_VALUE` 는 값 자체를 싣고, 클라이언트가 다음 run 입력에 그대로 돌려준다 | 다르다. masc 는 서명을 서버에 둔다. `masc.` |
| `KEEPER_TOOL_RESULT_READY` | 결과가 tool-call 저장소에 기록됐다. 내용은 없다 | `TOOL_CALL_RESULT` 는 `content` 가 필수다 | 다르다. Q2 |
| `KEEPER_TOOL_APPROVAL_REQUESTED`·`_SETTLED` | 턴 안에서 운영자 답을 기다린다 | interrupt 는 run 을 끝낸다 | 다르다. Q1 |
| `KEEPER_NATIVE_TOOL_START`·`_END`·`_PROGRESS` | provider 가 직접 도는 도구(검색 등)의 진행 | `ACTIVITY_*`: "structured progress that is not conversation content"(`activity.md`) | 가깝다. Q3 |
| `KEEPER_STREAM_MESSAGE_START`·`_DELTA` | provider 메시지의 model, stop reason, usage | `RUN_FINISHED.usage`(`TokenUsage[]`)는 usage 만 받는다 | usage 는 `RUN_FINISHED` 에도 싣는다. 이벤트는 `masc.` |
| `KEEPER_CONNECTED`, `KEEPER_RUNTIME_ATTEMPT_STARTED`, `KEEPER_PROVIDER_RETRY`, `KEEPER_STREAM_MESSAGE_STOP`, `KEEPER_STREAM_PING`, `KEEPER_CONTENT_BLOCK_START`·`_STOP`, `KEEPER_MODEL_CONTENT_ACTIVITY`, `KEEPER_STREAM_PROTOCOL_ERROR`, `KEEPER_MEDIA_DELTA` | provider 스트림과 runtime 관찰 | 없다 | `masc.` |
| `KEEPER_CHAT_OPERATION_ACCEPTED`, `KEEPER_CHAT_BATCH_BOUND`, `KEEPER_CONTINUATION_CHECKPOINT`, `KEEPER_EXTERNAL_EFFECT_COMPLETED`, `KEEPER_REPLY_DETAILS`, `KEEPER_TOOL_CALL_ADMITTED`, `KEEPER_TOOL_TRANSCRIPT_COMMITTED`, `KEEPER_ATTACHMENT` | masc 대화 operation 과 저장 사실 | 없다 | `masc.` |
| `MASC_EVENT` | `/ag-ui/events` 의 masc 이벤트 | 없다 | `masc.` |

- 마지막 세 묶음은 이벤트마다 뜻을 하나씩 맞대 보지 않았다. 단계 2 에서 이름을 바꿀 때 하나씩 본다.

## 2. 제안

### D1. 1.0 스키마 사본으로 서버 출력을 시험한다

- `schema.json` 을 저장소에 둔다. 출처 URL, 받은 날, sha256 을 같이 적는다.
- 시험은 둘이다.
  - frame 시험: fixture 의 frame 마다 자기 `type` 정의와 `Event` 로 검사한다.
  - 순서 시험: SSE fixture 가 `lifecycle.md` 를 지키는지 본다. 스키마는 순서를 보지 못하기 때문이다. 볼 규칙은 다음과 같다.
    - 첫 이벤트는 `RUN_STARTED` 나 `RUN_ERROR` 다.
    - 연 message·tool call·reasoning 은 run 이 끝나기 전에 닫는다. 열지 않은 id 에 content·end 를 보내지 않는다.
    - 닫힌 run 뒤에는 `RUN_STARTED` 만 온다. `RUN_FINISHED` 뒤의 늦은 `RUN_ERROR` 는 예외다.
- 사본은 에이전트가 고치지 않는다. 시험은 사본의 sha256 이 적어 둔 값과 다르면 실패한다. 새 버전은 사람이 받아서 바꾼다.
- `schema-files.md` 는 strict 스키마를 받는 쪽 검사에 쓰지 말고 작성과 시험에 쓰라고 한다. 이 RFC 는 서버 출력 시험에만 쓴다.
- 검사기는 Q4 다.

### D2. wire 를 1.0 모양으로 한 번에 바꾼다

- timestamp: 정수 ms 로 쓴다. 생성 타입은 `int` 다(Swift `Int`, Kotlin `Long`). 서버는 `Time_compat.now ()` 의 초를 ms 로 바꿔 쓴다.
- 확장 필드: 이벤트의 `metadata.masc` 객체로 옮긴다. ATD 에서는 종류마다 `metadata` record 를 적는다. masc 는 `metadata` 에서 `masc` key 하나만 쓴다.
  - 옮길 필드: `RUN_*` 밖의 `threadId`·`runId`, `textStreamScope`, `textResponse`, `toolStreamScope`, `providerMessageId`, `toolCallBlockIndex`.
- 필수 id: `TEXT_MESSAGE_CONTENT`·`END` 의 `messageId` 와 `TOOL_CALL_*` 의 `toolCallId` 를 늘 채운다.
  - text: 열려 있는 `TEXT_MESSAGE_START` 의 id 다.
  - tool: provider 가 id 를 주지 않으면 masc 가 occurrence(`toolStreamScope`, `toolCallBlockIndex`)와 runId 로 id 를 만든다. 1.0 은 `messageId` 가 thread 안에서 하나뿐이어야 한다고 정한다(`basic/index.md`). `toolCallId` 도 같은 규칙으로 만든다.
  - 만드는 곳마다 id 의 출처를 단계 2 의 PR 본문에 적는다.
- `snapshot`: Q5 를 정한 뒤 옮긴다.
- role: ATD `role` 을 1.0 의 네 값으로 좁힌다.
- CUSTOM 이름: `masc.` 를 앞에 붙인다. 예: `masc.KEEPER_CONNECTED`. 바뀌는 것이 앞의 다섯 글자뿐이라 찾기와 대조가 쉽다. reverse-DNS 이름(`com.example.…`)은 masc 가 가진 domain 이 없어 쓰지 않는다.
- thinking: `KEEPER_THINKING_DELTA` 를 `REASONING_*` 로 보낸다. provider content block 하나가 reasoning 하나다. block 이 열릴 때 `REASONING_START`·`REASONING_MESSAGE_START` 를, 닫힐 때 `_END` 둘을 보낸다. thinking 의 `response` 는 `metadata.masc` 로 간다.
- 스트림 시작: run 을 chat operation 하나로 본다.
  - 서버는 operation 을 받을 때 `RUN_STARTED` 를 먼저 journal 에 쓴다. runId 는 지금과 같은 operation run id 다. `protocolVersion` 은 `"1.0"` 이다.
  - 수락 정보는 그 뒤 `masc.KEEPER_CHAT_OPERATION_ACCEPTED` 로 보낸다.
  - 지금 턴이 시작할 때 쓰는 `RUN_STARTED` 는 쓰지 않는다. 큐에서 기다리는 동안에도 run 은 열려 있다. 이 동안 1.0 클라이언트가 무엇을 보이는지는 D4 에서 본다.
  - 한 턴이 operation 여럿을 묶는 경우는 Q6 이다.
- usage: provider 메시지마다 `TokenUsage` 를 만들어 `RUN_FINISHED.usage` 에 싣는다.
- `Ag_ui.protocol_version` 은 `"1.0"` 으로 바꾸고 `RUN_STARTED.protocolVersion` 에 쓴다.
- 이어 받기는 그대로 둔다.
  - `id:` 는 1.0 클라이언트가 무시하므로 해가 없다.
  - `since_seq` 재생은 run 중간부터 시작하는 스트림이다. 1.0 의 시작 규칙과 다르므로 masc 클라이언트만 쓴다. D3 의 길은 재생하지 않는다.
- masc 클라이언트 셋을 같은 스택에서 바꾼다. 옛 모양 reader 는 두지 않는다(hard cut).
  - Dashboard: frame 이름을 읽는 곳은 `dashboard/src/` 의 `keeper-stream.ts`, `schemas/sse.ts`, `keeper-state.ts`, `workspaces/keepers/keepers-api.ts`, `lib/keeper-response-state.ts`, `lib/keeper-chat-stream-contract.ts` 다(`rg -l TEXT_MESSAGE_CONTENT dashboard/src`, 시험 파일 뺌).
  - TUI: `lib/masc_tui/protocol/wire_fleet.ml:3873` 부근의 frame decoder.
  - 네이티브 앱: ATD 를 바꾸고 생성물을 다시 만든다.

### D3. `RunAgentInput` 을 받는 길을 더한다

- `POST /api/v1/ag-ui/keepers/:keeper`. 경로 이름은 단계 3 에서 정한다.
  - 요청: `Accept: text/event-stream`, `Content-Type: application/json`, 본문은 `RunAgentInput` 하나다.
  - 응답: run 이 시작되면 200 과 `text/event-stream` 이다. 거절은 이벤트 스트림 없는 HTTP 오류 상태다(`http-sse.md`).
- 인증: `chat/stream` 과 같은 bearer 다. 1.0 은 인증을 정하지 않는다(`transports/index.md`).
- 입력 해석:

| 필드 | 받는 값 | 받지 않으면 |
|---|---|---|
| `protocolVersion` | `"1.0"` | 400 |
| `threadId` | `keeper:<경로의 keeper>`. 지금 frame 의 threadId 와 같다 | 400 |
| `runId` | masc `request_id` 규칙을 통과하는 값. 처음 보는 operation | 400. 이미 있는 operation 이면 409. 이 길은 이어 받지 않는다 |
| `messages` | masc 기록에 없는 id 의 user 메시지가 정확히 하나. text part 만 | 400 |
| `tools`, `context`, `state`, `forwardedProps`, `resume` | 없거나 비어 있음 | 400. 조용히 버리지 않는다 |

- `messages` 에서 masc 가 아는 id 는 masc 기록의 행 id 와, 앞서 받은 user 메시지의 클라이언트 id 다. masc 는 받은 user 메시지의 id 를 그 행의 `external_message_id` 로 저장한다.
- run 의 첫 이벤트는 `RUN_STARTED` 다. thread 에 masc 기록이 있으면 그다음 `MESSAGES_SNAPSHOT` 을 보낸다(`snapshots.md`: 옛 thread 를 이어 가는 run 은 SHOULD). 기록을 `Message` 로 바꾸는 projection 은 네이티브 앱 RFC 단계 2 의 기록 쪽 결정과 같이 정한다.
- 내부는 `chat/stream` 과 같은 operation 저장소와 journal 을 쓴다. 요청 모양만 다르고 이벤트는 같다.

### D4. 외부 클라이언트로 확인한다

- `@ag-ui/client` 의 `HttpAgent` 로 로컬 서버에 붙어 run 하나를 끝까지 받는다. 받은 이벤트와 SDK 경고를 PR 본문에 남긴다.
- CopilotKit 화면에서 대화가 보이는지는 사람이 확인한다.

## 3. 하지 않는 것

- 클라이언트가 보내는 도구(frontend tools), `STATE_*`, `SUBAGENT_*`, protobuf binding.
- 승인을 interrupt 로 바꾸기(Q1).
- Dashboard·TUI 를 `@ag-ui/client` 나 CopilotKit 으로 바꾸기.
- 이어 받기를 없애기. masc 클라이언트가 계속 쓴다.

## 4. 단계

- 네이티브 앱 RFC 의 단계 1 스택(#55396)이 main 에 들어간 뒤 시작한다. 그 스택의 ATD 와 생성기를 쓴다.
- 단계 2 는 네이티브 앱 RFC 의 단계 3(Apple 앱)보다 먼저 들어가는 편이 좋다. 앱 코드가 옛 wire 의 timestamp 와 최상위 확장 필드를 읽지 않게 된다.

1. **스키마 사본과 검사기**
   - 사본, sha256, 검사기를 넣는다. 시험은 모든 fixture 가 통과하는 층에서 켠다. 그 전 층은 위반 수를 PR 본문에 남긴다.
   - 확인: 검사기가 지금 fixture 에서 §1.1 과 같은 수를 낸다.
2. **wire 를 1.0 모양으로**
   - 층마다 서버, masc 클라이언트 셋, fixture 를 같이 바꾼다. 각 층의 CI 가 깨지지 않게 하기 위해서다.
   - 층 2-a: timestamp, `metadata.masc`, 필수 id, role.
   - 층 2-b: CUSTOM 이름, thinking, 스트림 시작 순서, usage.
   - 층 2-c: frame 시험과 순서 시험을 켠다.
   - 확인: 두 시험 통과, Dashboard·TUI 기존 시험 통과, 네이티브 생성물 decode 시험 통과.
3. **`RunAgentInput` 길**
   - 확인: 입력 해석 표의 거절마다 시험, `MESSAGES_SNAPSHOT` 이 순서 시험을 통과.
4. **외부 클라이언트 확인**(D4)

## 5. 열린 질문

- **Q1. 승인과 interrupt.** masc 는 턴을 그 호출에서 멈추고 운영자 답을 기다린다. 1.0 은 run 을 interrupt 로 끝내고 클라이언트가 새 run 으로 답한다. 외부 클라이언트가 승인하게 하려면 run 의 끝과 턴의 끝을 나눠야 한다. 운영자가 승인할 곳(TUI, Dashboard, 외부 클라이언트)을 먼저 정한다.
- **Q2. 도구 결과.** `TOOL_CALL_RESULT` 는 `content` 가 필수다. tool-call 저장소에서 결과를 읽어 실을지 정한다. 결과 크기와, 결과에 든 비밀값을 가리는 규칙이 같이 정해져야 한다.
- **Q3. provider native 도구와 `ACTIVITY_*`.** `ACTIVITY_*` 는 `messages` 로 되돌아가지 않는 진행 표시다. native 도구의 진행이 그 뜻에 맞는지 이벤트마다 본다.
- **Q4. 검사기.** OCaml 에서 JSON Schema 2020-12 를 검사하는 opam 패키지가 있는지 확인한다. 없으면 Python `jsonschema`(측정에 쓴 것)나 Dashboard 의 node 도구 중에서 고른다. 헌장은 운영자 요청 없이 PR 마다 도는 검사를 늘리지 않게 한다. 지금 도는 시험 작업 안에서 돌아야 한다.
- **Q5. 인자 `snapshot`.** `snapshot` 이 오는 경우 그 call 에 `delta` 를 보낸 적이 있는지 본다. 없으면 `snapshot` 을 그대로 `delta` 로 보내면 된다. 있으면 1.0 에는 담을 자리가 없다.
- **Q6. 한 턴이 operation 여럿을 묶을 때**(`KEEPER_CHAT_BATCH_BOUND`). run 을 operation 마다 둘지, 묶인 턴 하나로 둘지 정한다.
- **Q7. CopilotKit 이 기본으로 보내는 값.** `tools`·`context`·`forwardedProps` 에 무엇을 넣는지 단계 3 전에 실제 요청으로 본다. 기본으로 넣는다면 D3 의 400 규칙을 그 값에 맞춰 다시 정한다.
