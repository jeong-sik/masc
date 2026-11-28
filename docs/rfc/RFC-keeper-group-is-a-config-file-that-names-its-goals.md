---
rfc: "keeper-group-is-a-config-file-that-names-its-goals"
title: "Keeper 그룹을 이름표에서 설정 파일로 올리고, 그룹 파일이 Goal 을 가리킨다"
status: Draft
created: 2026-11-28
updated: 2026-11-28
author: claude
related: ["config-field-kind-is-a-closed-type"]
---

# RFC keeper-group-is-a-config-file-that-names-its-goals: Keeper 그룹을 이름표에서 설정 파일로 올리고, 그룹 파일이 Goal 을 가리킨다

- 상태: **초안.** 운영자가 「그룹 목표 RFC」를 골랐다(2026-11-28). §6 의 세 선택은 운영자가 추천안으로 정했다(2026-11-28, 「휴리스틱 워크어라운드가 아니고 괴랄한 제약이 아니면 된다」). 승인 전에는 구현하지 않는다.
- 계기: 운영자 요청 「Keeper "회사" 를 그룹으로 바꾸고, 그룹을 만들고 고치고 지우고, 그룹 설정과 목표를 둔다」.
- 코드 좌표는 `origin/main` `99eea6d98bdc9` 에서 읽었다.

## 0. 요약

- 지금 그룹은 Keeper TOML 의 `keeper.group` 자유 글 한 줄이다. 그룹 자체를 담는 파일이 없다.
- 「그룹 없음」을 서버·대시보드·TUI 가 네 이름으로 부른다. TUI 는 그룹이 없으면 Keeper 이름 앞부분으로 그룹을 지어낸다.
- Goal 에는 주인이 없고, 모든 Keeper 가 같은 Goal 목록을 받는다. 헌법이 그렇게 정했다.
- 이 RFC 는 다섯 가지를 정한다.
  1. 그룹은 `.masc/config/groups/<id>.toml` 파일 하나다. 이름·설명·지시문·Goal 목록을 담는다(D1).
  2. 소속은 지금처럼 Keeper TOML 의 `keeper.group` 이 정한다. 값은 그룹 id 다(D2).
  3. 「그룹 없음」은 어디서나 값이 없는 것 하나로 다룬다(D3).
  4. 그룹 파일이 Goal id 를 가리킨다. Goal 은 그룹을 모른다. 구성원의 프롬프트는 그 Goal 에 「우리 그룹」 표시를 붙인다(D4).
  5. 그룹 지시문은 구성원 프롬프트의 블록 하나가 된다(D5).
- 권한, Board 멘션 대상, 실행 순서는 그룹이 정하지 않는다(D7).

## 1. 지금 모습

### 1.1 그룹은 Keeper 파일의 글 한 줄이다

- `keeper.group` 은 TOML 문자열이다(`lib/keeper/keeper_types_profile_toml_parser.ml:25`). 앞뒤 공백을 지우고, 비면 `None` 이다(같은 파일 `:358-363`).
- 쓰는 곳은 셋이다.
  - `masc_keeper_up` 의 `group` 인자(`lib/keeper/keeper_turn_up_args.ml:196-207`)
  - Keeper 설정 POST 의 `Field_group`(`lib/server/server_dashboard_http_keeper_api_post.ml:994-1001`)
  - 설정 PATCH `target=keeper:<name>`. 스키마 설명은 「대시보드에서 묶어 보이는 선택 이름표」다(`lib/server/server_dashboard_http_candle_config.ml:2180-2189`).
- 그룹 이름을 바꾸려면 구성원 파일을 모두 고쳐야 한다. 구성원이 없는 그룹은 어디에도 남지 않는다. 그룹 설명이나 설정을 둘 곳이 없다.
- 2026-11-28 운영 설정에서 `keeper.group` 을 쓰는 Keeper 는 31개 중 0개다(`tomllib` 로 읽기 전용으로 셌다).

### 1.2 「그룹 없음」의 이름이 넷이다

| 자리 | 그룹이 없을 때 | 위치 |
|---|---|---|
| 서버 shell `groups` | `"ungrouped"` | `lib/server/server_dashboard_http_core.ml:256-263` |
| 대시보드 Keeper 목록 | `'General'` | `dashboard/src/workspaces/keepers/keepers-api.ts:394` |
| TUI Fleet | 이름의 첫 `-` 앞부분이 두 Keeper 이상 같으면 그것, 아니면 `"Other"` | `lib/masc_tui/protocol/wire_fleet.ml:930-962` |
| 열린 PR #55334 의 그룹 막대 | `'미지정'` | `keeper-group-bar.ts`(PR 안) |

