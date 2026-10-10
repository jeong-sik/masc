---
rfc: "browser-keeper-firefox"
title: "Start the Keeper Firefox and its BiDi host with the MASC server"
status: Active
created: 2026-10-09
updated: 2026-10-10
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
- `Process_eio.spawn_detached` 와 `spawn_detached_devnull`: 자기 session 으로 띄우고, 띄운 쪽의 Eio switch 가 끝나도
  죽지 않는다. 그런데 `Unix.fork` 로 띄운다. OCaml 5 는 domain 이 여럿 도는 프로세스에서 fork 를 거절하고,
  서버가 geckodriver 를 posix_spawn 관리자(`Posix_spawn_process_mgr`)로 띄우는 것도 그 까닭이다.
  그래서 서버에서는 posix_spawn 으로 자기 process group 에 띄우고 switch 가 끝나도 멈추지 않는 길이 따로 필요하다
  (구현: `Posix_spawn_detached`).

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

0. host 를 같이 띄우지 않을 때는 Firefox 도 띄우지 않는다. 그 포트는 이 장비의 어떤 프로세스든 붙어서 조종할 수 있다(§5).
   - launcher 가 설치되지 않았거나 설치된 그대로가 아닐 때.
   - 잠금을 잡은 host 의 주소가 다른 포트이거나, 기록을 읽을 수 없어 주소를 모를 때.
     워크스페이스에는 host 가 하나뿐이라, 그 host 를 먼저 멈춰야 한다.
   - 잠금을 잡은 host 가 이 포트에 있을 때. host 는 시작할 때 한 번만 Firefox 에 붙으니,
     지금 띄우는 Firefox 에는 붙지 않는다. 포트가 비어 있으면 그 host 는 Firefox 가 사라져 곧 끝나고, 다음 서버 시작이 둘을 띄운다.
   서버는 그 까닭을 로그에 남긴다. host 를 띄울지는 이 한 번으로 정한다.
   - 기록에 끝난 까닭(`ended`)이 있는데 잠금이 아직 잡혀 있으면, 그 host 가 끝나는 중이다.
     host 는 끝난 까닭을 먼저 쓰고 나서 잠금을 놓는다. 이때 띄운 host 는 잠금에 막혀 끝나고 host 가 하나도 남지 않으니,
     잠금이 풀릴 때까지 5초까지 기다린다. 그래도 잡혀 있으면 아무것도 띄우지 않는다.
1. 그 포트에 무언가 듣고 있으면 Firefox 를 띄우지 않는다.
   듣는 것이 없으면 `firefox --no-remote --profile <profile> --remote-debugging-port <port>` 를 떨어진 프로세스로 띄운다(§2.2).
   포트가 열릴 때까지 기다린다. 열리지 않거나 Firefox 가 먼저 끝나면 띄우지 않은 까닭을 기록한다(§3.4).
   마감까지 포트가 열리지 않은 Firefox 는 멈춘다(아래 2 의 끝).
   같은 프로필로 이미 떠 있는 Firefox(플래그 없이 운영자가 띄운 것)가 있으면 Firefox 는 그 프로필을 두 번 열지 않는다.
   2026-10-09 Firefox 157.0.1 을 임시 프로필로 재 보니(headless), 두 번째 Firefox 는 약 5초 뒤 **종료 코드 0** 으로 끝났고
   포트는 열리지 않았다. stderr 에는 시스템 언어로 된 "이미 실행 중" 안내만 나왔다.
   출력 글자로는 가르지 않는다. "포트가 열리기 전에 Firefox 가 끝났다"를 하나의 까닭으로 기록하고,
   종료 코드가 0 일 때만 문장이 그 프로필을 다른 Firefox 가 열고 있을 수 있다고 말한다.
   처음 프로세스가 끝나도 그 process group 에 남은 프로세스가 있으면 마감 시간까지 계속 기다린다.
   받아 둔 업데이트를 적용하는 Firefox 는 updater 를 띄우고, updater 가 Firefox 를 다시 띄운다.
   둘 다 따로 group 을 떠나지 않으면 처음 group 에 남는다고 보았다(재지는 않았다).
   포트에 연결이 거절되면 "듣는 것 없음"이다. 그 밖의 오류로 알 수 없으면 Firefox 도 host 도 띄우지 않고 그 까닭을 남긴다.
   기다리는 동안 확인이 계속 그렇게 끝나면, 마감 때 마지막 확인의 까닭을 남긴다.
   이미 듣는 것이 이 프로필의 Firefox 인지는 host 가 세션을 받은 뒤에 확인한다(4).
