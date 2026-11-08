# Keepers 둘째 줄의 실패 시간과 12시간 맥박 (#49995, #50001)

Keepers 목록 Detailed 둘째 줄에 칸 둘이 생겼어요. 실패 중인 keeper 에 `failing 3h05m` 이 붙고(#49995), 줄 끝에 12시간 맥박 `✓⊘✗·?` 12칸이 붙어요(#50001). 합성 Keeper 8명을 서버에 두고 80 · 120 · 200칸, 색 있음과 `NO_COLOR=1` 에서 전후를 찍었어요. 화면 글과 배치는 시험으로 고정하지 않아서(헌법 354-355행) 이 폴더의 화면과 표가 근거예요.

## 방법

합성 서버가 `/health`, roster(`/api/v1/gate/keepers`), 빈 턴 목록(`/api/v1/keepers/turns`), 빈 SSE 흐름만 답해요. 나머지 경로는 404 라서 머리줄에 `HTTP [partial] · operator quiz read failed +3` 이 보여요. roster 행의 모양은 `test/test_tui_keeper_control.ml` 의 `gate_row` 픽스처를 따랐고, 행마다 `failing_since` 와 `recent_turns` 를 채웠어요. 로컬 keeper 메타 파일 8개는 실제 파일 하나의 칸 배치를 따라 만들고 이름 · id · 시각 · 지침 글을 바꿨어요. 이 화면은 그 파일의 다른 칸을 보여 주지 않아요. 합성 서버와 메타 파일을 만드는 스크립트는 저장소에 넣지 않았어요.

tmux 3.6a 안에서 `env -i` 로 환경을 비우고 `TERM=xterm-256color` 로 TUI 를 띄웠어요. 크기는 80x24, 120x35, 200x45 이고, 색 없음은 `NO_COLOR=1` 이에요. 단계는 이래요.

1. TUI 를 띄우고 머리줄에 `HTTP [connected|partial]` 이 나올 때까지 기다려요.
2. 터미널이 묻는 색 질문에 답해요.
3. `3` 으로 Keepers 탭을 열어요. 이 세션들에서는 처음 화면이 Detailed 였어요.
4. 화면을 저장해요. 같은 세션에서 `v` 로 Compact 와 Grouped 도 찍어 봤지만, 이 PR 이 바꾸지 않는 레이아웃이라 이 폴더에는 Detailed 만 넣었어요.

- 전: main 의 증명 빌드 Minimal manual checks run 42489112438(성공), 커밋 `bffe49a985275ba3c0923fab996c49aa519b81ab`, `masc-tui` sha256 `9e7dc84c7d94ed671fee130d2b606625a69bef06f18ab3aef53229ef04d62ffd`, `--build-commit` 이 같아요.
- 후: #50001 head 의 증명 빌드 Minimal manual checks run 42490533158(성공), 커밋 `e362481e758c26d9c63e678046f6938256b500c9`, sha256 `de0742d1220ece49fa3b684611accf401bf44e15db3c9ba378e15acfeddbe8b2`, `--build-commit` 이 같아요. 이 빌드에 #49995 와 #50001 이 다 들어 있어서, 실패 칸과 맥박 칸이 한 빌드에서 같이 보여요.
- 두 빌드 사이에는 이 PR 의 파일 말고 main 커밋 하나(#49982, `lib/board_tool_adapter/board_tool_post.ml`)가 더 있어요. Keepers 목록과 상관없는 파일이에요.

## 합성 Keeper

이름은 모두 지어낸 이름이에요. 서버가 보내는 값은 요청 시각에서 거꾸로 센 값이라서, 화면의 시간은 찍을 때마다 같아요.

| keeper | health | `failing_since` | `recent_turns` | 확인하려는 것 |
| --- | --- | --- | --- | --- |
| alpha-failing | failing | 3시간 5분 전 | 실패 2번(0 · 1시간 전), 쉼 1번(6시간 전), 정상 3번 | 실패 시간과 맥박의 네 기호 |
| beta-unrecorded | failing | null | 실패(0시간 전), 정상(3시간 전) | 시작을 못 적은 실패는 `failing ?` |
| gamma-skewed | failing | 지금보다 120초 뒤 | 실패(1시간 전) | 서버와 화면의 시계가 어긋나면 `failing ?` |
| delta-mixed | healthy | null | 정상 · 쉼이 섞인 8번 | 정상 keeper 에는 `failing` 이 없어요 |
| epsilon-busy | healthy | null | 최근 8시간에 24번, `truncated` | 서버가 24개만 들고 있어서 오래된 4시간이 `?` |
| zeta-unseeded | healthy | null | null | 서버가 맥박을 안 보냈으면 12칸이 모두 `?` |
| eta-quiet | healthy | null | 턴 없음, `truncated` 아님 | 창 전체를 알고 비었으면 칸이 없어요 |
| theta-idle | idle | null | 12시간 모두 정상 | 12칸이 꽉 찬 모양 |

## 결과

둘째 줄의 왼쪽 DETAIL 글(`task task-0001 · health failing` 등)은 빼고, 오른쪽 칸만 옮겼어요. 색 있음과 색 없음에서 목록 줄(첫 줄과 둘째 줄)의 글은 같아요. 인물 그림은 색 있음에서만 그려져서 목록 위치가 달라요.

### 80칸

| keeper | 전 | 후 |
| --- | --- | --- |
| alpha-failing | `◷ ?  mem ?` | `failing 3h05m  ◷ ?  mem ?  ··✓··⊘✓··✓✗✗` |
| beta-unrecorded | `◷ ?  mem ?` | `failing ?  ◷ ?  mem ?  ········✓··✗` |
| gamma-skewed | `◷ ?  mem ?` | `failing ?  ◷ ?  mem ?  ··········✗·` |
| delta-mixed | `◷ ?  mem ?` | `◷ ?  mem ?  ✓⊘··✓··✓·⊘✓✓` |
| epsilon-busy | `◷ ?  mem ?` | `◷ ?  mem ?  ????✓✓✓✓✓✓✓✓` |
| zeta-unseeded | `◷ ?  mem ?` | `◷ ?  mem ?  ????????????` |
| eta-quiet | `◷ ?  mem ?` | `◷ ?  mem ?` |
| theta-idle | `◷ ?  mem ?` | `◷ ?  mem ?  ✓✓✓✓✓✓✓✓✓✓✓✓` |

### 120칸

| keeper | 전 | 후 |
| --- | --- | --- |
| alpha-failing | `◷ ?  mem ?` | `failing 3h05m  ◷ ?  mem ?  ··✓··⊘✓··✓✗✗` |
| beta-unrecorded | `◷ ?  mem ?` | `failing ?  ◷ ?  mem ?  ········✓··✗` |
| gamma-skewed | `◷ ?  mem ?` | `failing ?  ◷ ?  mem ?  ··········✗·` |
| delta-mixed | `◷ ?  mem ?` | `◷ ?  mem ?  ✓⊘··✓··✓·⊘✓✓` |
| epsilon-busy | `◷ ?  mem ?` | `◷ ?  mem ?  ????✓✓✓✓✓✓✓✓` |
| zeta-unseeded | `◷ ?  mem ?` | `◷ ?  mem ?  ????????????` |
| eta-quiet | `◷ ?  mem ?` | `◷ ?  mem ?` |
| theta-idle | `◷ ?  mem ?` | `◷ ?  mem ?  ✓✓✓✓✓✓✓✓✓✓✓✓` |

### 200칸

| keeper | 전 | 후 |
| --- | --- | --- |
| alpha-failing | `◷ ?  mem ?` | `failing 3h05m  ◷ ?  mem ?  ··✓··⊘✓··✓✗✗` |
| beta-unrecorded | `◷ ?  mem ?` | `failing ?  ◷ ?  mem ?  ········✓··✗` |
| gamma-skewed | `◷ ?  mem ?` | `failing ?  ◷ ?  mem ?  ··········✗·` |
| delta-mixed | `◷ ?  mem ?` | `◷ ?  mem ?  ✓⊘··✓··✓·⊘✓✓` |
| epsilon-busy | `◷ ?  mem ?` | `◷ ?  mem ?  ????✓✓✓✓✓✓✓✓` |
| zeta-unseeded | `◷ ?  mem ?` | `◷ ?  mem ?  ????????????` |
| eta-quiet | `◷ ?  mem ?` | `◷ ?  mem ?` |
| theta-idle | `◷ ?  mem ?` | `◷ ?  mem ?  ✓✓✓✓✓✓✓✓✓✓✓✓` |

읽는 법이에요.

- `failing 3h05m`: 실패 phase 가 3시간 5분째예요. `failing ?`: 서버가 시작을 안 적었거나(beta), 시작이 이 화면의 시계보다 뒤예요(gamma).
- 맥박은 왼쪽이 12시간 전, 오른쪽이 방금 끝난 시간이에요. 한 칸이 한 시간이고, 그 시간에 턴이 여럿이면 가장 나쁜 것을 그려요. `✓` 정상, `⊘` 쉼, `✗` 실패, `·` 턴 없음, `?` 서버가 더는 안 가진 시간이에요.
- epsilon-busy 는 서버가 24개만 들고 있어서 8시간 전보다 오래된 4칸이 `?` 예요. 이 칸들은 턴이 없었다는 뜻이 아니에요.
- eta-quiet 는 전후가 같아요. 창 전체를 알고 턴이 없으면 칸을 그리지 않아요.
- 맥박은 자율 턴만 세요(`lib/keeper/keeper_turn_pulse.mli`). 사람과 나눈 대화 턴은 `·` 로 보일 수 있어요.

## DETAIL 자리

둘째 줄의 칸은 왼쪽 DETAIL 글보다 먼저 자리를 가져가요(`bin/masc_tui_render_keepers.ml` 의 `fit_cells` 와 `detail_space`). 80칸에서 둘째 줄 칸 자리는 73칸이에요(둘째 줄 폭 79칸에서 들여쓰기 6칸을 뺀 값이에요). 같은 방식으로 캡처에서 잰 둘째 줄 폭은 120칸에서 119칸, 200칸에서 143칸이에요. 200칸에서는 오른쪽 패널이 자리를 가져가요. 이 합성 데이터에서는 일정 칸과 기억 칸이 둘 다 짧은 `?` 꼴이에요(`◷ ?`, `mem ?`).

| keeper | 칸 너비 전 | 칸 너비 후 | DETAIL 에 남는 자리 전 | DETAIL 에 남는 자리 후 |
| --- | --- | --- | --- | --- |
| alpha-failing | 10 | 39 | 62 | 33 |
| theta-idle | 10 | 24 | 62 | 48 |

`남는 자리 = 73 - 칸 너비 - 1` 이에요. 이 셈은 코드에서 나온 값이고, 캡처에서는 alpha-failing 의 DETAIL 글(31칸)과 칸 사이에 빈칸이 3칸 남아서 맞아요. DETAIL 글이 33칸보다 길었다면 잘렸을 거예요. 일정 칸과 기억 칸이 더 길어지는 경우는 이 합성 데이터에 없어서 재지 못했어요.

## 질문 표

운영자 질문마다 첫 화면(Dashboard)에서 답이 보일 때까지 누르는 키 수예요.

| 질문 | 전 | 후 |
| --- | --- | --- |
| 이 keeper 가 실패한 지 얼마나 됐나 | 답할 수 없어요. `kr_failing_since` 를 읽는 곳이 `bin/` 에 0곳이에요 | 키 1번(`3`). Detailed 둘째 줄에 있어요 |
| 최근 12시간에 이 keeper 가 자율 턴을 돌렸나, 실패했나 | 답할 수 없어요. `kr_recent_turns` 를 읽는 곳이 `bin/` 에 0곳이에요 | 키 1번(`3`). Detailed 둘째 줄에 있어요 |

`git grep -c kr_failing_since origin/main -- bin` 과 `git grep -c kr_recent_turns origin/main -- bin` 이 모두 0곳이에요(main `27852676b4b6`). 다른 화면(Info 탭의 transitions 등)으로 답할 수 있는지는 세지 않았어요.

## 이 폴더가 말하지 않는 것

- 실제 서버가 보내는 `failing_since` 와 `recent_turns` 값은 아니에요. 합성 서버가 만든 값이에요.
- 일정 · 기억 칸이 길어지는 줄, 실제 DETAIL 글이 긴 줄, 선택된 줄의 색은 다루지 않았어요(선택된 줄은 색을 걷어 내요. 첫 줄 alpha-failing 이 선택된 줄이에요).
- NOW · AGE 열이 `- unknown`, `48d00h` 인 것은 합성 서버가 턴 목록을 비워 두고 메타 파일의 시각이 오래돼서예요. 이 PR 과 상관없어요.
- 이 빌드에 없는 동작은 말하지 않았어요.

## 파일

`<전|후>-<80|120|200>-<color|nocolor>.png` 는 화면이고, `.ansi.gz` 는 같은 화면의 ANSI 원문이에요. 24개 글 파일(`.txt`, `.ansi`)을 절대 경로, 토큰, 사용자 이름 패턴으로 훑어서 나온 것이 없어요. 이미지는 다섯 장(후 80칸 색 있음, 후 120칸 색 없음, 후 200칸 색 있음, 전 120칸 색 있음, 전 80칸 색 없음)을 열어서 확인했고, 나머지는 같은 화면의 글 파일로 대조했어요.
