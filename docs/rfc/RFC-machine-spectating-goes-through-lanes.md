---
title: "기계 화면은 Lane 라우트 하나로 보고, 사람의 조작도 알림을 낸다"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0439", "lane-addon-v0"]
implementation_prs: ["#38733", "#38730", "#38815"]
---

# RFC — 기계 화면은 Lane 라우트 하나로 본다

## 1. 문제 두 개

1. **기계마다 관전 API 를 만든다.** MSX 는 `/api/v1/msx/frame`(RFC-0439)을, #38439 는
   `/api/v1/dos/frame` 과 `Palette_dos` 를 만든다. 기계가 늘 때마다 서버와 TUI 를 고친다.
   #38439 리뷰에서는 요청 fiber 가 기계 lock(stdlib `Mutex`, 최대 4M 걸음 약 170ms)을
   기다리는 문제와, fault 뒤 `steps` 를 화면 변경 표식으로 쓰면 화면이 멈추는 문제가 나왔다.
   #38715 는 DOS 걸음 계산을 고쳤고, 이 RFC 는 화면 갱신을 별도 변경 카운터로 결정한다.
2. **사람의 조작은 알림을 내지 않는다.** `notify_activity` 를 부르는 곳은 도구가 끝났을 때
   (`keeper_event_bridge.ml:715`) 하나다. `/api/v1/msx/press`·`load`·`restore`·`disk`·`tick` 은
   `Msx_lane` 을 바로 불러서 Lane 인스턴스를 깨우지 않는다. 또 `notify_activity` 는 root
   domain 이 아니면 아무것도 하지 않는다(`lane_addon_runtime.ml:461`).

## 2. 결정

### 2.1 보기: `live` 라우트 하나

- `GET /api/v1/lane-addons/live?source_kind=…&since=N&incarnation=I`
  - 화면이 있는 source 종류(`msx_capture`, `dos_capture`)만 받는다. 화면 없는 종류는 오류다.
  - 기계가 가진 **변경 카운터**가 `N` 이고 incarnation 이 `I` 이면 "그대로"만 답한다. 하나라도
    다르면 화면과 카운터, incarnation 을 답한다. 카운터는 서버가 재시작하면 0 부터 다시 세므로
    카운터만으로는 두 화면을 가를 수 없다. `since` 와 `incarnation` 은 같이 오거나 같이 빠진다.
  - "그대로" 판정은 기계 lock 을 잡지 않는다. 카운터와 incarnation 을 하나의 불변 표식으로
    `Atomic.t` 에 게시한다. 실행 중인 화면을 이전 표식과 같다고 답해서는 안 된다. #38733 의
    DOS 는 `No_screen | Stable of mark | Running of mark` 를 게시하고 `Stable` 에서만 "그대로"를
    답한다. MSX 는 실행 전에 표식을 올려 같은 이전 표식의 "그대로"를 막는다. 새 source 도
    실행 중에는 이전 표식의 "그대로"를 막아야 한다. DOS 실행은 lock 을 최대 4M 걸음(약 170ms)
    쥐므로, lock 을 기다리면 몇 바이트짜리 응답이 제일 비싼 경로가 된다.
  - 다를 때만 `Eio_unix.run_in_systhread` 안에서 lock 을 잡고 화면·카운터·incarnation 을 한 번에
    읽는다(`capture_with_identity` 처럼).
  - store 에 아무것도 쓰지 않는다. 관측과 그 화면 evidence 는 지금 그대로다
    (`msx-observer`·`frame-progress`·Keeper evidence 가 인용한다).
  - 인증을 요구한다. `/api/v1/msx/frame` 과 달리 `is_public_read_path` 에 넣지 않는다.
- **변경 카운터**는 기계가 무엇이든 실행하면 오른다. 도구, 사람의 조작, tick, load, restore,
  그리고 fault 로 끝난 실행도 포함한다. 실행을 시도할 때마다 오르는 별도 값이다. DOS 의
  `steps` 에서 파생하지 않는다. `steps` 는 0 걸음 fault 에서 오르지 않는다. Lane 관측 seq 도 쓰지 않는다. seq 는 worker 가 관측에
  성공할 때만 오르므로(`commit_output`), worker 가 실패하거나 죽으면 멈춘다.
