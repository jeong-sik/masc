---
rfc: "0088"
title: "Prometheus metric ownership distribution"
status: Draft
authors:
  - jeong-sik (with Claude Opus 4.7)
created: 2026-05-15
related:
  - RFC-0056 (sub-library partition)
  - RFC-0086 (keeper namespace bulk promotion — Prometheus 가 6 cycle blocker 중 하나)
supersedes:
  - PR #14166 (closed by user as 회피형 split-by-shard)
---

# RFC-0088 — Prometheus metric ownership distribution

## 1. Problem

`lib/prometheus.ml` 가 3090 LoC / 221 unique `masc_*` metric name / 1067 caller fan-in 의 godfile.

| 구성 | LoC | 비고 |
|---|---|---|
| Core mechanism (types, registry, register/inc/set/observe primitives) | ~160 | 실제 로직 |
| Metric name 상수 (`let metric_X = "masc_..."`) — 173개 | ~2700 | 단순 string 정의 |
| 4 inline `register_histogram` 호출 (line 1293-1325) | ~30 | bootstrap metric |
| 잔존 (OCamldoc comment + spacing) | ~200 | doc |

**현재 패턴 분산도**:
- 209 caller가 `Prometheus.metric_X` named constant 참조
- 124 caller가 inline `"masc_..."` string 직접 사용
- 일부 도메인 (cascade_metrics, dashboard_governance_judge, keeper_stale_watchdog 등) 은 *이미* `Prometheus.register_*` 직접 호출 → **분산 패턴이 부분적으로 정착됨**

**왜 godfile 인가**: 메트릭 추가가 항상 `prometheus.ml` 의 두 곳 (constant 정의 + 가끔 register 호출) 을 수정해야 함. 도메인 모듈은 자기 메트릭을 *모름*. 결과:
1. RFC-0086 Phase 2.B (lib/keeper/ sub-library promotion) 의 6 cycle blocker 중 하나 — keeper_*.ml/mli 가 `Prometheus.metric_keeper_*` 참조
2. Merge conflict hotspot (병렬 RFC sprint 가 prometheus.ml 동시 수정)
3. AI 토큰 폭발 — 단순 metric 추가에도 3090 LoC 파일 전체 컨텍스트 필요

## 2. Non-goals

