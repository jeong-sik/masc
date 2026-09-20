---
rfc: "0459"
title: "TUI 시맨틱 토큰과 적응형 운영 워크벤치"
status: Draft
created: 2026-09-19
updated: 2026-09-20
author: dancer + antigravity
supersedes: []
superseded_by: null
related: ["0429", "tui-operator-ia", "tui-frame-budget"]
---

# RFC-0459: TUI 시맨틱 토큰과 적응형 운영 워크벤치

## 0. 결정

이 RFC는 두 가지를 정한다.

1. TUI 색과 강조를 ANSI 색 이름이 아니라 의미 역할(`text`, `border`, `surface`,
   `status`)로 부른다. 터미널이 실제 색을 소유하므로, 지원 수준마다 명시적인
   degradation 규칙을 둔다.
2. 운영 화면은 **적응형 단일 주 패널(cockpit)**을 기본으로 한다. 폭이 충분할
   때만 보조 패널을 붙이며, 고정 50:50 분할은 채택하지 않는다.

기존 Mermaid 렌더러는 교체하지 않는다. 네이티브 다이어그램은 현재 렌더러로
표현하기 어려운 모양과 실제 사용 빈도가 측정된 뒤 별도 제안으로 판단한다.

새 전역 대화 키도 만들지 않는다. 현재 키 레지스트리의 `Meta-i`가 이미 어느
surface에서든 보이는 keeper의 composer에 focus를 준다. plain `i`는
`Config_prompts`의 “input”이고 `Meta-2`는 Keepers 이동이므로 이 RFC는 `i`나
`Alt-1..4`를 재배정하지 않는다.

## 1. current-main 기준선

아래 표는 2026-09-20의 `main` `508b638747becb97f0f27d0de66cff066e0854c0`
(최근 태그 `v0.35.20`)에서 원문을 확인한 결과다. 8월의 이전 snapshot은 이
RFC의 근거로 쓰지 않는다.

