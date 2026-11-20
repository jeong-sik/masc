---
rfc: "amendment-librarian-multi-category-facets-and-temporal-scope"
title: "RFC #53148 개정 제안 — 교차 카테고리 Merge 의 다중 facets 와 wall-clock 만료 없는 인과적 temporal_scope"
status: Draft (Deferred atop L6)
created: 2026-11-19
updated: 2026-11-19
author: worker-d
supersedes: []
superseded_by: null
related:
  - "librarian-call-only-proposes-and-one-writer-per-keeper-commits-in-one-line"
  - "0517"
  - "53538"
  - "53543"
  - "53548"
---

# RFC #53148 개정 제안 — 다중 카테고리 `facets` 와 인과적 `temporal_scope`

## 0. 범위와 적층 원칙 (Explicit Deferral Atop L6)

이 문서는 RFC `#53148` (*Librarian 의 모델 호출은 제안만 하고, 반영은 Keeper 마다 하나인 쓰는 쪽이 기록 한 줄로 한다*), 병합·교정 시 가장 이른 `first_seen` 상속(`#53538`, `main` 반영 완료), 그리고 단위가 기존 fact 를 다시 말했을 때 문장 복사 없이 이름으로 재확인하는 `seen` op(`#53543`, `{"op":"seen","ref":"m5","from":["u1"]}`) 위에 놓이는 **두 가지 후속 스키마 개정안**을 정의한다.

- **구현 연기 (Deferred Stack) 및 파일 소유권 분리**: 본 문서는 스키마 변경을 현재 L6g 스택 PR 에서 **즉시 코드로 적용하지 않는다**. `config/prompts/librarian.ask.md` 정본 소유권은 L6 스택 PR `#53583` (`feat/librarian-l6g-on-l6c`) 에 두고(공존 충돌 방지), 이 PR(`#53577`)은 `main` 기반 결정적 `test_librarian_l6g_scoring.ml` 채점 스위트, 설계 청사진, 그리고 L6(`#53605`/`#53583`/`#53606`) + `#53543`(`seen`) 병합 뒤 그 위에 적층할 `Librarian_answer`, `Librarian_plan`, `Keeper_memory_os_types` 스키마 개정 초안을 제공한다.
- **현행 L6g 유지 계약**: 스키마 개정 전까지 L6g 질문 프롬프트(`config/prompts/librarian.ask.md`, L10 컷오버에서 레이어 번호 의존을 없앤 기능 이름)는 `#53148` · `#53538` · `#53543` 와이어 계약(`question`, `question_end`, `working_state`, `ops` 의 `add`/`drop`/`merge`/`revise`/`seen` 및 빈 `"ops": []` 허용, 단일 `category`, `basis: { kind: "observed" }`, `seen` 시 `claim` 비복사·비어 있지 않은 `"from"` 필수·자기 말 되풀이 제외)과 정렬되며, `test_librarian_l6g_scoring.ml` 은 `main` 의 현행 4-op `Librarian_answer` 디코더 위에서 코퍼스 채점을 유지한다. `config/prompts/librarian.md` 레거시 경로는 건드리지 않는다.
- **헌법 준수 (`docs/constitution.xml`)**:
  - `magic_number` / `budget_gate` 금지: 숫자·빈도·나이 임계값으로 승격하거나 삭제하지 않는다.
  - `no_wall_clock_death` 준수: 시간 경과(TTL)로 Memory fact 를 자동 삭제하지 않는다.
  - `closed_sum_over_string` / `strict_parse_no_default`: 닫힌 합타입으로 시간 범위를 표현하고, 모르는 토큰/필드는 기본값으로 누르지 않는다.
  - 단일 정본 원칙(`legacy_residue`): 기존 `Keeper_memory_os_types.fact` 를 직접 확장하며, 병렬 그림자 타입, 변환 어댑터, 단계 승격 임계값, 자동 만료 TTL 삭제를 두지 않는다.

---

## 1. 실측 근거 (Measured Evidence)

### 1.1 실측 근거 (DATED/PASS-TIME 실험, `#53538`, `#53543`, `#53548` 및 `docs/research/2026-11-17-librarian-failure-history.md`)

`E-synth` 90건(기억 묶음 31개, Inkling-2-Small 두 실행 합산 기회 76회; 쓸 날이 남은 서로 다른 기억 12개, 쓸 날이 지난 서로 다른 기억 7개)에서 측정한 결과:

