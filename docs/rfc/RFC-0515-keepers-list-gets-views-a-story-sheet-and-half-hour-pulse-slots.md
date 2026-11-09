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
- 2026-11-09 정정: 리뷰와 시안 대조에서 나온 것을 고쳤다. §2.1 의 `known_since` 규칙을 구현(#50190)과 맞추고, 키 사실(§1.3), 기본 보기(E8), 시안과 다르게 정한 것(§2.7)과 층(§3)을 더했다.
- 2026-11-09 두 번째 정정: 운영자가 V1 을 깔고 시안과 견줬다. 시안의 보기별 칸(기억별 · 나이별 · 앞 12시간 일정 띠)과 머리 띠가 어느 층에도 없었다. §2.4 를 보기가 칸 값을 고르는 줄로 고치고 §2.8, 층 V6 · V7 · V8, E16–E19 를 더했다.
- 시안: `docs/research/2026-11-06-keepers-list-past-now-next-preview.html` (Artifact `Keeper Pulse` 3판).
- 앞 RFC: RFC-0511 §4 가 보기 6개 · Story 창 · `s` `m` `w` 키를 "값이 main 에 오른 뒤 별도 RFC" 로 미뤘다. 이 RFC 가 그 별도 RFC 다.

## 0. 요약

- RFC-0511 이 행 안의 값(실패 지속 시간 · 맥박 · lag · 갱신 시계 · 나이 사다리 · 일정 칸 · 사람 몫 표지)을 main 에 올렸다. 화면 틀은 그대로라서 운영자 눈에는 옛 화면이다.
- 이 RFC 는 화면 틀 넷을 올린다. 보기 탭, 한 축 줄(◂ 직전 · ● 지금 · ▹ 다음), Story 창, 그리고 이 셋을 부르는 키다. 한 축 줄의 세 칸에 무엇을 넣을지는 보기가 고른다. 목록 위에는 묶음 수와 함대 실패 띠를 그린다.
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

`v` 는 레이아웃 순환(compact · detailed · grouped)이고 푸터에 `v:view` 로 적혀 있다. `J` 는 고른 Keeper 의 상세를 Automation 탭(일정)으로 열고, `K` 는 그 Keeper 앞으로 쌓인 Keeper 요청을 읽는 창(동료 읽기)을 연다.

Keepers 목록은 `[` `]` 를 쓰지 않는다. `K` 창이 열려 있을 때만 그 창이 `[` `]` 로 앞 · 다음 동료를 고른다(`bin/masc_tui.ml` 의 detail reading 갈래). Work · Board · Keeper 상세 같은 다른 화면은 `[` `]` 를 앞 · 다음 행이나 탭으로 쓴다(`docs/guides/TUI-KEYS.md`).

## 2. 제안

### 2.1 맥박은 30분 칸으로 24시간을 저장한다 (RFC-0511 D5 를 고친다)

서버 저장 모양을 바꾼다.

```ocaml
type tally = { ok : int; rested : int; failed : int }
type slot = { starts_at : int; tally : tally }   (* Unix 초, 30분 경계에 맞춘 칸 *)
type pulse = { known_since : float; slots : slot list }   (* 새 칸이 앞 *)
```

- 칸은 Unix 시각을 1800초로 내린 경계에 맞춘다. 한 턴은 끝난 시각의 칸 하나에 더해진다.
- 칸을 지우는 때는 기록할 때뿐이다. 가장 새 칸보다 24시간 넘게 앞선 칸을 지운다. 그때 `known_since` 가 `가장 새 칸 − 24시간` 보다 앞이면 그 시각으로 올린다. 지운 칸이 없어도 같다. 읽을 때는 아무것도 계산하지 않는다. 그래서 행 JSON 은 턴이 기록될 때만 바뀐다(RFC-0481 조건 유지).
- Keeper 하나가 들고 있는 칸은 시간으로 정해진다. 24시간 = 48칸에 지금 칸 하나를 더해 최대 49칸이다. 턴이 몇 개든 같다.
- `known_since` 는 "이 시각부터는 턴을 빠짐없이 안다" 는 서버의 말이다. 서버가 켜질 때 결정 로그에서 다시 채우는 범위(시드)가 정한다.
  - 시드는 자율 사이클 턴(`execution_path = autonomous_cycle`)만 센다. 채팅 턴은 실시간 기록에 없어서 시드에서도 뺀다. 지금보다 뒤로 찍힌 줄은 버린다.
  - 시드는 주 로그 `decisions.jsonl` 의 꼬리를 읽는다. 주 로그가 없거나, 주 로그를 처음부터 다 읽고도 창 시작에 못 닿으면 회전 로그 `decisions.jsonl.1` 을 이어 읽는다.
  - 창보다 오래된 줄을 읽으면 창의 시작이다. 줄의 이벤트 종류는 가리지 않는다. 그 줄 뒤의 줄은 모두 읽었기 때문이다.
  - 그런 줄 없이 읽기가 끝나면 두 로그에서 읽은 줄 중 가장 오래된 시각이다. 꼬리 읽기가 4MB · 1만 줄에서 끊긴 때와 로그가 창 안에서 시작하는 때가 여기다.
  - 로그가 없거나, 시각을 읽을 수 있는 줄이 하나도 없으면 지금이다.
  - 시드가 없는 Keeper 를 처음 기록하면 그 턴 시각이다.
  - 기록할 때 `가장 새 칸 − 24시간` 보다 앞이면 그 시각으로 올라간다. 그 밖에는 바뀌지 않는다.
- 아는 틈: 쉼 턴은 결정 로그에 실패로 적히고, 결정 행 없이 끝나는 실패가 있다. 그래서 재시작 뒤 일부 칸의 결과가 바뀐다(#50211). 부팅 때 Keeper 시작이 시드보다 앞이라, 첫 턴이 시드보다 먼저 기록되면 시드를 건너뛰고 지난 하루를 잃는다. 기본 warmup 60초에서는 시드가 대개 먼저 끝난다(#50258).
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
| 시간별 | 언제 일하나 | `Masc_tui_keeper_next_run.t` 를 늦음 · 1시간 안 · 12시간 안 · 그 뒤 · 보류 · 일정 없음 · 모름 으로 |
| 기억별 | 기억이 따라오나 | `Masc_tui_keeper_memory_reading` 의 gap 있음 · 밀림(lag > 0) · 따라옴 · 거부 · 모름 |
| 나이별 | 기억이 식어 가나 | 스냅샷 `updated_at` 나이 3시간 · 24시간 · 3일 · 그 뒤 · 모름 |
| runtime | 어느 runtime 이 막혔나 | 행의 현재 runtime id |
| 24h | 반나절 동안 어땠나 | 묶지 않고, 실패한 30분 칸 수가 많은 순. 행에 48칸 맥박 |

- 묶음 안의 순서는 지금의 정렬(`o`)을 따른다.
- 시간별의 보류는 `Held_current` · `Held_as_of` 다. `Not_before` 는 그 시각이 12시간보다 뒤면 그 뒤에, 안쪽이면 실제로 깰 시각을 몰라서 모름에 둔다. 지났지만 아직 늦음으로 판정되지 않은 `Scheduled_at` 은 1시간 안에 둔다.
- 기억별의 거부는 `Refused` 다. `Gap_unmeasured` 는 gap 있음, `Lag_unmeasured` 는 모름에 둔다.
- 경계값은 가까운 칸에 넣는다. 정확히 3시간이면 3시간 칸이다.
- 나이 경계(3시간 · 24시간 · 3일)는 표시용 값이다. 서버 상태가 아니다. 나이를 `stale` 이라 부르지 않는다(RFC-0418).
- 월드 줄(RFC-0511 D2c)은 기억별 · 나이별 보기의 맨 위에만 둔다.

### 2.4 한 축 줄

목록 외의 보기는 Keeper 한 줄을 ◂ 직전 · ● 지금 · ▹ 다음 세 칸으로 그린다. 세 칸의 틀은 모든 보기가 같고, 칸에 넣는 값은 보기가 고른다(E16).

```
 표지 이름        ◂ 직전          ● 지금            ▹ 다음
```

| 보기 | ◂ 직전 | ● 지금 | ▹ 다음 | 층 |
| --- | --- | --- | --- | --- |
| 상태별 · 원인별 · 시간별 | 맥박 12칸(§2.1) | 지금 낱말 | 다음 깰 시각 · 다음 dispatch 경로(`kr_runtime_path_rest`) · lag. V7 이 앞 12시간 일정 띠를 더한다 | V3 · V7 |
| 기억별 | 맥박 12칸 | Librarian 패스 끝(`mlh_state`: pending · drained 등) | 안 읽은 턴(lag) 막대 · 마지막 digest 나이 · gap | V6 |
| 나이별 | 사실 나이 4칸(`age_bins`, E17) | 마지막 갱신 나이(`updated_at`) | lag 막대 · stale 수(`source_invalidations`) · facts 수 | V6 |
| runtime | §2.7 의 교차표 | | | V5 |
| 24h | 48칸 맥박 | | 실패한 칸 수 `n/48` | V4 |
| 목록 | 지금 열 그대로 | | | — |

- 지금 낱말은 `Keeper_list_model.primary_activity_of_row` 의 낱말 하나다. 도는 턴은 기존 running 표지(`◐◓◑◒`, 150ms 걸음)를 그대로 쓴다. 새 움직임은 만들지 않는다.
- 기억별 · 나이별 칸의 값은 TUI 가 이미 받는 Memory 스냅숏(`memory_keeper_health`)에 있다. 새 서버 값은 없다. lag · gap · digest 시각 · `age_bins` · `updated_at` 은 `Masc_tui_keeper_memory_reading.t` 의 `Row` 가 들고 있다. Librarian 패스 끝(`mkh_librarian.mlh_state`)은 V6 이 `Row` 에 더한다.
- 앞 12시간 일정 띠(V7)는 일정의 반복(`Schedule_domain.recurrence`)으로 12시간 안의 깰 시각을 모두 구해 `◷` 로 찍는다. 지금 TUI 는 반복을 JSON(`sch_recurrence`)과 요약 문자열로만 받는다. 요약 문자열은 가르지 않는다. `Schedule_domain` 의 반복 디코더를 열어 닫힌 값으로 읽는다(E19). 행 JSON 의 반복 모양이 그 디코더와 맞는지는 V7 에서 확인한다.
- Mode · S · AGE · LIFECYCLE 은 Story 창으로 옮긴다. 실패한 Keeper 는 둘째 줄에 사슬과 원인을 그린다.
- 고른 Keeper 의 초상은 목록 보기의 두 줄에서만 그리고, 전신으로 그린다. 한 축 줄 보기는 그 줄들을 Keeper 행에 쓴다(E20).

### 2.5 Story 창

목록에서 `Enter` 를 누르면 고른 Keeper 의 Story 창이 목록 아래에 열린다(시안의 dock). 화면 높이가 모자라면 목록 위에 겹쳐 연다.

- 쪽은 셋이다. story · 일정 · 기억. 창 안의 `s` 는 일정 쪽, `m` 은 기억 쪽, `Tab` 은 다음 쪽이다. 창이 열려 있으면 `Tab` 은 창이 먼저 받는다(E15). 창이 닫히면 `Tab` 은 다시 다음 화면이다.
- story 쪽 줄: ◂ 직전(맥박 · 마지막 Librarian 성공) / ● 지금(활동 문장 · Mode · S · AGE · LIFECYCLE) / ▹ 다음(일정 · 경로 · lag) / 실패 사슬.
- 일정 쪽은 이 Keeper 로 거른 일정이다. `J` 가 여는 상세 Automation 탭과 같은 값이다. 기억 쪽은 이 Keeper 의 나이 사다리와 기억 줄이다.
- 창 안의 키: `→` 는 지금의 상세(탭 11개), `Esc` 는 닫기. 목록의 `s`(shutdown)와 `m`(대화)은 창이 닫혀 있을 때만 받는다.
- 마지막 wake 줄은 일정 응답의 `last_wake` 를 창이 열릴 때 읽는다(시안 B 단계). 첫 Story 층에는 넣지 않는다.
- 시안의 시간순 피드(지난 턴 · wake · digest 를 한 줄씩)는 S3 에서 다룬다. 피드가 읽을 값의 출처는 확인 필요다.

### 2.6 키

| 키 | 뜻 | 바뀌는 것 |
| --- | --- | --- |
| `v` | 보기 순환(§2.3 순서) | 지금은 레이아웃 순환이다. 푸터 글자 `v:view` 는 그대로다 |
| `V` | 한 줄 / 두 줄 전환 | 새 키. 지금의 compact · detailed 가 여기로 온다 |
| `V` 의 뜻 | 두 줄이면 모든 보기에서 둘째 줄을 그린다 | 목록 보기는 지금의 detailed 둘째 줄, 한 축 줄 보기는 실패 사슬과 원인 줄이다 |
| `[` `]` | 앞 · 다음 묶음으로 이동 | 새 키(Keepers 목록에서만). `K` 창이 열려 있으면 그 창이 먼저 받는다 |
| `Enter` | Story 창 | 지금은 상세. 상세는 `→` 로 간다 |
| `←` `→` | 묶음 제목 줄에서 접기 · 펼치기 | 새 뜻(제목 줄에서만). 묶는 보기에서는 `j` `k` 가 제목 줄에도 선다. 제목 줄에서는 접기가 `←` 의 "뒤로" 보다 먼저다. 행 위의 `←` `→` 는 그대로다 |
| `J` `K` | 지금 뜻 | 그대로. `J` 는 상세 Automation 탭을 연다. Story 일정 쪽은 그 탭과 같은 값을 그린다 |
| `o` | 정렬 순환 | 그대로 |
| `s` `m` `w` `x` `n` `t` | 지금 뜻 | 그대로. 시안의 뜻은 Story 창 안의 `s` `m` 만 받는다 |

- 설정 파일 `tui-keepers.toml` 의 `layout` 키는 hard cut 이다. `view` 와 `density` 를 새로 쓴다. 옛 `layout` 을 읽어 옮기는 코드는 만들지 않는다.
- 옛 `layout` 줄이 남은 파일은 오류 없이 읽고, 그 줄은 쓰지 않는다. 처음 켜면 기본값(E8)이다. 이 사실은 changelog 한 줄로 알린다. 화면 안 안내는 만들지 않는다.
- 시안의 시뮬레이션 키(`f` `r` `u` `c` `d` `D` `x`)와 `[sim]` 표시는 시연 장치라서 올리지 않는다.

### 2.7 시안과 다르게 정한 것

| 시안 | 이 RFC | 이유 |
| --- | --- | --- |
| 보기 순환 `o` | `v` · `V` | `o` 는 정렬이다(E3 · E4) |
| 목록에서 `s` `m` 으로 dock 쪽 열기 | Story 창 안에서만 | 목록의 `s` 는 shutdown, `m` 은 대화다(E6) |
| 시뮬레이션 키와 `[sim]` | 올리지 않는다 | 시연 장치다 |
| runtime 교차표(실패 Keeper × runtime) | V1 은 runtime id 로 묶고, V5 가 교차표로 바꾼다 | 묶기는 V1 의 묶는 함수로 바로 된다. 교차표는 `Masc_tui_keeper_trail.attempts_of_runtime` 을 읽는 새 그리기다 |
| 24h 벽의 세 묶음(실패 · 그 밖 · 정상)과 시간 눈금자 | V4 에 넣는다 | 48칸 맥박과 같은 층의 그리기다 |
| 월드 행을 골라 월드 창(Keeper 기억 → 원장 → 브리핑) | W1 | 월드 줄(RFC-0511 D2c)이 고를 수 있는 행이 되어야 한다 |
| 나이별 ◂ 의 촘촘한 나이 막대(30d · 7d · 1d · 6h · 1h) | `age_bins` 4칸(1시간 · 하루 · 1주 · 그 뒤) | 서버가 주는 칸이 넷이다(E17) |
| 나이별 머리 띠의 `stale events/day` · `changed` · `gone` | 그리지 않는다 | 무효화 시각은 약 3MB 인 `workspace-memory-context` 응답에만 있다(E18) |

### 2.8 머리 띠와 묶음 제목 줄

시안은 목록 위에 두 줄 띠를 두고, 묶음 제목 줄에도 세 칸을 그린다. V8 이 이 둘을 올린다.

- 띠 첫 줄은 지금 보기의 묶음마다 표지 · 수 · 수만큼의 막대를 그린다. 예: `! 2 failing ▫▫  ✓ 20 recovered ■■■■  ○ 14 paused ····`
- 띠 둘째 줄의 왼쪽은 함대 실패 띠다. 지난 12시간의 30분 칸마다 모든 행의 `recent_turns` 실패 수를 더한다. 오른쪽은 지금 선 뒤의 앞 12시간 깰 시각 수 띠다. 오른쪽은 V7 의 값을 쓴다.
- 묶음 제목 줄의 세 칸은 묶음의 합이다. ◂ 는 맥박 합, ● 는 묶음의 수, ▹ 는 깰 시각 띠 합이다. 기억별에서 ▹ 는 `Σ lag` 다.
- 맨 아래의 고른 Keeper 줄은 지금의 `selected ·` 줄을 세 칸 요약으로 바꾼다. 예: `ocaml-agent-ic ○ idle 77m · since 11-05 18:51 · ◷ 13:33 every 10m · lag 1`. 반복 표기(`every 10m`)는 V7 의 닫힌 값으로 쓴다.
- 고른 Keeper 줄은 Story 창이 닫혀 있을 때만 그린다. 창 story 쪽의 ● 지금 · ▹ 다음이 같은 값이라서다(시안도 창이 열리면 이 줄 대신 창을 그린다). 창과 이 줄은 목록 끝과 푸터 구분선 사이 같은 자리를 쓴다.

## 3. 층

한 스택으로 쌓는다. 밑동은 이 RFC 다. 층 하나는 한 가지 결과이고 OCaml 약 300줄 이하다.

| 층 | 결과 | 바뀌는 곳 |
| --- | --- | --- |
| R0 | 이 RFC | `docs/rfc/` |
| P1 | 맥박 30분 칸 저장과 행 JSON hard cut, TUI 정시 칸 | `lib/keeper/keeper_turn_pulse.ml(i)`, `lib/keeper/keeper_tool_surface_ops.ml`, `lib/tui_decode.ml`, `dashboard/src/api/schemas/gate-keepers.ts`, `bin/masc_tui_keeper_pulse.ml`, `bin/masc_tui_keeper_mark.ml`, 시험 |
| P2 | Detailed 첫 줄이 DETAIL 을 빼고 둘째 줄만 문장을 쓴다 | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_render_schedule.ml` |
| V1 | 보기 타입 · 묶는 함수 · `v` `V` · 설정 hard cut · 기본값(E8) | `bin/masc_tui_keeper_list_model.ml(i)`, `bin/masc_tui_config.ml(i)`(`layout` 을 읽는 갈래와 그 오류, 다른 선택을 지키는 검사의 `layout` 을 함께 지운다), `bin/masc_tui.ml` 키 두 곳, `bin/masc_tui_render_keepers.ml` 묶음 제목 |
| V2 | 보기 탭 줄과 누르기, `[` `]` 묶음 이동, 제목 줄 `←` `→` 접기 | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui.ml` |
| V3 | 한 축 줄의 세 칸 틀과 상태별 · 원인별 · 시간별 칸(§2.4) | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis.ml` |
| V4 | 24h 보기의 48칸 맥박, 세 묶음, 시간 눈금자 | `bin/masc_tui_keeper_pulse.ml`, `bin/masc_tui_render_keepers.ml` |
| V5 | runtime 보기의 교차표 | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_trail.ml` |
| V6 | 기억별 · 나이별 칸(§2.4) | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_memory_reading.ml(i)` |
| V7 | 앞 12시간 일정 띠와 고른 줄의 반복 표기 | `lib/schedule/schedule_domain.mli`(반복 디코더를 연다), `bin/masc_tui_keeper_next_run.ml(i)`, `bin/masc_tui_render_keepers.ml`, 시험 |
| V8 | 머리 띠 두 줄, 묶음 제목 줄의 세 칸 합, 고른 Keeper 줄(§2.8) | `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis.ml` |
| S1 | Story 창(A 단계 값만): story · 일정 · 기억 세 쪽 | 새 모듈 `bin/masc_tui_keeper_story.ml(i)`, 키 처리 |
| S2 | Story 창의 마지막 wake 줄(B 단계) | Story 모듈, 일정 읽기 |
| S3 | Story 창의 시간순 피드 | Story 모듈, 값 출처는 확인 필요 |
| W1 | 월드 줄 고르기와 월드 창 | `bin/masc_tui_render_keepers.ml`, 월드 줄 모듈 |

- V 층은 V2 → V3 → V6 → V7 → V8 → V4 → V5 → W1 순서로 올린다. V3 이 세 칸 틀을 한 번 만들고, 뒤 층은 칸 값만 더한다(E16). S 층은 V 층과 따로 main 위에 올린다.
- P1 · P2 는 보기와 무관하게 지금 화면을 고친다. 그래서 R0 · P1 · P2 를 한 스택으로 먼저 착지하고, V1 부터는 그 뒤에 새로 쌓는다(E14). 어느 스택이든 맨 위 PR 로 한 번에 병합한다(`docs/guides/NATIVE-GITHUB-STACKS.md`).
- P1 은 서버 저장 · 행 JSON · 디코더 · TUI 칸이 hard cut 으로 함께 바뀌어야 해서 300줄 기준을 넘었다(+707 · −577).
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
2. **동작 시험.** P1 은 서버 저장(칸 경계 · 24시간 지우기 · `known_since`)과 디코더의 닫힌 갈래를 본다. V1 은 보기마다 묶는 함수가 닫힌 값만 쓰는지 본다. V7 은 반복(`Interval` · `Daily` · `Cron` · `One_shot`)마다 12시간 안의 깰 시각을 고르는 함수를 본다. 화면 글과 배치는 보지 않는다.
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
| E8 | 처음 켤 때의 보기 · 밀도 | 상태별 · 두 줄 | 11-09 운영자가 본 화면은 `grouped` 라 둘째 줄 칸이 안 보였다. 상태별은 그 묶음을 지킨다. V3 전에는 상태별도 목록 줄 모양이라 두 줄이 맥박 · 일정 · lag 칸을 보인다. V3 부터는 한 축 줄 첫 줄이 그 칸을 들고, 두 줄은 실패 사슬과 원인을 더한다(§2.4 · §2.6) |
| E9 | `[` `]` 가 겹칠 때 | `K` 창이 열려 있으면 그 창, 아니면 묶음 이동 | 열린 창이 키를 먼저 받는 지금 규칙과 같다 |
| E10 | Story 창 자리 | 목록 아래(dock), 높이가 모자라면 목록 위 | 시안을 따른다. 목록과 창을 같이 본다 |
| E11 | runtime 보기 | V1 은 runtime id 로 묶고, V5 가 교차표 | 시안의 교차표를 따르되 묶는 함수부터 올린다 |
| E12 | 묶음 접기 키 | 제목 줄의 `←` `→` | 행 위의 `→` 는 상세라서 제목 줄에서만 받는다 |
| E13 | 옛 `layout` 줄 | 오류 없이 읽고 쓰지 않는다, changelog 로 알린다 | hard cut 이다. 호환 코드도 화면 안내도 만들지 않는다 |
| E14 | 착지 순서 | R0 · P1 · P2 스택을 먼저, V1 부터 새 스택 | P1 · P2 는 보기 없이도 지금 화면을 고친다. 정할 사람은 운영자다 |
| E15 | 열린 창과 겹치는 키 | 열린 창(Story · `K`)이 먼저 받는다 | Story 창의 `Tab` 과 전역 `Tab`(다음 화면), `K` 창의 `[` `]` 와 묶음 이동이 겹친다. E9 와 같은 규칙이다 |
| E16 | 보기마다 다른 칸 | V3 이 세 칸 틀을 만들고, 보기가 칸 값을 고른다 | V3 이 칸 값이 하나로 굳은 줄을 만들면 V6 · V7 이 그 줄을 다시 짠다 |
| E17 | 나이별 ◂ 칸 수 | `age_bins` 4칸 | 시안은 더 촘촘하다. 서버 칸을 늘리는 일은 이 RFC 밖이다 |
| E18 | 나이별 머리 띠 둘째 줄 | 그리지 않는다 | 무효화 시각은 약 3MB 응답에만 있다. 서버가 하루 무효화 수를 주면 다시 본다 |
| E19 | 앞 12시간 일정 띠의 재료 | `Schedule_domain` 의 반복 디코더를 열고, TUI 가 같은 `lib/schedule` 함수로 깰 시각을 구한다 | 대안은 서버가 앞 12시간 깰 시각을 행에 실어 주는 것이다. 서버와 TUI 가 같은 계산 함수를 링크하니 행 JSON 을 늘리지 않는다 |
| E20 | 초상 | 목록 보기 · 두 줄에서만, 전신(픽셀은 `Keeper_portrait_draw.render` 를 얼굴 초상과 같은 상자에, 모자이크는 Items 미리보기와 같은 24칸) | 2026-11-09 실측: 두 줄 보기 120x35 에서 초상이 약 9줄을 써서 Keeper 36명 중 4~6명만 보였다. 시안에는 초상이 없다. 운영자가 목록 보기에만 남기고 얼굴 대신 전신을 그리라고 골랐다. 모자이크 16칸에서는 관찰된 장비가 몸 색으로 뭉개져서 전신은 Items 의 24칸을 쓴다. 대화 머리의 얼굴 초상은 그대로다 |

## 8. 참고

- 시안: `docs/research/2026-11-06-keepers-list-past-now-next-preview.html`
- RFC-0511 §4 · §7 D5, RFC-0503, RFC-0481 §3.2, RFC-0418
- 저장: `lib/keeper/keeper_turn_pulse.ml`, 행 JSON: `lib/keeper/keeper_tool_surface_ops.ml`, 디코더: `lib/tui_decode.ml` 의 `decode_recent_turns`
- 맥박 칸: `bin/masc_tui_keeper_pulse.ml`, 범례: `bin/masc_tui_keeper_mark.ml`