- 보는 데 패키지 설치나 worker 는 필요 없다.
- **왜 Lane 경로 아래인가.** `live` 는 Lane 인스턴스·바인딩·관측을 읽지 않는다. 읽는 것은 Lane 의
  **source 어댑터**(`msx_capture`, `dos_capture`)가 가리키는 기계이고, 요청도 그 source 이름으로
  받는다. 관측은 source 를 캡처해 남기는 길이고, `live` 는 같은 source 를 남기지 않고 지금 보는
  길이다. 새 기계가 source 어댑터를 얻으면 같은 라우트로 보인다. 기계마다 라우트를 만들지 않는다.
- #38815 의 TUI 는 DOS 화면을 기존 0.3초 주기로 `live` 에 묻는다. MSX 는 열기·입력·load·
  checkpoint 뒤 `live` 를 읽고, 주기 실행은 기존 `POST /api/v1/msx/tick` 을 유지한다.
  `live` 의 "그대로" 답은 몇 바이트다.

### 2.2 사람의 조작도 알림을 낸다

- 사람 경로(`/api/v1/msx/press` 등)가 끝나면 도구와 같은 활동(`Msx_changed`)을 한 번 낸다.
- 알림은 root domain 에서 낸다. 넘기는 일은 호출자마다 하지 않고 `notify_activity` 안에서
  한다. 어느 domain 에서 불러도 root 로 넘어간다. 조용히 버리지 않는다.
- 도구 경로는 지금처럼 `activity_of_misc_operation` 이 낸다. 한 조작에 알림은 한 번이다.
- `tick` 은 frame 마다 알림을 내지 않는다(§4).

### 2.3 없애는 것

- `/api/v1/dos/frame`, `Palette_dos` 는 만들지 않는다.
- `/api/v1/msx/frame` 은 TUI 가 `live` 로 옮긴 뒤 지운다.

## 3. 하지 않는 것

- **입력 추상화.** MSX·DOS 입력 함수를 그대로 둔다. 공통 이벤트로 바꾸면 DOS `press` 의
  "기계가 바쁘면 나머지 키를 넣지 않음"과 `type_text` 의 대소문자 처리가 사라지고, ledger
  모양이 바뀌어 기존 checkpoint 와 `msx-observer` 가 깨진다. 축·조이스틱이 필요한 기계가
  생기면 그때 Linux evdev(`EV_KEY`·`EV_ABS`·`EV_REL`) 모양을 따른다.
- **관측 화면 보관 정책.** 관측이 화면을 얼마나 남길지는 패키지가 정한다.

## 4. 열린 항목

- **실시간 tick.** 사람이 실시간으로 게임하면 frame 마다 알림을 낼 수 없다. `snapshot_file`
  인스턴스는 모든 활동에 깨어나고, MSX 인스턴스는 관측마다 약 147KB 를 남긴다. tick 동안의
  알림을 어떻게 낼지 정해야 한다. 보기(§2.1)는 카운터로 하므로 이 문제와 상관없다.

## 5. 단계와 검증

| 단계 | 내용 | 증거 |
|---|---|---|
| 1 | 기계 변경 카운터, `live` 라우트 | 단위: fault 로 끝난 실행 뒤 카운터가 오른다. `since`·`incarnation` 이 같으면 "그대로". 같은 프로그램을 두 번 load 하고 이전 값을 보내면 "그대로"가 아니다. store 에 쓴 바이트 0. 인증 없으면 거절 |
| 2 | 사람 경로 알림 | 단위: root 가 아닌 domain 에서 부른 `notify_activity` 가 알림을 낸다. `/api/v1/msx/press` 한 번에 `Msx_changed` 한 번. 도구 한 번에도 한 번 |
| 3a (#38815) | TUI 가 `live` 로 그린다. TUI 의 `/api/v1/msx/frame` 호출을 지운다 | PTY: DOS 도구 한 번 → 그림이 바뀐다. 안 바뀌면 "그대로"만 온다. `rg '/api/v1/(msx|dos)/frame' bin` 결과 0 |
| 3b (후속) | 서버의 옛 `/api/v1/msx/frame` 라우트와 공개 읽기 허용 항목을 지운다 | `rg '/api/v1/(msx|dos)/frame' bin lib` 결과 0. 라우트 테스트도 `live` 계약으로 옮긴다 |

#38439 는 Draft 로 둔다. TUI 그리기(`masc_tui_machine_view`)는 전역 상태 모듈이므로 3 단계에서
그 PR 에서 가져올 부분을 다시 정한다.
