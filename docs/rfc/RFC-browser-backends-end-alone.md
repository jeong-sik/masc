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
지금은 셋이 한 몸이에요. 하나가 끝나면 worker 가 통째로 끝나고, 하나의 정리가 확인되지 않으면 셋 모두 새로 뜨지 못해요.

2026-10-22~23 에 이 구조 때문에 브라우저 도구가 두 번 오래 멈췄어요(1절).
1. Gecko 쪽 브라우저가 worker 밖으로 빠져나갔어요. 그 뒤 정리를 영영 확인할 수 없어서, 사람이 기록을 옮길 때까지 3시간 막혔어요.
2. live Firefox 연결 하나가 끊기자 worker 전체가 죽었어요. 런타임이 다시 띄우지 않아 9시간 막혔어요.

이 RFC 는 세 가지를 바꿔요.

- **A. Gecko 정리를 프로필 잠금으로 확인해요.** masc 전용 Gecko 프로필의 `.parentlock` 에 쓰기 잠금을 쥔 프로세스가 있는지 커널에 물어요(`fcntl F_GETLK`). 빠져나간 브라우저도 같은 프로필을 쓰므로 잡혀요. 확인할 수 없는 영수증(`automation-closed.json`)은 지워요.
- **B. backend 마다 상태를 따로 둬요.** live 연결이 끊기면 live backend 만 끝나고, worker 와 Chrome·Gecko 는 계속 일해요.
- **C. automation 전용 브라우저 설치본을 권장 설정으로 안내해요.** 운영자가 평소 쓰는 브라우저가 업데이트를 받아 둘 때 생기는 탈출을 줄여요. masc 가 운영자 브라우저의 정책 파일을 쓰지는 않아요.

1번 장애는 A 가, 2번 장애는 B 가 막아요. 2번 장애가 9시간이나 간 이유(죽은 worker 를 다시 띄우지 않음)는 #45290 에서 따로 고쳤어요.

## 1. 실측

### 1.1 Gecko 브라우저가 worker 밖으로 빠져나감 (#45187)

