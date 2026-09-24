---
rfc: "memory-search-beyond-substring"
title: "Memory search: from substring containment to ranked candidates and judged recall"
status: Draft
created: 2026-09-24
updated: 2026-09-24
author: claude (requested by fsy)
supersedes: []
superseded_by: null
related: ["0247", "0418", "0456", "0463", "librarian-absorb-gate"]
---

# Memory 검색을 substring 너머로 — 현황, absorb gate 상수, 개선 방향

이 문서는 제안이다. 코드는 바꾸지 않는다. 채택할 단계를 고르면 단계마다 별도 PR 로 낸다.

## 1. 현황: `keeper_memory_search` 는 두 단 substring 매칭이다

Keeper 가 기억을 찾는 유일한 도구는 `keeper_memory_search` 다
(`lib/keeper/keeper_tool_memory_runtime.ml:565`, 스키마 `config/tools/keeper_memory_search.toml`).
`keeper_memory_recall.ml` 의 키워드 분류기는 이미 지워졌고, "무엇을 떠올릴지"는 Keeper 가 이 도구에
넣는 query 로 정한다. 그러니 이 도구가 못 찾으면 Keeper 는 모른다고 판단한다.

매칭 규칙(`answering`, `keeper_tool_memory_runtime.ml:109`):

| 단 | 조건 | 구현 |
|---|---|---|
| 1단 (whole) | claim 이 query 전체를 한 덩어리로 포함 | `String_util.contains_substring_ci` (`string_util.ml:55`) |
| 2단 (fragments) | query 를 공백으로 자른 **모든** 토큰이 claim 어딘가에 substring 으로 있음 (AND) | `String_util.contains_all_tokens_ci` (`string_util.ml:176`) |

- 대소문자 무시는 ASCII 만(`Char.lowercase_ascii`). 토큰 분리도 ASCII 공백만.
- 점수가 없다. 각 단 안에서는 스냅숏 저장 순서를 그대로 쓰고 `take limit` 으로 자른다.
- 순서: 일반 현재 기억 1단 → source-bound 1단 → 일반 2단 → source-bound 2단.
- `limit` 은 1~10, 기본 5 (`keeper_tool_memory_runtime.ml:572`).
- 같은 `answering` 을 `source=absorbed`(흡수된 원문 행)와 `source=history`(`search_history`, 같은 파일
  `:434`, 체크포인트 user 메시지 → trace 히스토리)가 공유한다.

### 1.1 이 방식이 놓치는 것

| 경우 | 예 | 결과 |
|---|---|---|
| 다른 말로 쓴 같은 뜻 | 기억 "배포 스크립트는 …", query "deploy script" | 0건 |
| query 쪽 토큰이 더 긴 교착어 | 기억 "소주", query "소주를" | 0건 (역방향은 매칭됨) |
| query 에 단어 하나가 더 있음 | 기억에 없는 "관련" 이 query 에 섞임 | 2단 AND 가 전부 탈락 |
| 한/영 혼용, 약어 | "PR" vs "풀 리퀘스트", "CI" vs "빌드" | 0건 |
| 매칭이 많을 때 | 흔한 단어 query | 오래 저장된 순서대로 5건, 관련도와 무관 |
| 비ASCII 대소문자/공백 | 전각 공백, 그리스·키릴 대문자 | 매칭 실패 |

`constitution.xml` 의 실패 조건 "비슷한 이야기를 반복한다. 10턴 전 자신의 발화나 행동을 모른다" 와
바로 이어지는 지점이다. 검색이 `no_match: true` 를 돌려주면 Keeper 는 이미 아는 것을 다시 조사하거나
다시 적는다.

### 1.2 현재 측정되는 것과 안 되는 것

- 회수 사건은 기록된다: 반환된 `memory_id` 마다 query 를 담은 `Retrieved { query }` 사건(RFC-0418,
  `record_memory_events`).
- 기록되지 않는 것: **아무것도 못 찾은 query**(반환 id 가 없으니 사건도 없다. 도구 출력으로 trace 에만 남는다),
  `no_match` 비율, "찾았어야 했는데 못 찾은" 사례. 개선 효과를 재려면 이것부터 있어야 한다(§3.0).

