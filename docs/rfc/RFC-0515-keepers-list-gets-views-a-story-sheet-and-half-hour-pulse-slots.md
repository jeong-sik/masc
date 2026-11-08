---
rfc: "0515"
title: "Keepers 목록에 보기 탭 · 한 축 줄 · Story 창을 올리고 맥박을 30분 칸으로 저장한다"
status: Draft
created: 2026-11-09
updated: 2026-11-09
author: claude
supersedes: []
superseded_by: null
related: ["0511", "0503", "0481", "0418"]
---

# RFC-0515 — Keepers 목록에 보기 탭 · 한 축 줄 · Story 창을 올리고 맥박을 30분 칸으로 저장한다

- Status: **Draft.** 운영자가 2026-11-09 에 착수를 지시했다("1,2,3 전체 진행해줘"). §7 의 기본값은 이 RFC 를 병합하면서 받아들인다.
- 시안: `docs/research/2026-11-06-keepers-list-past-now-next-preview.html` (Artifact `Keeper Pulse` 3판).
- 앞 RFC: RFC-0511 §4 가 보기 6개 · Story 창 · `s` `m` `w` 키를 "값이 main 에 오른 뒤 별도 RFC" 로 미뤘다. 이 RFC 가 그 별도 RFC 다.

## 0. 요약

- RFC-0511 이 행 안의 값(실패 지속 시간 · 맥박 · lag · 갱신 시계 · 나이 사다리 · 일정 칸 · 사람 몫 표지)을 main 에 올렸다. 화면 틀은 그대로라서 운영자 눈에는 옛 화면이다.
- 이 RFC 는 화면 틀 넷을 올린다. 보기 탭, 한 축 줄(◂ 직전 · ● 지금 · ▹ 다음), Story 창, 그리고 이 셋을 부르는 키다.
- 그 앞에 맥박 저장을 고친다. 서버는 Keeper 마다 최근 턴 24개만 들고 있어서 바쁜 Keeper 의 12시간 칸이 `?` 로 찬다. 30분 칸으로 24시간을 저장한다. 이것이 24h 벽 보기의 재료이기도 하다.

## 1. 지금

### 1.1 운영자가 본 화면 (2026-11-09 08:2x KST)

- 설치본 `~/.local/bin/masc-tui` 는 main `9c7452c0e208` 빌드다. RFC-0511 의 TUI 층은 모두 들어 있다.
- 저장된 레이아웃이 `grouped` 였다. 둘째 줄은 `Detailed` 만 그린다(`bin/masc_tui_render_keepers.ml` 의 `entry_height`). 그래서 행 안의 값이 하나도 안 보였다.
- `Detailed` 로 바꾼 캡처(운영자 스크린샷)에서 세 가지가 보였다.
  - 맥박이 `???√√√√√√√√√` 처럼 앞쪽 칸이 `?` 다.
  - 둘째 줄 왼쪽이 첫 줄 DETAIL 칸과 같은 문장을 다시 쓴다. 오른쪽 칸들이 밀려 잘린다.
  - 보기 탭, 한 축 줄, Story 창은 없다. 열은 `KEEPER NOW Mode S AGE LIFECYCLE / RUNTIME DETAIL` 그대로다.

### 1.2 맥박의 `?` 는 저장 개수 상한에서 온다

`lib/keeper/keeper_turn_pulse.ml` 의 `max_samples_per_keeper = 24` 가 Keeper 마다 최근 턴 24개만 남긴다. TUI 는 남은 턴 중 가장 오래된 것보다 앞의 빈 칸을 `?` 로 그린다(`bin/masc_tui_keeper_pulse.ml` 의 `oldest_known_hour`). 범례도 "서버가 최근 24턴만 들고 있어서 바쁜 Keeper 의 앞 시간은 `?`" 라고 적는다(`bin/masc_tui_keeper_mark.ml` 의 `column_legend`).

2026-11-09 08:3x KST 에 `~/me/.masc/keepers/<name>.decisions.jsonl` 과 `.1` 의 `event=turn` 줄을 세었다.

