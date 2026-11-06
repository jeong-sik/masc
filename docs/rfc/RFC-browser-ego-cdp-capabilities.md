---
rfc: "browser-ego-cdp-capabilities"
title: "Serve the missing browser operations on ego through page.cdp"
status: Draft
created: 2026-11-06
updated: 2026-11-06
author: vincent + claude
related: ["browser-live-ego", "browser-live-one-connection", "browser-ego-input-lock", "browser-keeper-firefox"]
---

# RFC — ego 연결에 빠진 브라우저 동작을 page.cdp 로 붙인다

## 1. 문제

ego 연결은 masc 브라우저 기능 67개 중 49개만 한다.
2026-11-06 ego 연결(space 9)의 `masc_browser_tabs` 기능 목록에서 셌다.

빠진 18개 중 12개는 다른 연결에서는 된다. close_window 는 어떤 연결에도 없다.

| 묶음 | 동작 | 지금 되는 연결 |
|---|---|---|
| ego 만 빠짐 | list_windows, create_window | live BiDi |
| | read_html | WebExtension, live BiDi, Firefox(automation) |
| | resize_viewport, touch | live BiDi, Firefox |
| | page_zoom | WebExtension |
| Firefox 전용 | read_console, read_network, intercept_network, read_storage, write_storage, emulate_environment | Firefox |
| 어디에도 없음 | close_window | 없음 |

이 13개가 이 RFC 범위다. 나머지 5개는 범위 밖이다(§6).

`lib/browser_capabilities.ml` 는 ego 의 13개를 `missing` 으로 둔다. read_html 만 이유를 적은 `Unsupported` 다.
`lib/browser_ego_peer.ml` 의 `page.act` 는 쿠키·환경·요청 차단을 입력 전에 거절한다.

ego 공식 안내(`ego-browser skill` v2.2.0)에 길이 있다.
`page.cdp(method, params)` 는 Page·Runtime·DOM·Network·Input 명령을 받는다.
`task.cdp()` 는 Target·Browser 명령을 받는다.
masc 는 이미 이 길을 쓴다. 뒤로·앞으로 가기는 `Page.getNavigationHistory` 를 부르고, 로딩 멈춤은 `Page.stopLoading` 을 부른다.

## 2. 확인한 사실

2026-11-06, ego lite 0.6.2.7(Chromium 156), 이 맥에서 쟀다.
원본은 [docs/evidence/ego-cdp-capabilities-2026-11-06/](../evidence/ego-cdp-capabilities-2026-11-06/README.md) 에 있다.

| 동작 | CDP | 결과 |
|---|---|---|
| resize_viewport | `Emulation.setDeviceMetricsOverride` | 1548×990 → 800×600 |
| touch | `Emulation.setTouchEmulationEnabled` + `Input.dispatchTouchEvent` | 페이지가 touch pointer 와 touch 이벤트, click 을 받았다. 모두 `isTrusted` |
| read_html | `DOM.getOuterHTML` | `<!DOCTYPE html>` 부터 597 바이트 |
| read_storage | `Network.getCookies` | 쿠키 이름 `probe_cookie` |
| emulate_environment | `Emulation.setLocaleOverride`·`setTimezoneOverride`·`setGeolocationOverride` | Intl 이 `fr-FR`·`America/New_York` 로 바뀌었다. `navigator.language` 는 `ko-KR` 그대로였다 |
| intercept_network | `Network.setBlockedURLs` | 차단한 주소의 `fetch` 가 실패했다 |
| read_network | `Network.enable` + `page.events()` | reload 한 번에 43~105개. `requestWillBeSent`·`responseReceived`·`loadingFinished` 가 있다 |
| list_windows | `task.cdp("Browser.getWindowForTarget")` | windowId 와 위치·크기·상태 |
| page_zoom | `Emulation.setPageScaleFactor` | `visualViewport.scale` 이 2 가 됐다. 브라우저 확대가 아니라 핀치 배율이다 |
| read_console | `Runtime.enable` + `page.events()` | 기본 상태에서는 0줄이었다. `egoAutomated.disable` 뒤에는 3줄이 왔고, 로드 때 쓴 줄도 들어 있었다 |

두 가지가 설계를 가른다.

