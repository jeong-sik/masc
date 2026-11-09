# RFC-0515 남은 층 구현 지시서 (2026-11-09)

Keepers TUI 를 Keeper Pulse 시안과 같은 모양으로 만드는 일이 반쯤 끝났어요. 이 문서는 남은 층을 다른 세션(Codex 등)이 이어받도록 범위, 순서, 겹치는 PR, 확인 방법을 한곳에 모아요. 설계 원본은 RFC-0515 예요. 이 문서는 RFC 를 바꾸지 않아요. RFC 와 이 문서가 다르면 RFC 를 따르고, 다른 곳을 보고해 주세요.

- 설계: [`docs/rfc/RFC-0515-keepers-list-gets-views-a-story-sheet-and-half-hour-pulse-slots.md`](../rfc/RFC-0515-keepers-list-gets-views-a-story-sheet-and-half-hour-pulse-slots.md) §2.3 · §2.4 · §2.7 · §2.8 · §3 · §5 · §7
- 시안: [`docs/research/2026-11-06-keepers-list-past-now-next-preview.html`](../research/2026-11-06-keepers-list-past-now-next-preview.html)
- 저장소 규칙: 저장소 루트 `AGENTS.md`, `docs/constitution.xml` 의 `<execution_protocol>`

## 1. 지금 상태 (main `78e52290` 기준)

