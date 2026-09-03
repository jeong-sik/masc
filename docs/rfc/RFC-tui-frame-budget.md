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

## 5. 단계

| PR | 내용 | 기대 |
|---|---|---|
| 0 | 하네스 + 화면별 타이밍 + 이 문서 | 이후 PR 마다 같은 표를 붙인다 |
| 1 | 채팅 투영을 프레임당 한 번만 계산하고, 입력 리스트가 물리적으로 같으면 이전 결과를 쓴다 | 채팅 build p50 64ms → 수 ms |
| 2 | `chat_timeline`·`chat_projected_timeline_ats` 를 O(n) 으로 (Hashtbl, rev-append) | 첫 계산·재계산 비용 |
| 3 | `keeper_message_layout_entries` 를 walk 창으로 한정, 마크다운 캐시를 Hashtbl LRU 로 | 깊은 스크롤 |
| 4 | 다른 화면을 같은 하네스로 재고 8ms 넘는 화면을 고친다 | 전 화면 |

PR 1 은 `chat_rows_for` 의 결과가 상태 변화 없이는 바뀌지 않는다는 사실만 쓴다.
memo 키는 `msg_loaded`, `msg_history`, `msg_queued`, inflight, 가시성 토글의 물리 동일성.
파생 상태는 authority 로 재저장하지 않는다(projects.md 의 파생 상태 규칙).

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