1. **CDP 로 바꾼 설정은 SDK 프로세스와 같이 끝난다.** 새 프로세스에서 다시 읽으니 화면 크기, Intl, 시간대, 요청 차단, 배율이 모두 원래 값이었다.
   masc 는 연결 하나에 nodejs 프로세스 하나를 계속 띄운다(`lib/browser_addon_live_ego.ml` 의 `session_loop`).
   그 프로세스는 명령이 시간 안에 답하지 않거나, 출력 한도를 넘거나, 취소되면 끝난다. 다음 명령은 새 프로세스로 돈다.
   그러면 설정이 말없이 사라진다.
2. **ego 는 운영자의 실제 프로필을 쓴다.** 쿠키를 쓰거나 지우면 운영자의 로그인이 바뀐다. 위치 권한을 주면 운영자 프로필의 그 사이트 권한이 바뀐다.
   Firefox(automation)는 masc 가 띄운 따로 된 프로필이라 이 문제가 없다.

안내서는 console 에 대해서도 적는다.
ego 의 page 세션은 사이트가 자동화를 알아채지 못하게 console 메시지를 CDP 에서 숨긴다.
`egoAutomated.disable` 로 끄면 그동안 사이트가 CDP 를 알아챌 수 있다.

안내서는 "raw CDP 는 ref 를 무효로 만든다" 고도 적는다. CDP 를 부른 뒤에는 snapshot 을 다시 읽어야 한다.

## 3. 결정

### 3.1 붙이는 방식

- 각 동작은 ego 연결의 기존 page 스크립트 틀(`on_page`) 안에서 `page.cdp` 나 `page.evaluate` 를 부른다. 새 프로세스 경로는 만들지 않는다.
- 답의 모양은 Firefox 나 BiDi 의 같은 동작과 같게 한다. 다를 수밖에 없는 곳은 답에 그 사실을 적는다.
- 효과가 있는 동작의 답에는 `refsInvalidated: true` 를 넣는다. 다음 ref 동작 전에 snapshot 을 다시 읽으라는 뜻이다.
- 쓸 수 있는 문서 메서드가 있으면 그것을 먼저 쓴다. read_html 은 CDP 를 부르지 않고 page 스크립트로 문서를 읽는다. 이 경우 ref 가 무효가 되지 않는다.

### 3.2 설정의 수명

CDP 로 바꾼 설정(화면 크기, 터치 흉내, 언어·시간대·위치, 요청 차단)은 masc 가 따로 저장하지 않는다.
프로세스가 바뀐 뒤 masc 가 설정을 다시 걸지도 않는다.

대신 수명을 답에 적는다.

- 모든 ego 답에 `sdkProcessStartedAt` 을 넣는다. 객체인 답과 실패 receipt 모두다. 그 명령을 돌린 SDK 프로세스가 연결된 시각(초)이다. 명령이 프로세스를 멈췄으면 `null` 이다.
- 설정을 건 답에는 `lifetime: "ego_sdk_process"` 도 넣는다.
- Keeper 는 설정을 걸었을 때의 시각과 지금 답의 시각이 다르면 설정이 사라진 것을 안다.
- 하나씩 올리는 번호 대신 시각을 쓴다. `lib/browser_addon_live_ego.ml` 의 `serve_space` 는 연결 cycle 마다 session 을 새로 만든다. 서버가 다시 켜져도 처음부터다. 번호는 그때마다 1 부터 다시 시작해서, 다른 프로세스가 같은 번호를 가진다. 시각은 되풀이되지 않는다.
- 화면 크기는 scene·screenshot 의 viewport 로 다시 확인된다. 요청 차단은 다시 확인할 길이 없어서 시각이 유일한 근거다.
- 탭 목록처럼 배열인 답에는 붙지 않는다. `inputReadiness` 와 같다.

Firefox 의 `block_requests` 설명("unblock_requests 까지 실패한다")은 ego 에서는 "unblock_requests 를 부르거나 SDK 프로세스가 바뀔 때까지" 로 적는다.

### 3.3 동작별 결정

