---
rfc: "mcp-mrtr-client-continuation"
title: "MRTR 은 서버에 만들지 않고, 클라이언트가 한 번의 호출 안에서 이어 붙인다"
status: Draft
created: 2026-10-27
updated: 2026-10-27
author: claude
supersedes: []
superseded_by: null
related: ["mcp-dual-bearer-oauth"]
---

# RFC: MRTR 클라이언트 이어 붙이기 (mcp-mrtr-client-continuation)

## 0. 요약

MCP 2026-07-28 의 MRTR(Multi Round-Trip Requests)은 이렇게 돈다. 서버가 요청을 처리하다
입력이 더 필요하면 `InputRequiredResult` 를 돌려준다. 클라이언트는 같은 요청을 새 id 로
다시 보낸다. 서버는 상태를 저장하지 않고, 필요한 맥락을 `requestState` 에 담아 클라이언트가
그대로 돌려보내게 한다.

MASC 의 현재 상태는 이렇다.

- 서버는 server→client 요청을 하나도 보내지 않는다. MRTR 서버 의무는 그런 요청을 보낼 때만
  걸리므로, 지금 서버에 만들 것이 없다.
- 클라이언트(`Mcp_client`)는 capability 를 빈 객체로 선언한다. 그러면 외부 서버는 `inputRequests`
  를 보낼 수 없고, `requestState` 만 담은 라운드만 보낼 수 있다. Keeper 호출 경로는 이 라운드를
  이어 가지 않고 `input_required` 실패로 끝낸다.

이 RFC 는 세 가지를 정한다.

1. 서버 쪽 MRTR 생산자(producer)를 만들지 않는다.
2. `requestState` 만 있는 라운드를 한 번의 Keeper 도구 호출 안에서 이어 간다.
3. sampling 과 roots 는 선언하지 않는다. elicitation 은 이 RFC 범위 밖이고 별도 RFC 로 다룬다.

## 1. 실측

