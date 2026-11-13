---
rfc: "lane-row-offers-actions-filled-from-its-own-fields"
title: "lane 결과 행은 자기 값으로 채운 동작을 내고, 사람은 남은 칸만 채운다"
status: Draft
created: 2026-11-13
updated: 2026-11-13
author: claude
supersedes: []
superseded_by: null
related: ["operator-quiz-lane", "tui-one-screen-grammar"]
---

# lane 결과 행은 자기 값으로 채운 동작을 내고, 사람은 남은 칸만 채운다

## 0. 요약

운영자가 퀴즈 채점에 이의를 걸려면 지금 이렇게 한다.

1. Results 에서 질문 행을 고른다.
2. 행에 보이는 `ask_id` 와 `question_id` 를 마우스로 끌어 복사한다.
3. `a` 로 동작 양식을 열고, `kind` 칸에서 Left/Right 로 `dispute` 를 고른다.
4. `questions` 칸은 비워 둔다. 두 id 칸에 복사한 값을 붙여 넣고 `note` 를 쓴다.
5. Ctrl-S 로 확인하고 Enter 로 보낸다.

화면에 이미 있는 값을 사람이 손으로 옮긴다. 옮기다 틀리면 worker 가 거절한다.
dispute 에 쓰지 않는 `questions` 칸도 보인다.

규칙 하나에서 고친다. **행이 이미 가진 값은 다시 치지 않는다.**
패키지가 "이 lane 의 행은 이 동작을 내고, 이 칸은 행의 이 값으로 채운다"를 선언한다.
사람은 남은 칸만 쓴다. 퀴즈 이의라면 `note` 하나다.

바뀌는 것은 넷이다.

- presentation 에 `actions` 를 더한다.
- worker 가 동작 schema 를 알리면 host 가 행 동작마다 한 번 판정한다. TUI 와 대시보드는 그 판정을 읽는다.
- TUI 양식이 잠긴 칸과 `oneOf` 갈래를 받는다. 행 동작은 문법 RFC 의 "고른 것에 할 수 있는 동작" 목록에 들어간다.
- operator-quiz 0.3.3 이 동작 schema 를 `oneOf` 세 갈래로 바꾸고, 이의를 걸 수 있는 질문 행에 dispute 값을 싣는다.

이 RFC 는 #51791(동작 양식이 칸 설명을 보여 줌)의 다음 단계다.

## 1. 지금 구조 (main 202e915a2397)

### 1.1 presentation

- `lib/lane_addon/lane_addon_presentation.ml` 은 `description` 과 `readings` 만 받는다(38행). 모르는 키는 거절한다.
- reading 은 `lane_id`, `path`, `label`, `unit`, `format` 다섯 칸이다.
- `value`(57행)는 행의 fields 에서 `path` 를 따라 값을 꺼낸다. 없는 값과 모양이 틀린 값은 서로 다른 문자열 Error 로만 갈린다(62~63행).
- presentation 은 선언 revision 에 들어간다(`lib/lane_addon/lane_addon_types.ml` `package_to_json`, 274행).
  - 다른 선택 키는 "없을 때와 같은 뜻이면 쓰지 않는다"(234~235행). 그래서 그 키가 없는 패키지는 revision 이 그대로다.
  - revision 이 바뀌면 저장된 exact 요청의 목적지가 거절된다. 목적지는 revision 을 담고(`lib/lane_addon/lane_addon_captured_destination.ml` 6행), 보낼 때 지금 revision 과 다르면 거절한다(`lib/lane_addon/lane_addon_runtime.ml` 645~646행).
- `docs/guides/lane-addon-interface.md` 66행: "Display metadata grants no action authority."

### 1.2 동작 schema