- **Split by shard** (named group cap, prometheus_shard_a.ml/shard_b.ml 등) — PR #14166 에서 사용자 명시 거부 ("이거 해결책이 너무 바보같음", memory `feedback_prometheus_extract_too_evasive`). Cosmetic split 이 anti-pattern, 도메인 소유권 불변.
- **Lint with hardcoded metric prefix list** — memory `feedback_lint_string_classifier_is_workaround_not_fundamental` 워크어라운드 거부 기준 #2 string 분류기 보강 해당.
- **단일 PR 일괄 이전** — 173 constant 동시 이동은 N-of-M 패치 위험 (거부 기준 #3), 도메인별 N PR 로 분할.
- **Inline `"masc_..."` literal 모두 제거** — 124 caller가 inline 사용. Phase 2 에서 *strict 한 도메인부터* 점진 정리, 강제 lint 도입 금지.

## 3. Design

### 3.1 Core mechanism 추출 (Phase 0)

`lib/prometheus.ml` 의 ~160 LoC core 를 `lib/prometheus_core/` sub-library 로 추출.

```dune
; lib/prometheus_core/dune
(include_subdirs no)
(library
 (name masc_mcp_prometheus_core)
 (public_name masc_mcp.prometheus_core)
 (wrapped false)
 (libraries))
```

`lib/prometheus_core/prometheus_core.ml(i)` API:

```ocaml
type metric_type = Counter | Gauge | Histogram
type metric = { (* ... *) }

(* Registry primitives — 도메인 모듈이 init 시 호출 *)
val register_counter   : name:string -> help:string -> ?labels:string list -> unit -> unit
val register_gauge     : name:string -> help:string -> ?labels:string list -> unit -> unit
val register_histogram : name:string -> help:string -> ?labels:string list -> unit -> unit

(* Update primitives *)
val inc_counter      : string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit
val set_gauge        : string -> ?labels:(string * string) list -> float -> unit
val inc_gauge        : string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit
val dec_gauge        : string -> ?labels:(string * string) list -> ?delta:float -> unit -> unit
val observe_histogram: string -> ?labels:(string * string) list -> float -> unit

(* Read primitives (Grafana/dashboard 호환) *)
val get_metric_value     : string -> ?labels:(string * string) list -> unit -> float option
val metric_value_or_zero : string -> ?labels:(string * string) list -> unit -> float
val metric_total         : string -> float
```

**왜 분리 가능 leaf**: core 는 stdlib `Hashtbl` + `Mutex` + `Atomic` 만 의존 — 0 parent 의존성. PR-0c host_config / PR-0f memory_jsonl 와 동급 precedent.

### 3.2 Metric ownership 분산 (Phase 1)

각 도메인 모듈이 자기 metric 을 *소유*. 구조:

```ocaml
(* lib/keeper/keeper_metrics.ml — new file *)
let after_turn_hook_total = "masc_after_turn_hook_total"
let after_turn_response_content_empty_total = "masc_after_turn_response_content_empty_total"
(* ... *)

let init () =
  Prometheus_core.register_counter
    ~name:after_turn_hook_total
    ~help:"Total after-turn hooks fired" ();
  Prometheus_core.register_counter
    ~name:after_turn_response_content_empty_total
    ~help:"After-turn hooks where response.content was empty" ();
  (* ... *)
```

호출자:

```ocaml
(* before *)
Prometheus.inc_counter Prometheus.metric_after_turn_hook_total ()

(* after *)
Prometheus_core.inc_counter Keeper_metrics.after_turn_hook_total ()
```

도메인 → metric prefix 매핑 (audit 결과, top 10):

| 도메인 | prefix | unique metrics | 대상 module |
|---|---|---|---|
| llm/inference | `masc_llm_*` + `masc_inference_*` | 26 | lib/inference_metrics.ml (신규) |
| sse | `masc_sse_*` | 16 | lib/server/server_mcp_transport_http_sse.ml |
| oas | `masc_oas_*` | 16 | lib/keeper/keeper_hooks_oas.ml or 신규 |
| keeper | `masc_keeper_*` + `masc_after_*` | 22 | lib/keeper/keeper_metrics.ml (신규) |
| ws | `masc_ws_*` | 13 | lib/server/server_websocket_metrics.ml |
| cascade | `masc_cascade_*` | 13 | lib/cascade/cascade_metrics.ml (이미 존재, 일부 metric 통합) |
| auth | `masc_auth_*` | 11 | lib/repo_manager/auth_metrics.ml (신규) |
| grpc | `masc_grpc_*` | 8 | lib/grpc-direct/ 또는 신규 |
| tool | `masc_tool_*` | 7 | lib/tool_telemetry.ml (이미 존재, 통합) |
| 나머지 ~20 prefix | 다양 | 89 | 각 도메인 module |

### 3.3 lib/prometheus.ml 잔존 → shrink (Phase 2)

Phase 1 PR 들이 모든 173 constant 를 옮기면 `lib/prometheus.ml` 는:
- 0 metric name constant
- Re-export `Prometheus_core` 의 API (backward compat, 1 PR 동안만)
- 또는 완전 deletion (Phase 3)

각 caller `Prometheus.inc_counter X` → `Prometheus_core.inc_counter X` rename (수천 caller). 이 caller migration 은 **Phase 1 PR 머지 *마다* 함께** 진행 (해당 도메인 metric 의 callers 만) — N-of-M 패치 회피.

### 3.4 Inline `"masc_..."` literal callers (Phase 2)

124 inline literal 사용처는 *해당 도메인 module 머지될 때* 같은 PR 에서 `Domain_metrics.X` named constant 로 sed. lint 강제 안 함.

## 4. Sequencing

```
Phase 0: lib/prometheus_core/ 추출 (RFC + 1 PR)
  ├─ docs/rfc/RFC-0088 (이 PR)
  └─ feat(prometheus_core): extract core mechanism to sub-library

Phase 1: domain metric ownership 분산 (~10 PR, prefix 별 1-3개씩 묶음)
  ├─ feat(keeper_metrics): own keeper/after_turn metrics (22)
  ├─ feat(sse_metrics): own sse metrics (16)
  ├─ feat(oas_metrics): own oas metrics (16)
  ├─ feat(inference_metrics): own llm/inference metrics (26)
  ├─ feat(ws_metrics): own ws metrics (13)
  ├─ feat(cascade_metrics): consolidate cascade metrics (13)
  ├─ feat(auth_metrics): own auth metrics (11)
  ├─ feat(grpc_metrics): own grpc metrics (8)
  ├─ feat(tool_metrics): consolidate tool metrics (7)
  └─ feat(misc_metrics): 나머지 ~20 prefix 통합 (89)

Phase 2: prometheus.ml shrink + delete (1 PR)
  └─ refactor(prometheus): delete legacy compat, remove file
```

Phase 1 PR 들은 **병렬 가능** (서로 disjoint metric set + disjoint caller set). 단 `lib/prometheus.ml` 동시 편집 직렬화 필요 (constant block delete).

## 5. Verification gates

각 Phase 1 PR 단위 (RFC-0056 G1-G5 + 본 RFC 추가):

- **G-088-A**: 옮긴 metric 수 = PR description 명시 수 (compile-time check via grep)
- **G-088-B**: lib/prometheus.ml 의 `let metric_X = "masc_..."` line count 감소 (`grep -c '^let metric_' lib/prometheus.ml`)
- **G-088-C**: 해당 도메인의 caller 들이 named constant 사용 (inline literal 0건 — sed 검증)
- **G-088-D**: `Domain_metrics.init ()` 가 `main_eio.ml` boot path 에서 호출됨 (callgraph check)
- **G-088-E**: `dune build @check && dune runtest` green

## 6. Risks

| 위험 | 확률 | 영향 | 완화 |
|---|---|---|---|
| 도메인 → prefix 매핑이 일부 모호 (`masc_silent_*`, `masc_persistence_*` 등) | 중 | 저 (PR scope 조정) | Phase 1 PR 시작 시 매 prefix 직접 caller 추적 |
| 모듈 init 순서 의존성 — 도메인 metric 이 register 되기 전에 inc_counter 호출 시 silent miss | 낮 | 중 | `Prometheus_core.register_*` 가 idempotent + `init ()` 가 main_eio.ml boot path 첫 단계 |
| 124 inline literal caller 중 일부가 도메인 외부 module 에 살아있음 (cross-domain reference) | 중 | 중 | 각 Phase 1 PR 의 caller migration 에서 발견 즉시 그 PR scope 확장 |
| Phase 1 PR 들이 `lib/prometheus.ml` 동시 편집 → merge conflict 빈발 | 높 | 저 (resolve 단순) | 도메인 별 PR 직렬화 (1주 1 PR 페이스) |
| split-by-shard anti-pattern 재발 (예: 각 PR 이 prometheus_keeper.ml 같은 dummy file 생성) | 낮 | 고 | 본 RFC §2 명시 거부 + reviewer 워크어라운드-bar 7항목 self-check |

## 7. Done definition

본 RFC 는 다음 모두 만족 시 완료:

1. RFC-0088 status → `Active` (Phase 0 머지) → 종료 시 `Implemented`.
2. `lib/prometheus.ml` 파일 완전 삭제 (Phase 2 종료).
3. `wc -l lib/prometheus_core/prometheus_core.ml` ≤ 250 (Phase 0 종료 시).
4. `find lib bin -name '*.ml' | xargs grep -l '"masc_[a-z_]*"' | wc -l` = Phase 1 시작 시점의 1/10 이하 (대부분 named constant 사용).
5. `dune build @check` exit 0 + `dune runtest` exit 0 on main.
6. **RFC-0086 Phase 2.B (PR-2E) re-entry** — Prometheus 가 더 이상 cycle blocker 아님 확인.

## 8. Reference

- MEMORY `feedback_prometheus_extract_too_evasive` — split-by-shard anti-pattern 거부
- MEMORY `feedback_lint_string_classifier_is_workaround_not_fundamental` — string lint 거부
- MEMORY `feedback_hardcoding_and_legacy_zero_tolerance` — legacy 같은 PR 에서 박멸
- PR #14166 — closed split-by-shard 시도 (이 RFC 의 supersedes 대상)
- RFC-0086 — keeper namespace bulk promotion (이 RFC 의 unblock 대상)
- RFC-0056 — sub-library partition (PR-0c host_config / PR-0f memory_jsonl precedent)
- plan §8.14 — PR-2E cycle blocker audit (Prometheus 가 6 중 하나)
- plan §8.16 — 4 remaining blocker architectural decision 표
