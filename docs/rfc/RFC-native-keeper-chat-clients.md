---
rfc: "native-keeper-chat-clients"
title: "macOS·iOS·Android 앱은 ATD 정의 하나에서 만든 타입으로 Keeper 대화를 읽는다"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: claude
related: []
---

# macOS·iOS·Android 앱은 ATD 정의 하나에서 만든 타입으로 Keeper 대화를 읽는다

- 상태: 초안.
- 계기: 2026-11-28 운영자가 macOS·iOS·Android 설치판을 빠르게 동작하게 만들고 싶다고 했다. 운영자가 정한 것은 다음과 같다.
  - 모바일 앱은 원격 클라이언트다. 서버는 지금처럼 Mac 에서 돈다.
  - 앱은 플랫폼별 네이티브로 만든다. SwiftUI 하나로 macOS·iOS 를, Jetpack Compose 로 Android 를 만든다.
  - 첫 버전 화면은 Keeper 대화 하나다.
  - 코드는 이 저장소 `apps/` 에 둔다.
  - 첫 버전은 시뮬레이터·에뮬레이터·로컬 실행에서만 쓴다.
  - 「빠르다」는 화면 반응, 앱 시작·연결, 배터리·알림, macOS 서버 자체를 뜻한다. 이 RFC 는 앞의 셋 가운데 첫 버전이 닿는 부분을 다룬다(§3).
- 먼저 있는 결정:
  - 대화 스트림은 AG-UI 모양의 SSE 다. frame 은 `type` 필드를 가진 평평한 JSON 객체다(`lib/ag_ui/ag_ui.ml:141`).
  - 끊긴 스트림은 같은 `request_id` 에 `since_seq` 를 주어 다시 POST 하면 이어진다. 서버는 이미 보낸 seq 를 다시 내지 않는다(`lib/server/server_routes_http_keeper_stream.ml:3527`). TUI 가 이 길을 쓴다(`lib/masc_tui/app/cmd_executor.ml:4239-4356`).
  - `MASC_HTTP_BASE_URL` 이 loopback 이 아니면 strict auth 가 켜진다(`docs/spec/09-server-transport.md:410-412`).
  - ATD 선례: `lib/sse_event/sse_event.atd` 는 dune 의 atdgen 으로 OCaml 을 만든다. TypeScript 는 `dashboard/scripts/gen-sse-types.sh` 가 만들고, `--check` 가 어긋남을 본다.
  - 성능 목표 `docs/PERFORMANCE-SLO.md`: SSE 연결 1초 미만, 이벤트 전달 P95 500ms 미만.
- 코드 좌표는 `origin/main` `43b3fb7eb7fa` 에서 읽었다. ATD 는 이 Mac 의 opam switch `5.5.2` 에 있는 4.2.0 이다.

## 읽기 전에 — 말의 뜻

- **앱**: `apps/apple/` 의 SwiftUI 앱(macOS·iOS 한 타깃)과 `apps/android/` 의 Compose 앱이다.
- **응답 정의**: `lib/keeper_chat_wire/keeper_chat_wire.atd` 다. 첫 버전 앱이 주고받는 JSON 의 모양을 적는다. 이 RFC 가 새로 만든다.
- **생성 타입**: 응답 정의에서 만든 코드다. OCaml 은 atdgen 이 만들고, Swift·Kotlin 은 `tools/atd-native-gen/` 이 만든다.
- **type-field variant**: payload 를 가진 variant 가 JSON 에서 `{"type": "<이름>", ...payload 필드}` 로 나오는 모양이다. atdgen 은 `<json adapter.ocaml="Atdgen_runtime.Json_adapter.Type_field">` 로 이 모양을 읽고 쓴다.

## 0. 요약

앱이 쓸 서버 길은 이미 있다. Worker bearer 하나로 Keeper 목록을 읽고, 대화를 보내고, 스트림을 받고, 끊기면 이어 받을 수 있다. 서버에 새 route 는 필요 없다.

문제는 응답 모양을 적은 정의가 없다는 데 있다.