| Keeper | 12시간 턴 | 24시간 턴 | 최근 24턴이 덮는 시간 | 12칸 중 `?` |
| --- | --- | --- | --- | --- |
| code-reviewer | 318 | 360 | 0.6시간 | 11 |
| sangsu | 36 | 85 | 8.2시간 | 약 4 |
| wkbl-web-leader | 48 | 84 | 8.2시간 | 약 4 |
| wkbl-data | 23 | 47 | 12.4시간 | 0 |

턴이 많은 Keeper 일수록 맥박이 비어 보인다. 맥박이 답하려던 질문("반나절째 실패하나")에 가장 바쁜 Keeper 가 답하지 못한다.

RFC-0511 D5 는 "최대 24개, 시간으로 자르지 않는다" 를 골랐다. 이유는 서버가 읽는 시각에 맞춰 세면 같은 행 JSON 이 읽는 시각마다 달라진다는 것(RFC-0481)이었다. 이 이유는 맞다. 개수 상한이 아니어도 지킬 수 있다(§2.1).

### 1.3 키

Keepers 목록에서 시안 키 일곱은 이미 다른 뜻이다.

| 시안 | 시안의 뜻 | 지금 뜻 |
| --- | --- | --- |
| `s` | 스케줄 | shutdown(두 번 눌러 확인) |
| `m` | 기억 | 대화(`c` 별칭) |
| `o` | 보기 순환 | 정렬 순환 |
| `n` | NO_COLOR | 다음 일치 |
| `t` | 테마 | 도구 호출 |
| `w` | 월드 | wake |
| `x` | 처음으로 | 영구 삭제 |

`v` 는 레이아웃 순환(compact · detailed · grouped)이고 푸터에 `v:view` 로 적혀 있다. `[` `]` 는 Lanes · Tools 화면에서만 쓴다.

## 2. 제안

### 2.1 맥박은 30분 칸으로 24시간을 저장한다 (RFC-0511 D5 를 고친다)

서버 저장 모양을 바꾼다.

```ocaml
type tally = { ok : int; rested : int; failed : int }
type slot = { starts_at : float; tally : tally }   (* 30분 경계에 맞춘 칸 *)
type pulse = { known_since : float; slots : slot list }   (* 새 칸이 앞 *)
```

- 칸은 Unix 시각을 1800초로 내린 경계에 맞춘다. 한 턴은 끝난 시각의 칸 하나에 더해진다.
- 칸을 지우는 때는 기록할 때뿐이다. 새 턴 시각보다 24시간 넘게 앞선 칸을 지운다. 읽을 때는 아무것도 계산하지 않는다. 그래서 행 JSON 은 턴이 기록될 때만 바뀐다(RFC-0481 조건 유지).
- Keeper 하나가 들고 있는 칸은 시간으로 정해진다. 24시간 = 48칸에 지금 칸 하나를 더해 최대 49칸이다. 턴이 몇 개든 같다.
- `known_since` 는 "이 시각부터는 턴을 빠짐없이 안다" 는 서버의 말이다. 서버가 켜질 때 결정 로그에서 다시 채우는 범위가 정한다.
  - 로그가 없거나, 24시간 창보다 오래된 턴까지 읽었으면 창의 시작이다.
  - 로그 꼬리 읽기가 창 시작 전에 끊겼으면 읽은 턴 중 가장 오래된 시각이다. 턴을 하나도 못 읽었으면 지금이다.
  - 서버가 켜진 뒤 기록은 빠짐없으므로 `known_since` 는 더 늦어지지 않는다.
- 행 JSON `recent_turns` 는 `{known_since, slots: [[starts_at, ok, rested, failed], ...]}` 이다. 옛 `{truncated, turns}` 는 hard cut 이고 읽지 않는다.
- TUI 의 12칸은 벽시계 정시에 맞춘 1시간 칸이다. 30분 칸 둘을 합치고, 결과는 failed > rested > ok 순으로 가장 나쁜 것을 그린다. 턴이 없는 칸은 칸 시작이 `known_since` 보다 앞이면 `?`, 아니면 쉼 표지다.

### 2.2 Detailed 둘째 줄은 첫 줄 문장을 다시 쓰지 않는다