- 동작 schema 는 lane.toml 에 없다. worker 가 Ready 가 된 뒤 `lane_act` 도구의 `inputSchema` 로 알린다(`lib/lane_addon/lane_addon_worker_protocol.ml` 81·114·181행).
- host 검사기(`lib/lane_addon/lane_addon_action.ml`)는 `oneOf` 를 받는다. 정확히 한 갈래가 맞아야 통과한다(137~143행).
  - schema 의 노드마다 `type` 이 있어야 한다(80행).
  - properties 없이 `oneOf` 만 가진 object 노드는 `required`·`additionalProperties` 를 가질 수 없다(82~85행).
  - 갈래 안에 다시 `oneOf` 를 두거나, 한 노드가 `oneOf` 와 properties 를 같이 가져도 검사를 통과한다(75~86행).
- operator-quiz 0.3.2 의 동작 schema 는 평평한 object 하나다(`addons/operator-quiz/server.py` 37~53행).
  - `kind` 는 enum(compose·dispute·export)이고, 나머지 칸은 모두 선택이다.
  - "dispute 에는 ask_id·question_id·note 만" 이라는 규칙은 schema 에 없다. worker 가 실행할 때 따진다(163~166행).
  - 그래서 `questions` 가 달린 dispute 도 host 검사를 통과하고, worker 에서 거절된다.

### 1.3 TUI 동작 양식

- lane 화면의 `a` 는 `open_actions`(`bin/masc_tui_lane_addons.ml` 1288행)를 부른다. 처음 값은 늘 빈 object 다(1303행).
- 대상은 `selected_instance`(1218행)다. Overview 에서는 고른 행이 아니라 instance 커서를 따른다.
- `submit_action` 은 보낼 때 instance 의 id·incarnation·schema 만 다시 본다(1325~1330행). 행은 다시 보지 않는다.
- 양식(`bin/masc_tui_schema_form.ml`)은 object 의 properties 를 칸으로 편다(`fields`, 15행).
  - `oneOf` 로 갈래를 나눈 object 는 properties 가 없어서 JSON 을 통째로 쓰는 칸 하나가 된다.
  - 같은 양식을 Fusion 실행(`bin/masc_tui_fusion_launch.ml` 118행), 설치 바인딩(`bin/masc_tui_lane_installer.ml` 157행), Records(`bin/masc_tui_lane_records.ml` 365행)도 쓴다. 앞의 둘은 처음 값을 넘기고, Records 는 빈 object 를 넘긴다.
  - 칸을 잠그는 방법은 없다. 글자, Backspace, Ctrl-U(137행), Left/Right(123행), Ctrl-E(108행), 붙여 넣기(`insert_text`, 85행)가 모두 값을 바꾼다.

### 1.4 TUI 문법 RFC (Draft, 층별로 들어오는 중)

- `a` 는 앱 전체에서 "새로 만들기"다(`docs/rfc/RFC-tui-one-screen-grammar.md` §3.2).
- 고른 것에 할 수 있는 일은 `Space` 동작 창에 모두 보인다. 지금 못 쓰는 동작은 흐리게 적고 이유를 옆에 적는다. 빼지 않는다(§3.3).
- 화면은 "고른 것에 할 수 있는 동작" 목록을 값으로 낸다. 동작 창, 구역 5, `?` 가 모두 그 목록에서 나온다(§3.5).
- 동작 창은 아직 lane 화면에 없다. lane 화면은 지금 구역 5 에 `a:actions` 를 적는다(`bin/masc_tui_lane_addons.ml` 1257행).
- 동작 창 층은 문법 RFC §9 의 5번이고, 2026-11-13 에 아직 시작 전이다. 문법 캠페인 세션에 물어 확인했다.
  - 첫 판은 화면별 key binding(`Masc_tui_keys`)으로 창을 만든다. 행 필드에서 나오는 동적 목록은 다음 단계(§3.5)에서 받는다.
  - Lanes 는 지금 `Space` 를 켜고 끄기로 쓴다. 그래서 5번이 먼저 옮기는 세 화면에 든다.

### 1.5 대시보드

