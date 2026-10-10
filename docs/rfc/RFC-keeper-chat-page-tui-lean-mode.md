---
rfc: "keeper-chat-page-tui-lean-mode"
title: "대화 이력 페이지에 TUI 전용 응답 모드를 둔다"
status: Draft
created: 2026-10-11
updated: 2026-10-11
author: claude
supersedes: []
superseded_by: null
related: ["keeper-chat-page-row-content-bound", "tui-lazy-block-projection"]
implementation_prs: []
---

# RFC: 대화 이력 페이지의 TUI 전용 응답 모드

## 0. 요약

`/api/v1/keepers/<k>/chat/history/page`에 요청 파라미터로 TUI가 읽지 않는 행 필드
(`stream_contract`, `transcript_slot`)를 뺀 응답을 받는 모드를 둔다. 기본 응답은
바꾸지 않는다. 대시보드는 지금과 같다. 이 문서는 결정을 받기 위한 초안이고 코드는
바꾸지 않는다.

## 1. 배경 (실측)

측정 조건: 한 대의 Mac, 60x200 PTY, 키퍼 `e-masc-the-leader`, 2026-10-10~11.
TUI는 main에 #42262, #42275, #42204를 합친 빌드. 이력 서빙은 스텁 프록시(라이브
스트림 끊음).

### 1.1 응답에서 TUI가 안 읽는 부분

이력 4563행(JSON 8.9MB) 샘플. 행당 필드를 `masc_tui_keeper_chat_history.ml`의 디코더와
대조했다.

| 필드 | 이슈 #42200의 페이지 크기 비중 | TUI가 읽는가 |
|---|---|---|
| `stream_contract` | 25% (106KB / 403KB) | 아니오 |
| `transcript_slot` | 6% (25KB) | 아니오 |
| `delivery_key` | 7% (28KB) | 예 (`delivery_key`로 읽음) |
| `content` | 25% (102KB) | 예 |

두 필드를 지우면 JSON 바이트가 약 30% 줄었다.

### 1.2 지연에 미치는 효과 (상한)

같은 TUI exe로 원본 이력과 두 필드를 지운 이력을 번갈아 10쌍 쟀다. 측정 중 머신 load
average가 23~188(중앙값 72)이라 키 응답 70개 이상인 쌍은 구간마다 5~6쌍이었다.

| 구간 | 지표 | 원본 | 필드 제거 | 쌍별 차이 중앙값 | 제거본이 낮은 쌍 |
|---|---|---|---|---|---|
| 첫 PageUp (5쌍) | p95 | 31.9ms | 22.1ms | -9.8 | 5 / 5 |
| 첫 PageUp | p99 | 41.9ms | 36.9ms | -5.9 | 3 / 5 |
| PageDown (6쌍) | p95 | 11.7ms | 9.2ms | -1.8 | 6 / 6 |
| 두 번째 PageUp (5쌍) | p99 | 9.4ms | 8.0ms | -1.7 | 4 / 5 |

방향은 일관되게 낮은 쪽이다. 표본이 작아서 크기는 확정하지 못한다. 첫 PageUp p99는
36.9ms로 목표 20ms에 못 미친다. 이 모드만으로 목표에 닿지는 않는다.

### 1.3 이전 안이 못 얻은 근거

#42217(큰 tool 행 본문 상한)은 CPU 시간과 첫 PageUp 지연 둘 다에서 차이를 못 보였다.
응답 크기를 줄이는 이유가 "큰 행 몇 개"가 아니라 "모든 행의 반복 필드"일 수 있다는
것이 이 문서의 가설이다.

## 2. 제안

요청에 `?lean=1`을 받으면 각 행에서 `stream_contract`와 `transcript_slot`을 싣지 않는다.
`lean`이 없거나 `0`이면 지금과 같다. 알 수 없는 값은 400으로 거절한다(기존 `limit`
파라미터의 정책과 같다).

TUI는 `fetch_keeper_chat_history_page`에서 `lean=1`을 보낸다. `/chat/history`(꼬리 창)는
소비자가 대시보드라서 이 문서의 범위가 아니다.

## 3. 제약과 위험

- 대시보드는 `stream_contract`를 읽는다(`keeper-chat-history.ts`, `keeper-state.ts`).
  `lean`은 TUI만 보낸다. 대시보드는 `lean`을 보내지 않으므로 영향이 없다.
- TUI가 나중에 `stream_contract`나 `transcript_slot`을 읽게 되면 그 시점에 이 모드가
  조용히 값을 빼 버린다. 디코더가 필드의 부재를 오류로 보는지, 기본값으로 메우는지를
  확인해야 하고, 메우면 안 된다(없음과 비어 있음을 구분한다).
- 서버 구현은 행을 직렬화하는 자리에서 두 필드를 건너뛰는 것이어야 하고, 완성된 JSON에서
  지우는 후처리가 아니어야 한다.

## 4. 열린 질문

1. 파라미터 이름과 형태(`lean=1`, `fields=...`). 필드 목록을 받는 쪽이 더 일반적이지만
   계약이 넓어진다.
2. `delivery_key`(7%)와 `blocks`, `skill_activations`도 화면에 쓰이는지 같은 대조가
   필요하다. 이 문서는 TUI가 읽지 않는 두 필드만 다룬다.
3. 부하가 낮은 상태에서의 재측정. 1.2의 표본은 5~6쌍이다.

## 5. 검증 계획

- 서버: `lean=1`일 때 두 필드가 없고 나머지는 같다는 테스트, `lean=2` 거절 테스트,
  `lean`이 없을 때 응답이 바뀌지 않는 테스트.
- TUI: `lean=1` 응답을 디코드해서 기존 행과 같은 `msg_entry`가 나오는 테스트.
- 재측정: 같은 PTY 드라이버와 스텁으로 12쌍 이상, load average 30 미만에서.