`Detailed` 첫 줄의 DETAIL 칸을 뺀다. 문장은 둘째 줄에만 둔다. 첫 줄의 runtime 열이 그 자리를 쓴다. 둘째 줄 오른쪽 칸들(일정 · lag · 갱신 · stale · 맥박 · facts)이 덜 잘린다.

### 2.3 보기 탭

목록 위에 보기 이름을 한 줄로 그린다. 고른 보기는 반전으로 표시하고, 이름은 마우스로 누를 수 있다.

```
 목록 · 상태별 · 원인별 · 시간별 · 기억별 · 나이별 · runtime · 24h
```

보기마다 묶는 기준이 하나다. 모두 TUI 가 이미 decode 하는 닫힌 값으로 묶는다. 문자열로 가르지 않는다.

| 보기 | 묻는 것 | 묶는 기준(닫힌 값) |
| --- | --- | --- |
| 목록 | — | 묶지 않는다 |
| 상태별 | 누가 무엇을 기다리나 | `Keeper_list_model.attention`(지금의 `grouped`) |
| 원인별 | 왜 실패하나 | `Masc_tui_keeper_trail.cause_group`, 실패 없음 |
| 시간별 | 언제 일하나 | `Masc_tui_keeper_next_run.t` 를 늦음 · 1시간 안 · 12시간 안 · 그 뒤 · 일정 없음 · 모름 으로 |
| 기억별 | 기억이 따라오나 | `Masc_tui_keeper_memory_reading` 의 gap 있음 · 밀림(lag > 0) · 따라옴 · 모름 |
| 나이별 | 기억이 식어 가나 | 스냅샷 `updated_at` 나이 3시간 · 24시간 · 3일 · 그 뒤 · 모름 |
| runtime | 어느 runtime 이 막혔나 | 행의 현재 runtime id |
| 24h | 반나절 동안 어땠나 | 묶지 않고, 실패한 30분 칸 수가 많은 순. 행에 48칸 맥박 |

- 묶음 안의 순서는 지금의 정렬(`o`)을 따른다.
- 나이 경계(3시간 · 24시간 · 3일)는 표시용 값이다. 서버 상태가 아니다. 나이를 `stale` 이라 부르지 않는다(RFC-0418).
- 월드 줄(RFC-0511 D2c)은 기억별 · 나이별 보기의 맨 위에만 둔다.

### 2.4 한 축 줄

목록 외의 보기는 Keeper 한 줄을 시간 축으로 그린다.

```
 표지 이름        ◂ 맥박 12칸     ● 지금 한 단어    ▹ 다음: ◷ 일정 · runtime · lag
```

- ◂ 직전: §2.1 의 맥박. 24h 보기에서는 48칸.
- ● 지금: `Keeper_list_model.primary_activity_of_row` 의 낱말 하나. 도는 턴은 기존 running 표지(`◐◓◑◒`, 150ms 걸음)를 그대로 쓴다. 새 움직임은 만들지 않는다.
- ▹ 다음: 일정 칸(`◷`), 다음 dispatch 경로(`kr_runtime_path_rest`), lag.
- Mode · S · AGE · LIFECYCLE 은 Story 창으로 옮긴다. 실패한 Keeper 는 둘째 줄에 사슬과 원인을 그린다.

### 2.5 Story 창

목록에서 `Enter` 를 누르면 고른 Keeper 의 Story 창이 목록 위에 열린다.

- 줄: ◂ 직전(맥박 · 마지막 Librarian 성공) / ● 지금(활동 문장 · Mode · S · AGE · LIFECYCLE) / ▹ 다음(일정 · 경로 · lag) / 실패 사슬.
- 창 안의 키: `→` 또는 `Enter` 는 지금의 상세(탭 11개), `s` 는 이 Keeper 로 거른 Schedules, `m` 은 Memory 의 이 Keeper 행, `Esc` 는 닫기.
- 창 안의 `s` `m` 은 창의 키다. 목록의 `s`(shutdown)는 창이 닫혀 있을 때만 받는다.
- 마지막 wake 줄은 일정 응답의 `last_wake` 를 창이 열릴 때 읽는다(시안 B 단계). 첫 Story 층에는 넣지 않는다.

### 2.6 키

