---
rfc: "browser-live-one-connection"
title: "Let one live connection do a whole browser task"
status: Accepted
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
WebDriver BiDi 연결은 마우스를 올리고 끈다. 탭을 앞으로 가져오지 못한다.
`Browser_lane.live_transport_serves` 가 이 표다.

Keeper 가 한 가지 일을 하려면 지금은 두 연결을 오가야 할 수 있다.
그런데 두 연결은 서로를 모른다.
탭 번호도 연결마다 따로라서, 한쪽에서 읽은 탭을 다른 쪽에 그대로 넘길 수 없다.

이 RFC 는 "한 가지 일을 한 연결로 끝내게 하는 길"을 정한다.
후보는 둘이다. 두 연결을 한 쌍으로 묶는 길과, BiDi 연결 하나가 다 하게 만드는 길이다.

## 2. 확인한 사실

2026-10-08 에 소스, 공식 문서, 운영 중인 서버로 확인했다.
소스는 origin/main `c8e8125b03` 에 #41795, #41802, #41813 을 올린 것이다.
`live_transport_serves` 표와 TUI 의 연결 표시는 그 두 PR 에서 들어온다.
실제 Firefox 로 돌려 본 것은 §2.2 의 동작과 §2.4 의 세션 수명이다.

### 2.1 두 연결이 하는 일