| 동작 | 결정 |
|---|---|
| read_html | 다른 연결이 쓰는 문서 함수(`Browser_lane.Document.runtime` 의 `browserDocument()`)를 그대로 돌린다. doctype 없이 `outerHTML` 을 준다. 1 MiB 를 넘으면 다른 연결처럼 `html: null`, `htmlComplete: false` 로 답한다 |
| resize_viewport | `setDeviceMetricsOverride` 로 크기를 바꾸고, 빈 요청은 `clearDeviceMetricsOverride` 로 되돌린다. 범위는 BiDi 와 같은 100–4096 이다 |
| touch (tap_at, swipe) | touch 흉내를 켠 뒤 `dispatchTouchEvent` 로 누르고 뗀다. swipe 는 `touchMove` 를 경유점마다 보낸다. `touchEnd` 의 답을 받지 못하면 mouse 와 같이 `inputReadiness: release_uncertain` 으로 답한다(RFC-browser-ego-input-lock) |
| list_windows | `task.tabs()` 의 각 탭에 `Browser.getWindowForTarget` 을 불러 `windowId` 를 붙인다. 같은 windowId 는 같은 창이다 |
| read_storage | `Network.getCookies` 로 그 페이지가 보는 쿠키의 이름·도메인·속성만 준다. 값은 Firefox 처럼 돌려주지 않는다. localStorage·sessionStorage 키 이름과 IndexedDB 이름은 `page.evaluate` 로 읽는다 |
| emulate_environment | locale·timezone·좌표를 `Emulation.*Override` 로 건다. locale 은 Intl 만 바뀐다는 것을 답에 적는다. 좌표를 주면 Firefox 처럼 그 origin 에 위치 권한도 준다(§4 D3) |
| intercept_network | `Network.setBlockedURLs` 에 정확한 호스트를 `*://<host>/*` 와 `*://<host>:*/*` 로 넣는다. 하위 도메인은 따로 적어야 한다는 Firefox 규칙을 그대로 둔다 |
| read_network | 아래 §3.4 |
| page_zoom | 붙이지 않는다. CDP 에는 브라우저 확대가 없고 핀치 배율만 있다. masc 의 확대 계약은 "측정한 브라우저 확대, CSS 배율은 쓰지 않음" 이다. `missing` 을 이유를 적은 `Unsupported` 로 바꾼다 |
| read_console | 한 명령 안에서 숨김을 끄고, 읽고, 되돌린다(§4 D1) |
| write_storage | `Network.setCookie`·`deleteCookies` 로 Firefox 와 같은 규칙을 따른다. 답에 운영자 프로필의 쿠키가 바뀐다고 적는다(§4 D2) |
| create_window, close_window | 측정한 뒤 붙인다(§4 D4) |

### 3.4 network 기록

`page.events()` 는 SDK 프로세스의 버퍼를 돌려주고 비운다. workflow 의 `events` 단계도 같은 버퍼를 비운다.
두 곳이 따로 읽으면 서로의 이벤트를 가져간다.

그래서 ego session 스크립트 안에 버퍼를 읽는 함수를 하나만 둔다.

- 그 함수는 `page.events()` 를 부르고, `Network.*` 이벤트를 페이지별 network 기록에 옮긴다. 나머지는 workflow `events` 에 돌려준다.
- network 기록은 Firefox 와 같이 오래된 것부터 200개를 남기고, 넘친 개수를 `dropped` 에 적는다.
- 주소의 질의 값은 `REDACTED` 로 바꾼다. 헤더는 이름만 남기고, 쿠키와 본문은 넣지 않는다.
- 기록은 `Network.enable` 을 처음 부른 때부터 시작한다. 답의 `watchingSince` 에 그 시각과 `sdkProcessStartedAt` 을 적는다. 프로세스가 바뀌면 기록도 새로 시작한다.
- workflow `events` 설명의 "not a full history" 는 그대로 맞다. 여기에 "Network 이벤트는 read_network 로 간다" 를 더한다.

`Network.enable` 이 사이트에 자동화를 드러내는지는 재지 않았다. 구현 층에서 먼저 잰다.

## 4. 운영자 결정 (2026-11-06)