| 키 | 뜻 | 바뀌는 것 |
| --- | --- | --- |
| `v` | 보기 순환(§2.3 순서) | 지금은 레이아웃 순환이다. 푸터 글자 `v:view` 는 그대로다 |
| `V` | 한 줄 / 두 줄 전환 | 새 키. 지금의 compact · detailed 가 여기로 온다 |
| `[` `]` | 앞 · 다음 묶음으로 이동 | 새 키(Keepers 목록에서만) |
| `Enter` | Story 창 | 지금은 상세. 상세는 `→` 와 Story 창의 `Enter` 로 간다 |
| `o` | 정렬 순환 | 그대로 |
| `s` `m` `w` `x` `n` `t` | 지금 뜻 | 그대로. 시안의 뜻은 Story 창 안의 `s` `m` 만 받는다 |

- 설정 파일 `tui-keepers.toml` 의 `layout` 키는 hard cut 이다. `view` 와 `density` 를 새로 쓴다. 옛 `layout` 을 읽어 옮기는 코드는 만들지 않는다.
- 시안의 시뮬레이션 키(`f` `r` `u` `c` `d` `D` `x`)와 `[sim]` 표시는 시연 장치라서 올리지 않는다.

## 3. 층

한 스택으로 쌓는다. 밑동은 이 RFC 다. 층 하나는 한 가지 결과이고 OCaml 약 300줄 이하다.

| 층 | 결과 | 바뀌는 곳 |
| --- | --- | --- |
| R0 | 이 RFC | `docs/rfc/` |
| P1 | 맥박 30분 칸 저장과 행 JSON hard cut, TUI 정시 칸 | `lib/keeper/keeper_turn_pulse.ml(i)`, `lib/keeper/keeper_tool_surface_ops.ml`, `lib/tui_decode.ml`, `dashboard/src/api/schemas/gate-keepers.ts`, `bin/masc_tui_keeper_pulse.ml`, `bin/masc_tui_keeper_mark.ml`, 시험 |
| P2 | Detailed 첫 줄이 DETAIL 을 빼고 둘째 줄만 문장을 쓴다 | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_render_schedule.ml` |
| V1 | 보기 타입 · 묶는 함수 · `v` `V` · 설정 hard cut | `bin/masc_tui_keeper_list_model.ml(i)`, `bin/masc_tui_config.ml(i)`, `bin/masc_tui.ml` 키 두 곳 |
| V2 | 보기 탭 줄과 누르기 | `bin/masc_tui_render_keepers.ml` |
| V3 | 한 축 줄 | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis.ml` |
| V4 | 24h 보기의 48칸 맥박 | `bin/masc_tui_keeper_pulse.ml` |
| S1 | Story 창(A 단계 값만) | 새 모듈 `bin/masc_tui_keeper_story.ml(i)`, 키 처리 |
| S2 | Story 창의 마지막 wake 줄(B 단계) | Story 모듈, 일정 읽기 |

- P1 · P2 는 보기와 무관하게 지금 화면을 고친다. 먼저 병합해도 된다는 뜻이 아니다. 스택은 맨 위 PR 로 한 번에 병합한다(`docs/guides/NATIVE-GITHUB-STACKS.md`).
- `docs/guides/TUI-KEYS.md` 는 생성 문서다. 키나 범례를 바꾼 층이 생성기 출력과 맞춘다.

## 4. 하지 않는 것

- 서버의 권위(결정 로그 · 원장 · 영수증)를 바꾸지 않는다. 맥박은 결정 로그를 다시 읽어 만드는 투영이다.
- 칸 저장을 행동을 막거나 고르는 게이트로 쓰지 않는다.
- 화면 문구 · 배치 · 행 순서를 확인하는 시험을 만들지 않는다(`docs/constitution.xml` 의 `execution_protocol`). 증거는 캡처다.
- Schedules · Memory 전체 화면을 없애거나 합치지 않는다.
- 옛 `recent_turns` 모양, 옛 `layout` 설정을 읽는 호환 코드를 만들지 않는다.
- Failing 의 색(빨강 → 노랑 · 흐림)은 바꾸지 않는다. 다른 세션이 색 층을 다루고 있다.
- NO_COLOR · 테마 전환 키를 Keepers 목록에 더하지 않는다. 둘 다 화면 전체 설정이다.

