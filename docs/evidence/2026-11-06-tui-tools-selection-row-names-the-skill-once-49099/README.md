# The Tools selection row and the document below it name a skill once

PR #49099. The System ▸ Tools screen drew the selected skill, or the selected async request, twice in a row: the highlighted selection row, then a bold `Action Skill:` (or ` 요청:`) row under the divider that named the same thing. With nothing selected the two rows read `Skill: none` and `Action Skill: none`, and `Async request: none` sat over a sentence that said the same.

Before is the proof build of `main` at `6ad837c7cac` (run 42154515127). After is the proof build of this PR's code commit `973425b7cd6` (run 42155231130); the evidence commit that carries this README comes after it and changes no code. Both ran against a fixture server that has no skill profile and no async request, so every screen below is the nothing-selected case. Each pane was read at 80x24 and 100x30. The first pane was read 12 seconds after the screen opened, after the workspace read that the title row shows as `reading workspace` had finished; each next pane was read 2 seconds after its `p` key.

## The rows on screen

From the title row down to the third row under the divider, as the capture drew them, clock masked.

### Calls scope, 80x24

Before

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  ▸호출 범위  비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Skill: none
 ──────────────────────────────────────────────────────────────────────────────
 Action Skill: none
  선택 Keeper의 도구·Skill 노출 범위입니다.
    ORIGIN=도구 출처 · 전달 지원과 실제 호출은 별도입니다.
```

After

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  ▸호출 범위  비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Skill: none
 ──────────────────────────────────────────────────────────────────────────────
  선택 Keeper의 도구·Skill 노출 범위입니다.
    ORIGIN=도구 출처 · 전달 지원과 실제 호출은 별도입니다.
    사용 증거: Skill 기록 · Tool 호출별 입출력: Acting
```

### Calls scope, 100x30

Before

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  ▸호출 범위  비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Skill: none
 ──────────────────────────────────────────────────────────────────────────────────────────────────
 Action Skill: none
  선택 Keeper의 도구·Skill 노출 범위입니다.
    ORIGIN=도구 출처 · 전달 지원과 실제 호출은 별도입니다.
```

After

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  ▸호출 범위  비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Skill: none
 ──────────────────────────────────────────────────────────────────────────────────────────────────
  선택 Keeper의 도구·Skill 노출 범위입니다.
    ORIGIN=도구 출처 · 전달 지원과 실제 호출은 별도입니다.
    사용 증거: Skill 기록 · Tool 호출별 입출력: Acting
```

### Async requests, 80x24

Before

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  호출 범위  ▸비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Async request: none
 ──────────────────────────────────────────────────────────────────────────────
  선택한 비동기 요청 없음
  워크스페이스의 비동기 요청·복구 상태입니다.
    J/K:요청 선택 · Enter:상세 · t:원본 Task · o:원본 ID · r:재조회 · Esc:뒤로
```

After

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  호출 범위  ▸비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Async request: none
 ──────────────────────────────────────────────────────────────────────────────
  워크스페이스의 비동기 요청·복구 상태입니다.
    J/K:요청 선택 · Enter:상세 · t:원본 Task · o:원본 ID · r:재조회 · Esc:뒤로
    active=활성 원장 요청 수 · runtime-owned=현재 런타임 소유
```

### Async requests, 100x30

Before

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  호출 범위  ▸비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Async request: none
 ──────────────────────────────────────────────────────────────────────────────────────────────────
  선택한 비동기 요청 없음
  워크스페이스의 비동기 요청·복구 상태입니다.
    J/K:요청 선택 · Enter:상세 · t:원본 Task · o:원본 ID · r:재조회 · Esc:뒤로
```

After

```text
  MASC System / Tools  hh:mm:ss  HTTP [connected]
  호출 범위  ▸비동기 작업  Skill 기록  Skill 사용 집계  전체 도구
 Async request: none
 ──────────────────────────────────────────────────────────────────────────────────────────────────
  워크스페이스의 비동기 요청·복구 상태입니다.
    J/K:요청 선택 · Enter:상세 · t:원본 Task · o:원본 ID · r:재조회 · Esc:뒤로
    active=활성 원장 요청 수 · runtime-owned=현재 런타임 소유