- 그래서 화면마다 그룹이 다르다. 예를 들어 TUI 는 `code-reviewer-brother`·`code-reviewer-father` 를 `code` 그룹으로 묶는다. 설정에는 그런 그룹이 없다.
- 대시보드 Pulse 는 shell 이름을 그대로 써서 `"ungrouped"` 를 보이고, 목록에 없는 Keeper 만 `'General'` 로 둔다.
- `"ungrouped"`·`"General"` 같은 이름을 가진 진짜 그룹은 「그룹 없음」과 구별되지 않는다.

### 1.3 Goal 은 주인이 없다

- 헌법: 「Goal 은 workspace 가 공유하는 목표이며 개별 소유자를 두지 않는다」(`docs/constitution.xml:35-36`).
- Goal 에는 주인·담당·그룹 필드가 없다(`lib/goal/goal_document.mli:3-16`).
- 모든 Keeper 의 턴이 같은 Goal 목록을 싣는다(`lib/keeper/keeper_unified_prompt.ml:1270`). Keeper 마다 다른 점은, 그 Keeper 가 잡은 Task 가 이어진 Goal 에 붙는 「내 일」 표시 하나다(같은 파일 `:464-472`).
- 헌법의 목표 시나리오는 「Keeper 가 팀을 이뤄 해내야 하는 케이스」다(`docs/constitution.xml:267`). 팀이라는 단위는 아직 어떤 타입에도 없다.

### 1.4 열린 PR #55334

- 대시보드에 그룹 막대를 더한다. 그룹을 고르면 목록을 거르고, `keeper.group` 을 설정 PATCH 로 바꾼다.
- shell 의 그룹 목록에서 `g.name`·`g.id` 를 읽는다. 서버는 `group` 키로 보낸다(`server_dashboard_http_core.ml:288`). 그래서 서버 목록은 모두 건너뛰고 Keeper 행의 `company` 만 쓴다.
- 그룹을 비우면 `group = ""` 을 파일에 남긴다. 키를 지우지 않는다.
- `"ungrouped"`·`"general"`·`"미지정"`·`""` 을 대소문자 없이 비교해 「그룹 없음」으로 본다.

## 2. 문제

1. 그룹이 파일로 없어서 만들기·이름 바꾸기·지우기·설정이 모두 구성원 파일 수정이 된다. 구성원이 없는 그룹은 사라진다.
2. 같은 Keeper 가 화면마다 다른 그룹에 있다. 하나는 이름을 보고 지어낸 그룹이다.
3. 그룹이 함께 맡은 Goal 을 적을 곳이 없다. 모든 Keeper 가 모든 Goal 을 같은 무게로 받는다.

## 3. 결정

### D1. 그룹은 설정 파일 하나다

```toml
# <base-path>/.masc/config/groups/review.toml   (id 는 파일 이름 review)
[group]
name = "리뷰 팀"
description = "PR 을 읽고 판정을 남긴다"
instructions = """
리뷰 판정은 근거 줄 번호와 함께 남긴다.
"""
goals = ["goal-0193...", "goal-0194..."]
```

- id 는 파일 이름이다. 소문자·숫자·`-` 로 된 slug 만 받는다. 파일 안에 `id` 키를 따로 두지 않는다. 두 곳에 적으면 서로 다를 수 있고, 그 차이를 잡는 검사가 따로 필요해진다.
- 읽을 때 모르는 키를 거절한다(헌법 `strict_parse_no_default`, `docs/constitution.xml:202-206`).
- `instructions` 는 여러 줄 글이다. 설정 화면은 RFC `config-field-kind-is-a-closed-type` 의 `Text` 종류로 연다.
- 그룹 타입은 `lib/types/keeper_group.ml(i)` 에 둔다. 서버만 파일을 읽고 쓴다.

### D2. 소속은 Keeper 파일이 정한다

- 한 Keeper 는 그룹 하나에 속하거나 속하지 않는다. 소속의 근거는 `keeper.group` 하나다. 그룹 파일은 구성원 목록을 따로 갖지 않는다.
  - 장점: 소속을 두 곳에 적지 않는다. 두 파일이 서로 다른 말을 할 수 없다.
  - 단점: 「이 그룹의 구성원」은 Keeper 파일을 모두 읽어 구한다. Keeper 가 수십 개라 읽는 양은 작다.
