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
- 바깥 native host(확장 프로그램 또는 BiDi 브라우저)

2026-10-22~23 에 이 구조 때문에 브라우저 도구가 두 번 오래 멈췄어요(1절).
1. Gecko 브라우저가 worker 밖으로 빠져나갔어요. 정리를 영영 확인할 수 없어서 모든 출처가 3시간 막혔어요.
2. live Firefox 연결 하나가 끊기자 worker 전체가 죽었어요. Chrome·Gecko 도 같이 꺼졌어요.

같은 묶임이 ego 에도 있어요. ego 연결이 끝나거나 시작하지 못하면 worker 전체가 끝나요(2.1).

이 RFC 는 정석을 따라요. **장애의 경계는 프로세스이고, 프로세스를 띄우고 다시 띄우는 일은 supervisor 가 하고, 고르는 일은 그 위의 host 가 한다.**

- **S. 연결 출처마다 Lane Add-on worker 하나.**
  - 출처는 "그 브라우저를 누가 가졌나"로 나눈 닫힌 합타입이에요: `Automation | Stagehand | Owned_firefox | Ego | External_host`. 연결 방식(transport)은 지금처럼 client 정보에 남아요.
  - 패키지·선언·프로세스가 출처마다 하나씩이에요. 격리·정리 확인·교체는 이미 있는 설치 단위 장치와 #45290 을 그대로 써요.
  - browser worker 의 export 는 host 만 불러요. Keeper 는 지금도 있는 host 도구(`masc_browser_*`)를 써요.
- **H. 고르는 일은 host 가 해요.** host 가 요청할 때 각 worker 에 이미 있는 `Snapshot` 을 물어서 골라요. `Snapshot` 은 읽기라서, 실패해도 worker 를 failed 로 만들지 않아요.
- **G. masc 가 Gecko 브라우저를 끝까지 가져요.**
  - Gecko 프로필은 masc 가 Lane Add-on store 아래(`<lane-addons>/gecko-profiles/`)에 만들어요. 인스턴스 할당 밖이에요.
  - server 가 설정 패스마다 끝난 인스턴스의 프로필을 쓸어요. `.parentlock` 을 쥔 프로세스가 있으면 TERM 을 보내고, 같은 프로세스가 70 초 뒤에도 쥐고 있으면 KILL 을 보내요. 지우는 동안에는 masc 가 그 잠금을 쥐어요.
  - 세션 권한을 잃은 automation worker 는 스스로 끝나요.
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
| 20:57 이후 | 세션 생성이 sessionId 없이 끝나서 `uncertain` 이 켜졌어요. automation 명령이 모두 `owned browser session authority is unknown` 으로 거절됐어요. worker 는 그 상태로 계속 떠 있었어요. | `lib/browser_addon_automation.ml:92`, `115` |
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
| 상위 폴더까지 없는 경로를 `-profile` 로 넘기고 headless Zen 시작 | Zen 이 상위 폴더까지 새로 만들고 계속 떠 있었어요 |
| headless Zen 본체에 SIGKILL | 자식 `plugin-container` 10개가 5초 안에 모두 끝났어요 |
| headless Zen 본체에 SIGTERM | 바로 끝났어요(종료 코드 143). 그 프로필로 남은 프로세스는 없었어요 |
| Zen 이 상위 폴더까지 없는 `-profile` 경로를 만들 때의 권한 | 두 단계 모두 0700 이었어요 |
| `-profile` 만 주고 `--marionette-port` 없이 geckodriver 로 두 세션을 차례로 엶 | geckodriver 가 프로필 `user.js` 에 `marionette.port = 0` 을 썼어요. 두 브라우저가 각자 포트(64662, 64685)를 골라 프로필의 `MarionetteActivePort` 에 적었고, 두 세션 모두 1.5 초 안에 열렸어요. `moz:profile` 은 넘긴 경로와 글자까지 같았어요 |
| `-profile` 과 `--marionette-port M` 을 함께 줌 | geckodriver 가 `user.js` 에 `marionette.port = M` 을 썼어요. 다시 뜬 브라우저도 M 을 잡는다는 뜻이에요 |
| 없는 경로를 geckodriver 에 `-profile` 로 줌 | `session not created: Failed to set preferences` 로 거절했어요 |