| 항목 | current-main 상태 | 이 RFC의 판단 |
|---|---|---|
| 도구 결과 본문 | chat의 `Live.Tool_result`는 `{ occurrence; execution_id }`만 운반하지만 Activity/Recent는 observer의 input/output preview를 표시한다 (#36245, #36255) | platform-wide “증발” 주장을 철회한다. chat inline 결과가 더 필요한지는 별도 UX 판단이다. |
| 변경 목록의 줄바꿈 | `change_row_summary`가 `Terminal_text.preview_line`을 쓴다 (`bin/masc_tui_render.ml`) | #33482에서 해결됨. 범위에서 제거한다. |
| Mermaid 폭 초과 | parse 뒤 layout이 `Too_wide { cells; cols; turning_it_fits }`를 반환한다 | parser 결함으로 부르지 않는다. 폭 계약 문제다. |
| Mermaid fallback | 필요한/가용 cell 수와 회전 가능한 방향을 말한 뒤 원문을 보여 준다 (`bin/masc_tui_markdown.ml`) | 진단 한 줄만 보인다는 주장을 철회한다. |
| composer 접근 | `Meta-i`가 전역 composer focus로 등록돼 있다 (`bin/masc_tui_keys.ml`) | “3단계 진입” 주장을 철회한다. 현재 동작을 유지한다. |

`Too_wide`의 대체 방향 layout은 이미 계산되지만 자동 적용되지 않는다. 그래프가
읽히는 방향은 작성자의 선택이라는 `masc_tui_mermaid.mli` 계약 때문이다. 향후
명시적인 “제안 방향으로 보기” action은 가능하지만, 이 RFC는 방향을 몰래 바꾸지
않는다.

## 2. 범위와 비범위

### 범위

- 의미 기반 TUI token 이름과 terminal capability별 변환 규칙
- 실제 pane 폭을 입력으로 받는 적응형 cockpit 계약
- 80/100/120 column PTY에서 재현 가능한 acceptance gate
- 기존 key registry를 그대로 쓰는 chat-first focus 동작

### 비범위

- chat inline `Tool_result` payload wire 변경
- Mermaid parser/renderer 퇴역
- plain `i`, `Meta-1..4` 재배정
- “밀도 9/10 → 4/10” 같은 측정 정의가 없는 목표
- HTML preview를 terminal layout의 증거로 사용하는 일

각 비범위 항목은 이 RFC 승인과 묶지 않는다. 싼 결함 수리 때문에 새로운
diagram engine이나 전체 IA를 함께 승인할 필요가 없게 한다.

## 3. 시맨틱 토큰 계약

렌더러는 구체 색이 아니라 다음 역할을 요청한다.

- `text.default`, `text.subtle`, `text.inverse`
- `status.info`, `status.success`, `status.warning`, `status.danger`
- `border.default`, `border.focused`
- `surface.base`, `surface.raised`, `surface.modal`

색만으로 상태를 구별하지 않는다. focus는 border glyph, 실패/경고는 label 또는
mark, 선택 상태는 cursor와 text attribute를 함께 쓴다.

### 3.1 terminal capability별 degradation

| terminal 조건 | 변환 |
|---|---|
| truecolor이며 TUI가 foreground와 background를 모두 칠함 | 쌍으로 고른 token 값에 한해 normal text 4.5:1을 검증한다. |
| 256색 | 가장 가까운 palette entry로 내리되 4.5:1을 보장한다고 쓰지 않는다. glyph/label/attribute가 의미를 보존한다. |
| 16색 또는 unknown | terminal의 named color를 사용한다. 의미는 색이 아닌 glyph/label/attribute가 보존한다. |
| transparent/default background | 사용자의 theme가 대비를 결정한다. 배경 밝기 방향이나 수치 대비를 주장하지 않는다. |

### 3.2 layer 규칙

- **L0 base**: terminal default surface.
- **L1 pane**: 한 줄 border와 focus marker로 구분한다.
- **L2 inspector**: title과 border style로 구분한다. “배경 밝기 step-up”을
  요구하지 않는다.
- **L3 modal**: 명시적인 modal frame과 title을 쓴다. 전체 화면 dim은 기본
  계약이 아니며, 도입하려면 `tui-frame-budget`의 측정 gate를 통과해야 한다.

## 4. 선택한 layout: 적응형 cockpit

기존 제안의 **Direction A를 선택**하되 고정 비율을 제거한다. 한 순간에 하나의
primary task(Chat, Diff, Context, Memory)가 읽기 폭을 소유한다. roster와
inspector는 사용자가 요청했을 때 나타나는 secondary surface다.

Direction B의 고정 50:50 live split은 기각한다. terminal 80 columns에서 각
pane이 약 40 columns밖에 받지 못하며, RFC 초안의 84/101-cell 예시도 담을 수
없다. “terminal 전체 폭”과 “pane 가용 폭”을 같은 값으로 취급하지 않는다.

### 4.1 폭 계약

layout은 terminal 폭이 아니라 decoration을 뺀 **실제 pane columns**를 자식에게
건넨다.

| terminal 폭 | 기본 구성 | 금지 사항 |
|---|---|---|
| 80 | primary pane 하나; roster/inspector는 전환형 overlay | 고정 2열 |
| 100 | primary pane 하나와 접을 수 있는 status rail | 내용 폭을 줄이는 상시 inspector |
| 120 이상 | 양쪽 pane이 각자의 minimum을 만족할 때만 optional secondary pane | 50:50 강제 |

자식 renderer는 받은 `cols`보다 넓은 row를 반환하지 않는다. full 표현이 맞지
않으면 stacked 표현, compact summary, source/text fallback 순으로 낮춘다. 어떤
단계도 내용을 조용히 버리지 않는다.

### 4.2 key 계약

- `Meta-i`: 보이는 keeper의 composer focus. 유지.
- plain `i`: `Config_prompts`의 input 보기. 유지.
- `Meta-2`: Keepers surface 이동. 유지.
- 새 binding은 `masc_tui_keys.ml`의 registry와 충돌 검사를 먼저 통과해야 한다.

따라서 이 RFC의 chat acceptance는 “어디서든 `Meta-i` 한 chord로 composer에
focus”이며 새 단축키 구현이 아니다.

## 5. diagram과 폭 측정

`Too_wide`는 parse failure가 아니라 layout refusal이다. 현재 fallback은
`cells`, `cols`, `turning_it_fits`, 원문을 보존한다. renderer를 바꿔도
`needed_cells > pane_cols`라는 물리 제약은 사라지지 않는다.

state diagram 확장 #36964, #36965, #36967은 이미 merge됐다. 이 RFC는 그
구현을 퇴역 대상으로 만들지 않고 current Mermaid capability로 유지한다.

네이티브 diagram 작업을 시작하기 전 별도 instrumentation 변경으로 다음을
측정한다.

- Mermaid render attempt 수
- `Too_wide` 수와 `too_wide / attempts` 비율
- `cols` bucket별 `cells - cols`
- `turning_it_fits` 존재 여부
- diagram 문법 종류와 pane 폭(원문 내용은 기록하지 않음)

baseline artifact와 측정 명령이 PR에 붙기 전에는 “Too_wide 제거”를 이 RFC의
성공으로 주장하지 않는다. Flywheel, swimlane, ribbon, contention matrix는
가능한 vocabulary 후보일 뿐 폐쇄된 네 패턴 engine의 근거가 아니다.

향후 native renderer는 같은 `cols` 계약을 지켜야 한다.

1. full pattern
2. stacked/vertical pattern
3. compact summary
4. lossless text/source fallback

각 단계는 display width를 재서 `row_width <= cols`를 증명한다.

## 6. 전달 순서

각 단계는 독립 PR이며 앞 단계가 뒤 단계의 승인 조건을 대신하지 않는다.

1. **관측**: Mermaid attempt/Too_wide instrumentation과 baseline artifact.
2. **토큰**: semantic role type, capability mapping, fallback unit tests.
3. **cockpit**: 현재 `Meta-i`를 유지한 적응형 primary/secondary layout.
4. **별도 UX 판단**: Activity/Recent와 별개로 chat inline tool result가 필요한지
   검증하고, 필요할 때만 wire 변경.
5. **선택적 diagram 제안**: 1단계 수치와 기존 Mermaid로 표현할 수 없는 실제
   사례가 있을 때만 시작.

## 7. acceptance gate

구현 PR은 다음 증거를 함께 제출한다.

- 80/100/120-column **실제 PTY** golden frame. HTML mockup은 증거가 아니다.
- 모든 row의 display width가 pane `cols` 이하라는 automated assertion.
- 16색/256색/truecolor/default-background token mapping unit tests.
- 색을 제거해도 focus, warning, error를 구별할 수 있다는 text snapshot.
- key registry에서 중복 binding이 없고 `Meta-i`, plain `i`, `Meta-2` 의미가
  유지된다는 test.
- `tui-frame-budget`이 정한 frame 예산의 before/after 측정.

이 증거가 없으면 구현은 이 RFC를 충족한 것으로 보지 않는다.

## 8. 참고

- Atlassian Design System: <https://atlassian.design/>
- Diagram Design: <https://github.com/cathrynlavery/diagram-design>
- `docs/rfc/RFC-tui-frame-budget.md`
- `docs/rfc/RFC-tui-operator-ia.md`
