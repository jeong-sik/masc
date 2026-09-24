---
rfc: "browser-lane-stagehand"
title: "Add a Stagehand target to Browser Lane"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: vincent + claude
related: []
---

# RFC — Browser Lane 에 Stagehand target 을 더한다

## 1. 문제

지금 Keeper 가 브라우저에서 무언가를 누르려면 두 번 움직인다.
먼저 `BrowserRead` 로 요소 목록이나 scene 을 받는다.
그다음 그 안에서 selector 나 `nodeId` 를 직접 골라 `BrowserInteract`·`BrowserAct` 에 넘긴다.
요소 목록은 Keeper 모델 입력에 그대로 들어간다.
페이지가 클수록 입력이 커지고, 요소 하나 고르는 일에 Keeper 의 모델을 쓴다.

Browser Lane 은 Firefox 만 다룬다 (`docs/design/browser-lane.md`).
`live` 는 운영자의 Firefox/Zen 확장이고, `automation` 은 geckodriver 로 띄운 Firefox 다.
Chromium 에서만 제대로 도는 사이트는 볼 수 없다.

Stagehand v4 는 "무엇을 할지" 문장을 받아 accessibility tree 에서 요소를 고르고 실행한다 (`act`).
찾기만 하는 `observe`, 스키마 모양 JSON 을 돌려주는 `extract` 도 있다.
요소 고르기와 추출은 Stagehand 가 부르는 별도 모델이 맡는다.

`docs/research/2026-09-09-browser-composition-patterns.md` 는 Stagehand 를
"Lane 안에서 같은 fixture 로 비교할 후보" 로 적었다.
비교하려면 먼저 Lane 안에 Stagehand 가 있어야 한다.

가설은 이렇다. 요소 고르기와 추출을 Keeper 턴 밖으로 빼면 Keeper 가 받는 바이트와 도구 왕복이 준다.
아직 잰 적은 없다. 이 RFC 는 그 가설을 잴 수 있는 구조를 만든다.
성능 이야기는 §6.3 측정 뒤에만 한다.

## 2. 확인한 사실

2026-09-24 에 SDK 없이 CDP 만으로 Stagehand 확장을 움직여 봤다.
증거는 `docs/evidence/browser-stagehand-cdp-20260924/` 에 있다.

| 항목 | 결과 |
|---|---|
| 브라우저 | Chrome Canary 156, `--headless=new`, 새 profile |
| 확장 | `@browserbasehq/stagehand@4.1.0` 의 `dist/extension`, `protocolVersion 2.0.0` |
| 확장 올리기 | `--remote-debugging-port` websocket 에서 `Extensions.loadUnpacked` 가 받아졌다 |
| 확장 id | 확장 폴더 실제 경로의 SHA-256 앞 32자를 `a-p` 로 바꾼 값. 실행 전에 계산한 값과 Chrome 이 준 값이 같았다 |
| 준비까지 | 실행부터 런타임 준비 표식까지 0.6–7.1 s (그날 7번, 첫 실행이 가장 느렸다) |
| `stagehand.init` | `model: {source: "client"}` 와 `browser_cdp_url` 을 준다. 확장이 그 주소로 websocket 을 직접 연다 |
| Origin | `--remote-allow-origins` 가 없으면 `init` 이 `CDP websocket failed to open` 으로 실패한다. `chrome-extension://<id>` 하나만 허용하면 끝까지 된다 |
| `stagehand.extract` | host 가 `llm.generate` 를 두 번 받는다. 추출 스키마 하나, 진행 여부 스키마 하나 |
| `stagehand.act` | `llm.generate` 한 번 (4.8 KB, `[0-18]` 같은 id 가 붙은 accessibility tree). 답을 주면 실제로 클릭된다 |
| 로컬 캐시 | `cache.status = DISABLED`. 캐시는 Browserbase 서버에서만 된다 |

이 확인에서 LLM 답은 고정된 stub 이었다. 실제 모델의 요소 선택 품질은 재지 않았다.

Stagehand 쪽 사실:

- SDK 와 확장은 버전이 붙은 JSON-RPC 로 말한다 (`packages/protocol/stagehand.v4.json`).
  Go·Python SDK 도 이 스키마에서 생성된다. `protocolVersion` 은 SemVer 이고 major 가 바뀌면 호환이 깨진다.
