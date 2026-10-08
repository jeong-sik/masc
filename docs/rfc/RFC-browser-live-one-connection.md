---
rfc: "browser-live-one-connection"
title: "Let one live connection do a whole browser task"
status: Draft
created: 2026-10-08
updated: 2026-10-08
author: vincent + claude
related: ["browser-lane-stagehand", "setup-web-search-and-browser-lane"]
---

# RFC — live 브라우저 일 하나를 한 연결로 끝낸다

## 1. 문제

Keeper `kidsnote-incoming-dd-manager` 가 Slack 웹에서 메시지에 리액션을 달지 못했다
(Board `p-7a4f661d`, 이슈 #41594).
리액션 버튼은 마우스를 올려야 나타난다.
Slack 로그인은 운영자의 Firefox 에만 있다.

live 레인에는 연결 방식이 둘 있다.
WebExtension 연결은 페이지를 읽고 DOM 으로 누른다. 마우스를 올리지는 못한다.
WebDriver BiDi 연결은 마우스를 올리고 끈다. 요소 목록을 못 읽고 탭을 앞으로 가져오지 못한다.
`Browser_lane.live_transport_serves` 가 이 표다.

Keeper 가 한 가지 일을 하려면 지금은 두 연결을 오가야 할 수 있다.
그런데 두 연결은 서로를 모른다.
탭 번호도 연결마다 따로라서, 한쪽에서 읽은 탭을 다른 쪽에 그대로 넘길 수 없다.

이 RFC 는 "한 가지 일을 한 연결로 끝내게 하는 길"을 정한다.
후보는 둘이다. 두 연결을 한 쌍으로 묶는 길과, BiDi 연결 하나가 다 하게 만드는 길이다.

## 2. 확인한 사실

2026-10-08 에 소스, 공식 문서, 운영 중인 서버로 확인했다.
소스는 origin/main `c8e8125b03` 에 #41795 와 #41802 를 올린 것이다.
`live_transport_serves` 표와 TUI 의 연결 표시는 그 두 PR 에서 들어온다.
실제 Firefox 로 돌려 본 것은 §2.2 의 한 가지다.

### 2.1 두 연결이 하는 일

| live 작업 | WebExtension | BiDi |
|---|---|---|
| 탭 목록, 텍스트·scene 읽기, 스크린샷 | 됨 | 됨 |
| `click`·`fill`·`scroll`·`follow_link` | 됨 | 됨 |
| `click_at`·`scroll_at` | 됨 (요소의 `click()`) | 됨 (trusted 포인터·휠) |
| `hover_at`·`drag` | 안 됨 | 됨 |
| `mode=elements` 읽기 | 됨 | 안 됨 |
| `browser_document` 원천 (HTML 포함 읽기) | 됨 | 안 됨 |
| `activate_tab` | 됨 | 안 됨 |

근거: `lib/browser_lane/browser_lane.ml` 의 `live_transport_serves`,
`lib/browser_bidi_peer.ml` 의 `dispatch`, `connectors/browser/extension/background.js`.
`test_browser_bidi_peer` 가 표와 BiDi peer 가 같은 말을 하는지 확인한다.

### 2.2 리액션에 필요한 것

마우스 올리기(`hover_at`) → 화면 다시 찍기 → 나타난 버튼 누르기(`click_at`).
세 가지 모두 BiDi 연결이 한다.
즉 이 일은 BiDi 연결 하나로 끝난다. 두 연결을 묶지 않아도 된다.

BiDi 연결의 `hover_at` 과 `drag` 는 실제 Firefox 157.0.1 에서 확인했다.
`test/test_browser_bidi_host.py` 를 임시 프로필의 headless Firefox 로 돌렸다.
마우스를 올린 뒤 fixture 페이지가 `hover:true:0` 을 적었다. trusted 이벤트였고 버튼은 눌리지 않았다.
운영 중인 Firefox 와 실제 Slack 에서 해 본 사람은 아직 없다.

### 2.3 두 연결을 잇는 정보가 없다

- 연결 정보는 `client_id`, `browser`, `version`, `engine_version`, `transport` 다섯 개다
  (`Browser_lane.client_info`). "같은 브라우저"라고 말해 주는 값이 없다.
- `client_id` 는 host 프로세스가 뜰 때마다 새로 만드는 UUID 다.
- BiDi host 는 `browser` 를 늘 `firefox` 로 보고한다 (`browser_host.ml` `run_bidi`).
  WebExtension host 는 Zen 을 `zen` 으로 보고한다.
  Zen 에 둘을 붙이면 이름부터 다를 수 있다. Zen 의 BiDi 응답은 확인하지 않았다.
- 탭 번호: WebExtension 은 Firefox 의 탭 ID 를 쓴다.
  BiDi peer 는 context 가 처음 보인 순서대로 1부터 번호를 매긴다 (`Browser_bidi_peer.tree`).
  설계 문서는 "확장 ID 나 URL 과 잇지 않는다"고 적었다 (`docs/design/browser-bidi-live-host.md`).
- WebExtension API 가 BiDi context ID 를 알려 주는지는 확인하지 못했다. 확인 필요.

### 2.4 BiDi 연결은 운영자가 손으로 붙인다

- Firefox 를 `--remote-debugging-port` 로 띄워야 한다. 이미 떠 있는 Firefox 에 켜는 방법은 문서에 없다.
  주소는 `ws://127.0.0.1:PORT/session` 이다.
  ([MDN](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection), 2026-10-08 확인)
- 그 포트에 붙는 로컬 프로세스는 브라우저를 조종하고 쿠키를 읽을 수 있다. 인증도 암호화도 없다.
  loopback 에서만 받는다.
  ([Mozilla Remote Agent Security](https://firefox-source-docs.mozilla.org/remote/Security.html), 2026-10-08 확인)
- host 는 `masc-browser-host --bidi-url ws://127.0.0.1:PORT/session` 으로 띄운다.
  이 명령을 대신 실행해 주는 것이 없다.
  `connectors/browser/host/README.md`, `connectors/browser/install-host.sh`,
  `scripts/install-local-build.sh` 에 BiDi 가 나오지 않는다.
- BiDi 명령의 결과를 모르게 되면 host 가 끝난다 (`run_bidi`). 다시 띄우는 것도 손으로 한다.
- TUI 는 연결마다 `WebExtension`/`BiDi` 와 못 하는 일을 보여 준다.
  BiDi 가 붙어 있는지, 안 붙어 있으면 어떻게 붙이는지는 못 하는 동작을 시도한 뒤에야 나온다.

### 2.5 지금 운영 상태

2026-10-08 11:36 KST 에 다시 시작된 서버(`c8e8125b03`)에서 읽었다.

- 연결 목록은 Firefox 157.0 의 `web_extension` 연결 하나다. BiDi 연결은 없다.
- Keeper 도구에는 `hover_at` 이 있다. 지금 부르면 "이 연결은 못 한다"로 거절된다.
- 같은 날 Keeper 의 호출 로그에는 10:32 에 거절된 `drag` 가 있다.
  10:52 와 11:30 에는 "browser lane 이 제때 답하지 않았다"가 남았다.
  11:29 에 host 실행 파일이 바뀌었고 그 직후 연결 ID 가 바뀌었다. Keeper 는 11:32 에 `selected_client_disconnected` 를 받았다.

### 2.6 BiDi 에 빠진 것을 채우는 비용

| 빠진 것 | 채우는 길 | 걸리는 점 |
|---|---|---|
| 요소 목록 | automation·stagehand 가 쓰는 `Browser_page_script.elements` 를 그대로 실행 | 없음. 작다 |
| HTML 포함 읽기 | 크기 상한이 있는 읽기를 따로 만든다 | 지금 helper 에 상한이 없다 |
| 탭 앞으로 가져오기 | BiDi `browsingContext.activate` | 창 포커스까지 가져온다. `activate_tab` 은 "창 포커스 없이"를 약속한다 ([MDN](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/browsingContext/activate)) |
| 링크를 따라간 뒤 새 문서가 뜰 때까지 기다리기 | BiDi `browsingContext` 이벤트를 구독 | peer 가 지금은 이벤트를 버린다 |

## 3. 후보

### A. 두 연결을 한 쌍으로 묶는다

서버가 "이 둘은 같은 브라우저"라고 알고, 요청마다 할 수 있는 쪽으로 보낸다.
Keeper 는 브라우저 하나만 고른다.

필요한 것:

1. 같은 브라우저라는 증명.
2. 탭마다 두 번호를 잇는 대응표.

증명하는 길과 그 부담:

| 길 | 부담 |
|---|---|
| 운영자가 TUI 에서 "이 둘은 한 쌍"이라고 고른다 | 틀리게 고르면 다른 프로필의 탭을 누른다 |
| BiDi 가 표식 탭을 하나 열고, 확장이 그 탭을 본다 | 운영자 브라우저에 탭이 열렸다 닫힌다. peer 는 지금 탭을 닫지 않는다 |
| 두 쪽이 같은 문서의 URL 과 시작 시각을 읽어 맞춘다 | 값이 겹치면 못 정한다. 겹칠 때 거절해야 한다 |

탭 대응표는 탭이 열리고 닫히고 이동할 때마다 다시 맞춰야 한다.
한쪽에서 읽은 `documentId`·`nodeId`·`viewport` 를 다른 쪽에 넘길 때도 같은 문제가 생긴다.
읽은 것과 누르는 것 사이에 연결이 바뀌므로, "읽은 화면 그대로 누른다"는 지금의 보장이 약해진다.

### B. BiDi 연결 하나가 다 한다

BiDi 에 빠진 것을 채우고, BiDi 를 붙이는 일을 운영자의 정식 동작으로 만든다.
WebExtension 은 지금처럼 "설치만 하면 읽는" 연결로 둔다.

필요한 것:

1. BiDi peer 가 요소 목록을 읽는다 (§2.6 첫 줄).
2. BiDi 를 붙이는 명령 하나와 그 상태를 TUI·`masc doctor` 에 보여 준다.
   Firefox 를 플래그로 띄우는 것은 운영자가 한다. MASC 는 띄우지 않는다.
   RFC `setup-web-search-and-browser-lane` 이 제안한 "다시 열리는 설정 명령"에 이 단계를 더하는 모양이 맞다.
3. host README 에 BiDi 절을 넣는다.
4. host 가 끝났을 때 TUI 가 이유와 다시 붙이는 법을 보여 준다.

탭 번호와 관측은 한 연결 안에서만 쓰이므로 대응표가 필요 없다.

### C. 그대로 둔다

Keeper 가 거절 문구(`live_transport_unsupported` 의 `servingClients`)를 보고 직접 연결을 바꾼다.
BiDi 는 운영자가 문서를 보고 손으로 붙인다.

## 4. 비교

| | A 한 쌍 | B BiDi 하나 | C 그대로 |
|---|---|---|---|
| 리액션 일이 되는가 | 됨 | 됨 | 됨 (BiDi 를 손으로 붙이면) |
| 새로 생기는 판단 | 같은 브라우저 증명, 탭 대응 | 없음 | 없음 |
| 읽은 화면 그대로 누른다는 보장 | 약해짐 | 그대로 | 그대로 |
| 운영자가 할 일 | Firefox 를 플래그로 띄우기 + 확장 | Firefox 를 플래그로 띄우기 | 같음 + 문서 찾기 |
| 열린 포트의 위험 | 있음 | 있음 | 있음 |
| 코드 크기 | 큼 (서버 라우팅, 대응표, 증명) | 작음~중간 | 0 |

A 와 B 모두 Firefox 를 플래그로 띄워야 한다. A 가 이 부담을 덜어 주지 않는다.
A 만 주는 것은 "BiDi 가 못 하는 일(탭 앞으로 가져오기, HTML 포함 읽기)을 같은 흐름에서 쓰는 것"이다.

## 5. 제안

B 를 먼저 한다. A 는 B 뒤에 "두 방식이 같은 흐름에 꼭 필요한 일"이 실제로 나오면 다시 연다.

이유:

- 지금 막힌 일(리액션)은 BiDi 하나로 된다 (§2.2).
- A 의 두 판단(같은 브라우저, 탭 대응)은 틀렸을 때 다른 탭을 누른다. 로그인된 브라우저에서 이 피해는 크다.
- A 는 B 의 운영 부담(§2.4)을 그대로 안고 간다.

B 의 순서:

1. BiDi peer 의 요소 목록. 표의 한 칸이 바뀌고, `test_browser_bidi_peer` 가 그 칸을 확인한다.
2. BiDi 붙이기 명령과 상태 표시. TUI Browser Lane 에 "BiDi: 붙음 / 안 붙음 · 붙이는 법".
3. README·스킬 문서.

하지 않는 것:

- MASC 가 Firefox 를 띄우거나 프로필·설정을 바꾸는 일.
- 로그인이나 쿠키를 다른 세션으로 옮기는 일.
- WebExtension 에서 마우스 올리기를 흉내 내는 일. 페이지가 속지 않는다.

## 6. 확인 방법

1. 소유한 임시 프로필의 Firefox 와 fixture 페이지(마우스를 올려야 버튼이 보이는 페이지)로,
   BiDi 연결 하나에서 `hover_at` → 스크린샷 → `click_at` → 상태 변화까지 확인한다.
   `test/test_browser_bidi_host.py` 가 hover 표시와 trusted 이벤트까지는 이미 본다.
2. 요소 목록: 같은 fixture 에서 BiDi 와 automation 의 `mode=elements` 결과가 같은지 본다.
3. 붙이기 명령: 포트가 닫힌 상태, 열린 상태, host 가 끝난 뒤 상태에서 TUI 문구를 PTY 로 확인한다.
4. 받는 쪽 확인: `kidsnote-incoming-dd-manager` 가 실제 Slack 에서 리액션 하나를 달고,
   다시 찍은 화면에서 그 리액션을 확인한다. 이것이 #41594 의 완료 조건이다.

## 7. 운영자가 정할 것

1. 로그인된 Firefox 를 `--remote-debugging-port` 로 띄우는 것을 평소 운영으로 받아들이는가.
   받아들이지 않으면 B 도 A 도 리액션 일을 못 한다.
2. BiDi 의 탭 앞으로 가져오기는 창 포커스를 가져간다. 이 동작을 `activate_tab` 으로 허용하는가,
   다른 이름의 동작으로 두는가, 넣지 않는가.
3. B 뒤에도 A 가 필요한 일이 떠오르는가. 있으면 그 일을 이 RFC 에 적는다.