- 지금은 서버 encoder 가 유일한 권위다.
- Dashboard(valibot)와 TUI(`lib/masc_tui/protocol/wire_fleet.ml`)는 같은 모양을 각자 손으로 다시 쓴다.
- 앱 둘이 같은 방식으로 붙으면 손으로 쓴 정의가 다섯 벌이 된다. 서버가 필드 하나를 바꾸면 다섯 곳을 맞춰야 하고, 빠진 곳은 실행 중에야 드러난다.

제안은 셋이다.

1. 첫 버전이 쓰는 모양을 ATD 파일 하나에 적는다. 서버 encoder 는 그 파일에서 atdgen 이 만든 타입으로 쓴다.
2. Swift·Kotlin 타입은 같은 파일에서 `tools/atd-native-gen/` 이 만든다. 기성 생성기는 AG-UI frame 의 실제 모양을 적지 못한다(§2 D2).
3. 앱 성능은 고정 입력으로 재고, 측정값은 앱 PR 본문에 증거로 남긴다. 숫자로 PR 을 막는 검사는 만들지 않는다(헌장 `build_and_ci`).

성공 기준은 셋이다.

- 서버 encoder 가 낸 fixture 를 OCaml·Swift·Kotlin 생성 decoder 가 모두 읽는다.
- 응답 정의와 커밋된 생성물이 어긋나면 기존 필수 검사 `type-check`(`dune build @check`)가 실패한다. 새 CI 작업은 더하지 않는다.
- 앱 PR 본문마다 D4 측정값과, 같은 fixture 로 잰 Dashboard 값이 있다.

## 1. 지금 동작

### 1.1 앱이 쓸 길

| 하는 일 | 길 | 필요한 권한 |
|---|---|---|
| Keeper 목록 | `GET /api/v1/gate/keepers?detailed=true` | `channel_gate` = CanBroadcast(`tool_catalog.ml:275`) |
| 지금 도는 턴·control token | `GET /api/v1/keepers/turns` | 공개 읽기 |
| 기록 한 쪽 | `GET /api/v1/keepers/:k/chat/history/page?limit=1..400&cursor=` | 공개 읽기(strict auth 에서는 읽기 credential) |
| 보내기와 스트림 | `POST /api/v1/keepers/chat/stream` | `masc_keeper_delegate` = CanBroadcast |
| 도는 턴 멈추기 | `POST /api/v1/keepers/turn/interrupt` | `masc_keeper_delegate_cancel` = CanBroadcast |
| 첨부 올리기 | `POST /api/v1/attachments` | CanBroadcast |
| 첨부 받기 | `GET /api/v1/attachments/<id>?max_px=160\|320\|640\|1280` | CanReadState |

- 기록 쪽의 schema 이름은 `masc.keeper_chat_history.page.v2` 다. cursor 는 opaque 이고, 낡은 cursor 는 409 다(`lib/server/server_dashboard_http_keeper_chat_history.ml`).
- `chat/stream` 본문은 모르는 key 를 거절한다(`server_routes_http_keeper_stream.ml:386-406`). 응답은 `retry: 1500`, 수락 frame, journal 재생, 실시간 frame 순서다. 30초 동안 조용하면 `: keepalive` 를 보낸다.
- `/chat/events` 는 턴의 추론 전문을 담아 CanAdmin 이다(`lib/server/server_dashboard_http_keeper_chat_operations.ml:21-24`). 앱은 이 길을 쓰지 않는다. 끊긴 답은 `since_seq` 로 이어 받는다.
- Worker 역할은 CanInit·CanReset·CanAdmin 만 없다(`lib/types/types_auth.ml:412-484`). 표의 길은 모두 Worker bearer 로 된다.
- `Origin` 이 없는 요청은 통과한다. `Host` 는 bind 주소나 `MASC_HTTP_BASE_URL` 과 같아야 하고, 다르면 400 `request_authority_untrusted` 다(`lib/server/server_request_authority.mli`).

### 1.2 응답 모양이 정해지는 곳

