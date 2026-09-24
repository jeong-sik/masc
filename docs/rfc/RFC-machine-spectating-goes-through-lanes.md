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
사람이 TUI 에서 보는 것과 Keeper 가 evidence 로 받는 것이 같은 기록이 된다.

`docs/design/lane-addon-v0.md` 는 이미 이렇게 정했다.

- 6행: Add-on 은 MSX Lane 의 머신, Browser Lane 의 세션을 재사용한다.
- 52행: 새 의미 패키지를 붙이려고 서버 dispatcher, TUI 메뉴, Dashboard 컴포넌트를
  고쳐야 하면 실패다.
- 126~127행: 코어를 고치지 않고 attach·inspect·slice·detach 가 되고 TUI 에 저절로
  나와야 한다. MSX 도 같은 계약으로 frame clock 과 incarnation 을 보인다.

이 RFC 는 그 문서가 비워 둔 한 곳, **TUI 가 Lane 의 그림을 그리는 길**을 정한다.

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
- Lane 쪽에는 이미 필요한 게 대부분 있다.
  - `Msx_changed`·`Dos_changed` 활동이 기계 도구가 끝날 때마다 바인딩된 인스턴스를 깨운다.
    fault 로 끝난 도구도 끝난 도구다.
  - `msx_capture`·`dos_capture` 는 화면을 `rgb8` blob 으로 store 에 남기고, 관측의
    `screen` evidence 로 가리킨다.
  - Lane 라우트는 `masc_lane_*` 도구 권한으로 인증한다.
- TUI 에 없는 것.
  - Lane 화면(`masc_tui_lane_addons`)은 글자 행과 evidence 만 그린다.
    `Lane_addon_presentation.format` 은 `Text | Number | Boolean | Json` 뿐이다.
  - 새 관측을 알려 주는 push 가 없다. TUI 는 사용자가 움직일 때 inspect·slice 를 읽는다.
  - 남은 blob 을 TUI 가 읽는 라우트가 없다. evidence 는 Keeper 에게 보낼 때만 풀린다.
- #38439 의 `masc_tui_machine_view` 는 쓸 수 있다. 서버 프레임 한 장을 kitty 그래픽이나
  블록 모자이크로 그리는 부분이고, 기계를 가리지 않는다.

## 3. 결정

### 3.1 그림은 presentation 의 한 종류다

- `Lane_addon_presentation.format` 에 `Image` 를 더한다. 값은 관측 안의 evidence 참조
  하나이고, 가리키는 blob 은 `{format="rgb8", width, height, rgb_base64}` 이다.
  `msx_capture`·`dos_capture` 가 지금 쓰는 모양 그대로다.
- 패키지가 `format = "image"` 인 reading 을 선언하면 TUI Lane 화면이 그 reading 을
  `masc_tui_machine_view` 로 그린다. 기계 이름으로 나누지 않는다.
- 모르는 blob `format` 은 그리지 않고 오류 줄을 보인다. 조용히 빈 그림을 그리지 않는다.

### 3.2 새 관측이 올 때만 그림을 읽는다

- TUI 는 작은 요청(inspect 의 `observation_seq`)만 되풀이한다. seq 가 바뀌었을 때만
  blob 을 가져온다.
- blob 은 인스턴스와 digest 로 읽는 라우트 하나로 가져온다
  (`GET /api/v1/lane-addons/blob?instance_id=…&digest=…`). 그 인스턴스의 관측이 가리킨
  digest 만 답한다. 기계마다 라우트를 만들지 않는다.
- 인증은 다른 Lane 라우트와 같다.

### 3.3 기계 전용 관전 라우트와 팔레트는 없앤다

- `/api/v1/msx/frame` 폴링을 Lane 화면이 대신하면 TUI 의 MSX 관전 경로와 그 라우트를
  지운다. `/api/v1/dos/frame` 과 `Palette_dos` 는 처음부터 만들지 않는다.
- 남는 것: `masc_tui_machine_view` (그림 그리기), 기계 source 어댑터.

## 4. 바꾸지 않는 것

| 그대로 | 왜 |
|---|---|
| 기계는 서버에 산다 (RFC-0439) | 바뀌는 건 보는 길뿐이다 |
| Keeper 의 기계 도구 (`masc_msx_*`, `masc_dos_*`) | 기계를 움직이는 길은 도구다 |
| 관측을 보는 것만으로 기계 시간이 흐르지 않는다 | capture 는 이미 시간을 움직이지 않는다 |
| source 어댑터의 capture 모양 | `rgb8` blob 과 `screen` evidence 를 그대로 쓴다 |