| 번호 | 질문 | 결정 |
|---|---|---|
| D1 | console 을 읽으려면 ego 의 자동화 숨김을 잠깐 꺼야 한다. 그동안 사이트가 자동화를 알아챌 수 있다 | 붙인다. 한 명령 안에서 끄고, 읽고, `Runtime.disable` 과 `egoAutomated.enable` 로 되돌린다. 답에 숨김을 끈 구간을 적는다. 되돌리기가 실패하면 그 사실을 답에 적는다 |
| D2 | 쿠키 쓰기·지우기는 운영자의 실제 로그인을 바꾼다 | 붙인다. 답과 도구 설명에 운영자 프로필의 쿠키가 바뀐다고 적는다 |
| D3 | 위치 권한을 주면 운영자 프로필의 사이트 권한이 바뀐다 | 권한도 준다. `clear_emulation` 은 Firefox 처럼 그 권한을 그대로 둔다. 권한이 브라우저를 다시 켠 뒤에도 남는지는 L3 에서 재서 설명에 적는다 |
| D4 | `Target.createTarget({newWindow: true})` 로 만든 탭을 ego task space 가 관리하는지 모른다. close_window 는 어떤 연결에도 없는 새 동작이다 | 붙인다. L10 에서 먼저 잰다. 관리되지 않으면 그 결과를 들고 운영자에게 다시 묻는다. close_window 는 agent 가 연 탭만 있는 창에만 붙이고, 그 창의 탭을 `page.close()` 로 닫는다 |

## 5. 구현 순서

gh stack 한 스택에 층을 쌓는다. 층마다 기능 목록(`lib/browser_capabilities.ml`), ego peer 분기, 도구 설명 TOML 을 같이 바꾼다.

| 층 | 내용 | 확인 |
|---|---|---|
| L1 | read_html. page_zoom 을 이유 있는 `Unsupported` 로 바꿈 | masc 가 만드는 문서 스크립트를 ego SDK 로 로컬 페이지에서 돌려 `html` 바이트 수와 `htmlComplete` 를 본다([결과](../evidence/ego-cdp-capabilities-2026-11-06/l1-read-html/README.md)) |
| L2 | `sdkProcessStartedAt` 과 `lifetime` 필드. resize_viewport | 크기를 바꾸고 scene viewport 로 확인한다. 세션 프로세스를 바꾼 뒤 시각이 바뀌고 크기가 돌아오는지 본다 |
| L3 | emulate_environment (D3 반영) | Intl locale·시간대를 읽는다 |
| L4 | touch (tap_at, swipe) | 페이지가 기록한 pointerType 과 touch 이벤트를 본다 |
| L5 | list_windows | 탭마다 windowId 를 본다 |
| L6 | intercept_network | 차단한 호스트의 fetch 실패와 풀린 뒤 성공을 본다 |
| L7 | read_storage | 쿠키 이름과 저장소 키 이름. 값이 없는지 본다 |
| L8 | events 버퍼 함수 하나와 read_network | workflow `events` 와 read_network 를 번갈아 불러 이벤트가 사라지지 않는지 본다 |
| L9 | read_console | 페이지가 쓴 줄과 되돌린 뒤 숨김 상태 |
| L10 | create_window·close_window | 새 창 탭의 label 과 관리 여부를 먼저 잰다 |
| L11 | write_storage | 시험 origin 에 쿠키를 쓰고 지운 뒤 이름 목록 |

시험은 헌법 `testing` 에 맞춰 기능 단위로 쓴다. ego 를 대신하는 시험 실행기가 스크립트 첫 줄의 단계 이름을 읽는 기존 방식을 쓴다(`lib/browser_ego_peer.ml` 의 `frame`).

## 6. 범위 밖

- pointer_down·pointer_up: 어떤 연결에도 없다. ego 에서는 `mouse.down/move/up` 에 떼기 영수증이 없어서 좌표 드래그도 입력 전에 거절한다(`lib/browser_capabilities.ml` 의 pointer_drag 설명). 이 RFC 는 그 판단을 바꾸지 않는다.
- read_clipboard·write_clipboard: 어떤 연결에도 없다. ego 는 운영자의 macOS 클립보드를 같이 쓴다.
- session_lifecycle: 운영자가 띄운 브라우저라 masc 가 열고 닫지 않는다.
- 다른 연결의 동작은 바꾸지 않는다.
