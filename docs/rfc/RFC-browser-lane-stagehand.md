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
"Lane 안에서 같은 fixture 와 Slack 세션으로 비교할 후보" 로 적었다.
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
| 준비까지 | 실행부터 런타임 준비까지 약 2.0 s |
| `stagehand.init` | `model: {source: "client"}` 와 `browser_cdp_url` 을 주면 첫 page 를 돌려준다 |
| `page.goto` / `page.screenshot` | 135 ms / 약 80 ms |
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
- 확장은 Chrome 전용이다. Firefox 는 CDP `Extensions` 도메인이 없다.
  Lightpanda 도 같은 이유로 문서에서 Stagehand 를 3.x 에 고정했다 (lightpanda-io/docs#106).
- 2025년 자료에는 `Extensions.loadUnpacked` 가 `--remote-debugging-pipe` 에서만 된다고 적혀 있다.
  Canary 156 에서는 websocket 으로 됐고, Stagehand Go SDK 도 websocket 을 쓴다.
  버전에 따라 다를 수 있어서 CI 는 Chrome for Testing 으로 고정한다 (§6.2).

## 3. 결정

### 3.1 target 과 lane 이름

`Browser_lane` 에 세 번째 target 을 더한다.

```ocaml
type target = Automation | Live_client of client | Stagehand
type route = Automation_route | Live_route of client_id option | Stagehand_route
```

도구 입력의 `lane` 값은 `"stagehand"` 다 (`Tool_misc_browser_lane.route_of`).
이름을 `chromium` 이 아니라 `stagehand` 로 둔다. 동사에 답하는 것이 Stagehand 런타임이기 때문이다.
Stagehand 없이 Chromium 만 모는 target 은 이 RFC 에 없다.

닫힌 variant 에 생성자가 하나 늘면 컴파일러가 match 하는 곳을 전부 짚는다.
`lib/browser_surface.ml`, `lib/browser_interaction.ml`, `lib/lane_addon/lane_addon_sources.ml`,
`lib/tool_misc_browser_lane.ml` 이 대상이다.
`Browser_surface.source`, `Lane_addon_sources.browser_selection` 과 TUI 의 `source` 도 같이 늘린다.

### 3.2 동사

기존 동사는 이름을 그대로 쓰고, Stagehand 프로토콜 메서드에 연결한다.

| 기존 동사 | Stagehand 메서드 |
|---|---|
| `Session_open` / `Session_close` / `Session_status` | Chromium 실행 + `stagehand.init` / `stagehand.close` + 종료 / backend 기록 |
| `Tabs_list` | `context.pages` |
| `Page_goto` | `page.goto` |
| `Page_capture` | `page.screenshot` |
| `Page_read`, `Page_scene`, `Page_elements` | `page.evaluate` 로 지금 쓰는 스크립트(`Browser_page_script`, `Browser_scene_script`)를 그대로 돌린다 |
| `Page_interact` | `locator.click`·`locator.fill`·`page.click`(좌표)·`page.scroll`·`page.drag_and_drop` |
| `Page_act` | 대응 메서드가 있는 action 만. 없는 것은 거절 |
| `Page_document`, `Page_downloads`, `Page_context` | 첫 단계에서는 거절 |

scene·elements 를 같은 스크립트로 읽으면 Keeper 가 보는 관찰 형식이 target 마다 갈리지 않는다.

Stagehand target 에서만 받는 동사를 셋 더한다.

```ocaml
| Page_instruct of { tab_id : int; instruction : string }                          (* stagehand.act *)
| Page_locate of { tab_id : int; instruction : string option }                     (* stagehand.observe *)
| Page_extract of { tab_id : int; instruction : string; schema : Yojson.Safe.t option }  (* stagehand.extract *)
```

`verb_allowed_on_live` 처럼 `verb_allowed_on_stagehand` 를 둔다.
`_ ->` 없이 동사마다 true/false 를 적는다. 받지 않는 동사는 `Rejected_before_effect` 로 돌아간다.
`live`·`automation` 은 새 세 동사를 받지 않는다.

masc 동사의 `tab_id` 는 정수이고 Stagehand 의 `page_id` 는 문자열(CDP target id)이다.
backend 가 둘을 잇는 표를 들고, 표에 없는 `tab_id` 는 거절한다.

### 3.3 CDP 와 JSON-RPC 클라이언트

Node sidecar 없이 OCaml/Eio 가 직접 붙는다. 모듈은 둘이다.

- `Browser_cdp` — `ws-direct` 로 CDP websocket 을 연다.
  `Browser_bidi_peer.with_connection` 과 같은 모양이다.
  명령 id 마다 `Eio.Promise` 를 걸고, 이벤트는 따로 흘린다.
- `Stagehand_rpc` — 위 연결 위에서 service worker 를 붙잡고 JSON-RPC 를 주고받는다.
  순서는 Go SDK 와 같다: `Extensions.loadUnpacked` → service worker target 대기 →
  `Target.attachToTarget {flatten: true}` → `Runtime.enable` → `Runtime.addBinding` → 준비 표식 확인.

메시지는 닫힌 타입으로 받는다.

```ocaml
type extension_request =
  | Llm_generate of { id : Jsonrpc_id.t; params : Llm_generate.t }
  | Unsupported of { id : Jsonrpc_id.t; method_ : string }

type extension_notification =
  | Log of Stagehand_log.t
  | Page_event of Yojson.Safe.t
```

`Unsupported` 는 JSON-RPC `-32601` 로 답하고 로그를 남긴다. 조용히 넘기지 않는다.
준비 표식의 `protocolVersion` major 가 2 가 아니면 `Runtime_incompatible { found; supported }` 로
세션 열기를 실패시킨다.

MV3 service worker 는 멈췄다 다시 뜰 수 있다.
service worker target 이 떨어지면 다시 붙고 준비 표식을 다시 확인한다.
Go SDK 의 wake page(`wake-service-worker.html`) 처리도 같이 옮긴다.

### 3.4 Chromium 실행과 정리

`lib/server/server_browser_stagehand.ml` 을 `server_browser_webdriver.ml` 과 같은 모양으로 만든다.

- `Session_open` 때 Chromium 을 띄우고 `Session_close` 때 내린다. 서버가 뜰 때 미리 띄우지 않는다.
- `--remote-debugging-port=0` 으로 띄우고 profile 의 `DevToolsActivePort` 파일에서 포트를 읽는다.
  빈 포트를 먼저 잡았다가 넘기는 사이의 경쟁이 없다.
- profile 은 `<base-path>/.masc/browser-lane/stagehand-profiles` 에 두고 시작할 때 비운다.
- `Posix_spawn_process_mgr` 로 띄우고 `Switch.on_release` 에서 프로세스 그룹을 끝낸다.
  죽은 서버가 남긴 Chromium 은 owner 파일을 보고 다음 시작 때 끝낸다.
- 플래그: `--headless=new`(`Session_open.headless` 에 따름), `--enable-unsafe-extension-debugging`,
  `--no-first-run`, `--no-default-browser-check`, `--user-data-dir`, 창 크기.
  `--remote-allow-origins=*` 는 넣지 않는다 (§4).

### 3.5 설정

`Browser_configuration.t` 를 두 backend 가 같이 있을 수 있는 모양으로 바꾼다.

```ocaml
type automation = { driver : string; binary : string option }
type stagehand = { chrome : string; extension : string; exact_output_lane : string }
type t = { automation : automation option; stagehand : stagehand option }
```

```toml
[browser]
geckodriver = "/abs/path/geckodriver"   # 지금과 같다

[browser.stagehand]
chrome = "/abs/path/to/chrome"
extension = "/abs/path/to/stagehand-extension/4.1.0"
exact_output_lane = "browser_stagehand_exact"
```

경로는 geckodriver 처럼 절대 경로만 받는다. 환경변수는 만들지 않는다.
옛 `Disabled | Geckodriver` 모양은 남기지 않는다.

확장은 `connectors/browser/install-stagehand-extension.sh` 가 설치한다.
`npm pack @browserbasehq/stagehand@<버전>` 결과를 `npm view` 의 `dist.integrity` 와 대조하고,
`dist/extension` 만 `<base-path>/.masc/browser-lane/stagehand-extension/<버전>/` 에 푼다.
고정 버전은 이 스크립트 한 곳에만 적는다.

### 3.6 `llm.generate` 는 masc runtime 이 답한다

`[runtime.exact_output_lanes.browser_stagehand_exact]` 를 더한다.
librarian·verifier 처럼 한 번 묻고 구조화된 답을 받는 모양이라 exact-output lane 이 맞다.
slot 목록과 failover 는 기존 lane 과 같이 운영자가 정한다.
요소 고르기에 Keeper 와 다른 모델을 쓰는 것이 이 구조의 핵심이다.

| 요청 | 처리 |
|---|---|
| `response_format.type = "json_schema"` | `Agent_core.Exact_output` 로 보낸다. 답은 요청 스키마로 검증한다 |
| `response_format` 이 text 이거나 `tools` 가 있음 | 첫 단계에서는 typed 오류로 답하고 로그를 남긴다. §6.3 에서 나오는지 센다 |
| image 블록 | 첫 단계에서는 typed 오류. 필요해지면 `Runtime_agent.runtime_accepts_image_input` 과 같이 연다 |

- Stagehand 의 `system_prompt` 는 system 자리로 넘긴다.
- 답에 provider 의 `usage` 를 채운다. 안 채우면 `stagehand.metrics` 가 0 으로 나온다.
- provider 가 실패하면 JSON-RPC 오류로 돌려준다. Stagehand 의 `act` 가 실패하고, 그 실패가 Keeper 도구 결과로 간다.

### 3.7 Keeper 도구

- 기존 `BrowserTabs`·`BrowserRead`·`BrowserGoto`·`BrowserInteract`·`BrowserAct`·`BrowserSession` 의 `lane` 에 `stagehand` 를 더한다.
- 새 도구 `BrowserInstruct` (`config/tools/masc_browser_instruct.toml`) 를 더한다.
  입력은 `action = act | observe | extract`, `instruction`, `schema`(extract), `tab` 이다. lane 은 stagehand 로 고정이다.
  결과는 Stagehand 의 `data` 와 `metadata`(usage, cache 상태, 내부 LLM 호출 수, 걸린 시간)다.

`BrowserAct` 에 넣지 않는 이유가 있다. `BrowserAct` 의 action 은 모두 구조화된 동작이다.
문장과 스키마를 받는 입력을 섞으면 그 enum 의 뜻이 흐려진다.

### 3.8 관측

Stagehand RPC 하나, `llm.generate` 하나마다 로그 한 줄을 남긴다.
메서드, page, 걸린 시간, 주고받은 바이트, 쓴 slot, usage, 결과 variant 를 적는다.
TUI 브라우저 패널은 source 에 `stagehand` 를 그린다.

## 4. 보안

- `--enable-unsafe-extension-debugging` 이 켜지면 CDP 포트에 붙은 누구나 확장을 올리고 디버깅할 수 있다.
  포트는 loopback, 임의 번호다. profile 은 격리하고, 세션이 끝나면 브라우저도 끝난다.
- Stagehand 의 기본 launcher 는 `--remote-allow-origins=*` 를 넣는다.
  이 플래그는 DevTools websocket 의 Origin 검사를 끈다.
  그러면 같은 기기의 다른 브라우저에 열린 웹 페이지가 포트를 맞히는 순간 이 Chromium 을 조종할 수 있다.
  masc 는 이 플래그를 넣지 않는다. `ws-direct` 가 Origin 헤더를 보내지 않는지는 구현 PR 에서 테스트로 확인한다.
- 실행 코드에는 `HIGH-RISK-UNREVIEWED` 주석을 달고 사람 리뷰를 받는다.
- API 키는 브라우저로 가지 않는다. 모든 LLM 호출은 `llm.generate` 로 masc 에 돌아온다.
- 확장은 `debugger`, `<all_urls>` 권한을 갖는다. 다만 격리된 profile 안에서만이다. 운영자 브라우저는 건드리지 않는다.
- 확장은 버전을 고정하고 npm integrity 로 대조한다.

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
- `llm.generate` 연결은 가짜 exact-output lane 으로 돈다. 스키마 검증 실패와 provider 실패가 typed 오류로 오는지 본다.
- 받지 않는 동사가 `Rejected_before_effect` 로 오는지는 target 마다 본다.

### 6.2 실제 브라우저 증명

`.github/workflows/browser-host-proof.yml` 에 Chrome for Testing 과 고정 버전 확장을 더한다.
fixture 에서 `act`·`observe`·`extract` 를 돈다. CI 에는 provider 키가 없으니 stub lane 으로 돈다.
실제 모델로 돈 결과는 로컬에서 로그와 스크린샷으로 `docs/evidence/` 에 남긴다.

### 6.3 비교 실험

research 문서가 남긴 비교를 그대로 한다. 같은 fixture 와 같은 Slack 세션을 쓴다.

- A: `automation` (Firefox, Keeper 가 요소를 고른다)
- B: `stagehand` (`BrowserInstruct`)

잴 것: 과제 성공, Keeper 도구 왕복 수, Keeper 에게 돌아간 바이트, Keeper 입력 토큰,
내부 `llm.generate` 수·토큰·시간, 전체 시간.
결과는 `docs/evidence/` 에 남긴다.
숫자 기준으로 자동 판정하지 않는다. 측정값을 보고 운영자가 정한다.

## 7. 구현 순서 (Stacked PR)

1. 이 RFC 와 실측 증거.
2. `Browser_cdp`, `Stagehand_rpc` (`ws-direct`, 닫힌 메시지 타입, 가짜 transport 테스트).
3. `Browser_configuration` 변경, `[browser.stagehand]`, 확장 설치 스크립트, `server_browser_stagehand` 실행과 정리.
4. `llm.generate` → `browser_stagehand_exact` lane.
5. `Browser_lane.Stagehand` target, 기존 동사 연결, surface·TUI source.
6. `BrowserInstruct` 도구, 문서 (`docs-site` browser-lanes 가이드, `skills/browser-lanes`).
7. CI 실제 브라우저 증명, §6.3 비교 실험 증거.

## 8. 열린 질문

- Stagehand 가 text·tool 생성 요청을 보내는 경로가 있는가 (self-heal 등). §6.3 에서 센다.
- `tab_id` ↔ `page_id` 표를 Lane 상태에 둘지 backend 안에 둘지.
- 지금 스크립트가 `page.evaluate` 에서 그대로 도는가. automation 은 WebDriver `execute` 의 함수 본문 규칙으로 돌린다.
- 비교 실험의 Slack 로그인. 격리된 Chromium profile 에 운영자가 한 번 로그인해야 한다.
- branded Chrome 이 `Extensions.loadUnpacked` 를 앞으로도 받을지.
  branded Chrome 은 137 부터 `--load-extension` 을 막았다. 설정은 어떤 Chrome 경로든 받고, CI 는 Chrome for Testing 을 쓴다.
