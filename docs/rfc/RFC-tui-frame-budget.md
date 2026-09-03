---
rfc: "tui-frame-budget"
title: "TUI 프레임 예산 — 모든 화면에서 build p99 8ms, 입력→화면 p99 20ms"
status: Draft
created: 2026-09-03
updated: 2026-09-03
author: claude
supersedes: []
superseded_by: null
related: ["tui-operator-ia"]
---

# RFC: TUI 프레임 예산 (tui-frame-budget)

## 1. 문제

스크롤, 방향키, 붙여넣기에 화면이 늦게 따라온다. 2026-09-03 에 라이브 서버와
실제 상태(keeper `analyst` 채팅 561행, 637 KB)로 잰 값이다. 터미널 80×240.

| 화면·동작 | 키 | 프레임 | 입력→첫 출력 p50 | p95 | p99 |
|---|---|---|---|---|---|
| 채팅 PgUp | 120 | 77 | 37ms | 87ms | 104ms |
| 채팅 PgDn | 120 | 40 | 70ms | 135ms | 150ms |
| 채팅 휠 위 | 150 | 134 | 53ms | 216ms | 346ms |
| 채팅 휠 아래 | 150 | 178 | 34ms | 64ms | 74ms |
| 채팅 타이핑 | 120 | 70 | 32ms | 62ms | 63ms |
| 채팅 붙여넣기 300줄 | 3 | 164 | 66ms | 125ms | 125ms |

TUI 자체 시계(`MASC_TUI_FRAME_TIMING`)로 잰 프레임 비용:

| 단계 | 프레임 | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|
| build (채팅 위주) | 958 | 67ms | 64ms | 133ms | 167ms | 653ms |
| present | 958 | 0.55ms | 0.16ms | 0.67ms | 6.6ms | 113ms |
| build (Overview 만) | 603 | 1.2ms | 0.65ms | 1.3ms | 2.3ms | 272ms |

렌더 루프는 16ms 간격으로 입력을 모아 그린다(`Masc_tui_render_schedule`).
build 가 64ms 면 키 4개에 프레임 하나가 나가고, 그 사이 들어온 키는 다음
프레임까지 기다린다. 터미널에 쓰는 present 는 행 diff 라 비용이 아니다.

## 2. 원인

CPU 샘플(macOS `sample`, 12초)의 최상위 세 심볼이 전부 stdlib 리스트 함수다.

| 심볼 | 샘플 | 호출 자리 |
|---|---|---|
| `List.remove_assoc` | 1725 | `Masc_tui_types.chat_projected_timeline_ats` 의 `floors` assoc 리스트 |
| `List.flatten` | 926 | `chat_timeline_rows`, `keeper_message_visible_timeline` |
| `List.combine` | 514 | `chat_timeline_rows`, `keeper_message_visible_timeline` |

채팅 화면 한 프레임에 전체 transcript 위에서 이 계산이 3~4번 돈다.

1. `chat_rows_for` → `chat_timeline`: 행마다 `items @ [row]` 와 turn 탐색. O(n²).
2. `chat_timeline_rows`: turn 마다 `chat_projected_timeline_ats` (request_id 별 assoc
   리스트에 `remove_assoc`), 그 뒤 `List.stable_sort`.
3. `keeper_message_visible_timeline`: 정렬된 전체 목록 위에서 `chat_projected_timeline_ats` 를
   한 번 더. `render_keeper_message` 는 이 함수를 직접 한 번, `keeper_message_layout_entries`
   를 통해 또 한 번 부른다. `chat_rows_for` 는 pin 계산에서 한 번 더.
4. `keeper_message_layout_entries` 는 화면에 보이든 말든 n 개 메시지 전부의 layout entry 를
   만든다. 그 다음 `Message_layout.clamped_scrolled_rows` 가 뒤에서부터
   `requested + height` 행까지 걷는다. 마크다운 캐시는 128개짜리 리스트 LRU 라
   한 프레임이 128개 넘게 방문하면 전부 miss 다.

이 계산은 상태가 안 바뀐 프레임(2초 tick, 비동기 메시지 도착)에도 똑같이 돈다.

## 3. 예산

측정 조건: 80×240, 라이브 base path, 500행 이상 채팅. `scripts/tui-frame-latency.py` 로 잰다.

| 지표 | 목표 |
|---|---|
| build p99 (화면별) | ≤ 8ms |
| 입력→첫 출력 p99 (휠·PgUp·타이핑) | ≤ 20ms |
| present p99 | 지금 그대로 (≤ 7ms) |

8ms 는 16ms 간격의 절반이다. 그래야 키가 25ms 간격으로 와도 프레임이 밀리지 않는다.

## 4. 하네스 (이 RFC 의 첫 PR)

- `scripts/tui-frame-latency.py`: PTY 로 TUI 를 띄워 시나리오(Overview j/k, Keepers j/k,
  채팅 PgUp/PgDn/휠/타이핑/붙여넣기)를 보내고 키마다 첫 출력까지의 지연을 잰다.
  프레임 수와 바이트를 같이 내서, 아무것도 안 움직인 시나리오가 빠른 걸로 읽히지 않게 한다.
- `Masc_tui_frame_timing`: build/present 샘플에 화면 `surface_key` 를 태그해서
  리포트가 화면별 p50/p95/p99 를 낸다. 순수 `Samples` 모듈로 리포트 모양을 테스트한다.

## 5. 단계와 결과