- 동작 판(`dashboard/src/components/lane-addons-panel.ts`)은 JSON 글을 손으로 받는다(135행).
- 바인딩 양식(`dashboard/src/lib/lane-binding-form.ts`)은 `oneOf` 를 갈래 고르기로 그린다(100·189행).
- 갈래 이름은 `title`, 없으면 `description`, 없으면 `const` 칸들("kind: \"dispute\""), 없으면 "Alternative N" 이다(90~96행).

### 1.6 퀴즈 질문 행

- 질문 행은 답한 세션에만 있다(`addons/operator-quiz/quiz_projection.py` 119~121행).
- 행의 fields 에 `ask_id`·`question_id` 와 채점 상태(`grading`)가 있다(127~135행). 값이 없는 칸은 `null` 로 쓴다(97행).
- presentation 이 두 id 를 "Ask id, for a dispute"·"Question id, for a dispute" 로 보여 준다(`addons/operator-quiz/lane.toml` 106·107행). 사람이 옮겨 적으라고 둔 줄이다.
- worker 가 이의를 받는 질문은 셋을 모두 갖춘 것이다(`addons/operator-quiz/quiz_flow.py` 555~560행).
  - 그 ask 의 세션이 `answered` 다.
  - 그 질문이 그 세션에서 나갔다.
  - 그 질문의 채점 요청이 기다리는 중이 아니다.

## 2. 설계

### 2.1 계약

행 동작은 세 가지 값으로 동작 하나를 만든다.

- **고정 값**: 패키지가 정한 값. 예: `kind` = `dispute`.
- **행 값**: 고른 행의 fields 에서 읽은 값. 예: `ask_id`, `question_id`.
- **사람 값**: 사람이 채우는 나머지 칸. 예: `note`.

고정 값과 행 값은 사람이 바꾸지 못한다.
행 값을 읽지 못하는 행에서는 그 동작이 흐리게 보이고, 어떤 값이 왜 없는지 적힌다.

완성한 동작은 지금과 같은 `lane_act` 검사(`Lane_addon_action.validate`)와 권한을 거쳐 나간다.
행 동작은 새 실행 경로도 새 권한도 아니다. 같은 동작을 덜 쳐서 만드는 길이다.
그래서 `lane-addon-interface.md` 의 "Display metadata grants no action authority" 는 그대로 참이다. 그 문단에 행 동작이 무엇을 하는지 한 줄 더한다.

### 2.2 presentation `actions`

```json
"actions": [
  {"lane_id": "quiz/questions",
   "label": "Dispute this grade",
   "fixed": {"kind": "dispute"},
   "from_row": {"ask_id": ["dispute", "ask_id"], "question_id": ["dispute", "question_id"]}}
]
```

- 키는 이 넷뿐이다. readings 처럼 모르는 키와 중복 키를 거절한다.
- `label` 은 비지 않은 한 줄이다. 같은 lane 안에서 겹치지 않는다.
- `fixed` 와 `from_row` 는 동작 object 의 맨 위 칸 이름을 쓴다. 둘이 같은 칸을 쓰면 거절한다.
- `from_row` 의 경로는 비어 있지 않다.
- `lane_id`: 출력이 lane 목록을 고른 패키지(`Selected_lanes`)면 그 목록에 있어야 한다. 모든 lane 을 내는 패키지(`All_lanes`)는 어느 lane 이 나올지 설치 때 알 수 없어서 이 검사를 하지 않는다. 이 검사는 파서가 아니라 manifest 를 읽는 쪽이 한다. 파서는 출력을 모른다.
- `to_json` 은 `actions` 가 비어 있지 않을 때만 쓴다. `actions` 가 없는 패키지는 선언 revision 이 그대로다(§1.1).
- 행 동작은 presentation 안의 순번으로 부른다. label 은 화면에 보이는 이름일 뿐 열쇠가 아니다.

### 2.3 host 판정