| live 작업 | WebExtension | BiDi |
|---|---|---|
| 탭 목록, 텍스트·scene 읽기, 스크린샷 | 됨 | 됨 |
| `click`·`fill`·`scroll`·`follow_link` | 됨 | 됨 |
| `click_at` | 됨 (그 자리 요소의 `click()`) | 됨 (trusted 포인터) |
| `scroll_at` | 됨 (그 자리의 스크롤 영역에 `scrollBy`) | 됨 (trusted 휠) |
| `hover_at`·`drag` | 안 됨 | 됨 |
| `mode=elements` 읽기 | 됨 | 됨 (#41813) |
| `browser_document` 원천 (HTML 포함 읽기) | 됨 | 됨 (#41813) |
| `activate_tab` | 됨 | 안 됨 |

근거: `lib/browser_lane/browser_lane.ml` 의 `live_transport_serves`,
`lib/browser_bidi_peer.ml` 의 `dispatch`, `connectors/browser/extension/background.js`.
`test_browser_bidi_peer` 가 표와 BiDi peer 가 같은 말을 하는지 확인한다.

### 2.2 리액션에 필요한 것

마우스 올리기(`hover_at`) → 화면 다시 찍기 → 나타난 버튼 누르기(`click_at`).
세 가지 모두 BiDi 연결이 한다.
즉 이 일은 BiDi 연결 하나로 끝난다. 두 연결을 묶지 않아도 된다.

BiDi 연결의 `hover_at` 과 `drag` 는 실제 Firefox 157.0.1 에서 확인했다.
`test/test_browser_bidi_host.py` 를 임시 프로필의 headless Firefox 로 돌렸다(로컬 실행, 결과는 #41795 본문).
마우스를 올린 뒤 fixture 페이지가 `hover:true:0` 을 적었다. trusted 이벤트였고 버튼은 눌리지 않았다.
#41813 이 같은 테스트에 리액션 모양의 흐름을 더했다. 마우스를 올려야 나타나는 버튼이 올리기 전에는 요소 목록에 없고,
`hover_at` 뒤에는 있고, scene 이 알려 준 위치를 `click_at` 하면 페이지가 `reaction:true` 를 적는다(trusted 클릭).
운영 중인 Firefox 와 실제 Slack 에서 해 본 사람은 아직 없다.

### 2.3 두 연결을 잇는 정보가 없다

- 연결 정보는 `client_id`, `browser`, `version`, `engine_version`, `transport` 다섯 개다
  (`Browser_lane.client_info`). "같은 브라우저"라고 말해 주는 값이 없다.
- `client_id` 는 host 프로세스가 뜰 때마다 새로 만드는 UUID 다.
- BiDi host 는 `browser` 를 늘 `firefox` 로 보고한다 (`browser_host.ml` `run_bidi`).
  WebExtension host 는 Zen 을 `zen` 으로 보고한다.
  BiDi peer 는 브라우저가 자기 이름을 `firefox` 로 답할 때만 붙는다 (`Browser_bidi_peer.metadata`).
  Zen 이 어떻게 답하는지는 확인하지 않았다. 다르게 답하면 BiDi host 가 Zen 에 붙지 않는다.
  `firefox` 로 답하면 붙지만, 같은 Zen 의 두 연결이 `zen` 과 `firefox` 로 이름이 갈린다.
- 탭 번호: WebExtension 은 Firefox 의 탭 ID 를 쓴다.
  BiDi peer 는 context 가 처음 보인 순서대로 1부터 번호를 매긴다 (`Browser_bidi_peer.tree`).
  설계 문서는 "확장 ID 나 URL 과 잇지 않는다"고 적었다 (`docs/design/browser-bidi-live-host.md`).
- WebExtension API 가 BiDi context ID 를 알려 주는지는 확인하지 못했다. 확인 필요.

### 2.4 BiDi 연결은 운영자가 손으로 붙인다

- Firefox 를 `--remote-debugging-port` 로 띄워야 한다. 주소는 `ws://127.0.0.1:PORT/session` 이다.
  ([MDN](https://developer.mozilla.org/en-US/docs/Web/WebDriver/How_to/Create_BiDi_connection), 2026-10-08 확인)
- 이미 떠 있는 Firefox 에는 켤 수 없다. Remote Agent 는 명령줄 플래그로만 켠다.
  그 포트에 붙는 로컬 프로세스는 브라우저를 조종하고 쿠키를 읽을 수 있다. 인증도 암호화도 없다.
  loopback 에서만 받는다.
  ([Mozilla Remote Agent Security](https://firefox-source-docs.mozilla.org/remote/Security.html), 2026-10-08 확인)
- host 는 `masc-browser-host --bidi-url ws://127.0.0.1:PORT/session` 으로 띄운다.
  이 명령을 대신 실행해 주는 것이 없다.
  `connectors/browser/install-host.sh` 와 `scripts/install-local-build.sh` 에 BiDi 가 나오지 않는다.
  손으로 붙이는 절차는 #41817 이 `docs/design/browser-bidi-live-host.md` 와 host README 에 적었다.
- BiDi host 는 세 경우에 끝난다 (`run_bidi`): 명령의 결과를 모르게 됐을 때, 서버에 묻는 요청(poll)이 실패했을 때,
  결과를 서버에 보내지 못했을 때. 확장 host 는 실패하면 잠시 뒤 다시 묻지만 BiDi host 는 다시 묻지 않는다.
  그래서 MASC 서버를 재시작하면 BiDi host 가 끝난다. 다시 띄우는 것도 손으로 한다.
  #41851 이 이것을 바꿨다. poll 과 결과 전송이 실패해도 끝나지 않고 다시 한다(§3.B 의 4).
- 끝난 이유는 host 자기 로그에만 남는다 (`bin/masc_browser_host.ml`). 서버는 연결이 끊겼다는 것만 안다.
- BiDi 소켓이 끊겨도 host 는 끝나지 않는다. `Browser_bidi_peer.with_connection` 은 끊긴 것을 적어 두기만 하고,
  `run_bidi` 의 poll 은 peer 를 보지 않고 계속 돈다. 그 뒤에 온 읽기 요청은 실패로 답하고 다시 poll 한다.
  그래서 Firefox 를 꺼도 서버의 연결 목록에는 그 BiDi 연결이 남는다.
  #41851 뒤로는 host 가 끝나고 서버에 disconnect 를 보낸다. 실제 Firefox 157.0.1 을 꺼서 확인했다.
- 서버가 연결의 등록을 끝내는 경우가 있다. poll 이 120초 넘게 없으면 서버가 그 `client_id` 를 끝내고
  (`Browser_lane.lane_connected_window_sec`, `retired_clients`), 그 뒤의 poll 에는 HTTP 400 으로 답한다.
  같은 ID 로는 서버가 다시 뜰 때까지 못 붙는다.
  확장 host 는 이때 끝나고, 확장이 5초 뒤 새 host 를 띄워 새 ID 로 붙는다 (`background.js`).
  BiDi host 는 다시 띄워 주는 것이 없다.
- BiDi 세션은 소켓보다 오래 남는다. Firefox 157.0.1 을 임시 프로필로 띄워 쟀다(2026-10-08, headless).
  - host 를 멈춘 뒤(SIGTERM, SIGKILL 둘 다) 같은 Firefox 에 host 를 다시 띄우면 붙지 못한다.
    `session.new` 가 `session not created`("Maximum number of active sessions")로 거절된다.
    Firefox 는 세션을 하나만 받는다
    ([MDN](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/session/new), 2026-10-08 확인).
  - 남은 세션에 다시 들어가는 길도 없다. `ws://127.0.0.1:PORT/session/<세션 ID>` 는 404 다.
  - 세션을 만든 소켓에서 `session.end` 를 보내면 세션이 끝난다. Firefox 는 계속 떠 있고 탭도 그대로다.
    바로 다음 `session.new` 가 된다. 세 번 되풀이해 같았다.
  - host 는 지금 `session.end` 를 보내지 않는다 (`browser_host.ml` 의 `run_bidi` 주석이 그렇게 정해 두었다).
    그래서 host 가 한 번 끝나면 Firefox 를 다시 띄워야 다시 붙는다.
    #41853 이 이것을 바꿨다. host 가 끝날 때 `session.end` 를 보낸다.
    SIGTERM 으로 멈춘 host 뒤에 두 번째 host 가 같은 Firefox 에 붙는 것을 실제 Firefox 157.0.1 로 확인했다.
- TUI 는 연결마다 `WebExtension`/`BiDi` 와 못 하는 일을 보여 준다. 붙어 있는 BiDi 연결은 브라우저 고르기 목록에 보인다.
  붙은 BiDi 연결이 없다는 말과 붙이는 문서 경로는 못 하는 동작을 시도한 뒤에야 나온다.

### 2.5 지금 운영 상태

2026-10-08 11:36 KST 에 다시 시작된 서버(`c8e8125b03`)에서 읽었다.

- 연결 목록은 Firefox 157.0 의 `web_extension` 연결 하나다. BiDi 연결은 없다.
- Keeper 도구에는 `hover_at` 이 있다. 지금 부르면 거절된다.
  이 서버에는 #41795 가 없어서 거절 문구는 `trusted_hover_requires_live_bidi_connection` 한 단어다.
  어느 연결로 가면 되는지는 #41795 가 배포된 뒤에 나온다.
- 같은 날 Keeper 의 호출 로그에는 10:32 에 거절된 `drag` 가 있다.
  10:52 와 11:30 에는 "browser lane 이 제때 답하지 않았다"가 남았다.
  11:29 에 host 실행 파일이 바뀌었고 그 직후 연결 ID 가 바뀌었다. Keeper 는 11:32 에 `selected_client_disconnected` 를 받았다.

### 2.6 BiDi 에 빠진 것을 채우는 비용

| 빠진 것 | 채우는 길 | 걸리는 점 |
|---|---|---|
| 요소 목록 | automation·stagehand 가 쓰는 `Browser_page_script.elements` 를 그대로 실행 | 채웠다 (#41813) |
| HTML 포함 읽기 | automation 이 쓰는 `Browser_lane.Document.runtime` 을 그대로 실행. helper 는 결과가 1 MiB 를 넘으면 HTML 을 빼고 이유를 적는다 | 채웠다 (#41813) |
| 탭 앞으로 가져오기 | BiDi `browsingContext.activate` | 탭을 앞으로 가져오면서 포커스도 준다 ([MDN](https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi/Modules/browsingContext/activate)). W3C 명세는 그 창에 시스템 포커스를 준다고 적는다. `activate_tab` 은 "창 포커스 없이"를 약속한다 |
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
| BiDi 가 표식 탭을 하나 열고, 확장이 그 탭을 본다 | 운영자 브라우저에 탭이 열렸다 닫힌다. peer 는 지금 탭을 열지도 닫지도 않는다 |
| BiDi 가 이미 열린 탭의 DOM 에 표식 값을 적고, 확장이 그 값을 읽는다 | 탭을 새로 열지 않고, 탭마다 하면 번호 대응표도 된다. 대신 운영자가 보는 페이지의 DOM 을 건드린다 |
| 두 쪽이 같은 문서의 URL 과 시작 시각을 읽어 맞춘다 | 값이 겹치면 못 정한다. 겹칠 때 거절해야 한다 |

`expectedUrl` 확인이 이 위험을 다 막아 주지는 않는다. 포인터 동작과 `follow_link`, `activate_tab` 에서는 필수지만
`click`·`fill`·`scroll` 은 없이도 받는다 (`Browser_interaction.parse`).
그래서 A 를 하려면 두 연결을 오가는 모든 동작에 이 확인을 필수로 만들어야 한다.
그렇게 해도 짝이나 번호가 틀리면 URL 이 같은 다른 탭은 눌린다. Slack 처럼 같은 주소의 탭을 여럿 여는 곳에서는 그것으로 충분히 위험하다.

탭 대응표는 탭이 새로 열리거나 닫힐 때, 그리고 둘 중 한 연결이 다시 붙을 때 다시 맞춰야 한다.
탭을 옮기거나 그 탭 안에서 다른 주소로 가는 것으로는 깨지지 않는다.
확장의 탭 ID 는 브라우저를 끌 때까지 그 탭에 붙어 있고
([MDN](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/tabs)),
BiDi peer 는 한 번 번호를 준 context 를 순서와 상관없이 같은 번호로 둔다 (`Browser_bidi_peer.tree`).
한쪽에서 읽은 `documentId`·`nodeId`·`viewport` 를 다른 쪽에 넘길 때도 같은 문제가 생긴다.
읽은 것과 누르는 것 사이에 연결이 바뀌므로, "읽은 화면 그대로 누른다"는 지금의 보장이 약해진다.

### B. BiDi 연결 하나가 다 한다

BiDi 에 빠진 것을 채우고, BiDi 를 붙이는 일을 운영자의 정식 동작으로 만든다.
WebExtension 은 지금처럼 "설치만 하면 읽는" 연결로 둔다.

필요한 것:

1. BiDi peer 가 요소 목록과 HTML 포함 읽기를 한다 (§2.6 첫 두 줄). #41813 에서 했다.
2. BiDi 를 붙이는 명령 하나와 그 상태를 TUI·`masc doctor` 에 보여 준다.
   `masc doctor` 의 browser 검사는 지금 native host 설치와 서버 주소만 본다
   (`lib/operator/onboarding_status.ml` 이 `Browser_lane_launcher.observe` 를 읽는다). 붙어 있는 연결은 보지 않는다.
   doctor 는 서버 없이도 돌아야 하므로 아래 4번의 host 기록 파일을 읽는다. 서버가 답하면 연결 목록도 같이 본다.

   설정 명령에 더하는 단계는 확인만 하고 끝난다. 포트가 열려 있는지, host 기록 파일의 상태가 무엇인지,
   붙이는 명령이 무엇인지를 말한다. host 를 띄우지는 않는다.
   host 는 브라우저 일을 하는 내내 살아 있어야 하는 프로세스다. 설치 마법사가 부르는 명령 안에서 띄우면 그 명령이 끝나지 않는다.
   host 의 주인은 운영자의 터미널이다. 운영자가 foreground 로 띄우고 Ctrl-C 로 멈춘다(#41817 의 절차).
   백그라운드 서비스로 만들지 않는다. 필요해지면 `start`/`status`/`stop` 스크립트로 하고, 그것은 따로 정한다.
   한 workspace 에 BiDi host 는 하나다. Firefox 도 세션을 하나만 받는다(§2.4).
   Firefox 를 플래그로 띄우는 것은 운영자가 한다. MASC 는 띄우지 않는다.
   RFC `setup-web-search-and-browser-lane` 이 제안한 "다시 열리는 설정 명령"에 이 단계를 더하는 모양이 맞다.
3. host README 에 BiDi 절을 넣는다. #41817 에서 했다.
4. host 가 끝났을 때 TUI 가 이유와 다시 붙이는 법을 보여 준다. 지금은 이유가 서버에 오지 않는다(§2.4).
   끝나기 직전에 서버로 보내는 보고로는 풀리지 않는다. 서버가 재시작해서 끝나는 경우에는 그 보고도 같이 실패한다.
   그래서 host 가 이렇게 움직이게 한다.
   - 서버에 묻는 요청이 실패했을 때는 끝나지 않고 확장 host 처럼 잠시 뒤 다시 묻는다. #41851 에서 했다.
     브라우저에 아무것도 보내지 않은 상태라서 다시 물어도 같은 동작이 두 번 나가지 않는다.
   - 결과를 서버에 보내지 못했을 때는 확장 host 의 `publish` 와 같은 규칙을 쓴다. #41851 에서 했다.
     하면서 확장 host 에도 있던 틈을 고쳤다. 서버가 응답 없이 연결을 닫으면 "서버가 받고 거절했다"로 세어 결과를 버렸다.
     서버에 닿지 않았으면 같은 결과를 다시 보내고, 전달됐거나 서버가 받고 거절한 뒤에야 다음 요청을 묻는다.
     결과를 버리고 넘어가면 서버는 시간 초과로 끝내고, 이미 일어난 동작을 Keeper 가 다시 시킬 수 있다.
   - 다시 묻거나 다시 보낼 때 서버 주소도 확장 host 처럼 따라간다(`follow_workspace`). #41851 에서 했다.
     지금 `run_bidi` 는 처음 정한 주소로만 보낸다. 서버가 다른 포트로 다시 뜨면 같은 주소로는 다시 붙지 못한다.
     요청을 낸 서버가 없어지고 다른 서버가 답하면, 그 결과는 전달하지 못한 것으로 적고 새 서버에 다시 등록한다.
     새 서버는 그 요청을 모른다. 요청 ID 는 서버 메모리에만 있고 재시작하면 사라진다.
     그래서 이미 일어난 동작을 Keeper 가 다시 시킬 수 있다는 위험은 남는다. 확장 host 도 지금 같다(`Issuer_moved`).
     줄이는 것은 두 가지다. 전달하지 못한 결과를 아래 host 기록 파일에 남겨 TUI 가 보여 준다
     (요청 ID, 동작 이름, 성공·실패·모름, 시각. 페이지 내용과 인자는 넣지 않는다).
     Keeper 스킬에는 서버가 다시 뜬 뒤 첫 동작 전에 페이지를 다시 읽으라고 적는다.
     서버가 요청과 결과를 재시작 너머로 기억해 스스로 맞추는 것은 이 RFC 가 다루지 않는다.
   - 서버가 등록을 거절하면(HTTP 400, §2.4) 까닭에 따라 다르게 한다.
     서버가 이 연결을 끝낸 것이면 새 `client_id` 로 다시 등록한다.
     poll 은 host 가 쉬는 동안에만 보내므로 그때 걸려 있는 동작이 없다.
     탭 번호와 관측은 연결마다 따로라서 Keeper 는 새 연결의 탭 목록부터 다시 읽는다.
     그 밖의 거절(헤더가 틀림, 같은 ID 인데 브라우저 정보가 바뀜)은 다시 물어도 같은 답이므로 끝내고 이유를 남긴다.
     같은 ID 로 끝없이 다시 묻지 않는다.
   - BiDi 연결이 끊기면 host 가 끝난다. 일을 기다리는 중이어도 끝난다. #41851 에서 했다.
     그 전에는 끝나지 않고 죽은 연결로 남았다(§2.4).
   - 정리하면 host 가 끝나는 경우는 셋이다: 명령의 결과를 모르게 됐을 때, BiDi 연결이 끊겼을 때,
     서버가 다시 물어도 같은 답일 거절을 했을 때.
   - host 는 끝날 때 자기가 만든 BiDi 세션을 끝낸다(`session.end`). Ctrl-C 나 SIGTERM 으로 멈출 때도 그렇다. #41853 에서 했다.
     안 끝내면 Firefox 를 다시 띄워야 다시 붙는다(§2.4).
     탭이나 브라우저를 닫는 명령은 지금처럼 보내지 않는다. `session.end` 는 탭과 Firefox 를 그대로 둔다(§2.4).
     강제 종료(SIGKILL)나 crash 뒤에는 세션을 끝내지 못한다. 그때는 Firefox 를 다시 띄운다. 문서에 그렇게 적는다.
     `session.end` 는 소켓이 열려 있는 동안만 보낼 수 있다. 그래서 끝나는 경우마다 다르다.
     - 명령이 답을 못 받아 host 가 그 연결을 더 믿지 않게 된 경우(시간 초과): 소켓은 아직 열려 있으므로 보낸다.
       페이지 스크립트가 멈춘 것이지 브라우저가 없어진 것이 아니다.
       peer 는 이 경우 그 연결로 페이지 명령을 더 보내지 않는다. 세션 끝내기만은 따로 보낸다(#41853).
     - 소켓이 이미 닫힌 경우: 보내지 못한다. Firefox 가 꺼져서 닫힌 것이면 세션도 같이 없어졌으니 할 일이 없다.
       Firefox 는 살아 있는데 소켓만 끊긴 것이면 SIGKILL 과 같다. Firefox 를 다시 띄운다.
     - Firefox 가 `session.end` 에 답하지 않는 경우: 정해 둔 시간만 기다리고 끝난다. 이것도 SIGKILL 과 같다.
     세션을 끝내지 못한 채 끝날 때는 host 가 그 사실과 할 일을 로그와 기록 파일에 적는다.
   - 끝난 이유와 전달하지 못한 결과는 workspace 의 파일 하나에 남긴다(`<base>/.masc/browser-lane/` 아래).
     이 문서는 그 파일을 host 기록 파일이라 부른다. 서버, TUI, `masc doctor` 가 읽는다.
     파일은 host 가 붙을 때부터 있다. host 는 붙으면서 자기 pid, 프로세스 시작 시각, `client_id`, BiDi 주소를 적고,
     끝나면서 끝난 시각과 이유를 적는다.
     읽는 쪽은 같은 장비에 있으므로 그 pid 가 살아 있는지 직접 본다. 그래서 서버 없이도 네 상태가 갈린다.
     - 붙어 있음: 끝난 기록이 없고 그 프로세스가 살아 있다. 서버가 내려가 host 가 다시 묻는 중이어도 이 상태다.
     - 끝남: 끝난 기록이 있다.
     - 기록 없이 죽음: 끝난 기록이 없는데 그 프로세스가 없다. SIGKILL 이나 crash 다. 세션이 Firefox 에 남았을 수 있다.
     - 붙인 적 없음: 파일이 없다.
     pid 가 다른 프로세스에 다시 쓰인 경우는 같이 적어 둔 시작 시각으로 거른다.
     새 host 는 붙으면서 이전 기록을 덮어쓴다. 살아 있는 host 의 기록이 있으면 덮어쓰지 않고 그 pid 를 말하며 끝난다.
     시각을 주기적으로 갱신하는 heartbeat 는 두지 않는다. 프로세스를 직접 볼 수 있어서 필요 없고,
     죽은 host 가 남긴 시각을 "살아 있음"으로 읽을 일도 없다.
     서버가 떠 있지 않아도 남고, 다시 뜬 서버도 읽을 수 있다.

탭 번호와 관측은 한 연결 안에서만 쓰이므로 대응표가 필요 없다.

확장과 BiDi 가 둘 다 붙어 있으면 live 레인에 연결이 둘이다. 그때 `clientId` 없는 요청은
`ambiguous_browser_clients` 로 거절된다 (`Browser_lane.resolve_target`). 브라우저 둘을 붙였을 때와 같은 규칙이다.
B 는 이 규칙을 바꾸지 않는다. Keeper 는 일을 시작할 때 연결 목록에서 `webdriver_bidi` 연결을 고르고,
그 일이 끝날 때까지 같은 `clientId` 를 쓴다. 고르는 데 필요한 `transport` 는 연결 목록과 거절 응답에 이미 있다.
BiDi 만 붙여 두면 연결이 하나라서 고를 것이 없다.
"BiDi 가 붙어 있으면 그쪽을 기본으로 고른다"를 서버에 넣는 것은 하지 않는다.
두 연결이 같은 브라우저인지 서버가 모르는 채로 고르게 되기 때문이다. 그건 A 의 문제다.

### C. 그대로 둔다

Keeper 가 거절 문구(#41795 의 `live_transport_unsupported` 와 `servingClients`)를 보고 직접 연결을 바꾼다.
BiDi 는 운영자가 문서를 보고 손으로 붙인다.

## 4. 비교

| | A 한 쌍 | B BiDi 하나 | C 그대로 |
|---|---|---|---|
| 리액션에 필요한 동작 | BiDi 가 붙으면 됨 | BiDi 가 붙으면 됨 | BiDi 를 손으로 붙이면 됨 |
| 새로 생기는 판단 | 같은 브라우저 증명, 탭 대응 | 없음. 둘 다 붙어 있으면 Keeper 가 `clientId` 로 연결을 고른다(지금도 있는 규칙) | 같음 |
| 읽은 화면 그대로 누른다는 보장 | 약해짐 | 그대로 | 그대로 |
| 운영자가 할 일 | Firefox 를 플래그로 띄우기 + 확장 | Firefox 를 플래그로 띄우기 | 같음 + 문서 찾기 |
| 열린 포트의 위험 | 있음 | 있음 | 있음 |
| 코드 크기 | 큼 (서버 라우팅, 대응표, 증명) | 중간 (빈칸 채우기는 작고, host 가 끝난 이유를 알리는 보고가 새로 든다) | 0 |

"됨"은 코드와 fixture 페이지 기준이다. 실제 Slack 에서는 아무도 해 보지 않았다(§2.2).

A 와 B 모두 Firefox 를 플래그로 띄워야 한다. A 가 이 부담을 덜어 주지 않는다.
B 는 BiDi 의 빈칸을 BiDi 안에서 채운다(§2.6). 그래서 A 만 주는 것은 둘이다.
포커스를 가져가지 않는 탭 전환, 그리고 §2.6 넷째 줄을 만들기 전까지 링크를 따라간 뒤 새 문서를 기다려 주는 확장의 동작이다.

## 5. 제안

B 를 먼저 한다. A 는 B 뒤에 "두 방식이 같은 흐름에 꼭 필요한 일"이 실제로 나오면 다시 연다.

이유:

- 지금 막힌 일(리액션)은 BiDi 하나로 된다 (§2.2).
- A 의 두 판단(같은 브라우저, 탭 대응)은 틀렸을 때 다른 탭을 누른다. 로그인된 브라우저에서 이 피해는 크다.
- A 는 B 의 운영 부담(§2.4)을 그대로 안고 간다.

B 의 순서:

1. BiDi 붙이기. 지금 막힌 일을 푸는 것은 이 단계다. 리액션에 필요한 동작은 이미 BiDi 가 다 하고(§2.2),
   없는 것은 붙어 있는 BiDi 연결이다(§2.5). 운영자 결정(§7 의 1)이 먼저고, 그 뒤에 붙이는 명령,
   TUI 와 `masc doctor` 의 "BiDi: 붙음 / 안 붙음 · 붙이는 법", host 가 끝난 이유 보고를 만든다.
2. BiDi 의 빈칸 채우기: 요소 목록과 HTML 포함 읽기. 운영자 결정이 필요 없고 작아서 #41813 에서 먼저 했다.
   표의 칸이 바뀌었고 `test_browser_bidi_peer` 가 그 칸을 확인한다. 남은 빈칸은 탭 앞으로 가져오기(§7 의 2)다.
3. README·스킬 문서. 손으로 붙이는 절차와 Keeper 의 순서는 #41817 에서 적었다. 붙이는 명령이 생기면 다시 고친다.

하지 않는 것:

- MASC 가 Firefox 를 띄우거나 프로필·설정을 바꾸는 일.
- 로그인이나 쿠키를 다른 세션으로 옮기는 일.
- WebExtension 에서 마우스 올리기를 흉내 내는 일. 확장이 만드는 이벤트는 trusted 가 아니고,
  Keeper 가 그런 입력으로는 Slack 의 리액션 버튼을 열지 못했다(Board 글).
- Slack API 로 리액션을 다는 일. Keeper 의 browser 스킬은 browser 조작이 안 될 때 Slack API 로 돌아가지 말라고 적고 있고
  (`skills/browser-lanes/references/sites/slack.md`), 이 RFC 는 browser lane 이 그 일을 하게 하는 길을 다룬다.

## 6. 확인 방법

1. 소유한 임시 프로필의 Firefox 와 fixture 페이지(마우스를 올려야 버튼이 보이는 페이지)로,
   BiDi 연결 하나에서 `hover_at` → 스크린샷 → `click_at` → 상태 변화까지 확인한다.
   `test/test_browser_bidi_host.py` 가 이 흐름을 본다 (#41813). 스크린샷 대신 scene 읽기로 버튼 위치를 얻는다.
2. 요소 목록: 같은 fixture 에서 BiDi 와 automation 의 `mode=elements` 결과가 같은지 본다.
   두 레인이 같은 스크립트를 실행한다는 것은 단위 테스트가 확인한다. 나란히 돌려 보는 것은 geckodriver 가 있는 곳에서 한다.
3. HTML 포함 읽기: 실제 Firefox 에서 문서 하나를 온전히 읽는지(`htmlComplete: true`, `documentId` 가 화면의 것과 같음),
   1 MiB 를 넘는 문서에서는 HTML 이 빠지고 `document_html_exceeds_1_mib` 가 적히는지 본다.
   `Lane_addon_sources` 가 읽는 필드는 확장과 같은 helper 가 만들므로 모양이 같다.
   `test/test_browser_bidi_host.py` 가 두 경우를 본다 (#41813).
4. 붙이기 명령: 포트가 닫힌 상태, 열린 상태, host 가 끝난 뒤 상태에서 TUI 문구를 PTY 로 확인한다.
   서버를 같은 포트로, 그리고 다른 포트로 재시작한 뒤 host 가 다시 붙는지 본다.
   결과를 보내는 도중에 서버가 내려갔다 올라오면 같은 결과가 한 번 전달되는지, host 기록 파일을 다시 뜬 서버가 읽는지도 본다.
   - host 가 일을 기다리는 동안 Firefox 나 BiDi 소켓을 닫는다. host 가 끝나는지, 이유가 파일에 남는지,
     서버의 연결 목록과 TUI 에서 그 연결이 사라지는지 본다.
   - 서버가 연결의 등록을 끝낸 뒤(HTTP 400) host 가 새 `client_id` 로 다시 붙는지,
     다시 물어도 같은 답일 거절에는 끝나고 이유를 남기는지 본다.
   - host 가 소켓이 열린 채 끝난 뒤(결과를 모름, 등록 거절, Ctrl-C, SIGTERM) Firefox 를 다시 띄우지 않고 host 를 다시 붙인다.
     실제 Firefox 에서 붙는지, 탭이 그대로인지 본다.
     명령이 답을 못 받아 끝난 경우에도 `session.end` 가 나가는지 본다.
     SIGKILL 뒤와, Firefox 는 살아 있는데 소켓만 끊긴 뒤에는 붙지 못하고 까닭을 말하는지 본다.
   - `masc doctor` 가 네 상태(붙어 있음, 끝남, 기록 없이 죽음, 붙인 적 없음)를 서버가 떠 있을 때와 꺼져 있을 때 각각 말하는지 본다.
     서버가 꺼져 host 가 다시 묻는 중일 때 "붙어 있음"으로 말하는지, 새 host 가 붙으면 이전의 "끝남" 기록이 사라지는지도 본다.
   - 설정 명령의 BiDi 단계가 host 를 띄우지 않고 끝나는지 본다.
5. 받는 쪽 확인: `kidsnote-incoming-dd-manager` 가 실제 Slack 에서 리액션 하나를 달고,
   다시 찍은 화면에서 그 리액션을 확인한다. 이것이 #41594 의 완료 조건이다.

## 7. 운영자 결정 (2026-10-08)

세 가지를 물었고 운영자가 이렇게 정했다.

1. **Firefox 를 `--remote-debugging-port` 로 띄우는 것: 전용 프로필로 한다.**
   Keeper 가 일하는 곳(Slack 등)만 로그인한 Firefox 프로필을 따로 두고, 그 프로필만 플래그로 띄운다.
   평소 쓰는 프로필은 플래그 없이 그대로 둔다.
   그 포트로 읽을 수 있는 쿠키는 전용 프로필 것뿐이다. 운영자가 그 프로필에 한 번 로그인한다.
   이 프로필에는 확장을 붙이지 않아도 된다. BiDi 연결 하나가 `activate_tab` 을 뺀 모든 일을 한다(§2.1).
2. **BiDi 의 탭 앞으로 가져오기: 넣지 않는다.**
   BiDi 연결은 `activate_tab` 을 계속 거절한다. 리액션 흐름에는 필요 없다.
3. **A(두 연결을 한 쌍으로 묶기): 지금은 하지 않는다.**
   B 만 진행한다. A 가 꼭 필요한 일이 실제로 나오면 이 RFC 를 다시 연다.

남은 구현은 §5 의 1번이다. 2번(BiDi 의 빈칸 채우기)은 #41813, 3번(문서)은 #41817 에서 했다.

- §5 의 1번: 붙이는 명령, TUI 와 `masc doctor` 의 상태 표시,
  그리고 §3.B 의 4 가 적은 host 의 동작.
  그 가운데 서버 재시작에 끝나지 않기와 끊긴 BiDi 에 끝나기는 #41851 에서 했다.
  세션 끝내기는 #41853 에서 했다.
  남은 것은 서버가 끝낸 연결을 새 ID 로 다시 등록하기와 기록 파일이다.
