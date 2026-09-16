---
rfc: "0456"
title: "Librarian 의 출력 계약이 무변경을 가장 안전한 답으로 만든다 — 점호를 없애고 퇴장 경로를 가른다"
status: Draft
created: 2026-09-16
updated: 2026-09-16
author: claude
supersedes: []
superseded_by: null
related: ["0418"]
implementation_prs: []
---

# RFC-0456 — Librarian 의 출력 계약이 무변경을 가장 안전한 답으로 만든다

## 0. 요약

Librarian 은 Keeper 의 장기 기억을 선별한다. 라이브 fleet 에서 5,102 회차를 돌았고
그 중 **3,928 회차(77%)가 아무것도 바꾸지 않았다.** 한편 같은 Keeper 의 사실은
46일 동안 378개까지 늘었고, 최근 14일에만 +250 이다. 평평해지는 구간이 없다.

Librarian 이 게으른 것이 아니다. **출력 계약이 무변경을 유일하게 안전한 답으로
만들고 있다.**

1. 판정자는 현재 사실 **전부**에 판정을 달아야 한다. 하나라도 빠지면 답 전체가 거부된다
   (`Missing_disposition`).
2. 그렇게 받은 `retained_memory_ids` 는 적용 단계에서 **버려진다**
   (`keeper_memory_os_current.ml:1311` — `let (_ : string list) = retained_memory_ids in`).
   실제 적용은 "dropped 에 없으면 남김"이다.
3. 답이 거부되면 cadence 카운터가 0 으로 되돌아가 다음 시도가 한 바퀴 뒤로 밀린다
   (`keeper_librarian_runtime.ml:1132`, 기본 3턴).

즉 매 회차마다 **쓰이지 않는 378줄 점호**를 완벽하게 해야 하고, 한 글자 틀리면
판정 전체를 잃고 3턴 쉰다. 이 상황에서 100% 통과하는 답이 하나 있다 —
전부 retained, dropped 비움, new_claims 비움.

여기에 두 번째 문제가 겹친다. **사실이 나가는 길이 삭제 하나뿐이다.** 24개를
하나로 접으려면 24개를 영구히 못 읽게 만들어야 한다. `keeper_memory_search` 가
읽는 곳은 `Memory`(현재 스냅샷) / `History`(원본 사용자 메시지) / `All` 뿐이고,
`dropped` 된 사실에 도달하는 경로가 없다. 저널에 전부 남아 있지만 읽는 도구가 없다.

이 RFC 는 세 가지를 바꾼다. 새 저장 형식도, 새 상태도 만들지 않는다.

1. **점호를 없앤다.** `retained_memory_ids` 를 요구하지 않는다. 판정자는 바뀌는 것만 말한다.
2. **퇴장 경로를 가른다.** `dropped`(틀렸다)와 `absorbed`(더 큰 사실에 흡수됐다)를 나누고,
   흡수된 사실은 검색으로 도달 가능한 근거 층에 남긴다.
3. **판정자의 눈을 뜬다.** 이미 기록된 이력(`first_seen`, `last_seen`, 출처)을 프롬프트에 넣는다.

계수·가중치·유사도 임계값·나이 컷·중요도 점수는 **하나도 도입하지 않는다.**
무엇이 같은 주제이고 무엇이 낡았는지는 전부 판정자가 정한다.

## 1. 실측 (2026-09-16, `<base-path>/.masc/config/keepers`)

### 1.1 Librarian 은 돌고, 지우고, 못 따라잡는다

`code-reviewer.memory-journal.jsonl`, 8,297줄 전수.

| 소스 | 회차 | added | removed | 순증 |
|---|---|---|---|---|
| librarian | 5,102 | 1,639 | 3,012 | **−1,373** |
| explicit_write | 2,665 | 2,653 | 892 | **+1,761** |
| explicit_retract | 10 | 0 | 10 | −10 |

Librarian 은 넣는 것의 두 배를 지운다. 그런데 Keeper 가 직접 쓰는 `keeper_memory_write`
가 더 빨리 밀어넣어 순증이 난다. **청소부가 게으른 것이 아니라 청소부보다 쓰레기가
빨리 쌓인다.**

### 1.2 회차의 77% 가 무변경

Librarian 회차 5,102 건의 모양 분포.

| (added, removed) | 회차 |
|---|---|
| (0, 0) | **3,928** |
| (0, 1) | 177 |
| (1, 0) | 163 |
| (1, 1) | 118 |
| (2, 0) | 69 |
| (0, 2) | 60 |