- 서버: 손으로 쓴 yojson encoder 다.
  - 기록 행: `lib/keeper/keeper_chat_projection.ml:299`
  - AG-UI frame: `lib/ag_ui/ag_ui.ml:141-174`
  - CUSTOM 이름 28개: `lib/server/server_keeper_chat_agui_projection.ml:53-81`
  - `KEEPER_ATTACHMENT` payload: 같은 파일 `:140-194`
  - 첨부 meta: `Attachment_store.meta_to_wire_json`
- 서버 안의 frame 타입 `Ag_ui.event` 는 `event_type` 하나와 option 필드 열네 개를 가진 record 다(`lib/ag_ui/ag_ui.ml:58-77`). `TEXT_MESSAGE_CONTENT` 에 `delta` 가 없는 값도 타입으로는 만들 수 있다.
- Dashboard: `dashboard/src/workspaces/keepers/keepers-api.ts`, `dashboard/src/api/schemas/keeper-chat-history.ts`(손으로 쓴 valibot).
- TUI: `lib/masc_tui/protocol/wire_fleet.ml:2668`(요청), `:3172`(기록 쪽), `:3464`(CUSTOM), `:3838`(스트림 조각). 손으로 쓴 decoder 다.
- `/api/v1/openapi.json`(`lib/transport.ml:353`)에는 대화·첨부 길이 없다. `proto/masc_workspace.proto` 는 agent gRPC 이고 대화가 아니다.

### 1.3 화면 성능

- Dashboard 대화는 가상화 없이 마지막 120~1000행을 그린다(`dashboard/src/workspaces/keepers/keeper-chat-tab.ts:158-159`, `:2462`). 이전 기록은 40행씩 버튼으로 더 읽는다.
- markdown 은 `marked` 와 DOMPurify 로 그리고, 결과를 256개 LRU 로 캐시한다.
- 대화 화면과 대화 스트림의 성능 시험은 없다.

## 2. 제안

### D1. 첫 버전이 쓰는 모양을 ATD 파일 하나에 적는다

`lib/keeper_chat_wire/keeper_chat_wire.atd` 에 다음만 둔다.

- Keeper 목록 행: 앱이 그리는 필드만 둔다(§5 Q1).
- 기록 쪽과 행.
- `chat/stream` 요청 본문. `admission_intent` 를 포함한다.
- AG-UI frame. type-field variant 이고, 이벤트 종류마다 그 종류의 필드만 가진다.
- 첫 버전이 그리는 CUSTOM 이벤트: 수락, `KEEPER_ATTACHMENT`, 오류. 나머지는 열린 variant 로 받는다(D2).
- 첨부 meta.

서버는 이 파일에서 atdgen 이 만든 타입으로 쓴다.

- 위 encoder 들의 손 yojson 은 지운다.
- `Ag_ui.event` 는 생성된 sum type 으로 바꾼다. 쓰는 곳은 `lib/` 아래 10개 파일, 65군데다. 종류마다 필요한 필드가 타입으로 강제되어, `delta` 없는 `TEXT_MESSAGE_CONTENT` 는 만들 수 없게 된다.
- wire 는 바뀌지 않는다. 표현을 바꾸기 전에 지금 encoder 가 내는 JSON 을 fixture 로 먼저 남긴다. 표현을 바꾸는 층은 그 fixture 가 그대로인지로 옛 encoder 와 새 encoder 를 비교한다.
  - 옛 encoder 를 남겨 두고 나란히 비교하지 않는다. 그러려면 새 frame 을 옛 record 로 바꾸는 이전용 코드가 생기고, 다음 층에서 바로 지워야 한다.
  - 비교 단위는 JSON 값이다. 객체 key 순서는 보지 않고, 수는 수로 비교한다. 빠진 option 은 key 가 없는 것으로 본다. 바이트는 지금처럼 transport 의 정규 JSON encoder(`Sse_wire.format_event_yojson`)가 쓴다.
  - 비교할 값은 표본이 아니라 만드는 곳 목록에서 뽑는다. 먼저 이벤트를 만드는 곳을 모두 frame 종류별 생성 함수로 옮긴다. 그러면 이벤트는 frame 종류마다 하나인 생성 함수로만 만들어진다. fixture 는 생성 함수마다 만드는 곳에서 나오는 option 조합을 모두 넣는다. 만드는 곳이 새로 생겨도 생성 함수를 거치므로 새 모양이 나오지 않는다. 만드는 곳 목록은 PR 본문에 둔다.
