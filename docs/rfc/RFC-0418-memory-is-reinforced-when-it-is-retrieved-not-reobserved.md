---
rfc: "0418"
title: "Memory OS: 기억은 다시 꺼내 쓸 때 굳는다 — reinforcement 카운터를 걷어내고 회수·인용·개정 사건을 기록한다"
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

같은 5일 동안 keeper 의 `keeper_memory_search` 호출은 약 1,300건,
`keeper_memory_write` 는 그 이상, sangsu 의 librarian 은 revision 599 까지 돌았다.
그래도 0 이다. 기전이 아니라 정의가 문제다.

## 2. 사람의 기억은 어디서 굳는가

이 RFC 의 첫 초안은 librarian 에게 "이번 대화가 이 기억을 다시 뒷받침했나" 를 묻고
그 답을 세자고 했다. 그것도 결국 라벨을 하나 더 만드는 일이고, 임계값(3/10, 비율
0.5)이 따라왔다. 카운터를 어떻게 올릴지 정하기 전에, 기억이 실제로 어디서 강화되는지
먼저 본다. 인지과학이 반복해서 확인한 것은 넷이다.

1. **꺼내 쓸 때 굳는다 (retrieval practice, testing effect).** 같은 내용을 다시
   읽는 것(재노출)보다 스스로 회수해 쓰는 것이 훨씬 오래 남는다. Roediger &
   Karpicke (2006), Karpicke & Roediger (2008). 재노출은 그 자리에서는 익숙하게
   느껴지지만 지속 효과는 작다.
2. **간격을 두고 굳는다 (spacing effect).** 같은 횟수라도 몰아서 반복하면 곧
   잊고, 간격을 두고 회수하면 오래 남는다. Ebbinghaus (1885), Cepeda 외 (2006)
   메타분석. 몰아치기 반복은 짧은 시간 안의 강도만 올린다.
3. **꺼낼 때 바뀐다 (reconsolidation).** 회수된 기억은 잠시 불안정해지고, 그때의
   맥락을 담아 다시 저장된다. Nader, Schafe & LeDoux (2000), Dudai (2004).
   강화와 수정은 같은 사건이다. 바이트가 같은 재관측은 생물학적 기억과 정반대의
   가정이다.
4. **예측이 맞았을 때 굳고, 예상된 반복은 신호가 없다 (prediction error).**
   Rescorla–Wagner (1972), Schultz 외 (1997). 이미 아는 문장을 매 pass 다시 보는
   것은 오차가 0 인 사건이라 학습 신호도 0 이다. librarian 이 같은 문장을 다시
   뽑는 재주입 루프가 정확히 이것이다.

사회 차원에서도 같다. 집단 기억은 다시 이야기되고(retelling), 인용되고, 기록으로
제도화될 때 남는다 — Halbwachs (1925), Assmann (1995). 어떤 사실이 다른 사람의
새 맥락에서 불려 나오는 것이 강화이고, 같은 문장이 같은 자리에 다시 적히는 것은
강화가 아니다.

masc 에 대응시키면:

| 사람 | masc 의 사건 | 성격 |
|---|---|---|
| 재노출 | recall block 이 매 턴 사실을 프롬프트에 싣는 것 | 강화 아님 |
| 같은 문장 재관측 | librarian 재주입, `upsert_fact` 바이트 일치 | 강화 아님, dedup |
| 회수 | `keeper_memory_search` 가 사실 m 을 결과로 돌려준 것 | **강화 사건** |
| 인용 | keeper 의 tool call 인자에 `memory_id` 가 실린 것, 다른 keeper 나 Board 글이 그 id 를 든 것 | **강화 사건** |
| 재저장(수정) | librarian 이 m_old 를 버리고 그것을 잇는 새 claim 을 쓴 것 | **개정 사건** |
| 간격 | 위 사건들의 시각 분포 | 저장하지 않고 투영 |

## 3. 판단

- 저장하는 것은 **사건**이다. 카운터, 강도, 신뢰 라벨은 저장하지 않는다. 사건은
  런타임이 실제로 일어난 자리에서 기록한다. 판단을 묻지 않는다.
