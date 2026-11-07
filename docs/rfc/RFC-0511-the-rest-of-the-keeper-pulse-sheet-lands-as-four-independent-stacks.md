---
rfc: "0511"
title: "Keepers 목록의 남은 시안 항목은 갈래 넷의 독립 스택으로 올린다"
status: Accepted
created: 2026-11-07
updated: 2026-11-07
author: claude
supersedes: []
superseded_by: null
related: ["0503", "0418", "0480", "0481", "tui-operator-workbench"]
---

# RFC-0511 — Keepers 목록의 남은 시안 항목은 갈래 넷의 독립 스택으로 올린다

- Status: **Accepted (2026-11-07).** 운영자가 이 RFC 의 병합과 구현 착수를 지시했다. 병합은 §7 의 기본값을 받아들인다는 뜻이다. 다른 값을 원하면 이 RFC 를 고치는 PR 로 바꾼다.

## 0. 요약

- 시안 `Keeper Pulse`(Artifact 3판, 2026-11-06)의 데이터 표는 14행이다. main `3519bd8c658` 과 맞춰 보면 들어간 것이 1행, 일부 들어간 것이 3행, 서버 값을 기다리는 것이 2행이다. RFC-0503 §4 가 범위 밖으로 둔 것이 7행이고, 맡은 층이 없는 것이 1행이다.
- 이 RFC 는 남은 13행을 네 갈래로 나눈다. K 는 Keepers 목록의 글(TUI 만), S 는 roster 행에 더하는 서버 투영, A 는 행의 둘째 줄에 붙는 칸(일정 · 기억 읽기), W 는 기억 서버(나이 사다리 · 월드)다. 갈래마다 스택 하나를 두고, 갈래끼리 고치는 파일이 겹치지 않게 선을 긋는다. 겹치는 곳은 둘째 줄 함수 하나뿐이고 §5.2 에 적었다.
- 서버 값을 화면에 그리는 층 둘(D1 D2)은 2차 착수다. 앞 층이 main 에 오른 뒤에 시작한다.
- 나이는 값이다. stale 은 서버가 닫힌 값으로 적은 것에만 쓴다(RFC-0418). 모르는 값은 0 이 아니라 표지로 그린다.
- 대조에서 사실 넷이 나왔다. 서버는 한도 해제 시각과 그 출처를 이미 내고 TUI 는 출처를 버린다. `failing_since` 는 서버 어디에도 없다. 쉬는 시각은 `HH:MM` 이 아니라 날짜가 붙은 19칸 글이다. RFC-0503 §6.5 의 "서버는 해제 시각을 내지 않는다"는 main 보다 낡았다.
- 운영자가 이 RFC 의 병합과 구현 착수를 지시했다(2026-11-07). RFC-0503 §5 의 "층마다 범위를 먼저 승인받는다"를 이 RFC 의 §3 층 표로 대신한다. 구현 PR 의 병합은 따로 정한다.

## 1. 지금

### 1.1 시안 14행과 main

시안은 설계 보조 자료이고 실행되는 TUI 가 아니다. 값은 2026-11-06 13:30 KST 한 시점의 스냅샷이다. 시안의 "어디까지 진짜인가" 표가 14행이고, 단계는 세 가지다. A 는 지금 데이터로 된다. B 는 화면이 요청할 때 가져온다. C 는 서버 필드가 필요하다.

비교한 main 은 `3519bd8c658` 이다. 칸마다 그 커밋에서 `git grep` 으로 읽었다.