- 같은 fixture(`apps/fixtures/keeper_chat/`)를 각 언어의 생성 decoder 가 읽는지도 본다. 표현을 바꾼 뒤에는 이 protocol 경계 시험만 남는다.

단계 1 은 이 가운데 AG-UI frame 만 옮긴다. 나머지 모양은 단계 2 다(§4).

Dashboard·TUI 를 생성 타입으로 옮기는 일은 이 RFC 밖이다(§3).

### D2. Swift·Kotlin 타입은 `tools/atd-native-gen/` 이 만든다

2026-11-28 실험(ATD 4.2.0):

| 도구 | type-field variant 를 어떻게 적나 | AG-UI wire 와 같나 |
|---|---|---|
| atdgen + `Type_field` adapter (OCaml) | `{"type":"RUN_STARTED","threadId":…}` | 같다 |
| `atdcat -jsonschema` | `["RUN_STARTED", {…}]` 배열(`prefixItems`) | 다르다 |
| `atdts` | `['RUN_STARTED', …]` 배열을 읽고 쓴다 | 다르다 |

- adapter 는 OCaml 전용이다. `atd` 의 JSON annotation 이 아는 adapter 는 `adapter.ocaml` 과 `adapter.java` 뿐이다(`atd/json.ml`).
- 그래서 JSON Schema 를 거치는 기성 생성기는 실제 wire 와 다른 타입을 만든다. AG-UI 는 바깥 규격이라 wire 를 배열 모양으로 바꿀 수 없다.

`tools/atd-native-gen/` 은 OCaml `atd` 라이브러리로 `.atd` AST 를 읽어 Swift·Kotlin 을 낸다.

- 다루는 범위: record, option, list, enum, `<json name>`, type-field variant.
  - Swift 는 associated value 를 가진 `enum` 과 `Decodable` 구현이다.
  - Kotlin 은 `sealed interface` 와, `"type"` 을 먼저 읽고 그 종류의 `@Serializable` record 로 읽는 `DeserializationStrategy` 다. 열린 variant 의 `Unrecognized(name, raw)` 도 이 함수가 만든다.
  - 단계 1 의 생성물은 읽기만 한다. 앱이 보내는 요청 본문은 단계 2 에서 쓰기(Swift `Encodable`)와 `nullable` 을 더한다.
- 열린 variant: 앱은 서버보다 늦게 업데이트되므로, 모르는 이름을 받아도 decode 가 실패하면 안 된다.
  - type-field variant 에 생성기 전용 annotation `<native open>` 을 붙이면, 생성기가 `unrecognized(name, raw)` 경우를 더한다. 앱은 이 경우를 기본값으로 바꾸지 않고 「이 앱이 모르는 이벤트」로 보인다.
  - ATD 의 `<json open_enum>` 은 payload 없는 enum 에만 쓸 수 있어 이 자리에 맞지 않는다.
  - atdgen 은 모르는 annotation 절을 무시한다. ATD 4.2.0 에서 `<native open>` 을 붙인 파일로 `atdgen -t`·`-j` 가 그대로 통과했다. 서버는 이 variant 를 쓰기만 하므로 OCaml 쪽 동작은 바뀌지 않는다.
- 그 밖의 annotation 은 생성을 거절한다. 다른 adapter, 다른 field name 의 `Type_field.Param` 이 여기에 든다. 모르는 모양을 비슷한 모양으로 바꿔 내지 않는다.
- 생성물은 `apps/apple/MascWire/Generated/`, `apps/android/wire/src/main/kotlin/masc/wire/generated/` 에 커밋한다. Swift·Kotlin 은 dune 이 빌드하지 않기 때문이다.
- 어긋남 검사는 dune rule 로 둔다. 생성기를 돌린 결과를 커밋본과 `diff` 하는 rule 을 `@check` alias 에 붙인다. 그러면 지금 도는 `type-check` 가 이 검사를 같이 한다. 응답 정의만 바꾸고 생성물을 다시 만들지 않으면 `type-check` 가 실패한다.

