# RFC-OAS-002: OTel Metric Naming Convention & Eval Feed Schema

**Status**: Draft — Part A and Part B still apply. Part C is obsolete. Phase 2 is partially superseded and Phase 3 is obsolete; see the per-phase notes below and PR #2689.
**Date**: 2026-04-13
**Scope**: `lib/otel_tracer.ml`, `lib/eval.ml`, `lib/harness.ml`, `lib/llm_provider/metrics.ml`
**One sentence**: OAS가 방출하는 OTel metric/span 이름을 `oas.*` namespace로 표준화하고, harness swiss_verdict를 JSON schema로 공개하여 외부 consumer(downstream dashboards, Grafana, CI 등)가 안정적으로 소비할 수 있게 한다.

## Related Documents

- PR #841 (merged 2026-04-12) — event bus에 `session_id`/`worker_run_id` correlation 추가
- Issue #484 (open, Epic) — Delta-Context Architecture, checkpoint delta protocol
- `lib/otel_tracer.ml` — 현재 OTel tracer (W3C trace/span ID, OTLP JSON export)
- `lib/eval.ml` — `run_metrics`, `metric_value` 타입
- `lib/harness.ml` — swiss_verdict, verdict, layer 타입
- `lib/eval_baseline.ml` — regression detection (`Unchanged | Improved | Regressed | Added | Removed`)
- `lib/checkpoint.ml` — delta metric names (`checkpoint_delta_*`)
- `lib/llm_provider/metrics.ml` — provider-level event hooks
- `lib/raw_trace.ml` — JSONL trace format (v1, 6 record types)
- `docs/sdk-independence-principle.md` — downstream coordinator 어휘 역주입 금지

## Problem Statement

### 1. OTel Metric 이름 비표준

현재 OAS는 OTel semantic attribute(`gen_ai.agent.name`, `gen_ai.turn`)와 자체 metric name(`checkpoint_delta_apply_total`)을 혼용한다. 문제:

- **Namespace 충돌 위험**: `checkpoint_delta_*`는 OAS 고유이나 `gen_ai.*`는 OpenTelemetry GenAI SIG 공식 convention. OAS 자체 metric이 `gen_ai` 아래로 분류될 근거가 없음.
- **Consumer 파편화**: 외부 dashboard, Grafana, CI 각각이 metric name을 하드코딩. OAS가 이름을 바꾸면 downstream 전부 깨짐.
- **검색 불가**: `oas`라는 prefix가 없어 OTel collector에서 OAS 메트릭만 필터링하기 어려움.

### 2. Harness Verdict 스키마 비공개

`harness.ml`의 `swiss_verdict`는 OCaml 타입으로만 정의되어 있다:

```ocaml
type verdict = { passed: bool; score: float option; evidence: string list; detail: string option }
type 'obs swiss_verdict = { all_passed: bool; layer_results: 'obs layer_result list; coverage: float }
```

외부 consumer(downstream dashboard, CI reporter 등)가 이 구조를 안정적으로 파싱하려면 JSON Schema가 필요하다. 현재는 OCaml 소스를 읽어야 하고, 필드 추가/변경 시 downstream이 무예고로 깨진다.

### 3. Eval Metric 표준화 부재

`eval.ml`의 `metric_value`는 4-variant union(`Int_val | Float_val | Bool_val | String_val`)이지만, OTel metric으로 emit하는 경로가 없다. `run_metrics`가 수집하는 harness verdict와 trace summary도 OTel pipeline에 연결되지 않아 관측 불가.

## Design

### Part A: OTel Metric Naming Convention

모든 OAS-emitted metric은 `oas.` prefix를 사용한다. OpenTelemetry GenAI SIG convention(`gen_ai.*`)은 semantic attribute로만 사용하고 metric name에는 쓰지 않는다.

#### Naming Rules

```
oas.<subsystem>.<metric_name>[.<unit>]
```