## 2. absorb gate 의 상수와 휴리스틱

`lib/keeper/keeper_librarian_absorb_gate.ml` (RFC-librarian-absorb-gate). Librarian 이 여러 기억을 새
claim 하나로 묶을 때, 원문 문장마다 판정 모델(TypeSafe Jev)에게 "claim 이 이 문장을 전하는가"를 묻는다.
검색과 직접 호출 관계는 없지만, 흡수된 원문이 `source=absorbed` 검색의 대상이 되므로 같은 기억 품질 문제의
다른 끝이다.

| 상수 / 규칙 | 값 | 위치 | 근거 기록 | 평가 |
|---|---|---|---|---|
| `conveyed_boundary` | 0.5 | `:146` | mli 에 0.3/0.5/0.7 재집계(84원문, 314문장): 채점기 일치율 88%, 흡수율 38% | 근거 충분. 이동은 RFC §7 의 2단계 몫 |
| 역방향 질문의 동점 처리 | 0.5 정확히는 "전하지 못함" | `judge_copies` | 동점이 claim 을 버리게 하지 않으려는 비대칭 | 의도가 명시됨 |
| `request_bytes_limit` | 32,000 B | `:169` | OpenRouter 32k 토큰 한도를 바이트로 (토큰 ≥ 1바이트) | provider hard limit 이라 constitution 예외에 해당 |
| `state_bytes_limit` | 16,000 B (절반) | `:170` | claim 과 질문이 한 요청을 나눠 씀. 운영 claim 최대 14,127B, p99 5,394B | 근거 충분 |
| `questions_per_request` | 64 | `:147` | mli 는 "요청 크기 상한"이라고만 적음. 수치 근거 없음 | **근거 미기록.** 바이트 한도가 이미 요청 크기를 묶으므로 중복일 수 있음 |
| `min_statement_chars` | 20 (code point) | `:6` | #37079 채점기와 경계를 맞춤 | **휴리스틱.** 20자 미만 조각을 다음 조각에 붙임 |
| 문장 경계 | 줄바꿈, `. ! ? ;` + 공백, `다.`, ` — ` | `:33-34`, 분할 루프 | 채점기와 동일 | **문자열 휴리스틱.** `다.` 로 끝나지 않는 한국어 문체(`~함`, `~음`, 명사형 종결)나 목록형 기억은 한 문장으로 뭉침 |
| 공백 판정 | ASCII 공백만 | `is_ascii_space` | 보정 코퍼스에 비ASCII 공백 없음 | 검색과 같은 ASCII 한정 |

정리하면 판정 자체(`conveyed_boundary`)와 크기 한도는 근거가 있고, **문장 자르기**(20자, 구두점 목록)와
`questions_per_request = 64` 가 근거가 약한 휴리스틱이다. 문장 자르기는 판정 단위를 정하므로 결과에 영향을 준다:
긴 원문이 한 문장으로 뭉치면 부분만 전해도 "전하지 못함"이 되어 흡수가 막히고, 잘게 쪼개지면 질문 수가 늘어난다.

## 3. 개선 방향

원칙은 RFC-0247 §1 의 교정된 경계를 그대로 따른다:
**"결정론 = 구조 + 값싼 후보 생성. 판단 = 실제 결정."** 그리고 constitution `<when_stuck>` 의
"괴상한 비교문 대신 Lane 을 늘린다". 검색에서 이는 다음을 뜻한다.

- 문자열 매칭은 **후보 생성기**로 강등하고, 후보를 고르는 결정은 LLM 판단으로 옮긴다.
- 후보 생성 자체도 순서 없는 substring 이 아니라 순위가 있는 lexical 검색으로 바꾼다.
- 임베딩/벡터 검색은 RFC-0247 §3 에서 **소유자 결정으로 거부**됐다(오프라인·결정론·재현성, 외부 의존).
  이 문서는 그것을 다시 제안하지 않는다. 다시 열려면 소유자 결정이 먼저다.

### 3.0 단계 0 — 먼저 잰다 (권장 첫 PR)

