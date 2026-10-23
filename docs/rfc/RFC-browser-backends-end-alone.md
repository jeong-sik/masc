---
rfc: "browser-backends-end-alone"
title: "browser Add-on 의 backend 는 각자 끝나고, 각자 정리를 확인한다"
status: Draft
created: 2026-10-23
updated: 2026-10-23
author: claude
supersedes: []
superseded_by: null
related: ["browser-keeper-firefox", "browser-live-one-connection", "browser-lane-stagehand"]
---

# RFC: 각자 끝나는 browser backend (browser-backends-end-alone)

## 0. 요약

browser Add-on worker 하나가 backend 셋을 돌려요. Gecko automation, Chrome(Stagehand), live Firefox(BiDi)예요.
지금은 셋이 한 몸이에요. 하나가 끝나면 worker 가 통째로 끝나요. 하나의 정리가 확인되지 않으면 셋 모두 새로 뜨지 못해요.

2026-10-22~23 에 이 구조 때문에 브라우저 도구가 두 번 오래 멈췄어요(1절).
1. Gecko 쪽 브라우저가 worker 밖으로 빠져나갔어요. 정리를 영영 확인할 수 없어서 3시간 막혔어요.
2. live Firefox 연결 하나가 끊기자 worker 전체가 죽었어요. 다시 띄우지 않아서 9시간 막혔어요.

이 RFC 는 네 가지를 바꿔요.

- **A. Gecko 를 Chrome·live 처럼 소유해요.**
  - geckodriver 를 자기 프로세스 그룹과 자식 claim 으로 띄워요.
  - 정리 확인은 두 사실로 해요. 그 그룹이 비었는지, masc 전용 Gecko 프로필의 `.parentlock` 을 쥔 프로세스가 없는지예요. 잠금 주인은 커널에 물어요(`F_GETLK`, 이미 있는 `Owner_process_identity`).
  - 빠져나간 브라우저도 같은 프로필 잠금을 쥐어서 찾을 수 있어요.
  - 확인할 수 없는 영수증(`automation-closed.json`)은 지워요.
- **B. backend 마다 따로 끝나요.** 시작·실패·종료가 backend 별이에요. live 연결이 끊겨도 Chrome·Gecko 는 계속 일해요.
- **C. 정리 확인과 보류가 backend 별이에요.** 한 backend 의 정리가 확인되지 않아도, 같은 선언은 새 인스턴스를 띄워요. 그 backend 의 남은 자원은 따로 보류하고 다시 확인해요.
- **D. automation 전용 브라우저 설치본을 권장 설정으로 안내해요.** masc 가 운영자 브라우저의 정책 파일을 쓰지는 않아요.

1번 장애는 A·C 가, 2번 장애는 B 가 막아요. 2번 장애가 9시간이나 간 이유(죽은 worker 를 다시 띄우지 않음)는 #45290 에서 따로 고쳐요.

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

2026-10-23 11:16 에 masc 와 같은 인자(`--websocket-port 0`, `--profile-root`)로 다시 띄워 봤어요. 업데이트 상태가 이미 `failed` 였고, 이번에는 Zen 이 geckodriver 의 자식으로 같은 그룹에 정상으로 떴어요.
20:57 의 프로필 폴더(61MB)는 탈출한 뒤에도 지워지지 않고 남아 있었어요.

### 1.2 live 연결 하나가 worker 전체를 끝냄 (#45288)

| 시각 (KST) | 일 | 근거 |
|---|---|---|
| 10-23 01:13 | live Firefox 로그의 마지막 줄은 `Killing GPU process due to IPC reply timeout` 이에요. 서버도 01:02~01:17 에 15분 동안 멈춰 있었어요. | `live-firefox.log`, `masc-start-1023-0032.log` |
| 01:17 | worker 가 `Fatal error: exception Sys_error("owned Firefox backend ended: client_disconnected")` 로 죽었어요. Gecko 정리는 확인됐어요(`automation-closed.json` 있음). | `masc-start-1023-0032.log` 4492-4521행 |
| 01:17~10:13 | 인스턴스가 메모리에 `running + failed` 로 남았고, 아무도 다시 띄우지 않았어요. | #45288, #45290 |

