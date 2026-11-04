<<<<<<< HEAD
---
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
rfc: "0485"
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
rfc: "0482"
========
rfc: "0486"
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
rfc: "0482"
========
rfc: "0486"
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
title: "브라우저 lane 미러링과 MSX·DOS 관전은 TUI 가 당겨 오지 않고 서버가 프레임을 보낸다"
status: Draft
created: 2026-11-04
updated: 2026-11-04
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480", "msx-surface-focus-mode"]
---

<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
# RFC-0485 — 미러링과 관전은 서버가 프레임을 보낸다
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
# RFC-0482 — 미러링과 관전은 서버가 프레임을 보낸다
========
# RFC-0486 — 미러링과 관전은 서버가 프레임을 보낸다
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
# RFC-0482 — 미러링과 관전은 서버가 프레임을 보낸다
========
# RFC-0486 — 미러링과 관전은 서버가 프레임을 보낸다
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md

## 0. 요약

RFC-0480 은 TUI 의 주기 읽기를 모두 없앤다. 그중 두 화면은 "바뀌었다고 알리면 다시 읽는다"로 옮길 수 없다. 보여 주는 것이 계속 바뀌는 화면이라, 알림이 곧 프레임이기 때문이다.

- 브라우저 lane 미러링: Connectors 화면에 브라우저 lane 을 열면 2초 tick 마다 viewport 나 scene 을 다시 읽는다(`Browser_lane_view.cadence_operation`, `bin/masc_tui_types.ml`).
- MSX·DOS 관전: TUI 가 tick 을 POST 해서 머신을 한 단계 진행시키고 그 프레임을 받는다(`Masc_tui_msx_tick`, "The spectator's single advancing POST").

이 RFC 는 두 화면을 서버가 보내는 프레임 스트림으로 바꾸는 방향을 정한다. 운영자 결정(2026-11-04)으로 RFC-0480 의 층에서 빼서 따로 다룬다.

## 1. 지금 상태

| 화면 | TUI 가 하는 일 | 문제 |
|---|---|---|
| 브라우저 lane | 2초 tick 에 viewport 스크린샷이나 scene 을 다시 읽는다. 사용자가 누르는 중이거나 다른 요청이 진행 중이면 건너뛴다 | 브라우저가 안 바뀌어도 2초마다 이미지를 받는다. 2초 사이의 변화는 보이지 않는다 |
| MSX·DOS 관전 | 관전 화면이 열려 있는 동안 tick POST 로 머신을 진행시킨다 | 보는 사람이 머신 진행을 몰고 간다. 관전자가 둘이면 진행도 두 배가 되는지 확인하지 못했다 |

두 화면 모두 TUI 를 닫으면 멈춘다. 서버에는 "누가 보고 있다"는 사실이 TUI 요청의 형태로만 남는다.

## 2. 방향

1. 서버가 화면 단위의 스트림을 연다. 보는 사람은 구독만 하고, 진행이나 캡처를 일으키지 않는다.
2. 프레임은 바뀌었을 때만 보낸다. 같은 프레임을 반복해서 보내지 않는다.
3. 머신 진행(MSX·DOS)은 서버의 실행 주체가 정한다. 관전자가 진행 속도를 정하지 않는다.
4. 스트림이 끊기면 TUI 는 마지막 프레임을 "끊김"으로 표시하고, 다시 열리면 최신 프레임 하나부터 받는다. 놓친 프레임을 채우지 않는다.

## 3. 결정이 필요한 것

1. 브라우저 lane 의 "바뀜" 기준. DOM 변화, 화면 픽셀 변화, 탐색 이벤트 중 무엇으로 프레임을 낼지.
2. MSX·DOS 머신을 관전자 없이도 진행시킬지, 관전자가 하나라도 있을 때만 진행시킬지.
3. 프레임 전송 형식. 지금 응답 형식을 SSE 이벤트에 그대로 싣는지, 이미지 바이트를 따로 받는 주소만 알리는지.
4. 스트림 하나에 몇 명까지 붙일지와, 느린 구독자를 어떻게 다룰지.

## 4. 층

결정 1~4 가 정해진 뒤 나눈다. RFC-0480 의 Lz(2초 블록 삭제)는 이 RFC 의 층이 들어간 뒤에 들어간다.
||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2))
=======
---
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
rfc: "0485"
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
rfc: "0482"
========
rfc: "0486"
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
rfc: "0482"
========
rfc: "0486"
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
rfc: "0482"
========
rfc: "0486"
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
title: "브라우저 lane 미러링과 MSX·DOS 관전은 TUI 가 당겨 오지 않고 서버가 프레임을 보낸다"
status: Draft
created: 2026-11-04
updated: 2026-11-04
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480", "msx-surface-focus-mode"]
---