- `keeper_memory_search` 호출마다 source, `total_candidates`, `match_count`, `no_match` 를 OTel 카운터로
  세고, 0건 query 도 사건으로 남긴다(지금은 `Retrieved` 가 있는 경우만 query 가 남는다). 기억 본문은 이미
  private run evidence 로 남는 범위를 넘지 않는다.
- 운영 trace 에서 "`no_match` 직후 Keeper 가 같은 내용을 새로 조사하거나 `keeper_memory_write` 로 다시 적은"
  사례를 모아 **재생 세트**를 만든다. 이게 이후 단계의 합격선이다(단계별로 같은 세트에서 회수율 비교).
- 비용: 코드 변경 작음, 행동 변화 없음.

### 3.1 단계 1 — 순위 있는 lexical 후보 생성 (SQLite FTS5 + BM25)

저장소에 이미 선례가 있다: `lib/keeper/keeper_capability_search.ml` 은 요청마다 `:memory:` SQLite 에 FTS5
가상 테이블을 만들고 BM25 로 순위를 매긴다("SQLite FTS5 owns tokenization and BM25 ranking; this module adds
no stop-word, substring, regular-expression, or intent heuristics"). 같은 모양을 기억 검색에 쓴다.

- 인덱스: 요청마다 현재 스냅숏(+source-bound, 필요 시 absorbed)으로 메모리 DB 를 만든다. 영속 인덱스가
  없으니 스냅숏과 어긋날 상태가 생기지 않는다(`authoritative_read_only` 불변식과 충돌 없음).
- 토크나이저: `unicode61` 만으로는 한국어 교착 접미사("소주를")를 못 맞춘다. `trigram` 토크나이저는 부분 문자열을
  맞추고 유니코드 대소문자를 접는다. 단 **3글자 미만 토큰은 trigram 으로 못 찾는다**("소주", "PR").
  그래서 두 컬럼(`unicode61` 과 `trigram`)을 같이 두고 OR 로 묻는 구성을 제안한다. 구체 구성은 단계 0 재생
  세트로 고른다.
- 의미 변화: AND(전부 포함) → OR + BM25 순위. 단어 하나가 더 섞여도 결과가 사라지지 않는다.
  구절 일치는 FTS5 phrase query 로 여전히 최상위에 온다.
- 출력은 그대로 `memory_id`·store·basis. 도구 스키마 설명만 바뀐다.
- constitution 과의 관계: 검색 결과는 Keeper 에게 보여주는 후보일 뿐 제어 흐름 분기가 아니다. 그리고 매칭
  로직을 직접 짜는 대신 생태계 라이브러리(SQLite FTS5)에 맡긴다(`<libraries>`).

### 3.2 단계 2 — 판단으로 고르기 (recall 판정 lane)

lexical 은 "다른 말로 쓴 같은 뜻"을 원리적으로 못 찾는다. 임베딩을 거부한 이상 이 간극은 LLM 판단으로 메운다.
두 모양 중 하나를 고른다.

**2a. 선택형 (권장).** query 와 현재 기억 목록(`memory_id` + claim)을 판정 모델에 주고 "이 질문에 답하는 기억"을
고르게 한다. 출력은 닫힌 집합: 입력에 있던 `memory_id` 목록만 유효하고, 모르는 id 는 디코드 실패로 버린다
(`strict_parse_no_default`). 단계 1 의 BM25 상위 N 을 앞에, 나머지를 뒤에 두거나, 스냅숏이 요청 한도에
들어가면 전부 준다. absorb gate 와 같은 TypeSafe 계열 lane 이나 로컬 Standalone 모델(constitution
`<providers><local>`) 을 쓴다.

**2b. 질의 확장형.** 판정 모델이 query 를 한/영 동의어·다른 표현 몇 개로 바꾸고, 각각을 단계 1 에 넣는다.
싸지만 결정은 여전히 lexical 이 한다. 2a 가 불가능할 때의 대안이다.

공통 설계:
- `persist_before_model_call`: 판정 요청 전에 query 를 먼저 기록한다.
- 판정 lane 이 꺼져 있거나 실패하면 단계 1 결과를 그대로 돌려주고, 응답에 판정이 없었음을 typed 로 표시한다
  (조용히 빈 결과로 떨어지지 않게, `failure_keeps_evidence`).
- 호출 모드: 기본은 `no_match` 이거나 후보가 `limit` 을 넘을 때만 판정을 부르는 안과, 항상 부르는 안이 있다.
  constitution 은 비용을 문제 삼지 않으므로 "항상"이 더 단순하다. 지연이 체감되면 그때 조건부로 바꾼다.

### 3.3 단계 3 — 연상 (선택)

RFC-0247 의 그래프 한 홉(구조적 provenance, `Revised` 사슬, 같은 trace 에서 함께 `Retrieved` 된 기억)으로
검색 결과 옆에 "관련 기억" 을 붙인다. 결정론적이고 임베딩이 없다. 단계 2 판정의 입력 후보를 넓히는 용도로도 쓴다.

### 3.4 absorb gate 쪽 제안

1. **문장을 쓸 때 구조로 받는다.** Librarian 출력 계약(RFC-0456)의 claim 을 문장 배열로 받으면 gate 는
   문자열을 자를 필요가 없고 `min_statement_chars` 와 구두점 목록이 사라진다. 판정 단위를 쓰는 쪽(LLM)이
   정한다. 검색에도 도움이 된다: 단계 1 인덱스를 문장 단위로 만들 수 있다. 가장 근본적인 안이지만 출력 계약과
   Librarian 프롬프트를 함께 바꿔야 한다.
2. 1 이 부담스러우면: **문장 경계 보정을 재측정한다.** `다.` 외의 한국어 종결(`~함.`, `~음.`, 목록 `- `)이
   운영 기억에서 얼마나 되는지 #37079 코퍼스로 세고, 한 문장으로 뭉친 원문의 흡수율을 따로 본다. 수치가 나오기
   전에는 경계 목록을 늘리지 않는다(문자열 휴리스틱을 더 쌓는 방향이라서).
3. **`questions_per_request = 64` 의 근거를 적거나 없앤다.** 바이트 한도가 요청 크기를 이미 묶는다. 64 가 모델
   쪽 문항 수 한도(TypeSafe 문서)에서 온 것이면 그 출처를 주석에 적고, 아니면 바이트 한도만 남긴다.
4. `conveyed_boundary`, 바이트 한도는 그대로 둔다. 근거가 기록돼 있고 이동은 absorb gate RFC §7 2단계의 일이다.

## 4. 권장 순서

| 순서 | 내용 | 행동 변화 | 크기 |
|---|---|---|---|
| 1 | 단계 0 관측 + 재생 세트 | 없음 | 작음 |
| 2 | 단계 1 FTS5/BM25 (capability_search 모양 재사용) | 검색 결과 순서·범위 | 중간 |
| 3 | 단계 2a 선택형 recall 판정 | 의미 기반 회수 | 중간 |
| 4 | absorb gate 3번(64 근거) | 없음 | 아주 작음 |
| 5 | absorb gate 1번(문장 배열 출력) | Librarian 계약 | 큼, 별도 RFC |
| 6 | 단계 3 연상 | 결과에 관련 기억 추가 | RFC-0247 진척에 따름 |

각 단계는 main 기반 독립 PR 로 나눌 수 있다. 2 와 3 은 실제 의존이 있으므로 stacked PR 로 한다.

## 5. 결정 (2026-09-24, fsy)

- 단계 2 는 **2a 선택형**으로 간다.
- 단계 2 판정 lane 은 **로컬 모델**을 쓴다(기억 본문을 외부로 내보내지 않는다).
- 임베딩 거부(RFC-0247 §3)는 유지한다.
- 순서는 §4 표대로 단계 0 부터 진행한다.

## 6. 안 하는 것

- 코드 변경. 이 문서는 제안만 한다.
- 영속 검색 인덱스. 스냅숏과 어긋날 두 번째 진실을 만들지 않는다.
- 불용어 목록, 형태소 규칙, 정규식 같은 직접 짠 텍스트 휴리스틱.