| 지표 (Inkling 두 실행 합) | 기준선 (`librarian.md`) | 초안 A (시각만 추가, 1실행) | 초안 F (시각 + 쓸 날 규칙) | 비고 |
|---|---:|---:|---:|---|
| 쓸 날이 남은 기억 보존 (`scheduled_ahead`) | `52/76` (조기 삭제 `24/76`) | `23/38` | **`73/76`** (조기 삭제 `3/76`) | 이항 `+4.5σ`; A 대비 묶음 구간 `+0.204 ~ +0.449` |
| 쓸 날이 지난 기억 정리 (`scheduled_past`) | `5/34` | `2/17` | **`13/34`** | 이항 `+2.2σ` |
| 지우기 정밀도 (`drop_precision`) | `82/111` | `40/57` | **`102/108`** | 이항 `+4.2σ`, 묶음 구간 `+0.006 ~ +0.388` |
| GLM 기준선 `scheduled_ahead` 보존 (1실행) | `17/38` (조기 삭제 `21/38`) | — | — | 기준선에서 절반 이상 조기 삭제 |

핵심 발견:

1. **판정 시각만으로는 부족하다**: 시각만 넣은 초안 A(`23/38`)는 기준선(`52/76`)과 차이를 보이지 못했다. 조기 삭제 사유 15건 중 11건이 시각을 보지 않고 "일회성 메모"라는 문구만으로 삭제했다.
2. **시각 + 명시적 규칙의 결합이 필요하다**: 시각과 쓸 날 구분 규칙을 함께 넣은 초안 F 에서만 조기 삭제가 `24/76 -> 3/76` 으로 감소했다(보존율 `52/76 -> 73/76`).
3. **`no_wall_clock_death` 및 별도 `now` 변수의 한계**: `2026-11-16` 실험은 별도 `pass_time` 템플릿 변수를 패치해 측정했으며, `§6.1` 은 "시각이 지났을 때 지우는 일이 `no_wall_clock_death` 와 어떻게 만나는가"를 미결정 과제로 남겼다. RFC `#53148 §5.5` 가 닫힌 턴 단위마다 `닫힌 시각` 을 이미 싣기 때문에, L6 에서는 별도 wall-clock `now` 를 주입하지 않고 **단위의 닫힌 시각과 완료 증거**로 인과 판정을 수행한다.

### 1.2 L6g 고정 합성 코퍼스 채점 (`test/test_librarian_l6g_scoring.ml`, `Librarian_scoring`)

`dune exec --root . test/test_librarian_l6g_scoring.exe` 실행을 통해 `Librarian_scoring` 으로 직접 측정한 결과 (`12` 개 합성 케이스: 쓸 날이 남은 기억 보존 + 변경 없음 + 완료된 쓸 날 기록 인과 삭제 + `Constraint`/`Preference` 교차 카테고리 `merge` + 상시 정체성 제약 대 일시 큐 스냅샷 + `revise` 및 `Read_item_alone` 가드레일 + Keeper 자기 되풀이 빈 `ops: []` + 표적 모순 해소·상대 날짜 절대화 + 진행형·수치 `merge` 보존 및 `working_state` 다리·제약 이중 보존 + 쌍을 이룬 "모른다" 비삭제 대조 vs 운영자 명시적 철회 및 원문 언어 보존):

```text
answers 12
thrown away 0
ops 13
ops left out 0
answers that changed Memory 9
planted 10, in Memory afterwards 10
merged away 8, kept by the merge 8
```

- **와이어·스크리닝 무손실**: `thrown away 0`, `ops left out 0` (12/12 유효 디코드 및 계획 반영).
- **정보 회수율**: `planted 10, in Memory afterwards 10` (`10/10` 회복).
- **교차 카테고리 · 진행형 `merge` 보존**: `merged away 8, kept by the merge 8` (`8/8` 필수 토큰 보존; `Constraint` + `Preference` 합성이 스키마 거절 없이 `Constraint` 로 수용되며, 진행형·수치·날짜가 단순 현재로 납작해지지 않음).
- **대조 검증**:
  - 동일 `upcoming_usable_until` 기억을 레거시 오판("일회성 체크포인트")으로 `drop` 하면 `c1_dated_hold` 가 즉시 삭제됨(`dropped_claims = [c1_dated_hold.claim]`).
  - 동일 `ref` 에 `revise` 와 `drop` 을 함께 적으면 두 번째 op 가 `Ref_used_twice` 로 걸러짐.
  - `Read_item_alone` (`shown.memory = None`) 에서 `drop` 또는 비-`null` `working_state` 를 쓰면 `Not_valid_alone` 으로 차단됨.
  - `"모른다"` 턴에서 `m1` 을 `"Provided context lacks CI failure details."` 로 덮어쓰는 회귀 응답은 원본 제약을 소실시킴(`has_claim c11_ci_owner.claim bad_plan.facts = false`).