### D3. 앱은 Worker bearer 와 `chat/stream` 하나로 대화한다

- 처음 실행할 때 사람이 서버 URL 과 token 을 넣는다. token 은 `masc login --agent <기기 이름> --role worker` 로 만든다.
- token 은 Keychain(Apple)과 Keystore 키로 암호화한 DataStore(Android)에 둔다.
- 보내기와 스트림은 `POST chat/stream` 하나다.
- 앱은 CanAdmin 이 필요한 길을 쓰지 않는다.
- 첫 버전이 실시간으로 받는 턴은 앱이 보낸 턴뿐이다. TUI·Dashboard 가 시작한 턴은 대화를 열 때와 앱이 앞으로 돌아올 때 기록 쪽을 다시 읽어 보인다. 다른 곳에서 턴이 도는지는 `GET /api/v1/keepers/turns` 로 안다. 그런 턴을 실시간으로 따라가는 일은 §5 Q4 다.

#### 이어 받기

서버가 지키는 사실:

- 같은 `request_id` 로 다시 POST 하면, 서버는 그 operation 을 알 때만 journal 을 `since_seq` 뒤부터 다시 보낸다(`server_routes_http_keeper_stream.ml:3798-3812`, `acceptance.existing`). 새 턴은 시작하지 않는다.
- 서버가 모르는 operation 이면 `since_seq` 를 무시하고 처음 제출로 받는다.
- 다시 보낸 본문의 admission 이 처음과 다르면 `Idempotency_conflict` 로 거절한다(`keeper_chat_operation_store.ml:1521-1524`, `admission_digest`).
- journal 은 운영자 보존 일수(`Server_maintenance_toml_config.resolve_retention_days`)가 지나면 서버가 시작할 때 지운다.
- journal 쓰기가 실패한 이벤트는 실시간으로만 나가고, 더 높은 seq 뒤에 올 수 있다(`live_event_is_new` 위 주석).

그래서 앱은 다음과 같이 한다.

- 보낼 때 operation 하나를 디스크에 먼저 적는다. 적는 것은 Keeper 이름, `request_id`, 보낸 본문 원문, 받은 seq 집합이다. 수락 frame 을 받으면 그 사실도 적는다. 턴이 끝난 frame(`RUN_FINISHED`·`RUN_ERROR`)을 받으면 지운다.
- 중복은 seq 순서가 아니라 seq 집합으로 거른다. 위 다섯째 사실 때문이다.

| 상황 | 하는 일 |
|---|---|
| 스트림만 끊김, 앱은 살아 있음 | 저장한 본문 원문을 그대로, `since_seq` = 받은 가장 큰 seq 로 다시 POST |
| 앱이 뒤로 갔다 돌아옴 | 위와 같다 |
| 앱이 종료된 뒤 다시 켬, 수락 frame 을 받았던 operation | 먼저 `GET …/:k/chat/operations/:id` 로 서버가 아는지 본다. 알면 위와 같이 다시 POST 한다 |
| 그 조회가 `Unknown_operation` | 다시 POST 하지 않는다. 다시 보내면 새 턴이 되어 같은 말을 두 번 보내게 된다. 기록 쪽을 다시 읽고, 「보낸 것으로 확인되지 않음」을 그 메시지에 보인다 |
| 앱이 종료된 뒤 다시 켬, 수락 frame 을 못 받은 operation | 위 조회로 정한다. 알면 다시 POST 하고, 모르면 「보내지 않음」으로 보이고 사람이 다시 보내게 둔다 |
| 다시 POST 했는데 재생이 비고 스트림이 닫힘 | journal 이 이미 지워졌을 수 있다. 기록 쪽을 다시 읽고 message id 로 화면과 맞춘다 |
| `Idempotency_conflict` | 원문을 그대로 보내므로 나오면 앱 버그다. 오류로 보이고 다시 시도하지 않는다 |
| 401(token 거절) | 다시 시도하지 않는다. 서버 URL·token 입력 화면으로 간다 |
- Android 에뮬레이터는 `adb reverse tcp:8935 tcp:8935` 로 `127.0.0.1:8935` 에 붙는다. `10.0.2.2` 로 붙으면 `Host` 가 bind 주소와 달라 400 이다.