```

## All five panes

`p` walks the panes. Rows that open the document under the divider with the selection's name, before and after, and the rows only one of the two captures has (blank rows left out).

| pane | size | name rows under the divider before | after | rows only in before | rows only in after |
|---|---|---|---|---|---|
| 호출 범위 | 80x24 | 1 | 0 | `Action Skill: none` | - |
| 호출 범위 | 100x30 | 1 | 0 | `Action Skill: none` | - |
| 비동기 작업 | 80x24 | 1 | 0 | `선택한 비동기 요청 없음` | - |
| 비동기 작업 | 100x30 | 1 | 0 | `선택한 비동기 요청 없음` | - |
| Skill 기록 | 80x24 | 1 | 0 | `Action Skill: none` | - |
| Skill 기록 | 100x30 | 1 | 0 | `Action Skill: none` | - |
| Skill 사용 집계 | 80x24 | 1 | 0 | `Action Skill: none`; `[rows 1-14/25]` | `└────────────────────────────────────────────────────────────────────────────┘`; `[rows 1-14/24]` |
| Skill 사용 집계 | 100x30 | 1 | 0 | `Action Skill: none` | - |
| 전체 도구 | 80x24 | 1 | 0 | `Action Skill: none`; `[rows 1-14/270]` | `keeper`; `[rows 1-14/269]` |
| 전체 도구 | 100x30 | 1 | 0 | `Action Skill: none`; `[rows 1-20/257]` | `MascBoardPost                    yes      public_mcp, spawned_agent_mcp, keeper`; `[rows 1-20/256]` |

Every pane at both sizes lost exactly the one name row.

In the panes that scroll (Skill 사용 집계 80x24, 전체 도구 80x24, 전체 도구 100x30) the position counter `[rows a-b/n]` reads one less in after, because the document has one row fewer. The window is as tall as before, so it shows one more row at its end; those are the other rows only the after capture has.

## When the document names the selection again

The selection row cuts the middle of a name that does not fit it (`fit_middle`), so the document under the divider repeats the name only when the row had to cut it. The fixture has no skill and no async request, so that case is not in the captures. The limits follow from the code: the row is `columns - 2` cells wide.

| terminal columns | row width (columns - 2) | longest skill name drawn once (`Skill 1/9: ` prefix) | longest request id drawn once (`Request: ` prefix) |
|---|---|---|---|
| 60 | 58 | 47 | 49 |
| 80 | 78 | 67 | 69 |
| 100 | 98 | 87 | 89 |
| 120 | 118 | 107 | 109 |
| 200 | 198 | 187 | 189 |

The widest `name:` among the 36 `SKILL.md` files in this repository is 27 cells, so each of them is drawn once at every width in the table.

## What the change is

`tools_selection_document` in `bin/masc_tui_render_tools.ml` took the state and always returned the name row. It now takes `~cols` as well and returns the name row only when `display_width (selection row text) > Masc_tui_frame.inner_width ~cols`, the same condition under which `tools_selection_line` cuts the name. With nothing selected it returns no rows, because the selection row already says `none`. The prefixes `Skill n/m: ` and `Request: ` that both functions need are defined once, as `skill_selection_prefix` and `request_selection_prefix`.

## Test

This layer adds no test. `docs/constitution.xml` rules out tests of TUI layout and row order, so the rows are shown by the captures above. The type of `tools_selection_document` pins the call: it needs `~cols`, and the title pair is a `(style, text)` pair. The changed module was type checked without dune (`ocamlfind`, exit code 0), and two edits that break it (the call without `~cols`, the title as a bare string) fail that check with exit code 2.

## Not changed

- The selection row, the pane strip and the rows under the document head are the same text before and after.

- Languages. The selection row is English and the async document is Korean; the screen language policy is not part of this change.