단, 현재 L6 (`main`) 의 `Librarian_answer.new_fact` 와 `Keeper_memory_os_types.fact` 에는 `category` 가 **단일 필드**로만 존재하므로, 교차 카테고리 병합 후에는 검색/회수 계층에서 보조 카테고리 색인(`preference` 등)이 문장 텍스트 안에만 남고 타입 필드로는 사라진다. 또한 기억 자체가 `Standing` 인지 `Bounded` 인지 구조화된 표시가 없어, 프롬프트 지침에만 의존해야 한다. 아래 두 개정안은 L6 위에 이 두 구조를 타입으로 추가한다.

### 1.3 문헌·운영 실측 근거 (`librarian.ask.md` 설계 규칙의 실증 출처)

`config/prompts/librarian.ask.md` 와 `test_librarian_l6g_scoring.ml` 의 각 규칙은 다음 측정치에 직접 대응한다:

| 출처 / 이슈 | 측정 결과 | `librarian.ask.md` 반영 규칙 |
|---|---|---|
| **`Mem0 #4573`** (`mem0ai/mem0#4573`, `Claude Code #70525`) | 운영 감사 **10,134건 중 97.8%** 쓰레기(`"User prefers Vim"` 808개) — 회수 기억이 에이전트 출력에 실려 새 관측으로 재추출됨 | **`seen` 자기 말 되풀이 제외**: Keeper 가 기존 Memory 나 `working_state` 를 자기 발언에서 되풀이한 것은 `seen`·`add` 근거에서 배제하고 외부 사용자·자극·도구·Board 확인만 인정 |
| **MASC 운영/`2026-11-16 §0`** | 글 재작성 pointing 시 **18/27건**이 1~19자 차이; 운영 Memory **3,584개 모두 `last_seen == first_seen`** | **`seen` 전용 ref 지목**: 문장 재복사(`add`) 대신 `{"op":"seen","ref":"m5","from":["u1"]}` 로 `last_seen`·`sources` 만 갱신 |
| **`arXiv 2609.36457`** | 병합 시 진행형(progressive aspect)이 단순 현재로 납작해짐 (**381쌍 중 210쌍**, 반대 0쌍) | **`merge` 시제·진행형 보존**: 진행 중인 상태를 무시간 일반 현재로 깎지 않음 |
| **`arXiv 2608.11775`** | 일반 요약은 시간 표현을 **3.05%** 만 보존 | **상대 날짜 절대화 + 숫자/날짜/한정어 분리**: RFC `§5.5` 닫힌 시각(「지금」= 마지막 단위 닫힌 시각) 기준 절대 날짜화, 숫자·날짜·한정어 상이 시 `merge` 금지 |
| **`Graphiti #1728`** (`getzep/graphiti#1728`) | 그래프 전체 모순 탐색 시 fact **41%** 에 `invalid_at` 부여(수동 확인 **4건 중 3건**이 곁다리); 코드 주석 `"soft deadlines are not invalid_at"` | **표적 모순 해소 + `no_wall_clock_death`**: 직접 상충하는 같은 대상만 `revise`, 곁다리 fact 보존; soft deadline/쓸 날 경과만으로 자동 `drop` 금지 |
| **`code-reviewer` (`0/925`) / `pr-updater` (`0/551`) + `arXiv 2608.22752`** | Keeper 프롬프트에 Memory 본문 미주입·검색 0회(`code-reviewer` 72h 925턴 0회, `pr-updater` 551턴 0회); compaction 후 규칙 잔존 **1회 53% → 5회 10%** (**47%–90% 소실**) | **`working_state` 다리 + 제약 이중 보존**: `working_state` 에 `mN` 번호 대신 실제 `claim` 전문 전달, 유효 제약은 `working_state` 와 Memory fact 양쪽에 함께 유지 |

---

## 2. 개정안 1 — `Merge` 및 `Synthesize` 의 다중 카테고리 `facets`

### 2.1 문제

