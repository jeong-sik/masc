---
title: "기계 화면은 Lane 으로 본다 — 기계마다 API 와 TUI 화면을 따로 만들지 않는다"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0439", "lane-addon-v0"]
implementation_prs: []
---

# RFC — 기계 화면은 Lane 으로 본다

## 1. 원칙

Keeper 가 만지는 기계(MSX, DOS, 다음 기계)는 Lane 에 꽂아서 본다. Lane 에 꽂으면
화면만 보이는 게 아니라, 그 Lane 이 남긴 관측과 입력 기록을 맥락으로 쓸 수 있다.

`docs/design/lane-addon-v0.md` 는 이미 이렇게 정했다.

- 6행: Add-on 은 MSX Lane 의 머신, Browser Lane 의 세션을 재사용한다.
- 52행: 새 의미 패키지를 붙이려고 서버 dispatcher, TUI 메뉴, Dashboard 컴포넌트를
  고쳐야 하면 실패다.
- 126~127행: 코어를 고치지 않고 attach·inspect·slice·detach 가 되고 TUI 에 저절로
  나와야 한다. MSX 도 같은 계약으로 frame clock 과 incarnation 을 보인다.

이 RFC 는 그 문서가 비워 둔 한 곳, **TUI 가 Lane 에 꽂힌 기계의 화면을 보는 길**을 정한다.
기계를 움직이는 조작(입력·시간·수명)은 별도 RFC(§6)에서 다룬다.

## 2. 지금 모양 (2026-09-24, origin/main 과 #38438·#38439)