## 5. 대안

- **기계마다 전용 라우트와 화면 (지금 방식).** 기계가 늘 때마다 서버와 TUI 를 고친다.
  관전 기록이 Lane 맥락과 따로 논다. 폴링 문제가 기계마다 되풀이된다.
- **Lane 알림만 받고 그림은 전용 라우트로 읽는다.** 폴링 횟수는 준다. 하지만 전용 라우트와
  전용 화면이 그대로 남아 §1 의 기준을 못 넘는다.
- **SSE 로 그림을 밀어 준다.** TUI 에 Lane 알림 채널이 아직 없다. 채널이 생기면 §3.2 의
  seq 폴링만 바꾸면 된다. 먼저 폴링으로 시작한다.

## 6. 열린 항목 (운영자 결정)

1. **보관.** 관측마다 그림이 store 에 남는다. MSX 는 256×192 RGB 라 한 장에 147KB 다.
   DOS 는 화면 모드에 따라 다르고(`Dos_machine.frame_dims`), 리뷰에서 본 한 장은 base64 로
   약 1.2MB 였다. SHA-256 이라 같은 화면은 한 번만 남지만, 게임이 돌면 계속 쌓인다.
   `Lane_addon_store` 에는 지우는 API 가 없다. 관전용 그림을 얼마나 남길지 정해야 한다.
2. **사람의 조작.** 사람이 TUI 에서 MSX 에 키를 넣는 기능(press·load·save·restore·disk·tick)
   은 관전과 다르다. Lane Act 로 옮길지, 전용 경로로 둘지 정해야 한다. 이 RFC 는 관전만
   옮긴다.
3. **worker 없는 관전.** 지금 패키지는 관측마다 컨테이너 worker 를 부른다
   (`addons/msx-observer`, cpus 0.5). 화면만 보는 데 worker 가 필요한지, source 만 담는
   패키지를 허용할지 정해야 한다.
4. **도구 밖에서 바뀐 화면.** `/api/v1/msx/tick` 처럼 도구가 아닌 길로 시간이 흐르면
   활동 알림이 없다(`docs/guides/lane-addon-refresh.md`). 조작을 옮기지 않으면 그 길에서도
   알림을 내야 한다.
5. **DOS 가 둘이다.** 서버 안의 `Dos_lane` 과 컨테이너 DOSBox 인 `addons/dos-world` 가 있다.
   이 RFC 는 `dos_capture`(서버 안 기계)만 다룬다.

## 7. 단계

| 단계 | 내용 | 끝났다는 증거 |
|---|---|---|
| 1 | `Image` presentation, blob 라우트 | 단위 테스트: 선언한 digest 만 답하고, 모르는 format 은 오류 |
| 2 | TUI Lane 화면이 image reading 을 그린다 (`masc_tui_machine_view` 재사용) | PTY: DOS 도구 한 번 → seq 가 바뀌고 그림이 바뀐다. seq 가 그대로면 blob 요청이 없다 |
| 3 | §6 의 1·2·4 결정에 따라 보관, 사람의 조작, 도구 밖 알림 | 결정 뒤 따로 적는다 |
| 4 | MSX 관전을 Lane 으로 옮기고 `/api/v1/msx/frame` 폴링 경로를 지운다 | `rg '/api/v1/msx/frame' bin lib` 결과 0 |

4 단계는 3 단계 뒤에만 한다. 사람이 `/api/v1/msx/press` 로 넣은 키는 도구가 아니라서
`Msx_changed` 를 내지 않는다. 그 길이 알림을 내기 전에 frame 폴링을 지우면, 사람이 직접
게임할 때 화면이 멈춘다.

#38439 는 1~2 단계가 들어올 때까지 Draft 로 둔다. `masc_tui_machine_view` 는 2 단계로
옮긴다.

## 8. 검증

- 단위: presentation 파싱, blob 라우트 권한과 digest 범위, 모르는 format 거절.
- PTY: DOS 와 MSX 각각 도구를 한 번 부른 뒤 화면이 바뀐다. 바뀌지 않았으면 blob 요청이 없다.
- 라이브: 게임 한 판 동안 blob 요청 수가 도구 호출 수보다 많지 않은지 센다.
  서버 로그에 요청 fiber 가 기계 lock 을 기다린 흔적이 없는지 본다.