Chrome 과 Gecko 에는 문제가 없었어요. live 연결 하나 때문에 셋이 모두 꺼졌어요.

## 2. 지금 구조

인용한 줄은 이 RFC 를 올린 main(`6dfd417f5f4`) 기준이에요.

### 2.1 셋이 한 몸으로 돌아요

- worker 는 backend 를 감싸서 띄워요: `automation (chrome (live (serve)))` (`bin/masc_browser_addon_worker.ml:71-76`). 바깥 backend 가 준비돼야 안쪽이 시작해요. 바깥 backend 의 시작이 실패하면(`invalid_arg`) 안쪽은 시작조차 하지 않아요.
- owner 의 상태는 하나예요: `type phase = Serving | Retired` (`lib/browser_addon_owner.ml:4`). wire 에는 worker 전체를 끝내는 `Retire` 만 있어요.
- 세 backend 모두 자기가 끝날 때 owner 전체를 revoke 해요. Gecko 는 `lib/browser_addon_automation.ml:105`, `172`, Chrome 은 `lib/browser_addon_stagehand.ml:387`, live 는 `lib/browser_addon_live_bidi.ml:305`, `311`, `317` 이에요.
- live 는 연결이 끊기면 `Sys_error ("owned Firefox backend ended: " ^ detail)` 를 올려요(`browser_addon_live_bidi.ml:321`). 이 예외는 Chrome·Gecko 의 scope 를 차례로 풀고, 잡는 곳 없이 프로세스를 끝내요.
- 설계 문서도 그렇게 정해요: "An unexpected connection failure revokes that worker rather than publishing a dead client." (`docs/design/browser-addon-lifecycle.md` 21-22행). 이 RFC 는 이 결정을 바꿔요(4.2절).

### 2.2 정리 확인은 할당 하나에 하나예요

- `Browser_addon_socket.cleanup` 은 할당 하나(`/tmp/mb-<id>`)를 `let*` 한 줄로 확인해요. 기록도 하나, settlement 도 하나예요.
- 먼저 installation admission 이 `Settled` 여야 해요. worker 프로세스가 끝났고 그 프로세스 그룹이 비었다는 뜻이에요.
- 그다음 Chrome·live 의 자식 slot 을 settle 하고, Gecko 의 영수증을 읽어요. 하나라도 실패하면 할당 전체가 확인되지 않아요.
- 같은 선언의 새 인스턴스는 이전 인스턴스가 정리돼야 떠요(`lib/lane_addon/lane_addon_runtime.ml` 의 `native_settled`).
- 다운로드는 backend 중 하나라도 정리에 실패하면 버려져요. 그런데 다운로드를 만드는 것은 Gecko 뿐이에요.

### 2.3 Gecko 는 브라우저를 직접 갖지 않아요

- Chrome·live 브라우저는 자식 claim slot, guardian(`masc-browser-process-owner`), 따로 쓰는 프로세스 그룹(`foreground_mgr`, `browser_addon_stagehand.ml:208`, `browser_addon_live_bidi.ml:205`), host 쪽 settle 을 갖고 있어요.
- Gecko 는 그런 게 없어요. geckodriver 는 그룹을 만들지 않는 `mgr` 로 떠서 worker 그룹 안에 있어요(`browser_addon_automation.ml:82`). 그 자식인 브라우저도 같은 그룹이에요(1.1 의 재현).
- 그래서 정리 확인을 worker 가 쓰는 영수증에 맡겨요. worker 는 세션 생성이 확실하지 않으면(`uncertain`) 영수증을 쓰지 않아요. `uncertain` 은 한 번 켜지면 꺼지지 않아요(`browser_addon_automation.ml:92-96`).
- 브라우저가 그룹 밖으로 빠져나가면 그룹이 비어도 브라우저는 살아 있어요. masc 는 이 사실을 확인할 방법이 없어서 영수증을 영영 쓰지 못해요.
- DELETE 가 실패하면 geckodriver 만 SIGKILL 을 받아요. 브라우저가 worker 그룹에 남으면 admission 이 `Settled` 가 되지 않아요. 이 경우도 지금은 영영 막혀요.