- 강도는 읽는 쪽이 사건 기록에서 계산하는 **투영**이다. "검색으로 4회 회수, 8일에
  걸쳐, 마지막은 2일 전" 처럼 기록 자체를 보여 준다. 임계값과 라벨은 없다.
- 개정은 librarian 의 일이다. "같은 기억이 이렇게 바뀌었다" 는 의미 판단이고,
  librarian 은 이미 그 자리에 있다. `confirmed` 를 묻지 않고 `supersedes` 를 답하게
  한다.
- 어떤 사건도 gate 가 아니다. recall 순서, eviction, librarian 의 retain/drop 은
  이 기록을 읽지 않는다 (`keeper_memory_os_current.mli` 의 계약 그대로).
- `reinforcement` 정수 필드와 `upsert_fact` 의 증가는 지운다. 라이브 값이 전부
  0 이라 hard cut 이다.

## 4. 설계

### 4.1 사건 타입

```ocaml
(* keeper_memory_os_events *)
type event_kind =
  | Retrieved of { query : string }          (* keeper_memory_search 결과에 들었다 *)
  | Cited of { tool : string }               (* tool call 인자에 memory_id 로 실렸다 *)
  | Revised of { superseded_by : string }    (* librarian 이 이 사실을 잇는 새 claim 을 썼다 *)

type event =
  { recorded_at : float
  ; memory_id : string
  ; trace_id : string                        (* 그 턴 *)
  ; kind : event_kind
  }
```

닫힌 variant 다. 문자열로 분류하지 않는다. 새 종류가 필요하면 variant 를 더하고
컴파일러가 소비자 누락을 잡는다.

### 4.2 producer

- `keeper_memory_search_with_outcome` (`keeper_tool_memory_runtime.ml:248`):
  `fact_match` 는 이미 `Ordinary_memory_id` 를 든다(`:52-60`). 결과에 든 각
  사실에 `Retrieved { query }` 를 기록한다. 이미 있는 decision-log 줄
  (`:377-388`, `event: memory_search`)은 그대로 두고, 그 줄에도 `matched_memory_ids`
  를 싣는다.
- `keeper_memory_retract` 와 앞으로 `memory_id` 인자를 받는 모든 도구: 인자로 실린
  id 에 `Cited { tool }`. 텍스트 안의 id 를 정규식으로 찾지 않는다. 타입 있는
  인자만 센다.
- librarian: `new_claims[]` 에 선택 필드 `supersedes` (짧은 기억 ID `m<N>`). 파서는
  `dropped` 에 같은 id 가 있어야 받고(개정은 옛 것을 버리는 것과 함께 온다), 없으면
  답 전체를 거부한다. 적용 시 새 사실의 identity 로 `Revised { superseded_by }` 를
  옛 id 에 기록한다. 닫힌 variant 둘 추가: `Supersedes_unknown_memory_id`,
  `Supersedes_not_dropped`.

### 4.3 저장

사건은 keeper 별 append-only 사이드카 `<keeper>.memory-events.jsonl` 에 쓴다.
journal(`<keeper>.memory-journal.jsonl`)은 "librarian pass 당 한 줄, 턴 경로에서
읽지 않는다" 는 계약이 있어(`keeper_memory_os_current.mli:~110`) 턴 경로의 검색
사건을 거기에 섞지 않는다. 줄은 field-exact 코덱, 실패 시 append 는 경고로
격하한다(검색 결과를 돌려주는 일이 사건 기록에 막히면 안 된다). 스냅샷 코덱은
사건을 저장하지 않고, 사실 레코드에서 `reinforcement` 필드를 지운다.

사실이 dropped 되면 그 id 의 사건은 남는다. 기록이지 상태가 아니다. 읽는 쪽이
현재 사실에만 붙여 보여 준다.

### 4.4 투영과 소비자

- keeper API 의 memory 행: `reinforcement` 대신 `events` 요약을 싣는다 —
  `retrieved_count`, `retrieved_distinct_days`, `last_retrieved_at`, `cited_count`,
  `revised_from`(있으면 옛 id). 전부 사건 기록에서 계산한 값이고 저장하지 않는다.