worker 가 Ready 가 되어 동작 schema 를 알리면, host 가 행 동작마다 한 번 판정한다.

먼저 schema 모양을 본다. 받는 모양은 둘뿐이다.

- 닫힌 object 하나: `properties` 가 있고 `additionalProperties: false` 다. 이것이 갈래 하나다.
- `{"type":"object","oneOf":[…]}`: 노드 자체에는 properties 가 없고, 갈래가 모두 위의 닫힌 object 다. 갈래 안에 `oneOf` 가 다시 있으면 안 된다.

다른 모양이면 행 동작은 모두 Refused 다. 판정이 Offered 라고 했는데 보낼 때마다 "exactly one alternative" 로 거절되는 일을 막는다.

그다음 갈래마다 본다.

- 그 갈래의 properties 가 `fixed` 와 `from_row` 의 칸 이름을 모두 갖는다.
- `fixed` 의 값이 그 갈래의 해당 칸 schema 에 맞는다.
- 받는 갈래가 정확히 하나면 Offered 다. 그 갈래의 나머지 칸이 사람 값이고, required 인 칸은 필수다.

판정 결과는 닫힌 타입이다.

```
type row_action_verdict =
  | Offered of { branch : int option   (* None: 갈래 하나인 schema *)
               ; human : (string * bool) list }   (* 칸 이름, 필수 여부 *)
  | Refused of row_action_refusal

type row_action_refusal =
  | Schema_shape_unsupported
  | No_branch_accepts
  | Several_branches_accept of int list
  | Member_not_in_branch of string
  | Fixed_value_rejected of string
```

- instance 마다 snapshot 에 `row_actions` 로 싣는다. 순번, 판정, 갈래, 사람 값을 다 실어서 TUI 와 대시보드가 따로 계산하지 않는다.
- 거절 이유는 타입으로 싣고, 글은 화면이 만든다.
- 판정은 동작 schema 에서 언제든 다시 계산되는 projection 이다. 따로 저장하지 않는다. worker 가 다시 뜨면 다시 판정한다.

### 2.4 행 값 읽기

행 값은 타입 있는 결과로 읽는다: `Present of json | Absent | Wrong_shape`.
지금 `value` 의 두 문자열 Error 를 이 타입으로 바꾸고, readings 도 같은 것을 쓴다.

- `Absent`: 그 경로의 키가 없다. 동작은 흐리게 보이고 "이 행에는 <경로> 값이 없음" 이 적힌다.
- `Wrong_shape`: 키는 있지만 object 가 아니거나 `null` 이다. 동작은 흐리게 보이고 모양이 틀렸다고 적힌다. 패키지의 잘못이 화면에 드러난다.
- `Present` 지만 그 칸의 schema 에 맞지 않을 때도 흐리게 보이고 검사기의 이유가 적힌다. 잠긴 칸은 사람이 고칠 수 없으므로, 보낸 뒤에 거절당하게 두지 않는다.

### 2.5 TUI 양식

- 칸은 `Editable` 이거나 `Locked of json` 이다. 잠긴 칸은 맨 위에 값과 함께 보이고, 값을 바꾸는 키(글자, Backspace, Ctrl-U, Left/Right, Ctrl-E, 붙여 넣기)를 모두 거절한다.
- 커서는 사람이 채울 첫 칸에서 시작한다.
- `oneOf` 갈래가 여럿이면 첫 칸이 갈래 고르기다. Left/Right 로 고른다.
  - 갈래 이름은 대시보드와 같은 규칙이다: `title`, `description`, `const` 칸들, "Alternative N" 순서(§1.5).
  - 갈래를 고르면 그 갈래의 칸만 보인다. 갈래를 바꾸면 이전 갈래에서 쓴 값은 동작에 남지 않는다.
- 행 동작은 판정이 정한 갈래로 연다. 갈래 고르기도 잠긴다.
- 다른 양식(Fusion 실행, 설치 바인딩, Records)이 `oneOf` 를 만나면, 처음 값에 맞는 갈래가 정확히 하나일 때 그 갈래로 연다. 아니면(빈 처음 값도) 아무 갈래도 고르지 않은 채로 연다.

