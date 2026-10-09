---
rfc: "browser-keeper-firefox"
title: "Start the Keeper Firefox and its BiDi host with the MASC server"
status: Draft
created: 2026-10-09
updated: 2026-10-09
author: vincent + claude
related: ["browser-live-one-connection"]
---

# RFC — Keeper 전용 Firefox 와 BiDi host 를 MASC 서버가 같이 켠다

## 1. 문제

Keeper 가 Slack 에 리액션을 달려면 hover 가 필요하고, hover 는 BiDi 연결만 한다
(`Browser_lane.live_transport_serves`, RFC-browser-live-one-connection §2.1).
그 연결은 지금 운영자가 터미널 두 개로 붙인다.

1. 전용 프로필 Firefox 를 `--remote-debugging-port 9222` 로 띄운다.
2. 다른 터미널에서 `<base>/.masc/browser-lane/host/launch --bidi-url ws://127.0.0.1:9222/session` 을 띄운다.

두 터미널을 닫으면 연결이 끊긴다. MASC 서버를 다시 띄워도, 컴퓨터를 다시 켜도 운영자가 다시 해야 한다.
2026-10-09 운영자가 이 일을 처음 하고 "터미널 같은 거 안 하고 MASC 안에서" 되기를 원했다.

## 2. 확인한 사실 (main `1f5e6a0b2b`, 2026-10-09)

### 2.1 지금 문서가 정한 것

- `docs/design/browser-bidi-live-host.md` §Attaching a connection:
  "The operator does both steps. Nothing in MASC starts this Firefox or this host."
- RFC-browser-live-one-connection §2.4 은 "이 명령을 대신 실행해 주는 것이 없다"고 적었다.
  §7 의 결정 1(전용 프로필)은 이 RFC 에서도 그대로 간다. 바뀌는 것은 "누가 켜는가"다.

### 2.2 서버가 이미 띄우는 브라우저

- `[browser.automation]`: 서버가 시작할 때 geckodriver 를 띄운다(`Server_browser_webdriver.start`,
  `server_runtime_bootstrap.ml`). 띄운 pid 를 `<base>/.masc/browser-lane/geckodriver-owner.json` 에 적고,
  다음 서버가 앞 서버가 남긴 driver 를 멈춘다. 설정 표가 없으면 띄우지 않는다
  ("automation has no browser.automation.geckodriver").
  driver 와 브라우저는 서버의 switch 에 묶여 서버와 같이 멈춘다.
  Firefox 프로필은 `--profile-root` 아래에 세션마다 새로 생긴다. 로그인이 남지 않아서 Slack 일에는 못 쓴다.
- `[browser.stagehand]`: `profile` 에 운영자가 가진 프로필 디렉터리를 적으면 세션 사이에 그 프로필을 쓴다.
  로그인이 남는 프로필을 설정으로 받는 선례다.
- `Process_eio.spawn_detached` 와 `spawn_detached_devnull`: 자기 process group 으로 띄우고,
  띄운 쪽의 Eio switch 가 끝나도 죽지 않는다. 서버 안에서는 `spawn_detached_devnull` 을 이미 쓴다
  (`server_routes_http_routes_sidecar.ml`).

### 2.3 설정

- `[browser.live]` 는 `enabled` 하나만 받는다. `runtime.toml` 은 모르는 키를 로드 오류로 거절한다.
  그래서 새 키는 그 키를 아는 바이너리를 먼저 배포한 뒤에 써야 한다.
- `runtime.toml` 은 운영자 것이다. MASC 가 이 표를 스스로 쓰지 않는다.

### 2.4 Firefox 와 host

- Remote Agent 는 명령줄 플래그로만 켠다. 이미 떠 있는 Firefox 에는 켤 수 없다(Mozilla Remote Agent 문서).
  그래서 그 Firefox 는 이 플래그를 주는 쪽이 띄워야 한다.
- 그 포트에는 인증도 암호화도 없다. loopback 에서만 받는다. 붙는 로컬 프로세스는 그 브라우저를 움직이고 쿠키를 읽는다.
- 2026-10-09 10:40Z 에 이 장비에서 운영자가 띄운 Firefox 는 stderr 에
  `WebDriver BiDi listening on ws://127.0.0.1:9222` 를 썼다.