### D4. 성능은 고정 입력으로 재고, 값은 PR 본문에 남긴다

- 입력: 측정 target 안의 가짜 서버가 fixture 를 정해진 속도로 낸다.
  - 기록: 1만 행
  - 스트림: delta 초당 50개, 긴 답 하나
  - 이미지 행: 20개
- 재는 것:

  | 무엇 | Apple | Android |
  |---|---|---|
  | 첫 화면까지 | `XCTApplicationLaunchMetric` | Macrobenchmark `StartupTimingMetric` |
  | 스크롤 끊김 | `XCTOSSignpostMetric` scroll | `FrameTimingMetric` |
  | frame 을 받고 글이 보이기까지 | signpost 구간 | trace section |

- 측정은 손으로 돌리는 target 이다(`xcodebuild test -only-testing:MascPerf`, `gradle :macrobenchmark:connectedCheck`). 통과·실패를 숫자로 가르는 검사로 만들지 않는다.
  - 헌장 `build_and_ci` 는 기능 고장과 이어지지 않는 숫자 검사를 만들지 않게 한다. PR 마다 도는 검사를 운영자 요청 없이 늘리지도 못하게 한다.
  - 같은 헌장 규칙과 `docs/guides/WORKSPACE-STORAGE.md` 에 따라, 측정값은 저장소에 커밋하지 않고 그 앱 PR 본문에 남긴다. 조건(기기, OS, fixture, 빌드 설정)을 같이 적는다.
- 비교 기준으로 같은 fixture 를 Dashboard 에서 Playwright 로 한 번 잰다. 「Dashboard 보다 얼마나 빠른가」를 같은 입력으로 말하기 위해서다.
- 시뮬레이터·에뮬레이터 값은 실기기 값이 아니다. 첫 버전 값은 이 Mac 에서 앞 PR 과 비교하는 데만 쓴다. 실기기 값은 실기기 배포 RFC 에서 다시 잰다.

### D5. 앱 화면 규칙

- 앱을 열면 마지막 Keeper 목록과 Keeper 별 마지막 기록 쪽을 디스크 캐시에서 먼저 그린다. 서버 응답이 오면 바꾼다.
- 대화 목록은 stable id 를 가진 lazy 목록(`LazyVStack`, `LazyColumn` + key)으로 그린다.
- markdown 은 끝난 메시지만 main thread 밖에서 한 번 바꾼다. 스트리밍 중인 메시지는 delta 를 화면 한 frame 에 한 번 모아 붙인다. token 마다 layout 을 다시 하지 않는다.
- 이미지는 보일 크기 × 화면 배율에 맞는 `max_px` 파생본을 받는다. ETag 로 캐시한다.
- SSE 는 앱이 앞에 있고 턴이 도는 동안만 연다. 뒤로 가면 닫고, 돌아오면 `since_seq` 로 이어 받는다. 주기적으로 묻지(polling) 않는다.

## 3. 하지 않는 것