- 확장→host 메시지는 service worker 의 `Runtime.addBinding("__stagehandSendToHost")` 로 온다.
  host→확장 메시지는 `Runtime.evaluate` 로 `globalThis.__stagehandReceiveFromHost(<json>)` 를 부른다
  (`packages/sdk-go/cdp_client.go`).
- `model: {source: "client"}` 이면 모든 LLM 호출이 `llm.generate` 요청으로 host 에 온다.
  API 키가 브라우저에 들어가지 않는다.
- 확장은 받은 `structured_content` 를 자기 Zod 스키마로 다시 검사한다
  (`dist/extension/service-worker.js` 의 `schema.parse(response.structuredContent)`).
  모양이 틀리면 `act`·`extract` 호출이 오류로 끝난다.
- 확장은 Chrome 전용이다. Firefox 는 CDP `Extensions` 도메인이 없다.
  Lightpanda 도 같은 이유로 문서에서 Stagehand 를 3.x 에 고정했다 (lightpanda-io/docs#106).
- 2025년 자료에는 `Extensions.loadUnpacked` 가 `--remote-debugging-pipe` 에서만 된다고 적혀 있다.
  Canary 156 에서는 websocket 으로 됐고, Stagehand Go SDK 도 websocket 을 쓴다.
  버전에 따라 다를 수 있어서 CI 는 Chrome for Testing 으로 고정한다 (§6.2).

## 3. 결정

### 3.1 target, route, lane 이름

`Browser_lane` 에 세 번째 target 을 더한다.

```ocaml
type target = Automation | Live_client of client | Stagehand
type route = Automation_route | Live_route of client_id option | Stagehand_route
```

도구 입력의 `lane` 값은 `"stagehand"` 다.
이름을 `chromium` 이 아니라 `stagehand` 로 둔다. 동사에 답하는 것이 Stagehand 런타임이기 때문이다.
Stagehand 없이 Chromium 만 모는 target 은 이 RFC 에 없다.

#38664 에서 도구 입력, source, observation, screenshot, lane addon 의 lane 이름을
`Browser_lane.Lane_name` 으로 모았다. 이 타입은 현재 `Live | Automation` 과
`of_wire`·`to_wire` 를 가지며, 도구 TOML 의 enum 도 테스트가 이 파서로 확인한다.
client id 규칙은 자리마다 달라 lane 이름만 공유한다. Stagehand 생성자를 더하면
각 타입 패턴매치가 새 경우를 짚는다. TUI source 와 도구 enum 도 함께 갱신한다.

7번에서 도구 입력을 바꾼다.
- 도구의 `lane` enum 에는 그 lane 의 backend 가 도구의 기본 동사를 받을 때만 이름을 넣는다.
  `test_browser_lane_name` 이 `Browser_lane.verb_allowed` 로 이것을 확인한다.
  stagehand 는 `BrowserTabs`·`BrowserRead`·`BrowserInteract`·`BrowserSession`·`BrowserGoto` 에 있고, `BrowserAct` 에는 없다.
- `BrowserAct` 는 automation 만 받는다. 코드가 `lane` 없는 입력에 쓰는 기본값도 스키마의 기본값(automation)과 같다.
- `BrowserSession`·`BrowserGoto` 는 `lane`(automation·stagehand, 기본 automation)을 받는다.
  서버가 가진 lane 은 닫힌 타입 `Browser_lane.server_lane` 으로 읽어서 `lane:"live"` 는 입력 오류로 거절한다.
  대시보드의 `/browser-lane/session`·`/goto` 도 같은 타입을 쓰고, lane 을 꼭 받는다.
- 실행기가 없을 때(`Lane_absent`) 문구는 lane 마다 필요한 설정을 말한다.

### 3.2 동사

기존 동사는 이름을 그대로 쓰고, Stagehand 프로토콜 메서드에 연결한다.

| 기존 동사 | Stagehand 메서드 |
|---|---|
| `Session_open` / `Session_close` / `Session_status` | Chromium 실행 + `stagehand.init` / `stagehand.close` + 종료 / backend 기록 |
| `Tabs_list` | `context.pages` + `context.active_page`. `PageRef` 에는 active 가 없어서 둘을 합친다 (`Browser_surface.decode_tab` 이 요구) |
| `Page_goto` | `page.goto` |
| `Page_capture` | `page.screenshot` |
| `Page_read`, `Page_scene`, `Page_elements` | `page.evaluate` 로 지금 스크립트를 돌린다. 아래 참고 |
| `Page_interact` | `locator.click`·`locator.fill`·`page.click`(좌표)·`page.scroll`·`page.drag_and_drop` |
| `Page_act` | 대응 메서드가 있는 action 만. 없는 것은 거절 |
| `Page_document`, `Page_downloads`, `Page_context` | 첫 단계에서는 거절 |

`Browser_scene_script` 와 `Browser_page_script` 는 WebDriver `execute` 규칙으로 쓰여 있다.
맨 위에 `return` 이 있고 `arguments[0]` 을 읽는다.
Stagehand 의 `page.evaluate` 는 `{page_id, expression}` 만 받는다.
그래서 BiDi peer 가 이미 하는 방식(`browser_bidi_peer.ml:19-23`)으로 감싼다.
스크립트 본문을 함수로 감싸고, 인자를 JSON 리터럴로 넣어 즉시 부르고, 결과를 `JSON.stringify` 한다.
scene·elements 를 같은 스크립트로 읽으면 Keeper 가 보는 관찰 형식이 target 마다 갈리지 않는다.

Stagehand target 에서만 받는 동사를 셋 더한다.

```ocaml
| Page_instruct of { tab_id : int; instruction : string }                                (* stagehand.act *)
| Page_locate of { tab_id : int; instruction : string option }                           (* stagehand.observe *)
| Page_extract of { tab_id : int; instruction : string; schema : Yojson.Safe.t option }  (* stagehand.extract *)
```

`verb_allowed_on_live` 처럼 `verb_allowed_on_stagehand` 를 둔다.
`_ ->` 없이 동사마다 true/false 를 적는다. 받지 않는 동사는 `Rejected_before_effect` 로 돌아간다.
`live`·`automation` 은 새 세 동사를 받지 않는다.

masc 동사의 `tab_id` 는 정수이고 Stagehand 의 `page_id` 는 문자열(CDP target id)이다.
backend 가 둘을 잇는 표를 세션 상태로 든다. 한 번 준 번호는 다시 쓰지 않고, 표에 없는 `tab_id` 는 거절한다.

### 3.3 CDP 연결과 JSON-RPC

Node sidecar 없이 OCaml/Eio 가 직접 붙는다. 모듈은 둘이다.

`Browser_cdp` 는 `ws-direct` 로 CDP websocket 을 연다.
ws-direct 는 조각난 메시지를 다시 합치고, `max_message` 를 호출하는 쪽이 정하고, Origin 헤더를 보내지 않는다.
이번 일로 ws-direct 를 고칠 곳은 없다.
`Browser_bidi_peer.with_connection` 은 재사용하지 않는다.
그 함수는 BiDi 봉투만 읽고 이벤트를 버리며, 한 번의 `use` 호출 동안만 산다.
여기서는 `Runtime.bindingCalled` 이벤트가 RPC 통로 자체라 이벤트를 버리면 안 된다.

- 연결은 세션이 가진다. 세션 switch 위에서 읽기 fiber 가 돈다.
- CDP 봉투는 닫힌 타입으로 읽는다: `Reply of { id; session; result }`, `Event of { method_; session; params }`.
- CDP 명령마다 deadline 을 둔다. 브라우저가 명령에 답하지 않는 것은 자원 경계라서다.
  deadline 이 지나면 BiDi 와 같이 연결을 끝낸다. 답을 모르는 명령 뒤에 다른 명령을 쓰지 않는다.
- websocket 이 끊기면 기다리던 CDP 명령은 `Connection_lost`, 기다리던 RPC 는 `Lost` 로 끝낸다.

`Stagehand_rpc` 는 그 연결 위에서 service worker 를 붙잡고 JSON-RPC 를 주고받는다.
순서는 Go SDK 와 같다: `Extensions.loadUnpacked` → 실행 전에 계산한 id 와 비교 →
service worker 찾기 → `Target.attachToTarget {flatten: true}` → `Runtime.enable` →
`Runtime.addBinding` → 준비 표식 확인 → `stagehand.init`.

- service worker 는 로드한 뒤 `Target.getTargets` 를 0.1초마다 불러 찾는다. 확장 origin
  (`chrome-extension://<id>`, `Uri` 의 scheme·host 로 비교)에서 뜬 service worker 만 받는다.
  `targetCreated` 를 기다리면 이전 로드의 worker 를 잡을 수 있어서다. 기다리는 시간은 `worker_wait_s` 로 끝이 있다.
- 준비 표식은 host 가 0.1초마다 읽는다. receiver 가 함수이고 marker 가 있어야 준비된 것이다(runtime 은 receiver 를 먼저 설치한다).
  CDP 가 service worker 에서 평가하는 곳에는 `setTimeout` 이 없어서, 페이지 안에서 기다리는 식은 거절된다
  (증거 `run-readiness-in-service-worker.txt`). 답에 `exceptionDetails` 가 있으면 값이 아니라 실패로 읽는다.
- `init` 이 답하기 전(`Initialising`)에는 `init` 말고 다른 호출을 받지 않는다.
- attach 가 어느 단계에서 실패하든 세션은 끝난다. 확장이 이미 올라갔거나 `init` 을 보냈을 수 있어서 다시 attach 하지 않는다.

```ocaml
type extension_request =
  | Llm_generate of { id : id; params : Yojson.Safe.t }
  | Unsupported_request of { id : id; method_ : string }

type extension_notification =
  | Log of Yojson.Safe.t option
  | Page_event of Yojson.Safe.t option
  | Unsupported_notification of { method_ : string }
```

- `Llm_generate.params` 는 이 단계에서 JSON 으로 두고, §3.6 에서 경계를 넘을 때 타입으로 읽는다.
- `Unsupported_request` 는 JSON-RPC `-32601` 로 답하고 로그를 남긴다. 조용히 넘기지 않는다.
- 알림의 `params` 가 없으면 없다고 둔다. `llm.generate` 에 `params` 가 없으면 잘못된 메시지다.
- 준비 표식의 `protocolVersion` major 가 클라이언트가 구현한 major 와 다르면
  `Runtime_incompatible { found; supported }` 로 세션 열기를 실패시킨다.
  이 major 는 코드가 구현한 프로토콜이라 코드에 둔다. 설치 버전과는 다른 값이다.
- `Extensions.loadUnpacked` 가 돌려준 id 가 계산한 id 와 다르면 `Extension_id_mismatch` 로 실패한다.
  허용한 origin 이 틀리면 `init` 이 뒤에서 알 수 없는 이유로 실패하기 때문이다.

MV3 service worker 는 멈췄다 다시 뜰 수 있다.
service worker 가 떨어지면 나가 있던 호출은 `Lost` 로 끝나고, 세션은 뒤의 호출을 `Detached` 로 거절한다.
backend 의 status 가 그 이유를 보여준다. 세션을 닫고 다시 열면 새 브라우저와 새 tab 번호로 시작한다.

### 3.4 동시성과 수명

- Chromium 프로세스와 CDP 연결은 서버가 뜰 때 설치하는 Stagehand backend 의 switch 가 가진다.
  `Session_open` 동사는 "열어 달라" 고 요청만 한다.
  동사를 도는 fiber 는 `Watched_work` 가 deadline 에 취소하므로 프로세스를 가지면 안 된다.
- Stagehand 호출(`act`·`observe`·`extract`)은 세션마다 하나씩만 보낸다. 상태는 닫힌 타입이다.

  ```ocaml
  type call_state = Idle | In_flight of call | Abandoned of call
  ```

  - lane deadline 이 지나면 lane 은 `Timed_out` 으로 답하고, 도구 결과는 지금처럼
    `Tool_result.Effect_outcome_unknown` 으로 끝난다 (`tool_misc_browser_lane.ml:333`). 상태는 `Abandoned` 가 된다.
    Stagehand 에는 `act`·`observe`·`extract` 취소 메서드가 없다.
    각 호출의 `options.timeout` 에 lane deadline 보다 짧은 양의 밀리초를 보내
    확장이 스스로 호출을 끝낼 기회를 준다. 응답이 여전히 없으면 `Abandoned` 상태를 유지한다.
  - `Abandoned` 동안 온 `llm.generate` 는 거절한다. 도구가 이미 실패를 알린 뒤에 클릭이 일어나지 않게 하려는 것이다.
    버려진 호출의 응답이 오면 `Idle` 로 돌아간다. 그전의 새 호출은 `Rejected_before_effect` 다.
  - `Idle` 에서 온 `llm.generate` 는 주인이 없으므로 거절하고 로그를 남긴다.
- 세션은 backend 가 가진다 (`Browser_stagehand_backend`). 도구는 요청을 stream 에 넣고 답을 기다린다.
  요청은 backend switch 의 fiber 에서 처리되므로, 도구가 어느 fiber·domain 에서 돌든 세션 상태는 한 domain 에서만 바뀐다.
  도구가 떠나면 그 도구가 부탁한 page 동사만 취소되고, 세션은 그 호출을 `Abandoned` 로 든다.
  open 과 close 는 도구가 떠나도 끝까지 한다. close 는 `stagehand.close` 답을 5초까지만 기다리고 브라우저를 멈춘다.
- `llm.generate` 처리기는 호출 순서를 지키는 잠금을 잡지 않는다. 상태만 읽는다.
  잡으면 `act` 가 자기 LLM 답을 기다리며 서로 막힌다.
  `extract` 는 `llm.generate` 두 개를 동시에 보내므로 요청마다 fiber 를 따로 띄운다.

### 3.5 Chromium 실행과 정리

`lib/server/server_browser_stagehand.ml` 을 `server_browser_webdriver.ml` 과 같은 모양으로 만든다.

- `Session_open` 때 Chromium 을 띄우고 `Session_close` 때 내린다. 서버가 뜰 때 미리 띄우지 않는다.
- `--remote-debugging-port=0` 으로 띄우고 profile 의 `DevToolsActivePort` 파일에서 포트를 읽는다.
  빈 포트를 먼저 잡았다가 넘기는 사이의 경쟁이 없다.
- `Posix_spawn_process_mgr` 로 띄우고 backend switch 의 `on_release` 에서 프로세스 그룹을 끝낸다.
  죽은 서버가 남긴 Chromium 은 owner 파일을 보고 다음 시작 때 끝낸다.
- 플래그: `--headless=new`(`Session_open.headless` 에 따름), `--enable-unsafe-extension-debugging`,
  `--remote-allow-origins=chrome-extension://<id>`, `--no-first-run`, `--no-default-browser-check`,
  `--user-data-dir`, 창 크기.
- profile 은 두 가지다.
  - 설정에 `profile` 이 없으면 `<base-path>/.masc/browser-lane/stagehand-profile` 에 두고 시작할 때 비운다.
  - 설정에 `profile` 이 있으면 운영자가 가진 폴더를 그대로 쓰고 지우지 않는다. 로그인 상태를 남기는 용도다 (§6.3).
    Chrome 136 부터 기본 user-data-dir 에서는 원격 디버깅 플래그가 무시되므로, 평소 쓰는 Chrome 기본 폴더는 쓸 수 없다
    ([Chrome 공식 안내](https://developer.chrome.com/blog/remote-debugging-port)).
  - 어느 쪽이든 폴더 권한은 0700 으로 만든다.

### 3.6 설정

`Browser_configuration.t` 를 두 backend 가 같이 있을 수 있는 모양으로 바꾼다.
지금 이 타입을 쓰는 곳은 `server_browser_webdriver.ml` 과 그 테스트뿐이다.

```ocaml
type automation = { driver : string; binary : string option }
type stagehand = { chrome : string; extension : string; profile : string option }
type t = { automation : automation option; stagehand : stagehand option }
```

```toml
[browser]
geckodriver = "/abs/path/geckodriver"   # 지금과 같다

[browser.stagehand]
chrome = "/abs/path/to/chrome"
extension = "/abs/path/to/stagehand-extension/4.1.0"
# profile = "/abs/path/operator-owned-profile"   # 선택. 있으면 지우지 않는다
```

- 경로는 geckodriver 처럼 절대 경로만 받는다. 환경변수는 만들지 않는다.
- 옛 `Disabled | Geckodriver` 모양은 남기지 않는다.
- 어느 exact-output lane 을 쓸지는 설정에 두지 않는다. §3.7 의 닫힌 생성자로 정해진다.

확장은 `connectors/browser/install-stagehand-extension.sh` 가 설치한다.
`npm pack @browserbasehq/stagehand@<버전>` 결과를 `npm view` 의 `dist.integrity` 와 대조하고,
`dist/extension` 만 `<base-path>/.masc/browser-lane/stagehand-extension/<버전>/` 에 푼다.

버전은 두 곳에 나온다. 설치 스크립트의 고정 버전과, 운영자가 설정에 적는 경로다.
masc 코드는 설치 버전을 모른다. 세션을 열 때 준비 표식의 `serverInfo.version` 을 로그에 남긴다.
integrity 대조는 설치할 때 한 번만 한다. 확장을 올릴 때마다 다시 대조하지는 않는다.
혼자 쓰는 기기라는 전제에서 받아들이는 한계다 (§4).

### 3.7 `llm.generate` 는 masc runtime 이 답한다

`Standalone_lane.t` 에 `Browser_stagehand` 생성자를 더하고 (`Runtime.exact_lane` 은 그 별칭이다),
`[runtime.exact_output_lanes.browser_stagehand_exact]` 를 선언한다.
이 lane 은 retained run 을 만들지 않으므로 `Exact_lane_run_registry` 에는 넣지 않는다.
librarian·verifier 처럼 한 번 묻고 구조화된 답을 받는 모양이라 exact-output lane 이 맞다.
slot 목록과 failover 는 기존 lane 과 같이 운영자가 정한다.
요소 고르기에 Keeper 와 다른 모델을 쓰는 것이 이 구조의 핵심이다.

| 요청 | 처리 |
|---|---|
| `response_format.type = "json_schema"` | `Exact_output` 의 `Json_syntax` 로 보낸다 |
| `response_format` 이 text 이거나 `tools` 가 있음 | 첫 단계에서는 typed 오류로 답하고 로그를 남긴다. §6.3 에서 나오는지 센다 |
| image 블록 | 첫 단계에서는 typed 오류. 필요해지면 `Runtime_agent.runtime_accepts_image_input` 과 같이 연다 |

`Json_syntax` 를 고르는 이유가 있다.
- `Json_syntax` 는 스키마 지시문을 프롬프트에 붙이고 JSON 문법만 masc 안에서 검사한다 (`exact_output.mli:162-167`).
- `Provider_schema` 는 provider 마다 받는 스키마가 다르다.
  Gemini 허용 목록에는 `$schema` 와 `pattern` 이 없다 (`exact_output_gemini_schema.ml:8-24`).
  OpenAI 는 `strict:true` 로 보내는데, extract 스키마에는 `"additionalProperties": {}` 가 있다.
- 스키마 모양 검사는 스키마를 가진 Stagehand 가 Zod 로 한다 (§2).
  masc 는 JSON Schema 검사기를 새로 들이지 않는다.
  모양이 틀린 답은 Stagehand 호출 오류가 되어 Keeper 도구 결과로 돌아온다.

그 밖의 처리:

- Stagehand 의 `system_prompt` 는 system 자리로 넘긴다.
  system prompt 를 못 받는 slot 이 있다 (`Unsupported_system_prompt`, `exact_output_ready_admission.mli:92`).
  그래서 verifier 처럼 설정을 읽을 때 slot 이 system prompt 를 받는지 확인하고, 못 받으면 typed 오류로 거절한다.
- 답에 `usage` 를 채우려면 `Exact_output.success` 에 usage 가 있어야 한다.
  지금은 `raw_response { body; body_sha256 }` 뿐이다 (`exact_output.mli:237-240, 320-326`).
  그래서 AGENT_CORE 가 provider 응답에서 usage 를 읽어 `success` 에 typed 로 담게 한다 (§7 3번).
  이 변경은 기존 exact-output lane 들도 같이 쓴다.
- provider 가 실패하면 JSON-RPC 오류로 돌려준다. Stagehand 호출이 실패하고, 그 실패가 Keeper 도구 결과로 간다.

### 3.8 Keeper 도구

- `lane` enum 은 §3.1 의 규칙을 따른다.
- 새 도구 `BrowserInstruct` (`config/tools/masc_browser_instruct.toml`) 를 더한다.
  입력은 `action = act | observe | extract`, `instruction`, `tabId`, `schema`(extract) 다. lane 은 stagehand 로 고정이다.
  `schema` 는 JSON Schema **문자열**로 받는다. 모양이 정해지지 않은 object 매개변수는 provider 마다 strict 스키마에서 거절될 수 있어서다.
  결과는 Stagehand 의 `data` 와 `metadata`(usage, cache 상태 등)와 `tabId` 다.
  실패한 act 는 이미 동작했을 수 있어 결과 모름으로, observe·extract 는 읽기라 효과 전으로 답한다.

`BrowserAct` 에 넣지 않는 이유가 있다. `BrowserAct` 의 action 은 모두 구조화된 동작이다.
문장과 스키마를 받는 입력을 섞으면 그 enum 의 뜻이 흐려진다.

### 3.9 관측

Stagehand RPC 하나, `llm.generate` 하나마다 로그 한 줄을 남긴다.
메서드, page, 걸린 시간, 주고받은 바이트, 쓴 slot, usage, 결과 variant 를 적는다.
거절한 `llm.generate`(`Idle`·`Abandoned`) 도 같은 줄로 남긴다.
TUI 브라우저 패널은 source 에 `stagehand` 를 그린다.
Dashboard standalone lane 목록은 `browser_stagehand_exact` 를 표시하고 retained run 이 없음을 밝힌다.

## 4. 보안

전제: masc 는 운영자 한 명이 쓰는 기기에서 돈다.

- `--enable-unsafe-extension-debugging` 이 켜지면 CDP 포트에 붙은 누구나 확장을 올리고 디버깅할 수 있다.
- Origin 헤더를 보내지 않는 로컬 프로세스는 CDP 포트에 언제나 붙을 수 있다.
  `/json/version` 이 websocket 주소도 알려준다. loopback 과 임의 포트는 같은 기기의 다른 프로세스를 막지 못한다.
  그래서 이 target 은 여러 사용자가 쓰는 기기를 가정하지 않는다.
- Stagehand 의 기본 launcher 는 `--remote-allow-origins=*` 를 넣는다.
  이 플래그는 DevTools websocket 의 Origin 검사를 끈다.
  그러면 같은 기기에서 열린 아무 웹 페이지가 포트를 맞히는 순간 이 Chromium 을 조종할 수 있다.
  masc 는 `chrome-extension://<id>` 하나만 허용한다. 확장 자신의 websocket 만 통과한다 (§2).
- 실행 전에 계산한 확장 id 와 Chrome 이 준 id 를 비교한다 (§3.3).
- profile 폴더는 0700 으로 만든다. 확인 때 `DevToolsActivePort` 는 0755 폴더 안의 0644 파일이었다.
  운영자 profile 에는 Slack 같은 로그인 쿠키가 들어가므로 특히 중요하다.
- Docker·microVM Keeper 가 `host.docker.internal` 로 이 포트에 닿는지는 확인하지 않았다.
  Chrome 은 127.0.0.1 에만 열지만, 구현 PR 에서 docker Keeper 로 한 번 확인한다.
- 실행 코드에는 `HIGH-RISK-UNREVIEWED` 주석을 달고 사람 리뷰를 받는다.
- API 키는 브라우저로 가지 않는다. 모든 LLM 호출은 `llm.generate` 로 masc 에 돌아온다.
- 확장은 `debugger`, `<all_urls>` 권한을 갖는다. 다만 격리된 profile 안에서만이다. 운영자의 Firefox 는 건드리지 않는다.

## 5. 하지 않는 것

- Browserbase 클라우드, 서버 캐시.
- Jev 로 `act` 를 푸는 경로. Stagehand 에서 아직 병합되지 않았고 (browserbase/stagehand#2953), TS SDK 환경변수로만 켜진다.
- `live` Firefox 확장 변경, `automation` target 교체나 삭제.
- Stagehand `agent()`, code mode, WebMCP 메서드, `page.cdp_event` 구독.

## 6. 검증

### 6.1 테스트

- 가짜 CDP transport 가 녹화한 wire 를 되돌려준다.
  녹화본은 `docs/evidence/browser-stagehand-cdp-20260924/extension-to-host-requests.json` 에서 시작한다.
  `Tool_misc_browser_lane` handler 를 거쳐 `Session_open` → `Page_goto` → `Page_extract` → `Page_instruct` 를 돈다.
- `llm.generate` 연결은 테스트 안에서 만든 exact-output 응답기로 돈다. 이 응답기는 `test/` 에만 있다.
  `Runtime.exact_lane` 에 stub 생성자를 두지 않으므로 운영 설정이 그것을 고를 수 없다.
- 확인할 것: provider 실패와 JSON 문법 실패가 typed 오류로 오는지,
  `Abandoned` 동안 온 `llm.generate` 가 거절되는지, service worker 가 떨어졌을 때 나가 있던 호출이 `Lost` 이고 뒤 호출이 `Detached` 인지,
  받지 않는 동사가 target 마다 `Rejected_before_effect` 로 오는지.

### 6.2 실제 브라우저 증명

`.github/workflows/browser-host-proof.yml` 에 Chrome for Testing 과 고정 버전 확장을 더한다.
fixture 에서 `act`·`observe`·`extract` 를 돈다.
CI 에는 provider 키가 없으니 §6.1 의 테스트 응답기를 쓰는 테스트 실행 파일로 돈다.
실제 모델로 돈 결과는 로컬에서 로그와 스크린샷으로 `docs/evidence/` 에 남긴다.

### 6.3 비교 실험

`automation` 은 시작할 때 profile 을 비우고 (`server_browser_webdriver.ml:226`),
Firefox 와 Chromium 은 로그인 세션을 나눠 쓸 수 없다.
그래서 비교를 둘로 나눈다.

1. fixture 와 공개 페이지: `automation` (Keeper 가 요소를 고른다) 대 `stagehand` (`BrowserInstruct`).
2. Slack: `live` (운영자가 로그인한 Firefox) 대 `stagehand` (운영자가 한 번 로그인한 `profile` 폴더).
   research 문서가 말한 "같은 Slack 세션" 은 운영자 자신의 로그인한 브라우저를 뜻한다.
   계정은 같지만 브라우저 세션은 다르다는 점을 결과에 적는다.

잴 것: 과제 성공, Keeper 도구 왕복 수, Keeper 에게 돌아간 바이트, Keeper 입력 토큰,
내부 `llm.generate` 수·토큰·시간, 전체 시간.
결과는 `docs/evidence/` 에 남긴다.
숫자 기준으로 자동 판정하지 않는다. 측정값을 보고 운영자가 정한다.

## 7. 구현 순서 (Stacked PR)

4–7번은 따로 두면 아무 데서도 부르지 않는 코드다.
그래서 한 묶음으로 리뷰하고 순서대로 함께 병합한다.
2·3번은 혼자서도 쓸모가 있어서 먼저 들어가도 된다.

1. 이 RFC 와 실측 증거.
2. 완료 (#38664): lane 이름을 읽는 곳을 `Browser_lane.Lane_name` 하나로 모았다. 동작은 바꾸지 않았다.
3. AGENT_CORE: `Exact_output.success` 에 typed usage 를 담는다.
4. `Browser_cdp`(#38668), Stagehand 세션(#38676): `ws-direct`, 닫힌 봉투·메시지 타입, `call_state`,
   호출별 `options.timeout` 과 가짜 transport 테스트.
5. `Browser_configuration` 변경과 확장 설치 스크립트(#38684), `server_browser_stagehand` 실행과 정리(#38686).
6. `Standalone_lane.Browser_stagehand`, lane 선언, system prompt admission, `llm.generate` 연결(#38708).
7. 나눠서 쌓는다.
   - `Browser_lane.Stagehand` target, 동사, surface·TUI source, `BrowserSession`·`BrowserGoto` 의 `lane`(#38697)
   - 동사를 Stagehand 호출로 바꾸는 실행기와 tab 번호 표(#38720)
   - 세션을 가지는 backend(#38736), 서버가 뜰 때 설치(#38739)
   - `BrowserInstruct` 도구(#38747), 문서(#38752)
   - `Page_read`·`Page_elements`·`Page_scene` 을 automation 과 같은 페이지 스크립트로(#38805)
   - TUI 의 `c` 키와 대시보드 경로의 lane(#38808)
   - `Page_interact`: DOM 조작은 같은 스크립트로, 좌표 조작은 `page.click`·`page.scroll`·`page.drag_and_drop` 로(#38812)
8. CI 실제 브라우저 증명(#38760, Chrome for Testing 154), §6.3 비교 실험 증거.

## 8. 열린 질문

- Stagehand 가 text·tool 생성 요청을 보내는 경로가 있는가 (self-heal 등). §6.3 에서 센다.
- branded Chrome 이 `Extensions.loadUnpacked` 를 앞으로도 받을지.
  branded Chrome 은 137 부터 `--load-extension` 을 막았다. 설정은 어떤 Chrome 경로든 받고, CI 는 Chrome for Testing 을 쓴다.
- Docker·microVM Keeper 에서 이 포트에 닿는지 (§4).
- MV3 service worker 가 실제 사용 중 얼마나 자주 멈추는지. 자주 멈추면 세션을 닫지 않고 다시 붙는 처리가 필요하다.
