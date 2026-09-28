---
rfc: "tui-region-grammar"
title: "TUI 영역 규칙 — 선은 영역 사이에만, 키를 받는 영역은 하나만 표시한다"
status: Draft
created: 2026-09-28
updated: 2026-09-28
author: dancer + claude
supersedes: []
superseded_by: null
related: ["0459", "tui-operator-workbench", "tui-measured-operator-home", "tui-frame-budget"]
implementation_prs: []
---

# RFC: TUI 영역 규칙 (tui-region-grammar)

## 0. 요약

운영자가 2026-09-28 에 "화면이 많은데 영역이 헷갈린다, 경계가 애매하다"고 했다.
같은 날 라이브 TUI 를 PTY 로 띄워 폭별로 찍어 보니, 헷갈리는 이유가 코드에 있었다.

- 가는 선 한 종류가 네 가지 뜻으로 쓰인다.
- 오른쪽 Activity 칸에는 이름이 없다.
- 키가 어느 영역으로 가는지 화면에 표시가 없다.
- 맨 아래 세 줄(키 힌트, agenda, 입력 줄)이 구분 없이 붙어 있다.

이 RFC 는 화면을 **영역**으로 나누는 규칙을 정한다.
선과 틴트는 영역 사이에만 쓴다. 영역마다 머리 줄에 이름을 단다.
키를 받는 영역 하나만 표시한다.

새 관례를 만들지 않는다. 목록 옆칸과 context inspector 가 이미 쓰는 표시(`▸` + bold)를
모든 영역으로 넓힌다(§3.3).

### RFC-0459 와의 관계

RFC-0459 는 방향만 정했다. 이 RFC 는 그중 아래 세 곳을 구체적인 규칙으로 바꾼다.