| Rule | Example | Rationale |
|------|---------|-----------|
| Subsystem prefix | `oas.agent.turns_total` | OTel collector에서 `oas.*` 필터 가능 |
| Snake_case | `oas.checkpoint.delta_apply_total` | OTel metric naming convention 준수 |
| Unit suffix (선택) | `oas.llm.request_duration_seconds` | OTel unit convention |
| Counter suffix `_total` | `oas.tool.calls_total` | Prometheus convention 호환 |

#### Migration Table

| 현재 이름 | 새 이름 | 타입 |
|-----------|---------|------|
| `checkpoint_delta_apply_total` | `oas.checkpoint.delta_apply_total` | counter |
| `checkpoint_delta_apply_failures_total` | `oas.checkpoint.delta_apply_failures_total` | counter |
| `checkpoint_delta_size_bytes` | `oas.checkpoint.delta_size_bytes` | histogram |
| (신규) | `oas.agent.turns_total` | counter |
| (신규) | `oas.agent.run_duration_seconds` | histogram |
| (신규) | `oas.tool.calls_total` | counter |
| (신규) | `oas.tool.errors_total` | counter |
| (신규) | `oas.tool.duration_seconds` | histogram |
| (신규) | `oas.llm.requests_total` | counter |
| (신규) | `oas.llm.tokens_input_total` | counter |
| (신규) | `oas.llm.tokens_output_total` | counter |
| (신규) | `oas.llm.cost_usd` | counter (monotonic) |
| (신규) | `oas.llm.cache_hit_total` | counter |
| (신규) | `oas.context.compaction_total` | counter |
| (신규) | `oas.eval.verdict_passed_total` | counter |
| (신규) | `oas.eval.verdict_failed_total` | counter |
| (신규) | `oas.eval.coverage` | gauge (0.0-1.0) |

#### Semantic Attributes (변경 없음)

OpenTelemetry GenAI SIG attribute는 span attribute로 유지:
- `gen_ai.agent.name` — agent 식별
- `gen_ai.turn` — turn 번호
- `gen_ai.operation.name` — operation 식별
- `gen_ai.request.model` — (신규 권장) 요청 모델명

### Part B: Swiss Verdict JSON Schema

`harness.ml`의 verdict를 JSON Schema Draft 2020-12로 공개한다.

#### Schema 파일

`docs/schemas/swiss-verdict.schema.json`:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "oas:swiss-verdict:v1",
  "type": "object",
  "required": ["schema_version", "all_passed", "coverage", "layer_results"],
  "properties": {
    "schema_version": { "const": 1 },
    "all_passed": { "type": "boolean" },
    "coverage": { "type": "number", "minimum": 0.0, "maximum": 1.0 },
    "layer_results": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["layer_name", "passed", "evidence"],
        "properties": {
          "layer_name": { "type": "string" },
          "passed": { "type": "boolean" },
          "score": { "type": ["number", "null"] },
          "evidence": {
            "type": "array",
            "items": { "type": "string" }
          },
          "detail": { "type": ["string", "null"] }
        }
      }
    },
    "eval_metrics": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["name", "value"],
        "properties": {
          "name": { "type": "string" },
          "value": {},
          "unit": { "type": ["string", "null"] },
          "tags": {
            "type": "object",
            "additionalProperties": { "type": "string" }
          }
        }
      }
    }
  }
}
```

#### Versioning Contract

- `schema_version` 필드로 하위호환 관리. 현재 v1.
- 필드 추가 = minor bump (하위호환). 필드 제거/타입 변경 = major bump (breaking).
- JSON Schema 파일은 `docs/schemas/`에 체크인. `dune` rule로 OCaml 타입과 schema 동기 검증.

### Part C: Eval Metrics OTel Bridge

`eval.ml`의 `run_metrics`를 OTel metric으로 emit하는 bridge를 추가한다.

```ocaml
(* eval_otel_bridge.ml *)
val emit_run_metrics : Otel_tracer.t -> run_metrics -> unit
(** run_metrics의 harness_verdicts → oas.eval.* counters,
    trace_summary → oas.agent.* metrics로 변환 후 emit *)