| PR | 내용 | 채팅 build p50 / p95 / p99 |
|---|---|---|
| 시작 | | 64 / 133 / 167 ms |
| #32839 | 화면별 프레임 측정 + PTY 지연 하네스 | 측정 도구 |
| #32847 | 행 투영을 바뀔 때만 계산 | |
| #32851 | 대화 조립을 O(n) 으로 | 44 / 277 / 603 ms |
| #32854 #32872 | 굶주린·빈 실행을 하네스가 판정 | 측정 도구 |
| #32862 | 링크 스캔이 본문을 자르지 않는다 | 17 / 111 / 129 ms |
| #32878 | 항목을 입력이 바뀔 때만 다시 만든다 | 6.6 / 84 / 101 ms |
| #32886 | 그려둔 행 저장소가 걷지 않고 찾는다 | |
| #32908 | 항목을 메시지 단위로 물려받아 append 를 새 행만큼만 만든다 | |
| #32896 | 스크롤한 프레임은 창만 배치한다 | 아래 A/B |

위 숫자들은 load average 가 170 근처였던 때의 값입니다. 그 뒤 이 기계의 부하가 400~500 대로
올라가서 같은 절대값이 다시 나오지 않습니다. 그래서 마지막 단계는 절대값 대신 **같은 트리에서
한 줄만 되돌린 두 바이너리를 번갈아 돌린 A/B** 로 적습니다.

## 5.1 #32896 A/B (load 407~483, 3회 교차)

채팅 화면 build, keeper-message 태그만:

| 회차 | 창만 배치 | 거리만큼 배치 |
|---|---|---|
| 1 | 2.86 / 36.5 / 87.0 ms | 4.13 / 102.7 / 302.2 ms |
| 2 | 2.95 / 37.6 / 155.6 ms | 3.56 / 114.5 / 212.3 ms |
| 3 | 2.86 / 47.1 / 106.5 ms | 6.01 / 74.8 / 158.0 ms |

(p50 / p95 / p99). 세 회차 모두 세 통계 전부에서 창 쪽이 낮습니다. 중앙값으로 p95 는 2.7배,
p99 는 2.0배 차이입니다. 키를 누르고 화면이 움직이기까지의 중앙값은 창 8·18·9ms, 거리 19·13·53ms.

두 바이너리는 `bin/masc_tui_render.ml` 의 walk 대상 한 줄만 다릅니다. 그 한 줄이 프레임마다 새
리스트를 넘기면 행수 보관이 매번 비므로, 되돌린 쪽은 `row_counts` 가 통째로 꺼진 상태와 같습니다.

## 5.2 다른 화면들

`--scenario surfaces` (#32898) 가 링 열 곳을 돌며 잽니다. 이 기계는 다른 세션의 빌드와 로컬 모델
서버 때문에 load average 가 40~530 을 오갑니다. 그래서 아래는 **측정이 아니라 상한**이고, 회차별
최솟값입니다.

| 화면 | p50 | p95 | p99 |
|---|---|---|---|
| acting | 0.36ms | 1.68ms | 2.30ms |
| keeper-list | 0.83ms | 1.72ms | 2.50ms |
| repositories | 0.86ms | 3.32ms | 8.46ms |
| config | 0.59ms | 3.45ms | 9.52ms |
| memory | 0.91ms | 3.61ms | 8.31ms |
| approvals | 0.58ms | 3.91ms | 8.58ms |
| runtime | 0.70ms | 9.02ms | 10.91ms |
| planning-list | 0.81ms | 14.20ms | 37.82ms |
| overview | 2.58ms | 22.19ms | 61.70ms |
| board-list | 0.72ms | 31.99ms | 62.73ms |

주기 갱신을 끄고(`--refresh 120`) 같은 부하에서 다시 재면 board 의 p95 가 31.99 → 11.38ms,
planning 이 14.20 → 6.69ms 로 내려갑니다. 즉 이 화면들의 꼬리는 스크롤 프레임이 아니라 **2초마다
새 데이터가 도착한 프레임**입니다. 채팅이 가졌던 "모든 프레임이 비싼" 구조적 비용은 이 화면들에
없습니다. 같은 실행 안에서 가장 싼 화면(acting) 대비 p95 는 1~2배 수준입니다.

예산을 숫자로 확정하려면 조용한 기계에서 한 번 더 재야 합니다. 남은 후보는 두 가지입니다.
갱신 프레임이 파생 상태를 다시 만드는 자리와, Overview 의 p50 (다른 화면의 세 배).

## 6. 검증

- PR 마다 §1 표를 같은 조건으로 다시 재서 본문에 붙인다.
- `test_tui_chat_queue_wiring`, `test_tui_http_ast` 등 기존 Alcotest 와 PTY 시나리오는 그대로 통과.
- PR 2 는 예전 투영과 새 투영을 같은 입력에 돌려 결과가 같은지 비교하는 테스트를 넣는다.

## 7. 트레이드오프

- memo 는 상태 하나를 더 든다. 대신 `render` 가 순수 함수라는 성질은 유지한다(캐시는 입력의
  물리 동일성으로만 유효하고, 렌더가 authority 를 고치지 않는다).
- 걷는 창을 한정하면 "검색이 몇 번째 물리 행에 있나" 를 셀 때 전체 layout 이 필요하다.
  그 경로는 검색 때만 전체를 걷는다.
- 8ms 는 라이브 상태 기준이라 더 큰 transcript(수천 행)에서는 다시 재야 한다. 그때는
  PR 3 의 창 한정이 효과를 낸다.