| RFC-0459 | 거기서 정한 것 | 이 RFC 가 정하는 것 |
|---|---|---|
| §3 토큰 | `border.default`, `border.focused`, `surface.base/raised` 라는 이름 | 어느 영역의 어느 줄이 그 토큰을 쓰는지 (§3.1–3.4) |
| §3.1 degradation | 색이 없어도 의미는 glyph/label/attribute 가 지킨다 | 포커스·선택·경계를 색 없이 무엇으로 보이는지 (§3.7) |
| §3.2 layer | "L1 pane 은 한 줄 border 와 focus marker 로 구분한다" | "한 줄 border" 와 "focus marker" 가 무엇인지, 섹션·표 머리는 L1 이 아니라는 것 (§3.1–3.3) |
| §4.1 폭 계약 | 둘째 pane 은 양쪽이 각자 최소 폭을 채울 때만 | 본문 최소 폭 100칸 (운영자 결정 2026-09-28, #36351) |

토큰 이름, degradation 표, 층 정의는 다시 적지 않는다. RFC-0459 를 따른다.

## 1. 화면에서 본 것

2026-09-28 에 `masc-tui` 를 PTY 로 띄워 140×42, 131, 132, 100, 80칸에서 찍었다.
화면은 pyte 에뮬레이터로 받았다. 글자 위치와 폭은 TUI 출력 그대로다. 색은 근사값이다.
화면에 운영 데이터(글 제목, 대화 내용, 계정 이름)가 들어 있어서 이미지는 저장소에 올리지 않는다.
workbench RFC §1 과 같은 이유다. 아래는 구조만 옮긴 것이다.
줄 번호는 `1fb92879fe` 기준이다.

### 1.1 140×42 화면의 띠

```
행 0      탭 띠 ─────────────────────────────── 전체 폭
행 1      (빈 줄)                 │ [Recent] Changes · 24 keepers   ← Activity 칸 머리
행 2      MASC Overview [me] …    │ state  tool  calls  new tok
행 3      ──────────────────      │ ● keeper  open  tool_execute  1+
…         본문 84칸                │ Activity 칸 56칸 (배경 틴트)
행 39     본문 키 힌트             │
행 40     ▸ 03:14 … sweep · …                    ; Awaiting you·1   ← 전체 폭
행 41     › to code-reviewer   (i to write)                          ← 전체 폭
```

### 1.2 선 하나가 네 가지 뜻

본문이 긋는 가로선은 `box_divider` 하나뿐이다(`bin/masc_tui_ansi.ml:849`). 호출은 157곳이다.
이 선이 아래 네 가지를 모두 맡는다.

1. 화면 제목 밑줄. `surface_chrome` 이 제목 다음에 긋는다(`bin/masc_tui_render_prim.ml:1285-1287`).
2. 섹션 구분. 본문이 `push_divider` 로 긋는다(`bin/masc_tui_render_prim.ml:1299`).
3. 표 머리 위아래. 머리 줄을 쓰고 바로 선을 긋는다(`bin/masc_tui_render.ml:3487-3490`, `:9014-9015`).
4. Activity 칸 안에서 목록과 선택한 Keeper 블록 사이.

그래서 선을 보고는 새 영역인지, 새 섹션인지, 표 머리인지 알 수 없다.
Activity·Keepers·Board 화면에서는 표 머리가 선 두 줄 사이에 끼어, 따로 떨어진 섹션처럼 보인다.

### 1.3 오른쪽 칸에 이름이 없다

Activity 칸 머리는 `[Recent] Changes` 다(`bin/masc_tui_acting_pane.ml:96-97`).
화면 어디에도 "Activity" 라는 말이 없다.
칸의 내용도 지금 탭과 상관이 없다. Board 를 볼 때도 Keeper 목록이 나온다.
캡처마다 24행 중 19~23행이 `no events` 였다.

### 1.4 키가 어느 영역으로 가는지 모른다

- `Theme.border_focus` 는 정의만 있고 쓰는 곳이 없다(`bin/masc_tui_theme.ml:380`, `bin/masc_tui_ansi.ml:205`).
- `Ctrl-W` 로 Activity 칸에 커서를 주면, 칸의 커서 행도 반전으로 칠한다(`bin/masc_tui_render_prim.ml:1122-1127`).
  본문의 선택 행도 반전 그대로다. 반전 두 줄이 동시에 보이고, 어느 쪽이 `j/k` 를 받는지 머리에 표시가 없다.
- 선택 표시가 네 가지다.
  - 반전만: `bin/masc_tui_render.ml:15035`
  - `>` + 반전: `bin/masc_tui_render_prim.ml:4402`
  - `▸` 앞머리: `bin/masc_tui_render_prim.ml:1558`
  - bold + `▸`: `bin/masc_tui_render_prim.ml:3932`

### 1.5 맨 아래 세 줄이 붙어 있다

- 본문 키 힌트는 본문의 마지막 줄이다. 그래서 본문 폭(84칸)만 쓰고, 옆에 Activity 칸이 이어진다.
- 그 아래 agenda 줄과 입력 줄은 전체 폭이다. 세 줄 사이에 구분이 없다.
- agenda 줄 오른쪽 `; Awaiting you·1` 은 키(`;`)와 개수를 붙여 쓴다(`bin/masc_tui_agenda.ml:156`).
  바로 위 키 힌트(`r:refresh  Tab:next`)와 모양이 달라서, 키 힌트인지 알림인지 헷갈린다.
- 입력 줄 `› to code-reviewer (i to write)`(`bin/masc_tui_composer.ml:50`)는 Board 화면에도 떠 있다.
  화면에 없는 Keeper 에게 보내는 입력칸이다.

### 1.6 이름을 두 번 말하고, 머리 높이가 어긋난다

- 탭 띠가 `▸Board` 를 표시하고, 바로 아래 제목 줄이 `MASC Board` 를 또 쓴다.
- 본문은 `box_top` 이 빈 줄 하나를 먼저 넣어서(`bin/masc_tui_ansi.ml:840`) 제목이 2행에 온다.
  Activity 칸 머리는 1행에 온다. 나란한 두 영역의 머리가 한 줄 어긋난다.

### 1.7 목록과 상세가 선 하나로만 나뉜다

Lanes·Memory 는 목록 아래에 선택한 행의 상세를 붙인다. 사이에는 `box_divider` 한 줄뿐이다.
상세 첫 줄이 항목 이름이긴 하지만, 목록과 글자 모양이 같다.
그래서 여기서부터 다른 영역이라는 게 드러나지 않는다.

### 1.8 모서리가 섞여 있다

- 공용 `Theme.Box` 는 각진 모서리(`┌`)만 있다(`bin/masc_tui_theme.ml:235-244`). 오버레이 틀이 이것을 쓴다.
- context inspector 머리는 둥근 `╭─` 이다(`bin/masc_tui_render_prim.ml:4443`, `:4463`, `:4630`, `:4645`).
- 링크 미리보기(`bin/masc_tui_link_preview.ml:463`, `:509`)와 명령 도움말(`bin/masc_tui_command.ml:852`)도 둥글다.

### 1.9 이미 있는 좋은 선례

키를 받는 칸을 표시하는 방법은 이미 두 곳에 있다.

- 목록 옆칸: 포커스면 제목이 bold 에 `▸`, 아니면 dim 이다(`bin/masc_tui_render_prim.ml:1588-1593`).
  주석이 "어느 키가 되는지는 footer 가, 어느 칸이 듣는지는 이 glyph 하나가 말한다"고 적었다.
- context inspector: 두 칸 머리 중 듣는 칸에만 `▸ ` 를 붙인다(`bin/masc_tui_render_prim.ml:4438-4443`).

전체 화면에서 바깥 박스를 치지 않는 결정도 있다(`bin/masc_tui_ansi.ml:834-838`,
"터미널 가장자리가 이미 틀이다"). 이 RFC 는 이 결정을 유지한다.

## 2. 다른 도구는 어떻게 나누나

| 도구 | 방식 | 출처 |
|---|---|---|
| lazygit | 패널마다 둥근 테두리. 키를 받는 패널만 테두리를 초록+bold 로 칠한다. 좁으면 패널을 세로로 쌓는다 | https://github.com/jesseduffield/lazygit/blob/master/docs/Config.md |
| Codex CLI | 위아래 테두리 없이 배경 틴트. 틴트 양은 OSC 11 로 읽은 배경에 맞춰 계산하고, 대비 하한을 둔다 | https://github.com/openai/codex/blob/main/codex-rs/tui/src/style.rs , https://github.com/openai/codex/blob/main/codex-rs/tui/styles.md |
| opencode | 좌우 한쪽 막대(`┃`)만 긋고 위아래 테두리는 없다 | https://github.com/anomalyco/opencode/blob/dev/packages/tui/src/ui/border.ts |
| zellij 0.44–0.45 | 테두리 없는 pane, 제목만 있는 틀(title frame) | zellij CHANGELOG |
| Amp | TUI 안에 늘 떠 있던 사이드바를 2026-08-27 에 뺐다 | https://ampcode.com/news/so-long-tui-sidebar |
| Claude Code agent view | 한 행이 한 세션이다. 상태는 셋뿐이고, `Space` 로 잠깐 보고 `Enter` 로 들어간다 | Claude Code changelog v2.1.139 (2026-05-11) |

공통점은 두 가지다.

- 선이나 틴트는 **영역 경계에만** 쓴다. 영역 안의 섹션은 제목과 빈 줄로 나눈다.
- 키를 받는 영역은 **하나만, 머리나 테두리로** 표시한다.

## 3. 규칙

### 3.1 영역

경계를 받는 단위는 영역뿐이다. 섹션과 표 머리는 영역이 아니다.

| 영역 | 폭 | RFC-0459 층 |
|---|---|---|
| 탭 띠 | 전체 | L0 |
| 본문 (surface) | 전체 또는 전체 − 옆 칸 | L0 |
| Activity 칸, roster 칸 | 고정 폭 | L1 |
| inspector, 상세 칸 (Lanes·Memory 상세 포함) | 본문 안 | L2 |
| 모달 (palette, help, agenda 패널) | 본문 위 | L3 |
| agenda 띠 | 전체 | L0 |
| 입력 줄 (composer) | 전체 | L0 |

본문 키 힌트(footer)는 영역이 아니다. 본문 영역의 마지막 줄이다.

### 3.2 선

- 영역과 영역 사이에만 선을 긋는다. 쓸 선은 영역 경계선 하나다(`border.default`).
- 섹션은 선 대신 **제목 줄 + 빈 줄** 로 나눈다.
- 표 머리는 선으로 감싸지 않는다. 머리 줄 자체를 `recede` 로 그린다(지금 머리 줄 스타일 그대로).
- 화면 제목 밑줄은 없앤다. 제목 줄이 영역 머리 줄이다(§3.3).
- 목록과 상세처럼 한 본문 안의 두 영역(L2) 사이에는 영역 경계선을 긋고, 상세에 머리 줄을 단다.

### 3.3 머리 줄과 포커스

- 모든 영역은 첫 줄에 이름을 단다. Activity 칸은 `Activity` 다. 지금의 `[Recent] Changes` 는 그 뒤 탭이다.
- 키를 받는 영역은 늘 하나다. 그 영역 머리만 `▸` + bold + `border.focused` 로 그린다.
  나머지 영역 머리는 `recede` 로 그린다. §1.9 의 목록 옆칸 규칙을 그대로 넓힌 것이다.
- 나란한 영역의 머리 줄은 같은 행에서 시작한다.
- 본문 제목 줄은 탭 띠가 이미 말한 이름을 되풀이하지 않는다.
  하위 단계가 있을 때만 경로를 쓴다. 채팅이 이미 `Keepers ▸ code-reviewer ▸ chat` 로 쓰는 방식이다.

### 3.4 선택

- 반전(`Theme.selection`)은 포커스 영역의 선택 행에만 쓴다.
- 포커스가 없는 영역의 선택 행은 `▸` 앞머리만 남긴다. 반전하지 않는다.
- 지금의 네 가지 선택 표시(§1.4)는 이 두 가지로 줄인다.

### 3.5 맨 아래 띠

- 본문 키 힌트는 본문 영역 안에 둔다. 지금처럼 본문 폭을 쓴다.
- agenda 띠와 입력 줄은 전역 띠다. 둘 다 전체 폭이다.
- agenda 띠는 키를 입력 줄과 같은 모양으로 쓴다. 입력 줄이 `(i to write)` 라고 쓰듯 `Awaiting you 1 (; to open)` 으로 쓴다.
  전역 띠 두 개가 키를 한 가지 모양으로 말하게 된다.
- 입력 줄은 포커스가 없을 때 `recede` 로 그린다. `i` 를 눌러 포커스를 받으면 머리에 `▸` 가 붙는다.
  입력 대상이 지금 화면에 없는 Keeper 라는 사실은 대상 이름으로 이미 보인다. 이 줄의 글자는 바꾸지 않는다.

### 3.6 모서리

모서리는 한 가지만 쓴다. 어느 쪽인지는 운영자가 정한다(§5, R3).

### 3.7 색이 없을 때

RFC-0459 §3.1 에 따라 의미는 색이 아닌 글리프와 속성이 지킨다.

| 뜻 | 색이 있을 때 | `NO_COLOR` / 16색 |
|---|---|---|
| 포커스 영역 | `▸` + bold + `border.focused` | `▸` + bold |
| 포커스 아닌 영역 | `recede` | 표시 없음 |
| 포커스 영역의 선택 | 반전 | 반전 (`NO_COLOR` 도 반전은 유지한다, `bin/masc_tui_theme.ml:207`) |
| 포커스 아닌 영역의 선택 | `▸` 앞머리 | `▸` 앞머리 |
| 영역 경계 | 선 또는 틴트 | 선 글리프 |

### 3.8 폭

둘째 영역(Activity 칸)은 본문이 100칸 이상 남을 때만 연다.
운영자가 2026-09-28 에 정했다(#36351). RFC-0459 §4.1 의 "각자 최소 폭"을 본문 100칸으로 정한 것이다.
채팅도 다른 화면과 같은 규칙으로 Activity 칸을 그린다(#39574).

## 4. 구현 순서

화면마다 따로 고치면 N-of-M 이 된다. 공용 틀에서 먼저 고치고, 공용 틀을 안 쓰는 화면을 틀 안으로 옮긴다.

지금 공용 틀과 우회 경로의 크기는 이렇다(`1fb92879fe` 에서 `rg` 로 셈).

- `surface_chrome` 을 쓰는 곳: 27곳 (`bin/masc_tui_render.ml`)
- `box_line`, `box_line_styled`, `box_line_selected` 를 직접 부르는 곳: 433곳, 7개 파일
  (`masc_tui_render.ml` 385, `masc_tui_render_chat.ml` 28, `masc_tui_render_prim.ml` 13, 나머지 7)
- `box_divider`, `push_divider`: 157곳
- 탭 띠 구현: 2개 (`bin/masc_tui_ansi.ml:375`, `bin/masc_tui_render_prim.ml:752`)

| 단계 | 내용 | 확인 방법 |
|---|---|---|
| G1 | 영역 머리 줄 부품 하나를 만든다(이름, 포커스, 개수). `surface_chrome`, 목록 옆칸, context inspector, Activity 칸이 이 부품을 쓴다. `border_focus` 가 여기서 처음 쓰인다 | `NO_COLOR` 텍스트 스냅샷에서 `▸` 가 붙은 머리가 정확히 하나 |
| G2 | Activity 칸 머리를 `Activity` 로 바꾸고 포커스를 붙인다. `Ctrl-W` 로 칸이 포커스를 받으면 본문 선택 행의 반전을 거둔다 | PTY: `Ctrl-W` 전후로 반전 행이 한 줄씩이고 `▸` 가 옮겨 감 |
| G3 | 표 머리를 감싸는 선을 뺀다. 머리 줄과 선을 같이 긋는 자리를 표 머리 부품 하나로 모은 뒤 선을 뺀다 | 캡처에서 표 머리 바로 위아래에 선이 없음 |
| G4 | 섹션 구분선을 제목 줄 + 빈 줄로 바꾼다. `push_divider` 의 뜻을 섹션 경계로 좁힌다. #38801 이 Dashboard 를 새로 그리므로 그 뒤에 한다 | 한 화면 안의 선 개수가 영역 경계 수와 같음 |
| G5 | 맨 아래 띠: agenda 키 모양을 입력 줄과 맞추고, 입력 줄에 포커스 표시를 붙인다 | PTY: `i` 전후로 입력 줄 머리의 `▸` |
| G6 | 선택 표시 네 곳을 §3.4 의 두 가지로 모은다 | 선택 스타일을 만드는 함수가 하나 |
| G7 | 탭 띠 구현 두 개를 하나로 합친다 | 두 화면 종류에서 탭 띠 캡처가 같은 모양 |
| G8 | `surface_chrome` 밖에서 그리는 화면을 틀 안으로 옮긴다. #39008(손으로 센 행 수), #38988(열 폭 예산)과 같이 간다 | `box_line` 직접 호출 수가 줄어드는 것을 PR 마다 기록 |

G1 이 먼저다. G2–G7 은 G1 위에서 서로 독립이다. G8 은 오래 걸리고 다른 에픽과 같이 간다.

## 5. 정할 것

| # | 질문 | 제안 |
|---|---|---|
| R1 | #38801 이 Dashboard·Work·Usage 에서 Activity 칸을 끄는 목록(`List.mem state.view [...]`)을 100칸 기준(#36351) 뒤에도 둘까 | 뺀다. 132~155칸에서는 100칸 기준이 이미 모든 탭에서 칸을 끈다. 목록은 156칸 이상에서 탭을 바꿀 때 칸이 생겼다 사라지게 만든다. 운영자는 "모든 탭에 같은 기준"을 골랐다 |
| R2 | Activity 칸 경계를 틴트로 할까, 선으로 할까 | 지금처럼 둘 다 둔다(틴트 `side_pane_background` + 한 줄 `│`). 문제는 경계가 아니라 이름과 포커스였다 |
| R3 | 모서리를 각지게 할까, 둥글게 할까 | 각지게. 공용 `Theme.Box` 와 오버레이 틀이 이미 각지다. 둥근 곳은 context inspector, 링크 미리보기, 명령 도움말 세 군데다. lazygit·btop 은 둥근 모서리가 기본이라 반대 선택도 흔하다 |
| R4 | 본문 제목 줄에서 `MASC <이름>` 을 뺄까 | 뺀다. 탭 띠가 이미 말한다. 제목 줄에는 경로(하위 단계)와 그 화면의 상태만 남긴다 |
| R5 | agenda 띠의 `; Awaiting you·1` 을 입력 줄과 같은 모양(`(; to open)`)으로 바꿀까 | 바꾼다(§3.5). 좁은 폭에서도 이 개수만은 남는다는 지금 규칙(`bin/masc_tui_agenda.ml:152-155`)은 그대로 둔다 |

## 6. 하지 않는 것

- 최상위 7곳의 이름과 순서는 바꾸지 않는다(#38801, measured-home RFC).
- 전체 화면에 바깥 박스를 다시 치지 않는다(§1.9).
- 배경 밝기로 층을 나누는 규칙은 만들지 않는다. RFC-0459 §3.2 가 요구하지 않기로 했다.
- 테마와 색 값은 바꾸지 않는다. 어느 줄이 어느 토큰을 쓰는지만 정한다.

## 7. 관련

- RFC-0459 — 토큰 이름, degradation, 층, 폭 계약
- RFC-tui-operator-workbench — 공용 부품(§5), 열 폭(§5.4, #38988)
- RFC-tui-measured-operator-home (#38801) — 최상위 7곳
- #36351 — Activity 칸이 열리면 본문이 56칸을 잃음 (100칸 기준으로 고침)
- #39574 — 채팅 화면이 132칸 이상에서 오른쪽 56칸을 비움
- #38988 — 열 폭 예산 에픽
- #39008 — 손으로 센 행 수
