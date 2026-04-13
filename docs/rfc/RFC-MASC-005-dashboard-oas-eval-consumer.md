# RFC-MASC-005: Dashboard as OAS Eval Consumer

**Status**: Draft
**Date**: 2026-04-13
**Scope**: `lib/dashboard/`, `lib/server_dashboard_http.ml`
**One sentence**: MASC dashboard가 자체 eval store를 만들지 않고 OAS의 `raw_trace.ml`, `harness.ml`, `eval_baseline.ml` 결과를 read-only로 소비하여, keeper 실행 품질을 관측 가능하게 한다.

## Related Documents

- RFC-OAS-002 (OTel Metric Naming & Eval Feed Schema) — `oas.*` metric + swiss_verdict JSON schema. **이 RFC의 전제**.
- `lib/dashboard/dashboard_harness_health.ml` — 현재 harness health 집계 (evaluator stale 탐지)
- `lib/dashboard/dashboard_http_keeper_detail.ml` — keeper 상세 페이지 (trace_id 파싱 존재)
- `lib/dashboard/dashboard_http_keeper_metrics.ml` — keeper 24h 메트릭 버킷
- OAS `lib/raw_trace.ml` — JSONL trace format (v1, 6 record types)
- OAS `lib/harness.ml` — swiss_verdict, verdict
- OAS `lib/eval.ml` — run_metrics, metric_value
- OAS `docs/schemas/swiss-verdict.schema.json` (RFC-OAS-002에서 생성 예정)
- `feedback_tailwind-only-dashboard.md` — Tailwind utility만 사용
- `feedback_dashboard-observation-focus.md` — 설명 최소화, 핵심은 누가/어디서/뭘/왜
- `feedback_masc-oas-layer-boundary.md` — MASC는 추상 신호만, OAS가 raw 인프라 소유

## Problem Statement

### 현재 상태

MASC dashboard는 keeper 실행 메트릭(turn count, tool calls, duration)을 자체 수집하지만, **OAS 수준의 eval 메트릭은 전혀 표시하지 않는다**:

- Swiss cheese verdict (layer별 passed/failed, coverage)
- Eval baseline regression (Improved/Regressed/Unchanged)
- Raw trace 기반 tool 정확도, turn 효율성
- OTel metric 시계열

`dashboard_harness_health.ml`이 evaluator stale 탐지는 하지만, 실제 verdict 내용을 파싱하거나 표시하지 않는다.

### 왜 자체 eval store를 만들지 않는가

1. **MASC-OAS Layer Boundary** (`feedback_masc-oas-layer-boundary.md`): OAS가 eval 인프라를 소유. MASC가 eval store를 별도로 만들면 동기화 문제 + 이중 진실 원천.
2. **OAS가 이미 제공**: `raw_trace.ml` JSONL + `harness.ml` verdict + `eval.ml` run_metrics. Consumer가 파싱만 하면 된다.
3. **Dashboard observation focus** (`feedback_dashboard-observation-focus.md`): dashboard는 관찰 도구. 데이터 생성은 OAS 책임.

## Design

### Architecture: Read-Only Consumer

```
OAS (data producer)              MASC Dashboard (consumer)
─────────────────                ─────────────────────────
raw_trace.ml → JSONL files   →  dashboard reads JSONL
harness.ml → swiss_verdict   →  dashboard parses JSON schema
eval.ml → run_metrics        →  dashboard renders metrics
otel_tracer → oas.* metrics  →  dashboard queries OTel endpoint
```

MASC dashboard는 **읽기만** 한다. 쓰기/수정/변환은 하지 않는다.

### Part A: Eval Feed Reader Module

```ocaml
(* dashboard_eval_feed.ml — 신규 *)

type eval_snapshot = {
  agent_name: string;
  session_id: string option;
  worker_run_id: string;
  timestamp: float;
  verdict: swiss_verdict_json;    (** RFC-OAS-002 schema v1 *)
  coverage: float;
  baseline_status: string option; (** "Improved" | "Regressed" | "Unchanged" *)
}

val read_latest : base_path:string -> agent_name:string -> limit:int -> eval_snapshot list
(** OAS raw_trace JSONL + eval output 디렉토리에서 최근 N개 eval snapshot 읽기.
    파일 탐색 경로: <base_path>/.oas/traces/<agent_name>/*.jsonl
                    <base_path>/.oas/eval/<agent_name>/*.json *)

val read_verdict_json : Yojson.Safe.t -> (swiss_verdict_json, string) result
(** RFC-OAS-002 swiss-verdict.schema.json v1 파싱.
    schema_version != 1이면 Error. *)
```

