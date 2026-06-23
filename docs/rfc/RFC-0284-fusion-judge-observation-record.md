# RFC-0284 — Fusion 심판 실행 관측 record (judge observation record)

- Status: Draft
- Author: Vincent (with Claude Opus 4.8)
- Parent: RFC-0252 (fusion panel-judge deliberation), RFC-0277/0278 (panel observation), RFC-0283 (judge-of-judges)
- implementation_prs: (this PR)

## 1. 동기

Fusion topology(`Simple|Refine|Conditional|Judge_of_judges`)는 keeper의 도구 입력 인자로만 존재하고, 어떤 대시보드 데이터 경로에도 emit되지 않는다. 4개 위상은 backend에서 서로 다른 judge 호출 구조로 실행되지만, sink에 도달하는 시점엔 `fusion_orchestrator.ml`의 `judge = Result.map fst judge_full`로 **단일 `judge_synthesis`로 collapse**된다. 결과적으로:

- JOJ의 N개 1차 심판 + meta 구조가 orchestrator 내부에서만 존재하다 영구 소실된다.
- board meta_json의 `judge`는 단일 객체라, 대시보드 `fusion-surface`는 위상과 무관하게 항상 단일 judge 노드만 렌더한다(`FusionPipelineStrip` 고정 5노드).
- 운영자는 대시보드에서 "이 run이 JOJ였고 3명의 심판이 독립 종합한 뒤 meta가 reconcile했다"를 볼 수 없다.

요구(2026-06-23, Vincent): **topology의 실행 구조가 대시보드에 고스란히 표시되어야 한다.**

## 2. 핵심 결정 — 관측 record (실행 추상 아님)

grounding(backend→frontend E2E 매핑)이 보여준 핵심: `panel[]`은 이미 **관측 데이터**(사후 실행 사실 배열)로 emit되어 frontend가 `run.panel.map`으로 topology를 모르고도 일반 렌더한다. `judge`만 단일로 평탄화되어 JOJ 구조가 소실된다.

따라서 **judge를 panel과 동형의 관측 record로 확장**한다:

- `judge_outcome`(`Synthesized of judge_node | Judge_failed of judge_error_node`)는 `panel_outcome`(`Answered | Failed`)와 구조 동형.
- orchestrator가 각 topology arm에서 *실제로 실행된* 심판 노드의 list(`judge_outcome list`)를 보존한다.
- sink가 board meta_json에 `judges:[]` 배열로 emit한다(기존 단일 `judge` 키는 canonical로 ADDITIVE 유지).
- 대시보드는 `judges` 배열의 shape만으로 구조를 렌더한다: **1 node = simple, 2 = refine, N개 first + meta = judge-of-judges**. 위상 이름 vocabulary를 frontend에 하드코딩하지 않는다.

### 2.1 관측 ≠ 실행 추상 (ChainEngine 재건 회피)

