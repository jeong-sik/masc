---
rfc: "0418"
title: "Memory OS: reinforcement 는 librarian 이 '이번 대화가 이 기억을 다시 뒷받침했다' 고 판단한 횟수다 — 바이트 동일성 카운트를 걷어낸다"
status: Draft
created: 2026-09-05
updated: 2026-09-05
author: vincent
supersedes: []
superseded_by: null
related: ["0247", "0251", "0402", "tui-operator-ia"]
---

## 1. 문제

`fact.reinforcement` 는 "같은 claim 바이트가 다시 관측된 횟수" 다
(`lib/keeper/keeper_memory_os_types.mli:241-248`). 올라가는 자리는
`Keeper_memory_os_current.upsert_fact` 하나다
(`lib/keeper/keeper_memory_os_current.ml:1398-1416`):

```ocaml
if String.equal (memory_id existing) incoming_identity
then (
  { incoming with
    first_seen = existing.first_seen
  ; last_seen = Float.max existing.last_seen incoming.last_seen
  ; reinforcement = existing.reinforcement + 1
  ; origin = existing.origin
  ; basis = merge_basis existing.basis incoming.basis })
```

그 함수를 부르는 건 keeper 의 `keeper_memory_write` 도구뿐이다
(`lib/keeper/keeper_tool_memory_runtime.ml:685-691`). LLM 은 같은 사실을
바이트까지 같게 다시 쓰지 않으므로 이 값이 움직일 길이 없다.

재관측이 실제로 일어나는 자리는 librarian 이다. 매 pass 현재 기억 전체와 새 대화를
읽고 `retained_memory_ids` / `dropped` / `new_claims` 를 답한다
(`lib/keeper/keeper_librarian.ml:36-41`). 그 답을 적용하는 `apply_disposition`
(`lib/keeper/keeper_memory_os_current.ml:1263-1320`) 은 이미 있는 identity 의
`new_claims` 를 "중복이므로 건너뜀" 처리하고 카운트를 올리지 않는다. RFC-0402
§3.2 (`docs/rfc/RFC-0402-memory-os-board-provenance.md:46`) 는 "두 번째 관측은
reinforcement 로 센다" 고 적었지만 구현은 그 문장을 지키지 않는다.

그런데 TUI Memory 탭은 이 값을 기본 정렬로 삼고 `×N` 배지를 그리며, 3 이상이면
`(Confirmed)`, 10 이상이면 `(High Confidence)` 라고 붙인다
(`bin/masc_tui_render.ml:12113-12126`, `:12203-12211`). 화면이 약속하는 것은
"확인된 사실" 인데, 값이 세는 것은 "저장소가 중복 행을 흡수한 횟수" 다. 둘은
다른 개념이고, 후자는 0 이다.

### 1.1 실측 (2026-09-05, `~/me/.masc/config/keepers/*.memory-current.json`)

| store | facts | reinforcement > 0 |
|---|---:|---:|
| 15 개 keeper | 1,094 | 0 |
| origin `injected` (librarian) | 1,020 | 0 |
| origin `authored` (keeper 도구) | 74 | 0 |

같은 5일 동안 keeper 의 memory 도구 호출은 2,571건, sangsu 의 librarian 은
revision 599 까지 돌았다. 그래도 0 이다. 기전이 아니라 정의가 문제다.

## 2. 판단

"이 기억이 다시 뒷받침됐다" 는 바이트 비교가 답할 수 있는 질문이 아니다. 같은
뜻을 다른 문장으로 말하는 것이 대화의 기본이고, 그것을 알아보는 자리는 이미 있다.
librarian 이다. 그러므로:

- `reinforcement` 의 정의를 **librarian 이 confirmed 로 답한 횟수** 로 바꾼다.
- 바이트 동일성은 dedup 키로만 남는다. `upsert_fact` 의 identity 일치는 행을
  하나로 유지하고 `last_seen` 만 갱신한다. 카운트를 올리지 않는다.
