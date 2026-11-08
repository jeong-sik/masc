# Code 파일 푸터가 diff·history·blame·notes 키를 먼저 보여요(#50150)

Code 화면에서 파일을 열면 푸터 키 줄에 `d:diff`, `H:history`, `b:blame`, `m:notes`, `y:copy source` 가 없었어요. 300칸에서도 `K:hover R:references D:definition B:back e:edit draft S:save draft V:draft comparison X:discard draft` 가 그 자리를 채웠어요. 푸터는 키 표 순서대로 앞에서부터 채우는데, 표에서 이 다섯 키가 언어 서버 키와 초안 키 뒤에 있었어요.

## 바꾼 것

- `bin/masc_tui_keys.ml` Code 표에서 `d`, `H`, `b`, `m`, `y` 를 `K` 앞으로 옮겼어요. 키 동작과 도움말 시트 글은 그대로예요.
- 파일 창 푸터에서 `Shift-Left / Shift-Right:pan`(28칸)을 `Shift-←/→:pan`(13칸)으로 줄여요. Diff 창 푸터는 이미 그렇게 써요. 도움말 시트는 전체 이름을 그대로 둬요.
- `docs/guides/TUI-KEYS.md` 는 표에서 만든 문서라 같은 순서로 다시 만들었어요.

## 잰 것

- 증명 빌드 둘이에요. 앞은 `214806e33111`(run 42518546224, masc-tui sha256 `2309d3076818…`)이에요. 이 PR 의 바탕 커밋(`789b0b150b91`)과 소스가 같아요. 두 커밋의 차이는 `docs/evidence/` 와 `changelog.d/` 파일뿐이에요. 뒤는 이 브랜치 머리 `deda60d70427`(run 42524666622, masc-tui sha256 `6ea4453a1594…`)이에요.
- 같은 서버 환경에서 읽었어요. 알림이 없는 환경이에요. 작은 Git 저장소를 서버 작업 폴더에 만들었어요. `src/main.ml`(90줄 넘게, 첫 줄에 `masc(fixture)` 메모)은 커밋 둘과 작업 폴더 변경이 있고, `README.md` 는 작업 폴더에서 고쳐졌고 `notes.txt` 는 추적하지 않아요.
- Code 화면 상태 7개 x 폭 7개(80, 100, 120, 140, 160, 200, 300칸, 30줄) = 49곳의 푸터 줄(아래에서 둘째 줄)을 읽었어요. 상태는 저장소 루트 파일 목록(tree), `src` 안 파일 목록(subdir), 파일 창(`README.md`)(file), 파일 창(`src/main.ml`, 메모가 있어요)(memo), Diff 창(`README.md`)(diff), 메모 창(`src/main.ml`)(notes), History 창(`src/main.ml`)(history)예요.

## 결과

- 49곳 중 14곳의 푸터가 바뀌었어요. 바뀐 상태는 파일 창 둘(`README.md`, `src/main.ml`)이에요. 나머지 다섯 상태(폴더 목록 둘, Diff 창, 메모 창, History 창)는 푸터 줄이 폭마다 글자까지 같아요.
- 두 파일 창의 푸터는 폭마다 글자까지 같아요. 두 빌드 모두 그래요.
- 이름이 보이는 `d H b m y` 개수는 앞 0개에서 폭 120칸 1개, 140칸 4개, 200칸 4개, 300칸 5개로 늘어요. 80칸과 100칸은 앞에서도 `Home/End:top/bottom` 이 안 들어가던 폭이라 그대로예요.
- 이름이 보이는 언어 서버 키와 초안 키(`K R D B e S V X`)는 앞 140칸 1개, 200칸 2개, 300칸 8개에서 뒤 140칸 0개, 200칸 0개, 300칸 6개로 줄어요. 좁은 폭에서는 이 키들이 먼저 잘려요. 300칸에서 잘리는 건 `V`, `X` 예요.
- 80칸 파일 창은 `Shift-←/→:pan` 이 처음 보여요. 앞에서는 이름이 28칸이라 안 들어갔어요.
- 읽은 파일에는 초안이 없는데 300칸 푸터에 `S:save draft` 가 나와요. 푸터가 초안이 있는지 보지 않아서 그래요.

| 폭 | 앞 | 뒤 |
|---|---|---|
| 80 | `j/k:scroll  h/l:pane  Left / Esc:back  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  Left / Esc:back  q:quit  …?` |
| 100 | `j/k:scroll  h/l:pane  Shift-Left / Shift-Right:pan  PgUp/PgDn:page  Left / Esc:back  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  PgUp/PgDn:page  Left / Esc:back  q:quit  …?` |
| 120 | `j/k:scroll  h/l:pane  Shift-Left / Shift-Right:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  d:diff  q:quit  …?` |
| 140 | `j/k:scroll  h/l:pane  Shift-Left / Shift-Right:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  K:hover  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  d:diff  H:history  b:blame  m:notes  q:quit  …?` |
| 160 | `j/k:scroll  h/l:pane  Shift-Left / Shift-Right:pan  PgUp/PgDn:page  Left / Esc:back  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  q:quit  …?` |
| 200 | `j/k:scroll  h/l:pane  Shift-Left / Shift-Right:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  K:hover  R:references  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  d:diff  H:history  b:blame  m:notes  q:quit  …?` |
| 300 | `j/k:scroll  h/l:pane  Shift-Left / Shift-Right:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  K:hover  R:references  D:definition  B:back  e:edit draft  S:save draft  V:draft comparison  X:discard draft  q:quit  …?` | `j/k:scroll  h/l:pane  Shift-←/→:pan  PgUp/PgDn:page  Home/End:top/bottom  Left / Esc:back  d:diff  H:history  b:blame  m:notes  y:copy source  K:hover  R:references  D:definition  B:back  e:edit draft  S:save draft  q:quit  …?` |

`README.md` 와 `src/main.ml` 파일 창의 푸터예요.

## 화면

앞(위)과 뒤(아래)예요. 푸터는 맨 아래에서 둘째 줄이에요.

파일, 80칸

![앞](file-w080-before.png)

![뒤](file-w080-after.png)

파일, 140칸

![앞](file-w140-before.png)

![뒤](file-w140-after.png)

파일, 300칸

![앞](file-w300-before.png)

![뒤](file-w300-after.png)

## 시험

Test 워크플로 run 42524663701 이 이 브랜치에서 통과했어요: `test_tui_keys_doc`(`docs/guides/TUI-KEYS.md` 가 표에서 만든 글과 같은지), `test_tui_keys` 70개, `test_tui_footer_detail_state` 7개, `test_tui_footer_row_need` 14개, `test_tui_footer_notice_forms` 4개, `test_tui_help_filter` 20개예요. 증명 빌드가 만든 `key-reference.md` 도 `docs/guides/TUI-KEYS.md` 와 바이트까지 같아요.

## 재지 않은 것

- 언어 서버가 붙은 환경이에요. `K`, `R`, `D`, `B` 가 실제로 답하는 모습은 읽지 않았어요.
- 초안이 있는 파일의 푸터예요. `footer_hints_code` 가 초안 상태를 받지 않아서 초안이 있어도 같다고 읽었어요.
- 알림이 있는 환경이에요. 알림이 키를 밀어내는 일은 #49925 가 다뤄요.
- 80칸보다 좁은 폭과 30줄이 아닌 높이예요.
- 파일 창이 아닌 상태(폴더 목록, Diff 창, 메모 창, History 창)의 푸터는 이 PR 이 바꾸지 않았어요. 위에서 읽은 값도 앞뒤가 같아요.