넣고 빼기가 같은 회차에 일어난 것이 520건, 그 중 1:1 교체가 118건이다.
**여러 개를 하나로 접는 모양은 그보다 훨씬 드물다.**

`analyst` 도 같은 모양이다 — 3,595 회차 중 2,616 무변경, added 1,261, removed 3,162.

### 1.3 크기는 평평해지지 않는다

| Keeper | day ~32 | day ~46 | 최근 증가 |
|---|---|---|---|
| code-reviewer | 103 | 353 | 14일에 +250 |
| analyst | 157 (day 36) | 326 | 9일에 +169 |
| rondo | 123 (day 36) | 293 | 10일에 +170 |

code-reviewer 현재 378개 · 108,869자. 이 전체가 매 Librarian 회차 프롬프트에 들어간다
(`keeper_librarian.ml:159-166`, 상한 없음).

### 1.4 뭉칠 것이 없어서 안 뭉치는 것이 아니다

378개 claim 을 LLM 판정자에게 통째로 주고 "같은 주제로 묶여야 하는데 따로 남은 것"을
물었다. 입력은 Librarian 이 보는 것과 **완전히 동일**했다 — `claim` 과 `category` 뿐.

| | 개수 |
|---|---|
| 전체 사실 | 378 |
| 군집에 속한 사실 | **356** |
| 단독 사실 | 22 |
| 군집 개수 | 42 |
| 군집당 1건으로 접었을 때 | **64** |

가장 큰 군집은 24개이고, 전부 "TUI 는 어떤 폭·상태에서도 거짓을 말하지 않는다"의
특수 사례다. 두 번째는 18개, "초록 체크는 무엇이 실행됐는지 확인 전엔 증거가 아니다".

**같은 입력으로 다른 판정자는 묶어냈다. 보는 것이 막힌 것이 아니라 말하는 것이 막혀 있다.**

> 이 수치는 "이만큼 줄여야 한다"는 목표가 아니다. §4.3 을 볼 것 — 순진하게 접으면
> 실행 가능한 세부가 증발한다. 여기서 말하는 것은 **접을 거리가 실재한다**는 사실뿐이다.

## 2. 왜 무변경이 안전한 답인가

### 2.1 점호는 강제되고, 쓰이지 않는다

프롬프트 (`config/prompts/librarian.md:25-27`):

> 모든 기존 ID 를 `retained_memory_ids` 와 `dropped` 중 정확히 한 곳에 한 번씩 넣어야
> 합니다. 누락, 중복, 양쪽 포함은 답 전체가 거부되는 오류입니다.

코드도 그렇게 강제한다 — `keeper_librarian.ml` 의 `Missing_disposition`,
`Duplicate_retained_memory_id`, `Dropped_memory_id_also_retained`,
`Unknown_retained_memory_id`.

그리고 적용 단계 (`keeper_memory_os_current.ml:1311`):

```ocaml
let (_ : string list) = retained_memory_ids in
```

버린다. 그 아래는 `dropped` 에 든 것만 빼고 나머지를 그대로 유지한다. 즉 **적용은
이미 keep-by-default 이고, 점호는 검증 외에는 아무 데도 쓰이지 않는다.**

### 2.2 실패 비용이 크다

`keeper_librarian_runtime.ml:1132` 에서 실패한 pass 는 cadence 카운터를 되돌려
다음 시도를 한 바퀴 미룬다. 기본 cadence 는 3턴
(`lib/config/env_config_keeper.ml:274`, `librarian_cadence_turns_default = 3`).

378개를 완벽히 나열해야 하고, 틀리면 판정 전체를 잃고 3턴 쉰다.

### 2.3 그래서 보수적인 답이 지배한다

전부 retained · dropped 비움 · new_claims 비움 은 **항상 통과한다.**
24개를 접으려면 378줄 점호를 하면서 그 중 24개만 정확히 다른 칸으로 옮기고, 새 문장을
쓰고, 계승 링크를 걸어야 한다. 실패 확률이 훨씬 높고 실패 대가는 같다.

**계약이 위험을 보상하지 않는다.**

## 3. 왜 뭉치면 소멸하는가

### 3.1 나가는 길이 하나뿐이다

Librarian 이 사실을 현재 집합에서 내보내는 방법은 `dropped` 뿐이다. 그리고
`keeper_memory_search` 가 읽을 수 있는 store 는 셋이다
(`keeper_tool_memory_runtime.ml:18-37`):