| 층 | 결과 | 상태 |
| --- | --- | --- |
| P1 · P2 | 서버 30분 맥박 칸, Detailed 둘째 줄 | main |
| V1 · V2 | 보기 타입 · 묶는 함수 · 보기 탭 · 묶음 접기 키 | main |
| V3 · V6 | 한 축 줄 칸 값 | main(G1 이 격자로 옮김) |
| S1 · S2 · S3a · S3b | Story 창 | main |
| G1a · G1b | 격자 `layout(cols)`, `┃ ● now ┃`, due · lag 열, 실패 둘째 줄, 열 머리 | main(#50499 `ee773a34`, #50517 `90f5de90`) |
| G2 | 한 축 줄 맥박 30분 칸 `·▁▄█` | 진행 중. 브랜치 `feat/keepers-pulse-half-hour` |
| A1 | 나이 사다리 24칸 hard cut, memory 탭 `facts` 줄 쉬운 말 | 진행 중. 브랜치 `feat/keepers-age-ladder-24` |
| G3 계산 | 앞 12시간 깰 시각 띠 계산 | 리뷰 반영 중. #50469 |
| G3 그리기 | ▹ 띠 열에 `◷` | #50469 병합 뒤 |
| G4 | 원인별 회복 · 멈춤 묶음, 묶음 제목 줄의 합, 처음 접힘 | **이 문서가 넘기는 일** |
| V8 | 머리 띠 두 줄과 고른 Keeper 줄 | **이 문서가 넘기는 일** |
| V4 | 24h 벽 보기 | **이 문서가 넘기는 일** |
| V5 | runtime 교차표 | **이 문서가 넘기는 일** |
| W1 | 월드 줄 고르기와 월드 창 | **이 문서가 넘기는 일** |

시안과 다른 곳은 아래 열 대조로 셌어요(설치본 2026-11-09 08:5xZ, 120칸, 원인별). `┃` 열 위치와 이름 폭은 G1 공식과 같아요. 남은 차이는 맥박 칸(G2), 나이별 칸(A1), 띠의 `◷`(G3), 묶음 제목 줄의 합과 접힘(G4), 머리 띠(V8), 24h · runtime 보기(V4 · V5), 월드 줄(W1) 이에요.

## 2. 넘기는 층과 순서

권하는 순서는 V5 → V4 → G4 → V8 → W1 이에요. V5 는 진행 중인 층과 겹치는 곳이 가장 적어요. V4 는 G2 의 30분 글리프 함수를 쓰고, G4 와 V8 의 띠 합은 G3 값을 써요. 앞 층이 main 에 들어오기 전이면, 그 값을 쓰는 칸은 비워 두고 PR 본문 "확인하지 않은 것" 에 적어요.

### 2.1 V5 runtime 교차표

- 무엇: runtime 보기를 "실패 Keeper × runtime" 교차표로 그려요. 지금은 runtime id 로 묶은 격자 줄이고 칸 값은 상태별과 같아요.
- RFC: §2.3 runtime 줄, §2.7 runtime 교차표 줄, E11
- 시안: `drawMatrix`, 보기 `matrix`. 글 화면 `matrix-{171x45,120x35,80x24}.txt`(§4.2)
- 값: `Masc_tui_keeper_trail.attempts_of_runtime`. 새 서버 값은 만들지 않아요.
- 바뀌는 곳: `bin/masc_tui_render_keepers.ml`(runtime 보기 갈래), `bin/masc_tui_keeper_trail.ml(i)`
- 시험: 교차표 칸을 고르는 함수가 닫힌 값만 쓰는지

### 2.2 V4 24h 벽

- 무엇: 24h 보기를 30분 맥박 48칸으로 그려요. 폭이 모자라면 시안처럼 48칸보다 적게 그려요. 세 묶음(실패 · 그 밖 · 정상)과 시간 눈금자(`HH:00` 이 이어지는 머리)를 둬요. 지금은 상태별과 같은 12시간 격자를 그리면서 이름만 `24h` 예요.
- RFC: §2.3 24h 줄(실패한 30분 칸 수가 많은 순), §2.7 24h 벽 줄, E2
- 시안: `drawWall`, `wallOrder`, 보기 `wall`. 글 화면 `wall-*.txt`
- 값: 서버 30분 칸 `kr_recent_turns.slots`(24시간 보관). 글리프 고르기는 G2 의 함수를 다시 써요. 같은 글리프 규칙을 두 번 쓰지 않아요.
- 바뀌는 곳: `bin/masc_tui_keeper_pulse.ml(i)`(G2 와 같은 파일이에요. G2 가 main 에 들어온 뒤 시작해요), `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis_row.ml`(`shape_of_view` 의 `Day_wall` 갈래)

### 2.3 G4 묶음 제목 줄과 처음 접힘

- 무엇
  - 원인별 `cause_bucket` 에 회복 · 실패 없음 · 멈춤을 더해요. 실패 원인 묶음(`Cause_named` · `Cause_unnamed`) 뒤에 둬요.
  - 묶음 제목 줄의 ● 열 · ▹ 쪽 · 오른쪽 열을 RFC §2.4.7 표대로 채워요.
  - 처음 열 때 접힌 묶음을 E26 대로 정해요.
- RFC: §2.3, §2.4.2(판정), §2.4.7(표, 오래 쉰 자율 Keeper, 처음 접힘), E26
- 시안: `paintLane`(묶음 제목 줄), `aggPulse` · `aggRuler`(제목 줄의 합), `fold0`(처음 접힘), `oddDormant`, `toggleFold`
- 지금 있는 것: 접기 · 펼치기 키와 `Masc_tui_keeper_list_model.refold` · `stops` 는 main 에 있어요(V2). G4 는 처음 접힘 값과 합만 더해요.
- 판정 순서: G1a 는 실패 → 멈춤 → health 순서로 판정해요(`Masc_tui_keeper_grid.verdict`). §2.3 의 "멈춤이 먼저다" 와 같은 뜻인지 확인해요. 다르면 코드를 바꾸기 전에 보고해요.
- 띠 합(`깰 시각 합의 띠`)은 G3 값이에요. G3 그리기가 main 에 없으면 비워 둬요.
- 바뀌는 곳: `bin/masc_tui_keeper_list_model.ml(i)`, `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_config.ml(i)`(접힘을 저장한다면)
- 시험: 원인별 묶는 함수가 닫힌 판정만 쓰는지(RFC §5.2)

### 2.4 V8 머리 띠와 고른 Keeper 줄

- 무엇
  - 목록 위 두 줄 띠를 그려요. 첫 줄은 고정된 넷(`! N failing` · `✓ N recovered` · `● N ok` · `○ N paused`, 나이별은 `fresh · today · cooling · dormant`)이에요. 둘째 줄은 fleet 30분 실패 수와 깰 시각 수예요.
  - 맨 아래 `selected ·` 줄을 세 칸 요약으로 바꿔요.
- RFC: §2.8 전부, E18, E24
- 시안: `drawHeader`, `stripGroups`, `stripAge` · `drawAgeSummary`(나이별), `currentKeeper` · `drawFooter`(고른 Keeper 줄). 글 화면 각 보기의 2 · 3번째 줄
- 겹침
  - 다른 PR(`feat/keepers-fleet-proactive-interval`)이 fleet 줄에 `proactive every 5m` 를 더해요. V8 이 그 줄을 옮기거나 바꾸면 그 읽기를 지켜요.
  - 둘째 줄 띠 열과 고른 Keeper 줄의 반복 표기(`every 10m`)는 G3 값이에요.
- 바뀌는 곳: `bin/masc_tui_render_keepers.ml`, `bin/masc_tui_keeper_axis.ml(i)`

### 2.5 W1 월드 줄

- 무엇: 기억별 · 나이별 보기 맨 위에 월드 줄을 같은 격자로 그리고, 고를 수 있게 해요. 고르면 월드 창(Keeper 기억 → 원장 → 브리핑)을 열어요.
- RFC: §2.3 마지막 줄, §2.4.7 월드 줄, §2.7 월드 행 줄, RFC-0511 D2c
- 시안: `paintWorld`, `worldWord`, `selectWorld`, `dockWorld`(월드 창)
- 지금 있는 것: Memory 화면의 `memory_world_rows`(`bin/masc_tui_render_memory.ml:899`)
- 바뀌는 곳: `bin/masc_tui_render_keepers.ml`, 월드 줄 모듈(새로 만들면 `.mli` 와 같이)

## 3. 겹치는 PR 과 파일

`bin/masc_tui_render_keepers.ml` 은 거의 모든 층이 고쳐요. 층마다 다른 함수를 고치고, 앞 PR 이 main 에 들어오면 main 위로 다시 올려요. 다른 PR 의 브랜치에 커밋하지 않아요.

| 진행 중 | 브랜치 · PR | 고치는 파일(이 일에서는 건드리지 않음) |
| --- | --- | --- |
| G2 | `feat/keepers-pulse-half-hour` | `bin/masc_tui_keeper_pulse.ml(i)`, `bin/masc_tui_keeper_mark.ml(i)`, render_keepers 의 맥박 열 |
| A1 | `feat/keepers-age-ladder-24` | `lib/keeper/keeper_memory_age_bins.ml(i)`, `lib/server/server_dashboard_http_keeper_memory_health.ml`, `lib/tui_decode_memory_health.ml`, `dashboard/src/api/dashboard-misc.ts`, `bin/masc_tui_keeper_age_ladder.ml`, `bin/masc_tui_keeper_memory_reading.ml(i)`, `bin/masc_tui_render_memory.ml`, render_keepers 의 나이별 열, `bin/masc_tui_render_keeper_story.ml` 의 `memory_lines` |
| G3 계산 | #50469 `feat/keepers-wake-strip-data` | `bin/masc_tui_keeper_next_run.ml(i)`, `bin/masc_tui_types.ml` 의 `sch_recurrence`, `bin/masc_tui_schedule_decode.ml`, `lib/schedule/schedule_domain.ml(i)`, `bin/masc_tui_keeper_axis.ml(i)` 의 띠 접근자 |
| fleet 간격 | `feat/keepers-fleet-proactive-interval` | `lib/fleet_stream/*`, render_keepers 의 fleet 줄, `bin/masc_tui_fleet_summary.ml` |
| 일정 탭 정렬 | #50522 | `bin/masc_tui_render_keeper_story.ml` 의 `schedule_lines` |

시작 전에 `gh pr list --repo jeong-sik/masc --state open --search "keepers in:title"` 로 위 표가 아직 맞는지 봐요. 병합됐으면 main 에 있는 코드를 써요.

## 4. 확인 방법

### 4.1 정해진 것

- 로컬 `dune build` · `dune runtest` 는 돌리지 않아요(헌법 `execution_protocol`). PR 의 `type-check` 가 판정해요. push 뒤 한 번만 읽어요. CI 감시 루프는 돌리지 않아요.
- 시험은 동작만 봐요. 묶는 함수, 칸 값을 고르는 함수, 디코더의 닫힌 갈래예요. 화면 글 · 배치 · 행 순서 시험은 쓰지 않아요(헌법 354-355, RFC §4).
- 결과는 캡처로 보여요. 120x35 와 80x24 의 전 · 후 tmux 캡처를 남기고, 절대 경로 · 토큰 · 계정 이름은 가려요.

### 4.2 시안 대조

낱말이 있는지만 세면 뼈대 차이를 못 봐요. 그래서 같은 목록 폭에서 열 단위로 견줘요(RFC §5.5). 아래 경로는 이 기기의 로컬 파일이에요.

- 시안 글 화면(보기 6 × 폭 3): `/Users/dancer/.claude/projects/-Users-dancer-me-workspace-yousleepwhen-masc/memory/tools/keepers-capture/mock-text/<view>-<WxH>.txt`. 이름 `matrix` 는 runtime, `wall` 은 24h 예요.
- 시안 글 화면을 다시 뽑는 법: 같은 폴더의 `mock-dump-README.md`
- 설치본 캡처: 같은 폴더의 `keepers_capture.sh <out-dir> <label>`. `SIZES="171x45 120x35 80x24"` 로 폭을 고르고, 설치된 `masc-tui` 를 tmux 에 띄워 8 보기 × 2 밀도를 찍은 뒤 설정을 되돌려요.
- 열 대조: 같은 폴더의 `python3 -I keepers_grid_compare.py <out-dir> <label>`. 보기 · 폭 · 밀도마다 `┃` 열, 목록 폭, 이름 폭, 맥박 칸 수, 열마다 글리프와 값 꼴을 시안과 나란히 표로 내요. TUI 테두리 때문에 120칸 화면의 목록 폭은 118 이에요. 이것은 차이가 아니에요.
- V4 · V5 는 격자가 아닌 화면이라 이 스크립트가 재지 않아요. 같은 폭의 `wall` · `matrix` 글 화면과 줄 단위로 견주고, 재는 것(칸 수, 머리 눈금 위치, 묶음 수)을 PR 본문 표로 남겨요.

### 4.3 리뷰

- 올리기 전에 새 맥락의 읽기 전용 리뷰어가 diff 를 읽어요.
- 병합에는 지금 head 의 독립 승인 2개가 필요해요. Ready 로 바꾸는 일과 병합은 운영자가 해요.

## 5. 지켜야 할 것

- OCaml: 반환은 `Result`, catch-all `_ ->` 금지, `Obj.magic` 금지, 문자열 분류 금지(typed variant 와 exhaustive `match`), 뜻 없는 리터럴은 상수로 둬요. 판정은 RFC §2.4.2 의 닫힌 값에서만 해요.
- 모르는 값은 기본값으로 바꾸지 않아요. 모르면 `?` 로 그려요.
- hard cut 스키마 변경에는 호환 reader · converter · migration 을 만들지 않아요.
- 고치기 전에 `rg "<대상>" lib/ bin/ test/ dashboard/src` 로 호출처를 모두 봐요.
- `docs/guides/TUI-KEYS.md` 는 생성 문서예요. 범례나 키를 바꾸면 생성기 출력과 맞춰요.
- 층 하나는 한 가지 결과이고 OCaml 약 300줄 이하예요. 넘으면 나눠요.
- 시안과 다르게 정하면 RFC §2.7 표에 적을 줄을 PR 본문에 제안해요. RFC 를 같은 PR 에서 고치지 않아요.

## 6. Git 과 PR 절차

- 저장소 루트 체크아웃은 다른 세션이 써요. 일은 `.worktrees/<branch>` 에서 해요: `git fetch origin main && git worktree add -b <branch> .worktrees/<branch> origin/main`
- 이 저장소는 partial clone 이라 push 는 `git push --no-thin` 이에요. force push 는 하지 않아요. main 이 앞서가면 merge 로 따라가요.
- 두 번째 push 부터는 전에 `gh pr view <N> --json state -q .state` 가 정확히 `OPEN` 인지 봐요. 병합된 PR 브랜치에 push 하지 않아요.
- 커밋은 영어 Conventional Commits 예요. 파일 단위로 `git add <file>` 해요.
- PR 은 Draft 로 열고 제목 · 본문은 한국어로 써요. 본문은 사람이 읽을 부분(무엇이 바뀌나, 확인한 것, 확인하지 않은 것)과 리뷰어용 부분을 나눠요.
- `changelog.d/<PR>.md` 를 더하고 `python3 scripts/changelog-fragments.py check-files changelog.d/<PR>.md` 로 확인해요. 형식은 `changelog.d/README.md` 예요.
- 커밋 전에 test stanza 의 의존을 확인해요. `-open Masc` 가 없는 test stanza 는 `Masc.X` 로 가리켜요.

## 7. 끝나면 남길 것

층마다 PR 본문에 아래를 적어요.

- 지금 head SHA, `type-check` run id 와 결론
- 시안 대조 표(§4.2)와 120x35 · 80x24 캡처 경로
- 시안과 다르게 정한 것
- 확인하지 않은 것