이 record는 *관측 데이터*(무엇이 실행됐나, 사후)이지 *실행 추상*(어떻게 조립하나, 사전 명세)이 아니다. masc는 `lib/chain` ChainEngine(47모듈 ~17K LOC 노드-그래프 DSL + Mermaid 파서)을 consumer 부재로 purge한 이력이 있다(#5799, #7747). 관측 record는 평면 배열이지 노드-그래프 어휘가 아니므로 그 묘지를 재건하지 않는다.

## 3. 설계

### 3.1 타입 (`fusion_core/fusion_types`)

```ocaml
type judge_role = Single | Refine_pass | First of string | Meta
type judge_node = { role : judge_role; synthesis : judge_synthesis; usage : usage }
type judge_error_node = { failed_role : judge_role; error : string }
type judge_outcome = Synthesized of judge_node | Judge_failed of judge_error_node
```

`First of string`은 panelist_id를 정체성으로 보존(panel `model`과 대칭). 전부 `[@@deriving yojson, show, eq]`.

### 3.2 orchestrator — per-arm hand-written (콤비네이터 없음)

`judge_full` match가 `(canonical result, judge_outcome list)` 쌍을 반환한다. 각 arm이 둘을 hand-write한다:

- `Simple` → `[Single]`
- `Refine` → `[Single; Refine_pass]` (2차 실패 시 `[Single; Judge_failed Refine_pass]`, canonical degrade=s1)
- `Conditional` → escalate 여부에 따라 1 또는 2 노드
- `Judge_of_judges` → `firsts`(성공/실패 모두) 노드 + `Meta`(또는 실패 노드). canonical은 meta 성공 시 meta_s, 실패 시 첫 1차 성공 first_s.

**콤비네이터/plan-tree를 도입하지 않는다**(§4). 닫힌 enum dispatch는 그대로 — 컴파일러 exhaustiveness가 새 위상 추가 시 모든 site를 강제한다.

### 3.3 sink — additive emit

`judge_synthesis_fields`를 `judge_meta`(canonical `judge` 키)와 `judge_node_meta`(`judges` 배열)가 공유한다(5섹션 직렬화 키 매핑 중복 회피). `judge_node_meta`는 `role`(single/refine/first/meta) + `identity`(First는 panelist_id) + 5섹션 + 노드별 usage를 emit한다.

### 3.4 byte-identity

기존 4 위상의 **결정 동작**(canonical synthesis decision/answer, chat 결론, wake payload, board headline, `observed_usage`)은 불변이다. canonical `judge_full`은 기존 로직과 동일하고, usage = 모든 Synthesized 노드 합산이 기존 계산과 일치한다(refine 성공 u1+u2 / 실패 u1 / JOJ firsts+meta / meta 실패 firsts). emit-shape 변경(`judge` 단일 + `judges` 배열 추가)은 ADDITIVE — 의도된 변화.

## 4. 콤비네이터 추출 defer (적대 분석 결정)

추출 형태를 4개 후보(observe-only / +combinator / +topology-data / +prompt-unify)로 6렌즈 적대 분석(워크플로우 `ww1hqdkun`, 9 agent)한 결과, **4개 독립 평가가 전부 "관측 record는 ship, 코드 추상은 defer"로 수렴**:

- **combinator**(Seq/Branch/Fan_reduce/Node plan tree): verbatim ChainEngine vocabulary, HIGH revival risk by the candidate's own admission. 닫힘이 타입 강제가 아닌 unexposed `.mli` 관습으로만 보장됨. 5번째 위상에서 1개 사이트(dispatch 1줄)만 절약.
- **topology-data**({producer;reducer} product): 16셀 중 ~5 유효 → arity catch-all = parse-don't-validate 역행 + 리터럴 `Fanout` 재도입. MEDIUM risk.
- **prompt-unify**: `compose_refine_prompt`의 `<prior_synthesis>`를 `<judge id>`로 collapse → Refine+Conditional 2개 위상의 LLM 프롬프트를 조용히 변경(golden 커버리지 0).

**추출 트리거**: 진짜 5번째 위상이 기존 primitive 조합으로 표현 가능하고 hand-written 중복이 *3번째* 재발할 때. 그 전엔 5번째 match arm + 작은 헬퍼로 충분(exhaustive match가 누락 강제). 3-Try/추상화 거부 기준 적용.

## 5. 비범위 (별도 작업)

- **registry topology label**: registry `run` record(PATH B)는 run-detail view(PATH A board)와 join되지 않으므로 topology field를 넣어도 detail에 안 보인다. RUNNING card용 lifecycle label은 별도 가치이나 이 PR 범위 밖.
- **preset/topology two-path join**: `fusion-surface.ts:651`의 `preset · n/a` stub. run_id correlation 필요. 별도 item.
- **dashboard render**: `judges` 배열을 `run.judges.map`으로 렌더하는 frontend 변경은 PR 2(#22081 `fusion-surface.ts` 위에 stack).

## 6. 대안 (기각)

- **graph-kernel** (keeper-authored graph JSON): tool-schema 층에 중첩 그래프 어휘가 없어 구축 불가(B1, bake-off `w5hzcsycl`). 닫힌 named-topology enum이 SOUND.
- §4의 3개 코드 추상: 적대 분석 `ww1hqdkun`에서 전부 REJECT.

## 7. 검증

- `fusion_core/test_fusion.ml`: `judge_outcome` yojson round-trip(First panelist_id + decision 3변형 + 성공/실패 노드).
- `test_fusion_sink_meta.ml`: `judge_node_meta` value-pin(role/identity 정확값, 5섹션 스키마 공유, 노드별 usage, 실패 노드).
- orchestrator의 per-arm 노드 구성 + canonical byte-identity는 N+1 심판 LLM 실행이 필요 → RFC-0252 §11 하네스(별도 트랙).