| source | 읽는 것 |
|---|---|
| `Memory` | 현재 스냅샷 |
| `History` | 원본 사용자 메시지 |
| `All` | 위 둘 |

**`dropped` 된 사실에 도달하는 경로가 없다.** `memory-journal.jsonl` 에 사유까지 전부
남아 있지만 (code-reviewer 기준 8,297줄) 그것을 읽는 도구가 없다.

그래서 24개를 하나로 접는 행위는 **24개를 영구히 못 읽게 만드는 행위**와 같다.

### 3.2 통합 사실이 새것인 것은 문제가 아니다

통합된 기억은 새로 쓴 주장이므로 `first_seen` 이 지금인 것이 정직하다. 이것은 고칠
필요가 없다. 고쳐야 하는 것은 **원본이 갈 곳이 없다**는 것이다.

이 구분이 중요한 이유: 사실의 정체성을 내용과 분리하는 큰 변경
(`memory_id = SHA256(claim)`, `keeper_memory_os_types.ml:702-704`, lib/bin 302 곳 참조)이
필요하다고 볼 수도 있었다. **필요 없다.** 사실은 불변값으로 두고 **층만 바꾸면 된다.**

### 3.3 `supersedes` 가 1:1 이다

`keeper_librarian.ml:365-380` 에서 새 claim 하나가 `supersedes` 로 지목할 수 있는 것은
id 하나다. `translate_revisions` (`:448-466`) 도 1:1 로 매핑한다. 24개를 접었다고
적을 칸이 없다.

## 4. 변경

### 4.1 점호를 없앤다

`retained_memory_ids` 를 출력 스키마에서 제거한다. 판정자는 **바뀌는 것만** 말한다.

```
{ "dropped":     [ { memory_id, reason } ... ],
  "absorbed":    [ { memory_id, into } ... ],
  "new_claims":  [ { claim, category, absorbs: [memory_id ...] } ... ] }
```

적용은 이미 keep-by-default 이므로 **`keeper_memory_os_current.ml` 의 적용 로직은
바뀌지 않는다.** 없어지는 것은 `Missing_disposition` 강제와, 그것을 요구하는 프롬프트
조항과, 매 회차 378줄을 뱉는 출력 비용이다.

무결성 검사는 남는다 — 모르는 id 지목, 같은 id 두 번 지목, `absorbed` 의 `into` 가
이번 답의 `new_claims` 를 가리키지 않는 경우는 전부 거부한다.

### 4.2 퇴장 경로를 가른다

| | 뜻 | 어디로 |
|---|---|---|
| `dropped` | 틀렸거나 쓸모없다 | 사라진다 (지금과 같음) |
| `absorbed` | 더 큰 사실이 대신 말한다 | 근거 층. 검색으로 도달 |

`keeper_memory_search` 에 근거 층을 가리키는 source 를 추가한다. 강등된 사실은 **매
요청에 주입되지 않는다** — 현재 스냅샷에서는 빠지고, 물어볼 때만 나온다. 따라서
컨텍스트 오염은 생기지 않는다.

`new_claims` 의 `absorbs` 목록이 §3.3 의 1:1 제약을 대신한다. `supersedes` 는
`absorbs` 로 흡수되어 사라진다.

### 4.3 판정자의 눈을 뜬다

지금 사실 하나가 프롬프트로 나갈 때의 전부 (`keeper_librarian.ml:143-152`):

```ocaml
let current_fact_json index fact =
  `Assoc
    [ wire_field_memory_id, `String (surrogate_id_of_index index)
    ; ("fact", `Assoc [ wire_field_claim,    `String fact.claim
                      ; wire_field_category, `String (...) ]) ]
```

`claim` 과 `category` 둘뿐이다. 디스크에는 `first_seen`, `last_seen`, `origin`, `basis`
가 모두 있고 렌더 직전에 버려진다. **판정자는 378개 날짜 없는 맨 문장을 본다.**
3주 전에 적고 한 번도 안 건드린 사실과 오늘 아침 사실이 화면에서 똑같이 생겼다.

그리고 사실별 사용 기록도 이미 존재한다 (`keeper_memory_os_events.ml:180-186`):

```ocaml
type summary =
  { retrieved_count : int
  ; retrieved_distinct_days : int
  ; last_retrieved_at : float option
  ; cited_count : int
  ; revised_from : string list }