RFC `#53148 §6.2` 의 `new_fact` 와 `Keeper_memory_os_types.fact` 는 `category : category` 하나만 갖는다.
`Constraint` ("protected main 에 force-push 금지") 와 `Preference` ("stacked PR 과 `gh-stack rebase` 선호") 를 `Merge` 로 합치면:

- L6g 프롬프트가 본문 문장에 두 측면을 모두 보존하더라도 (`4/4` 토큰 유지),
- 스냅샷과 메모리 검색기(`keeper_memory_search` / `keeper_memory_select`)에서는 `Preference` 분류가 소실되고 단일 대표 `category` (`Constraint`) 만 남는다.
- 반대로 두 기억을 계속 분리해 두면 "지식마다 맞는 fact 하나" 원칙(RFC-0517) 과 충돌한다.

### 2.2 제안 타입 확장 (`Keeper_memory_os_types` 및 `Librarian_answer` 위 적층)

기존 `Keeper_memory_os_types.category` 를 깨뜨리지 않고(`category` 필드 유지), 선택적 `facets : category list` 를 덧붙인다:

```ocaml
(* Keeper_memory_os_types 확장안 — 기존 category 유지 *)
type fact =
  { claim : string
  ; category : category                  (* 기존 대표 카테고리 — 하위 소비자 호환 *)
  ; facets : category list               (* 선택적 보조/교차 카테고리 스펙트럼, 기본 [] *)
  ; first_seen : float
  ; last_seen : float
  ; origin : origin
  ; basis : basis
  }

(* Librarian_answer 확장안 (RFC #53148 §6.2 Merge.into / Add / Revise) *)
type new_fact =
  { claim : string
  ; category : category
  ; facets : category list               (* 와이어에서 생략 시 [] — 기존 L6 답과 호환 여부 정책 결정 *)
  ; observation : observation
  ; from_units : string list
  }
```

### 2.3 불변식 및 정산 규칙

1. **정규화 및 중복 제거**: `facets` 는 `category_to_string` 기준 중복 없이 정렬된 리스트이며, 대표 `category` 자체는 `facets` 에서 제외하거나(또는 항상 비어 있지 않은 보조 집합으로 유지) 단일 규약으로 고정한다. 예약어 `"all"`, `"source"`, `"dropped"` 는 기존 `category_of_string` 과 동일하게 거부한다(`strict_parse_no_default`).
2. **원본 스펙트럼 상속 (`Librarian_plan`)**:
   - `Merge` 가 `refs` 를 합칠 때, 모델이 명시한 `into.facets` 에 더해(또는 검증 시) 대체된 원본들의 `(fact.category :: fact.facets)` 중 대표 `into.category` 와 다른 항목을 합집합으로 보존할 수 있다.
   - `Add` 와 `Revise` 는 단일 카테고리면 `facets = []` 를, 여러 측면을 종합(Synthesize)한 경우 해당 보조 `category list` 를 싣는다.
3. **`Keeper_memory_os_types.category` 무파괴**:
   - `category` 필드의 타입과 의미(`Code_change | Fact | Preference | Blocker | Goal | Constraint | Validated_approach | Lesson | Custom of category_name`)는 전혀 변경하지 않는다.
   - `facets` 만 보고 읽는 새 검색/선택 소비자는 `(fact.category :: fact.facets)` 전체를 대상으로 매칭하고, 기존 소비자는 `fact.category` 를 그대로 읽는다.
4. **와이어 엄격성 (`strict_parse_no_default`)**:
   - L6+ 스키마 버전이 적용될 때 `Librarian_answer` 와 `memory-current.json` codec 이 `facets` 필드를 명시적으로 검증한다(알 수 없는 토큰이 있으면 `Unknown_token` 으로 거부; L6 현행 `exact_field_names_result` 계약에 맞춰 이 스택 PR 이 들어갈 때 `Librarian_answer` 와 golden fixture 를 함께 갱신한다).

---

## 3. 개정안 2 — `no_wall_clock_death` 를 지키는 명시적 `temporal_scope`

### 3.1 문제

`2026-11-16` 연구 기록 §6.1 이 짚었듯이, 시간 관련 기억을 프롬프트 문장만으로 구분하면 두 가지 극단이 생긴다:

- 기준선처럼 구분이 없으면 예정된 미래 작업(`scheduled_ahead`)을 "일회성 상태"로 오인해 `24/76` (GLM `21/38`) 조기 삭제한다.
- 반대로 자동 만료 상태나 TTL 숫자(`expires_at`, N일 경과 시 자동 sweep)를 넣으면 `docs/constitution.xml` 의 `no_wall_clock_death` ("시간 경과로 상태를 죽이지 않는다") 및 `magic_number` 를 정면으로 위반한다.