- 값은 projection 이다. recall 순서, eviction, 어떤 gate 에도 쓰지 않는다
  (`keeper_memory_os_current.mli`: "importance, recency, budget, echo 휴리스틱은
  truth 를 바꾸지 않는다" 는 그대로다).

`retained` 와 `confirmed` 는 다르다. "반박할 게 없어서 남겼다" 를 확인으로 세면
매 pass 전부 +1 이 되어 다시 뜻이 사라진다. librarian 에게 묻는 것은 "이번 대화에
그 기억을 다시 뒷받침하는 내용이 있었나" 하나다.

## 3. 설계

### 3.1 librarian 답 스키마

`config/prompts/librarian.md` 출력 스키마에 배열 하나를 더한다.

```json
"confirmed": [
  {
    "memory_id": "정확한 현재 기억의 짧은 기억 ID, 예: m3",
    "reason": "한 문장: 이번 대화의 어느 부분이 이 기억을 다시 뒷받침했는지."
  }
]
```

규칙 문장을 프롬프트에 적는다: `confirmed` 는 `retained_memory_ids` 에도 있는
ID 만 담는다. 이번 대화가 새로 뒷받침한 기억만 넣고, 반박할 게 없어서 남기는
기억은 넣지 않는다. 뒷받침한 것이 없으면 빈 배열이다.

### 3.2 타입과 검증

```ocaml
(* keeper_memory_os_types *)
type confirmation_statement = { memory_id : string; reason : string }
(* dropped_statement 와 같은 모양, 같은 field-exact 코덱. journal 줄에 실리고
   스냅샷 코덱은 저장하지 않는다. *)

(* keeper_librarian: selection 에 confirmed : confirmation_statement list *)
(* parse_error 에 닫힌 variant 넷 추가 *)
| Confirmation_schema_mismatch
| Unknown_confirmed_memory_id of string
| Duplicate_confirmed_memory_id of string
| Confirmed_memory_id_not_retained of string   (* dropped 이거나 retained 에 없음 *)
```

기존 규칙과 같이, 하나라도 걸리면 답 전체를 거부한다. `_ ->` 없이 전 variant 를
`parse_error_to_string` 에 적는다.

### 3.3 store

`apply_disposition ~confirmed` 를 받는다. 적용은 `dropped` 를 뺀 뒤, `confirmed`
의 각 id 에 대해 그 행의 `reinforcement + 1`, `last_seen = now`. `new_claims` 처리는
지금과 같다(중복 identity 는 건너뜀). confirmation statement 는 dropped statement 와
같은 자리, 즉 그 commit 의 journal 줄에 실린다. 스냅샷에는 카운트만 남는다.

`upsert_fact` 의 identity 일치 가지에서 `reinforcement = existing.reinforcement + 1`
을 지운다. 나머지(`first_seen`·origin 보존, `last_seen` 갱신, basis merge)는 그대로다.

### 3.4 wire, 소비자

- 스냅샷의 `reinforcement` 필드 이름과 타입은 그대로다. 뜻만 바뀌고, 라이브 값이
  전부 0 이라 hard cut 에 옮길 데이터가 없다. 호환 reader 를 만들지 않는다.
- journal 줄: `dropped` 옆에 `confirmed` 배열. 대시보드 TS 디코더
  (`dashboard/src/api/dashboard-memory-journal.ts`) 는 새 배열을 받는다.
- TUI Memory 탭: `×N` 은 "librarian 재확인 N회" 로 라벨을 바꾼다. `(Confirmed)` /
  `(High Confidence)` 는 지운다. 확신을 재는 값이 아니고, 임계값 3/10 은 어디서도
  나온 숫자가 아니다. 기본 정렬은 recency 로 두고 reinforcement 정렬은 남긴다.
  마지막 confirmation 의 `reason` 은 journal detail(Ctrl-N)에서 이미 보이는 자리에
  실린다.
- recall/render(`keeper_memory_os_render.ml`)는 바뀌지 않는다. 모델에게 이 값을
  보여 주지 않는다.

## 4. 판정 기준

1. 배포 일주일 뒤 `reinforcement > 0` 인 사실이 있어야 한다.
   `jq '[.facts[] | select(.reinforcement > 0)] | length' <base>/.masc/config/keepers/<k>.memory-current.json`
2. pass 당 `confirmed / retained` 비율을 journal 에서 센다. 대부분의 pass 에서 0.5
   를 넘으면 프롬프트 규칙("반박할 게 없어 남긴 것은 확인이 아니다")이 지켜지지
   않는 것이고, 그때는 프롬프트를 고친다. 카운트를 깎는 장치를 넣지 않는다.
3. `upsert_fact` 경로에서 reinforcement 가 변하지 않는다(테스트).

## 5. 대안과 비채택

- **라벨만 걷어내고 필드를 둔다.** 정직하지만 RFC-0402 가 약속한 "두 번째 관측"
  개념을 영영 비워 둔다. librarian 이 이미 그 판단을 하는 자리에 있으니 채우는
  쪽이 맞다.
- **retained 를 그대로 확인으로 센다.** 매 pass 전부 +1 이라 뜻이 없다(§2).
- **임베딩 유사도로 재관측을 잡는다.** 같은 질문을 두 번째 모델에게 다시 묻는
  꼴이고, 임계값이 새 휴리스틱이 된다. librarian 의 한 번의 판단으로 충분하다.
- **카운트를 recall 순서나 eviction 에 쓴다.** 모델 판단을 gate 로 쓰는 것이고
  `keeper_memory_os_current.mli` 의 계약과 어긋난다. 하지 않는다.

## 6. 구현 범위와 순서

한 PR 로 닫힌다. 순서는 producer → store → consumer → caller 다.

1. `keeper_memory_os_types`: `confirmation_statement` 타입·코덱·wire 필드, 테스트.
2. `keeper_librarian`: `selection.confirmed`, 파서와 variant 넷, 테스트
   (`test/test_keeper_librarian_retry.ml` 옆).
3. `keeper_memory_os_current`: `apply_disposition ~confirmed`, journal 줄,
   `upsert_fact` 의 증가 제거, 테스트(`test/test_keeper_memory_os_current.ml`).
4. `config/prompts/librarian.md`: 스키마와 규칙 문장. 프롬프트 자산 동기화
   테스트가 이 파일을 읽는다.
5. `keeper_librarian_runtime`: `~confirmed:selection.confirmed` 전달.
6. 대시보드 journal 디코더, TUI 라벨·기본 정렬, 그 테스트.
7. RFC-0402 §3.2 의 "두 번째 관측은 reinforcement 로 센다" 문장을 이 RFC 를
   가리키도록 고친다.

## 7. 건드리지 않는 것

- `memory_id` 가 claim 바이트의 digest 라는 것. dedup 키로는 맞다.
- recall/render 가 모델에 보여 주는 내용.
- 저장소가 판단값으로 truth 를 바꾸지 않는다는 계약.