- 기기 안에서 서버 돌리기. iOS 는 Docker·Apple Container·VM 을 돌리지 못한다.
- 푸시 알림. APNs·FCM 발신자는 `Server_observation_input.subscribe` 에 붙일 수 있어 보이지만, 다음 RFC 에서 다룬다.
- 기기 페어링(QR, 범위를 좁힌 token, 갱신).
- 게시판, 리뷰, 서버 관리 화면.
- macOS 앱이 서버를 품는 일(시작·업데이트·메뉴 막대). 서버 시작 시간은 이 RFC 밖에서 다룬다(#55235).
- macOS 시스템 통합: 알림 센터, 메뉴 막대, 단축어(App Intents), Spotlight, 공유. 2026-11-28 운영자가 바란다고 했다. 첫 버전 대화 화면이 자리 잡은 뒤 다음 RFC 에서 다룬다.
- 실기기 설치와 TestFlight. 이 Mac 에는 코드 서명 인증서가 없다.
- Dashboard·TUI 를 생성 타입으로 옮기기. D1·D2 가 자리 잡은 뒤 따로 한다.

## 4. 단계

헌장 `execution_protocol` 대로 native stack 으로 쌓는다.

- 단계마다 main 위의 새 스택으로 시작한다. 앞 단계 스택이 main 에 들어간 뒤에 연다.
- 각 스택은 맨 위 PR 로 한 번에 병합한다. 단계 1 은 이 RFC 가 맨 아래 층이다.
- 2026-11-28 운영자가 단계 1 을 AG-UI frame 과 생성기로 닫고, 나머지 응답 모양을 단계 2 로 나누기로 했다. 아래 층을 고칠 때마다 위 층을 다시 쌓는 일을 줄이기 위해서다.

1. **AG-UI frame 과 생성기**
   - 층 1-a: ATD 파일과 atdgen rule. 서버 encoder 는 아직 그대로 둔다.
   - 층 1-b: frame 종류마다 타입 있는 생성 함수를 두고, 이벤트를 만드는 곳을 모두 옮긴다. `make_event` 는 공개 interface 에서 뺀다. 표현과 encoder 는 그대로 둔다.
   - 층 1-c: 지금 encoder 로 fixture(`apps/fixtures/keeper_chat/*.json`, `*.sse`)를 만들고, 서버 출력이 fixture 와 같은 JSON 값인지 보는 테스트를 둔다.
   - 층 1-d: 서버 표현을 생성 타입으로 바꾸고 손으로 쓴 encoder 를 지운다. 1-c 의 fixture 는 그대로여야 한다.
   - 층 1-e: `tools/atd-native-gen/` 의 Swift 출력, `apps/apple/MascWire` 생성물, `@check` 어긋남 rule.
   - 층 1-f: Kotlin 출력. inherit 으로만 쓰이는 record 는 쓰지 않는다.
   - 층 1-g: `apps/android/wire` 생성물과 어긋남 rule.
   - 확인: 대상별 `dune build --root .`, fixture 비교 테스트, 생성기 거절 테스트(모르는 annotation, 두 언어가 담지 못하는 이름), Swift·Kotlin 생성물의 fixture decode(로컬 `swift test`·`gradle :wire:test`), 기존 Dashboard·TUI 테스트 통과.
2. **나머지 응답 모양**
   - 대상: 기록 쪽과 행, `chat/stream` 요청 본문, 첨부 meta, 첫 버전이 그리는 CUSTOM payload(수락, `KEEPER_ATTACHMENT`, 오류), Keeper 목록 행(§5 Q1 측정 뒤).
   - 모양마다 단계 1 과 같은 순서로 간다. 지금 출력을 fixture 로 남기고, 서버 표현을 생성 타입으로 바꾸고, 생성물을 다시 만든다.
   - 기록 행은 최상위 field 가 스무 개쯤이다. `blocks`·`surface`·`speaker`·`approval_lifecycle` 은 각자 encoder 가 있다. 앱이 그리지 않는 하위 값은 ATD 에서 `json` 으로 두고, 그 값을 만드는 모듈이 계속 쓴다. Dashboard·TUI 가 읽는 바이트는 바뀌지 않는다.
   - 요청 본문: 서버 parser 는 모양을 읽은 뒤 trim, 빈 값, 연결 문맥 조건을 본다. 생성 reader 는 모양만 읽고, 그 뒤 검사는 그대로 둔다. 거절 문구가 바뀌는지는 fixture 로 본다.
   - 확인: 단계 1 과 같다.
3. **Apple 앱 v1**
   - 확인: `xcodebuild test`(iOS 26.5 시뮬레이터, macOS), fixture decode, D4 측정.
   - 실서버 확인: 로컬 서버에 Worker token 으로 붙어 보내기, 스트리밍, 끊긴 뒤 이어 받기, 이미지.
4. **Android 앱 v1**
   - 확인: `gradle test`, 에뮬레이터 `connectedCheck`, D4 측정, 같은 실서버 확인.

앱 빌드·테스트를 CI 에서 돌릴지는 운영자가 정한다(§5 Q3). 정하기 전에는 앱 PR 본문에 로컬 결과를 남긴다.

## 5. 열린 질문

- **Q1. Keeper 목록 크기.** `detailed=true` 응답은 `masc_keeper_list` 도구 출력을 그대로 담는다(meta, 최근 턴, portrait). 앱 시작을 늦출 만큼 큰지 먼저 잰다. 크면 앱이 그리는 필드만 담은 목록 projection 을 따로 둔다.
- **Q2. 기록 쪽 응답 압축.** `json_value ~compress:true` 를 쓰는 route 가 있다. 기록 쪽도 쓰는지, 터널 너머에서 몇 바이트인지 잰다.
- **Q3. 앱 CI 작업.** 헌장은 PR 마다 도는 검사를 운영자 요청 없이 늘리지 않게 한다. 앱 빌드·테스트를 CI 에서 돌리려면 운영자가 정해야 한다.
  - 정한다면 `apps/apple/**` 는 macOS runner, `apps/android/**` 는 Ubuntu runner 에서 돈다. 각 작업은 그 경로가 바뀐 PR 에서만 돈다.
  - macOS runner 는 Linux runner 보다 비싸다.
  - 생성물 어긋남 검사는 이 질문과 상관없다. 이미 도는 `type-check` 안에서 돈다(D2).
- **Q4. 다른 곳에서 시작한 턴 따라가기.** Dashboard 는 observer 스트림(`/mcp?sse_kind=observer`, 다중 계정에서는 `/api/v1/auth/events`)으로 모든 대화 operation 의 AG-UI 이벤트를 받는다(`dashboard/src/core/observer.ts`). 앱이 이 스트림을 쓰면 TUI·Dashboard 가 시작한 턴도 실시간으로 보인다.
  - 대신 앱이 앞에 있는 동안 연결 하나를 늘 열어 둔다.
  - Worker token 으로 열리는지, 다시 붙을 때(`Last-Event-ID`, `observer_resync_required`) 무엇을 다시 읽어야 하는지 확인한 뒤 정한다.
- **Q5. AG-UI 1.0 과 얼마나 맞출지.** 2026-11-28 `docs.ag-ui.com/spec/1.0` 을 읽었다. 서버의 `Ag_ui.protocol_version` 은 `"0.1.0"` 이고 부르는 곳이 없다.
  - 1.0 의 HTTP SSE binding 에는 이어 받기가 없다. SSE `id:` 는 무시하라고 하고, 끊긴 스트림은 새 `runId` 로 다시 시작하게 한다(`spec/1.0/basic/transports/http-sse.md` 「No resumption」). masc 의 `id: <journal seq>` 와 `since_seq` 이어 받기(D3)는 이 binding 밖의 확장이다. 앱은 뒤로 갔다 돌아올 때 이 확장이 필요하다.
  - 1.0 schema 에서 생성한 SDK 는 TypeScript·Python·.NET 이다(`migrating-to-1-0.md`). Kotlin SDK 는 community 이고(`introduction.md`), Swift SDK 는 없다. 앱 쪽 타입은 D2 생성기가 계속 만든다.
  - 1.0 표준 이벤트와 뜻이 겹쳐 보이는 CUSTOM 이 있다. `KEEPER_THINKING_*` 와 `REASONING_*`, `KEEPER_TOOL_RESULT_READY` 와 `TOOL_CALL_RESULT`, `KEEPER_NATIVE_TOOL_*` 와 `ACTIVITY_*` 가 후보다. 뜻이 정확히 같은지는 아직 보지 않았다. 바꾸면 Dashboard·TUI 가 읽는 wire 가 바뀌므로 따로 정한다.
  - 단계 2 의 기록 쪽을 1.0 `MESSAGES_SNAPSHOT` 모양의 projection 으로 줄 수도 있다. 메시지가 role 별 union 이고 이미지 ContentPart 가 있다. 대신 cursor 가 없고, masc 행의 `turn_ref`·delivery provenance·승인 상태는 담지 못한다. 단계 2 를 시작할 때 기록 행을 그대로 옮기는 안과 비교한다.