- `keeper.group` 값은 그룹 id 다. 없는 id 를 저장하려 하면 서버가 거절한다.
- 이미 저장된 파일이 없는 id 를 가리키면(그룹 파일을 손으로 지운 경우) Keeper 는 그대로 돈다. 소속은 닫힌 타입으로 읽는다.

  ```ocaml
  type membership =
    | No_group
    | Member of Keeper_group.t
    | Missing_group of Keeper_group.id   (* 파일이 가리키는 그룹 파일이 없다 *)
  ```

  - `Missing_group` 인 Keeper 의 프롬프트에는 그룹 블록도 「우리 그룹」 표시도 없다.
  - Keeper 행과 shell 은 `group: {"missing": "<id>"}` 로 보내고, 대시보드와 TUI 는 그 Keeper 에 「없는 그룹 `<id>`」를 표시한다. 운영자는 그룹을 다시 만들거나 소속을 바꾼다.
  - Keeper 를 멈추지 않는 이유: 헌법은 하드 게이팅을 기본으로 두지 않는다(`docs/constitution.xml:428`). 그룹은 권한도 실행 조건도 아니라서, 그룹 파일이 없다고 Keeper 일을 막을 근거가 없다.
- 지금 `keeper.group` 을 쓰는 Keeper 가 없으므로(§1.1) 옛 이름표를 옮기는 코드는 만들지 않는다.

### D3. 「그룹 없음」은 값이 없는 것 하나다

- 서버 응답의 Keeper 행은 `group: {"id": "<id>"} | {"missing": "<id>"} | null` 이다.
- shell 은 `groups: [{id, name, keepers}]` 와 `ungrouped_keepers: [...]` 를 따로 보낸다. `"ungrouped"` 라는 이름은 없앤다.
- 대시보드의 `'General'`, TUI 의 `"Other"` 와 이름 앞부분 추정, #55334 의 이름 비교를 지운다. 화면은 `null` 을 「그룹 없음」으로 그린다.

### D4. 그룹 파일이 Goal 을 가리킨다

- 그룹 파일의 `goals` 는 Goal id 목록이다. Goal 에는 아무 필드도 더하지 않는다. 헌법의 「Goal 은 개별 소유자를 두지 않는다」를 그대로 지킨다.
- 구성원 Keeper 의 Active Goals 블록은 그 Goal 에 「우리 그룹」 표시를 붙이고 앞에 둔다. 「내 일」 표시(`summary_held_task_link`)와 같은 방식으로, goal summary 에 닫힌 타입 필드 하나를 더한다.

  ```ocaml
  type group_link = Named_by_my_group | Not_named_by_my_group
  ```

- 다른 Goal 을 숨기지 않는다. 모든 Keeper 는 지금처럼 모든 Goal 을 본다. 무엇을 할지는 Keeper 가 고른다.
- 그룹 설정을 저장할 때 없는 Goal id 는 거절한다. 이미 저장된 그룹 파일이 없는 Goal id 를 가리키면 그룹 읽기를 거절하지 않는다. 그 id 를 「없는 Goal」로 보여 준다. Goal 은 지우지 않고 Drop 하므로 이 경우는 Goal 파일이 손상됐을 때만 생긴다.

### D5. 그룹 지시문은 프롬프트 블록 하나다

- `Prompt_block_id` 에 `Group_instructions` 를 더한다. 자리는 `Keeper_instructions` 바로 뒤다.
- 그 결과 대시보드 Keeper Prompt 탭과 TUI 프롬프트 블록 서브탭이 그룹 지시문을 따로 보여 준다. 블록 digest 가 턴 기록에 남아, 그룹 지시문이 바뀐 턴을 「구성」 Δ 로 볼 수 있다.
- 그룹 지시문은 System prompt 에 들어간다. 자주 바뀌지 않으니 Provider 캐시 앞부분을 깨지 않는다.

### D6. 만들기·고치기·지우기

| 동작 | 경로 | 권한 |
|---|---|---|
| 목록·읽기 | `GET /api/v1/groups`, `GET /api/v1/groups/<id>` | CanReadState |
| 만들기 | `POST /api/v1/groups` (`id`, `name`) | CanAdmin |
| 설정 고치기 | `POST /api/v1/config/patch` `target=group:<id>` | CanAdmin |
| 지우기 | `DELETE /api/v1/groups/<id>` | CanAdmin |
| 소속 바꾸기 | 지금처럼 Keeper 설정 PATCH 의 `keeper.group` | CanAdmin |

- 설정 고치기는 Keeper 설정과 같은 스키마·PATCH 경로를 쓴다. 대시보드와 TUI 설정 화면을 그대로 쓴다.
- 이름을 바꿔도 id 는 그대로다. 구성원 파일은 바뀌지 않는다.
- 구성원이 있는 그룹은 지울 수 없다. 서버는 409 와 구성원 목록을 돌려준다. 구성원을 함께 바꾸는 일괄 지우기는 두지 않는다.