### 2.6 TUI 행 동작

- 행 동작은 그 행의 "고른 것에 할 수 있는 동작" 목록에 들어간다(문법 RFC §3.5). 따로 메뉴를 만들지 않는다.
  - 그 행의 lane 이 선언한 행 동작은 모두 목록에 있다.
  - Offered 이고 행 값이 모두 `Present` 이며 칸 schema 에 맞으면 고를 수 있다.
  - 아니면 흐리게 보이고 이유가 적힌다(§2.3, §2.4). 빼지 않는다.
- 동작 창 층은 아직 없다(§1.4). L3 은 지금 있는 `a:actions` 위에 올린다. 맨 아래 "Other action" 이 지금의 빈 양식을 연다. 새 키는 만들지 않는다.
- L3 은 행의 동작 목록을 값으로 만든다. 동작 창이 lane 화면에 오면 그 값을 읽기만 한다(문법 RFC §3.5).
- 목록 제목에는 그 행과 행을 낸 instance 를 적는다. 동작 창의 제목도 고른 것의 이름이라 같다(문법 RFC §3.3).
- 행 동작의 대상은 그 행을 낸 instance 다(`row_owner`, 359행). instance 커서를 따르지 않는다.
- 보낼 때 그 행을 id 로 다시 읽는다. 행이 사라졌거나 행 값이 열 때와 다르면 보내지 않고 "행이 바뀌었어요. 다시 여세요" 를 적는다.
- 그 밖은 지금 흐름과 같다. Ctrl-S 로 확인 화면을 열고 Enter 로 한 번 보낸다(`bin/masc_tui_schema_form.ml` 103~106행).
  - 확인 화면은 보내면 일어나는 일을 한 문장으로 적는다: 어느 instance 가 어떤 동작(label)을 받는지.
  - 동작을 되돌릴 수 있는지는 패키지만 안다. TUI 는 되돌릴 수 있다고도, 없다고도 적지 않는다.
  - 글자 하나로 바로 실행되지 않으므로 문법 RFC §3.3 의 `y` 확인은 더하지 않는다.

### 2.7 operator-quiz 0.3.3

- 동작 schema 를 `{"type":"object","oneOf":[…]}` 로 바꾼다. 노드 자체에는 `required`·`additionalProperties` 를 두지 않는다(§1.2).
  - **Compose**: `kind` = `{"type":"string","const":"compose"}`, `questions` 필수.
  - **Dispute**: `kind` = `{"type":"string","const":"dispute"}`, `ask_id`·`question_id`·`note` 필수.
  - **Export**: `kind` = `{"type":"string","const":"export"}`.
  - 갈래마다 닫힌 object 이고 `title` 을 단다.
- 0.3.2 에서 맞던 동작은 0.3.3 에서도 맞는다. Keeper 의 `masc_lane_act` 호출은 그대로 통한다.
- 뜻 없는 조합(예: `questions` 가 달린 dispute)은 이제 host 에서 거절된다.
- 이의를 걸 수 있는 질문인지를 함수 하나로 정한다(§1.6 의 세 조건). projection 과 `Flow.dispute` 가 같은 함수를 쓴다.
- 그 함수가 참인 질문 행에만 `dispute` object(`{"ask_id","question_id"}`)를 싣는다. 아니면 키를 쓰지 않는다. `null` 로 쓰지 않는다.
- presentation 에 §2.2 의 dispute 행 동작을 더한다.
- "Ask id, for a dispute"·"Question id, for a dispute" 두 reading 은 지운다. 옮겨 적을 일이 없어진다.
- worker 가 실행할 때 하는 검사(163~166행)는 그대로 둔다. worker 는 host 와 다른 프로세스이고 자기 입력을 스스로 따진다.
- `docs/guides/operator-quiz.md` 의 이의 제기 절을 고친다. 행 → 동작 목록 → "Dispute this grade" → `note` → Ctrl-S → Enter.