2. 0 에서 띄우기로 했으면 `<base>/.masc/browser-lane/host/launch --bidi-url ws://127.0.0.1:<port>/session` 을 떨어진 프로세스로 띄운다.
   launcher 상태는 0 에서 본 그대로다(연결 목록이 `bidiHost.attach.launcher_state` 로 말하는 상태).
   그 사이 다른 host 가 잠금을 잡았으면 여기서 띄운 host 는 잠금에서 거절되고, 자기 로그에 그렇게 남긴다.
   host 를 띄우지 못하면(로그를 열 수 없음, launcher 를 실행할 수 없음), 여기서 띄운 Firefox 는 짝 없이 남는다.
   - 여기서 띄운 Firefox 가 짝 없이 남으면 그 process group 을 멈춘다. 1 의 마감에 포트가 열리지 않은 경우도 같다.
     SIGTERM 을 보내고, 5초가 지나도 남아 있으면 SIGKILL 을 보낸다. group 이 비면 신호를 보내지 않는다.
   - 포트가 처음부터 답한 Firefox 는 서버가 띄운 것이 아니라 건드리지 않는다.
     지난 host 가 그 Firefox 에 세션을 남긴 경우만 다르다. MASC 가 띄운 것이 확인되면 다시 띄운다(§3.5 의 4).
   host 에는 서버의 `MASC_HTTP_BASE_URL`·`MASC_HTTP_PORT` 를 넘기지 않는다.
   host 는 이 둘을 `connection.toml` 보다 먼저 고정 주소로 쓰기 때문이다(`connectors/browser/host/README.md`).
   새 host 는 지난 host 기록의 확인 못 한 결과를 archive 에 옮긴 뒤에 기록을 바꾼다(#42150).
3. 이 일은 서버 시작을 막지 않는다. geckodriver 처럼 별도 fiber 에서 한다.
4. 서버가 띄우는 host 는 `--firefox-profile <profile>` 도 받는다. 세션을 받은 뒤 `moz:profile` 이 그 프로필이 아니면
   세션을 끝내고, 그 까닭을 기록에 남기고 끝난다. 두 경로는 링크를 풀어 비교한다.
   2026-10-09 Firefox 157.0.1 을 임시 프로필로 재 보니, `session.new` 의 capabilities 에 `moz:profile`(받은 경로 그대로,
   링크를 풀지 않음)과 `moz:processID` 가 있었다.
   그래서 그 포트에 평소 쓰는 Firefox 의 Remote Agent 가 떠 있어도 Keeper 가 그 프로필로 일하지 않는다.
   그 Firefox 에 세션이 잠깐 열렸다가 바로 끝난다.

### 3.3 서버가 멈출 때와 다시 뜰 때

- 서버가 멈춰도 Firefox 와 host 는 멈추지 않는다(§2.2 의 떨어진 프로세스).
  배포할 때마다 서버가 다시 뜨는데, 그때마다 Keeper 창이 닫혔다 열리지 않게 하려는 것이다.
- 다시 뜬 서버는 §3.2 를 다시 한다. 둘 다 떠 있으면 아무것도 하지 않는다.
  host 는 #41898 대로 새 서버에 다시 등록한다.
- 표를 지우거나 `[browser.live] enabled = false` 로 바꾼 서버는, 뜰 때 `keeper-firefox.json`(§3.4)을 읽어
  MASC 가 띄운 Firefox 만 멈춘다. 운영자가 띄운 것은 그대로 둔다. host 는 자기 Firefox 가 끝나면 같이 끝난다(§2.4).
  - MASC 가 띄웠는지는 §3.5 의 4 와 같이 확인하고, 확인되지 않으면 멈추지 않는다. 서버 로그에 까닭과 "그 Firefox 를 닫으라"를 남긴다.
  - 기록을 읽을 수 없으면 아무것도 멈추지 않고, 기록도 그대로 둔다.
  - `runtime.toml` 을 읽지 못한 서버(설정이 로드되지 않음)는 운영자가 무엇을 원하는지 모르므로 아무것도 멈추지 않는다.
  - 멈춘 뒤 group 이 비었거나, 기록의 process group 에 남은 프로세스가 없으면 기록을 지운다.
  - 신호를 보낼 때마다(SIGTERM, 5초 뒤 SIGKILL) 그 번호가 아직 그 group 인지 다시 본다. 그 사이 group 이 비고 번호를
    다른 group 이 받았으면 신호를 보내지 않는다.
  - 이 계정이 신호를 보낼 수 없는 group(kill 이 EPERM)은 비었다고 보지 않는다. Darwin 은 프로세스가 모두 끝나는 중이거나
    zombie 인 group 에도 EPERM 을 주므로, 커널의 member 목록으로 가른다. 목록이 없는 플랫폼에서는 있는 것으로 본다.
- 이 점이 geckodriver 와 다르다. geckodriver 는 세션을 서버만 닫을 수 있어서 서버와 같이 멈춘다.
  BiDi host 는 스스로 `session.end` 를 보내고, 다음 host 를 위한 기록을 남긴다.

### 3.4 서버가 남기는 것

- `<base>/.masc/browser-lane/keeper-firefox.json`: 서버가 띄운 Firefox 의 process group(띄운 프로세스의 pid 와 같은 번호),
  그 프로세스를 알아볼 표지, 프로필, 포트, 띄운 시각. host 기록과 같은 방식으로 통째로 다시 쓴다.
  - 기록은 Firefox 를 띄운 바로 뒤, 포트를 기다리기 전에 쓴다. 기다리는 30초 사이에 서버가 끝나도 그 Firefox 는 기록에 남는다.
  - 표지는 띄운 프로세스의 시작 표지이고, 읽지 못했으면 "시작을 읽지 못함"이다.
    처음 프로세스가 끝나고 group 의 다른 프로세스가 포트를 연 경우(업데이트를 적용하며 다시 뜬 경우), 기록의 표지는 끝난 프로세스의 것이 된다.
    이 경우와 "시작을 읽지 못함"은 나중의 다른 group 과 가를 수 없으므로 MASC 가 멈추지 않는다.
  - 시작 표지는 커널의 프로세스 표에서 읽는다(`Posix_spawn_detached.process_start`). macOS 는 `sysctl` 의 `p_starttime`(마이크로초),
    Linux 는 boot id 와 `/proc/<pid>/stat` 의 starttime 이다. pid 가 다른 프로세스에게 다시 주어져도 이 표지는 같지 않다.
  - 띄운 직후, 서버가 그 자식을 거둘 수 있기 전에 읽는다. 거두기 전에는 끝난 자식도 그 번호를 쥐고 있어서, 읽은 표지는
    반드시 그 자식의 것이다. 다른 프로세스(`ps`)를 띄워 읽으면 그 사이 자식이 거둬지고 번호가 다른 프로세스에 갈 수 있어,
    서버 시작 잠금의 `ps -o lstart=` 방식을 쓰지 않는다.
  - 띄우지 못한 까닭은 이 기록에 넣지 않는다. 켜기마다 결과를 따로 남긴다(§3.7).
- Firefox 띄우기는 이 기록을 디스크에 쓰기까지 해야 성공이다. 쓰지 못하면(디스크가 가득 참, 쓸 수 없는 디렉터리)
  포트를 기다리지 않고 방금 띄운 process group 을 멈추고, host 도 띄우지 않고, 그 까닭을 로그에 남긴다.
  주인을 알 수 없는 Firefox 와 열린 포트가 서버보다 오래 남지 않게 하려는 것이다.
  기록은 썼는데 디렉터리 항목을 디스크에 내리지 못했으면, 기록이 있는 것으로 보고 경고만 남긴다.
- 그 Firefox 가 포트를 열기 전에 끝나거나 다른 프로세스가 포트를 열었으면 기록을 지운다.
  30초 안에 포트를 열지 않았거나 host 를 띄우지 못해 서버가 그 Firefox 를 멈췄으면, group 이 빈 것을 본 뒤에 지운다.
- 서버는 Firefox 를 띄우기 전에 이 기록을 읽는다. 기록의 group 이 아직 돌 수 있으면(MASC 가 띄운 것으로 확인되거나, 끝났다고 확인되지 않으면)
  또 띄우지 않고 까닭을 로그에 남긴다. 기록을 읽을 수 없어도 띄우지 않는다.
  포트가 열리기 전에 서버가 끝난 경우, 다음 서버가 기록을 덮어쓰고 두 번째 Firefox 가 프로필 잠금으로 끝나며 기록을 지우면
  첫 Firefox 가 이름 없이 남기 때문이다.
- 기록의 pid 로 다른 시작 표지의 프로세스가 돌면, 기록의 group 은 끝난 것으로 본다.
  POSIX fork(2) 는 새 프로세스에 아직 있는 process group 의 번호를 주지 않는다.
- host 의 출력은 `<base>/.masc/browser-lane/bidi-host.log`, Firefox 의 출력은 `keeper-firefox.log` 에 쓴다.
  떨어진 프로세스는 처음부터 그 파일을 stdout·stderr 로 받는다.
  띄울 때마다 지난 실행의 로그를 `<이름>.1` 로 옮긴다(그 전 것은 덮인다). 그래서 파일은 두 번의 실행만 담는다.
  한 번 실행하는 동안은 계속 커진다. 서버가 꺼져 있으면 host 는 5초마다(`reconnect_delay_sec`) 실패 한 줄을 남겨,
  하루에 약 17,000줄이 된다.
- 연결 목록·doctor·Keeper 답의 문장은 이 상태와 마지막 켜기의 결과를 말한다(§3.7).

### 3.5 Firefox 나 host 가 꺼졌을 때: Keeper 가 필요할 때 다시 켠다

운영자가 Keeper 창을 닫거나 Firefox 가 죽으면 host 도 끝난다(§2.4). host 만 죽을 수도 있다.
서버는 Keeper 가 BiDi 만 하는 일(지금은 hover·drag, `Trusted_hover`·`Trusted_drag`)을 부탁했는데
그 일을 할 BiDi 연결이 목록에 없을 때 다시 켠다(운영자 결정, §8 의 2).

- 켜기를 부탁하는 거절은 넷이다: 연결이 하나도 없음(`no_live_client`), 고른 연결이 끊김(`selected_client_disconnected`),
  고른 연결이 그 일을 못 함(`live_transport_unsupported`), 연결이 여럿이라 골라야 함(`ambiguous_browser_clients`).
  어느 경우든 목록의 어떤 연결도 그 일을 못 할 때만이다. 그 일을 하는 연결이 있으면 그 연결을 고르는 것이 할 일이다.
- 요청 때마다 그때의 `runtime.toml` 을 읽는다. 표가 없거나 lane 이 꺼져 있으면 켜지도 멈추지도 않고, 답은 지금과 같다.
- 답의 거절 이름은 그대로 둔다.
  - 연결이 보이면 `bidiConnection` 에 그 연결과 무엇을 켰는지(`started`: Firefox 와 host / host 만 / 없음)를 싣는다.
    `retry` 는 "무엇을 켰다. 그 연결의 탭을 다시 보고 화면을 다시 관찰한 뒤 다시 요청하라"가 된다.
  - 안 보이면 `bidiStartFailed` 에 까닭과 갈래(`kind`)를 싣는다. 갈래는 다시 요청했을 때 일어나는 일로 나눈다.
    - `operator_needed`: lane 이 설치되지 않음, 다른 host·지난 Keeper Firefox 가 워크스페이스를 쥠. 운영자가 고치기 전엔 같은 답이다.
      `retry` 는 지금처럼 운영자의 할 일을 말한다.
    - `start_failed`: 켜기를 해 봤고 host 가 뜨지 않았다. 다시 요청하면 다시 켠다.
    - `not_listed_in_time`: host 를 켰거나 이미 돌았는데 정한 시간 안에 연결이 목록에 안 보였다. 조금 뒤 다시 요청하면 보일 수 있다.
- 요청 하나가 기다리는 시간은 길어야 약 50초다: 끝나는 host 의 잠금 5초, Firefox 의 포트 30초, 연결 15초.
  Firefox 를 다시 띄울 때(4)는 약 11초가 더해진다: 멈추기의 SIGTERM 뒤 5초와 SIGKILL 뒤 1초, 포트가 닫히기를 기다리는 5초.

1. §3.2 의 순서로 빠진 것만 켠다.
2. 그 BiDi 연결이 목록에 올라올 때까지 기다린다. 처음 요청을 새 연결로 그대로 보내지는 않는다.
   그 요청의 `clientId`·`tabId`·좌표는 그 전 연결에서 본 것이고, 새 host 는 탭 번호를 새로 매긴다(`browser_bidi_peer.ml`).
   다른 연결로 옮길 때 탭을 다시 보라는 규칙(`tool_misc_browser_lane.ml`)과 같다.
   그래서 Keeper 에게 "BiDi 연결을 새로 붙였으니 탭과 화면을 다시 보고 다시 요청하라"고 답한다.
   정한 시간 안에 올라오지 않으면 거절하고, 왜 못 켰는지를 `bidiHost` 문장으로 말한다.
   시간은 15초다. Firefox 시작부터 host 의 첫 poll 까지 1.75~5.68초 걸렸다
   (2026-10-10, 14회, Firefox 157.0.1 headless, M3 Max, 부하 110~150). 가장 느린 값의 약 2.6배로, 창이 있는 Firefox 의 여유를 둔다.
   이 시간은 Firefox 가 포트를 여는 30초(§3.2)와 끝나는 host 를 기다리는 5초 다음에 센다.
3. 켜기는 워크스페이스마다 한 번에 하나다. 서버 시작 때의 켜기(§3.2)와 Keeper 요청 때의 켜기가 같은 하나를 쓴다.
   - 서버 시작 fiber 가 포트 확인과 Firefox 띄우기 사이에 있을 때 hover 가 오면, 그 요청은 새로 켜지 않고 그 켜기를 기다린다.
     동시에 온 요청끼리도 같다.
   - 겹치게 두면 둘 다 빈 포트를 보고 같은 프로필로 Firefox 를 띄운다. 두 번째는 약 5초 뒤 끝나지만(§3.2 의 1),
     그 결과가 첫 Firefox 의 기록이나 까닭을 덮을 수 있다.
   - 켜기는 서버 switch 위의 fiber 하나가 차례로 한다. 요청은 다른 domain 에서 올 수 있어서 그 switch 에 직접 프로세스를 띄우지 않고,
     그 fiber 에 부탁만 한다. 한 켜기가 도는 동안 온 요청들은 그 켜기의 결과로 답을 받는다.
   - 켜기가 띄운 host 가 연결이 보이기 전에 끝나면(Firefox 가 세션을 거절함, 다른 프로필 등), 그 host 를 위해 띄운 Firefox 를 멈추고
     기록을 지운 뒤 `start_failed` 로 답한다. host 를 띄운 것만으로 성공으로 치면 그 Firefox 가 포트를 연 채 주인 없이 남는다.
   - 한 켜기는 연결이 목록에 보이거나, 띄운 host 가 끝나거나, 기다림이 끝날 때까지다. 막 띄운 host 는 잠금도 기록도 아직 없어서, 그 사이에 켜기를 또 하면
     host 를 하나 더 띄우기 때문이다.
   - 서버 시작 때의 켜기는 예전처럼 따로 돌고(서버가 멈출 때 끝나기를 기다린다), 요청을 받는 fiber 가 그 결과를 받아 연결을 기다린 뒤
     그동안 온 요청에 답한다.
   - 서버가 멈추면 기다리던 요청은 바로 "서버가 멈추는 중" 으로 답을 받는다.
4. 지난 host 가 Firefox 에 세션을 남겨(`left`, `refused`) 새 host 가 붙을 수 없으면:
   - 지난 host 의 기록이 이 포트에서 `left` 나 `refused` 로 끝났고, 포트가 답할 때다.
     host 가 죽었거나 세션을 끝내기 전에 연결을 잃었으면(`unknown`) 세지 않는다. 세션이 남았는지 모르고,
     다음 host 가 붙어 보면 안다. 거절되면 그 host 가 `refused` 로 끝났다고 남기고, 다음 켜기가 그것을 본다.
   - MASC 가 띄운 것이 확인되면 그 process group 을 멈추고 거둔 뒤 다시 띄운다.
     확인은 둘 다 맞을 때다: 기록의 pid 로 도는 프로세스의 시작 표지가 기록과 같고(§3.4), 그 process group 이 기록과 같다.
     그리고 그 Firefox 가 지난 host 가 끝나기 전에 떴어야 한다(`keeper-firefox.json` 의 `started_at` 이 host 기록의 끝난 시각보다 늦지 않음).
     그 뒤에 뜬 Firefox 에는 그 host 의 세션이 없다.
     프로필에 로그인이 남아 있어서 다시 로그인하지 않아도 된다.
   - 멈춘 뒤 group 에 프로세스가 남으면 기록을 그대로 두고 아무것도 띄우지 않는다. 답은 `start_failed` 다.
   - group 이 비면 기록을 지우고, 그 포트가 닫힐 때까지 5초까지 기다린 뒤 새 Firefox 를 띄운다.
     Darwin 에서는 끝나는 중인 프로세스도 group 에서 빠진 것으로 세는데, 그 프로세스가 포트와 프로필 잠금을 아직 놓지 않았을 수 있다.
     5초가 지나도 포트가 답하면 아무것도 띄우지 않는다. 답은 `start_failed` 다.
   - 하나라도 맞지 않거나 읽을 수 없으면 멈추지 않는다. pid 가 다른 프로세스에게 다시 주어졌을 수 있어서다.
     서버 로그에 까닭과 "그 Firefox 를 닫으라"를 남기고, host 는 그대로 띄운다. 기록이 그 Firefox 보다 오래됐을 수 있고,
     거절되면 그 host 가 그렇게 남기며, 연결 목록·Keeper 답의 `bidiHost` 문장이 운영자 Firefox 와 같이 그 Firefox 를 다시 띄우라고 말한다.
   - 실행 파일이나 `--profile` 은 맞춰 보지 않는다. `ps` 는 인자를 공백으로 이어 붙여 보여 주므로 경로의 공백과 인자를 가를 수 없다.
   - 서버 시작 때의 켜기도 같다. 둘은 같은 켜기다(3).
   - `refused` 는 다른 워크스페이스의 host 가 그 Firefox 에 붙어 있을 때도 나온다(`Browser_bidi_host_record.Session_refused`).
     MASC 가 띄운 Firefox 에 그런 host 가 붙어 있었다면, 다시 띄울 때 그 연결도 끊긴다.

시간을 정해 두고 계속 다시 켜는 고리는 두지 않는다. 다시 켜는 것은 언제나 Keeper 의 요청 하나나 서버 시작이 시작한다.
운영자가 일부러 창을 닫았어도, 다음 hover·drag 요청이 오면 창이 다시 열린다.
BiDi 가 아니어도 되는 요청(읽기, 클릭, 스크롤)은 BiDi 연결이 없다는 이유로 창을 다시 열지 않는다.

### 3.6 바뀌는 문서

- `docs/design/browser-bidi-live-host.md` §Attaching a connection: "Nothing in MASC starts this Firefox or this host"
  를 지우고, 설정 한 덩어리로 켜는 절차를 첫 길로 적는다. 손으로 띄우는 절차는 설정이 없을 때의 길로 남긴다.
- RFC-browser-live-one-connection §2.4 의 host 항목을 지금 사실로 고친다.
  표를 적은 워크스페이스는 서버가 띄우고, 표가 없으면 운영자가 손으로 붙인다. 그 RFC 에 이 RFC 를 `related` 로 건다.

### 3.7 마지막 켜기와 상태 문장 (4단계)

- `<base>/.masc/browser-lane/keeper-firefox-start.json`: 서버가 켜기(서버 시작, Keeper 요청)를 마칠 때마다 통째로 다시 쓴다.
  - 필드는 `schema`, `at`(마친 시각), `port`·`profile`(그 켜기가 쓴 설정), `outcome` 이다. `outcome` 은 `attached`(+ `started`: `firefox_and_host` / `host_only` / `nothing`)이거나
    `operator_needed`·`start_failed`·`not_listed_in_time`(+ `message`)이다. 갈래는 Keeper 답의 `bidiConnection`·`bidiStartFailed` 와 같다.
  - `message` 는 host 기록의 `reason` 과 같은 규칙으로 쓴다. 출력 가능한 ASCII 로, 다른 바이트는 `\xNN` 으로 쓰고, 상한을 넘으면 자르고 표시한다.
    상한은 1024바이트다. 서버 문장에는 경로가 둘 이상 들어가기도 해서, 512바이트인 `reason` 보다 길게 둔다.
  - 이 기록은 켜기를 막지 않는다. 읽는 곳은 문장뿐이다. 읽을 수 없으면 문장이 그렇게 말한다.
  - 쓰지 못하면 서버 로그에 경고를 남기고 켜기의 답은 그대로 준다.
- 상태 문장은 그 워크스페이스의 설정을 함께 받는다.
  - 서버(연결 목록, Keeper 답, setup 상태)는 불러 둔 설정을 쓴다.
  - `masc doctor` 는 그 워크스페이스의 `runtime.toml` 을 읽고, 파일 전체가 불러질 때만 쓴다. 서버도 불러지지 않는 파일에서는 browser 설정이 없기 때문이다.
- `[browser.live] enabled = false` 이면, 표가 있든 없든 문장 맨 앞에 "lane 이 꺼져 있어 MASC 는 아무것도 켜지 않는다"를 둔다.
- 표가 있고 lane 이 켜져 있으면, 운영자가 Firefox 를 띄우고 host 를 실행하라는 문장 대신
  "다음 서버 시작이나 Keeper 의 다음 hover·drag 때 MASC 가 port N, 프로필 P 의 Keeper Firefox 와 host 중 돌지 않는 것을 켠다"고 말한다.
  lane 이 설치되지 않았으면 "lane 을 설치하면" 을 붙인다.
  - 지난 host 가 이 포트에서 세션을 남겼거나(`left`) 거절당했으면(`refused`), MASC 가 띄운 것으로 확인된 Firefox 는 그 켜기가 다시 띄우고(§3.5 의 4),
    확인되지 않은 Firefox 는 운영자가 먼저 닫는다고 말한다. 지난 host 가 다른 포트였으면 다시 띄우지 않으므로 그냥 켠다고 말한다.
  - 마지막 켜기가 연결을 보이지 못했으면 그 시각과 까닭을 말한다. 다만 같은 설정(port, 프로필)의 켜기여야 하고,
    host 기록이 그 뒤로 말하는 것보다 나중이어야 한다: 끝난 host 는 끝난 시각, 죽은 host 와 도는 host 는 붙은 시각
    (없으면 시작 시각) 뒤의 켜기만 말한다. 늦게 붙은 host 옆에 "제때 연결이 없었다" 를 말하지 않기 위해서다.
  - 기록은 프로필을 한 줄의 출력 가능한 ASCII 로 쓰므로, 설정의 프로필도 그 형태로 바꿔 견준다.
  - Keeper 거절 답은 그 요청의 켜기 결과를 `bidiStartFailed`·`bidiConnection` 에 싣으므로, `bidiHost` 문장에는 마지막 켜기를 다시 쓰지 않는다.
- 표가 없으면 지금 문장에 "`[browser.live.bidi]` 를 적으면 MASC 가 켠다"를 더한다.
- 설정을 받지 못하면 지금 문장 그대로다.
- TUI 의 host 줄은 같은 것을 짧게 말한다(4단계의 셋째 PR).
  - 서버가 연결 목록의 `bidiHost` 에 `keeper` 를 함께 싣는다. 누가 켜는지(`masc_starts`·`lane_off`·`not_configured`·`not_known`)와,
    MASC 가 켜면 port·프로필·마지막 켜기 기록이다. 문장과 TUI 는 같은 함수로 마지막 켜기를 말할지 정한다.
  - MASC 가 켜면 `Attach:` 명령 자리에 MASC 가 켠다는 줄과 port·프로필을 둔다.
    남은 세션 줄은 운영자에게 재시작하라고 하지 않는다. 이 포트면 MASC 의 기록이 MASC 가 띄웠다고 보이는 Firefox 만 다음 켜기가 다시 띄우고
    아닌 것은 운영자가 먼저 닫는다고, 다른 포트면 MASC 의 켜기를 막지 않는다고 말한다. 포트가 같은지는 문장과 같은 함수로 본다.
  - 표가 없으면 명령 뒤에 그 한 줄을 더한다. lane 이 꺼져 있으면 host 상태와 상관없이 맨 끝에 그 한 줄을 더한다.
  - report 의 필드가 늘어서, 서버와 다른 빌드의 TUI 는 "이 TUI 는 서버의 report 를 읽지 못한다"고 말한다.

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
- host 를 붙일 수 없을 때는 Firefox 를 띄우지 않는다(§3.2 의 0). 쓸 데 없이 열린 포트를 두지 않는다.
- 그 포트에 다른 프로필의 Firefox 가 떠 있으면, host 는 세션을 받은 뒤 `moz:profile` 로 알아보고 끝난다(§3.2 의 4).
  그 사이 그 Firefox 에는 세션이 하나 잠깐 열린다.

## 6. 단계

1. 이 RFC (문서만).
2. 설정과 서버 시작: `Browser_configuration` 이 `[browser.live.bidi]` 를 읽고, 서버가 뜰 때 Firefox 와 host 를 켠다
   (§3.1~§3.3). 출력은 `keeper-firefox.log`, `bidi-host.log` 로 간다. 설계 문서의 붙이는 절차도 이 단계에서 고친다(§3.6).
   `keeper-firefox.json` 은 그것을 읽는 3단계에서 더한다.
   읽기만 하는 PR 을 따로 두지 않는다. 읽는 곳이 없는 설정 필드가 main 에 남기 때문이다.
   이 PR 이 배포된 뒤에 운영자가 `runtime.toml` 에 표를 적는다(§2.3).
3. 세 PR 로 나눈다.
   1. `keeper-firefox.json` 을 쓰고(§3.4), 표가 없거나 lane 이 꺼진 서버가 그것으로 MASC 가 띄운 Firefox 만 멈춘다(§3.3).
   2. Keeper 의 hover·drag 요청이 빠진 것을 다시 켜고 기다린다(§3.5 의 1~3).
   3. 남은 세션 때문에 MASC 가 띄운 Firefox 를 다시 띄운다(§3.5 의 4).
4. 연결 목록·doctor·Keeper 답의 문장과 TUI 의 host 줄이 "MASC 가 켠다"를 말한다(§3.7). 세 PR 로 나눈다.
   1. host 기록이 다른 프로필로 끝난 까닭을 남기고, 문장과 Keeper 답이 그것을 말한다(#42164).
   2. 마지막 켜기의 기록과, 설정을 받는 상태 문장.
   3. TUI 의 host 줄(§3.7 끝).

## 7. 확인 방법

- 설정 파서: 빠진 키, 상대 경로, 모르는 키, `enabled = false` 와 함께 있을 때.
- 켜는 순서: 포트가 이미 열림 / 비어 있음 / 다른 프로세스가 씀, host 잠금이 잡힘 / 안 잡힘 / 다른 포트의 host,
  launcher 없음(Firefox 도 안 띄움), 같은 프로필을 플래그 없이 연 Firefox 가 이미 있음.
  host 에 서버의 주소 변수가 가지 않음, 띄울 때 지난 로그를 옮김.
- 프로필 확인: `moz:profile` 이 다른 Firefox 에서 host 가 세션을 끝내고 끝남, 링크로 적은 같은 프로필은 받아들임.
  실제 Firefox 대신 포트만 여는 가짜 실행 파일로 OCaml 테스트를 쓴다.
- 서버 재시작: 떠 있는 Firefox 와 host 를 다시 띄우지 않는다. host 가 새 서버에 다시 등록한다.
- 필요할 때 다시 켜기: BiDi 연결이 없을 때 hover 요청 하나가 켜고 기다린 뒤 다시 보라고 답한다. 동시에 온 요청 둘이 한 번만 켠다.
  서버 시작의 켜기가 도는 중에 온 요청도 새로 켜지 않는다.
- 기록: `keeper-firefox.json` 을 쓰지 못하면 방금 띄운 Firefox 가 남지 않는다.
  기록의 pid 를 시작 표지가 다른 프로세스가 가졌으면 그 프로세스를 멈추지 않는다.
  정한 시간 안에 안 붙으면 까닭과 함께 거절한다. 읽기 요청은 창을 열지 않는다.
  남은 세션: MASC 가 띄운 Firefox 는 다시 띄우고, 운영자가 띄운 Firefox 는 멈추지 않는다.
- 실제 Firefox 157 을 임시 프로필로 띄워 한 번 끝까지 확인한다(headless 가 아닌 창은 로컬에서만).
- 이 장비에서 운영자 프로필로 서버를 다시 띄워, 손대지 않고 연결 목록에 `webdriver_bidi` 가 생기는지 본다.

## 8. 운영자 결정

2026-10-09 운영자가 셋을 정했다.

1. **켜는 때: 서버와 같이 자동으로.** 버튼이나 별도 명령으로 켜지 않는다(§3.2).
2. **꺼진 Firefox·host 를 다시 켜는 때: Keeper 가 필요할 때 바로.** 다음 서버 시작을 기다리지 않는다(§3.5).
   운영자가 일부러 닫은 창도 다음 hover·drag 요청에 다시 열린다는 것을 알고 정했다.
3. **켜는 조건: `runtime.toml` 에 `[browser.live.bidi]` 가 있을 때만.**
   `~/masc-keeper-firefox-profile` 디렉터리가 있다는 것만으로는 켜지 않는다(§3.1).
