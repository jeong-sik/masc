---
rfc: "browser-backends-end-alone"
title: "browser 연결 출처마다 worker 하나: 장애는 프로세스에 갇히고, 고르는 일은 host 가 한다"
status: Draft
created: 2026-10-23
updated: 2026-10-23
author: claude
supersedes: []
superseded_by: null
related: ["browser-keeper-firefox", "browser-live-one-connection", "browser-lane-stagehand", "browser-live-ego"]
---

# RFC: browser 연결 출처마다 worker 하나 (browser-backends-end-alone)

## 0. 요약

browser Add-on worker 하나가 브라우저 연결 출처 다섯을 한 프로세스에서 돌려요.
- Gecko automation
- Chrome(Stagehand)
- masc 가 띄우는 live Firefox
- ego lite 작업 공간
- 바깥 확장 프로그램 client 대기열

2026-10-22~23 에 이 구조 때문에 브라우저 도구가 두 번 오래 멈췄어요(1절).
1. Gecko 브라우저가 worker 밖으로 빠져나갔어요. 정리를 영영 확인할 수 없어서 모든 출처가 3시간 막혔어요.
2. live Firefox 연결 하나가 끊기자 worker 전체가 죽었어요. Chrome·Gecko 도 같이 꺼졌어요.

같은 묶임이 ego 에도 있어요. ego 연결이 끝나거나 시작하지 못하면 worker 전체가 끝나요(2.1).

이 RFC 는 정석을 따라요. **장애의 경계는 프로세스이고, 프로세스를 띄우고 다시 띄우는 일은 supervisor 가 하고, 고르는 일은 그 위의 host 가 한다.**