- TUI Memory 탭: `×N` 배지와 `(Confirmed)`/`(High Confidence)` 를 지운다. 행에는
  "회수 4 · 8일 · 2d ago" 처럼 기록을 그대로 쓴다. 정렬은 recency(기본), 마지막 회수,
  회수 횟수. 상세 화면은 사건 목록을 시각순으로 보여 준다.
- 대시보드 journal 디코더는 `reinforcement` 필수 필드를 지우고 `events` 요약을
  받는다.
- recall/render 는 바뀌지 않는다. 모델에게 강도를 보여 주지 않는다. 재노출이
  강화가 아니듯, 강도 표시가 모델의 판단을 물들이면 안 된다.

## 5. 판정 기준

1. 배포 일주일 뒤 `Retrieved` 사건이 있는 사실 수와 그 분포를 센다. 검색 호출이
   하루 수백 건이니 0 이면 producer 배선이 틀린 것이다.
2. 한 사실의 회수 시각 분포로 간격을 볼 수 있어야 한다(`retrieved_distinct_days`).
   같은 턴 안의 반복 회수는 하루로 접힌다.
3. `Revised` 사건 수와, librarian 답에서 `supersedes` 가 파서를 통과한 비율.
4. `upsert_fact` 와 `apply_disposition` 어느 경로도 사건을 만들지 않는다(테스트).
   재관측은 dedup 이고 강화가 아니다.

## 6. 대안과 비채택

- **librarian 에게 `confirmed` 를 답하게 한다 (첫 초안).** 라벨을 하나 더 만드는
  일이고 "반박할 게 없어 남긴 것은 확인이 아니다" 같은 규칙과 비율 임계값이
  따라온다. 재노출을 강화로 셀 위험도 그대로다. 회수 사건은 이미 런타임에 있고
  판단이 필요 없다.
- **바이트 일치 재관측을 그대로 센다 (현재).** 움직이지 않고, 움직여도 뜻이 없다.
- **임베딩 유사도로 재관측을 잡는다.** 임계값이 새 휴리스틱이 된다. 같은 기억이
  어떻게 바뀌었는지는 librarian 이 `supersedes` 로 말하면 된다.
- **강도 값을 저장하고 감쇠시킨다.** 망각 곡선을 흉내 내는 상수가 생긴다. 시각이
  찍힌 사건을 저장하면 감쇠는 읽는 쪽이 언제든 계산할 수 있고, 저장소는 사실만
  든다.
- **recall block 주입을 회수로 센다.** 그것은 재노출이다. 매 턴 전부 +1 이 되어
  뜻이 사라진다.

## 7. 구현 범위와 순서

producer → store → consumer → caller 순이고, 한 PR 이 한 단계씩 닫힌다.

1. `keeper_memory_os_events`: 타입, field-exact 코덱, 사이드카 append/read,
   투영 계산(`summary_for ~memory_id`), 테스트.
2. `keeper_memory_os_types`: `reinforcement` 필드 제거, 스냅샷 코덱과 테스트. 라이브
   스냅샷은 필드가 있어도 exact-fields 디코더가 거부하므로 배포 전에 15개 store 의
   필드를 지우는 일회성 작업이 필요하다. 호환 reader 는 만들지 않는다.
3. `keeper_tool_memory_runtime`: 검색 결과에 `Retrieved` 기록, decision-log 줄에
   `matched_memory_ids`, retract 에 `Cited`.
4. `keeper_librarian` + `config/prompts/librarian.md`: `supersedes`, variant 둘,
   적용 시 `Revised` 기록.
5. keeper API 행, 대시보드 디코더, TUI 표시·정렬, 그 테스트.
6. RFC-0402 §3.2 의 "두 번째 관측은 reinforcement 로 센다" 를 이 RFC 를 가리키게
   고친다.

## 8. 건드리지 않는 것

- `memory_id` 가 claim 바이트의 digest 라는 것. dedup 키로는 맞다.
- recall/render 가 모델에 보여 주는 내용.
- 저장소가 판단값이나 사건 기록으로 truth 를 바꾸지 않는다는 계약.
