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

## 5.2 다른 화면들 (2026-09-04, load 85)

`--scenario surfaces` (#32898) 가 링 열 곳을 돌며 잽니다. build, 회차 1220 프레임:

| 화면 | p50 | p95 | p99 | max |
|---|---|---|---|---|
| approvals | 0.44ms | 1.98ms | 2.67ms | 3.34ms |
| acting | 0.44ms | 2.14ms | 2.78ms | 3.43ms |
| config | 1.02ms | 1.99ms | 2.98ms | 5.14ms |
| memory | 0.75ms | 1.86ms | 2.37ms | 2.57ms |
| planning-list | 2.21ms | 3.69ms | 4.48ms | 4.88ms |
| runtime | 2.17ms | 4.07ms | 5.31ms | 5.46ms |
| overview | 1.80ms | 3.28ms | 5.42ms | 594ms (첫 프레임) |
| keeper-list | 1.12ms | 3.34ms | 5.55ms | 6.87ms |
| board-list | 2.39ms | 5.18ms | 7.36ms | 7.51ms |
| repositories | 0.64ms | 3.04ms | 17.17ms | 19.00ms |

전체 build p50 1.30ms · p95 3.50ms · p99 5.44ms. 다른 회차(load 205)는 p99 4.66ms 로 더 낮고,
화면별로도 대부분 2ms 아래입니다.

**첫 프레임을 빼면 열 화면 모두 16ms 예산 안입니다.** repositories 의 p99 17.17ms 는 117 프레임 중
한 프레임짜리 꼬리입니다.

부하가 240 을 넘는 회차에서는 같은 바이너리가 planning-list p99 86.91ms, runtime 125.43ms 로
벌어집니다. 이전 판의 이 표는 그런 부하(400~500)에서 잰 상한이었고, 지금 표가 그것을 대체합니다.
화면 사이 차이보다 부하 사이 차이가 훨씬 큽니다.

## 5.3 조용한 기계에서 잰 값 (2026-09-04)

다른 세션들이 빌드를 멈춘 새벽, load average 12~23 구간에서 잰 값입니다.
채팅 화면, 561행 대화, 80x240, 두 회차:

| | p50 | p95 | p99 | max |
|---|---|---|---|---|
| build (keeper-message, 1004 프레임) | 1.46ms | 2.55ms | **7.09ms** | 18.83ms |
| 2회차 (991 프레임) | 1.53ms | 2.95ms | **6.98ms** | 19.27ms |

키를 누르고 첫 바이트가 나오기까지 (1회차):

| 동작 | p50 | p95 | p99 | max |
|---|---|---|---|---|
| PgUp | 2.3ms | 16.9ms | 19.0ms | 19.9ms |
| PgDn | 1.6ms | 15.3ms | 20.8ms | 21.3ms |
| 휠 위 | 1.6ms | 11.1ms | 16.6ms | 21.4ms |
| 휠 아래 | 1.6ms | 13.1ms | 15.7ms | 16.7ms |
| 타이핑 | 1.5ms | 10.3ms | 16.0ms | 17.4ms |
| 붙여넣기 | 4.3ms | 4.7ms | 4.7ms | 4.7ms |

키 120개에 프레임 120~129개 — 삼켜진 키가 없으니 지연값이 키마다 제 프레임을 가리킵니다.

**build 는 p99 에서 예산 안에 들어옵니다.** 지연의 p99 16~25ms 는 계산이 아니라 루프 간격입니다.
루프가 16ms 마다 깨므로, 깨어난 직후 도착한 키는 다음 깨어남까지 기다립니다. 16ms + build 몇 ms
가 이 설계의 바닥이고, 지금 값이 그 바닥에 붙어 있습니다.

부하가 80 을 넘으면 같은 바이너리가 p99 45~75ms 로 벌어집니다. 그때의 숫자는 코드가 아니라
기계를 재는 것이고, 하네스가 `STARVED` 로 그렇게 말합니다.

## 5.4 남은 것

가장 비싼 프레임 두 개는 둘 다 **한 세션에 한 번**입니다.

- 채팅을 처음 열 때: 대화가 바뀌면 창 밖 항목까지 전부 만듭니다. 조용할 때 18.8ms,
  부하 200 에서 130ms. 창에 닿는 항목만 만들면 없어지지만, `Message_layout.entry` 를
  지연 생성으로 바꾸는 일이라 별도 RFC 감입니다.
- 첫 화면을 그릴 때: overview 첫 프레임이 190ms~2.6초. 회차별로 8배 넘게 흔들려서
  코드 비용이 아니라 프로세스가 아직 안 올라온 시간으로 보입니다. 재기 전에는 단정하지 않습니다.

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