- **S. 연결 출처마다 Lane Add-on worker 하나.**
  - 출처는 닫힌 합타입 `Automation | Stagehand | Live of live_transport` 예요. `live_transport` 는 이미 있는 `Webdriver_bidi | Ego_task_space | Web_extension` 이에요.
  - 패키지·선언·프로세스가 출처마다 하나씩이에요.
  - 격리·정리 확인·교체는 masc 에 이미 있는 설치 단위 장치(admission·claim·settlement, #45290 의 교체)를 그대로 써요.
- **H. 고르는 일은 host 가 해요.** Automatic 선택은 요청할 때 각 worker 에서 받은 snapshot 으로 host 가 계산해요. worker 는 자기에게 정해진 요청만 실행해요.
- **G. Gecko worker 는 자기가 띄운 브라우저를 끝까지 가져요.**
  - Gecko 프로필은 masc 가 만들어요.
  - 정리는 두 사실로 확인해요. worker 의 프로세스 그룹이 비었는지, 그리고 프로필의 `.parentlock` 을 쥔 프로세스가 없는지예요.
  - 잠금 주인이 있으면 신원에 묶어 TERM 을 보내고, 다음 정리에도 남아 있으면 KILL 을 보내요.
  - 지우는 동안에는 masc 가 그 잠금을 쥐어요.
  - 확인할 수 없는 영수증 `automation-closed.json` 은 지워요.
- **D. 켜고 끄는 스위치는 선언의 `enabled` 하나예요.** runtime.toml 의 `[browser.*] enabled` 는 지워요. runtime.toml 에는 어떻게 띄울지만 남아요.

1번 장애는 G 가, 2번 장애와 ego 의 묶임은 S 가 막아요. 죽은 worker 를 다시 띄우는 일은 #45290 이 맡아요.

## 1. 실측

### 1.1 Gecko 브라우저가 worker 밖으로 빠져나감 (#45187)

| 시각 (KST) | 일 | 근거 |
|---|---|---|
| 10-22 16:12 | 운영자의 Zen 이 1.23.4b 업데이트(163MB)를 받아 두었어요. 상태는 `Install Pending` 이에요. | `~/Library/Caches/Mozilla/updates/Users/dancer/Applications/Zen/active-update.xml`, `updates/0/update.mar` |
| 20:56:57 | Keeper 가 `lane=automation` 을 열었어요. geckodriver 가 운영자의 Zen 을 이 인스턴스 전용 프로필로 띄웠어요. | `webdriver.log` 의 `Running command` |
| 20:57:03 | geckodriver 가 `Process (pid=60783) unexpectedly closed with status 1` 로 답했어요. 같은 초에 `update.status` 가 `failed: 9` 로 쓰였어요. 같은 프로필의 Zen(61713)이 launchd 아래에서 다시 떴어요. | `updates/0/update.status` 수정 시각, #45187 댓글 |
| 20:57 이후 | 세션 생성이 sessionId 없이 끝나서 `uncertain` 이 켜졌어요. automation 명령이 모두 `owned browser session authority is unknown` 으로 거절됐어요. | `lib/browser_addon_automation.ml:92`, `115` |
| 21:48 | 배포로 서버가 다시 떴어요. Gecko 쪽은 `automation-closed.json` 을 쓰지 않았어요. | 인스턴스 할당 폴더 |
| 21:49~00:42 | 새 서버가 1분마다 `cleanup incomplete: missing automation-closed.json` 만 남겼어요. 같은 선언은 새 인스턴스를 띄우지 못했고, Chrome·live 도 같이 멈췄어요. 운영자 retain(#45216)으로 풀었어요. | `masc-start-1022-2149.log` 등 |

Firefox 계열은 받아 둔 업데이트가 있으면 시작하자마자 종료하고 updater 를 돌린 뒤 자신을 다시 띄워요. Mozilla 는 이 동작을 고치지 않기로 했어요. updater 가 Firefox 프로세스를 바꿔치기하기 때문이에요([bug 1450268](https://bugzilla.mozilla.org/show_bug.cgi?id=1450268), WONTFIX).
업데이트를 끄는 공식 방법은 enterprise policy(`DisableAppUpdate` 등)뿐이고, 설치본 전체에 걸려요([Disabling Automatic Update](https://firefox-source-docs.mozilla.org/toolkit/mozapps/update/docs/HowToDisable.html)).

### 1.2 live 연결 하나가 worker 전체를 끝냄 (#45288)

| 시각 (KST) | 일 | 근거 |
|---|---|---|
| 10-23 01:13 | live Firefox 로그의 마지막 줄은 `Killing GPU process due to IPC reply timeout` 이에요. 서버도 01:02~01:17 에 15분 동안 멈춰 있었어요. | `live-firefox.log`, `masc-start-1023-0032.log` |
| 01:17 | worker 가 `Fatal error: exception Sys_error("owned Firefox backend ended: client_disconnected")` 로 죽었어요. Gecko 정리는 확인됐어요. | `masc-start-1023-0032.log` 4492-4521행 |
| 01:17~10:13 | 인스턴스가 메모리에 `running + failed` 로 남았고, 아무도 다시 띄우지 않았어요. | #45288. #45290 에서 고쳤어요 |

Chrome 과 Gecko 에는 문제가 없었어요. 잡히지 않은 예외 하나가 모두를 끝냈어요.

### 1.3 이 RFC 의 가정을 직접 확인한 것 (2026-10-23, Zen 1.22.1b, geckodriver 0.37.1)

| 확인한 것 | 결과 |
|---|---|
| masc 와 같은 인자(`--websocket-port 0`, `--profile-root`)로 띄움 | Zen 이 geckodriver 의 자식으로, 같은 프로세스 그룹에 떴어요 |
| 실행 중인 Zen(pid 30381)의 `.parentlock` 을 읽기 전용으로 열고 `F_GETLK` | `write-locked, holder pid 30381` |
| 미리 만든 프로필을 `-profile` 로 넘기고 `--marionette-port` 를 정함 | 세션이 열렸고 `moz:profile` 이 넘긴 경로였어요. 세션을 닫은 뒤에도 프로필이 그대로 남았어요 |
| 다른 프로세스가 그 프로필의 `.parentlock` 에 쓰기 잠금을 쥔 채로 같은 프로필로 headless Zen 시작 | `A copy of Zen is already open. Only one copy of Zen can be open at a time.` 를 내고 바로 끝났어요. 남은 프로세스는 없었어요 |

geckodriver 문서도 같은 걸 말해요([Profiles](https://firefox-source-docs.mozilla.org/testing/geckodriver/Profiles.html)).
- `-profile` 로 넘긴 프로필은 그 자리에서 써요. 올바르게 동작하는 데 필요한 설정은 geckodriver 가 직접 써 넣어요.
- 지워지는 건 geckodriver 가 만든 임시 프로필뿐이에요.
- 직접 넘긴 프로필에서는 Marionette 포트를 `--marionette-port` 로 넘겨야 해요.

## 2. 지금 구조

인용한 줄은 이 판의 base 인 main(`22f7eaea05a`) 기준이에요.

### 2.1 다섯 출처가 한 프로세스에 있어요

- worker 는 출처를 감싸서 띄워요: `automation (chrome (live_bidi (ego (serve))))` (`bin/masc_browser_addon_worker.ml:77-86`). 바깥 것의 시작이 실패하면 안쪽은 시작조차 하지 않아요.
- owner 의 상태는 하나예요: `type phase = Serving | Retired` (`lib/browser_addon_owner.ml:4`). 프로세스마다 owner 는 하나뿐이에요(`process_claimed`, `owner.ml:21-31`). live 연결은 transport 마다 하나씩 owner 의 목록에 붙어요(`owner.ml:14`).
- 출처마다 자기가 끝날 때 owner 전체를 revoke 해요.

  | 출처 | revoke | 프로세스를 끝내는 예외 |
  |---|---|---|
  | Gecko | `browser_addon_automation.ml:105`, `172` | |
  | Chrome | `browser_addon_stagehand.ml:387` | |
  | live Firefox | `browser_addon_live_bidi.ml:274`, `280`, `286` | 연결이 끊기면 `:290` |
  | ego | `browser_addon_live_ego.ml:157`, `163`, `170` | 시작 실패 `:167`, 연결이 끝나면 `:175` |

- 설계 문서도 그렇게 정해요.
  - "An unexpected connection failure revokes that worker rather than publishing a dead client." (`docs/design/browser-addon-lifecycle.md` 38-39행)
  - "An ego that cannot start, or a task space name the operator holds, fails the worker's start as a configured live Firefox does." (같은 문서 25-27행)

### 2.2 정리 확인은 할당 하나에 하나예요

- `Browser_addon_socket.cleanup` 은 할당 하나(`$TMPDIR/mb-<id>`)를 한 줄로 확인해요. installation admission 이 `Settled` 여야 하고, Chrome·live 자식 slot 을 settle 하고, Gecko 영수증을 읽어요. 하나라도 실패하면 모두 막혀요.
- 같은 선언의 새 인스턴스는 이전 인스턴스가 정리돼야 떠요(`lane_addon_runtime.ml` 의 `native_settled`).
- 빈 폴더 트리만 지워요(`empty_tree`, `browser_addon_socket.ml:143-151`). 파일이 남은 Gecko 프로필은 지울 수 없어요.
- Chrome 비공개 프로필은 자식 claim 을 settle 한 뒤, 이름이 정확한 UUID 인 폴더만 따로 정한 규칙(`remove_profile`)으로 지워요(`browser_addon_stagehand.ml:107-121`).

### 2.3 Gecko 는 브라우저를 직접 갖지 않아요

- geckodriver 는 worker 그룹 안에서 떠요(`browser_addon_automation.ml:82`, 그룹을 만들지 않는 `mgr`). 프로필은 geckodriver 가 `--profile-root` 아래에 만들어요.
- 정리 확인은 worker 가 쓰는 영수증에 맡겨요.
  - 세션 생성이 확실하지 않으면(`uncertain`) 영수증을 쓰지 않아요. `uncertain` 은 한 번 켜지면 꺼지지 않아요(`browser_addon_automation.ml:92-96`).
  - 세션 DELETE 가 실패해도 영수증을 쓰지 않아요(`:106-108`, `:150-153`).
- 브라우저가 그룹 밖으로 빠져나가면 masc 는 그걸 확인할 방법이 없어서 영수증을 영영 쓰지 못해요.

### 2.4 host 와 worker 의 경계

**고르기**
- Automatic 선택(`Browser_selection.resolve`)은 worker 안에서 해요. 입력은 그 프로세스의 전역 `Browser_lane` 상태예요(`browser_addon_tool.ml:113`, `browser_selection.ml:54-63`, `177`).
- worker 는 `browserSelection`(lane, clientId, reason)을 답에 붙이고, host 는 그것을 검사해요(`browser_addon_tool.ml:128-130`, `browser_addon_host.ml:113-119`).
- host 는 이미 worker 에 `Snapshot` 을 물어볼 수 있어요(`browser_addon_host.ml:43-49`, `browser_addon_owner.ml:237-239`). 화면용 `choose` 도 host 에 있어요(`browser_addon_view.ml:89-95`).

**서비스는 하나라고 가정해요**
- `Browser_addon_host.connect` 는 browser 서비스가 정확히 하나여야 해요(`browser_addon_host.ml:17-22`).
- native host 의 처음 poll 도 그래요(`browser_addon_ingress.ml:61-64`). 문서 소스도 같아요(`Several_browser_services`, `lane_addon_runtime.ml:1929-1935`).
- presence 는 export 하나의 관측을 찾고, 둘이면 `Ambiguous_installations` 예요(`lane_addon_runtime.ml:1804-1829`). lane inventory 는 한 worker 의 관측 한 줄로 세 레인 줄을 만들어요(`browser_addon_observation.ml:43-45`, `server_lane_inventory.ml:131-140`).

**export 이름은 설치 전체에서 하나여야 해요**
- `tool_export_reading` 은 보이는 설치 사이에 같은 이름의 export 가 있으면 읽기 전체를 실패로 돌려요(`lane_addon_runtime.ml:1754-1760`, `1779-1782`).
- 이 함수는 browser host 만 쓰지 않아요.
  - 요청마다 Keeper 의 도구 목록을 만드는 곳(`mcp_server_eio_protocol.ml:318-323`). 실패하면 `tools/list` 가 `Invalid_request` 로 통째로 실패해요(`:409-410`).
  - machine host(`machine_addon_host.ml:127`, `143`), Skill 편집기(`server_skill_editor.ml:473`).
- 공개 목록(`isolate`)은 같은 이름을 모두 충돌로 숨겨요(`lane_addon_tool_export.ml:39-50`).
- 그래서 지금 패키지를 그대로 여럿 띄우면 `browser_command` 가 겹쳐서 Keeper 의 `tools/list` 가 실패해요. setup 이 enabled 선언 둘을 거절하는 것도 이 때문이에요. 실패 범위가 너무 넓은 문제는 #45360 에 따로 남겼어요.

**live 연결**
- live 연결의 종류는 이미 닫힌 합타입이에요: `type live_transport = Web_extension | Webdriver_bidi | Ego_task_space` (`browser_lane/browser_lane.ml:481`).
- 바깥 확장 client 는 `/browser-lane/poll` 로 들어와요. 이 경로는 `x-lane: live` 만 받아요(`server_routes_http_routes_browser_lane.ml:64-69`).
  - 처음 poll 때 browser 서비스 하나에 묶이고, 그 사실을 `registrations/<clientId>/owner.json` 에 남겨요(`browser_addon_registration.ml:60-76`).
- worker 가 여는 live Firefox·ego client 는 프로세스 안에서 바로 등록되고, 기록 파일은 남기지 않아요(`browser_addon_live_bidi.ml:231`, `browser_addon_live_ego.ml:106`).

**켜고 끄기**
- host 는 browser 패키지마다 전역 `[browser.*]` 설정을 읽고, 켜진 출처를 모두 그 worker 에 넘겨요(`lane_addon_runtime.ml:1500-1535`). 켜졌는지는 `*_enabled` 로 봐요(`1508`, `1512`, `1520`, `1532`).
- 같은 `*_enabled` 가 server 쪽 activity 도 정해요(`server_browser_configuration.ml:1-16`). activity 가 꺼진 레인은 새 일을 `Lane_off` 로 거절하고, 세션 닫기·상태 확인은 받아요(`browser_lane/browser_lane.ml:452-469`).
- worker 안에서는 activity 가 runtime.toml 이 아니라 "그 backend 가 붙었나"로 정해져요(`browser_addon_owner.ml:33`).
- TUI 의 레인 켜기·끄기는 runtime.toml 의 그 값을 고쳐요(`bin/masc_tui_browser_activity.ml:36-45`).
- 그래서 켜고 끄는 사실이 세 곳에 있어요. 선언의 `enabled`, runtime.toml 의 `*_enabled`, worker 안의 붙음 여부예요.

**broker 와 manifest**
- 업로드·다운로드·`locate` Exact Output 은 Gecko 만 써요. `stagehand` Exact Output 은 Chrome 만 써요. live 연결은 broker 를 안 써요.
- 그런데 모든 worker 가 업로드·다운로드 broker 를 만들고(`bin/masc_browser_addon_worker.ml:27-44`), 패키지 하나가 두 Exact Output 을 다 선언해요(`addons/browser/lane.toml:20-25`).

**Skill 과 Keeper 도구**
- Keeper 가 쓰는 browser 도구(`BrowserTabs`, `BrowserRead`, `BrowserSession`, `BrowserGoto`, `BrowserAct`, `BrowserInteract`, `BrowserInstruct`)는 host 의 도구예요(`keeper_tool_descriptor.ml:1098-1210`).
- `addons/browser/skills/browser/SKILL.md` 하나가 모든 출처를 설명해요. 대부분은 출처와 상관없는 규칙이에요(결과 전체 읽기, 답을 잃은 뒤 다시 보내지 않기, `lane`·`clientId` 받아 두기). 출처별 문단은 Gecko 의 `locate`·업로드·다운로드, Chrome 의 act/extract 정도예요.

**운영자 프로필 보호**
- Chrome 영속 프로필과 live Firefox 프로필은 프로필 폴더 안의 claim slot 으로 지켜요(`.masc-browser-profile-claim`, `.masc-firefox-profile-claim`).
- 이 slot 은 커널 레코드 잠금(`Unix.lockf ... F_TLOCK`)이라, 어느 프로세스가 쥐었든 다른 프로세스는 못 쥐어요(`native_addon_lease/native_addon_lease.ml:486`).

## 3. 원칙과 불변식

**원칙**
- 장애의 경계는 OS 프로세스예요. 한 프로세스 안에서 일어난 일(잡히지 않은 예외, C stub 충돌, 메모리 부족)은 그 프로세스 밖으로 번지지 않아요.
  - Chromium 이 renderer 를 프로세스로 나누는 이유와 같아요. 예전에는 rendering engine 의 버그 하나가 "bring down the entire browser and all of the currently running tabs" 했어요. browser process 는 "manages renderer and other processes" 해요([Multi-process Architecture](https://www.chromium.org/developers/design-documents/multi-process-architecture/)).
- 프로세스를 띄우고 다시 띄우는 일은 supervisor 한 곳이 해요.
  - Erlang/OTP 의 supervisor 는 "responsible for starting, stopping, and monitoring its child processes" 해요. one_for_one 은 "If a child process terminates, only that process is restarted." 예요([Supervisor Behaviour](https://www.erlang.org/doc/system/sup_princ.html)).
  - masc 에서는 Lane Add-on runtime 이 supervisor 예요.
- OTP 의 restart intensity(정한 시간 안에 정한 횟수를 넘기면 멈춤)는 가져오지 않아요. masc 는 누적 횟수로 행동을 막는 게이트를 두지 않아요(`docs/constitution.xml` 의 `budget_gate`). 대신 지금처럼 고정 박자(설정 패스, 기본 60초)로 다시 시도해요. 횟수 제한 없이도 재시작 속도가 박자에 묶여요.
- 나누는 단위는 레인이 아니라 연결의 출처예요. 레인은 Keeper 가 고르는 이름이고, 한 레인(live)에 출처가 셋 있어요. 장애는 출처 단위로 나요.
- 원하는 상태는 선언이 정하고, runtime 이 그 상태로 맞춰요(reconcile). 프로세스가 끝난 모양을 보고 운영자의 뜻을 추측하지 않아요.

**불변식**
1. 출처는 닫힌 합타입이에요: `Browser_backend.t = Automation | Stagehand | Live of Browser_lane.live_transport`. `lane : t -> Browser_lane.Lane_name.t` 는 전체 함수예요. 새 출처는 variant 를 더해서 만들고, 모든 match 가 컴파일러에게 검사받아요.
2. browser worker 하나는 정확히 한 출처만 맡아요. 출처는 패키지 manifest 가 정해요. host 는 그 출처의 설정만 넘겨요.
3. workspace 하나에 출처마다 serving 중인 설치는 많아야 하나예요. setup·preflight 가 두 번째 enabled 선언을 거절해요. 손으로 둘을 선언하면 export 이름이 겹쳐서 지금 규칙대로 Add-on 도구 읽기가 실패해요(2.4, #45360).
4. 고르는 일은 host 의 함수예요. 입력은 요청할 때 받은 worker snapshot 과 요청이에요. worker 는 자기에게 정해진 요청만 실행해요.
5. worker 가 띄운 프로세스는 둘 중 하나예요. worker 의 프로세스 그룹 안에 있거나, worker 할당 안의 masc 전용 프로필 잠금을 쥐고 있어요. 정리 확인은 두 경우가 모두 없다는 걸 봐요.
6. 정리 확인과 교체는 설치 단위예요. worker 안에 출처별 상태 기계를 따로 두지 않아요.
7. 출처를 켜고 끄는 사실은 선언의 `enabled` 하나뿐이에요. runtime.toml 은 어떻게 띄울지만 담아요.

## 4. 제안

### 4.1 S: 연결 출처마다 worker 하나

**패키지**

| 패키지 | `browser_backend` | 출처 | Exact Output | 업로드·다운로드 broker | worker 가 띄우는 것 |
|---|---|---|---|---|---|
| `browser-automation` | `automation` | `Automation` | `locate` | 있음 | geckodriver, Gecko 브라우저 |
| `browser-stagehand` | `stagehand` | `Stagehand` | `stagehand` | 없음 | guardian, Chrome |
| `browser-firefox` | `webdriver_bidi` | `Live Webdriver_bidi` | 없음 | 없음 | guardian, live Firefox |
| `browser-ego` | `ego_task_space` | `Live Ego_task_space` | 없음 | 없음 | 명령마다 `ego-browser nodejs` 한 번 |
| `browser-extension` | `web_extension` | `Live Web_extension` | 없음 | 없음 | 없음. 바깥 client 대기열만 가져요 |

- 다섯 다 embedded 패키지예요.
- manifest 의 `browser_backend` 는 위 다섯 값 중 하나예요. 모르는 값은 manifest 오류예요.
  - 값과 variant 는 `Browser_backend.of_wire`·`to_wire` 로 서로 바꿔요. live 쪽 값은 이미 있는 `live_transport_to_string` 과 같아요.
  - 파싱 결과는 `worker_service = Mcp_tools | Browser_service of Browser_backend.t` 예요. 지금은 `Browser_service` 하나예요(`lane_addon_types.ml:50`, `lane_addon_manifest.ml:134`).
  - `lane_addon` 은 이미 `Browser_lane` 을 참조하므로 의존 방향은 바뀌지 않아요(`lane_addon_sources.ml:2-5`).
- **export 이름은 출처에서 나와요.**
  - 각 패키지는 `Browser_addon_tool.export_name backend` 하나만 내보내요(예: `browser_webdriver_bidi_command`). 이 함수는 variant 에서 이름을 만드는 전체 함수예요. worker 와 host 가 같은 함수를 써요.
  - manifest 파싱은 `Browser_service backend` 패키지의 export 가 그 이름 하나가 아니면 거절해요.
  - 그래서 "보이는 설치 사이에 export 이름은 하나"라는 지금 규칙(2.4)을 고치지 않아요. machine Add-on 처럼 이 규칙에 기대는 다른 소비자도 그대로예요.
- **Skill.**
  - 출처와 상관없는 규칙은 Keeper 가 늘 보는 host 도구 설명(`keeper_tool_descriptor.ml`)으로 옮겨요. 도구를 가진 쪽이 그 계약을 설명해요.
  - 출처에만 있는 문단은 그 패키지 Skill 에 둬요. `browser-automation` 은 `locate`·업로드·다운로드, `browser-stagehand` 는 act/extract 예요. 따로 할 말이 없는 출처는 Skill 이 없어요.
  - 그래서 같은 문장이 여러 패키지에 생기지 않고, 출처가 꺼지면 그 문단만 빠져요.

**worker**
- 실행 파일은 지금의 `masc-browser-addon-worker` 하나를 그대로 써요. host 가 manifest 의 출처를 `--backend <wire>` 로 넘겨요.
- worker 는 그 출처 하나와 그 출처의 broker 만 만들어요.
- 감싸서 띄우는 구조(2.1)는 없어져요. owner 의 상태(`Serving | Retired`)는 그대로 둬요. 이제 owner 하나가 출처 하나의 수명과 같아요.
- 출처마다의 "끝나면 owner 를 revoke 하고 예외를 올림"도 그대로 둬요. 이제 그건 그 worker 하나만 끝내요. runtime 은 #45290 대로 그 설치만 정리하고 다음 설정 패스에 새로 띄워요.

**설정**
- host 는 worker 를 띄울 때 그 출처의 설정만 넘겨요.

  | 출처 | 설정 |
  |---|---|
  | `Automation` | `[browser.automation]` |
  | `Stagehand` | `[browser.stagehand]` |
  | `Live Webdriver_bidi` | `[browser.live.bidi]` |
  | `Live Ego_task_space` | `[browser.live.ego]` |
  | `Live Web_extension` | 없음 |

- 설정이 필요한 출처의 선언에 설정이 없으면 시작 실패(`Worker_failed`)로 끝나고, 까닭은 "설정 없음"이에요.

**선언과 setup**
- `browser-lane-setup` 은 설정된 출처마다 선언을 하나씩 써요(`browser-automation.toml` 등). `browser-extension` 은 native host 를 설치할 때(`--mode host`) 써요.
- 출처마다 enabled 선언이 둘 이상이면 setup 과 preflight 가 거절해요. 지금은 패키지 id `browser` 로 세요(`browser_addon_setup.ml:231-247`, `browser_addon_preflight.ml:40-69`). 이걸 출처로 세게 바꿔요.
- `browser` 패키지와 `browser.toml` 은 지워요(hard cut, 7절).

**바깥 확장 client**
- `/browser-lane/poll` 은 지금처럼 `x-lane: live` 만 받아요.
- `Browser_addon_ingress.for_poll` 의 "browser 서비스가 정확히 하나" 조건은 "`Live Web_extension` 서비스가 정확히 하나"로 바뀌어요. registration 기록의 모양은 그대로예요.

**운영자 프로필 보호**
- 그대로예요. claim slot 은 프로필 폴더 안의 커널 잠금이라, worker 가 나뉘어도 같은 프로필을 두 프로세스가 쓰지 못해요(2.4).

### 4.2 H: 고르는 일은 host 가 해요

**고르기**
- `Browser_selection.resolve` 를 host 로 옮겨요. 이유(reason)의 종류는 지금과 같아요.
- host 는 요청할 때 serving 중인 browser worker 에 이미 있는 `Snapshot` 을 나란히 물어요(2.4). 그 답으로 `Browser_selection.snapshot` 을 만들어요.
  - `live_clients` 는 세 live worker 의 client 를 합친 거예요. automation·stagehand 의 `registered`·`session`·`locate` 는 각자의 worker 에서 받아요.
  - 출처가 있는지(activity)는 그 출처의 worker 가 serving 중이고 snapshot 에 답했는지로 정해요. runtime.toml 을 읽지 않아요(4.4).
  - 지금 `snapshot ()` 이 프로세스 전역 상태를 읽는 부분(`browser_selection.ml:54-63`)은 worker 답을 모으는 함수로 바뀌어요.
  - 캐시된 관측을 쓰지 않아요. 고르는 데 쓰는 값과 실행하는 worker 의 상태가 같은 시점이어야 해서요.
  - snapshot 에 답하지 못한 worker 는 이번 선택에서 쓸 수 없는 출처로 봐요. 그 까닭을 `browserSelection` 에 남겨요.
- 고른 route 를 worker 로 바꾸는 건 전체 함수예요.
  - `Automation_route` → `Automation` worker
  - `Stagehand_route` → `Stagehand` worker
  - `Live_route (Some clientId)` → snapshot 에서 그 client 를 내놓은 live worker. 없으면 dispatch 전에 거절해요.
- Exact route 도 같아요. `Automation_route`·`Stagehand_route` 는 snapshot 없이 바로 보내요. `Live_route (Some clientId)` 는 live worker 들의 snapshot 으로 주인을 찾아요.
- host 가 `browserSelection` 을 직접 찍어요. worker 가 붙이고 host 가 검사하던 일(`browser_addon_host.ml:113-119`)은 없어져요.

**실행**
- worker 는 자기에게 정해진 route 만 받아요. 다른 출처의 route, 자기 것이 아닌 client 는 dispatch 전에 거절해요(`Proven_pre_effect`).
- snapshot 이후 상태가 바뀌어 worker 가 거절하면, host 는 그 거절을 그대로 돌려줘요. 다른 출처로 몰래 다시 보내지 않아요. 다시 고를지는 Keeper 가 정해요. 이미 보냈을 수 있는 입력은 다시 보내지 않는다는 지금 규칙과 같아요.

**서비스 신원**
- `Browser_addon_host.connect` 는 (출처 → 서비스와 그 인스턴스의 export) 표를 돌려줘요.
- export 는 그 인스턴스에서 `export_name backend` 로 찾아요(4.1). 지금처럼 인스턴스 id 와 owner 도 맞춰 봐요(`browser_addon_host.ml:24-27`).
- "정확히 하나" 조건(`browser_addon_host.ml:17-22`)은 출처마다의 조건이 돼요. 한 출처가 없으면 그 출처만 쓸 수 없어요. 나머지는 그대로 골라지고 실행돼요.

**관측과 화면**
- 각 worker 는 자기 출처의 관측 한 줄을 내요(`browser/<wire>`). presence 는 출처마다 찾아요(`lane_addon_runtime.ml:1804-1829`).
- lane inventory 의 세 레인 줄은 그 레인의 worker 들에서 읽어요(`server_lane_inventory.ml:131-140`). Live 줄은 세 live worker 를 합쳐요.
- `/api/v1/dashboard/browser-lane/clients` 는 host 가 snapshot 들을 합쳐 지금과 같은 모양으로 답해요. TUI 는 같은 endpoint 를 그대로 읽어요(`bin/masc_tui_http.ml:3926`).
- 문서 소스는 route 로 worker 를 찾아요. 그래서 `Several_browser_services`(`lane_addon_runtime.ml:1929-1935`)는 "그 route 의 worker 가 없음"으로 바뀌어요.

**#44023 과의 관계**
- 요청이 프로필 종류를 요구하는 일(`profile = Operator_signed_in | Any`)은 host 쪽 선택의 입력이에요. #44023 에서 함께 정해요(issuecomment-6357334797). 이 RFC 는 그 입력이 들어갈 자리(host 의 순수 함수)를 만들어요.

### 4.3 G: Gecko worker 는 자기가 띄운 브라우저를 끝까지 가져요

native worker 는 자기 프로세스 그룹을 가져요. 멈출 때는 먼저 revoke 하고, 그 그룹을 끝내고 거둬요(`lane_addon_native_worker.mli:1-4`, `40`). geckodriver 와 그 브라우저는 이 그룹에 있어요(1.3, `browser_addon_automation.ml:82`). 그래서 DELETE 가 실패해서 남은 브라우저도 worker 를 멈출 때 같이 끝나요. 남는 건 그룹 밖으로 빠져나간 브라우저뿐이에요. 같은 mli 도 "Descendants leaving the group are outside its release receipt and need their package's explicit resource cleanup." 라고 적어요. G 가 그 정리예요.

**G1. 프로필은 masc 가 만들어요.**
- 세션을 열 때마다 worker 가 할당 안에 `profiles/<uuid>` 를 0700 으로 만들어요. Chrome 의 `chromium-profiles/<uuid>` 와 같은 모양이에요.
- 그 경로를 `moz:firefoxOptions.args` 의 `-profile` 로 넘기고, `--profile-root` 는 쓰지 않아요. geckodriver 는 넘겨받은 프로필을 지우지 않아요. 필요한 설정은 geckodriver 가 직접 써 넣어요(1.3). masc 는 `user.js` 를 쓰지 않아요.
- Marionette 포트는 worker 가 driver 포트를 고를 때처럼 빈 loopback 포트를 골라요(`browser_addon_automation.ml:39-44`). geckodriver 의 `--marionette-port` 로 넘겨요. 세션은 한 번에 하나라서 driver 가 사는 동안 포트 하나로 충분해요.

**G2. 잠금 주인을 커널에 물어요.**

정리할 때 `profiles/` 아래 항목마다 이렇게 해요. 이름이 정확한 UUID 가 아닌 항목은 Chrome 처럼 거절해요(2.2).
1. `.parentlock` 을 `O_RDONLY | O_NOFOLLOW` 로 열어요. 일반 파일이고, 소유자가 masc 실행 사용자이고, 링크 수가 1 이어야 해요. 할당 폴더의 inode 는 지금처럼 먼저 확인돼 있어야 해요.
2. 그 fd 로 잠금 주인을 붙잡아요(G3 의 타입). `F_GETLK` 로 찾고, pid 파일은 읽지 않아요.
3. 결과는 닫힌 합타입이에요.
   - `Unlocked`
   - `Held_by of holder`
   - `No_lock_file`
   - `Changing`: 물어보는 사이에 주인이 끝나거나 바뀌었어요. 다음 정리에서 다시 물어요.
   - `Unreadable of string`: `Cleanup_unconfirmed` 로 남기고 경로와 실패한 검사를 말해요.
4. Chrome 은 바꾸지 않아요. Chrome 은 자기 자식 slot 으로 띄우고 정리해요(2.2). 이 잠금 확인은 Gecko 에만 써요.

**G3. 잠금 주인은 별도 타입으로 멈춰요.**
- `Owner_process_identity` 의 계약은 그대로 둬요. 그 모듈의 대상은 workspace lease 주인, 곧 masc 서버예요. "SIGTERM to the captured process incarnation only; never PID fallback or SIGKILL escalation." (`owner_process_identity.mli:8-10`)
- masc 전용 프로필 잠금 주인은 새 타입 `Private_profile_holder.t` 로 다뤄요.
  - 이 값은 G2-1 의 검사를 통과한 잠금 fd 에서만 만들 수 있어요. 검사 결과를 담은 private 타입을 받기 때문이에요.
  - `request_termination` 과 `request_kill` 을 둬요. 둘 다 붙잡은 그 프로세스에만 보내요.
  - C 쪽은 `owner_process_identity_stubs.c` 의 붙잡기·신원 확인(`F_GETLK`, `masc_owner_identity_capture`)을 함께 쓰고, KILL 하나만 더해요.
- 그래서 masc 서버에 KILL 을 보내는 코드는 타입 검사를 통과하지 못해요.
- `Held_by` 를 처음 보면 TERM 을 보내요. 다음 정리 때도 같은 프로세스가 잠금을 쥐고 있으면 KILL 을 보내요. 박자는 지금의 정리 재시도와 같고, 새 시간 제한이나 횟수는 없어요.
- 그 프로세스는 masc 전용 0700 할당 안의 파일에 쓰기 잠금을 쥔 같은 사용자의 프로세스예요. 그래서 그 프로필로 뜬 Gecko 브라우저라고 봐요. 이건 추론이라서, 주인의 실행 파일 경로를 기록에 남겨 사람이 확인할 수 있게 해요.

**G4. 지우는 동안에는 masc 가 잠금을 쥐어요.**
- 모든 항목이 `Unlocked` 이거나 `No_lock_file` 이면, 항목마다 `.parentlock` 에 쓰기 잠금을 직접 걸어요(`lockf`, non-blocking). 걸리지 않으면 G2 부터 다시 해요.
- 잠금을 쥔 채로 프로필을 지워요. 그동안 같은 프로필로 뜨려는 브라우저는 "already open" 으로 바로 끝나요(1.3).
- 지우는 규칙은 Chrome 비공개 프로필의 `remove_profile` 을 두 worker 가 함께 쓰는 함수로 옮겨서 써요. 소유 uid 를 확인하고, 링크는 따라가지 않고 지우고, 링크 수 1 인 일반 파일만 지우고, 그 밖의 것이 있으면 남기고 실패해요.
- `.parentlock` 은 마지막에 지우고, 바로 폴더를 지워요.
  - 그 순간에 다시 뜬 브라우저가 폴더를 새로 만들면 할당 폴더가 비지 않아요.
  - 그러면 할당 정리가 실패하고, 다음 정리가 그 새 폴더를 G2 부터 다시 확인해요. 이 틈도 다음 박자에 잡혀요.

**G5. 함께 바꾸는 것**
- `automation-closed.json` 영수증과 그걸 쓰고 읽는 코드를 지워요. 호환 읽기는 만들지 않아요(hard cut).
- worker 안의 `uncertain` 은 남겨요. 이건 "지금 세션에 명령을 보내도 되나"를 정하는 값이지 정리 확인이 아니에요.
- `uploads/`·`download-snapshots/`·`downloads/` 는 지금처럼 빈 폴더여야 해요(`browser_addon_socket.ml:158-159`, `205`).

### 4.4 D: 켜고 끄는 스위치는 선언 하나예요

- 출처를 켜고 끄는 사실은 그 선언의 `enabled` 하나예요(불변식 7). 꺼진 선언의 worker 는 없어요.
- runtime.toml 의 `[browser.automation] enabled`·`[browser.stagehand] enabled`·`[browser.live] enabled` 를 지워요.
  - `Browser_configuration` 의 `*_enabled` 필드와 그 parser 를 지워요. 허용 키 목록에서도 빠지므로, 남아 있는 `enabled` 는 "is not a supported setting" 으로 거절돼요(`browser_configuration.ml:27-32`).
  - host 가 `*_enabled` 로 출처를 고르던 곳(2.4 의 `1508`, `1512`, `1520`, `1532`)은 지워져요. 띄울지는 선언이 정했어요.
  - server 쪽 activity observer(`server_browser_configuration.ml:1-16`)도 지워요. 출처가 있는지는 host 가 serving 중인 worker 로 알아요(4.2).
  - worker 안의 activity observer(`browser_addon_owner.ml:33`)는 자기 출처만 보면 돼서 단순해져요.
- TUI 의 켜기·끄기는 레인 셋이 아니라 출처마다 보여 줘요. 누르면 runtime.toml 대신 그 선언의 `enabled` 를 고쳐요. 운영자 선언 쓰기 경로(`POST /api/v1/lane-addons/declaration`)가 이미 있어요.
- 꺼서 생기는 일도 출처 하나예요. live Firefox 선언을 끄면 그 worker 만 멈춰요. ego·Chrome·Gecko·바깥 client 는 그대로예요.
- automation 전용 브라우저 설치본은 설치 문서에서 권장만 해요. `[browser.automation] binary` 를 운영자가 평소 쓰지 않는 설치본으로 두고, 그 설치본에만 `DisableAppUpdate` 를 걸면 1.1 의 탈출 자체가 생기지 않아요. setup 이 묻거나 정책 파일을 쓰지는 않아요. G 가 탈출을 정리 박자 안에 풀기 때문이에요.

## 5. 장애별로 달라지는 것

| 장애 | 지금 | 바뀐 뒤 |
|---|---|---|
| live Firefox 연결이 끊김 | worker 가 죽고 모든 출처가 꺼짐 | `browser-firefox` 만 끝나요. 다음 설정 패스가 새로 띄워요. 나머지 세션은 이어져요 |
| ego 연결이 끝나거나, 운영자가 작업 공간을 쥐고 있어 시작하지 못함 | worker 가 죽거나 시작하지 못해 모든 출처가 꺼짐 | `browser-ego` 만 끝나거나 실패해요. 박자마다 다시 시도해요 |
| Gecko 브라우저가 업데이트 재실행으로 빠져나감 | 영수증이 영영 없어 모두 막힘 | automation 정리가 잠금 주인을 찾아 TERM, 다음 박자에 KILL. 확인되면 새 automation 이 떠요. 나머지는 상관없어요 |
| Gecko 세션 DELETE 가 실패함 | 영수증을 쓰지 않아 정리가 영영 막힘(2.3) | automation worker 를 멈출 때 그룹이 끝나요. 잠금이 풀린 걸 확인하면 정리돼요 |
| 출처 코드의 잡히지 않은 예외·C stub 충돌 | 모두 꺼짐 | 그 출처의 worker 하나만 꺼져요 |
| 한 출처의 시작 실패(예: Chrome 실행 파일 없음) | 감싼 구조라 안쪽 출처가 시작하지 못함 | 그 선언만 실패하고, 박자마다 다시 시도해요 |
| 운영자가 live Firefox 만 끄려 함 | `[browser.live] enabled` 가 live Firefox·ego 를 같이 정함(`1508`, `1520`) | `browser-firefox` 선언만 끄면 돼요 |

## 6. 단계

두 스택으로 나눠요. G 는 지금 구조에서도 같은 코드라 먼저 해도 버려지지 않아요. 그래서 효과가 큰 G 를 먼저 내요.

**스택 1: Gecko 소유 (G)**

| 층 | 내용 | 검증 |
|---|---|---|
| G-L1 | `Private_profile_holder`(붙잡기, TERM, KILL)와, Chrome 에서 옮긴 비공개 프로필 삭제 함수 | 실제 자식 프로세스가 `fcntl` 쓰기 잠금을 쥔 픽스처로 `Held_by`·`Unlocked`·`No_lock_file`·`Changing` 확인. TERM 을 무시하는 픽스처가 KILL 로 끝나는지. 링크·링크 수 2 파일 거절 |
| G-L2 | masc 가 만든 Gecko 프로필, `--marionette-port`, `--profile-root` 제거 (G1) | 세션이 masc 가 만든 프로필로 열리는지(`moz:profile`). 세션을 닫아도 프로필이 남는지 |
| G-L3 | 잠금으로 정리 확인, 잠금을 쥔 채 삭제, 영수증 삭제 (G2~G5) | `profiles/<uuid>` 잠금을 쥔 그룹 밖 자식 프로세스가 정리를 막고, TERM 뒤(또는 다음 박자의 KILL 뒤) 운영자 retain 없이 확인되는지. 정리하는 동안 같은 프로필로 뜬 브라우저가 바로 끝나는지. DELETE 가 실패한 세션도 worker 를 멈춘 뒤 정리되는지 |

**스택 2: 출처마다 worker 하나 (S, H, D)**

| 층 | 내용 | 검증 |
|---|---|---|
| S-L1 | host 쪽 선택. 요청할 때 받은 snapshot 으로 `resolve`, route → worker 전체 함수, host 가 `browserSelection` 을 찍음, worker 는 자기 route 만 실행 (H 의 고르기·실행). 이 층에서는 worker 가 아직 하나예요 | 지금의 선택 테스트를 host 로 옮겨 같은 결과가 나오는지. worker 가 다른 route·남의 client 를 거절하는지 |
| S-L2 | `Browser_backend.t`, 서비스 신원을 출처로, `connect`·ingress·presence·inventory·화면·문서 소스를 출처별로 (H 의 나머지) | 다섯 출처의 가짜 browser 서비스로 각 경로가 맞는 worker 로 가는지. 한 출처가 없어도 나머지가 골라지는지 |
| S-L3 | 다섯 패키지, `browser_backend`, 출처별 export 이름, worker `--backend`, 출처별 broker·설정, setup·preflight 출처별, `browser` 패키지 삭제 (S) | 각 worker 가 자기 출처만 띄우는지. 다섯 패키지를 함께 띄워도 Keeper 의 `tools/list` 가 실패하지 않는지. live Firefox 를 끊어도 다른 출처 명령이 계속 되는지. 한 출처의 시작 실패가 다른 출처를 막지 않는지 |
| S-L4 | runtime.toml `enabled` 삭제, activity observer 정리, TUI 켜기·끄기를 선언으로 (D) | `enabled` 가 남은 runtime.toml 이 거절되는지. TUI 에서 끈 출처의 선언만 `enabled = false` 가 되고 그 worker 만 멈추는지 |
| S-L5 | Skill 을 host 도구 설명과 출처별 Skill 로 나눔, 설계 문서(`browser-addon-lifecycle.md`)와 설치 문서 | Keeper 가 받는 도구 설명과 Skill 목록을 실제 `tools/list` 로 확인 |

스택 2 는 native stack 이라 맨 위 PR 로 한 번에 들어가요. 그래서 중간 층은 테스트만 통과하면 되고, 배포할 수 있는 건 맨 위 층이에요.

**바뀌는 기존 테스트**
- `test/test_browser_addon_live_bidi.ml` 의 "unexpected peer loss fences the worker": 그 worker 만 끝나는 걸로 바뀌어요(S-L3).
- `test/test_browser_addon_owner_cleanup.ml` 의 "all backends settle despite failure and caller cancellation": worker 하나에 출처 하나가 돼요(S-L3).
- `test/test_browser_addon_socket.ml` 의 "owned backend requires receipt and empty resource trees"(G-L3)
- `test/test_browser_addon_automation.ml` 의 영수증 관련 테스트(G-L3)
- `test/test_lane_addon_native_runtime.ml` 225-262행의 retain 시나리오(G-L3): `profiles/` 에 남은 파일 `escaped-browser-profile` 때문에 정리가 거절되고 retain 으로 끝나요. 결과는 같아요. 거절하는 까닭만 "영수증 없음"에서 "masc 가 만든 프로필이 아닌 항목"으로 바뀌어요.
- 서비스나 선언이 하나라는 가정(S-L2, S-L3)
  - `test/test_lane_addon_native_runtime.ml:716` ("with two browser Add-ons the source is unavailable")
  - `test/test_lane_addon.ml:379` (`Several_browser_services`)
  - `test/test_browser_addon_owner.ml:159-160`, `test/test_browser_addon_preflight.ml:106-122`, `test/test_browser_addon_setup.ml:155-168`, `test/test_browser_lane_routes.ml:187`

## 7. 옮겨 가기 (hard cut)

- **G-L3 을 배포할 때.** 이전 판이 띄운 인스턴스의 할당에는 `automation-closed.json` 이 남아 있어요. 새 판은 모르는 파일로 보고 정리를 거절해요. 그 배포에서 한 번은 운영자 retain 이 필요해요. changelog 에 `Fresh state required` 로 적어요.
- **S-L3·S-L4 를 배포할 때.**
  - 배포 전에 운영자가 runtime.toml 의 `[browser.*]` 에서 `enabled` 줄을 지워요. 남아 있으면 새 판이 runtime.toml 을 읽지 못해요(4.4). runtime.toml 은 운영자 파일이라 masc 가 고쳐 쓰지 않아요.
  - 지우기 전에 꺼 둔 출처가 있었다면, setup 이 그 출처의 선언을 `enabled = false` 로 써요.
  - `browser.toml` 과 `packages/browser` 를 지우고, `browser-lane-setup` 이 출처별 선언을 새로 써요. `install-local-build.sh` 는 `--no-browser-addon` 을 주지 않으면 browser Add-on 을 설치하므로 같은 단계에서 해요.
  - 이전 `browser` 인스턴스는 지금의 정리·retain 경로로 끝내요.
  - 호환 읽기나 옛 선언 변환은 만들지 않아요. changelog 에 `Fresh state required` 로 적어요.

## 8. 대안과 트레이드오프

| 대안 | 장점 | 단점 |
|---|---|---|
| worker 하나 안에서 출처별 상태와 정리를 나눔 (이 RFC 의 첫 판) | 프로세스가 하나라 가벼워요 | 프로세스가 통째로 죽는 장애(잡히지 않은 예외, C stub 충돌, 메모리 부족)는 여전히 모두를 끝내요. 설치 단위 정리·교체 장치를 worker 안에 하나 더 만들어 같은 일을 하는 장치가 둘이 돼요 |
| 레인마다 worker 하나 (live·automation·stagehand 셋, 이 RFC 의 둘째 판) | 프로세스가 셋이고, 레인과 패키지가 1:1 이에요 | live 안의 Firefox·ego·바깥 client 가 한 프로세스에 남아요. ego 의 시작 실패나 Firefox 의 끊김이 다른 live 연결을 같이 끝내요(2.1, 5절). 1.2 와 같은 장애예요 |
| 고르는 일을 맡는 별도 worker(router)를 둠 | host 를 덜 고쳐요 | 거쳐 가는 곳과 장애 지점이 하나 더 생겨요. host 는 이미 요청을 받는 곳이라 router 를 따로 둘 이유가 없어요 |
| 선택을 worker 마다 하고 host 는 처음 받아 주는 worker 를 씀 | 고칠 곳이 적어요 | 결과가 worker 가 답한 순서에 따라 달라져요. 같은 입력에 같은 답이 나오지 않아요 |
| 공용 이름 규칙에서 browser export 만 빼 줌 | 패키지 export 이름이 같아도 돼요 | 이름 규칙에 기대는 다른 소비자(2.4)와 다른 규칙을 하나 더 만들어요. 출처에서 이름을 만드는 쪽은 기존 규칙을 그대로 둬요 |
| Gecko 브라우저를 masc 가 직접 띄우고 geckodriver 는 `--connect-existing` 으로 붙음 | 브라우저 pid 를 masc 가 알아요 | 업데이트 재실행처럼 브라우저가 스스로 다시 뜨면 결국 놓쳐요. 잠금 확인은 그래도 필요해요 |
| 시작 전에 브라우저의 업데이트 대기 상태를 읽고 거절 | 탈출을 미리 막아요 | Mozilla 내부 파일 형식(`active-update.xml`)에 기대요. 형식이 바뀌면 조용히 틀려요 |
| masc 가 정책 파일을 써서 업데이트를 끔 | 탈출이 사라져요 | 운영자 브라우저 전체 설정을 바꿔요 |

치르는 비용
- 상주 프로세스가 하나에서 최대 다섯으로 늘어요. 설정한 출처만 떠요. `browser-ego`·`browser-extension` 은 브라우저를 띄우지 않아요. 다섯 worker 의 메모리는 S-L3 배포 뒤 재서 증거로 남겨요.
- Automatic 요청과 live client 를 지정한 요청마다 로컬 `Snapshot` 왕복이 최대 다섯 늘어요.
- 운영자가 runtime.toml 을 한 번 고쳐야 하고, hard cut 이 두 번 있어요(7절).

남는 한계
- 잠금 주인이 Gecko 브라우저라는 판단은 추론이에요(G3). 실행 파일 경로를 기록해서 사람이 확인할 수 있게 해요.
- masc 가 고른 Marionette 포트를 다른 프로세스가 먼저 잡으면 그 세션 시작이 실패해요. automation worker 만 영향을 받아요.

## 9. 검증 방법

배포한 뒤 5절의 장애를 실제로 일으키고, 서버 로그와 `GET /api/v1/lane-addons` 응답을 증거로 남겨요.

| 장애 | 배포한 층 | 성공 기준 |
|---|---|---|
| Gecko 탈출 | G-L3 | 운영자 Zen 에 업데이트를 받아 둔 채로 automation 세션을 열어요. 운영자 retain 없이 정리 박자 한두 번 안에 탈출한 프로세스가 멈추고 할당이 확인돼요 |
| live Firefox 끊김 | S-L3 | live Firefox 를 직접 꺼요. 다른 출처 명령이 계속 되고, 다음 설정 패스에 `browser-firefox` 가 새로 떠요 |
| ego 시작 실패 | S-L3 | 운영자가 ego 작업 공간을 쥔 채로 둬요. `browser-ego` 만 실패로 남고, 나머지는 serving 이에요 |
| 출처 하나가 죽음 | S-L3 | `browser-stagehand` worker 를 밖에서 죽여요. 다른 worker 는 그대로이고, stagehand 만 다시 떠요 |
| 출처 끄기 | S-L4 | TUI 에서 live Firefox 를 꺼요. `browser-firefox` 선언만 `enabled = false` 가 되고 그 worker 만 멈춰요 |

## 10. 정하지 않은 것

1. 요청 시점 snapshot 비용은 재지 않았어요. S-L1 에서 재고, 그 값이 문제가 될 때만 다른 방법을 찾아요.
2. TUI 에서 출처 다섯을 어떻게 보여 줄지는 S-L4 에서 운영자와 정해요. 레인 단위 묶음 버튼을 둘지도 그때 정해요.

## 11. 결정과 리뷰 기록

**운영자 결정 (2026-10-23)**
- Gecko 정리는 프로필 잠금으로 확인하고, 전용 설치본은 문서에서 권장만 해요.
- backend 분리를 같은 RFC 에서 다뤄요.
- "정석, 시스템적으로 단단한 결정"을 기준으로 다시 정했어요.
  - 출처마다 worker 하나를 둬요(S).
  - host 가 골라요(H).
  - 켜고 끄는 사실은 선언 하나예요(D).
  - "끝난 live 를 요청이 올 때 다시 띄우기"는 거뒀어요. 그건 worker 가 운영자의 뜻을 추측하는 일이었고, 다시 띄우는 경로가 supervisor 말고 하나 더 생겼어요.
  - KILL 은 별도 타입에만 두고, `user.js` 는 쓰지 않아요.

**판을 바꾼 까닭**
- 첫 판(#45319 로 main 에 들어감)은 worker 하나 안에서 backend 별 상태를 나눴어요. 프로세스가 통째로 죽는 장애를 막지 못해서 버렸어요.
- 둘째 판은 레인마다 worker 를 뒀어요. 쓰는 동안 ego lite 스택(#45234~#45256)이 main 에 들어왔어요. live 레인에 출처가 셋이 되어, 나누는 단위를 출처로 바꿨어요.
- 둘째 판을 쓰며 같은 이름의 export 가 Keeper `tools/list` 전체를 막는 걸 찾았어요. 그래서 export 이름을 출처에서 만들고, 그 넓은 실패 범위는 #45360 으로 따로 남겼어요.

**첫 판의 적대적 리뷰 (2026-10-23, 맥락 없이 따로 맡김)**

나온 지적과 이 판에서 그 지적이 어디로 갔는지예요.
- **P1:** 잠금이 풀린 프로필은 `empty_tree` 로 지울 수 없었어요. → G4 에서 Chrome 비공개 프로필 삭제 규칙을 함께 써요.
- **P1:** live 재시작에 그걸 일으킬 장치가 없었어요. → live 연결도 worker 하나라서 supervisor 가 다시 띄워요(S).
- **P2:** Gecko 확인이 worker 전체의 `Settled` 에 기대는 점 → Gecko worker 가 따로라서 그대로 맞는 조건이 됐어요.
- **P2:** 모든 backend 가 owner 를 revoke 하는 점, 시작이 감싸여 있는 점 → worker 하나에 출처 하나라서 더는 문제가 아니에요(S).
- **P2:** DELETE 실패로 브라우저가 worker 그룹에 남는 점 → automation worker 를 멈출 때 그룹이 끝나요(G).
- **P2:** `Owner_process_identity` 의 사용 조건과 오류 → G2·G3 에 반영했어요.
- **P2:** 지워진 프로필의 잠금을 볼 수 없는 틈 → masc 가 프로필을 만들어 닫았어요(G1). 다시 뜨기 직전의 틈 → 잠금을 쥔 채 지워서 닫았어요(G4). 둘 다 1.3 에서 실제로 확인했어요.
- **P2:** 할당 하나에 기록 하나라서 서로 막는 점 → 설치가 출처마다 따로라서 없어졌어요(S).
- **P3:** 인용 줄 번호는 이 판의 base 에서 다시 읽었어요. 배포 때 retain 이 한 번 필요한 점은 7절에 적었어요.