geckodriver 문서도 같은 걸 말해요([Profiles](https://firefox-source-docs.mozilla.org/testing/geckodriver/Profiles.html)).
- `-profile` 로 넘긴 프로필은 그 자리에서 써요. 올바르게 동작하는 데 필요한 설정은 geckodriver 가 직접 써 넣어요.
- 지워지는 건 geckodriver 가 만든 임시 프로필뿐이에요.
- 알려진 버그 때문에 직접 넘긴 프로필에서는 `--marionette-port` 로 포트를 정하라고 해요. 하지만 0.37.1 은 위 표처럼 포트를 정하지 않아도 세션마다 다른 포트를 썼어요. masc 는 실측을 따라 포트를 정하지 않아요.

Marionette 포트에 관한 두 줄(`--marionette-port` 있음·없음)은 2026-10-23 에 geckodriver 0.37.1 로 한 번씩 본 결과예요. 문서가 말하는 버그가 남은 판에서는 다를 수 있어요(8절 남는 한계).

표의 결과가 4.3 의 설계를 정해요. 프로필을 지워도, 다시 뜬 브라우저는 그 경로를 새로 만들어요. 그래서 masc 는 인스턴스가 끝난 뒤에도 그 경로를 계속 봐야 해요. 반대로 잠금 주인 하나만 끝내면 그 브라우저의 자식까지 끝나요.

## 2. 지금 구조

인용한 줄은 이 판의 base 인 main(`22f7eaea05a`) 기준이에요.

### 2.1 다섯 출처가 한 프로세스에 있어요

- worker 는 출처를 감싸서 띄워요: `automation (chrome (live_bidi (ego (serve))))` (`bin/masc_browser_addon_worker.ml:77-86`). 바깥 것의 시작이 실패하면 안쪽은 시작조차 하지 않아요.
- owner 의 상태는 하나예요: `type phase = Serving | Retired` (`lib/browser_addon_owner.ml:4`). 프로세스마다 owner 는 하나뿐이에요(`process_claimed`, `owner.ml:21-31`). live 연결은 transport 마다 하나씩 owner 의 목록에 붙어요(`owner.ml:14`).
- 출처마다 자기가 끝날 때 owner 전체를 revoke 하고, 시작에 실패하거나 연결이 끊기면 예외로 프로세스를 끝내요.

  | 출처 | revoke | 프로세스를 끝내는 예외 |
  |---|---|---|
  | Gecko | `browser_addon_automation.ml:105`, `172` | 시작 실패 `:169` |
  | Chrome | `browser_addon_stagehand.ml:387` | 시작 실패 `:384` |
  | live Firefox | `browser_addon_live_bidi.ml:274`, `280`, `286` | 시작 실패 `:284`, 연결이 끊기면 `:290` |
  | ego | `browser_addon_live_ego.ml:157`, `163`, `170` | 시작 실패 `:167`, 연결이 끝나면 `:175` |

- 설계 문서도 그렇게 정해요.
  - "An unexpected connection failure revokes that worker rather than publishing a dead client." (`docs/design/browser-addon-lifecycle.md` 38-39행)
  - "An ego that cannot start, or a task space name the operator holds, fails the worker's start as a configured live Firefox does." (같은 문서 25-27행)

### 2.2 정리 확인은 할당 하나에 하나예요

- `Browser_addon_socket.cleanup` 은 할당 하나(`$TMPDIR/mb-<id>`)를 한 줄로 확인해요. installation admission 이 `Settled` 여야 하고, Chrome·live 자식 slot 을 settle 하고, Gecko 영수증을 읽어요. 하나라도 실패하면 모두 막혀요.
- 같은 선언의 새 인스턴스는 이전 인스턴스가 정리돼야 떠요(`lane_addon_runtime.ml` 의 `native_settled`).
- 할당이 확인되면 폴더를 지우고 `released` 를 기록해요(`browser_addon_socket.ml:311`, `317`). 그 뒤로 그 인스턴스는 다시 정리되지 않아요. 다음 인스턴스는 새 `mb-<uuid>` 를 써요(`:16-20`).
- 빈 폴더 트리만 지워요(`empty_tree`, `browser_addon_socket.ml:143-151`). 파일이 남은 Gecko 프로필은 지울 수 없어요.
- Chrome 비공개 프로필은 자식 claim 을 settle 한 뒤(`cleanup`, `browser_addon_stagehand.ml:107-121`), 이름이 정확한 UUID 인 폴더만 `remove_profile`(`:89-104`)로 지워요. `remove_profile` 은 폴더 목록 순서대로 지워요.

### 2.3 Gecko 는 브라우저를 직접 갖지 않아요

- geckodriver 는 worker 그룹 안에서 떠요(`browser_addon_automation.ml:82`, 그룹을 만들지 않는 `mgr`). 프로필은 geckodriver 가 `--profile-root` 아래에 만들어요. driver 하나가 worker 가 사는 동안 세션을 여러 번 열어요(`browser_webdriver.ml:271-300`).
- 정리 확인은 worker 가 쓰는 영수증에 맡겨요.
  - 세션 생성이 확실하지 않으면(`uncertain`) 영수증을 쓰지 않아요. `uncertain` 은 sessionId 없는 생성(`:92-96`)이나 `Invalid_session_id` 답(`:99`)으로 켜지고 다시 꺼지지 않아요.
  - 세션 DELETE 가 실패해도 영수증을 쓰지 않아요(`:106-108`, `:150-153`).
- `uncertain` 이 켜지면 모든 명령을 거절하지만(`:114-116`), worker 를 끝내는 코드는 없어요. 1.1 의 20:57~21:48 이 그 상태였어요.
- 브라우저가 그룹 밖으로 빠져나가면 masc 는 그걸 확인할 방법이 없어서 영수증을 영영 쓰지 못해요.

### 2.4 host 와 worker 의 경계

**고르기**
- Automatic 선택(`Browser_selection.resolve`)은 worker 안에서 해요. 입력은 그 프로세스의 전역 `Browser_lane` 상태예요(`browser_addon_tool.ml:113`, `browser_selection.ml:54-63`, `177`).
- worker 안에서만 하는 일이 더 있어요.
  - `lane=live` 에 clientId 가 없으면, 연결된 client 가 하나일 때만 그 client 를 써요. 둘 이상이면 `Ambiguous_clients` 예요(`browser_lane/browser_lane.ml:774-781`).
  - Exact route 의 `requiredActions` 확인(`require_target`, `browser_addon_tool.ml:116`, `browser_selection.ml:171-176`)도 worker 안의 상태로 해요.
  - 답의 `browserConnection` 은 worker 안의 target 으로 만들어요(`browser_binding.ml:10-11`).
- worker 는 `browserSelection`(lane, clientId, reason)을 답에 붙이고, host 는 그것을 검사해요(`browser_addon_tool.ml:128-130`, `browser_addon_host.ml:113-119`).
- host 는 이미 worker 에 `Snapshot` 을 물어볼 수 있어요(`browser_addon_host.ml:43-49`, `browser_addon_owner.ml:237-239`). 시간 제한은 control 명령과 같아요(`browser_addon_client.ml:60`, 기본 5초, `env_config_runtime.ml:695-696`).
- 그런데 `Snapshot` 이 쓴 뒤에 끝나지 못하면 `Outcome_unknown` 이 되고(`browser_addon_client.ml:65-67`), runtime 은 그 worker 를 failed 로 바꿔요(`lane_addon_runtime.ml:1908-1909`). 예외는 `only_if_idle` 읽기뿐이에요(`:1881-1883`).

**서비스는 하나라고 가정해요**
- `Browser_addon_host.connect` 는 browser 서비스가 정확히 하나여야 해요(`browser_addon_host.ml:17-22`).
- native host 의 처음 poll 도 그래요(`browser_addon_ingress.ml:61-64`). 문서 소스도 같아요(`Several_browser_services`, `lane_addon_runtime.ml:1929-1935`).
- presence 는 export 하나의 관측을 찾고, 둘이면 `Ambiguous_installations` 예요(`lane_addon_runtime.ml:1804-1829`). lane inventory 는 한 worker 의 관측 한 줄로 세 레인 줄을 만들어요(`browser_addon_observation.ml:43-45`, `server_lane_inventory.ml:131-140`).

**worker 의 export 가 Keeper 도구가 돼요**
- Keeper 의 도구 목록은 보이는 Add-on export 를 모두 도구로 만들어요(`keeper/keeper_run_tools_setup.ml:553-556`, `keeper/keeper_lane_addon_descriptor.ml:29-57`). MCP `tools/list` 도 그래요(`mcp_server_eio_protocol.ml:338-339`). 그래서 worker 의 `browser_command` 는 지금 Keeper 도구예요.
- 같은 일을 하는 host 도구도 따로 있어요. Keeper 안에서는 `BrowserTabs`·`BrowserRead`·`BrowserSession`·`BrowserGoto`·`BrowserAct`·`BrowserInteract`·`BrowserInstruct`(`lib/keeper/keeper_tool_descriptor.ml:1098-1210`), MCP 에서는 `masc_browser_*` 예요(`config.ml:9`, `tool_schemas/tool_schemas_misc_toml.ml:22`).
- export 이름은 보이는 설치 전체에서 하나여야 해요. `tool_export_reading` 은 같은 이름이 둘이면 읽기 전체를 실패로 돌려요(`lane_addon_runtime.ml:1754-1760`, `1779-1782`). 그러면 `tools/list` 가 `Invalid_request` 로 통째로 실패해요(`mcp_server_eio_protocol.ml:409-410`). machine host(`machine_addon_host.ml:127`, `143`)와 Skill 편집기(`server_skill_editor.ml:473`)도 이 함수를 써요. 실패 범위가 너무 넓은 문제는 #45360 에 따로 남겼어요.
- 그래서 지금 패키지를 그대로 여럿 띄우면 Keeper 도구 목록이 깨져요. setup 이 enabled 선언 둘을 거절하는 것도 이 때문이에요.

**live 연결**
- live 연결의 방식은 닫힌 합타입이에요: `type live_transport = Web_extension | Webdriver_bidi | Ego_task_space` (`browser_lane/browser_lane.ml:481`).
- 바깥 native host 는 `/browser-lane/poll` 로 들어와요. 이 경로는 `x-lane: live` 만 받고(`server_routes_http_routes_browser_lane.ml:64-69`), 연결 방식으로 `Web_extension` 과 `Webdriver_bidi` 를 받아요(`:73-82`). 바깥 BiDi host 는 `masc-browser-host --bidi-url` 이에요(`bin/masc_browser_host.ml:38`).
  - 그래서 `Webdriver_bidi` 는 masc 가 띄운 Firefox 일 수도, 바깥 native host 가 붙인 브라우저일 수도 있어요. 연결 방식만으로는 누가 그 브라우저를 가졌는지 알 수 없어요.
  - 처음 poll 때 browser 서비스 하나에 묶이고, 그 사실을 `registrations/<clientId>/owner.json` 에 남겨요(`browser_addon_registration.ml:60-76`).
- worker 가 여는 live Firefox·ego client 는 프로세스 안에서 `poll 0.` 으로 등록되고(`browser_addon_live_bidi.ml:229`, `browser_addon_live_ego.ml:104`, `browser_addon_owner.ml:277-284`), 기록 파일은 남기지 않아요.

**켜고 끄기**
- host 는 browser 패키지마다 전역 `[browser.*]` 설정을 읽고, 켜진 출처를 모두 그 worker 에 넘겨요(`lane_addon_runtime.ml:1500-1535`). 켜졌는지는 `*_enabled` 로 봐요(`1508`, `1512`, `1520`, `1532`). `[browser.live] enabled` 하나가 live Firefox 와 ego 를 같이 정해요.
- 값이 없으면 켜진 걸로 읽어요(`browser_configuration.ml:41-43`). `enabled` 만 있는 표는 "설정 안 함"으로 읽어요(`:77-79`).
- `*_enabled` 를 읽는 곳이 더 있어요.
  - server 쪽 activity(`server_browser_configuration.ml:1-16`)와 BiDi host 상태(`browser_bidi_host_status.ml:12-17`, 화면의 `bidiHost`)
  - setup 계획(`browser_lane_automation_setup.ml:305`, `332`, `browser_lane_bidi_setup.ml:315`, `browser_lane_ego_setup.ml:208`, `221`)과 setup 안내 문구(`bin/masc_cli_browser_lane_setup.ml:172`, `230`, `264`)
  - lane inventory(`server_lane_inventory.ml:160`)
- worker 안에서는 activity 를 runtime.toml 이 아니라 "그 출처가 붙었나"로 정해요. live 레인은 늘 켜져 있어요(`browser_addon_owner.ml:34`). 그래서 `[browser.live] enabled = false` 는 바깥 native host 를 막은 적이 없어요. masc 가 띄우는 live Firefox·ego 를 띄우지 않을 뿐이었어요.
- TUI 의 레인 켜기·끄기는 runtime.toml 의 그 값을 고쳐요(`bin/masc_tui_browser_activity.ml:36-45`).
- 그래서 켜고 끄는 사실이 세 곳에 있어요. 선언의 `enabled`, runtime.toml 의 `*_enabled`, worker 안의 붙음 여부예요.

**Exact Output 과 broker**
- 업로드·다운로드·`locate` Exact Output 은 Gecko 만 써요. `stagehand` Exact Output 은 Chrome 만 써요. live 연결은 broker 를 안 써요.
- 그런데 모든 worker 가 업로드·다운로드 broker 를 만들고(`bin/masc_browser_addon_worker.ml:27-44`), 패키지 하나가 두 Exact Output 을 다 선언해요(`addons/browser/lane.toml:20-25`).
- Exact Output 의 lane 은 선언 id 로 묶여요: `[runtime.addon_exact_lanes.<declaration id>.<output>]` (`runtime/runtime_toml.ml:3011-3015`, `lane_addon_runtime.ml:1272-1276`). 지금 선언 id 는 `browser` 예요. 이름이 맞는 표가 없으면 `Lane_unconfigured` 예요(`server_lane_addon_exact.ml:234-239`).

**Skill**
- `addons/browser/skills/browser/SKILL.md` 하나가 모든 출처를 설명해요. "exported `browser_command` tool 을 쓰라"로 시작해요.
- 대부분은 출처와 상관없는 규칙이에요(결과 전체 읽기, 답을 잃은 뒤 다시 보내지 않기, `lane`·`clientId` 받아 두기). 출처별 문단은 Gecko 의 `locate`·업로드·다운로드, Chrome 의 act/extract 정도예요.

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
- OTP 의 restart intensity(정한 시간 안에 정한 횟수를 넘기면 멈춤)는 가져오지 않아요. masc 는 누적 횟수로 행동을 막는 게이트를 두지 않아요(`docs/constitution.xml` 의 `budget_gate`). 대신 지금처럼 고정 박자(설정 패스, 기본 60초)로 다시 시도해요.
- 나누는 단위는 레인도 연결 방식도 아니고, 그 브라우저를 누가 가졌나예요. 장애는 그 단위로 나요. 레인은 Keeper 가 고르는 이름이고, 연결 방식은 client 정보예요.
- masc 가 띄운 것은 masc 가 끝까지 가져요. 인스턴스가 끝나도, 그 인스턴스가 띄운 브라우저가 다시 뜰 수 있는 동안은 masc 가 봐요.
- 원하는 상태는 선언이 정하고, runtime 이 그 상태로 맞춰요(reconcile). 프로세스가 끝난 모양을 보고 운영자의 뜻을 추측하지 않아요.

**불변식**
1. 출처는 닫힌 합타입이에요: `Browser_backend.t = Automation | Stagehand | Owned_firefox | Ego | External_host`. `lane : t -> Browser_lane.Lane_name.t` 는 전체 함수예요(`Owned_firefox`·`Ego`·`External_host` 는 `Live`). 새 출처는 variant 를 더해서 만들고, 모든 match 가 컴파일러에게 검사받아요.
2. browser worker 하나는 정확히 한 출처만 맡아요. 출처는 패키지 manifest 가 정해요. host 는 그 출처의 설정만 넘겨요.
3. workspace 하나에 출처마다 serving 중인 설치는 많아야 하나예요. setup·preflight 가 두 번째 enabled 선언을 거절해요. 손으로 둘을 선언하면 그 출처만 `Ambiguous` 로 쓸 수 없어요. browser export 는 공개 도구 목록에 오르지 않으므로(4.1), 다른 도구까지 막히지는 않아요.
4. 고르는 일은 host 의 함수예요. 입력은 요청할 때 받은 worker snapshot 과 요청이에요. worker 는 자기에게 정해진 요청만 실행해요. snapshot 을 묻는 일은 worker 의 수명에 영향을 주지 않아요.
5. masc 가 띄운 프로세스는 둘 중 하나예요. worker 의 프로세스 그룹 안에 있거나, workspace 의 Gecko 프로필 root 안에서 `.parentlock` 을 쥐고 있어요. 그룹은 인스턴스 정리가, 프로필 root 는 server 가 설정 패스마다 확인해요. 할당을 놓는 일은 프로필 root 를 기다리지 않아요.
6. 정리 확인과 교체는 설치 단위예요. worker 안에 출처별 상태 기계를 따로 두지 않아요.
7. 출처를 켜고 끄는 사실은 선언의 `enabled` 하나뿐이에요. runtime.toml 은 어떻게 띄울지만 담아요.

## 4. 제안

### 4.1 S: 연결 출처마다 worker 하나

**패키지**

| 패키지 | `browser_backend` | 출처 | Exact Output | 업로드·다운로드 broker | worker 가 띄우는 것 |
|---|---|---|---|---|---|
| `browser-automation` | `automation` | `Automation` | `locate` | 있음 | geckodriver, Gecko 브라우저 |
| `browser-stagehand` | `stagehand` | `Stagehand` | `stagehand` | 없음 | guardian, Chrome |
| `browser-firefox` | `owned_firefox` | `Owned_firefox` | 없음 | 없음 | guardian, live Firefox |
| `browser-ego` | `ego` | `Ego` | 없음 | 있음 | 명령마다 `ego-browser nodejs` 한 번 |
| `browser-external` | `external_host` | `External_host` | 없음 | 없음 | 없음. 바깥 native host 의 client 대기열만 가져요 |

- 업로드·다운로드 broker 는 automation 과 ego 에 있어요. 두 출처의 브라우저가 업로드 사본을 읽고 다운로드를 남겨요(`browser_addon_uploads.ml` 의 stage, `browser_addon_live_ego.ml` 의 다운로드). 처음 판의 표는 ego 를 "없음"으로 적었는데, 코드와 달라서 S-L3 에서 바로잡았어요.
- 다섯 다 embedded 패키지예요. 저장소에서는 `addons/browser/<automation|stagehand|firefox|ego|external>/` 에 있어요.
- manifest 의 `browser_backend` 는 위 다섯 값 중 하나예요. 모르는 값은 manifest 오류예요.
  - 값과 variant 는 `Browser_backend.of_wire`·`to_wire` 로 서로 바꿔요.
  - 파싱 결과는 `worker_service = Mcp_tools | Browser_service of Browser_backend.t` 예요. 지금은 `Browser_service` 하나예요(`lane_addon_types.ml:50`, `lane_addon_manifest.ml:134`).
  - `Browser_backend` 는 `Browser_lane` 만 참조하는 작은 모듈이에요. `lane_addon` 은 이미 `Browser_lane` 을 참조하므로(`lane_addon_sources.ml:2-5`) 의존 방향은 바뀌지 않아요.
- `External_host` worker 는 바깥 native host 가 붙이는 두 연결 방식(`Web_extension`, `Webdriver_bidi`)을 다 받아요. 연결 방식은 지금처럼 `client_info.transport` 에 남아요.

**browser export 는 host 만 불러요**
- `Browser_service` 설치의 export 는 Keeper 도구 목록과 MCP `tools/list` 에 오르지 않아요. 공개 export 를 읽는 함수(`tool_export_snapshot`, `tool_export_reading`)는 `Mcp_tools` 설치만 봐요. 설치의 타입으로 가르므로 이름이나 문자열을 보지 않아요.
- `Browser_addon_host` 는 browser 서비스를 출처로 따로 읽어요. 그래서 다섯 패키지가 모두 `browser_command` 라는 같은 이름을 내보내도 서로 겹치지 않아요.
- Keeper 는 지금도 있는 host 도구(`Browser*`, `masc_browser_*`, 2.4)로 브라우저를 써요. MCP 호출자도 `masc_browser_*` 를 써요. 이 일곱 도구는 MCP `tools/list` 에 올라요.
- worker 의 `browser_command` 로만 되던 일은 둘이었어요. 문서 원문 읽기는 `BrowserRead` `mode = "html"` 로, Keeper 가 아닌 호출자의 스크린샷은 결과의 이미지 블록으로 host 도구에 옮겨요. export 를 host 전용으로 바꾸는 PR(#46183)에서 같이 해요.
- 그래서 worker export 이름은 공개 이름 규칙(2.4)과 상관이 없어지고, #45360 의 넓은 실패에도 browser 는 걸리지 않아요.

**Skill**
- 출처와 상관없는 규칙은 Keeper 가 늘 보는 host 도구 설명(`keeper_tool_descriptor.ml`, `tool_schemas_misc_toml`)으로 옮겨요. 도구를 가진 쪽이 그 계약을 설명해요.
- 출처에만 있는 문단은 그 패키지 Skill 에 둬요. `browser-automation` 은 `locate`·업로드·다운로드, `browser-stagehand` 는 act/extract 예요. 따로 할 말이 없는 출처는 Skill 이 없어요.
- 그래서 같은 문장이 여러 패키지에 생기지 않고, 출처가 꺼지면 그 문단만 빠져요.

**worker**
- 실행 파일은 지금의 `masc-browser-addon-worker` 하나를 그대로 써요. host 가 manifest 의 출처를 `--backend <wire>` 로 넘겨요.
- worker 는 그 출처 하나와 그 출처의 broker 만 만들어요.
- 감싸서 띄우는 구조(2.1)는 없어져요. owner 의 상태(`Serving | Retired`)는 그대로 둬요. 이제 owner 하나가 출처 하나의 수명과 같아요.
- 출처마다의 "끝나면 owner 를 revoke 하고 예외를 올림"도 그대로 둬요. 이제 그건 그 worker 하나만 끝내요. runtime 은 #45290 대로 그 설치만 정리하고 다음 설정 패스에 새로 띄워요.
- 정리 descriptor 는 출처를 담은 variant 로 바꿔요(지금은 출처마다 optional 필드를 가진 record, `browser_addon_socket.ml:30-56`). worker 하나가 출처 하나라서, 여러 출처가 함께 들어 있는 상태를 타입이 막아요. 옛 descriptor 는 읽지 않아요(7절).

**설정**
- host 는 worker 를 띄울 때 그 출처의 설정만 넘겨요.

  | 출처 | 설정 |
  |---|---|
  | `Automation` | `[browser.automation]` |
  | `Stagehand` | `[browser.stagehand]` |
  | `Owned_firefox` | `[browser.live.bidi]` |
  | `Ego` | `[browser.live.ego]` |
  | `External_host` | 없음 |

- 설정이 필요한 출처의 선언에 설정이 없으면 시작 실패(`Worker_failed`)로 끝나고, 까닭은 "설정 없음"이에요.

**선언과 setup**
- `browser-lane-setup` 은 설정된 출처마다 선언을 하나씩 써요(`browser-automation.toml` 등). `browser-external` 은 native host 를 설치할 때(`--mode host`) 써요.
- 출처마다 enabled 선언이 둘 이상이면 setup 과 preflight 가 거절해요. 지금은 패키지 id `browser` 로 세요(`browser_addon_setup.ml:231-247`, `browser_addon_preflight.ml:40-69`). 이걸 출처로 세게 바꿔요.
- setup 은 runtime.toml 에 옛 선언 id `browser` 를 가리키는 Exact Output lane 표가 남아 있으면, 옮길 표 이름을 알려 줘요(7절). 고치는 건 운영자예요. runtime.toml 은 운영자 파일이에요.
- `browser` 패키지와 `browser.toml` 은 지워요(hard cut, 7절).

**바깥 native host**
- `/browser-lane/poll` 은 지금처럼 `x-lane: live` 만 받아요.
- `Browser_addon_ingress.for_poll` 의 "browser 서비스가 정확히 하나" 조건은 "`External_host` 서비스가 정확히 하나"로 바뀌어요. registration 기록의 모양은 그대로예요.

**운영자 프로필 보호**
- 그대로예요. claim slot 은 프로필 폴더 안의 커널 잠금이라, worker 가 나뉘어도 같은 프로필을 두 프로세스가 쓰지 못해요(2.4).

### 4.2 H: 고르는 일은 host 가 해요

**snapshot**
- host 는 요청할 때 serving 중인 browser worker 에 이미 있는 `Snapshot` 을 나란히 물어요(2.4).
- `Snapshot` 은 읽기예요. 실패해도(`Unavailable`, `Outcome_unknown`) worker 를 failed 로 만들지 않아요.
  - 지금 이 예외는 `only_if_idle` 읽기에만 있어요(`lane_addon_runtime.ml:1881-1909`). 이걸 "아무것도 바꾸지 않는 명령"을 고르는 전체 함수로 바꾸고, `Snapshot` 을 거기에 넣어요. 새 wire 명령이 생기면 컴파일러가 그 함수에서 물어봐요.
  - 답하지 못한 worker 는 이번 선택에서만 없는 출처로 봐요. 그 까닭을 `browserSelection` 에 남겨요.
- 기다리는 시간은 지금의 control 명령 시간 제한(기본 5초, 2.4)이에요. 새 제한을 만들지 않아요. 멈춘 worker 하나가 Automatic 요청을 그만큼 늦출 수 있어요(8절 비용).
- host 는 답을 모아 `Browser_selection.snapshot` 을 만들어요.
  - live 쪽은 출처마다 client 목록이에요. 지금의 `live_activity` 하나(`browser_selection.ml:11`)는 "그 출처가 serving 중이고 답했나"로 바뀌어요.
  - automation·stagehand 의 `registered`·`session`·`locate` 는 각자의 worker 에서 받아요.
  - 지금 `snapshot ()` 이 프로세스 전역 상태를 읽는 부분(`browser_selection.ml:54-63`)은 worker 답을 모으는 함수로 바뀌어요.
  - 캐시된 관측을 쓰지 않아요. 고르는 값과 실행할 worker 의 상태가 같은 시점이어야 해서요.

**고르기**
- `Browser_selection.resolve` 를 host 로 옮겨요. 이유(reason)의 종류는 지금과 같아요.
- 고른 route 를 worker 로 바꾸는 건 전체 함수예요.

  | route | worker | snapshot |
  |---|---|---|
  | `Automation_route` | `Automation` | `requiredActions` 가 있을 때만 그 worker 에 물어요 |
  | `Stagehand_route` | `Stagehand` | `requiredActions` 가 있을 때만 그 worker 에 물어요 |
  | `Live_route (Some clientId)` | snapshot 에서 그 client 를 내놓은 live worker | live worker 들에 물어요. 아무도 없으면 dispatch 전에 거절해요 |
  | `Live_route None` | 세 live worker 의 client 를 합쳐 하나면 그 worker | 하나도 없으면 `No_live_client`, 둘 이상이면 `Ambiguous_clients` 예요. 지금 규칙(`browser_lane.ml:774-781`)과 같아요 |

- Exact route 의 `requiredActions` 확인(`require_target`)도 host 가 그 worker 의 snapshot 으로 해요.
- host 가 `browserSelection` 과 `browserConnection` 을 직접 찍어요. `browserConnection` 은 snapshot 의 `client_info` 로 만들어요. worker 가 붙이고 host 가 검사하던 일(`browser_addon_host.ml:113-119`)은 없어져요.

**실행**
- worker 는 자기에게 정해진 route 만 받아요. 다른 출처의 route, 자기 것이 아닌 client 는 dispatch 전에 거절해요(`Proven_pre_effect`).
- snapshot 이후 상태가 바뀌어 worker 가 거절하면, host 는 그 거절을 그대로 돌려줘요. 다른 출처로 몰래 다시 보내지 않아요. 다시 고를지는 Keeper 가 정해요. 이미 보냈을 수 있는 입력은 다시 보내지 않는다는 지금 규칙과 같아요.

**서비스 신원**
- `Browser_addon_host.connect` 는 (출처 → 서비스와 그 인스턴스의 export) 표를 돌려줘요. export 는 지금처럼 인스턴스 id 와 owner 로 맞춰 봐요(`browser_addon_host.ml:24-27`).
- "정확히 하나" 조건(`browser_addon_host.ml:17-22`)은 출처마다의 조건이 돼요. 한 출처가 없거나 둘이면 그 출처만 쓸 수 없어요. 나머지는 그대로 골라지고 실행돼요.

**관측과 화면**
- 각 worker 는 자기 출처의 관측 한 줄을 내요(`browser/<wire>`). presence 는 출처마다 찾아요(`lane_addon_runtime.ml:1804-1829`).
- lane inventory 의 세 레인 줄은 그 레인의 worker 들에서 읽어요(`server_lane_inventory.ml:131-140`). Live 줄은 세 live worker 를 합쳐요.
- `/api/v1/dashboard/browser-lane/clients` 는 host 가 snapshot 들을 합쳐 지금과 같은 모양으로 답해요. TUI 는 같은 endpoint 를 그대로 읽어요(`bin/masc_tui_http.ml:3926`). 그 안의 `bidiHost`(`browser_addon_view.ml:96`)는 4.4 에서 바뀌어요.
- 문서 소스는 route 로 worker 를 찾아요. 그래서 `Several_browser_services`(`lane_addon_runtime.ml:1929-1935`)는 "그 route 의 worker 가 없음"으로 바뀌어요.

**#44023 과의 관계**
- 요청이 프로필 종류를 요구하는 일(`profile = Operator_signed_in | Any`)은 host 쪽 선택의 입력이에요. #44023 에서 함께 정해요(issuecomment-6357334797). 이 RFC 는 그 입력이 들어갈 자리(host 의 순수 함수)를 만들어요.

### 4.3 G: masc 가 Gecko 브라우저를 끝까지 가져요

native worker 는 자기 프로세스 그룹을 가져요. 멈출 때는 먼저 revoke 하고, 그 그룹을 끝내고 거둬요(`lane_addon_native_worker.mli:1-4`, `40`). geckodriver 와 그 브라우저는 이 그룹에 있어요(1.3, `browser_addon_automation.ml:82`). 그래서 DELETE 가 실패해서 남은 브라우저도 worker 를 멈출 때 같이 끝나요. 남는 건 그룹 밖으로 빠져나간 브라우저뿐이에요. 같은 mli 도 "Descendants leaving the group are outside its release receipt and need their package's explicit resource cleanup." 라고 적어요. G 가 그 정리예요.

빠져나간 브라우저는 인스턴스가 끝난 뒤에 다시 뜰 수 있어요. 지워진 프로필 경로도 새로 만들어요(1.3). 그래서 G 는 그 브라우저를 인스턴스 할당이 아니라 Lane Add-on store 범위에서 봐요.

**G1. 프로필은 masc 가 Lane Add-on store 아래에 만들어요.**
- 프로필 root 는 `<lane-addons>/gecko-profiles/` 이고 0700 이에요(`Browser_gecko_profile.root`). host 가 인스턴스를 띄우기 전에 `<instance_id>/` 를 0700 으로 만들어요. root 가 symlink 이면 따라가지 않고 거절해요. 세션을 열 때마다 worker 가 `<instance_id>/<uuid>` 를 0700 으로 만들어요.
- 그 경로를 `moz:firefoxOptions.args` 의 `-profile` 로 넘기고, `--profile-root` 는 쓰지 않아요. geckodriver 는 넘겨받은 프로필을 지우지 않아요. 필요한 설정은 geckodriver 가 직접 써 넣어요(1.3). masc 는 `user.js` 를 쓰지 않아요.
- Marionette 포트는 정하지 않아요. geckodriver 가 프로필에 `marionette.port = 0` 을 쓰고 브라우저가 고른 포트를 `MarionetteActivePort` 로 읽어요(1.3). 그래서 다시 뜬 브라우저가 다음 세션의 포트에 있을 일이 없어요.
- 세션이 열리면 `moz:profile` 이 masc 가 만든 그 경로인지 확인하고, 아니면 그 세션을 닫고 거절해요. 다른 브라우저에 붙은 세션을 쓰지 않기 위해서예요. live Firefox 는 이미 이렇게 확인해요(`browser_addon_live_bidi.ml:218`, `runs_profile`).
- 세션을 닫으면 worker 가 그 세션의 프로필을 G2~G4 로 지워요. driver 하나가 세션을 여러 번 열기 때문에(2.3), 그대로 두면 worker 가 사는 동안 프로필이 쌓여요.

**G2. 잠금 주인을 커널에 물어요.**

정리할 때 프로필 폴더마다 이렇게 해요. 이름이 정확한 UUID 가 아닌 항목은 Chrome 처럼 거절해요(2.2).
1. `.parentlock` 을 `O_RDWR | O_NOFOLLOW` 로 열고, 없으면 0600 으로 만들어요. 일반 파일이고, 소유자가 masc 실행 사용자이고, 링크 수가 1 이어야 해요. 이 fd 하나를 G2 부터 G4 까지 같은 패스 안에서 들고 있어요.
   - POSIX 레코드 잠금은 그 파일의 fd 를 하나라도 닫으면 그 프로세스의 잠금이 다 풀려요. 코드도 이미 그렇게 적어요(`native_addon_lease.ml:492-493`). 그래서 프로세스 안의 등록부가 파일마다 fd 하나만 열게 하고, 이미 열린 파일을 다시 열려는 호출은 거절해요(`Private_browser_profile.open_lock`).
2. 그 fd 로 잠금 주인을 붙잡아요(G3 의 타입). `F_GETLK` 로 찾고, pid 파일은 읽지 않아요.
3. 결과는 닫힌 합타입이에요.
   - `Unlocked`
   - `Held_by of holder`
   - `Changing`: 물어보는 사이에 주인이 끝나거나 바뀌었어요. 다음 패스에서 다시 물어요.
   - `Unreadable of string`: 경로와 실패한 검사를 남기고, 그 폴더는 다음 패스에 다시 봐요.
4. Chrome 은 바꾸지 않아요. Chrome 은 자기 자식 slot 으로 띄우고 정리해요(2.2). 이 잠금 확인은 Gecko 에만 써요.

**G3. 잠금 주인은 별도 타입으로 멈춰요.**
- `Owner_process_identity` 의 계약은 그대로 둬요. 그 모듈의 대상은 workspace lease 주인, 곧 masc 서버예요. "SIGTERM to the captured process incarnation only; never PID fallback or SIGKILL escalation." (`owner_process_identity.mli:8-10`)
- masc 전용 프로필 잠금 주인은 새 라이브러리 `Private_browser_profile` 의 `holder` 로 다뤄요.
  - 이 값은 G2-1 의 검사를 통과한 잠금 fd 에서만 만들 수 있어요. 검사 결과를 담은 private 타입을 받기 때문이에요.
  - `request_termination` 과 `request_kill` 을 둬요. 둘 다 붙잡은 그 프로세스에만 보내요. 보내기 직전에 주인을 다시 확인하는 일은 지금 stub 이 이미 해요.
  - C 쪽은 별도 stub(`private_browser_profile_stubs.c`)이에요. 붙잡는 방식(`F_GETLK`, macOS audit token, Linux pidfd)은 `owner_process_identity_stubs.c` 를 따르되 그 모듈의 계약은 건드리지 않아요. 붙잡은 값은 잠금 파일 fd 를 복제하지 않아서, 그 값을 놓아도 1 의 잠금이 풀리지 않아요. 놓는 일은 `release` 로 명시해요.
- 그래서 masc 서버에 KILL 을 보내는 코드는 타입 검사를 통과하지 못해요.
- TERM 과 KILL 사이에는 상태가 필요해요. 정리하는 쪽이 TERM 을 보낸 프로필마다 붙잡은 주인과 KILL 을 보내도 되는 시각을 메모리에 들고 있어요. 잠금 파일 fd 는 들지 않아요.
  - `Held_by` 를 처음 보면 TERM 을 보내고 그 주인을 기록해요.
  - 같은 신원이 유예가 지난 뒤에도 잠금을 쥐고 있으면 KILL 을 보내요. 유예 안에 온 패스는 아무것도 보내지 않아요.
  - 보낸 TERM 은 그 프로필이 사라질 때까지 기억해요. 어떤 패스가 그 프로필에 닿지 못해도 유예는 이어져요.
  - 서버가 다시 뜨면 상태가 사라지고 TERM 부터 다시 해요.
- 유예는 70 초예요(`Browser_gecko_sweep.termination_grace_seconds`). Firefox 의 종료 감시가 종료 단계 하나에 주는 시간과 같아요. 한 단계가 `toolkit.asyncshutdown.crash_timeout`(기본 60 초)에 `crash_timeout_additional_wait`(10 초)를 더한 시간 동안 나아가지 않으면 Firefox 가 스스로 crash 해요(`toolkit/components/terminator/nsTerminator.cpp`). 단계마다 다시 세서, 계속 나아가는 종료는 70 초보다 길 수 있어요. 그래서 70 초는 Firefox 가 보장하는 값이 아니라 masc 가 고른 한도예요.
  - 패스 간격을 유예로 쓰지 않아요. 재촉(nudge)으로 패스가 바로 이어질 수 있어서예요.
  - 이건 masc 가 가진 프로세스를 멈추는 안전 한도예요. native worker 가 자기 그룹을 멈출 때 TERM 뒤 유예를 두고 KILL 하는 것(`lane_addon_native_worker` 의 `grace_seconds`)과 같은 종류예요. 행동을 막는 게이트가 아니에요.
- 그 프로세스는 masc 전용 0700 폴더 안의 파일에 쓰기 잠금을 쥔 같은 사용자의 프로세스예요. 그래서 그 프로필로 뜬 Gecko 브라우저라고 봐요. 이건 추론이라서, 주인의 실행 파일 경로를 기록에 남겨 사람이 확인할 수 있게 해요. 주인을 끝내면 그 자식도 끝나요(1.3).

**G4. 지우는 동안에는 masc 가 잠금을 쥐어요.**
- 결과가 `Unlocked` 이면 G2 의 fd 로 쓰기 잠금을 걸어요(`F_SETLK`, non-blocking). 걸리지 않으면 이번 패스에서는 그 폴더를 두고 다음 패스에 다시 봐요. 한 패스 안에서 되풀이하지 않아요.
- 잠금을 쥔 채로 프로필을 지워요. 그동안 같은 프로필로 뜨려는 브라우저는 "already open" 으로 바로 끝나요(1.3).
- 지우는 규칙은 Chrome 의 `remove_profile`(`browser_addon_stagehand.ml:89-104`)을 공용 함수로 옮겨서 써요. 소유 uid 를 확인하고, 링크는 따라가지 않고 지우고, 링크 수 1 인 일반 파일만 지우고, 그 밖의 것이 있으면 남기고 실패해요.
  - 지금은 폴더 목록 순서대로 지워요. Gecko 는 `.parentlock` 을 마지막에 지우도록 순서를 정해요. Chrome 은 지금 순서 그대로예요.
- `.parentlock` 을 지운 뒤 폴더를 지우고, 그다음에 fd 를 닫아요. 그 사이에 다시 뜬 브라우저가 폴더를 새로 만들면 다음 패스가 G2 부터 다시 봐요.

**G5. 누가, 언제 쓰나요**
- 살아 있는 automation worker 는 자기 인스턴스 폴더만 다뤄요. 닫은 세션의 프로필을 지워요(G1).
- server 는 설정 패스마다 끝난 인스턴스의 폴더를 다뤄요. 대상은 store 에 그 인스턴스의 할당이 `released` 로 기록됐거나(`browser_addon_socket.ml:317`), 기록이 아예 없는 `<instance_id>` 폴더예요.
  - 인스턴스 기록은 worker 가 폴더를 만들기 전에 생겨요(admission 이 spawn 보다 먼저예요). 그래서 기록 없는 폴더는 남은 것뿐이에요.
  - 운영자가 retain 한 인스턴스의 폴더는 건드리지 않아요. retain 은 운영자가 그 자리를 그대로 두라는 뜻이에요.
  - 폴더의 프로필이 모두 지워지면 `<instance_id>` 폴더도 지워요.
  - 기록과 함께 이 서버가 지금 돌리거나 복구 중인 인스턴스도 빼요. 읽지 못한 기록은 그 기록이 가리키는 인스턴스를 막고, 어느 인스턴스인지 모르면 그 패스는 쓸지 않아요.
  - 다룰 인스턴스는 설정 잠금 안에서 정해요. 그 시점의 binding 전체(실행 중인 것 포함)와 실행 여부를 같이 읽고, root 를 한 번 읽어요. 지우기와 신호는 잠금을 놓은 뒤 systhread 에서 해요. 그래서 Attach·Detach·retain 이 프로필 지우기를 기다리지 않아요.
  - 인스턴스 id 는 다시 쓰이지 않아서, 정한 뒤 대상이 다시 살아날 일이 없어요. 그 뒤에 생긴 폴더는 그 패스에 없어요.
  - 남긴 항목은 설정 상태의 issue 로 보여요. 매 패스 경고 로그를 찍지 않아요.
- 두 쪽이 다루는 폴더는 인스턴스가 살아 있는지로 갈라서 겹치지 않아요. worker 가 지우다 멈추면(그룹이 끝나면) 남은 것은 server 가 이어서 지워요. 지우는 함수는 반쯤 지워진 폴더에서 다시 시작해도 돼요.
- 인스턴스 할당 정리(`Browser_addon_socket.cleanup`)는 더 이상 Gecko 프로필을 보지 않아요. 그래서 빠져나간 브라우저가 있어도 할당은 확인되고 새 인스턴스가 떠요. 빠져나간 브라우저는 server 가 따로 끝내요.

**G6. 세션 권한을 잃은 worker 는 끝나요.**
- 세션을 잃었는지는 WebDriver 클라이언트가 정해요(`Browser_webdriver.create ~lost`). 클라이언트가 스스로 세션 상태를 모른다고 기록하는 자리예요.
  - 세션 생성이 예외(명령 시간 초과 포함)·전송·프로토콜 오류로 끝났거나, 답에 sessionId 가 없을 때
  - 지금 세션에 대해 `invalid session id` 답을 받았을 때
  - WebDriver 오류로 거절된 생성(`session not created` 등)은 브라우저를 띄우지 않았다는 뜻이라 잃은 게 아니에요.
- serving 중에 세션을 잃거나 드라이버 프로세스가 끝나면, automation worker 는 owner 를 revoke 하고 예외로 끝나요. live Firefox 가 연결을 잃었을 때와 같아요(`browser_addon_live_bidi.ml:290`).
- admission 이 이미 retire 된 뒤(Retire, SIGTERM)의 손실은 worker 를 끝내는 이유가 아니에요. 정리를 "확인되지 않음" 으로 남기고 멈춤을 이어 가요. 다른 백엔드의 정리를 중간에 끊지 않으려는 거예요.
- 그러면 runtime 이 그 그룹을 끝내고, #45290 대로 다음 설정 패스에 새로 띄워요. 빠져나간 브라우저는 G5 가 끝내요.
- 지금처럼 모든 명령을 거절한 채 떠 있는 상태(1.1 의 20:57~21:48)는 없어져요.

**G7. 함께 바꾸는 것**
- `automation-closed.json` 영수증과 그걸 쓰고 읽는 코드를 지워요. 호환 읽기는 만들지 않아요(hard cut).
- 할당 안의 `uploads/`·`download-snapshots/`·`downloads/` 는 지금처럼 빈 폴더여야 해요(`browser_addon_socket.ml:158-159`, `205`). `profiles/` 는 할당에서 빠져요.

### 4.4 D: 켜고 끄는 스위치는 선언 하나예요

- 출처를 켜고 끄는 사실은 그 선언의 `enabled` 하나예요(불변식 7). 꺼진 선언의 worker 는 없어요.
- runtime.toml 의 `[browser.automation] enabled`·`[browser.stagehand] enabled`·`[browser.live] enabled` 를 지워요.
  - `Browser_configuration` 의 `*_enabled` 필드와 그 parser 를 지워요. 허용 키 목록에서도 빠지므로, 남아 있는 `enabled` 는 "is not a supported setting" 으로 거절돼요(`browser_configuration.ml:27-32`).
  - `enabled` 만 남은 표를 "설정 안 함"으로 읽던 규칙(`:77-79`)도 지워요. 빈 표는 지금처럼 "필수 키 없음"으로 거절돼요. 운영자는 그 표를 지워요(7절).
- `*_enabled` 를 읽던 곳(2.4)은 이렇게 바뀌어요.

  | 지금 읽는 곳 | 바뀐 뒤 |
  |---|---|
  | host 가 띄울 출처를 고름(`lane_addon_runtime.ml:1508`, `1512`, `1520`, `1532`) | 지워요. 띄울지는 선언이 정했어요 |
  | server 쪽 activity(`server_browser_configuration.ml:1-16`) | 지워요. 출처가 있는지는 host 가 serving 중인 worker 로 알아요(4.2) |
  | worker 안의 activity(`browser_addon_owner.ml:33`) | 자기 출처만 보면 돼서 단순해져요 |
  | BiDi host 상태(`browser_bidi_host_status.ml:12-17`) | `Lane_off` 를 지워요. `[browser.live.bidi]` 가 있을 때만 선언을 읽어서, `browser-firefox` 를 돌리는 켜진 선언이 있으면 `Addon_managed`, 없으면 `Addon_off`, 선언을 다 읽지 못하면 `Not_known` 이에요. 표가 없으면 선언은 읽지 않고 `Not_configured` 예요 |
  | setup 계획·안내 문구(2.4) | 선언의 `enabled` 를 읽고 써요 |
  | lane inventory(`server_lane_inventory.ml:160`) | 그 레인 worker 들의 선언으로 정해요 |
  | TUI 의 레인 켜기·끄기(`masc_tui_browser_activity.ml`) | 지워요. 출처마다 켜고 끄는 일은 `browser-<출처>` 패키지 줄의 선언 편집기가 이미 해요(`POST /api/v1/lane-addons/declaration`) |

- 꺼서 생기는 일도 출처 하나예요. `browser-firefox` 선언을 끄면 그 worker 만 멈춰요. ego·Chrome·Gecko·바깥 native host 는 그대로예요.
- automation 전용 브라우저 설치본은 설치 문서에서 권장만 해요. `[browser.automation] binary` 를 운영자가 평소 쓰지 않는 설치본으로 두고, 그 설치본에만 `DisableAppUpdate` 를 걸면 1.1 의 탈출 자체가 생기지 않아요. setup 이 묻거나 정책 파일을 쓰지는 않아요. G 가 탈출을 정리 박자 안에 풀기 때문이에요.

## 5. 장애별로 달라지는 것

| 장애 | 지금 | 바뀐 뒤 |
|---|---|---|
| live Firefox 연결이 끊김 | worker 가 죽고 모든 출처가 꺼짐 | `browser-firefox` 만 끝나요. 다음 설정 패스가 새로 띄워요. 나머지 세션은 이어져요 |
| ego 연결이 끝나거나, 운영자가 작업 공간을 쥐고 있어 시작하지 못함 | worker 가 죽거나 시작하지 못해 모든 출처가 꺼짐 | `browser-ego` 만 끝나거나 실패해요. 박자마다 다시 시도해요 |
| Gecko 브라우저가 업데이트 재실행으로 빠져나감 | automation 이 모든 명령을 거절한 채 떠 있고, 다음 배포 뒤에는 영수증이 없어 모두 막힘 | automation worker 가 바로 끝나요(G6). 할당은 확인되고 다음 패스에 새 automation 이 떠요. 빠져나간 브라우저는 server 가 TERM 을 보내고, 70 초 뒤에도 남으면 KILL 해요(G5). 나머지 출처는 상관없어요 |
| 정리한 뒤에 빠져나간 브라우저가 다시 떠서 프로필을 새로 만듦 | 해당 없음(정리가 끝나지 않음) | 그 폴더는 끝난 인스턴스의 것이라 다음 패스에 server 가 잡아요(G5) |
| Gecko 세션 DELETE 가 실패함 | 영수증을 쓰지 않아 정리가 영영 막힘(2.3) | automation worker 를 멈출 때 그룹이 끝나요. 프로필은 G5 가 지워요 |
| 출처 코드의 잡히지 않은 예외·C stub 충돌 | 모두 꺼짐 | 그 출처의 worker 하나만 꺼져요 |
| 한 출처의 시작 실패(예: Chrome 실행 파일 없음) | 감싼 구조라 안쪽 출처가 시작하지 못함 | 그 선언만 실패하고, 박자마다 다시 시도해요 |
| worker 하나가 `Snapshot` 에 늦게 답함 | 그 worker 가 failed 가 되어 교체되고 세션을 잃음(2.4) | 그 요청에서만 그 출처를 빼고 골라요. worker 는 그대로예요 |
| 운영자가 live Firefox 만 끄려 함 | `[browser.live] enabled` 가 live Firefox·ego 를 같이 정함(2.4) | `browser-firefox` 선언만 끄면 돼요 |

## 6. 단계

세 스택으로 나눠요. G 는 지금 구조에서도 같은 코드라 먼저 해도 버려지지 않아요(스택 1 = native stack #45404). 그래서 효과가 큰 G 를 먼저 내요. D 는 S 위에 쌓고 S 와 함께 배포해요(7절).

**스택 1: Gecko 소유 (G)**

| 층 | 내용 | 검증 |
|---|---|---|
| 층 | PR | 내용 | 검증 |
|---|---|---|---|
| G-L1 | #45391 | `Private_browser_profile`(등록부로 파일마다 fd 하나, 붙잡기, TERM, KILL, 명시적 놓기)와 공용 프로필 삭제 함수(`.parentlock` 마지막) | 실제 자식 프로세스가 `fcntl` 쓰기 잠금을 쥔 픽스처로 `Held_by`·`Unlocked`·`Changing` 확인. TERM 을 무시하는 픽스처가 KILL 로 끝나는지. 붙잡은 값을 놓아도 masc 쪽 잠금이 그대로인지. 링크·링크 수 2 파일 거절 |
| G-L2 | #45403 | Lane Add-on store 프로필 root, `-profile`, `--profile-root` 제거, Marionette 포트를 정하지 않음, `moz:profile` 확인, 끝난 세션의 프로필 놓기 (G1) | 세션이 masc 가 만든 프로필로 열리는지. 다른 프로필의 브라우저가 붙으면 세션을 거절하는지. 세션이 어떻게 끝나든 프로필을 정확히 한 번 놓는지 |
| G-L3 | #45411 | server 의 패스별 정리(G2~G5), 할당 정리에서 프로필 빼기, 영수증 삭제 (G7) | 끝난 인스턴스 폴더의 `.parentlock` 을 쥔 그룹 밖 자식이 TERM 뒤(또는 유예 뒤 KILL 뒤) 끝나고 폴더가 지워지는지. 기록이 retained·실패인 인스턴스의 폴더는 그대로인지. 계획 뒤에 생긴 폴더는 건드리지 않는지 |
| G-L4 | #45433 | 세션을 잃거나 드라이버가 끝나면 automation worker 가 끝남 (G6) | 생성 결과마다 손실을 세는지. sessionId 없는 답, 시간 초과가 끊은 생성, 준비 뒤 드라이버 종료로 worker 가 끝나는지. 생성 중 Retire 에는 예외 없이 멈추는지. 남긴 프로필을 host 패스가 지우는지 |

**스택 2: 출처마다 worker 하나 (S, H)**

| 층 | 내용 | 검증 |
|---|---|---|
| S-L1 | `Snapshot` 을 수명에 영향 없는 읽기로, host 쪽 선택(snapshot 모으기, `resolve`, route → worker 전체 함수, `browserSelection`·`browserConnection`), worker 는 자기 route 만 실행. 이 층에서는 worker 가 아직 하나예요 | `Snapshot` 이 시간을 넘겨도 worker 가 failed 가 되지 않는지. 지금의 선택 테스트를 host 로 옮겨 같은 결과가 나오는지. `Live_route None` 의 `Ambiguous_clients`. worker 가 다른 route·남의 client 를 거절하는지 |
| S-L2 | `Browser_backend.t`, 서비스 신원을 출처로, `connect`·ingress·presence·inventory·화면·문서 소스를 출처별로 | 다섯 출처의 가짜 browser 서비스로 각 경로가 맞는 worker 로 가는지. 한 출처가 없거나 둘이어도 나머지가 골라지는지 |
| S-L3 | 다섯 패키지, `browser_backend`, browser export 를 host 전용으로, host 도구의 verb 빈칸 채우기, worker `--backend`, 출처별 broker·설정, 정리 descriptor variant, setup·preflight 출처별, Skill 나누기, `browser` 패키지 삭제 | 각 worker 가 자기 출처만 띄우는지. 다섯 패키지를 함께 띄워도 `tools/list` 에 browser export 가 없고 실패하지 않는지. live Firefox 를 끊어도 다른 출처 명령이 계속 되는지. 한 출처의 시작 실패가 다른 출처를 막지 않는지. 바깥 BiDi host 와 확장 프로그램이 둘 다 `browser-external` 로 붙는지 |
| S-L4 | 설계 문서(`browser-addon-lifecycle.md`)와 설치 문서 | Keeper 가 받는 도구 설명과 Skill 목록을 실제 `tools/list` 로 확인 |

스택 2 는 native stack 이라 맨 위 PR 로 한 번에 들어가요. 중간 층은 테스트만 통과하면 되고, 배포할 수 있는 건 맨 위 층이에요. S-L3 부터는 꺼짐 스위치가 runtime.toml 과 선언 두 곳에 있어서, 꺼진 lane 의 선언된 출처가 설정 패스마다 시작 실패와 재시도를 되풀이해요. 그래서 D-L1 을 스택 2 맨 위에 쌓아 함께 머지해요.

**스택 3: 스위치 하나 (D)** — 스택 2 맨 위에 쌓아 함께 머지하고 배포해요(7절 배포 2)

| 층 | 내용 | 검증 |
|---|---|---|
| D-L1 | `*_enabled` 와 그 parser·읽는 곳 삭제(4.4 표), TUI·웹의 browser lane 편집기 삭제(켜기·끄기는 `browser-<출처>` 패키지 줄) | `enabled` 가 남은 runtime.toml 이 거절되는지. 선언을 끄면 Lanes 의 browser 줄과 BiDi host 상태가 그 선언만으로 바뀌는지 |

**바뀌는 기존 테스트**
- `test/test_browser_addon_live_bidi.ml` 의 "unexpected peer loss fences the worker": 그 worker 만 끝나는 걸로 바뀌어요(S-L3).
- `test/test_browser_addon_owner_cleanup.ml` 의 "all backends settle despite failure and caller cancellation": worker 하나에 출처 하나가 돼요(S-L3).
- `test/test_browser_addon_socket.ml` 의 "owned backend requires receipt and empty resource trees"(G-L3)
- `test/test_browser_addon_automation.ml` 의 영수증 관련 테스트(G-L3)
- `test/test_lane_addon_native_runtime.ml` 225-262행의 retain 시나리오(G-L3): 할당의 `profiles/` 에 남은 파일 때문에 정리가 거절되던 시나리오예요. `profiles/` 가 할당에서 빠지므로, 할당에 남은 모르는 항목을 쓰는 시나리오로 바꿔요.
- 서비스나 선언이 하나라는 가정(S-L2, S-L3)
  - `test/test_lane_addon_native_runtime.ml:716` ("with two browser Add-ons the source is unavailable")
  - `test/test_lane_addon.ml:379` (`Several_browser_services`)
  - `test/test_browser_addon_owner.ml:159-160`, `test/test_browser_addon_preflight.ml:106-122`, `test/test_browser_addon_setup.ml:155-168`, `test/test_browser_lane_routes.ml:187`
- `enabled` 를 읽는 테스트(D-L1): `test/test_onboarding_status.ml:556-558` 등

## 7. 옮겨 가기 (hard cut)

두 번 배포해요. 순서가 바뀌면 안 돼요. hard cut 이라 스위치가 둘인 중간 판을 두지 않아요.

**배포 1: 스택 1 (G)**
- 새 판은 옛 automation 정리 기록(`driver`·`binary` 만 있는 것)을 읽지 않아요. 배포 전 검사가 그 기록을 가진 native claim 슬롯을 거절해요(`lane_addon_store_preflight.ml`, decoder `Browser_addon_socket.check_retained`).
- 서버를 멈춰요. 거절마다 그 기록이 가리키는 `mb-…` 할당의 `profiles/` 를 아직 쥔 프로세스가 있으면 먼저 끝내요(`lsof +D <할당>/profiles`). 옛 판은 다시 뜬 Gecko 브라우저를 그곳에 남길 수 있어요(#45187). 그런 다음 배포 전 검사가 알려 주는 경로(슬롯, 그 인스턴스의 binding 과 observations)와 그 할당을 옮겨 두고 새 판을 띄워요. 옛 할당에 남은 `automation-closed.json` 과 `profiles/` 도 이때 함께 치워져요.
- changelog 에 `Fresh state required` 로 적어요(#45403).

**배포 2: 스택 2·3 (S, H, D)**
1. 옛 서버가 떠 있는 동안 옛 `browser` 인스턴스를 Detach 하고, `released` 가 기록됐는지 봐요. 새 판은 옛 정리 descriptor 를 읽지 않아요(4.1). 옛 인스턴스가 남아 있으면 `install-local-build.sh` 의 `validate-stores` 가 설치를 멈춰요(`scripts/install-local-build.sh:293-295`, `lane_addon_store_preflight.ml:247`).
   - released 가 되지 않으면, 서버를 멈추고 `browser` binding 과 그 native-claims slot, 그 `mb-…` 할당을 지워요.
2. 운영자가 지금의 `[browser.*] enabled` 값을 적어 두고, runtime.toml 에서 그 줄을 지워요. 그러고 나서 빈 표가 남으면(예: `enabled` 만 있던 `[browser.stagehand]`) 그 표도 지워요. 남아 있으면 새 판이 runtime.toml 을 읽지 못해요(4.4). `install-local-build.sh` 는 설치 전에 새 판으로 runtime.toml 을 확인해서 이걸 먼저 알려 줘요(`:280-284`).
3. 운영자가 runtime.toml 의 Exact Output lane 표를 새 선언 id 로 옮겨요.
   - `[runtime.addon_exact_lanes.browser.locate]` → `[runtime.addon_exact_lanes.browser-automation.locate]`
   - `[runtime.addon_exact_lanes.browser.stagehand]` → `[runtime.addon_exact_lanes.browser-stagehand.stagehand]`
   - 옮기지 않으면 `locate` 와 act/extract 가 `Lane_unconfigured` 가 돼요(2.4).
4. 설치해요. `install-local-build.sh` 는 `--no-browser-addon` 을 주지 않으면 browser Add-on 을 설치해요.
5. `browser-lane-setup` 이 출처별 선언을 써요. 각 선언의 `enabled` 는 운영자가 2 에서 적어 둔 값으로 정해요. `browser-external` 은 늘 켜진 선언이에요. 바깥 native host 는 지금도 `[browser.live] enabled` 의 영향을 받지 않아서예요(2.4).
- 호환 읽기나 옛 선언 변환은 만들지 않아요. changelog 에 `Fresh state required` 로 적어요.
- 되돌리면 옛 판은 `enabled` 줄이 없는 표를 켜진 것으로 읽어요(`browser_configuration.ml:41-43`). 되돌릴 때는 2 에서 적어 둔 값을 다시 써 넣어요.

## 8. 대안과 트레이드오프

| 대안 | 장점 | 단점 |
|---|---|---|
| worker 하나 안에서 출처별 상태와 정리를 나눔 (이 RFC 의 첫 판, #45319) | 프로세스가 하나라 가벼워요 | 프로세스가 통째로 죽는 장애(잡히지 않은 예외, C stub 충돌, 메모리 부족)는 여전히 모두를 끝내요. 설치 단위 정리·교체 장치를 worker 안에 하나 더 만들어 같은 일을 하는 장치가 둘이 돼요 |
| 레인마다 worker 하나 (live·automation·stagehand 셋) | 프로세스가 셋이고, 레인과 패키지가 1:1 이에요 | live 안의 Firefox·ego·바깥 native host 가 한 프로세스에 남아요. ego 의 시작 실패나 Firefox 의 끊김이 다른 live 연결을 같이 끝내요(2.1). 1.2 와 같은 장애예요 |
| 출처를 연결 방식으로 나눔(`Live of live_transport`) | 이미 있는 타입을 그대로 써요 | `Webdriver_bidi` 는 masc 가 띄운 Firefox 와 바깥 BiDi host 가 함께 써요(2.4). 한 worker 가 두 출처를 맡게 돼요 |
| 출처마다 export 이름을 다르게 해서 공개 이름 규칙을 지킴 | 공개 읽기 함수를 고치지 않아요 | export 가 여전히 Keeper 도구가 돼요. Keeper 에게 도구 다섯 개가 생기고, 각자 Automatic 을 받지 못해요 |
| 고르는 일을 맡는 별도 worker(router)를 둠 | host 를 덜 고쳐요 | 거쳐 가는 곳과 장애 지점이 하나 더 생겨요. host 는 이미 요청을 받는 곳이라 router 를 따로 둘 이유가 없어요 |
| 선택에 worker 가 낸 관측(캐시)을 씀 | 요청마다 기다리지 않아요 | 고른 값과 실행할 worker 의 상태가 다른 시점이에요. 끊긴 client 를 다시 고르는 일이 관측이 바뀔 때까지 되풀이돼요 |
| Gecko 프로필을 인스턴스 할당 안에 둠 (이 판의 앞선 초안) | 지금 구조와 같아요 | 할당을 놓은 뒤 다시 뜬 브라우저가 경로를 새로 만들면 아무도 보지 않아요(1.3). 그 브라우저가 쥔 프로필 때문에 할당이 확인되지 않으면 같은 선언이 다시 막혀요 |
| Gecko 브라우저를 masc 가 직접 띄우고 geckodriver 는 `--connect-existing` 으로 붙음 | 브라우저 pid 를 masc 가 알아요 | 업데이트 재실행처럼 브라우저가 스스로 다시 뜨면 결국 놓쳐요. 잠금 확인은 그래도 필요해요 |
| 시작 전에 브라우저의 업데이트 대기 상태를 읽고 거절 | 탈출을 미리 막아요 | Mozilla 내부 파일 형식(`active-update.xml`)에 기대요. 형식이 바뀌면 조용히 틀려요 |
| masc 가 정책 파일을 써서 업데이트를 끔 | 탈출이 사라져요 | 운영자 브라우저 전체 설정을 바꿔요 |

치르는 비용
- 상주 프로세스가 하나에서 최대 다섯으로 늘어요. 설정한 출처만 떠요. `browser-ego`·`browser-external` 은 브라우저를 띄우지 않아요. 다섯 worker 의 메모리는 배포 2 뒤 재서 증거로 남겨요.
- Automatic 요청과 live client 를 지정한 요청마다 로컬 `Snapshot` 왕복이 최대 다섯 늘어요. 멈춘 worker 가 있으면 그 요청은 control 시간 제한(기본 5초)만큼 늦어져요.
- server 가 설정 패스마다 Gecko 프로필 root 를 읽어요.
- 운영자가 runtime.toml 을 한 번 고치고, hard cut 이 두 번 있어요(7절).

남는 한계
- 잠금 주인이 Gecko 브라우저라는 판단은 추론이에요(G3). 실행 파일 경로를 기록해서 사람이 확인할 수 있게 해요.
- 빠져나간 브라우저는 SIGTERM 을 무시하면 길면 패스 간격 두 번과 유예 70 초(기본 약 3분) 동안 살아 있어요. 그동안 CPU·메모리를 써요. 다른 출처와 새 automation 인스턴스는 막히지 않아요.
- 브라우저가 Marionette 포트를 고르는 동작은 geckodriver 0.37.1 에서 확인했어요(1.3). 문서가 말하는 버그가 남은 판을 쓰면 세션이 열리지 않을 수 있어요.

## 9. 검증 방법

배포한 뒤 5절의 장애를 실제로 일으키고, 서버 로그와 `GET /api/v1/lane-addons` 응답을 증거로 남겨요.

| 장애 | 배포 | 성공 기준 |
|---|---|---|
| Gecko 탈출 | 1 | 운영자 Zen 에 업데이트를 받아 둔 채로 automation 세션을 열어요. automation worker 가 바로 끝나고, 다음 패스에 새 인스턴스가 운영자 retain 없이 떠요. 빠져나간 프로세스는 SIGTERM 에 끝나거나 70 초 유예 뒤 KILL 로 끝나고, 그 폴더가 지워져요 |
| live Firefox 끊김 | 2 | live Firefox 를 직접 꺼요. 다른 출처 명령이 계속 되고, 다음 설정 패스에 `browser-firefox` 가 새로 떠요 |
| ego 시작 실패 | 2 | 운영자가 ego 작업 공간을 쥔 채로 둬요. `browser-ego` 만 실패로 남고, 나머지는 serving 이에요 |
| 출처 하나가 죽음 | 2 | `browser-stagehand` worker 를 밖에서 죽여요. 다른 worker 는 그대로이고, stagehand 만 다시 떠요 |
| 늦은 snapshot | 2 | `browser-stagehand` worker 를 SIGSTOP 으로 멈추고 Automatic 요청을 보내요. 요청은 stagehand 를 빼고 골라지고, worker 는 failed 가 되지 않아요. SIGCONT 뒤 그대로 써요 |
| 출처 끄기 | 2 | TUI 에서 live Firefox 를 꺼요. `browser-firefox` 선언만 `enabled = false` 가 되고 그 worker 만 멈춰요 |

## 10. 정하지 않은 것

1. 요청 시점 snapshot 비용은 재지 않았어요. S-L1 에서 재고, 그 값이 문제가 될 때만 다른 방법을 찾아요.
2. TUI 에서 출처 다섯을 어떻게 보여 줄지는 D-L1 에서 운영자와 정해요. 레인 단위 묶음 버튼을 둘지도 그때 정해요.

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
- 다시 쓰는 동안 ego lite 스택(#45234~#45256)이 main 에 들어와 live 레인에 출처가 셋이 됐어요. 그래서 나누는 단위를 레인에서 출처로 바꿨어요.
- 같은 이름의 export 가 Keeper `tools/list` 전체를 막는 걸 찾아 #45360 으로 남겼어요.

**첫 판의 적대적 리뷰 (2026-10-23)**
- **P1:** 잠금이 풀린 프로필을 `empty_tree` 로 지울 수 없었어요. → G4 에서 공용 삭제 함수를 써요.
- **P1:** live 재시작에 그걸 일으킬 장치가 없었어요. → live 연결도 worker 하나라서 supervisor 가 다시 띄워요(S).
- **P2 다섯:** Gecko 확인이 worker 전체의 `Settled` 에 기대는 점, 모든 backend 가 owner 를 revoke 하는 점, DELETE 실패로 남는 브라우저, `Owner_process_identity` 의 조건, 할당 하나에 기록 하나인 점 → S·G 로 사라지거나 G2·G3 에 반영했어요.
- **P2:** 지워진 프로필의 잠금을 볼 수 없는 틈 → masc 가 프로필을 만들고(G1), 잠금을 쥔 채 지워요(G4).

**이 판의 적대적 리뷰 (2026-10-23, 맥락 없이 따로 맡김)**

| 지적 | 반영한 곳 |
|---|---|
| P1: `uncertain` 인 automation worker 를 아무도 끝내지 않아 G 가 시작되지 않음 | G6, G-L4 |
| P1: 요청마다 묻는 `Snapshot` 이 늦으면 worker 가 failed 가 되어 교체됨 | 4.2 snapshot, S-L1, 5절, 9절 |
| P1: 바깥 BiDi host 가 여섯째 출처라 `Live of live_transport` 로 가를 수 없음 | 불변식 1, 4.1, 8절 |
| P1: 선언 id 가 바뀌면 Exact Output lane 표가 조용히 안 맞음 | 2.4, 4.1 setup, 7절 배포 2 |
| P1: 할당을 놓은 뒤 다시 뜬 브라우저를 아무도 보지 않음 | 1.3(직접 확인), 불변식 5, G1, G5 |
| P2: 출처별 export 가 Keeper·MCP 도구가 되어 host 선택을 건너뜀 | 2.4, 4.1 "browser export 는 host 만", 8절 |
| P2: `Live_route None`, Exact route 의 `requiredActions`, `browserConnection` 이 worker 안에 남음 | 2.4, 4.2 고르기 |
| P2: `*_enabled` 를 읽는 곳 목록이 모자라고, live 끄기가 바깥 host 를 막는 것처럼 적음 | 2.4 켜고 끄기, 4.4 표 |
| P2: 배포 순서가 나중에 필요한 값을 먼저 지움 | 6절 스택 3, 7절 |
| P2: 잠금 fd 를 어떻게 들지 정하지 않음(닫으면 풀리는 POSIX 규칙) | G2-1, G3 |
| P2: TERM 과 KILL 사이의 상태와 유예를 적지 않음 | G3 |
| P2: 세션 프로필이 쌓이고, Marionette 포트로 다른 브라우저에 붙을 수 있음 | G1 |
| P2: 정리 descriptor 를 바꾸면 옛 인스턴스를 정리할 수 없음 | 4.1 worker, 7절 배포 2 |
| P3: 인용 줄 번호 몇 개, `export_name` 의 의존 방향 | 2.1~2.4. `export_name` 은 쓰지 않아요 |
