# Features 실행 목록: 고치기 전후

RFC `tui-one-screen-grammar` 의 첫 구현 층이 Features 실행 목록의 표를 어떻게 바꿨는지 보여 준다.

## 무엇을 그렸나

같은 실행 여섯 건을 표 코드에 넣고 안쪽 폭 196·116·76·56칸에서 그렸다. 기준 시각은
2026-11-11 15:43:00 KST 로 고정했다. 여섯 건은 오늘 네 건, 어제 한 건, 400일 전 한 건이다.

- `before.txt`: main(`eb22878fa756`)의 `bin/masc_tui_render_schedule.ml` 표 코드
- `after.txt`: 이 층의 표 코드

## 보이는 차이

| | 전 | 후 |
|---|---|---|
| 시작 | 늘 `11-11 15:36:13` | 오늘은 `15:36:13`, 올해는 `11-10 15:43:00`, 다른 해는 `2025-10-07` |
| 400일 전 실행 | `10-07 15:43:00` (올해 일과 구별되지 않음) | `2025-10-07` |
| 이름 | 16칸에서 가운데를 자름 (`kidsn…dd-manager`) | 폭이 있으면 자르지 않음, 없으면 끝을 자름 |
| 상태 | wire 철자를 11칸에서 가운데를 자름 (`com…unknown`) | 기호와 화면 언어의 낱말 (`✕ 결과 저장 불확실`) |
| 열 머리 | 영어 대문자 고정 | 화면 언어 |

## 한계

- 실행 중인 TUI 를 찍은 화면이 아니다. worktree 의 표 코드(`masc_tui_table`,
  `masc_tui_message_layout`, `masc_tui_value`, `masc_tui_render_schedule` 의 실행 목록 구간)를
  따로 컴파일해 표준 출력으로 그렸다. 틀, 색, 고른 줄 띠는 나오지 않는다.
- `masc_tui_theme` 은 `Glyph.no_value` 상수 하나만 든 대역으로 바꿨다(터미널 팔레트의 C stub 을
  피하려고).
- 상태 칸의 글자는 `bin/masc_tui_render_lanes.ml` 의 `lane_run_status_text` 가 내는 것을 그리는
  프로그램에 손으로 옮겨 적었다. 상태 사전 자체는 타입 검사만 거쳤다.
- 뒤쪽 공백은 지웠다.

## 다시 만들기

스크래치 폴더에 `lib/string_util/string_util.ml(i)`, `bin/masc_tui_frame.ml(i)`,
`bin/masc_tui_grapheme_segmentation.ml`, `bin/masc_tui_message_layout.ml(i)`,
`bin/masc_tui_table.ml(i)`, `bin/masc_tui_value.ml(i)` 를 복사한다. `run_table.ml` 은
`module Table = Masc_tui_table` 한 줄 뒤에 `bin/masc_tui_render_schedule.ml` 의
`(* Lane run columns.` 부터 `(* File change columns.` 앞까지를 붙여 만든다. 그리는 프로그램은
`draw-after.ml.txt`(전은 `draw-before.ml.txt`)다.

```
ocamlfind ocamlopt -package uucp,uuseg,unix -linkpkg -w -a \
  string_util.mli string_util.ml masc_tui_frame.mli masc_tui_frame.ml \
  masc_tui_grapheme_segmentation.ml masc_tui_message_layout.mli masc_tui_message_layout.ml \
  masc_tui_table.mli masc_tui_table.ml masc_tui_value.mli masc_tui_value.ml \
  masc_tui_theme.ml run_table.ml draw.ml -o draw
TZ=Asia/Seoul ./draw
```