### Part B: Dashboard HTTP Routes

`server_dashboard_http.ml`에 eval 관련 route 추가:

| Route | Method | Response |
|-------|--------|----------|
| `/api/v1/dashboard/eval/:agent_name` | GET | 최근 eval snapshot list (JSON) |
| `/api/v1/dashboard/eval/:agent_name/latest` | GET | 가장 최근 1건 |
| `/api/v1/dashboard/eval/:agent_name/trend` | GET | 최근 24h coverage trend |

모든 route는 read-only. 캐시: `dashboard_cache.ml`의 기존 캐시 인프라 활용 (TTL 60s).

### Part C: Dashboard UI (Tailwind-only)

Keeper detail 페이지에 eval 섹션 추가:

```
┌─── Eval Quality ──────────────────────────────────┐
│ Coverage: ████████░░ 0.82  [Improved ↑]           │
│                                                    │
│ Layer Results:                                     │
│  ✓ ToolSelected    0.95  "correct tool chosen"     │
│  ✓ CompletesWithin 1.00  "3/5 turns"              │
│  ✗ ContainsText    0.00  "missing expected output" │
│                                                    │
│ Trend (24h): 0.78 → 0.82 (+5.1%)                  │
└────────────────────────────────────────────────────┘
```

원칙:
- Tailwind utility만 사용 (`feedback_tailwind-only-dashboard.md`)
- 설명 최소화, 숫자 중심 (`feedback_dashboard-observation-focus.md`)
- 영한혼용 금지

### Part D: OTel Metric 시계열 (선택적)

RFC-OAS-002의 `oas.*` metric이 OTel endpoint에 emit되면, dashboard가 이를 쿼리하여 시계열 그래프를 렌더링할 수 있다. 단, OTel collector가 MASC 환경에 배포되어 있어야 함.

현재 MASC는 OTel collector를 내장하지 않으므로 이 기능은 **optional**:
- OTel endpoint 설정이 있으면 시계열 표시
- 없으면 JSONL 기반 snapshot만 표시

## Implementation Phases

### Phase 1: Eval Feed Reader (1 PR)
- `dashboard_eval_feed.ml` 생성
- Swiss verdict JSON 파서 (RFC-OAS-002 schema v1 기준)
- Unit test: 샘플 JSONL/JSON 파싱 검증

### Phase 2: HTTP Routes (1 PR)
- `/api/v1/dashboard/eval/:agent_name` 3개 route
- `dashboard_cache.ml` 통합
- Integration test: mock eval data → route 응답 검증

### Phase 3: Dashboard UI (1 PR)
- Keeper detail 페이지에 eval 섹션 추가
- Tailwind-only 렌더링
- Coverage trend 24h 그래프 (SVG inline 또는 CSS bar)

### Phase 4: OTel 시계열 (선택적, 1 PR)
- OTel endpoint 설정 탐지
- Metric query + 시계열 렌더링
- 설정 없으면 graceful skip

## Dependencies

| 의존 대상 | 상태 | 차단 여부 |
|-----------|------|----------|
| RFC-OAS-002 (swiss_verdict JSON schema) | Draft | Phase 1 차단: schema 확정 필요 |
| RFC-OAS-002 (OTel `oas.*` metric naming) | Draft | Phase 4 차단 (Phase 1-3은 비차단) |
| OAS raw_trace JSONL 경로 convention | 구현됨 | 비차단 |
| Issue #484 (Delta-Context Epic) | Open | 비차단 (checkpoint replay는 이 RFC 범위 밖) |

## Risks

| Risk | Mitigation |
|------|------------|
| OAS eval output 경로가 변경되면 dashboard 깨짐 | Path convention을 config로 외부화. 기본값은 `.oas/` 하위 |
| Swiss verdict schema v1이 빠르게 v2로 변경 | `schema_version` 필드 체크. v2 추가 시 v1 파서 유지 (하위호환) |
| Eval data가 없는 keeper (eval 미실행) | "No eval data" 표시. Empty state UI 처리 |
| JSONL 파일이 커서 읽기 느림 | `limit` 파라미터로 최근 N건만. tail -N 방식 읽기 |

## Scope Exclusion

- Eval data 생성/수정 (OAS 책임)
- OTel collector 배포 (인프라 별도)
- Eval 기반 자동 keeper 조정 (관측만, 제어 없음)
- Board/team-session eval 집계 (keeper 단위만)
- Swiss verdict 외 커스텀 eval format 지원