## 5. 확인 방법

1. **타입.** 로컬 dune 빌드를 하지 않는다. PR 의 `type-check` 가 판정한다. 실행을 인용할 때 workflow 이름, run id, head SHA, 결과를 같이 적는다.
2. **동작 시험.** P1 은 서버 저장(칸 경계 · 24시간 지우기 · `known_since`)과 디코더의 닫힌 갈래를 본다. V1 은 보기마다 묶는 함수가 닫힌 값만 쓰는지 본다. 화면 글과 배치는 보지 않는다.
3. **실측.** P1 은 §1.2 표를 같은 로그로 다시 센다. 바쁜 Keeper 의 12칸 중 `?` 는 서버 기록 범위(`known_since`) 앞에서만 나와야 한다.
4. **캡처.** TUI 층은 120x35 와 80x24 전 · 후 tmux 캡처를 남긴다. 절대 경로 · 토큰 · 계정 이름을 가린다.
5. **적대적 리뷰.** 층을 올리기 전에 새 맥락의 읽기 전용 에이전트가 diff 를 읽는다. 독립 승인은 따로 받는다.

## 6. 위험

- 행 JSON 크기. 칸 하나는 숫자 넷이고 Keeper 하나는 최대 49칸이다. 2026-11-09 결정 로그로 같은 규칙을 계산하면 Keeper 39명의 `recent_turns` 합이 23,504바이트(최근 24턴)에서 13,852바이트(30분 칸)로 준다. 가장 큰 행은 861바이트다. 쉬는 Keeper 는 칸이 적어서 작아진다.
- 정시 칸은 30분 경계마다 보이는 행 거의 전부가 한 칸 민다. 30분에 한 번이라 다시 그리는 비용은 작다(시안 「끊김 없이 움직이나」 표).
- `Enter` 의 뜻이 바뀐다. 상세로 바로 가던 손버릇은 `→` 로 옮겨야 한다.

## 7. 정할 것

| # | 정할 것 | 기본값 | 이유 · 대안 |
| --- | --- | --- | --- |
| E1 | 맥박 저장 | 30분 칸 · 24시간 · 칸마다 결과별 개수 | 대안 "턴을 24시간 동안 다 보관" 은 바쁜 Keeper 가 하루 360턴이라 행 JSON 이 턴 수에 비례한다 |
| E2 | 행의 맥박 칸 | 정시 1시간 칸 12개(30분 칸 둘을 합침) | 시안은 30분 칸 24개다. 행 폭이 모자라 24h 보기에서만 30분 칸 48개를 쓴다 |
| E3 | 보기 순환 키 | `v` | 시안의 `o` 는 정렬이다. 푸터는 이미 `v:view` 다 |
| E4 | 한 줄 / 두 줄 키 | `V` | `v` 를 보기에 쓰면 밀도 전환이 갈 곳이 필요하다 |
| E5 | `Enter` | Story 창 | 대안은 `Enter` 를 상세로 두고 Story 를 `→` 에 두는 것이다. 시안을 따른다 |
| E6 | 시안 키 일곱 | 지금 뜻을 지킨다. Story 창 안의 `s` `m` 만 시안 뜻 | `x` 는 영구 삭제, `s` 는 shutdown 이라 뜻을 바꾸면 사고가 난다 |
| E7 | 보기 순서 | 목록 · 상태별 · 원인별 · 시간별 · 기억별 · 나이별 · runtime · 24h | 시안 6개에 지금 화면 둘(목록 · 상태별)을 앞에 둔다 |

## 8. 참고

- 시안: `docs/research/2026-11-06-keepers-list-past-now-next-preview.html`
- RFC-0511 §4 · §7 D5, RFC-0503, RFC-0481 §3.2, RFC-0418
- 저장: `lib/keeper/keeper_turn_pulse.ml`, 행 JSON: `lib/keeper/keeper_tool_surface_ops.ml`, 디코더: `lib/tui_decode.ml` 의 `decode_recent_turns`
- 맥박 칸: `bin/masc_tui_keeper_pulse.ml`, 범례: `bin/masc_tui_keeper_mark.ml`