| # | 시안 항목 | 단계 | main `3519bd8c658` | 이 RFC |
| --- | --- | --- | --- | --- |
| 1 | 지금 단어 분리 | A | 들어갔다. 건강은 활동이 아니고, 열린 턴의 시도 실패는 `Attempt_failed` 다(RFC-0503 L2, #49256) | — |
| 2 | 원인 묶음 · 시도 사슬 `✗ › ✗` | A | 일부. 종착 원인을 typed 로 읽어 행마다 원인 낱말을 쓴다(L3 #49361, `bin/masc_tui_render_keepers.ml:99`). 80칸에서는 DETAIL 칸이 좁아 긴 낱말이 잘리고(셈, §2.3 K1), 시도 사슬은 그리지 않는다 | K1 K3 |
| 3 | 다음 `▹` · `◌` | A | 일부. 쉬는 runtime 하나만 DETAIL 에 `쉬는 중 ~YYYY-MM-DD HH:MM:SS (runtime)` 으로 그린다(#49568, `bin/masc_tui_render_keepers.ml:285`). 줄 안 `▹` 표지는 없다 | K2 |
| 4 | 한도가 풀리는 시각 | C | 일부. 서버가 `release_at` 과 `release_basis` 를 낸다. TUI 는 시각만 그린다(§1.2 ①) | K2 |
| 5 | 12시간 맥박 | C | 없다. roster 행에 최근 턴 결과가 없다 | S1a S1b D1 |
| 6 | 사람이 움직임(빨강) | C | 없다. roster 행에 사람 몫인지 가르는 값이 없다. 영수증에는 있다(§1.2 ⑤) | S3 S3d |
| 7 | failing since | B | 없다. `failing_since` 는 `lib` · `bin` · `test` 어디에도 없고 문서에만 있다(`rg` 0건) | S2 D1 |
| 8 | 눈금 `◷` · 늦음 | A | RFC-0503 §4 가 범위 밖으로 뒀다. Keepers 목록 코드가 일정 응답을 읽지 않는다 | A1 A2 |
| 9 | wake 줄(마지막 실행) | B | 〃 | A1 A2 |
| 10 | lag · gap · digest 줄 | A | 〃. 기억 응답도 읽지 않는다(§1.2 ⑥) | A3 A4 A5 |
| 11 | 갱신 시계 `+ 47m` · `+1 −0` | A | 〃 | A3 A4 A5 |
| 12 | stale ×N(근거 무효화) | B | 〃 | A3 A4 A5 |
| 13 | 사실 나이 사다리 · `absent` | C | 〃. 서버에 사다리가 없다 | W1 W2 D2 |
| 14 | 월드 `current` · `stale` · `building` | C | 〃. 서버에 월드 읽기 경로가 없다 | W3 W4 D2 |

### 1.2 대조에서 나온 사실

1. 서버는 한도 해제 시각과 그 출처를 이미 낸다. 쉬는 중인 Keeper 의 행은 `release_at` 과 `release_basis` 를 싣는다(`lib/keeper/keeper_tool_surface_ops.ml:314`). `release_basis` 는 `Stated_by_provider` 와 `Bounded_by_masc` 둘 중 하나다(`lib/keeper/keeper_turn_driver.ml:345`). TUI 는 `release_at` 만 그리고 출처를 버린다(`bin/masc_tui_render_keepers.ml:292` 의 `release_basis = _`). 제공자가 말한 시각과 MASC 가 정한 상한이 같은 글로 보인다. 시각은 `lib/tui_terminal_text.ml:490` 의 `short_timestamp_of_unix_for_terminal` 이 만드는 19칸 글(`YYYY-MM-DD HH:MM:SS`)이다.
2. `Detailed` 의 둘째 줄은 DETAIL 글만 그린다(`bin/masc_tui_render_keepers.ml:421`). 시도 사슬을 그릴 자리는 이미 있다.
3. RFC-0503 §6 의 다섯째 후보("서버는 날짜 없는 한도의 해제 시각을 일부러 내지 않는다")는 main 보다 낡았다. 서버는 제공자가 끝을 말하지 않은 쉼에도 MASC 가 정한 시각을 내고 출처를 `Bounded_by_masc` 로 적는다(`lib/keeper/keeper_tool_surface_ops.ml` 의 `runtime_path_rest_json` 앞 주석). 그래서 그 후보는 서버 일이 아니라 TUI 일(K2)이다. `runtime_path_rest` 는 모든 행에 실린다(`lib/keeper/keeper_tool_surface_ops.ml:447`).
4. 오늘 다른 세션이 같은 영역을 먼저 고쳤다. 리셋 시각을 말한 한도 거절은 실패가 아니라 쉬는 중으로 끝난다(#49567). 쉬는 walk 의 해제 시각과 출처가 행에 실린다(#49568). 요약 줄의 좁은 폭 숫자 잘림이 풀렸다(#49560 #49594 #49611). RFC-0503 §1.2 의 "15행 모두 `provider`" 읽기는 이 변경 전 값이다. 지금 failing 행의 구성이 같다고 가정하지 않고, 캡처는 변경 뒤 코드로 다시 찍는다.
5. 영수증은 `operator_disposition` 을 이미 싣는다. 행 빌더는 가장 최근 영수증 JSON 을 이미 읽는다(`lib/keeper/keeper_tool_surface_ops.ml:386`). 그 값은 roster 행에 실리지 않는다. 같은 값을 trust 쪽이 따로 읽는 비공개 파서가 있다(`lib/keeper/keeper_runtime_trust_snapshot.ml:245`).
6. `+ 47m`, `+1 −0`, `stale ×N` 의 재료는 `keeper-memory-health` 행에 이미 있다(`updated_at`, `added`, `removed`, `source_invalidations`; `lib/server/server_dashboard_http_keeper_memory_health.ml:745`). 서버에 새로 필요한 것은 나이 사다리와 월드 읽기 경로다. Keepers 목록은 이 응답을 읽지 않는다. `memory_health_on_screen` 이 `Memory` 와 `Metrics` 에서만 읽기를 켠다(`bin/masc_tui.ml:9517`).
7. 일정도 비슷하다. 목록 행은 일정을 읽지 않지만 TUI 는 모든 화면에서 갱신되는 fleet 첫 쪽 `schedules_agenda` 를 이미 들고 있다(`bin/masc_tui_types.ml:10258`). `◷` 는 이미 일정 배지 글리프다(`bin/masc_tui_keeper_mark.ml:51`).

## 2. 제안

### 2.1 공통 규칙

네 갈래가 같은 규칙을 지킨다.

1. 나이는 값이고, stale 은 서버가 적은 상태다. `stale` 은 서버가 닫힌 값으로 적은 무효화(`source_changed` · `source_unavailable`)와 브리핑 신선도 `Stale` 에만 쓴다. 나이만으로 stale 이라 부르지 않는다(RFC-0418, `lib/keeper/keeper_memory_os_types.mli:333`).
2. 모르는 값은 `?` 나 `모름` 으로 그린다. 0 으로 그리지 않고 빈 칸으로 두지 않는다. 서버가 보내지 않은 시각 · 횟수 · 상태 이름을 TUI 가 지어내지 않는다.
3. roster 행의 값은 읽는 시각에 따라 바뀌지 않는다(RFC-0481 §3.2). 서버는 시각과 사건을 싣고 "몇 분 전" 은 TUI 가 그린다. 그래서 맥박은 시간으로 센 값이 아니라 턴 결과 목록을 싣는다. 나이 사다리(W2)는 roster 가 아니라 health 응답의 값이고 `generated_at` 시점 값이다.
4. 새 필드는 hard cut 이다. 옛 형태를 읽는 코드를 만들지 않는다. 디코더가 모르는 키를 거부하므로 서버 · TUI 디코더 · 웹 스키마를 한 PR 에서 함께 바꾼다.
5. 서버가 더하는 값은 모두 읽기 투영이다. 권위(원장 · 전이 기록 · 영수증 · 결정 로그)에서 계산하고, 권위로 다시 저장하지 않고, 행동을 막거나 고르는 데 쓰지 않는다.
6. 색은 글리프나 낱말과 함께 쓴다. `NO_COLOR=1` 에서도 구분되어야 한다.

선행 사례 셋을 2026-11-07 에 원문으로 확인했다. 모두 위 1 · 2번과 같은 쪽을 가리킨다.

- HTTP 캐시는 `Age` 를 초 단위 숫자로 싣고, stale 은 신선 기간과 견주어 계산한다(RFC 9111 §5.1 · §4.2). 기억 사실에는 신선 기간이 없다. 그래서 나이만으로 stale 을 계산하지 않는다.
- Prometheus 는 대상이 더 이상 없는 시계열을 stale 로 표시해 조회에서 뺀다(`querying/basics` 의 Staleness 절). 시간이 흐른 것이 아니라 원천이 사라진 것이 stale 이다.
- ratatui `Sparkline` 은 값 없음(`None`)을 0 과 다른 기호로 그린다(`widgets::Sparkline` 문서). 맥박과 사다리의 "모름"도 같은 방식으로 그린다.

### 2.2 갈래

| 갈래 | 맡는 행 | 층 | 고치는 곳 | 서버 변경 |
| --- | --- | --- | --- | --- |
| K | 2 3 4 | K1 K2 K3 | `bin/masc_tui_render_keepers.ml` 목록 영역, `bin/masc_tui_render_schedule.ml`, `bin/masc_tui_keeper_trail.ml` | 없다 |
| S | 5 6 7 | S3 S3d S2 S1a S1b | `lib/keeper/` 의 행 투영, `lib/tui_decode.ml`, `dashboard/src/api/schemas/gate-keepers.ts` | roster 행에 필드 셋 |
| A | 8 9 10 11 12 | A1 A2 A3 A4 A5 | `bin/masc_tui_keeper_*` 새 모듈, 둘째 줄 함수 한 곳, `bin/masc_tui.ml` 의 읽기 조건 한 곳 | 없다 |
| W | 13 14 | W1 W2 W3 W4 | `lib/keeper/keeper_memory_age_bins`, `lib/workspace_memory/`, health 서버 · 디코더 | health 행에 필드 하나, 읽기 경로 하나 |

2차 착수는 D1(S 값을 행에 그린다)과 D2(W 값을 Memory 화면과 행에 그린다)다.

### 2.3 K 갈래 — Keepers 목록의 글

**K1. 원인 문장이 DETAIL 칸에서 잘리지 않게 한다**

- 지금: 80칸에서 DETAIL 칸은 22칸이다. NAME 이 16칸을 먼저 가져간다. 문장 머리 `◂ 2m14s · ` 가 10칸이라 원인 낱말에 12칸이 남는다. `recovery needed` 는 15칸, `terminal not observed` 는 21칸이라 `…` 로 잘린다. RUNTIME 칸은 `Detailed` 에서 inner 120칸 이상일 때만 있다. `Compact` 에서는 문장이 어디에도 온전히 나오지 않는다. 숫자는 조사 에이전트가 `bin/masc_tui_render_schedule.ml:142` 부터를 읽고 센 값이고 캡처로 확인하지 못했다.
- 바꾼다: 문장 머리(`◂ ` + 가장 넓은 나이 글 + ` · ` + 원인 낱말)를 행에서 재어 DETAIL 칸의 바닥으로 삼는다. NAME 이 남는 폭을 가져가기 전에 DETAIL 에 준다. 긴 이름은 기존 `fit_middle` 이 가운데를 접는다. 문구는 바꾸지 않는다.
- 하지 않는다: 원인을 문장 맨 앞으로 옮기지 않는다. RFC-0503 §2.2 의 표와 도움말을 함께 고쳐야 한다. "AGE 가 보이면 문장 나이를 뺀다"도 쓰지 않는다. 두 나이는 다른 시계다.
- 확인: 80 · 90 · 120칸 전후 캡처. 열 너비를 숫자로 내는 기존 시험이 깨지면 값만 맞춘다. 새 화면 시험은 더하지 않는다.

**K2. `▹` 다음 걸음과 한도 해제 시각의 출처**

- 지금: `keeper_path_rest_detail` 이 쉬는 runtime 하나만 그리고 `release_basis` 를 버린다(§1.2 ①).
- 바꾼다: `Tui_decode.keeper_path_rest` 를 와일드카드 없이 `match` 하는 `keeper_next_text` 를 둔다.
  - `Path_rest_resting` 은 출처를 말로 가른다. `Stated_by_provider` 는 제공자가 말한 시각, `Bounded_by_masc` 는 MASC 가 정한 상한이다. 낱말은 캡처를 보고 정한다.
  - 시각은 상대 글(`Message_layout.span_text`)로 줄인다. 이미 지난 시각이면 시각을 쓰지 않는다.
  - 조각을 DETAIL 맨 끝으로 옮겨 "오른쪽 = 다음"(RFC-0503 §2.2)을 지킨다.
  - `▹` 는 직전 턴이 실패한 행(`Trail_failed`)에만 단다. 모든 행이 serving 이라 전부에 달면 되풀이다.
  - 쉼 표지로 `◌` 를 쓰지 않는다. `◌` 는 Deferred · Waiting 글리프다(`bin/masc_tui_keeper_mark.ml:33`).
- 확인: 캡처(제공자가 말한 쉼, MASC 상한 쉼, serving, 읽기 실패 행, 해제 시각이 이미 지난 스테일 로스터). 도움말(`docs/TUI-GUIDE.md`)에 두 출처의 뜻을 적는다.

**K3. 시도 사슬 `✗ › ✗`**

- 지금: `Detailed` 의 둘째 줄은 DETAIL 글 한 줄이다(§1.2 ②). 상세 창의 5절은 후보별로 이미 그린다.
- 바꾼다: RFC-0503 L5 를 이어받는다.
  - `bin/masc_tui_keeper_trail.ml` 에 `attempt = { ordinal; runtime_id; dispatch; cause; fault; terminal }` 와 `attempts_of_runtime` 을 더한다. 기존 값은 바꾸지 않는다. 서수당 노드 하나이고 `Walk_ended` 와 `Walk_no_terminal` 일 때만 만든다. 같은 센 법을 쓰는 `tried_of` 와 후보 수가 어긋나지 않아야 한다.
  - 둘째 줄의 왼쪽은 사슬 + 기존 DETAIL 글이다. 폭이 모자라면 DETAIL 글이 먼저 빠진다. 노드 라벨은 `runtime_id` 전체다. TUI 는 id 를 쪼개지 않는다.
  - 노드는 통째로 남기거나 뺀다. 우선순위는 종착 > 다음(K2) > 가까운 이전 시도이고, 뺀 수는 `+n` 으로 말한다. `fault` 가 있으면 낱말 하나를 노드에 붙인다.
- 기대 모양: 후보 셋의 사슬은 id 길이 때문에 약 150칸이다(조사 에이전트의 셈). 120칸 화면의 둘째 줄(113칸)에 다 안 든다. 생략이 평소 모양이다. 200칸에서 읽히는지 캡처로 적는다.
- 글리프: `✗`(`Attempt_failed`, `bin/masc_tui_keeper_mark.ml:27`)를 쓴다. 구분자 ` › ` 는 선택 행 표지와 같은 글자다(`bin/masc_tui_render_keepers.ml:397`). 선택 행은 색이 벗겨지므로(`:1089`) 캡처로 확인한다.
- 확인: `test/test_tui_keeper_trail.ml` 에 `attempts_of_runtime` 의 값 시험(서수 · 종착 · 후보 수 일치)을 더한다. 글 시험은 더하지 않는다. 캡처는 120 · 200칸.
- 링크: `bin/dune` 에 `masc.agent_core.llm_provider` 가 필요한지 빌드 없이 짐작한 것이다. PR 의 `type-check` 로 확인한다.

### 2.4 S 갈래 — roster 행에 더하는 서버 투영

필드를 하나 더할 때 바뀌는 곳은 같다. 기준 사례는 #49568 이고, 서버만 먼저 나가서 TUI 디코더가 열흘간 모르는 키로 넘긴 #46391 이 반면 사례다.

1. 서버 JSON 은 `keeper_list_row_json` 의 목록에 더한다(`lib/keeper/keeper_tool_surface_ops.ml:436`). 오류 행(`:253`)에는 싣지 않는다. 문자열 철자는 타입 옆의 `*_to_wire` · `*_of_wire` 한 쌍으로 둔다.
2. 변경 신호(RFC-0481 §3.2). registry 에서 오는 값은 `row_fields_changed`(`lib/keeper/keeper_registry_setup.ml:46`)에 필드를 넣는다. phase 에 얹히는 값은 필요 없다. 영수증에서 오는 값은 영수증 append 가 이미 낸다(`lib/keeper/keeper_execution_receipt.ml:559`). 맥박은 `Keeper_row_broadcast.changed` 를 직접 부른다. `lib/keeper/keeper_row_broadcast.mli` 의 설명과 RFC-0481 §1.3 의 표를 같이 고친다.
3. TUI 디코더는 `lib/tui_decode.ml(i)` 이고, `keeper_runtime` 리터럴이 있는 시험 픽스처 셋도 고친다(`test/test_tui_keeper_control.ml`, `test/test_tui_keeper_trail.ml`, `test/test_tui_keeper_list_model.ml`).
4. 웹 대시보드 스키마 `dashboard/src/api/schemas/gate-keepers.ts` 는 모르는 키를 거부한다(`onExcessProperty: 'error'`, `:269`). 같은 PR 에서 `Schema.optional` 로 더하고 `schemas/gate-keepers.test.ts` 와 `api/gate-keepers.test.ts` 를 고친다. 이 스키마에는 `runtime_path_rest` 도 없다(`:36`). 실제로 거부하는지는 확인하지 못했다. 거부가 확인되면 이슈로 남기고 이 층에서 고치지 않는다.
5. 시험은 서버 → 디코더 왕복(`test/test_keeper_list_truncation.ml:679` 방식)과 디코더 단독(`test/test_tui_keeper_control.ml:1328` 방식)이다.
6. 층마다 roster 응답 크기를 `bin/masc_http_probe.ml` 로 재서 PR 본문에 적는다. 지금은 40행에 약 9 KB 다(RFC-0481 §1.1).

세 필드는 같은 줄(`keeper_list_row_json` 의 목록, `keeper_runtime` 레코드, 픽스처 셋)을 만진다. 한 에이전트가 S3 → S3d → S2 → S1a → S1b 순서로 쌓는다.

**S3. 사람이 움직여야 하는가 (행 6)**

- 키: `operator_disposition`, `operator_disposition_reason`. 값은 영수증의 닫힌 variant 의 문자열이고, 영수증이 없거나 짝이 깨졌으면 `null` 이다.
- 출처: 행 빌더가 이미 읽는 가장 최근 영수증이다. 영수증을 더 읽지 않는다. trust 스냅숏은 Keeper 마다 승인 큐와 결정 로그 꼬리를 읽으므로 행마다 부르지 않는다.
- 파서는 하나로 합친다. trust 쪽 비공개 `receipt_operator_disposition`(`lib/keeper/keeper_runtime_trust_snapshot.ml:245`)을 `Keeper_execution_receipt` 로 옮기고 양쪽이 쓴다.
- TUI 는 기존 `_of_string` 으로 읽고, 모르는 글자는 그 행 옆에 `Error` 로 둔다(`kr_runtime_path_rest` 와 같은 방식). 사람이 움직이는지는 `needs_operator_broadcast`(`lib/keeper/keeper_execution_receipt.mli:243`)로 TUI 가 가른다.
- 이 값은 가장 최근에 끝난 턴의 영수증이 적은 사실이다. 지금 상태가 아니다. 화면은 영수증 시각을 함께 그린다.
- 이 필드로 이슈 #43018(일곱 블로커 분류의 `disposition_reason`)은 풀리지 않는다. 그 결정은 따로 남는다.

**S3d. 사람 몫인 행의 표지 (행 6의 표시)**

- 가장 최근 영수증이 사람 몫인 행은 `Held_call` 과 같은 글리프 `!` 와 `Theme.bad` 에 낱말 `사람 몫` 을 붙인다. 사람이 움직인다는 뜻이 같아서 글리프도 같다. 원인이 다르므로 낱말로 가른다.
- 그룹 편입과 요약 줄 칩은 바꾸지 않는다(D6). 표지와 색만 바꾼다.
- 확인: 캡처(사람 몫 failing, 일반 failing, `Held_call`)를 색 있음과 `NO_COLOR=1` 로 찍는다.

**S2. 실패가 시작된 시각 (행 7)**

- 키: `failing_since`(unix 초 또는 `null`). 지금 phase 가 `Failing` 이고 그 구간이 시작된 전이의 시각이다. 실패 중이 아니면 `null` 이다.
- 출처: phase 전이 기록이다. `keeper_registry.ml:741` 부터는 phase 가 바뀔 때만 `wall_clock_at_decision` 과 두 phase 를 기록하고, 이 기록은 50칸 링과 durable `Transition_audit` 저장소로 간다. `Failing` 으로 들어가는 전이에서 registry entry 의 값을 세우고, 나가는 전이에서 지운다. phase 변화는 `row_fields_changed` 가 이미 보므로 새 신호는 필요 없다.
- 재시작: entry 를 새로 만드는 두 곳(`lib/keeper/keeper_registry_setup.ml:533` 근처와 재시작 경로)이 필드를 비운다. 시작할 때 durable 전이 기록에서 현재 `Failing` 구간의 시작 전이를 다시 구한다. 기록 범위 안에서 찾지 못하면 `null` 이다. 값을 지어내지 않고 옛 데이터를 소급하지 않는다. 찾지 못한 Keeper 수를 PR 본문에 적는다.
- 건드리지 않는 것: `last_failure.at_unix` 는 최신 실패 시각이라 시작 시각이 아니다. `keeper.turn_failure_streak.v1` 의 schema 는 올리지 않는다. 읽기 실패가 Keeper 등록 실패가 된다(`lib/keeper/keeper_registry_setup.ml:517`).

**S1a. 턴 결과 보관 (행 5)**

- 새 모듈 `lib/keeper/keeper_turn_pulse.ml(i)`. 키(base_path + 이름)별 불변 맵을 Atomic 으로 들고 CAS 로 바꾼다. `lib/keeper/keeper_turn_attempt_observer.ml` 이 본보기다. roster 계산은 executor pool 의 다른 도메인에서 돌므로(`lib/server/server_dashboard_http_runtime_support.ml:17`) 읽는 쪽은 불변 스냅숏만 본다. registry entry 의 필드로 두면 entry 를 새로 만드는 두 곳에서 비워지므로 쓰지 않는다.
- 값: `type outcome = Turn_ok | Turn_rested | Turn_failed`, `type sample = { at : float; outcome : outcome }`. 최신이 앞이고 개수 상한은 이름 붙은 상수다(기본 24).
- 기록 자리: `lib/keeper/keeper_heartbeat_loop_cycle.ml:121` 부터의 턴 결과 `match` 한 곳이다. `Failed` 는 `Turn_failed`, `Completed` · `Checkpointed` · `Input_required` 는 `Turn_ok`, `Rested` 는 `Turn_rested` 다. `Cancelled` 와 `Skipped` 는 이름을 적어 무시한다. 새 갈래가 생기면 컴파일러가 잡는다. 기록 뒤에 `Keeper_row_broadcast.changed` 를 부른다. 영수증 append 와 Owner commit 신호가 이 `match` 보다 먼저 나가서, 부르지 않으면 행이 한 턴 늦다.
- 자율 턴만 센다. 채팅 레인이 빠지는지는 `rg` 로만 확인했으므로 층에서 다시 확인한다. 크래시 사이클(`lib/keeper/keeper_heartbeat_loop.ml:523`)을 포함할지도 층에서 정한다.
- 쉼은 따로 센다. 서버가 "쉼은 실패가 아니다"를 이미 정했다(`lib/keeper/keeper_unified_turn.ml:1202`). 결정 로그에는 쉼도 `error` 로 적힌다.

**S1b. 시드와 JSON (행 5)**

- 시드: 시작할 때 결정 로그 `decisions.jsonl` 과 `.1` 에서 12시간 안의 `event=turn` 행을 `Keeper_decision_outcome.of_string` 으로 읽어 채운다. 로그에서 온 샘플은 `rested` 가 될 수 없다. 로그 append 가 기록보다 먼저라서 시드는 레인이 뜨기 전에 해야 중복이 없다. 부트스트랩 후보는 `lib/server/server_bootstrap_maintenance.ml:659` 이고, 레인보다 먼저 도는지는 확인하지 못했다. 꼬리 읽기 전례는 `Keeper_memory.read_file_tail_lines_with_completion` 이고 `max_bytes` 는 1 MB 이상이어야 한다(`lib/keeper/keeper_runtime_trust_snapshot.ml:336`).
- 키: `recent_turns`. `null` 이면 시드하지 못한 것(모름)이다.
  ```json
  { "truncated": false, "turns": [[1794037335, "ok"], [1794036000, "failed"]] }
  ```
  `turns` 는 최신이 앞이고 `[unix 초, "ok" | "rested" | "failed"]` 쌍이다. `truncated` 는 개수 상한 때문에 더 오래된 턴이 빠졌다는 뜻이다. 서버는 시간으로 자르지 않는다. 12시간 창은 TUI 가 샘플 시각으로 자른다(공통 규칙 3).
- 크기: 쌍 24개는 한 행에 약 0.5 KB 로 40행에 약 20 KB 다(추정). PR 본문에 잰 값을 적고, 전체가 지금의 몇 배가 되는지 함께 적는다.
- 측정 근거: 이 장비의 결정 로그 39개를 집계했다. 12시간 턴 수는 Keeper 당 최대 272, p90 165, 중앙 13이고 50턴을 넘는 Keeper 가 6명이다. 마지막 50턴 링으로는 이 6명이 12시간을 못 덮는다. 그래서 `truncated` 를 싣는다. 한 장비 한 시점의 값이다.
- 기존 `Keeper_transition_audit` 링(50칸)을 쓰지 않는 이유: `Turn_substantive` 와 `Turn_failed` 는 turn_phase 분류라 실패 턴이 substantive 로 남을 수 있고, 쉼 갈래가 없고, Hashtbl 과 가변 배열이라 다른 도메인에서 읽으면 안전하지 않다.

### 2.5 A 갈래 — 행의 둘째 줄에 붙는 칸

둘째 줄 오른쪽에 칸 목록을 단다. 칸은 평문과 닫힌 `tone` 이다. 색은 렌더러가 칠한다(`Masc_tui_agenda` 와 같은 방식). 폭이 모자라면 가장 오른쪽 칸부터 통째로 뺀다. 잘린 숫자를 만들지 않는다(요약 줄의 `join_fitting` 과 같다). `Compact` 는 한 줄이라 새 칸을 더하지 않는다.

**A1. 칸 리프와 일정 환원**

- `bin/masc_tui_keeper_axis_cell.ml(i)`: `type tone = Quiet | Attention | Failure`, `type t = { text : string; tone : tone }`.
- `bin/masc_tui_keeper_next_run.ml(i)`:
  ```ocaml
  type t =
    | No_schedule
    | Scheduled_at of float
    | Late_since of float
    | Held_since of float
    | Not_before of float
    | Unknown
  val index_of_agenda : Masc_tui_types.schedule_snapshot option -> index
  val of_snapshot : keeper_name:string -> Masc_tui_types.schedule_snapshot -> t
  val find : index -> keeper_name:string -> t
  val cell : now:float -> t -> Masc_tui_keeper_axis_cell.t option
  ```
- 입력은 TUI 가 모든 화면에서 갱신하는 fleet 첫 쪽 `schedules_agenda`(20행)다. 요청을 더하지 않는다.
  - Keeper 의 일정은 `sch_payload_keeper_name = Some _` 인 행이다(`bin/masc_tui_types.ml:2825`). `lane:` 대상은 Keeper 가 아니다. 접두 문자열로 가르지 않는다.
  - 첫 쪽에 그 Keeper 의 활성 행이 있으면 가장 이른 행이 정확한 다음 시각이다 → `Scheduled_at`.
  - 없고 응답이 잘렸고(`scs_truncated`) 마지막 행이 활성이면 그 due 이후라는 것만 안다 → `Not_before`.
  - 없고 잘리지 않았으면 → `No_schedule`. 읽지 못했거나 시각을 해석하지 못하면 → `Unknown`.
  - 늦음은 서버 상태로 가른다. status `Due` 이고 훅이 없으면 `Late_since`, 훅이 있으면 `Held_since` 다. TUI 시계로 늦음을 가르지 않는다. 러너 틱이 15초이고 화면은 움직임이 있을 때만 다시 그려진다.
  - 상세 쪽은 같은 환원을 `keeper_schedules` 에 적용한다. `fsm.next_due_at` 가 그 Keeper 전체의 최솟값이다.
- 마지막 실행(행 9)은 요청 행의 `last_wake` 가 시각으로 읽히면 `t` 에 `last_wake : float option` 으로 담는다. 읽히지 않으면 담지 않고 PR 본문에 적는다. 그 경우 행 9 는 미완으로 남는다.
- 시험은 환원 결정만 본다. 여섯 갈래, 잘림 규칙, `lane:` 과 Keeper 구분, 해석 실패.

**A2. 둘째 줄 칸 자리와 일정 칸**

- `bin/masc_tui_render_keepers.ml:421` 의 `keeper_secondary_row_content` 가 오른쪽 정렬 `cells` 를 받는다. 왼쪽 글을 먼저 줄인다.
- `bin/masc_tui_keeper_axis.ml(i)` 를 만든다. `val segments : Masc_tui_types.state -> now:float -> keeper_name:string -> Masc_tui_keeper_axis_cell.t list`. 인덱스는 프레임당 한 번 만든다. 이 층에서는 일정 칸 하나만 낸다.
- 칸은 `◷` 로 시작한다. NOW 칸의 배지 글(`◷ schedule`, `bin/masc_tui_render_keepers.ml:245`)과 겹쳐 보이면 캡처에 적고 PR 본문에서 정한다.
- 확인: 80 · 120 · 200칸, 색 있음과 `NO_COLOR=1`, 전후 쌍.

**A3. 기억 읽기 모듈**

- `bin/masc_tui_keeper_memory_reading.ml(i)`:
  ```ocaml
  type t =
    | Unknown
    | No_row
    | Refused of string
    | Row of { state : memory_state; lag : lag; gap : gap
             ; digest_at : float option; updated_at : float option
             ; added : int; removed : int; source_invalidations : int }
  val index_of_snapshot : Masc.Tui_decode_memory_health.memory_health_snapshot option -> index
  val find : index -> keeper_name:string -> t
  val cells : now:float -> t -> Masc_tui_keeper_axis_cell.t list
  ```
- `lag` 는 `unread_atom_turns + unread_official_turns`(둘 다 `Some` 일 때)이고 아니면 `Lag_unmeasured` 다. Memory 화면의 규칙과 같다(`bin/masc_tui_render_memory.ml:262`). 같은 낱말이 두 화면에서 같은 숫자를 뜻하게, 규칙을 이 모듈로 옮기고 Memory 화면이 이 모듈을 부른다.
- `gap` 은 `memory_librarian_stalled`(`lib/tui_decode_memory_health.mli:76`)에서 만든다. 막대 눈금은 fleet 최댓값으로 잡아 상수를 피한다.
- 갱신 시계 `+ 47m` 은 `updated_at` 의 나이, `+1 −0` 은 `added` 와 `removed` 다. `~retained` 는 필드가 아니라 `facts - added` 다.
- `stale ×N` 의 N 은 `source_invalidations` 다. 경로당 한 건이고 다시 쓰면 지워지는 기록이라 사건 수가 아니다. 낱말은 "근거 N곳 무효" 같은 뜻으로 풀어 도움말에 적는다. 파생 사실의 지지 상실인 `support_invalidations` 는 stale 이 아니다.
- 조인 키는 `Keeper_id.Keeper_name.t` 다(`lib/keeper_registry/keeper_id.mli`). 스냅숏을 읽었는데 행이 없으면 `No_row` 다. `mkr_keeper_id = None` 인 거부 행이 있으면 귀속할 수 없어 `Unknown` 이다(`lib/tui_decode_memory_health.mli:185` 근처).
- 시험은 환원 결정만 본다(`lag` 규칙, `Unknown` · `No_row` 구분, 거부 행).

**A4. Keepers 목록이 기억 health 를 읽게 한다**

- `memory_health_on_screen`(`bin/masc_tui.ml:9517`)이 `Memory` 와 `Metrics` 에서만 읽기를 켠다. Keepers 목록을 더한다. 그 밖의 화면에서는 읽기 빚과 푸시 대기열을 지우는 기존 동작이 그대로다(`:9525`). 도착 시 읽기 팔(`:8566`)에도 목록을 더한다.
- 읽기 횟수는 도착 시 fleet 읽기 1회, `Memory_health` 푸시마다 그 Keeper 의 행 읽기 1회다(Keeper 별 중복 제거). RFC-0480 의 "바뀌었다고 서버가 말할 때 읽는다"를 지킨다. 폴링을 더하지 않는다.
- 확인: 합성 서버 로그로 목록에 머무는 동안의 읽기 횟수를 센다.

**A5. 기억 칸을 둘째 줄에 단다**

- `Masc_tui_keeper_axis.segments` 에 `Masc_tui_keeper_memory_reading.cells` 를 더한다. 일정 칸 뒤에 놓는다.
- 확인: 120 · 200칸 전후 캡처. 질문 표(§6 4번)로 키 수를 센다.

### 2.6 W 갈래 — 기억 서버

**W1. 나이 사다리 모듈**

- 새 모듈 `lib/keeper/keeper_memory_age_bins.ml(i)`. 서버와 TUI 디코더가 함께 쓴다(`Keeper_memory_health_totals` 와 같다).
  ```ocaml
  type bin = Under_hour | Under_day | Under_week | Older
  val of_first_seen : now:float -> float list -> t
  ```
  `of_first_seen` 은 전함수다. 미래 시각은 나이 0 으로 센다. 경계는 표 한 곳에 `Masc_time_constants` 의 `hour` · `day` · `days_to_seconds`(`lib/config/masc_time_constants.ml:13`)로 둔다.
- `first_seen` 만 쓴다. 일반 사실 목록의 나이 배지는 `last_seen` 이다(`bin/masc_tui_render_memory.ml:664`). 두 시계가 다르므로 사다리에는 "처음 본 뒤"라고 이름을 붙인다. 이름에 `fresh` · `stale` · `cooling` · `dormant` 를 쓰지 않는다(RFC-0418).

**W2. health 행에 사다리를 싣는다 (행 13)**

- 키: `age_bins`. 값은 `null` 또는 `{"under_hour": n, "under_day": n, "under_week": n, "older": n}` 이다. `null` 은 스냅숏이 없거나 읽기에 실패한 것이고 0 과 다르다. 합은 `facts` 와 같다. 디코더가 합을 검증한다(`lib/tui_decode_memory_health.ml:517` 방식). `totals` 에는 넣지 않는다. 일반 저장소만 세고 원본 저장소는 후속이다.
- 캐시: `cached_keeper_health`(`lib/server/server_dashboard_http_keeper_memory_health.ml:506`)는 시간 만료가 없고 커밋 때만 비워진다. 그 안에서 빈을 세면 얼어붙는다. 캐시 항목에는 `first_seen : float list` 만 담고, JSON 을 내는 `keeper_health_entry_to_json ~now`(`:661`)에서 센다. 파일 읽기는 늘지 않는다.
- 스키마 `keeper.memory_os.current_health.v8` 를 `v9` 로 올린다. TUI 디코더가 필드를 정확히 맞춰 읽고(`:476`) 서버 시험이 실제 JSON 을 TUI 디코더에 통과시키므로, 서버 · TUI 디코더 · 대시보드 TS · 픽스처의 `v8` 문자열(조사 에이전트가 센 17곳, 시험 12곳)을 한 PR 에서 바꾼다.
- 대시보드 `decodeKeeperMemoryHealth` 의 봉투 키(`dashboard/src/api/dashboard-misc.ts:650`)에는 `execution` 이 없는데 서버는 보낸다(`lib/server/server_dashboard_http_keeper_memory_health.ml:809`). 실제로 거부하는지는 확인하지 못했다. 거부가 확인되면 이슈로 남긴다.

**W3. 월드 읽기 경로 (행 14)**

- 새 라우트 `GET /api/v1/dashboard/workspace-memory-inventory`. 인증은 `CanReadState`, 응답은 `respond_cached_read` 60초다. health 봉투에 넣지 않는 이유는 셋이다. health 는 `Public_read` 라 인증이 다르다. 장부는 Curator 가 쓰는데 무효화와 푸시가 없다. TUI 디코더가 봉투 키를 고정한다.
- 타입 둘을 더한다. `Workspace_memory_briefing` 에 `type pass = { target : int; remaining : int }` 와 `val pass : t -> pass option`. `Workspace_memory_ledger` 의 `observation.Available` 에 `excluded_count : int` 와 `building : (pass option, string) result`. 같은 `Briefing.load` 결과에서 파생한다. `Available` 리터럴 5곳(시험)이 바뀐다.
- 응답은 `Workspace_memory_ledger_view.inventory` 의 이름을 재사용한다.
  ```json
  { "schema": "...", "generated_at": 1794037335, "status": "available",
    "semantic_verification": "not_performed", "ledger_sha256": "...",
    "claim_count": 0, "conflict_count": 0, "excluded_count": 0, "classified_count": 0,
    "briefing": { "status": "pending", "building": null } }
  ```
  `briefing.status` 는 `pending | current | stale | unavailable` 이고 `building` 은 `null` 또는 `{"target": n, "remaining": n}` 이다. `status` 가 `missing` 이면 나머지 키가 없다. `unavailable` 이면 `building` 키가 없다. 손상된 장부는 ledger 라우트처럼 503 이다. `schema` 문자열은 같은 모듈의 기존 이름 규칙을 따른다.
- 이 값이 말하지 않는 것(도움말과 화면 글에 지킨다).
  - `semantic_verification: not_performed` 이므로 장부는 Curator 의 해석이다. `claim_count` 와 `conflict_count` 는 기록 개수다.
  - 저장된 묶음을 다시 검증하지 않는다(`stored_bindings_not_revalidated`). `stale ×0` 은 "신선하다"가 아니다.
  - `Current` 는 "발행본이 현재 근거와 계약과 같다"일 뿐 내용이 맞다는 뜻이 아니다. 근거가 0개면 항상 `Current` 와 빈 본문이다.
  - `building` 은 "열린 pass 가 디스크에 있다"이고 "모델이 지금 돈다"가 아니다. 저장이 모델 호출 앞에서 일어난다. `remaining = target` 이면 이전 요약 없이 처음부터라는 뜻이다.
- 넣지 않는 것: `published_at`. `publication` 에 시각이 없고 `briefing.json` 은 pass 중에도 다시 쓰여서 mtime 도 발행 시각이 아니다. 넣으려면 briefing 스키마 hard cut 과 재합성이 필요하다. `absent` 수도 넣지 않는다. `Context.collect` 와 `reconcile` 이 필요해 무겁다.

**W4. 월드 TUI 디코더**

- `lib/tui_decode_workspace_memory.ml(i)` 를 만들고 W3 의 실제 JSON 을 통과시키는 왕복 시험을 둔다. 모르는 키는 거부한다. W3 의 와이어가 확정된 뒤에 시작한다.

### 2.7 2차 착수 — 표시 층

- **D1.** S 의 값을 행에 그린다. `failing_since` 로 "실패 N분째" 칸, `recent_turns` 로 맥박 칸을 둘째 줄 칸 목록에 더한다. 맥박은 샘플 시각으로 12시간 창을 자르고, 창 앞부분이 `truncated` 로 비었으면 그 부분을 "모름" 기호로 그린다. `rested` 와 `failed` 는 다른 기호다. 선행: S1b · S2 · A2 가 main 에 오른 뒤.
- **D2.** W 의 값을 그린다. Memory 화면의 `memory_fleet_header_rows`(`bin/masc_tui_render_memory.ml:907`)에 월드 줄과 사다리 줄을 더하고, 선택한 Keeper 상세(`memory_context_lines`, `:238`)에 사다리를 더하고, 둘째 줄 칸 목록에 사다리 칸을 더한다. 선행: W2 · W4 · A5 가 main 에 오른 뒤.

## 3. 바뀌는 것

줄 수는 조사 에이전트의 추정이다. 층이 300줄을 넘으면 시험이나 문서를 다음 층으로 뗀다. 층 하나는 한 가지 결과만 낸다.

| 층 | 새 파일 | 고치는 파일 | 약 줄 | 선행 |
| --- | --- | --- | --- | --- |
| K1 | — | `bin/masc_tui_render_schedule.ml(i)`, `bin/masc_tui_render_keepers.ml` | 40–80 | — |
| K2 | — | `bin/masc_tui_render_keepers.ml`, `docs/TUI-GUIDE.md` | 50–90 | — |
| K3 | — | `bin/masc_tui_keeper_trail.ml(i)`, `bin/masc_tui_render_keepers.ml`, `bin/dune`, `test/test_tui_keeper_trail.ml` | 220–290 | K2 |
| S3 | — | `keeper_execution_receipt.ml(i)`, `keeper_runtime_trust_snapshot.ml`, `keeper_tool_surface_ops.ml`, `tui_decode.ml(i)`, `gate-keepers.ts` 와 시험 둘, 픽스처 셋 | 120 | — |
| S3d | — | `bin/masc_tui_keeper_mark.ml`, `bin/masc_tui_render_keepers.ml`(표지와 색 함수만) | 80 | S3 |
| S2 | — | `keeper_registry_types.ml(i)`, `keeper_registry.ml`, `keeper_registry_setup.ml`, `keeper_tool_surface_ops.ml`, `tui_decode.ml(i)`, TS, 시험 | 150 | S3d |
| S1a | `keeper_turn_pulse.ml(i)`, 시험 | `keeper_heartbeat_loop_cycle.ml`, `keeper_heartbeat_loop.ml` | 200 | S2 |
| S1b | — | `server_bootstrap_maintenance.ml`, `keeper_tool_surface_ops.ml`, `tui_decode.ml(i)`, TS, 시험 | 180 | S1a |
| A1 | `masc_tui_keeper_axis_cell.ml(i)`, `masc_tui_keeper_next_run.ml(i)`, 시험 | `bin/dune`, `test/dune` | 310 | — |
| A2 | `masc_tui_keeper_axis.ml(i)` | `bin/masc_tui_render_keepers.ml`, `bin/dune` | 90 | A1 |
| A3 | `masc_tui_keeper_memory_reading.ml(i)`, 시험 | `bin/masc_tui_render_memory.ml`, `bin/dune` | 290 | A1 |
| A4 | — | `bin/masc_tui.ml` | 10 | A3 |
| A5 | — | `bin/masc_tui_keeper_axis.ml` | 60 | A2 A4 |
| W1 | `keeper_memory_age_bins.ml(i)`, 시험 | `test/dune` | 150 | — |
| W2 | — | `server_dashboard_http_keeper_memory_health.ml`, `tui_decode_memory_health.ml(i)`, `dashboard-misc.ts`, 픽스처 | 190 | W1 |
| W3 | — | `workspace_memory_briefing.ml(i)`, `workspace_memory_ledger.ml(i)`, `workspace_memory_ledger_view.ml(i)`, `server_routes_http_routes_dashboard.ml`, 시험 | 185 | — |
| W4 | `tui_decode_workspace_memory.ml(i)`, 시험 | `bin/dune` 또는 `lib/dune` | 200 | W3 |
| D1 | 칸 모듈 | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis.ml` | 250 | S1b S2 A2 가 main 에 오른 뒤 |
| D2 | — | `bin/masc_tui_render_memory.ml`, `bin/masc_tui_keeper_axis.ml` | 200 | W2 W4 A5 가 main 에 오른 뒤 |

경로는 `lib/keeper/` · `lib/server/` · `lib/workspace_memory/` · `lib/` · `bin/` 를 줄여 적은 것이다. 층을 시작하는 에이전트가 자기 기준 커밋에서 경로를 다시 확인한다.

## 4. 하지 않는 것

- 서버의 권위(원장 · 결정 로그 · 영수증 · 전이 기록)를 바꾸지 않는다. 서버 갈래는 읽기 투영만 더한다. 투영은 권위로 다시 저장하지 않고, 행동을 막거나 고르는 게이트로 쓰지 않는다.
- 기억의 나이로 사실의 힘을 바꾸지 않는다. 나이를 `stale` 이라 부르지 않는다(RFC-0418, `lib/keeper/keeper_memory_os_types.mli:333`).
- 서버가 말하지 않은 시각 · 횟수 · 상태 이름을 만들지 않는다. 값이 없으면 `모름` 으로 둔다.
- 화면 문구 · 배치 · 행 순서를 확인하는 시험을 만들지 않는다(`docs/constitution.xml:354-355`). 증거는 캡처와 계산표다.
- `Provider` 묶음을 `api_candidate_fault` 로 가르지 않는다. 가를 수 있는 행이 2026-11-06 표본 15행 중 `Provider` 3행의 1행뿐이라 N-of-M 패치다. 근본 해결은 서버 RFC-0454 P2(`Core` 를 생성자별로 넓힌다)다. 그때까지는 K3 노드에 `fault` 낱말을 붙이는 데서 멈춘다.
- 시안의 보기 6개(원인별 · 시간별 · 기억별 · 나이별 · runtime × keeper · 24h 벽), Story 창, `s` `m` `w` 키는 이 RFC 밖이다. 같은 행 값을 다르게 묶는 화면이라서 값이 main 에 오른 뒤에 별도 RFC 로 낸다.
- Schedules · Memory 전체 화면을 없애거나 합치지 않는다. Keepers 줄에는 칸만 더한다.
- 옛 형태를 읽는 호환 코드를 만들지 않는다. 새 필드는 hard cut 이다.
- `recovered_at`, `runtime_blocker_class`, 월드 `published_at`, `absent` 수는 시안 항목이 아니거나 재료가 없어서 더하지 않는다.
- 요약 줄의 좁은 폭 문제(#49560 #49594 #49574 #49611)는 이미 고쳐졌다. 80칸에서 요약 줄의 `layout · sort` 항목이 빠지는 것은 항목을 통째로 빼는 설계의 결과이고 시안 항목이 아니라서 다루지 않는다.
- 실패 시작 시각을 Info 탭에서 `GET /api/v1/keepers/:name/transitions` 로 읽는 길을 채택하지 않는다(D4).

## 5. 층과 병렬 규칙

### 5.1 착수

- 1차 착수는 스택 넷, 에이전트 넷이다. K · S · A · W. 층 순서는 §3 표대로이고, 스택마다 밑동 PR 은 `main` 을 겨냥하고 다음 층은 앞 층의 브랜치를 겨냥한다(`docs/guides/NATIVE-GITHUB-STACKS.md`). W 스택은 서버 쪽(W1 W2 W3)과 디코더(W4)를 한 에이전트가 순서대로 쌓는다.
- 2차 착수(D1 D2)는 앞 층이 main 에 오른 뒤에 각각 main 에서 새 스택으로 시작한다. 1차 스택이 병합되기 전에는 시작하지 않는다.
- 에이전트는 자기 갈래의 층만 만든다. 구현 PR 의 병합, Ready 전환, 강제 푸시, 이미 리뷰가 달린 스택의 rebase, 다른 갈래의 파일 수정은 하지 않는다.

### 5.2 파일 소유와 충돌

| 파일 | 소유 | 다른 갈래가 닿는 곳 |
| --- | --- | --- |
| `bin/masc_tui_render_keepers.ml` 목록 영역 | K | A2 가 `keeper_secondary_row_content` 와 그 호출부 한 곳, S3d 가 표지와 색 함수만 |
| `bin/masc_tui_render_schedule.ml` | K | — |
| `bin/masc_tui_keeper_trail.ml(i)` | K | — |
| `lib/tui_decode.ml(i)`, `lib/keeper/keeper_tool_surface_ops.ml`, `lib/keeper/keeper_registry*.ml`, `gate-keepers.ts` | S | — |
| `bin/masc_tui_keeper_axis*.ml`, `bin/masc_tui_keeper_next_run.ml`, `bin/masc_tui_keeper_memory_reading.ml` | A | — |
| `bin/masc_tui.ml` | 아무도 | A4 가 읽기 조건 한 곳 |
| `lib/tui_decode_memory_health.ml(i)`, health 서버, `dashboard-misc.ts` | W | A3 는 읽기만 한다 |
| `bin/masc_tui_render_memory.ml` | A3 가 규칙을 옮기는 두 곳 | D2 가 줄을 더한다 |
| `bin/dune`, `test/dune` | 모두 | 떨어진 줄에 추가한다 |

- 겹치는 곳은 둘째 줄 함수(K3 와 A2)다. 먼저 병합되는 스택이 이기고, 뒤 스택은 충돌이 나면 스택 전체를 `gh stack rebase` 한 번 한다. 권하는 병합 순서는 K → A → S → W 다. 순서는 병합하는 사람이 정한다.
- 층을 시작하기 전에 `git fetch origin main` 으로 main 이 움직였는지 보고, 같은 파일을 만지는 열린 PR 이 있는지 `gh pr list` 로 확인한다. 있으면 시작 전에 보고한다.

### 5.3 층마다 지키는 것

- 층 하나는 한 가지 결과이고 OCaml 약 300줄 이하다. 커밋은 영어 Conventional Commits 이고, PR 제목과 본문은 한국어 `~요` 체다.
- PR 은 Draft 로 연다. 본문은 템플릿 제목을 모두 채우고 `Relates #49201` 과 이 RFC 번호를 적는다. `changelog.d/<PR>.md` 를 PR 번호가 생긴 뒤에 더하고 `python3 scripts/changelog-fragments.py check-files` 로 확인한다.
- 로컬 dune 빌드를 하지 않는다. 타입은 독립 타입 검사 하네스나 PR 의 `type-check` 가 판정한다. CI 를 기다리는 반복 조회를 하지 않는다.
- 같은 막힘에 서로 다른 방법으로 세 번 실패하면 멈추고 시도한 것을 보고한다.

## 6. 확인 방법

화면 시험은 만들지 않는다(`docs/constitution.xml:354-355`). 층마다 아래 다섯 가지로 확인한다.

1. **타입.** 로컬 dune 빌드는 하지 않는다. 독립 타입 검사 하네스나 PR 의 `type-check` 가 판정한다. 실행 기록을 인용할 때는 workflow 이름, run id, head SHA, 결과를 함께 적는다(`docs/constitution.xml` 의 `run_citation`).
2. **동작 시험.** 타입이 있는 논리만 본다. 디코더, 서버 투영, 순수 함수의 갈래다. 화면 글, 배치, 행 순서는 보지 않는다. `test.yml` 수동 실행으로 층마다 head 당 한 번 돌린다.
3. **캡처(TUI 층).** 합성 Keeper 로 80 · 120 · 200칸, 색 있음과 `NO_COLOR=1`, 전 · 후 한 쌍을 찍는다. 입력은 변경 뒤 코드가 내는 행의 모양을 이름 없이 옮긴 합성 행이다. 절대 경로 · 토큰 · 실제 이름 검사를 통과한 것만 `docs/evidence/` 에 둔다. 찍은 빌드의 SHA 를 README 에 적고, 그 빌드에 없는 동작은 말하지 않는다.
4. **질문 표.** 층이 답하는 운영자 질문마다 키를 몇 번 눌러 답하는지 캡처로 센다(RFC-0503 §7 의 방식). 측정값은 PR 본문에 둔다.
5. **적대적 리뷰.** 층을 올리기 전에 새 맥락의 읽기 전용 에이전트가 diff 를 읽는다. 지적은 코드로 다시 확인하고 틀린 지적은 틀렸다고 적는다. 독립 승인은 따로 받는다.

서버 층은 둘을 더한다. 읽는 쪽(디코더)과 쓰는 쪽(투영)이 같은 닫힌 variant 를 쓰는지 본다. 행 JSON 에 싣는 값이 바뀌는 쓰기마다 그 Keeper 의 변경 신호가 나가는지 본다(RFC-0481 §3.2). S1b 와 S2 는 roster 응답 크기를 잰 값을 PR 본문에 적는다.

## 7. 정할 것

아래 기본값은 이 RFC 를 병합하면서 받아들인 값이다. 바꾸려면 이 RFC 를 고치는 PR 로 낸다.

| # | 정할 것 | 기본값 | 이유 · 대안 |
| --- | --- | --- | --- |
| D1 | 새 칸의 자리 | `Detailed` 둘째 줄 오른쪽. `Compact` 에는 더하지 않는다 | 첫 줄에 새 칸을 더하면 네 곳(`bin/masc_tui_render_schedule.ml:162`, `bin/masc_tui_render_keepers.ml:345` `:367` `:931`)을 고쳐야 한다. 셋째 줄은 높이 계산(`:990` `:1044` `:1116`)까지 닿는다 |
| D2 | `lag` 의 뜻 | Memory 화면 규칙(`unread_atom_turns + unread_official_turns`, 둘 다 `Some`) | 시안은 `unread_atom_turns` 하나였다. 두 화면에서 같은 낱말이 다른 숫자가 되면 안 된다 |
| D3 | 나이 사다리의 경계와 이름 | 1시간 · 1일 · 7일, 이름은 `Under_hour` `Under_day` `Under_week` `Older` | 이름에 강도를 암시하는 말을 쓰지 않는다(RFC-0418). 경계는 표 한 곳에서 바꾼다 |
| D4 | 실패 시작 시각의 출처 | 서버 필드 `failing_since`(S2) | 대안은 Info 탭에서 `transitions` 를 읽는 길이다. 280–360줄이 들고, 링 50개 밖이면 모르고, 목록 행마다 읽으면 N+1 이라 목록에는 못 쓴다 |
| D5 | 맥박의 모양 | 결과 셋(`ok` `rested` `failed`), 자율 턴만, 최대 24개, 시간으로 자르지 않는다. 12시간 창은 TUI 가 자른다 | 서버가 읽는 시각에 맞춰 세면 값이 읽는 시각에 따라 바뀐다(RFC-0481). 쉼을 실패와 섞으면 "쉼은 실패가 아니다"(#49567)와 어긋난다 |
| D6 | 사람 몫 행의 그룹 | 표지와 색만 바꾸고 Attention 그룹에는 넣지 않는다 | 그룹 편입은 요약 줄 칩과 RFC-0503 의 그룹 정의를 바꾼다. 따로 낸다 |
| D7 | 일정 읽기 | fleet 첫 쪽 재사용(요청 0) | 서버가 Keeper 별 요약 필드를 더하는 안(서버 약 45줄 + TUI 약 120줄)은 캡처에서 `Not_before` 와 `Unknown` 의 비율이 높다고 드러나면 별도 RFC 로 낸다 |
| D8 | `Provider` 가르기 | 하지 않는다 | §4. 근본 해결은 서버 RFC-0454 P2 |
| D9 | 월드의 `published_at` 과 `absent` | 1차에서 제외 | 재료가 없거나 무겁다(W3) |
| D10 | 2차 착수 시점 | 필요한 1차 스택이 main 에 오른 뒤 | 두 스택에 걸친 층은 스택 하나로 쌓을 수 없다 |

## 8. 참고

- RFC-0503: [`RFC-0503-keepers-list-shows-a-failed-last-turn-apart-from-the-activity-now.md`](RFC-0503-keepers-list-shows-a-failed-last-turn-apart-from-the-activity-now.md). 이 RFC 는 §4 의 제외 항목과 §6 의 서버 후속 후보를 이어받는다.
- RFC-0418: 기억의 나이는 표시 값이고, 다시 관찰한 것은 강도 신호가 아니다.
- RFC-0480 · RFC-0481: TUI 는 서버가 바뀌었다고 말할 때 읽는다. roster 행은 바뀐 Keeper 만 다시 읽고, 값은 읽는 시각에 따라 바뀌지 않는다.
- 연구 문서: [`docs/research/2026-11-06-keepers-list-past-now-next.md`](../research/2026-11-06-keepers-list-past-now-next.md)
- 근거 기록: [`docs/evidence/research/2026-11-06-keepers-list-past-now-next/README.md`](../evidence/research/2026-11-06-keepers-list-past-now-next/README.md)
- 실행 규칙: [`docs/constitution.xml`](../constitution.xml) `<execution_protocol>`, [`docs/guides/NATIVE-GITHUB-STACKS.md`](../guides/NATIVE-GITHUB-STACKS.md)
- 외부 문서(2026-11-07 확인): [RFC 9111](https://www.rfc-editor.org/rfc/rfc9111.html) §4.2 · §5.1, [Prometheus querying basics](https://prometheus.io/docs/prometheus/latest/querying/basics/) 의 Staleness, [ratatui `Sparkline`](https://docs.rs/ratatui/latest/ratatui/widgets/struct.Sparkline.html)