- host 는 서버 재시작에도 붙어 있다(#41851). 서버가 끝낸 연결은 새 ID 로 다시 등록한다(#41898).
  Firefox 가 꺼지면 host 도 끝난다. 끝날 때 `session.end` 를 보낸다(#41853).
- host 는 자기 기록 `bidi-host.json` 과 잠금 `bidi-host.lock` 을 남긴다(#41919).
  두 번째 host 는 잠금을 못 잡고 Firefox 에 닿기 전에 끝난다.
- 연결 목록·`masc doctor`·Keeper 거절 답은 그 기록을 읽어 다음 할 일을 말한다(#41971).
  지금 그 문장은 "운영자가 Firefox 를 띄우고 host 를 실행한다"고 말한다.

## 3. 제안

### 3.1 설정

```toml
[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "/Users/dancer/masc-keeper-firefox-profile"
port = 9222
```

- `firefox`, `profile` 은 절대 경로이고 빠질 수 없다. `profile` 은 운영자가 로그인해 둔 디렉터리다.
  지금 손으로 쓰는 `~/masc-keeper-firefox-profile` 을 적으면 다시 로그인하지 않아도 된다.
- `port` 를 빼면 9222 다. 주소는 언제나 `ws://127.0.0.1:<port>/session` 이다.
- 이 표가 있으면 서버가 켠다. 없으면 지금처럼 아무것도 켜지 않는다. `[browser.automation]` 과 같은 규칙이다.
- `[browser.live] enabled = false` 이면 이 표가 있어도 켜지 않는다.

### 3.2 서버가 뜰 때

서버는 빠진 것만 켠다. 이미 떠 있는 것은 그대로 쓴다.

1. 그 포트에 무언가 듣고 있으면 Firefox 를 띄우지 않는다.
   듣는 것이 없으면 `firefox --no-remote --profile <profile> --remote-debugging-port <port>` 를 `spawn_detached` 로 띄운다.
   포트가 열릴 때까지 기다린다. 열리지 않거나 Firefox 가 먼저 끝나면 띄우지 않은 까닭을 기록한다(§3.4).
   같은 프로필로 이미 떠 있는 Firefox(플래그 없이 운영자가 띄운 것)가 있으면 Firefox 는 그 프로필을 두 번 열지 않는다.
   그때 Firefox 가 어떻게 끝나는지(종료 코드, 창)는 아직 재지 않았다. 구현 전에 잰다.
2. host 기록이 `Running` 이고 잠금이 잡혀 있으면 host 를 띄우지 않는다.
   아니면 `<base>/.masc/browser-lane/host/launch --bidi-url ws://127.0.0.1:<port>/session` 을 `spawn_detached` 로 띄운다.
   launcher 가 설치되어 있지 않으면 띄우지 않고 그렇게 기록한다
   (연결 목록이 이미 `bidiHost.attach.launcher_state` 로 말하는 그 상태다).
3. 이 일은 서버 시작을 막지 않는다. geckodriver 처럼 별도 fiber 에서 한다.

### 3.3 서버가 멈출 때와 다시 뜰 때

- 서버가 멈춰도 Firefox 와 host 는 멈추지 않는다(`spawn_detached`).
  배포할 때마다 서버가 다시 뜨는데, 그때마다 Keeper 창이 닫혔다 열리지 않게 하려는 것이다.
- 다시 뜬 서버는 §3.2 를 다시 한다. 둘 다 떠 있으면 아무것도 하지 않는다.
  host 는 #41898 대로 새 서버에 다시 등록한다.
- 이 점이 geckodriver 와 다르다. geckodriver 는 세션을 서버만 닫을 수 있어서 서버와 같이 멈춘다.
  BiDi host 는 스스로 `session.end` 를 보내고, 다음 host 를 위한 기록을 남긴다.

### 3.4 서버가 남기는 것

- `<base>/.masc/browser-lane/keeper-firefox.json`: 서버가 띄운 Firefox 의 pid, 프로필, 포트, 띄운 시각.
  띄우지 못했으면 그 까닭(포트를 다른 프로세스가 씀, 실행 파일 없음, 포트가 안 열림, 먼저 끝남).
  host 기록과 같은 방식으로 통째로 다시 쓴다.
- host 의 출력은 `<base>/.masc/browser-lane/bidi-host.log` 에 이어 쓴다. 지금은 운영자 터미널에 나온다.
  `spawn_detached_devnull` 은 출력을 버리므로, 파일로 보내는 갈래가 필요하다(구현 때 정한다).
- 연결 목록의 `bidiHost` 에 이 상태를 더한다. 문장도 바꾼다.
  - 설정이 있으면 "MASC 가 켠다"고 말하고, 실패했으면 그 까닭과 고칠 것을 말한다.
  - 설정이 없으면 지금 문장에 "`[browser.live.bidi]` 를 적으면 MASC 가 켠다"를 더한다.

### 3.5 Firefox 가 꺼졌을 때

운영자가 Keeper 창을 닫거나 Firefox 가 죽으면 host 도 끝난다(§2.4).
이 RFC 의 1단계에서는 다음 서버 시작 때 다시 켠다. 그 사이 hover·drag 를 부탁받은 Keeper 는
지금처럼 `live_transport_unsupported` 답과 `bidiHost` 문장을 받는다.
시간을 정해 두고 다시 켜는 고리는 두지 않는다. 운영자가 일부러 닫은 창을 MASC 가 되살리지 않게 하려는 것이다.
Keeper 가 필요할 때 다시 켜는 것은 §7 의 결정을 기다린다.

### 3.6 바뀌는 문서

- `docs/design/browser-bidi-live-host.md` §Attaching a connection: "Nothing in MASC starts this Firefox or this host"
  를 지우고, 설정 한 덩어리로 켜는 절차를 첫 길로 적는다. 손으로 띄우는 절차는 설정이 없을 때의 길로 남긴다.
- RFC-browser-live-one-connection §2.4 의 "이 명령을 대신 실행해 주는 것이 없다"는 그 RFC 를 쓴 때의 사실이다.
  그 RFC 에 이 RFC 를 `related` 로 걸고, §7 끝에 "누가 켜는가는 RFC-browser-keeper-firefox 가 정한다"고 적는다.

## 4. 하지 않는 것

- 로그인을 대신하지 않는다. 처음 한 번은 운영자가 그 창에서 Slack 에 로그인한다.
  평소 쓰는 Firefox 의 쿠키를 옮기지 않는다.
- 평소 쓰는 Firefox 에는 손대지 않는다. `--no-remote` 와 전용 프로필로 따로 띄운다.
- `runtime.toml` 을 MASC 가 쓰지 않는다. 운영자가 `[browser.live.bidi]` 를 적는다.
- headless 로 띄우지 않는다. 운영자가 Keeper 가 하는 일을 볼 수 있고, 로그인이 풀리면 그 창에서 다시 로그인한다.
- launchd 같은 OS 서비스로 등록하지 않는다. 서버가 뜰 때 켠다.

## 5. 보안 영향

- 지금도 운영자가 띄워 두면 같은 포트가 열린다. 바뀌는 것은 열려 있는 시간이다.
  MASC 서버가 도는 동안 늘 열리고, 서버가 멈춰도 Firefox 가 떠 있는 동안 열려 있다(§3.3).
- 그 시간 동안 이 장비의 어떤 로컬 프로세스든 그 Firefox 를 움직이고, 그 프로필의 쿠키를 읽을 수 있다.
  전용 프로필에 Keeper 가 일하는 사이트만 로그인하는 것이 그 범위를 줄인다(RFC-browser-live-one-connection §7 의 1).
- loopback 에서만 받는 것은 Firefox 가 정한다. MASC 는 `--remote-debugging-port` 에 주소를 주지 않는다.

## 6. 단계

1. 이 RFC (문서만).
2. 설정: `Browser_configuration` 이 `[browser.live.bidi]` 를 읽는다. 아직 아무것도 켜지 않는다.
   이 PR 이 배포된 뒤에 운영자가 `runtime.toml` 에 표를 적는다(§2.3).
3. 서버가 Firefox 와 host 를 켠다(§3.2~§3.4). `keeper-firefox.json`, `bidi-host.log`.
4. 연결 목록·doctor·Keeper 답의 문장과 TUI 의 host 줄이 "MASC 가 켠다"를 말한다. 설계 문서를 고친다(§3.6).

## 7. 확인 방법

- 설정 파서: 빠진 키, 상대 경로, 모르는 키, `enabled = false` 와 함께 있을 때.
- 켜는 순서: 포트가 이미 열림 / 비어 있음 / 다른 프로세스가 씀, host 잠금이 잡힘 / 안 잡힘, launcher 없음,
  같은 프로필을 플래그 없이 연 Firefox 가 이미 있음.
  실제 Firefox 대신 포트만 여는 가짜 실행 파일로 OCaml 테스트를 쓴다.
- 서버 재시작: 떠 있는 Firefox 와 host 를 다시 띄우지 않는다. host 가 새 서버에 다시 등록한다.
- 실제 Firefox 157 을 임시 프로필로 띄워 한 번 끝까지 확인한다(headless 가 아닌 창은 로컬에서만).
- 이 장비에서 운영자 프로필로 서버를 다시 띄워, 손대지 않고 연결 목록에 `webdriver_bidi` 가 생기는지 본다.

## 8. 운영자 결정

### 정한 것 (2026-10-09)

1. **켜는 때: 서버와 같이 자동으로.** 버튼이나 별도 명령으로 켜지 않는다.

### 정할 것

1. **꺼진 Firefox 를 언제 다시 켜나.** 이 RFC 는 "다음 서버 시작 때"를 제안한다(§3.5).
   다른 길은 "Keeper 가 hover·drag 를 부탁할 때 켜고, 그 Keeper 는 잠시 뒤 다시 한다"다.
   손이 덜 가는 대신 운영자가 일부러 닫은 창도 다시 열린다.
2. **켜는 조건.** 이 RFC 는 "`runtime.toml` 에 `[browser.live.bidi]` 가 있을 때만"을 제안한다(§3.1).
   다른 길은 설정 없이 `~/masc-keeper-firefox-profile` 디렉터리가 있으면 기본값(macOS Firefox 경로, 9222)으로 켜는 것이다.
   설정을 적는 일이 없어지는 대신, 디렉터리 하나가 있다는 것만으로 포트가 열린다.