### 2.8 하지 않는 것

- **이름이 같으면 채워 넣는 추측.** 예: reading 경로 끝이 `ask_id` 면 동작의 `ask_id` 칸에 넣기. 이름이 같다고 뜻이 같지 않다. masc 는 의미를 문자열로 짐작하지 않는다.
- **행마다 완성된 동작을 fields 에 싣기.** 같은 틀이 행마다 반복되고, 판정도 행마다 다시 해야 한다.
- **조건 언어**(예: `when`). 패키지는 동작이 뜻이 있는 행에만 값을 싣는다. 조건은 projection 이 행 모양으로 나타낸다.
- **행 동작만의 메뉴.** 문법 RFC 의 동작 목록 하나와 어긋난다.
- **Keeper 경로.** Keeper 는 지금처럼 동작 전체를 `masc_lane_act` 로 보낸다.

## 3. 순서

층마다 PR 하나다. L1~L3 이 병합되어도 행 동작을 선언한 패키지가 없으므로 바뀌는 동작은 없다. L4 가 처음으로 쓴다.
네 층을 한 스택으로 열고 L4 까지 연달아 병합해, 부르는 곳 없는 층이 오래 남지 않게 한다.

| 층 | 범위 | 확인 |
|---|---|---|
| L1 | lib: 행 값 타입, `actions` 파서와 `to_json`, manifest 의 lane 검사, host 판정, snapshot `row_actions`, `lane-addon-interface.md` 한 줄 | `actions` 없는 패키지의 선언 revision 이 그대로, 파서가 받는 것·거절하는 것, 판정 결과 |
| L2 | TUI 양식: 잠긴 칸, `oneOf` 갈래, 처음 값의 갈래 | 다른 세 양식이 보내는 값이 그대로, 잠긴 칸 편집 거절, 갈래를 바꾼 뒤 보낸 값 |
| L3 | TUI 행 동작: 동작 목록 항목, 대상 instance, 보낼 때 행 다시 읽기 | 보낸 요청의 `action` 과 instance, 바뀐 행의 거절 |
| L4 | operator-quiz 0.3.3, 안내서 | `addons/tests` 의 schema·projection 시험, 라이브에서 이의 한 번 |
| L5 | 대시보드 동작 판 (방향) | 따로 RFC 또는 PR |

## 4. hard cut

- presentation 은 선택 키 하나가 는다. 옛 패키지는 그대로 읽히고 revision 도 그대로다. 옛 모양을 위한 reader 나 converter 는 없다.
- L1 이전에 빌드한 TUI 는 `actions` 를 선언한 패키지가 있으면 lane snapshot 을 읽지 못한다. presentation 파서가 모르는 키를 거절하기 때문이다(§1.1). TUI 와 서버는 함께 올린다.
- 저장된 동작 receipt 의 `action` 칸은 바뀌지 않는다.
- operator-quiz 0.3.3 설치는 지금 업그레이드 절차를 따른다. 퀴즈 기록(log)의 모양은 바뀌지 않는다.

## 5. 시험

masc 규칙대로 화면 글과 배치는 시험하지 않는다. 보낸 요청, 저장된 상태, 판정만 본다.

- lib revision: `actions` 가 없는 패키지의 선언 revision 이 L1 전과 같다.
- lib 파서: `actions` 를 받는다. 모르는 키, 빈 경로, `fixed` 와 `from_row` 가 같은 칸, 같은 lane 의 겹치는 label 을 거절한다. `Selected_lanes` 에 없는 `lane_id` 를 manifest 검사가 거절한다.
- lib 행 값: 키 없음은 `Absent`, `null` 과 object 아닌 중간 값은 `Wrong_shape` 다.
- lib 판정
  - 평평한 닫힌 schema 에서 Offered 다.
  - `oneOf` 세 갈래에서 dispute 갈래 하나로 Offered 고, 사람 값은 필수 `note` 다.
  - 두 갈래가 받으면 `Several_branches_accept` 다.
  - 갈래 안에 `oneOf` 가 있거나 노드가 `oneOf` 와 properties 를 같이 가지면 `Schema_shape_unsupported` 다.