```

동작:
1. `harness_verdicts` iterate → `oas.eval.verdict_passed_total` / `oas.eval.verdict_failed_total` increment
2. `coverage` → `oas.eval.coverage` gauge set
3. `trace_summary` → `oas.agent.turns_total`, `oas.tool.calls_total` 등

## Implementation Phases

### Phase 1: Metric Naming Migration (1 PR)
- `otel_tracer.ml`: `oas.*` namespace prefix 적용
- `checkpoint.ml`: 4개 delta metric 이름 변경
- `llm_provider/metrics.ml`: event hook metric을 `oas.llm.*`로 emit
- 하위호환: 1 release cycle 동안 구이름/새이름 동시 emit, deprecated 경고

### Phase 2: Swiss Verdict JSON Schema (1 PR)

> **Partially superseded by PR #2689.** The `Eval.run_metrics_to_json`
> bullet below was removed alongside the eval/harness execution stack
> purge; `Eval.run_metrics` no longer carries a `trace_summary` field
> and `Eval.set_trace_summary` is gone. The schema file
> (`docs/schemas/swiss-verdict.schema.json`) and
> `Harness.swiss_verdict_to_json` remain in place, so only the
> `eval.ml`-side JSON export obligation is retired.

- `docs/schemas/swiss-verdict.schema.json` 생성
- `harness.ml`에 `swiss_verdict_to_json` 함수 추가 (schema 준수 보장)
- ~~`eval.ml`에 `run_metrics_to_json` 함수 추가~~ — removed in PR #2689
- dune rule: `ppx_deriving_yojson`로 생성된 `to_yojson`과 schema를 cross-check하는 테스트. OCaml 타입이 source-of-truth, schema는 파생물.

### Phase 3: Eval OTel Bridge (1 PR)

> **Obsolete as of PR #2689.** `lib/eval_otel_bridge.ml` and its
> `.mli` were deleted with no consumers (the `oas eval` CLI entry point
> was removed in #1814, leaving the bridge with zero production
> callers). The `emit_run_metrics` call site in `agent.ml` was never
> wired. Do not implement this phase as written; a future OTel export
> path, if needed, must be re-RFC'd against the surviving
> `Eval.create_collector` surface.

- ~~`eval_otel_bridge.ml` 신규 모듈~~ — deleted in PR #2689
- ~~`agent.ml`의 run 종료 시점에서 `emit_run_metrics` 호출~~ — never wired; deleted in PR #2689
- ~~Integration test: mock tracer로 metric name/value 검증~~ — deleted alongside the bridge in PR #2689

## Risks

| Risk | Mitigation |
|------|------------|
| Metric rename이 기존 Grafana 대시보드를 깨뜨림 | Phase 1에서 1 cycle 동안 dual-emit. Downstream dashboards migrate first. |
| Dual-emit으로 metric cardinality 2배 증가 | Feature flag로 구이름 emit 대상을 선택적으로 제한. 전체 metric이 아닌 downstream consumer가 실제 사용하는 구이름만 dual-emit |
| JSON Schema와 OCaml 타입 drift | dune rule로 CI에서 schema↔type 동기 검증 |
| OTel GenAI SIG convention 변경 시 재작업 | `gen_ai.*`는 attribute만 사용, metric name은 `oas.*` 자체 namespace이므로 SIG 변경에 독립 |

## Scope Exclusion

- `Agent.replay_from()` API (Issue #484 Epic 범위)
- Checkpoint delta protocol 변경 (Issue #484 Epic 범위)
- Raw trace format 변경 (v1 유지)
- Downstream consumer code changes (those live in their own repositories, not in OAS)
- Cost tracking OTel emit 세부 구현 (~~Phase 3에서 다루되 cost_tracker.ml 내부 로직 변경은 없음~~ — `cost_tracker.ml`은 2026-07-21 test-only surface cut에서 삭제됨)