| 시각 (KST) | 일 | 근거 |
|---|---|---|
| 10-22 16:12 | 운영자의 Zen 이 1.23.4b 업데이트(163MB)를 받아 두었어요. 상태는 `Install Pending` 이에요. | `~/Library/Caches/Mozilla/updates/Users/dancer/Applications/Zen/active-update.xml`, `updates/0/update.mar` |
| 20:56:57 | Keeper 가 `lane=automation` 을 열었어요. geckodriver 가 운영자의 Zen 을 이 인스턴스 전용 프로필로 띄웠어요. | `webdriver.log` 의 `Running command` |
| 20:57:03 | geckodriver 가 `Process (pid=60783) unexpectedly closed with status 1` 로 답했어요. 같은 초에 `update.status` 가 `failed: 9` 로 쓰였고, 같은 프로필의 Zen(61713)이 launchd 아래에서 다시 떴어요. | `updates/0/update.status` 수정 시각, #45187 댓글 |
| 20:57 이후 | 세션 생성이 sessionId 없이 끝나서 `uncertain` 이 켜졌어요. automation 명령이 모두 `owned browser session authority is unknown` 으로 거절됐어요. | `lib/browser_addon_automation.ml:92-96` |
| 21:48 | 배포로 서버가 다시 떴어요. Gecko 쪽은 `automation-closed.json` 을 쓰지 않았어요. | 인스턴스 할당 폴더 |
| 21:49~00:42 | 새 서버가 1분마다 `cleanup incomplete: missing automation-closed.json` 만 남겼어요. 같은 선언은 새 인스턴스를 띄우지 못했고, Chrome·live 도 같이 멈췄어요. 운영자 retain(#45216)으로 풀었어요. | `masc-start-1022-2149.log` 등 |

Firefox 계열은 받아 둔 업데이트가 있으면 시작하자마자 종료하고 updater 를 돌린 뒤 자신을 다시 띄워요. Mozilla 는 이 동작을 고치지 않기로 했어요. updater 가 Firefox 프로세스를 바꿔치기하기 때문이에요([bug 1450268](https://bugzilla.mozilla.org/show_bug.cgi?id=1450268), WONTFIX).
업데이트를 끄는 공식 방법은 enterprise policy(`DisableAppUpdate` 등)뿐이에요. 이 정책은 설치본 전체에 걸려요([Disabling Automatic Update](https://firefox-source-docs.mozilla.org/toolkit/mozapps/update/docs/HowToDisable.html)).
2026-10-23 11:16 에 masc 와 같은 인자로 다시 띄워 봤어요. 업데이트 상태가 이미 `failed` 였고, 이번에는 Zen 이 geckodriver 의 자식으로 정상으로 떴어요.

### 1.2 live 연결 하나가 worker 전체를 끝냄 (#45288)

| 시각 (KST) | 일 | 근거 |
|---|---|---|
| 10-23 01:13 | live Firefox 로그의 마지막 줄은 `Killing GPU process due to IPC reply timeout` 이에요. 같은 시각 서버도 15분 동안 멈춰 있었어요(01:02~01:17). | `live-firefox.log`, `masc-start-1023-0032.log` |
| 01:17 | worker 가 `Fatal error: exception Sys_error("owned Firefox backend ended: client_disconnected")` 로 죽었어요. Gecko 정리는 확인됐어요(`automation-closed.json` 있음). | `masc-start-1023-0032.log` 4492-4521행 |
| 01:17~10:13 | 인스턴스가 메모리에 `running + failed` 로 남았고, 아무도 다시 띄우지 않았어요. | #45288, #45290 |

Chrome 과 Gecko 에는 문제가 없었어요. live 연결 하나 때문에 셋이 모두 꺼졌어요.

## 2. 지금 구조

### 2.1 셋이 한 몸으로 돌아요

- worker 는 backend 를 순서대로 감싸서 띄워요: `automation (chrome (live (serve)))` (`bin/masc_browser_addon_worker.ml:72-77`). 바깥 backend 가 준비돼야 안쪽이 시작해요.
- owner 의 상태는 하나예요: `type phase = Serving | Retired` (`lib/browser_addon_owner.ml:4`). backend 마다 따로 끝내는 상태도, wire 명령도 없어요. wire 에는 `Retire` 하나뿐이에요.
- live backend 는 연결이 끊기면 일부러 예외를 올려요. owner 전체를 먼저 revoke 하고(`lib/browser_addon_live_bidi.ml:341`), `Sys_error ("owned Firefox backend ended: " ^ detail)` 를 올려요(351). 이 예외는 Chrome·Gecko 의 scope 를 차례로 풀고, 잡는 곳 없이 프로세스를 끝내요.
- 설계 문서도 그렇게 정해요: "An unexpected connection failure revokes that worker rather than publishing a dead client." (`docs/design/browser-addon-lifecycle.md` 첫머리). 이 RFC 는 이 결정을 바꿔요(4.2절).

### 2.2 정리 확인은 할당 하나에 하나예요

- `Browser_addon_socket.cleanup` 은 할당 하나를 `let*` 한 줄로 확인해요. 할당은 `/tmp/mb-<id>` 하나이고, 기록도 하나, settlement 도 하나예요.
- 먼저 installation admission 이 `Settled` 여야 해요. worker 프로세스가 끝났고 그 프로세스 그룹이 비었다는 뜻이에요.
- 그다음 Chrome·live 의 자식 slot 을 settle 하고, Gecko 의 영수증을 읽어요. 하나라도 실패하면 할당 전체가 확인되지 않아요.

### 2.3 Gecko 는 브라우저를 직접 갖지 않아요

- Chrome·live 브라우저는 자식 claim slot, guardian(`masc-browser-process-owner`), 따로 쓰는 프로세스 그룹, host 쪽 settle 을 갖고 있어요.
- Gecko 는 그런 게 없어요. geckodriver 가 브라우저를 띄우고, masc 는 geckodriver 만 알아요. geckodriver 와 그 브라우저는 worker 의 프로세스 그룹 안에 있어요.
- 그래서 정리 확인을 worker 가 쓰는 영수증에 맡겨요. worker 는 세션 생성이 확실하지 않으면(`uncertain`) 영수증을 쓰지 않아요. `uncertain` 은 한 번 켜지면 꺼지지 않아요(`lib/browser_addon_automation.ml:92-96`).
- 브라우저가 그룹 밖으로 빠져나가면, 그룹이 비어도 브라우저는 살아 있어요. masc 는 이 사실을 확인할 방법이 없어서 영수증을 영영 쓰지 못해요.

## 3. 목표와 비목표

목표
- 하나의 backend 가 끝나도 나머지 backend 와 worker 는 계속 일해요.
- Gecko 정리는 masc 가 직접 관측한 사실로 확인해요. 빠져나간 브라우저도 찾아서 멈추고 확인해요.
- 운영자 retain(#45216)은 남겨요. 다만 이번 같은 경우에는 필요 없게 해요.

비목표
- 운영자 브라우저의 업데이트 정책을 masc 가 바꾸지 않아요.
- Chrome 의 지금 방식(세션마다 열고 닫기)은 바꾸지 않아요.
- worker 를 backend 마다 다른 프로세스로 나누지 않아요. 7절에 이유를 적어요.

## 4. 제안

### 4.1 A: Gecko 정리를 프로필 잠금으로 확인해요

Firefox 계열은 실행 중인 동안 프로필의 `.parentlock` 에 쓰기 잠금(`fcntl`)을 쥐어요. 2026-10-23 에 실행 중인 Zen(pid 30381)으로 확인했어요. 읽기 전용으로 열고 `F_GETLK` 로 물으니 `write-locked, holder pid 30381` 이 나왔어요. 다시 뜬 브라우저도 같은 `-profile` 을 쓰므로 같은 잠금을 쥐어요. 부모 프로세스나 그룹과 상관없어요.

host 쪽 Gecko 정리 확인을 이렇게 바꿔요.

1. installation admission 이 `Settled` 인지 봐요(지금과 같음). geckodriver 와 그 자식 브라우저는 worker 그룹에 있으므로, 이것으로 그 둘이 끝난 게 확인돼요.
2. 할당의 `profiles/` 아래 프로필 폴더마다 `.parentlock` 을 읽기 전용으로 열고, 이미 있는 `Owner_process_identity.capture ~lease_fd` 에 넘겨요(`lib/owner_process_identity/owner_process_identity.mli`). 이 모듈은 pid 파일이 아니라 `F_GETLK` 로 잠금 주인을 찾고, 그 프로세스를 붙잡아 둬요. 결과는 닫힌 합타입으로 받아요: `Unlocked`(`No_owner`) | `Held_by of Owner_process_identity.t` | `No_lock_file` | `Unreadable of error`.
3. 모두 `Unlocked` 이거나 `No_lock_file` 이면, Gecko 의 몫은 정리된 것으로 봐요. `profiles/`·`downloads/` 를 지금처럼 지워요.
4. `Held_by` 면, 그 프로세스는 masc 전용 프로필을 쓰는 Gecko 브라우저예요. host 가 멈춰요.
   - `Owner_process_identity.request_termination` 으로 붙잡은 그 프로세스에만 SIGTERM 을 보내요. pid 숫자로 다시 찾지 않고, SIGKILL 로 올리지 않아요. 모듈의 계약이 그래요.
   - 다음 정리 시도에서 다시 물어요. 잠금이 풀리면 3으로 가요.
   - 시간 제한이나 시도 횟수는 두지 않아요. 지금의 maintenance 박자(기본 60초)에 따라요.
5. `Unreadable` 이면 지금처럼 `Cleanup_unconfirmed` 로 남겨요. 무엇을 읽지 못했는지(경로, errno)를 말해요.

함께 바꾸는 것
- `automation-closed.json` 영수증과 그걸 쓰고 읽는 코드를 지워요. 호환 읽기는 만들지 않아요(hard cut). 남아 있는 옛 할당은 운영자 retain 으로 넘겨요.
- worker 안의 `uncertain` 은 남겨요. 이건 "지금 세션에 명령을 보내도 되나"를 정하는 값이지 정리 확인이 아니에요.
- Gecko 프로필 경로는 지금처럼 geckodriver 가 `--profile-root` 아래에 정해요. host 는 그 폴더 아래를 모두 훑어요. 이름 규칙(`rust_mozprofile*`)에 기대지 않아요.

### 4.2 B: backend 마다 상태를 따로 둬요

owner 의 상태를 backend 별로 나눠요.

```ocaml
type backend = Automation | Stagehand | Live
type backend_state =
  | Serving
  | Ended of ended            (* 이 backend 만 끝남. worker 는 계속 일함 *)
type ended =
  | Peer_lost of string        (* live 연결이 끊김 *)
  | Startup_failed of string
  | Cleanup_unconfirmed of string
type phase = Serving_backends of (backend * backend_state) list | Retired
```

- live 연결이 끊기면, live backend 는 자기 자식 claim 만 settle 하고 `Ended (Peer_lost _)` 가 돼요. owner 전체는 revoke 하지 않고, 예외도 올리지 않아요.
- 끝난 backend 로 가는 명령은 지금의 "등록 안 됨"처럼 dispatch 전에 거절돼요. 거절 문구는 끝난 까닭을 말해요.
- snapshot·inventory 가 backend 별 상태를 실어요. 지금 inventory 는 `automation`·`stagehand` 키를 꼭 요구해요(`browser_addon_inventory.ml:11-12`). `live` 를 같은 자리에 더해요.
- host 쪽 선택(`Browser_selection`)은 지금처럼 registered·enabled 만 고르므로, 끝난 backend 를 자연히 건너뛰어요.
- `Retire`·stdin EOF·signal 은 지금처럼 worker 전체를 끝내요.

끝난 live 를 다시 띄우는 시점
- 이 RFC 는 "다음에 live 를 쓰려는 명령이 올 때 다시 띄운다"를 제안해요. Chrome 이 이미 세션마다 열고 닫는 방식과 같아요.
- 운영자가 live 창을 일부러 닫은 경우에도, Keeper 가 live 를 쓰면 다시 열려요. 이게 괜찮은지는 8절에 질문으로 남겨요.

정리 확인
- 할당 하나에 기록 하나는 그대로 둬요. 정리 확인은 backend 별 결과를 모아서 내요.
- 끝난 backend 의 정리는 그 backend 가 끝날 때 해요(live 는 자식 slot settle, Gecko 는 4.1 의 잠금 확인). 할당 전체 정리 때는 이미 확인된 몫을 다시 확인하기만 해요.

### 4.3 C: automation 전용 브라우저 설치본을 권장해요

- `[browser.automation] binary` 는 운영자가 평소 쓰지 않는 설치본을 가리키게 하라고 안내해요. 그 설치본에만 `DisableAppUpdate` 정책을 걸면 1.1 의 탈출이 생기지 않아요.
- masc 는 정책 파일을 쓰지 않아요. 운영자 설치본 전체의 업데이트를 바꾸는 일이라서요.
- `browser-lane-setup` 과 설치 문서에 이 권장을 적어요. 설정을 강제하는 검사는 만들지 않아요.
- 전용 설치본을 쓰지 않아도 A 가 정리를 확인하므로 막히지는 않아요. C 는 탈출 자체를 줄이는 권장이에요.

## 5. 단계 (Stacked PR)

| 층 | 내용 | 검증 |
|---|---|---|
| L1 | Gecko 프로필 잠금 읽기. `profiles/` 를 훑고 각 `.parentlock` 을 `Owner_process_identity.capture` 에 넘겨 닫힌 합타입으로 돌려줌. 새 C 코드는 없음 | `fcntl` 쓰기 잠금을 쥔 실제 자식 프로세스로 `Held_by`·`Unlocked`·`No_lock_file` 확인 |
| L2 | `Browser_addon_socket.cleanup` 의 Gecko 확인을 잠금으로 바꾸고 `automation-closed.json` 을 지움. 잠금을 쥔 프로세스의 신원 확인과 TERM | 빠져나간 프로세스를 흉내 낸 픽스처(같은 프로필 잠금을 쥔 그룹 밖 프로세스)가 정리 확인을 막고, 멈춘 뒤 확인되는지 |
| L3 | owner 의 backend 별 상태와 wire·inventory 확장. live 연결이 끊겨도 worker 가 계속 일함 | 기존 `test_browser_addon_live_bidi` 의 "unexpected peer loss fences the worker" 를 새 동작으로 바꿈. Chrome·Gecko 명령이 계속 되는지 |
| L4 | 끝난 live 를 다음 명령 때 다시 띄우기 | live 재시작 테스트 |
| L5 | 설계 문서와 설치 문서의 권장(C) | 문서 |

바뀌는 기존 테스트
- `test/test_browser_addon_live_bidi.ml` 의 peer loss 테스트(L3)
- `test/test_browser_addon_socket.ml` 의 "owned backend requires receipt and empty resource trees"(L2)
- `test/test_browser_addon_automation.ml` 의 영수증 관련 테스트(L2)
- `test/test_lane_addon_native_runtime.ml` 의 `escaped-browser-profile` 시나리오(L2)

## 6. 검증 방법

- L2 를 배포한 뒤, 운영자 Zen 에 업데이트가 받아져 있는 상태에서 automation 세션을 열어요. 1.1 을 실제로 재현해 봐요.
  - 전과 같이 빠져나가는지 봐요.
  - host 가 잠금으로 그 프로세스를 찾아 멈추는지 봐요.
  - 다음 정리에서 할당이 확인되고 새 인스턴스가 뜨는지 봐요.
- L3 를 배포한 뒤, live Firefox 를 직접 꺼요. Chrome·Gecko 명령이 계속 되는지, worker 가 끝나지 않는지 봐요.
- 두 경우 모두 서버 로그와 `GET /api/v1/lane-addons` 응답을 증거로 남겨요.

## 7. 대안과 트레이드오프

| 대안 | 장점 | 단점 |
|---|---|---|
| backend 마다 worker 프로세스를 따로 둠 | 끝나는 단위가 프로세스와 같아서 단순해요 | Exact Output broker·업로드·다운로드·선택이 한 worker 를 전제로 짜여 있어요. 고칠 곳이 이 RFC 보다 훨씬 많아요 |
| Gecko 브라우저를 masc 가 직접 띄우고 geckodriver 는 `--connect-existing` 으로 붙임 | 브라우저 pid 를 masc 가 알아요 | 업데이트 재실행처럼 브라우저가 스스로 다시 뜨면 결국 놓쳐요. 잠금 확인은 그래도 필요해요 |
| 시작 전에 브라우저의 업데이트 대기 상태를 읽고 거절 | 탈출을 미리 막아요 | Mozilla 내부 파일 형식(`active-update.xml`)에 기대요. 형식이 바뀌면 조용히 틀려요 |
| masc 가 정책 파일을 써서 업데이트를 끔 | 탈출이 사라져요 | 운영자 브라우저 전체 설정을 바꿔요. 비목표예요 |
| 지금처럼 두고 운영자 retain 만 씀 | 바꿀 게 없어요 | 이번 같은 일이 날 때마다 사람이 들여다봐야 해요 |

잠금 확인의 한계
- 다시 뜨는 브라우저가 아직 잠금을 잡기 전인 아주 짧은 틈에 정리가 돌면, 잠금이 비어 보여요. 그 상태로 프로필을 지우면 그 브라우저가 masc 밖에 남을 수 있어요.
- 실제로는 정리가 worker 가 끝난 뒤에 돌아요. 이번 탈출은 정리보다 51분 먼저였어요. 그래도 틈이 0 은 아니어서 8절에 질문으로 남겨요.

## 8. 정하지 않은 것

1. 끝난 live 를 다시 띄우는 때(4.2): 다음 명령 때가 맞나요? 아니면 운영자가 연결을 다시 열 때만인가요?
2. 잠금이 비어 보이는 짧은 틈(7절): 받아들일까요? 아니면 L2 에서 updater 프로세스까지 찾는 방법을 더 조사할까요?
3. `Held_by` 프로세스가 SIGTERM 에도 끝나지 않으면 어떻게 할까요? `Owner_process_identity` 는 SIGKILL 으로 올리지 않아요. 이 RFC 는 정리를 확인하지 않은 채로 두고 운영자 retain 에 맡기자고 제안해요. KILL 이 필요하면 그 모듈의 계약부터 바꿔야 해요.
4. 전용 설치본 권장(C)을 `browser-lane-setup` 이 물어볼까요, 문서로만 둘까요?