<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
<<<<<<<< HEAD:docs/rfc/RFC-0485-lane-mirroring-and-spectating-stream-frames.md
# RFC-0485 — 미러링과 관전은 서버가 프레임을 보낸다
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
# RFC-0482 — 미러링과 관전은 서버가 프레임을 보낸다
========
# RFC-0486 — 미러링과 관전은 서버가 프레임을 보낸다
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
# RFC-0482 — 미러링과 관전은 서버가 프레임을 보낸다
========
# RFC-0486 — 미러링과 관전은 서버가 프레임을 보낸다
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md
|||||||| parent of 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0482-lane-mirroring-and-spectating-stream-frames.md
# RFC-0482 — 미러링과 관전은 서버가 프레임을 보낸다
========
# RFC-0486 — 미러링과 관전은 서버가 프레임을 보낸다
>>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2)):docs/rfc/RFC-0486-lane-mirroring-and-spectating-stream-frames.md

## 0. 요약

RFC-0480 은 TUI 의 주기 읽기를 모두 없앤다. 그중 두 화면은 "바뀌었다고 알리면 다시 읽는다"로 옮길 수 없다. 보여 주는 것이 계속 바뀌는 화면이라, 알림이 곧 프레임이기 때문이다.

- 브라우저 lane 미러링: Connectors 화면에 브라우저 lane 을 열면 2초 tick 마다 viewport 나 scene 을 다시 읽는다(`Browser_lane_view.cadence_operation`, `bin/masc_tui_types.ml`).
- MSX·DOS 관전: TUI 가 tick 을 POST 해서 머신을 한 단계 진행시키고 그 프레임을 받는다(`Masc_tui_msx_tick`, "The spectator's single advancing POST").

이 RFC 는 두 화면을 서버가 보내는 프레임 스트림으로 바꾸는 방향을 정한다. 운영자 결정(2026-11-04)으로 RFC-0480 의 층에서 빼서 따로 다룬다.

## 1. 지금 상태

| 화면 | TUI 가 하는 일 | 문제 |
|---|---|---|
| 브라우저 lane | 2초 tick 에 viewport 스크린샷이나 scene 을 다시 읽는다. 사용자가 누르는 중이거나 다른 요청이 진행 중이면 건너뛴다 | 브라우저가 안 바뀌어도 2초마다 이미지를 받는다. 2초 사이의 변화는 보이지 않는다 |
| MSX·DOS 관전 | 관전 화면이 열려 있는 동안 tick POST 로 머신을 진행시킨다 | 보는 사람이 머신 진행을 몰고 간다. 관전자가 둘이면 진행도 두 배가 되는지 확인하지 못했다 |

두 화면 모두 TUI 를 닫으면 멈춘다. 서버에는 "누가 보고 있다"는 사실이 TUI 요청의 형태로만 남는다.

## 2. 방향

1. 서버가 화면 단위의 스트림을 연다. 보는 사람은 구독만 하고, 진행이나 캡처를 일으키지 않는다.
2. 프레임은 바뀌었을 때만 보낸다. 같은 프레임을 반복해서 보내지 않는다.
3. 머신 진행(MSX·DOS)은 서버의 실행 주체가 정한다. 관전자가 진행 속도를 정하지 않는다.
4. 스트림이 끊기면 TUI 는 마지막 프레임을 "끊김"으로 표시하고, 다시 열리면 최신 프레임 하나부터 받는다. 놓친 프레임을 채우지 않는다.

## 3. 결정이 필요한 것

1. 브라우저 lane 의 "바뀜" 기준. DOM 변화, 화면 픽셀 변화, 탐색 이벤트 중 무엇으로 프레임을 낼지.
2. MSX·DOS 머신을 관전자 없이도 진행시킬지, 관전자가 하나라도 있을 때만 진행시킬지.
3. 프레임 전송 형식. 지금 응답 형식을 SSE 이벤트에 그대로 싣는지, 이미지 바이트를 따로 받는 주소만 알리는지.
4. 스트림 하나에 몇 명까지 붙일지와, 느린 구독자를 어떻게 다룰지.

## 4. 층

결정 1~4 가 정해진 뒤 나눈다. RFC-0480 의 Lz(2초 블록 삭제)는 이 RFC 의 층이 들어간 뒤에 들어간다.
>>>>>>> 3917a516618 (docs(rfc): renumber lane-mirroring draft 0482 -> 0486 (fixes #48072 CR P2))