| 기계 | Lane source | TUI 가 화면을 읽는 길 |
|---|---|---|
| MSX | `msx_capture` (`lane_addon_sources.ml`) | `/api/v1/msx/frame` 폴링 (RFC-0439) |
| DOS | `dos_capture` (#38438 에서 추가) | `/api/v1/dos/frame` 폴링 (#38439 에서 추가) |

- MSX 는 전용 라우트가 8개다. frame·carts·press·load·save·restore·disk·tick
  (`server_routes_http_routes_msx.ml:439-479`). frame 과 carts 는 로그인 없이 열려 있다
  (`server_auth.ml:983-987`).
- #38439 는 같은 모양을 DOS 에 하나 더 만든다. 전용 라우트, 전용 팔레트(`Palette_dos`),
  전용 폴링이다. §1 의 52행 기준으로 실패한 모양이다.
- 적대적 리뷰에서 전용 폴링의 문제가 나왔다.
  - 요청 fiber 에서 `Dos_lane.identify` 가 stdlib `Mutex` 를 잡는다. Keeper 가 4M 걸음을
    돌리는 동안(약 170ms) 0.5초마다 오는 요청이 Eio domain 을 멈춘다.
  - 로그인 없이 열려 있고, 요청 하나에 base64 약 1.2MB 를 보낸다.
  - 게스트가 fault 를 내면 화면은 바뀌었는데 `steps` 가 그대로라 "안 바뀜"이 계속된다.
- Lane 쪽에 이미 있는 것.
  - `Msx_changed`·`Dos_changed` 활동이 기계 도구가 끝날 때마다 바인딩된 인스턴스를 깨운다.
    fault 로 끝난 도구도 끝난 도구다.
  - `msx_capture`·`dos_capture` 는 관측마다 화면을 `rgb8` blob 으로 store 에 남기고,
    관측의 `screen` evidence 로 가리킨다.
  - Lane 라우트는 `masc_lane_*` 도구 권한으로 인증한다.
- **관측의 화면은 증거로 쓰인다.**
  - `addons/msx-observer/server.py:45-58` 은 매 행의 evidence 에 `screen` 을 넣는다.
  - `addons/frame-progress/server.py:127-129` 는 `screen` 이 evidence 에 없으면 캡처를
    거절한다.
  - 행을 Keeper 에게 보내면 `publish_for_keeper` 가 그림 바이트까지 그대로 복사한다.
  - 그러니 관측의 화면을 남기지 않으면 이 둘과 Keeper evidence 가 깨진다.
- TUI 에 없는 것.
  - Lane 화면(`masc_tui_lane_addons`)은 글자 행과 evidence 만 그린다.
  - 새 관측을 알려 주는 push 가 없다. TUI 는 사용자가 움직일 때 inspect·slice 를 읽는다.
- #38439 의 `masc_tui_machine_view` 는 쓸 수 있다. 서버 프레임 한 장을 kitty 그래픽이나
  블록 모자이크로 그리는 부분이고, 기계를 가리지 않는다.

## 3. 결정

### 3.1 관전은 관측이 아니다

화면에는 쓰임이 둘 있다. 섞지 않는다.

| | 관측 | 관전 |
|---|---|---|
| 무엇 | 패키지가 인용하는 증거 | 사람이 지금 보는 화면 |
| 남기나 | 남긴다. 지금 동작 그대로 | 남기지 않는다. 지나가면 끝이다 |
| 어디서 | source capture → store → 관측 | source 의 지금 화면을 바로 읽는다 |

관측이 화면을 얼마나 남길지는 패키지가 정한다. `msx-observer` 가 매 행에 화면을 넣는 것은
그 패키지의 선택이고, 이 RFC 는 바꾸지 않는다.

### 3.2 source 가 "지금 화면"을 내놓는다

- 화면이 있는 source 는 그 사실을 타입으로 가진다. `msx_capture`·`dos_capture` 가 그렇다.
  기계 이름으로 가르지 않는다. 화면이 없는 source(`snapshot_file`, `lane_output`)에 관전을
  요청하면 오류다.
- 라우트 하나를 둔다: `GET /api/v1/lane-addons/live?instance_id=…&source_id=…`.
  - 그 인스턴스 바인딩에 있는 source 만 답한다.
  - store 에 아무것도 쓰지 않는다.
  - 기계 lock 은 `Eio_unix.run_in_systhread` 안에서만 잡는다. 요청 fiber 가 기계 lock 을
    기다리지 않는다.
  - 인증은 다른 Lane 라우트와 같다.
  - 응답은 지금 capture 모양(`{format="rgb8", width, height, rgb_base64}`)과 그 화면의
    기계 시간(MSX frame, DOS steps), incarnation 이다.
- 모르는 화면 `format` 은 TUI 가 그리지 않고 오류 줄을 보인다. 빈 그림으로 바꾸지 않는다.

### 3.3 새 관측이 왔을 때만 읽는다

- TUI 는 inspect 의 `observation_seq` 만 되풀이해 읽는다. seq 가 바뀌었을 때만 `live` 를
  부른다.
- 턴제 기계는 도구나 조작이 끝날 때만 화면이 바뀌고, 그때 활동 알림이 인스턴스를 깨워
  seq 가 오른다. 그래서 seq 로 충분하다.
- fault 로 끝난 도구도 활동을 낸다. 그래서 "화면은 바뀌었는데 안 바뀜" 문제가 없다.

### 3.4 TUI Lane 화면이 그린다

- 화면 있는 source 가 바인딩된 인스턴스를 고르면, TUI Lane 화면이 `masc_tui_machine_view`
  로 그린다.
- 크기 설정과 이미지 슬롯은 인스턴스마다 따로 둔다. #38439 의 "MSX·DOS 가 `image_id` 32 를
  같이 씀" 문제가 여기서 없어진다.

### 3.5 기계 전용 관전 라우트와 팔레트는 없앤다

- `/api/v1/dos/frame` 과 `Palette_dos` 는 만들지 않는다.
- `/api/v1/msx/frame` 은 사람의 조작이 Lane 을 거쳐 활동 알림을 낼 때 지운다(§6).
  지금 `/api/v1/msx/press` 는 도구가 아니라서 `Msx_changed` 를 내지 않는다. 먼저 지우면
  사람이 직접 게임할 때 화면이 멈춘다.

## 4. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| 기계는 서버에 산다 (RFC-0439) | 바뀌는 건 보는 길뿐이다 |
| 관측과 그 화면 evidence | 패키지와 Keeper evidence 가 인용한다(§2) |
| Keeper 의 기계 도구 (`masc_msx_*`, `masc_dos_*`) | 조작 RFC 에서 다룬다 |
| 보는 것만으로 기계 시간이 흐르지 않는다 | capture 는 이미 시간을 움직이지 않는다 |

## 5. 대안

- **기계마다 전용 라우트와 화면 (지금 방식).** 기계가 늘 때마다 서버와 TUI 를 고친다.
  폴링 문제가 기계마다 되풀이된다.
- **관측에 `Image` presentation 을 더해 관측의 화면을 그린다.** 관전이 관측을 만들어야만
  보이고, 보는 화면마다 store 에 남는다. 관전은 증거가 아니다.
- **관측의 화면을 남기지 않는다.** `msx-observer`·`frame-progress` 와 Keeper evidence 가
  사라진 blob 을 가리킨다.
- **SSE 로 화면을 밀어 준다.** TUI 에 Lane 알림 채널이 아직 없다. 채널이 생기면 §3.3 의
  seq 폴링만 바꾸면 된다.

## 6. 기계 조작 (별도 RFC)

사람이 TUI 에서 기계를 움직이는 길은 이 RFC 밖이다. 방향만 적는다.

- 조작은 세 층이다. **입력**(Button·Abs·Rel 이벤트), **시간**(턴제 기계의 진행),
  **수명**(전원·리셋, 미디어, 저장·복원). 의미 동작(Browser 요소 클릭, 패키지 Act)은
  Lane 마다 다르므로 공통 층에 넣지 않는다.
- 기계는 자기 장치를 선언하고, 선언한 입력만 받는다. 사람 장치를 기계 장치로 옮기는 변환은
  바인딩에 선언한다.
- 사람의 조작도 Lane 을 거쳐 활동 알림을 낸다. 그러면 §3.5 의 `/api/v1/msx/frame` 을
  지울 수 있다.

## 7. 열린 항목

1. **실시간 진행.** `/api/v1/msx/tick` 처럼 도구 밖에서 시간이 흐르면 활동 알림이 없다
   (`docs/guides/lane-addon-refresh.md`). 조작 RFC 의 시간 층에서 정한다.
2. **worker 없는 관전.** §3.2 는 worker 를 부르지 않는다. 하지만 인스턴스는 바인딩이 있어야
   하고, 지금 바인딩은 패키지 설치로만 생긴다. 화면만 보려고 패키지를 설치해야 하는지 정한다.
3. **DOS 가 둘이다.** 서버 안의 `Dos_lane` 과 컨테이너 DOSBox 인 `addons/dos-world` 가 있다.
   이 RFC 는 `dos_capture`(서버 안 기계)만 다룬다.

## 8. 단계

| 단계 | 내용 | 끝났다는 증거 |
|---|---|---|
| 1 | source 의 화면 타입, `live` 라우트 | 단위: 바인딩 밖 source 거절, 화면 없는 source 거절, store 에 쓴 바이트 0, 요청 fiber 에서 기계 lock 을 잡지 않음 |
| 2 | TUI Lane 화면이 `live` 를 그린다 (`masc_tui_machine_view` 재사용) | PTY: DOS 도구 한 번 → seq 가 오르고 그림이 바뀐다. seq 가 그대로면 `live` 요청이 없다 |
| 3 | 조작 RFC 가 사람의 조작에 활동 알림을 붙인다 | 그 RFC 에서 정한다 |
| 4 | MSX 관전을 Lane 으로 옮기고 `/api/v1/msx/frame` 폴링 경로를 지운다 | `rg '/api/v1/msx/frame' bin lib` 결과 0 |

#38439 는 Draft 로 둔다. `masc_tui_machine_view` 는 2 단계로 옮긴다.

## 9. 검증

- 단위: §8 1 단계 항목.
- PTY: DOS 와 MSX 각각 도구를 한 번 부른 뒤 화면이 바뀐다. 바뀌지 않았으면 `live` 요청이 없다.
- 라이브: 게임 한 판 동안 `live` 요청 수가 활동 수보다 많지 않은지, 관전 중 Lane store
  크기가 관측이 남긴 만큼만 늘었는지 센다.