## 3. 목표와 비목표

목표
- 하나의 backend 가 끝나도 나머지 backend 와 worker 는 계속 일해요.
- Gecko 정리는 masc 가 직접 관측한 사실로 확인해요. 빠져나간 브라우저도 찾아서 멈추고 확인해요.
- 한 backend 의 정리가 확인되지 않아도 같은 선언은 새 인스턴스를 띄워요.
- 운영자 retain(#45216)은 남겨요. 다만 이번 같은 경우에는 필요 없게 해요.

비목표
- 운영자 브라우저의 업데이트 정책을 masc 가 바꾸지 않아요.
- Chrome 의 지금 방식(세션마다 열고 닫기)은 바꾸지 않아요.
- worker 를 backend 마다 다른 프로세스로 나누지 않아요. 7절에 이유를 적어요.

## 4. 제안

### 4.1 A: Gecko 를 Chrome·live 처럼 소유해요

**A1. geckodriver 를 자기 그룹으로 띄워요.**
- Chrome·live 처럼 `foreground_mgr` 와 guardian 으로 띄우고, 인스턴스마다 Gecko 자식 claim slot 을 둬요(`Automation_child_slot`). 지금은 `Installation_slot | Chrome_child_slot | Live_bidi_child_slot` 이에요.
- 이렇게 하면 Gecko 의 그룹이 비었는지를 worker 와 따로 확인할 수 있어요. DELETE 가 실패해도 그 그룹 전체에 TERM 을 보내고, 유예 뒤 KILL 을 보내요. Chrome·live 와 같은 규칙이에요.

**A2. 프로필 잠금 주인을 커널에 물어요.**

Firefox 계열은 실행 중인 동안 프로필의 `.parentlock` 에 쓰기 잠금(`fcntl`)을 쥐어요. 2026-10-23 에 실행 중인 Zen(pid 30381)으로 확인했어요. 읽기 전용으로 열고 `F_GETLK` 로 물으니 `write-locked, holder pid 30381` 이 나왔어요. 다시 뜬 브라우저도 같은 `-profile` 을 쓰므로 같은 잠금을 쥐어요. 부모 프로세스나 그룹과는 상관없어요.

Gecko 자식 slot 을 settle 할 때, 할당의 `profiles/` 아래 프로필 폴더마다 이렇게 해요.

1. `.parentlock` 을 `O_RDONLY | O_NOFOLLOW` 로 열어요. 일반 파일이고, 소유자가 masc 실행 사용자이고, 링크 수가 1 이어야 해요. 할당 폴더의 inode 는 지금처럼 먼저 확인돼 있어야 해요. `Owner_process_identity` 는 이 확인을 호출하는 쪽에 맡겨요(`lib/owner_process_identity/owner_process_identity.mli:1-3`).
2. 연 fd 를 `Owner_process_identity.capture ~lease_fd` 에 넘겨요. 이 모듈은 pid 파일이 아니라 `F_GETLK` 로 잠금 주인을 찾고, 그 프로세스를 붙잡아 둬요.
3. 결과를 닫힌 합타입으로 받아요.
   - `Unlocked` (`No_owner`)
   - `Held_by of Owner_process_identity.t`
   - `No_lock_file`
   - `Changing` (`Owner_changed` · `Unavailable`): 물어보는 사이에 주인이 끝나거나 바뀐 경우예요. 이번 확인을 미루고 다음 정리에서 다시 물어요.
   - `Unreadable of string`: 열기·검사가 실패한 경우예요. `Cleanup_unconfirmed` 로 남기고, 경로와 실패한 검사를 말해요. `Owner_process_identity.error` 에는 errno 가 없으므로, 모듈의 variant 이름을 그대로 말해요.
4. `Held_by` 면 `Owner_process_identity.request_termination` 으로 그 프로세스에만 SIGTERM 을 보내요. pid 숫자로 다시 찾지 않고, SIGKILL 로 올리지 않아요. 모듈의 계약이 그래요. 다음 정리에서 다시 물어요.
   - masc 전용 0700 할당 안의 파일에 쓰기 잠금을 쥔 같은 사용자의 프로세스예요. 그래서 그 프로필로 뜬 Gecko 브라우저라고 봐요. 다른 프로그램이 이 파일을 잠글 이유는 없지만, 이건 추론이에요. 주인의 실행 파일 경로를 기록에 남겨 사람이 확인할 수 있게 해요.
5. 모든 폴더가 `Unlocked` 이거나 `No_lock_file` 이면 프로필을 지워요.
   - 지금의 `empty_tree` 는 빈 폴더만 지워서 프로필(`.parentlock` 등 파일이 있음)을 지울 수 없어요(`lib/browser_addon_socket.ml:143-151`).
   - Chrome 의 비공개 프로필을 지우는 규칙(`remove_profile`, `lib/browser_addon_stagehand.ml`)을 같이 써요. 소유 uid 를 확인하고, 링크는 따라가지 않고 지우고, 링크 수가 1 인 일반 파일만 지우고, 그 밖의 것은 남기고 실패해요.
   - 이 규칙을 두 backend 가 함께 쓰는 함수 하나로 옮겨요.

**A3. 함께 바꾸는 것**
- `automation-closed.json` 영수증과 그걸 쓰고 읽는 코드를 지워요. 호환 읽기는 만들지 않아요(hard cut).
  - L2 를 배포할 때 이전 판이 띄운 인스턴스의 할당에는 이 파일이 남아 있어요. 새 판은 모르는 파일로 보고 정리를 거절해요. 그 배포에서 한 번은 운영자 retain 이 필요해요. changelog 에 `Fresh state required` 로 적어요.
- worker 안의 `uncertain` 은 남겨요. 이건 "지금 세션에 명령을 보내도 되나"를 정하는 값이지 정리 확인이 아니에요.
- `downloads/`·`download-snapshots/` 는 지금처럼 빈 폴더여야 해요(`browser_addon_socket.ml:158-159`, `205`).

### 4.2 B: backend 마다 따로 끝나요

**B1. owner 상태를 backend 별로 둬요.** 빠지거나 겹치는 backend 가 없도록 레코드로 둬요.

```ocaml
type ended =
  | Peer_lost of string          (* live 연결이 끊김 *)
  | Startup_failed of string
  | Cleanup_unconfirmed of string
type backend_state = Not_configured | Serving | Ended of ended
type backends = { automation : backend_state; stagehand : backend_state; live : backend_state }
type phase = Serving_backends of backends | Retired
```

**B2. 시작을 backend 별로 해요.**
- backend 를 감싸지 않고 나란히 띄워요. 하나의 시작이 실패하면 그 backend 만 `Ended (Startup_failed _)` 가 되고, 나머지는 시작해요.
- 서비스는 설정된 backend 가 모두 시작했거나 끝났을 때 요청을 받기 시작해요.

**B3. 끝날 때 owner 전체를 revoke 하지 않아요.**
- 2.1 의 revoke 여섯 곳을 그 backend 의 상태만 `Ended` 로 바꾸는 것으로 바꿔요. live 는 예외를 올리지 않아요.
- 끝난 backend 는 자기 자식 slot 을 settle 해요(A 의 Gecko 확인 포함).
- 끝난 backend 로 가는 명령은 지금의 "등록 안 됨"처럼 dispatch 전에 거절돼요. 거절 문구는 끝난 까닭을 말해요.
- `Retire`·stdin EOF·signal 은 지금처럼 worker 전체를 끝내요.
- 다운로드는 Gecko 의 몫이 실패했을 때만 버려요.

**B4. snapshot·inventory 가 backend 별 상태를 실어요.**
- 지금 inventory 는 `automation`·`stagehand` 키를 꼭 요구해요(`lib/browser_addon_inventory.ml:11-12`). `live` 를 같은 자리에 더하고, 셋 모두 `Ended` 와 까닭을 실을 수 있게 해요.
- host 쪽 선택(`Browser_selection`)은 지금처럼 registered·enabled 만 골라요. 그래서 끝난 backend 를 건너뛰어요.

**B5. 끝난 live 를 다시 띄워요.**
- 지금은 다시 띄울 장치가 없어요.
  - live 는 시작할 때마다 새 client id 를 받아요(`browser_addon_live_bidi.ml` 의 start).
  - owner 의 live 자리는 한 번만 채워지는 lazy 값이라, 두 번째 붙이기는 "already attached" 로 거절돼요(`browser_addon_owner.ml`).
- 그래서 이렇게 바꿔요.
  1. host 의 설정 패스가 관측에서 `live: Ended` 를 보면, worker 에 새 wire 명령 `Start_backend Live` 를 보내요. 박자는 설정 패스(기본 60초)와 같아요. 시간 제한이나 시도 횟수는 두지 않아요.
  2. worker 는 새 자식 claim instance 와 새 client id 로 live 를 띄우고, owner 의 live 자리를 바꿔 끼워요.
  3. 이전 client id 를 지정한 요청은 이미 있는 `Client_retired` 거절(`client_disconnected`)을 받아요(`lib/browser_lane/browser_lane.ml:774-776`). Keeper 는 다시 골라요.
- 자동 선택(Automatic)이 live 대신 Chrome·Gecko 를 고르는 것은 지금과 같아요. 로그인된 live 가 필요한 일은 `lane=live` 를 지정해야 해요. 8절에 질문으로 남겨요.

### 4.3 C: 정리 확인과 보류를 backend 별로 해요

- 할당의 기록을 backend 별 결과로 나눠요. `Released`, `Retained`(이 backend 만 보류), `Pending` 중 하나예요.
- installation slot(worker 자신)이 `Settled` 이고, 각 backend 가 `Released` 또는 `Retained` 면, 같은 선언은 새 인스턴스를 띄울 수 있어요. 2.2 의 `native_settled` 조건을 이렇게 바꿔요.
- 이렇게 해도 안전한 이유
  - 새 인스턴스는 새 할당 폴더, 새 자식 slot, 새 비공개 프로필, 새 임의 포트를 받아요. 보류된 Gecko 자원과 겹치는 게 없어요.
  - 운영자의 공유 프로필(live Firefox 프로필, Chrome 영속 프로필)은 프로필 claim 이 지켜요. 이전 live 가 아직 그 프로필을 쓰고 있으면, 새 live 시작은 지금처럼 "이미 쓰는 프로필"로 거절돼요. 그 backend 만 `Ended (Startup_failed _)` 가 돼요.
- 보류된 backend 의 정리는 설정 패스마다 다시 시도해요(지금의 `Cleanup_unconfirmed` → `Retry` 와 같은 박자). 서버 로그와 Lane Add-ons 화면에 보류된 자원과 까닭을 보여 줘요.
- 운영자 retain 은 "다시 시도해도 확인되지 않는 보류"를 사람이 맡는 길로 남아요.

### 4.4 D: automation 전용 브라우저 설치본을 권장해요

- `[browser.automation] binary` 는 운영자가 평소 쓰지 않는 설치본을 가리키게 하라고 안내해요. 그 설치본에만 `DisableAppUpdate` 정책을 걸면 1.1 의 탈출이 생기지 않아요.
- masc 는 정책 파일을 쓰지 않아요. 운영자 설치본 전체의 업데이트를 바꾸는 일이라서요.
- `browser-lane-setup` 과 설치 문서에 이 권장을 적어요. 설정을 강제하는 검사는 만들지 않아요.

## 5. 단계 (Stacked PR)

| 층 | 내용 | 검증 |
|---|---|---|
| L1 | geckodriver 를 `foreground_mgr`·guardian·`Automation_child_slot` 으로 띄움 (A1) | Gecko 그룹이 worker 와 따로 settle 되는지. DELETE 실패 뒤 그룹 전체가 끝나는지 |
| L2 | 프로필 잠금 확인과 비공개 프로필 삭제(A2), 영수증 삭제(A3) | 같은 프로필 잠금을 쥔 그룹 밖 프로세스가 정리 확인을 막고, SIGTERM 뒤 확인되는지. 잠금이 없을 때 프로필이 지워지는지 |
| L3 | owner 의 backend 별 상태, 나란히 시작, revoke 여섯 곳 바꿈, inventory 확장 (B1~B4) | live 연결을 끊어도 Chrome·Gecko 명령이 계속 되는지. 한 backend 의 시작 실패가 나머지를 막지 않는지 |
| L4 | backend 별 정리 기록과 보류, `native_settled` 조건 변경 (C) | Gecko 를 보류한 채 같은 선언이 새 인스턴스를 띄우는지. 공유 프로필을 쓰는 live 가 남았을 때 새 live 만 거절되는지 |
| L5 | `Start_backend Live` 와 live 재시작 (B5) | 끝난 live 가 다음 설정 패스에서 새 client id 로 돌아오는지. 이전 id 요청이 `Client_retired` 를 받는지 |
| L6 | 설계 문서(`browser-addon-lifecycle.md` 21-22행 결정 포함)와 설치 문서의 권장(D) | 문서 |

바뀌는 기존 테스트
- `test/test_browser_addon_live_bidi.ml` 의 "unexpected peer loss fences the worker"(L3)
- `test/test_browser_addon_owner_cleanup.ml` 의 "all backends settle despite failure and caller cancellation"(L3, L4)
- `test/test_browser_addon_socket.ml` 의 "owned backend requires receipt and empty resource trees"(L2)
- `test/test_browser_addon_automation.ml` 의 영수증 관련 테스트(L2)
- `test/test_lane_addon_native_runtime.ml` 의 `escaped-browser-profile` 시나리오(L2, L4)

## 6. 검증 방법

- L2·L4 를 배포한 뒤 운영자 Zen 에 업데이트를 받아 둔 상태에서 automation 세션을 열어요. 1.1 을 실제로 재현해요.
  - 전과 같이 빠져나가는지 봐요.
  - host 가 잠금으로 그 프로세스를 찾아 멈추는지 봐요.
  - 그사이 같은 선언의 새 인스턴스가 바로 뜨는지 봐요.
- L3·L5 를 배포한 뒤 live Firefox 를 직접 꺼요.
  - Chrome·Gecko 명령이 계속 되는지 봐요.
  - 다음 설정 패스에서 live 가 새 client id 로 돌아오는지 봐요.
- 두 경우 모두 서버 로그와 `GET /api/v1/lane-addons` 응답을 증거로 남겨요.

## 7. 대안과 트레이드오프

| 대안 | 장점 | 단점 |
|---|---|---|
| backend 마다 worker 프로세스를 따로 둠 | 끝나는 단위가 프로세스와 같아서 단순해요 | Exact Output broker·업로드·다운로드·선택이 worker 하나를 전제로 짜여 있어요. 고칠 곳이 이 RFC 보다 훨씬 많아요 |
| Gecko 브라우저를 masc 가 직접 띄우고 geckodriver 는 `--connect-existing` 으로 붙임 | 브라우저 pid 를 masc 가 알아요 | 업데이트 재실행처럼 브라우저가 스스로 다시 뜨면 결국 놓쳐요. 잠금 확인은 그래도 필요해요 |
| masc 가 Gecko 프로필을 직접 만들고 `-profile` 로 넘김 | geckodriver 가 프로필을 지우지 않아서, 아래 틈 하나가 닫혀요 | geckodriver 문서의 알려진 문제가 있어요. 직접 넘긴 프로필에서는 임의 Marionette 포트가 geckodriver 에 전달되지 않아요. 포트를 미리 정해 넘겨야 해요 |
| 정리할 때 잠금을 직접 잡고(`F_SETLK`) 지우는 동안 쥐고 있음 | 지우는 동안 그 프로필로 브라우저가 뜨지 못해요 | 이미 지워진 프로필에서 도는 브라우저는 여전히 못 찾아요 |
| 시작 전에 브라우저의 업데이트 대기 상태를 읽고 거절 | 탈출을 미리 막아요 | Mozilla 내부 파일 형식(`active-update.xml`)에 기대요. 형식이 바뀌면 조용히 틀려요 |
| masc 가 정책 파일을 써서 업데이트를 끔 | 탈출이 사라져요 | 운영자 브라우저 전체 설정을 바꿔요. 비목표예요 |
| 지금처럼 두고 운영자 retain 만 씀 | 바꿀 게 없어요 | 이번 같은 일이 날 때마다 사람이 들여다봐야 해요 |

잠금 확인으로 닫히지 않는 틈
- **다시 뜨기 직전.** 다시 뜨는 브라우저가 아직 잠금을 잡기 전이면 잠금이 비어 보여요. 그때 프로필을 지우면 그 브라우저가 masc 밖에 남을 수 있어요. 탈출은 브라우저가 시작할 때 생겨요. 그래서 worker 가 끝나는 시점과 겹칠 수 있어요.
- **지워진 프로필.** geckodriver 가 임시 프로필을 지운 뒤에도 브라우저가 지워진 inode 의 잠금을 쥐고 돌 수 있어요. 그러면 `No_lock_file` 로 보여요. 1.1 에서는 프로필이 남아 있었지만, geckodriver 가 언제 프로필을 지우는지는 확인 필요예요.
- 두 틈 모두 위 표의 "프로필을 직접 만들고 넘김"·"잠금을 쥐고 지움"으로 줄일 수 있어요. 어느 쪽을 L2 에 넣을지 8절에서 정해요.

## 8. 정하지 않은 것

1. 끝난 live 를 다시 띄우는 때(B5): 다음 설정 패스가 맞나요? 아니면 운영자가 연결을 다시 열 때만인가요? 운영자가 live 창을 일부러 닫은 경우에도 다시 열려요.
2. live 가 없는 동안 자동 선택이 다른 프로필(Chrome·Gecko)로 일을 보내는 것을 그대로 둘까요? 로그인이 필요한 일은 다른 프로필에서 실패해요.
3. 7절의 두 틈: L2 에 "프로필을 직접 만들고 넘김"을 넣을까요, "잠금을 쥐고 지움"을 넣을까요, 둘 다 넣을까요?
4. `Held_by` 프로세스가 SIGTERM 에도 끝나지 않으면 어떻게 할까요? `Owner_process_identity` 는 SIGKILL 으로 올리지 않아요. 이 RFC 는 그 backend 를 보류(C)로 두고 운영자 retain 에 맡기자고 제안해요. KILL 이 필요하면 그 모듈의 계약부터 바꿔야 해요.
5. 전용 설치본 권장(D)을 `browser-lane-setup` 이 물어볼까요, 문서로만 둘까요?

## 9. 리뷰 기록

맥락 없이 따로 맡긴 적대적 리뷰(2026-10-23)에서 나온 지적을 반영했어요.
- **P1:** 잠금이 풀린 프로필은 `empty_tree` 로 지울 수 없었어요. Chrome 비공개 프로필 삭제 규칙을 같이 쓰기로 했어요(A2-5).
- **P1:** live 재시작에 그걸 일으킬 장치가 없었어요. `Start_backend Live` 와 client id 교체를 넣었어요(B5).
- **P2:** 아래 다섯 가지를 반영했어요.
  - Gecko 확인이 worker 전체의 `Settled` 에 기대는 점 → A1
  - 세 backend 모두 owner 를 revoke 하는 점 → 2.1, B3
  - 시작이 감싸여 있는 점 → B2
  - DELETE 실패 시 브라우저가 worker 그룹에 남는 점 → A1
  - `Owner_process_identity` 의 사용 조건과 오류 → A2-1·3
- **P2:** 잠금이 사라진 inode 의 틈은 7절에 적고, 정할 것은 8절에 남겼어요.
- **P2:** 할당 하나에 기록 하나라서 여전히 서로 막는 점 → C 로 따로 다뤄요.
- **P3:** 인용 줄 번호를 이 RFC 의 base 에서 다시 읽어 고쳤어요. 상태를 리스트가 아닌 레코드로 바꿨어요. 다운로드가 Gecko 실패에서만 버려지게 했어요. 배포 때 retain 한 번이 필요하다는 점을 적었어요.
