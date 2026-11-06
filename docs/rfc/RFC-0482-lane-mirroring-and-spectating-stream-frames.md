---
rfc: "0482"
title: "브라우저 lane 미러링과 MSX·DOS 관전은 TUI 가 당겨 오지 않고 서버가 프레임을 보낸다"
status: Draft
created: 2026-11-04
updated: 2026-11-05
author: vincent + claude
supersedes: []
superseded_by: null
related: ["0480", "msx-surface-focus-mode"]
---

# RFC-0482 — 미러링과 관전은 서버가 프레임을 보낸다

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

## 3. 구현 결정 (2026-11-05)

1. **Browser scope.** 구독은 `source`, 선택한 `clientId`, `tabId`, 읽기 view, scene view/scope를 정확히 지목한다. 다른 대상의 알림은 읽지 않는다. 이미지 viewport도 같은 identity를 쓴다.
2. **변경의 정본.** 서버는 선택 대상을 2초마다 한 번씩 읽고, `elapsed_ms`를 뺀 정본 응답의 SHA-256 revision이 바뀔 때만 `browser_observation`을 낸다. 현재 worker snapshot에는 tab/document/scene revision이 없고 backend 공통 native DOM event도 없으므로, 이 층에서는 서버 관측으로 변경을 발견한다. 이 제한을 native push라고 부르지 않는다. TUI 주기 HTTP 읽기와 그 fallback은 없다. observer가 닫히면 서버 관측도 멈춘다.
3. **전송.** SSE에는 scope와 revision만 싣고 page text·scene·PNG bytes는 싣지 않는다. TUI는 일치하는 알림을 받으면 기존 read/scene/screenshot 경로로 정본을 읽는다. 첫 응답, `r`, 명시적 tab/client 전환, 재연결 재검증은 유지한다. single-flight와 trailing read, 실패 백오프, observer gap 재검증을 공유한다. pointer press·URL 초안·client picker·진행 중 요청은 관측 구독도 멈춘다.
4. **Machine.** 현재 `Control_machine`에서만 observer query로 machine을 선택하고 서버 ticker를 둔다. Observe 모드와 checkpoint 전에는 ticker를 멈춘다. 기존 `Machine_live` 변경 알림의 incarnation/evidence 비교와 단일 읽기를 쓰며, `/api/v1/msx/tick`은 사용하지 않는다.
5. **연결 수명.** 기존 observer 연결·cursor·backpressure·재연결 정책을 공유한다. 새 병렬 평면 스트림이나 전용 환경 변수는 두지 않는다. 실제 Browser 종류별 변경 완전성과 서버 관측 비용은 fixture와 분리해 기록한다.

## 4. 검증 층

- dataset/query/scope 거절, request identity, `elapsed_ms` 제외 revision, observer 종료 후 관측 정지.
- TUI 선택·재연결·pointer/draft 소유권과 다른 client/tab 무응답.
- 실제 PTY에서 고정 idle 무요청, 정확한 변경 한 번, burst trailing 한 번, 실패 재시도, reconnect 재검증, `/api/v1/msx/tick` 0회.
- 서버 native 이벤트가 아니라 관측이라는 제한과 실제 backend 미검증 범위를 증거에 함께 남긴다.