### D7. 그룹이 하지 않는 것

- 권한을 주지 않는다. Board 멘션 대상을 정하지 않는다. 실행 순서나 대기를 정하지 않는다.
- 그룹 단위 runtime·sandbox 기본값은 이 RFC 에 넣지 않는다. 필요해지면 따로 올린다.
- 헌법의 「하드 게이팅을 기본으로 고려하지 않는다」(`docs/constitution.xml:428`)에 맞춘다.

## 4. 다른 방법과 고르지 않은 이유

| 방법 | 장점 | 단점 | 판단 |
|---|---|---|---|
| A. 이름표 그대로 두고 화면만 맞춘다 | 서버를 안 고친다 | 이름 바꾸기·빈 그룹·설정·Goal 을 둘 곳이 여전히 없다 | 고르지 않음 |
| B. 그룹 파일이 구성원 목록도 갖는다 | 그룹 파일 하나로 구성원을 안다 | 소속을 두 곳에 적어 서로 어긋날 수 있다 | 고르지 않음 |
| C. Goal 에 `group` 필드를 더한다 | Goal 을 읽으면 그룹이 보인다 | 헌법 `:35-36`(Goal 은 소유자가 없다)과 부딪친다. Goal 디코더와 저장 형식이 바뀐다 | 고르지 않음 |
| D. 그룹 Goal 이 아닌 Goal 은 구성원에게 숨긴다 | 프롬프트가 짧아진다 | 「공유 목표」라는 Goal 의 뜻이 바뀐다. 다른 그룹 일을 도울 수 없다 | 운영자 선택(§6) |
| E. 그룹 파일 + Keeper 소속 + 그룹이 Goal 을 가리킴(이 RFC) | 소속은 한 곳, Goal 모델은 그대로 | 새 파일 종류와 API 가 생긴다 | 고름 |

## 5. 단계와 확인 방법

1. `Keeper_group` 타입·읽기·쓰기 → 확인: slug 가 아닌 파일 이름과 모르는 키를 거절하는 시험. 왕복 시험.
2. `keeper.group` 이 그룹 id 인지 검사 → 확인: 없는 id 저장은 거절된다. 손으로 지운 그룹을 가리키는 Keeper 는 돌고, 응답에 `{"missing": "<id>"}` 가 오고, 프롬프트에 그룹 블록이 없다.
3. API 와 설정 스키마 `target=group:<id>` → 확인: 만들기·이름 바꾸기·지우기 시험. 구성원이 있으면 409.
4. 프롬프트: `Group_instructions` 블록과 Active Goals 의 「우리 그룹」 표시 → 확인: 구성원의 조립 결과에 블록이 있고 비구성원에게는 없다. 턴 기록 digest 가 지시문 변경을 따라간다.
5. shell·Keeper 행의 `group` 과 `ungrouped_keepers` → 확인: `"ungrouped"` 문자열이 응답에 없다.
6. 대시보드·TUI: 그룹 없음 이름과 이름 앞부분 추정을 지우고, 그룹 화면(목록·만들기·설정·지우기)을 둔다 → 확인: 화면 시험. `rg "'General'|\"Other\"|ungrouped"` 가 그룹 코드에서 0건.

- 1~5 는 서버 stack, 6 은 대시보드·TUI stack 이다. 5 와 6 은 응답 모양이 바뀌므로 같이 병합한다.
- PR #55334 의 그룹 막대는 D3·D6 에 맞춰 다시 쓰는 것이 낫다. 그 PR 작성자와 순서를 맞춘다.

## 6. 운영자 결정 (2026-11-28)

1. 그룹 Goal 이 아닌 Goal 도 구성원 프롬프트에 그대로 싣는다(§4 D 안을 고르지 않음). Goal 이 공유 목표라는 헌법 문장을 바꾸지 않는다.
2. 없는 그룹을 가리키는 Keeper 는 그대로 돌고, 「없는 그룹」을 상태로 보인다(D2). 처음 추천은 Keeper 를 띄우지 않는 것이었다. 그룹은 권한도 실행 조건도 아니라 Keeper 를 멈추는 것은 필요 없는 하드 게이트라서 거뒀다.
3. 그룹 지시문은 Keeper 지시문 뒤의 별도 블록이다(D5). 어느 지시문이 어느 턴에 바뀌었는지 따로 보인다.

## 7. 범위 밖

- 한 Keeper 가 여러 그룹에 속하는 것
- 그룹 단위 비용·한도
- 그룹 사이의 메시지 경로