- TUI 양식: Fusion 실행·설치 바인딩·Records 가 보내는 값이 L2 전과 같다. 잠긴 칸에 대한 편집 키가 모두 거절된다. 갈래를 바꾸면 이전 갈래의 값이 보낸 값에 없다.
- TUI 행 동작: 보낸 요청의 `action` 이 `{"kind":"dispute","ask_id":<행 값>,"question_id":<행 값>,"note":<입력>}` 이고, instance 가 그 행을 낸 instance 다. 행 값이 바뀐 뒤 보내면 요청이 나가지 않는다.
- 패키지: 0.3.3 schema 가 세 동작을 받고 `questions` 가 달린 dispute 를 거절한다. 채점 요청이 기다리는 질문 행에는 `dispute` 키가 없다. projection 과 `Flow.dispute` 가 같은 함수로 판단한다.

## 6. 대안

- **TUI 가 행 값을 클립보드에 담아 주기.** 복사 한 번이 줄 뿐, 붙여 넣기와 `kind` 고르기는 남는다. 대시보드에는 쓸 수 없다.
- **동작 schema 를 lane.toml 로 옮기기.** 설치 때 행 동작을 판정할 수 있다. 대신 worker 계약(`lane_act` 의 `inputSchema`)을 바꿔야 한다. 이 RFC 의 문제를 푸는 데는 필요 없다.
- **TUI 와 대시보드가 각자 판정.** 같은 패키지를 두 화면이 다르게 판정할 수 있다.

## 7. 사용자 결정

사용자가 2026-11-13 에 D1~D5 를 모두 아래 표대로 정했다.

| # | 결정 | 정한 것 | 근거 | 대가 |
|---|---|---|---|---|
| D1 | 판정 자리 | host | 두 화면이 같은 판정을 읽는다 | snapshot 에 칸 하나 |
| D2 | 동작 schema 자리 | 지금처럼 worker 가 알림 | worker 계약을 바꾸지 않는다 | 행 동작이 맞는지는 설치 때가 아니라 worker 가 뜬 뒤 안다. 안 맞으면 그때 흐리게 이유와 함께 보인다 |
| D3 | 두 id reading | 지움 | 옮겨 적을 일이 없어진다 | id 는 `D:raw` 에서만 보인다 |
| D4 | 대시보드(L5) | 방향만 적고 따로 | 동작 판은 지금 JSON 글이라 바꿀 폭이 크다 | 대시보드는 L5 전까지 지금과 같다 |
| D5 | TUI 진입 | 문법 RFC 의 동작 목록 | 동작 창, 구역 5, `?` 가 한 목록에서 나온다 | 동작 창이 lane 화면에 오기 전까지는 지금 `a:actions` 가 그 목록을 보인다 |

## 8. 확인하지 않은 것

- 동작 창 층(문법 RFC §9 5번)이 행의 동작 목록 값을 읽는 모양. 그 층의 PR 이 나오면 맞춘다.
- 대시보드가 lane 결과 행을 어디에 보여 주는지, 그 자리에 행 동작을 붙일 수 있는지.
- 대시보드 바인딩 양식(`lane-binding-form.ts`)을 동작 schema 에 그대로 쓸 수 있는지. 동작 schema 는 닫힌 object 만 받는다(`Closed_objects`).
- 라이브 서버가 이 RFC 를 쓰는 시점의 operator-quiz 설치판. 이 RFC 는 저장소의 0.3.2(`addons/operator-quiz/lane.toml`)를 기준으로 했다.