### 3.2 제안 타입 (`closed_sum_over_string`)

임의의 만료 시각 숫자나 자동 삭제 타이머 대신, fact 의 **구조적 시간 성격**을 닫힌 합타입으로 표현한다:

```ocaml
type temporal_scope =
  | Standing
      (** 정체성 결정, 아키텍처 불변식, 운영자 제약, 재사용 교훈.
          시간 경과로 절대 삭제되지 않으며, 명시적 대체/철회 증거로만 바뀐다. *)
  | Point_in_time
      (** 특정 순간의 일시적 상태/스냅샷(예: 큐 깊이, 대기 체크포인트).
          장기 기억으로 보존하지 않으며, 남길 교훈·제약 추출 후 인과적으로 정리한다. *)
  | Bounded of { valid_until_label : string }
      (** 특정 일정·마감·배포 창·목표 이벤트를 위해 유효한 기록(예: "2026-11-23").
          자동 TTL 삭제 대상이 아니다. *)
```

### 3.3 평가 규칙 (인과적 단위 시각 비교 — TTL 자동 삭제 절대 금지)

1. **자동 삭제 경로 없음 (`no_wall_clock_death`)**:
   - `Librarian_writer`, 스냅샷 로더, sweep 의 어느 코드도 `Unix.gettimeofday () > valid_until` 같은 벽시계 비교로 fact 를 자동 삭제하지 않는다.
   - 자동 만료 사유 생성자나 백그라운드 TTL sweeper 를 추가하지 않는다.
2. **평가 입력은 RFC `#53148 §5.5` 닫힌 단위 시각 + 완료 증거뿐**:
   - Librarian 은 질문 안 단위(`u1 … uK`)에 이미 기록된 **닫힌 턴 시각(`Closed.at`)** 과 **단위 본문/도구 관측 안의 완료·취소·대체 증거**만 보고 `Bounded { valid_until_label }` 이 아직 도래 전인지, 이미 종료됐는지 판단해 `Drop` 또는 `Revise` 제안을 낸다.
   - 단위가 없는 `Make_room` 질문이나 닫힌 시각 정보가 부족한 경우에는 상상한 `now` 로 `Bounded` 기억을 삭제하지 않는다.
3. **사유의 기록과 원복 가능성**:
   - `Bounded` 기억을 `Drop` 할 때는 반드시 단일 문장의 인과 사유(`Dropped { reason }`)를 `<k>.memory-log.jsonl` 에 남긴다. 원문은 반영 기록에 통째로 보존된다(`RFC #53148 §8.1`).
4. **L6g 와의 연속성**:
   - 현행 L6g 프롬프트(`config/prompts/librarian.ask.md`)는 `temporal_scope` 와이어 필드가 아직 없는 L6 환경에서도 텍스트 수준에서 `Standing` / `Point_in_time` / `Bounded` 3분류와 RFC `§5.5` 닫힌 단위 시각 비교 규칙(「지금」= 마지막 단위 닫힌 시각, 상대 날짜 절대화, soft deadline 보존)을 먼저 집행한다. 이 개정안은 그 규약을 후속 PR 에서 타입(`temporal_scope`)으로 승격하는 작업이다.

---

## 4. 후속 스택 구현 계획 (L6 병합 이후)

| 스택 단계 | 대상 모듈 | 내용 | 비고 |
|---|---|---|---|
| **A1** | `Keeper_memory_os_types` | `facets : category list` 및 `temporal_scope` 닫힌 합타입 + 엄격 JSON codec | 변환 어댑터 없이 L5/L6 snapshot schema 버전과 정합 |
| **A2** | `Librarian_answer`, `Librarian_plan` | `new_fact` 에 선택/명시 `facets`, `temporal_scope` 반영 및 `Merge` 시 원본 스펙트럼 합집합 보존 | `main` 의 `#53538` (`first_seen` 상속) 및 `#53543` (`seen`: 점수/횟수 임계값 없이 `last_seen` 과 단위 `sources` 만 갱신) 위 적층 |
| **A3** | `config/prompts/librarian.ask.md`, `Librarian_scoring` | 프롬프트 스키마 예시 확장 및 다중 facet · `Bounded` 보존율 채점 확장 | 기존 `test_librarian_scoring` 과 `test_librarian_l6g_scoring` 회귀 유지 |