```

몇 번 조회됐고, 언제 마지막으로 조회됐고, 몇 번 인용됐는지 **전부 세고 있다.**
그리고 이 값은 TUI 로 간다 — `masc_tui_render_memory.ml:377,383` 이 `retrieved_count`
와 `cited_count` 를 그리고, `masc_tui_types.ml:3164` 에 "Retrieved (Most)" 정렬이 있다.

**운영자는 이 숫자를 본다. 무엇을 잊을지 정하는 판정자만 못 본다.**

이미 기록된 값을 그대로 넣는다. 파생 수치·점수·나이 구간은 만들지 않는다.

> m212 · lesson · 2026-08-30 기록 · 이후 같은 내용 재관측 없음 · 조회 0회 · 인용 0회 ·
> 출처: board p-c627b3…

오래된 것이 버릴 이유가 되는 것이 아니라 **판단의 재료**가 된다. 3주 된 운영자 계약은
조회가 0이어도 남고, 3주 된 일회성 사건 메모는 나갈 수 있다. 그 구분은 판정자가 한다.
`retrieved_count` 에 임계값을 걸지 않는다 — 숫자를 보여주고 판단은 넘긴다.

### 4.4 접기는 압축이 아니라 구조화다

§1.4 의 판정자가 명시적으로 경고한 것: 24개 TUI 군집의 멤버는 **서로 다른 계약**이다.
시간대 변환, 폭 절단, 이중 셈 제거, 미지값 표기, 전이행렬 게이팅은 서로를 대체하지
못한다. "TUI 는 거짓말하지 않게 렌더한다" 한 줄로 접으면 실행 가능한 관용구가 전부
증발한다.

따라서 통합 사실은 **절을 가진 하나의 기억**이어야 한다. 프롬프트가 요구할 것은
"짧게 만들어라"가 아니라 "같은 주제의 것들을 하나의 구조화된 기억으로 쓰라"이다.
`claim` 은 이미 여러 줄을 담을 수 있다 (현재 최대 1,265자).

## 5. 하지 않는 것

- 유사도 계수, 중요도 점수, 관련성 가중치, 나이 임계값, 호출 횟수 컷, 랭킹 공식.
  **하나도 넣지 않는다.** 의미 판정을 숫자로 근사하는 순간 안 맞는데 맞는 척하는 답이 나오고,
  이후 PR 이 그 패턴을 선례로 학습한다 (`software-development.md` §워크어라운드 거부 기준
  시그니처 2번).
- 사실 개수 정원. 크기는 상한이 아니라 접는 능력으로 통제한다.
- 사실 정체성 변경. `memory_id = SHA256(claim)` 은 그대로 둔다 (§3.2).
- 저장 형식 변경. hard cut 이 필요 없다.

20개 메모리 파일 전수 스윕 결과, **유사도 계수·가중치·관련도/중요도/신뢰도 점수·decay·
랭킹 공식은 한 곳도 없다.** `List.sort` 는 전부 `String.compare`(id·이름) 나
`Float.compare`(타임스탬프) 이고, 사실 내용을 읽어 순위를 매기는 비교 함수는 없다.
발견된 수치 휴리스틱은 전부 정수 상한과 비율 하나, 접두사 길이 하나다 (§6).

이 저장소는 같은 원칙을 이미 한 번 적용했다 — `keeper_memory_recall.ml:1-7`:

> 키워드 분류기 recall eval 은 legacy memory bank 와 함께 제거됨: recall 은 substring
> 휴리스틱이 아니라 `keeper_memory_search` 를 통한 Keeper 자신의 판단이다.

## 6. 같이 검토할 것 (이 RFC 범위 밖, 별도 판정 필요)

| 자리 | 규칙 | 왜 의심스러운가 |
|---|---|---|
| `keeper_memory_os_current.ml:703-722` | `maintain_supported_facts` — 전제가 사라진 derived fact 를 자동 무효화 | 판정자 없이 잊는다. 라이브에서 16,000 회차에 6번 발동 (code-reviewer 0 / analyst 1 / rondo 2 / lane-smith 3) |
| `keeper_memory_os_current.ml:729-737` | `merge_observation` — Board 가 Transcript 를 이기는 우선순위표 | "두 번째 읽기는 첫 번째가 주지 않은 것을 주지 않는다"는 판단이 match 로 굳어 있다. 내용이 아니라 출처 표기라 경계선 |
| `keeper_librarian_runtime.ml:394-435` | `fitted_messages` — body 한도에 맞을 때까지 메시지를 이분 탐색으로 줄인다 | 한도 자체는 바깥이 강제하는 물리값이지만, **무엇을 버릴지**를 코드가 정한다 (오래된 것부터) |
| `keeper_librarian_runtime.ml:458-494` | `fit_context_input` — source 를 탐욕적으로 채운다 | 같음. 무엇이 들어갈지를 코드가 정한다 |
| `keeper_librarian_context.ml:193-197` | 진행 basis 가 같고 pocket 이 `Current` 이고 모든 source 가 현재 집합에 있을 때만 `next_steps` 를 보여준다 | 판정자가 과거 정리 결과를 볼지를 코드가 정한다 |
| `keeper_tool_memory_runtime.ml:217-219` | `key_of s = String.sub s 0 (min 100 …)` — **앞 100자가 같으면 같은 메시지로 보고 하나를 버린다** | 접두사 동일성을 의미 동일성으로 쓴다. 긴 공통 머리말을 가진 서로 다른 메시지가 조용히 사라진다 |
| `keeper_memory_recall.ml:204` | `~max_lines:(max_n * 3)` — "user 메시지 1개당 로그 3줄"이라는 비율 가정 | 실제 비율이 낮으면 요청한 개수를 못 채우고 **조용히 적게 돌려준다** |
| `keeper_librarian_runtime.ml:71` | `prompt_max_messages = max_messages () * cadence_turns ()` (24 × 3 = 72) | 무관한 두 튜너블의 곱을 증거 창 크기로 삼는 공식 |
| `keeper_librarian_runtime.ml:1132` | 실패 시 cadence 한 바퀴 후퇴. 주석이 `"A three-turn delay on recovery is the cheaper side of that trade"` 로 근거 없음을 자인 | §2.2 의 실패 비용 본체 |
| `keeper_memory_source_current.ml:6` | `max_source_bytes = 1 MiB` 넘는 파일은 근거가 될 수 없다 | 바깥이 강제하는 값이 아니다. 파일시스템도 API 도 이 숫자를 모른다 |
| `keeper_memory_lane.ml:146-171` | 큐 깊이 1 — 미처리 유닛을 새 유닛이 덮는다 (`Replace_latest`) | 밀린 턴의 재료가 판정자에게 아예 안 간다 |

## 7. 미해명 — 이 RFC 는 이것을 설명하지 못한다

`explicit_write` 소스의 저널 항목 764건이 사실 892개를 **제거**했다 (code-reviewer).
`keeper_memory_write` 는 add-only 로 알려져 있고 (`keeper_memory_os_current.ml:1447`
— `let facts = if !found then facts else facts @ [ incoming ] in`, 유일한 found 분기는
바이트 동일 재관측), 도구 TOML 에 `memory_id`·`supersedes`·`replace` 필드가 없다.

표본 항목은 `outcome: committed`, `added: 1`, `removed: 4`, `retained: 48` 이었다.
제거된 행은 `claim`·`category`·`first_seen` 을 그대로 갖고 있었다.

**원인을 모른다.** §4 의 변경은 이것과 독립적이지만, 규명 전에는 "explicit_write 는
add-only" 라고 적은 어떤 문서도 믿을 수 없다. 별도 이슈로 판다.

## 8. 검증

이 RFC 의 효과는 라이브 저널로 직접 측정된다. 새 계측을 만들지 않는다.

| 항목 | 지금 | 기대 방향 |
|---|---|---|
| Librarian 무변경 회차 비율 | 3,928 / 5,102 (77%) | 내려간다 |
| `absorbs` 가 2개 이상을 지목한 회차 | 0 (칸이 없음) | 0 보다 크다 |
| 현재 사실 수 | 378, 14일에 +250 | 증가율이 꺾인다 |
| 답 거부로 인한 cadence 후퇴 | 미측정 | 내려간다 (점호가 없어지므로) |

§4.1 만 먼저 넣고 §4.2·§4.3 전에 한 번 측정하면, 점호 제거 단독의 효과를 분리할 수
있다. 점호를 없앴는데도 무변경 비율이 안 내려가면 남은 원인은 §3 의 소멸 대가라는 것이
증명된다.

## 9. 순서

1. **§4.1 점호 제거** — 출력 스키마와 프롬프트. 적용 로직 무변경. 효과를 단독 측정.
2. **§4.2 퇴장 경로 분리** — `absorbed` 와 근거 층, `keeper_memory_search` source 추가.
3. **§4.3 이력 노출** — 렌더 함수 하나.
4. **§6 재판정** — 위 셋이 자리 잡은 뒤, 남은 규칙들을 하나씩.

§7 은 1번과 병행해서 판다.