2026-10-27 확인. 코드는 스택 #46344~#46349 를 얹은 상태이고, 이 스택은 아직 컴파일되지 않았다.
표의 기준 트리는 스택 맨 위 `refs/pull/46349/head` 다. 이 PR 의 트리(main)에는
`start_tool_with_continuation`, `resume_tool_with_state`(#46348), `Input_required` 처리(#46349),
`client_capabilities_meta_key` 가 아직 없다.

| 항목 | 값 | 확인 방법 |
|---|---|---|
| 서버가 보내는 server→client 요청 | 0건 | `rg '"(elicitation/create\|sampling/createMessage\|roots/list)"' lib bin` |
| 서버가 광고하는 capability | `elicitation`, `sampling`, `roots` 없음 | `rg '"elicitation"\|"sampling"\|"roots"'` 를 서버 프로토콜 파일에 실행 |
| 클라이언트가 선언하는 capability | 빈 객체 | `lib/mcp_client/mcp_client.ml` 의 `client_capabilities_meta_key` |
| 서버가 받는 이어받기 필드 | 발급하지 않은 `requestState`, `inputResponses` 는 실행 전에 거부 | #46347 |
| 클라이언트 이어 붙이기 API | `start_tool_with_continuation`, `resume_tool_with_state`. 메모리 안, 한 번만 쓸 수 있음 | `lib/mcp_client/mcp_client.mli` |
| Keeper 의 처리 | `Input_required` 를 복구 불가 실패로 보고 ("효과가 적용됐을 수 있으니 상태를 확인하라") | `lib/keeper/keeper_identity_tools.ml` |

명세 근거는 [MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
페이지다(원본: 명세 저장소 `docs/specification/2026-07-28/basic/patterns/mrtr.mdx`). 이 RFC 가
기대는 문장은 다음과 같다. 괄호의 번호는 페이지의 "Server Requirements (Basic Workflow)" 와
"Client Requirements (Basic Workflow)" 목록 번호이고, 뒤의 `:숫자` 는 원본 `mrtr.mdx` 의 줄이다.
원본은 모든 항목을 `1.` 로 적어서 번호가 소스에 보이지 않으니 줄로 찾는다.

- 서버는 server→client 요청을 MRTR 로 보내야 한다. 이 요구는 그런 요청을 보낼 때만 의미가 있다.
  (페이지 머리말)
- 서버는 클라이언트가 선언하지 않은 요청을 `inputRequests` 에 넣어서는 안 된다. (서버 7, :246)
- 서버는 `InputRequiredResult` 에 `inputRequests` 와 `requestState` 중 하나 이상을 넣어야 한다.
  (서버 6, :245)
- 서버는 들어온 `requestState` 를 공격자가 만든 입력으로 다루고, 결과에 영향을 주면 무결성을
  검증해야 한다. (서버 4, :232)
- `inputRequests` 가 없으면 클라이언트는 원래 요청을 바로 다시 보내도 된다. (클라이언트 1, :251-253)
  글자 그대로 읽으면 `requestState` 도 없는 결과에 붙는다. 그런 결과는 서버 6 을 어긴 것이고,
  그때 클라이언트가 할 일은 명세에 없다. D2 에서 정한다.
- 클라이언트는 `requestState` 를 있는 그대로 돌려줘야 하고, 없던 라운드에는 넣어서는 안 된다.
  (클라이언트 2, :254-255)
- 재시도의 JSON-RPC `id` 는 처음 요청과 달라야 한다. (클라이언트 3, :256)
- `requestState` 와 `inputRequests` 는 그 재시도 하나에만 쓴다. (클라이언트 4, :257)
- 서버는 클라이언트가 재시도할 것이라고 가정해서는 안 된다. (서버 8, :247)
- `InputRequiredResult` 를 보낼 수 있는 요청은 `tools/call`, `resources/read`, `prompts/get` 이다.
  ("Supported Requests" 표)

## 2. 결정

### D1. 서버 생산자를 만들지 않는다

서버가 server→client 요청을 보낼 일이 없고 capability 도 광고하지 않는다. 생산자를 만들면
쓰지 않는 코드와 서명·만료·재생 방지 같은 보안 의무만 생긴다.

서버는 지금 동작을 유지한다. 발급하지 않은 `requestState` 와 `inputResponses` 는 실행 전에 거부한다.
서버에 server→client 요청이 필요한 도구가 처음 생기면 이 RFC 를 갱신한다.

### D2. 클라이언트는 `requestState` 만 있는 라운드를 이어 간다

조건별 동작은 다음과 같다.

| 받은 결과 | 동작 |
|---|---|
| `inputRequests` 없음, `requestState` 있음 | 같은 도구·인자·`requestState` 로 새 id 를 달아 다시 보낸다 |
| `inputRequests` 있음 | 지금처럼 `Input_required` 실패. 클라이언트는 capability 를 선언하지 않으므로 서버가 보낸 `inputRequests` 는 명세 위반(서버 7)이다. 선언했더라도 `ElicitRequest`, `CreateMessageRequest`, `ListRootsRequest` 어느 것도 채울 수단이 없다 |
| 둘 다 없음 | 서버가 서버 6 을 어긴 경우다. 클라이언트 1 은 글자 그대로 읽으면 이때도 다시 보내도 된다고 하지만, 새 id 만 달아 같은 요청을 되풀이하는 셈이라 서버가 같은 답을 주면 마감까지 헛돈다. 그래서 `Malformed` 로 끝낸다. 명세가 정한 동작이 아니라 이 RFC 의 선택이다 |

### D3. 승인 한 번이 한 번의 호출 전체를 덮는다

이어 붙인 요청은 승인된 원본과 같은 도구와 인자다. 승인은 첫 전송 앞에서 한 번 쓰이고
라운드마다 새로 받지 않는다. 매 라운드 직전에 실제 도구 목록을 다시 받아, 승인할 때 묶어 둔
스키마와 읽기 전용 표시를 비교한다. 이 비교는 `resume_tool_with_state` 에 이미 있다.

이 결정이 가장 논쟁거리다. 라운드마다 승인을 받으면 사용자가 같은 일을 두 번 승인하고,
한 번만 받으면 서버가 라운드를 늘려서 얻는 권한이 없는지 봐야 한다. 라운드가 늘어도 도구와
인자가 같다는 점이 근거다.

### D4. 이어 붙이는 횟수에는 상한을 두지 않고, 호출 하나가 deadline 하나를 나눠 쓴다

횟수 상한은 `cap` 이라서 워크어라운드 거부 기준에 걸린다. 두지 않는다.

그렇다고 서버가 끝없이 라운드를 돌려주는 경우를 지금 코드가 끊어 주지는 않는다. 호출 시간 제한은
요청 하나에만 걸려 있다(줄 번호는 이 PR 의 트리 기준).

- `lib/mcp_client/mcp_client.ml:46`: "one window per request".
- `lib/keeper/keeper_identity_tools.ml:24-27`: "The bound is per request, not per call: ... one that
  answers each request inside the threshold runs the call to its end."
- 두 주석 모두 attempt watchdog 이 진행 중인 도구를 보지 않으므로 이 창이 호출의 유일한 생존 장치라고
  적는다(`mcp_client.ml:50-51`).

그래서 라운드마다 새 창이 열리고, 서버가 매 요청을 창 안에서 답하면 호출 전체 시간은 `라운드 수 × 문턱`
이 된다. 라운드 수는 서버가 정한다.

결정: 이어 붙이기는 첫 전송의 deadline 하나를 라운드 사이로 들고 간다. 첫 전송 시각에 문턱을 더한
시각을 이어 붙이기 전체의 경계로 삼고, 매 라운드에는 남은 시간을 넘긴다. 라운드 수에 상한이 없어도
호출은 유한하다. 호출 취소(Eio cancel)는 그대로 유효하다.

### D5. 선언하지 않는 것

- `sampling`: 외부 서버가 Keeper 의 모델 호출을 직접 일으킬 수 있게 된다. 비용과 권한 경계 때문에
  선언하지 않는다.
- `roots`: 작업 디렉터리 경로를 외부 서버에 알리게 된다. 선언하지 않는다.
- `elicitation`: 외부 서버가 사용자에게 질문을 보낼 수 있게 된다. 이 RFC 에서는 선언하지 않고,
  선언하려면 별도 RFC 를 쓴다. 그 RFC 가 풀어야 할 것은 Keeper 의 Ask 경로 연결, 요청 스키마
  검증, 응답을 원래 작업과 승인에 묶는 방법, URL 모드 제외다.

## 3. 이어 붙이기가 지켜야 할 것

1. 서버가 `InputRequiredResult` 를 실제로 돌려준 뒤에만 이어 보낸다. 전송 오류, timeout, 응답
   없음 뒤에는 이어 보내지 않는다. 응답이 오지 않은 요청이 서버에서 실행됐는지 알 수 없기
   때문이다. 보낸 뒤 재시도를 없앤 이유와 같다.
2. 라운드마다 새 JSON-RPC id 를 쓴다.
3. `requestState` 는 받은 문자열 그대로 돌려준다. 읽거나 바꾸지 않는다. 서버가 주지 않은
   라운드에는 필드를 넣지 않는다.
4. 상태는 이어 붙이는 요청 하나에만 쓴다. 같은 클라이언트의 다른 요청에 쓰지 않는다.
5. `requestState` 값은 로그와 영수증에 남기지 않는다. 라운드 수와 각 라운드의 요청 id 만 남긴다.
6. 취소되면 진행 중인 라운드에 `notifications/cancelled` 를 보내고 이어 붙이기를 멈춘다.
7. 이어 가지 못한 채 끝나면(취소, 서버가 더 이상 응답하지 않음) 지금의 Keeper 문구를 유지한다.
   "효과가 적용됐을 수 있으니 상태를 확인하라"는 뜻이다.
8. 이어 붙이기 전체가 첫 전송의 deadline 하나를 나눠 쓴다. 라운드마다 새 deadline 을 주지 않는다(D4).
9. 재시도도 새 요청이라 `_meta` 의 필수 필드(`protocolVersion`, `clientInfo`, `clientCapabilities`)를
   싣는다. 명세가 모든 요청에 요구한다.

## 4. 하지 않는 것

- 서버 쪽 생산자와 서버가 상태를 저장하는 것.
- 횟수 상한, 쿨다운.
- 재시작 뒤에도 이어 가는 저장. 이어 붙이기는 메모리 안에서 한 번만 쓴다. 재시작되면 그 호출은
  끝난 것으로 보고 위 7번 문구로 보고한다.
- Keeper 의 `Input_required` 턴 상태 변경. 이건 Keeper 가 운영자에게 묻는 별개의 개념이다.

## 5. 검증

가짜 MRTR 서버로 다음을 증명한다.

| 경우 | 기대 |
|---|---|
| `requestState` 만 있는 라운드 2번 뒤 완료 | 호출 하나가 결과를 돌려주고, id 가 모두 다르고, 상태가 정확히 그대로 간다 |
| `requestState` 가 없는 라운드 | 재시도에 `requestState` 필드가 없다 |
| `inputRequests` 가 있는 라운드 | 이어 붙이지 않고 `Input_required` 실패 |
| 둘 다 없는 라운드 | `Malformed` (D2. 명세에 없는 이 RFC 의 선택) |
| 라운드 중 전송 오류 | 이어 붙이지 않는다. 같은 라운드를 다시 보내지 않는다 |
| 라운드 중 취소 | `notifications/cancelled` 가 나가고 이어 붙이기가 멈춘다 |
| 라운드 중 도구 스키마 변경 | 보내기 전에 중단 |
| 승인 | 라운드 수와 상관없이 한 번 쓰인다 |
| 서버가 매 요청을 문턱 안에서 답하며 라운드를 끝없이 돌려줌 | 첫 전송의 deadline 이 지나면 호출이 실패로 끝나고 더 이어 보내지 않는다. 라운드마다 deadline 이 새로 열리지 않는다 |
| 재시도 요청 | `_meta` 의 필수 필드가 있다 |
| 로그와 영수증 | `requestState` 값이 없다 |

실제 서버와의 호환은 확인하지 못했다. `requestState` 라운드를 내는 공개 서버나 SDK 가 있는지
찾아보지 않았다. 확인 필요.

## 6. 열린 질문

- Q1. 이어 붙이기가 나눠 쓰는 deadline 의 길이. 첫 전송 + 문턱 하나로 정하면, 라운드마다 오래 걸리는
  정상 도구가 중간에 끊긴다. 문턱의 배수나 별도 설정이 필요한지 구현 전에 정한다.
- Q2. 라운드 수와 요청 id 를 Keeper 실행 영수증의 어느 필드에 남기는가.
- Q3. elicitation 을 선언할 시점과 운영자 화면 경로.

## 7. 근거 기록

- Evidence: [MCP 2026-07-28 MRTR](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/mrtr)
- Timestamp: 2026-10-27
- Confidence: 명세 문장 High(원문을 읽었다). 코드 사실 Medium(컴파일되지 않은 스택 위의 소스).
- 보강(2026-10-27): 서버 의무 6~8 과 클라이언트 의무 1~4 를 명세 저장소의 `mrtr.mdx` 원본 파일로 다시
  대조했다. D4 의 코드 주석은 이 PR 의 head 에서 읽었다.
- Delta: 이전 감사 문서는 "서버에 일반 MRTR 생산자가 없다"를 남은 필수 간극으로 적었다.
  서버 의무는 server→client 요청을 보낼 때만 걸리므로 간극이 아니다. 실제 간극은 클라이언트가
  `requestState` 만 있는 라운드를 호출 경로에서 이어 가지 않는 것이다.
