# RFC-0043: Distribute Prometheus metric ownership to domain modules

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-05-08
- **Number**: jeong-sik/masc-mcp 의 RFC 번호는 PR Draft 시점 점유. 본 RFC `0043`
  잠정. PR #13918 (RFC-0039), PR #14157 (RFC-0041), PR #14181 (RFC-0042) 동시
  Draft 점유 중. maintainer 가 머지 시점 재배정 가능.
- **Related**:
  - PR #14166 (CLOSED, **user-rejected**, "refactor(prometheus): extract 365
    metric-name constants into 3 sub-modules") — 본 RFC 가 대체하는 회피형 fix
  - 사용자 코멘트: "이거 해결책이 너무 바보같음" (PR #14166 closure)
  - PR #14049, #14112, #14107, #14143, #14147, #13990 — 최근 telemetry-add PR
    들이 5-15 LOC 씩 metric 상수 누적, godfile cap 돌파 트리거
  - `instructions/MANIFEST.md`: "당장의 진행을 위해 잠시 회피하는 식으로 작업하기보다
    근본적으로 해결이 필요"
- **Drives**: Eliminate `lib/prometheus.ml` 의 godfile size cap 위반을 *file split*
  으로 회피하는 대신 **metric ownership 을 도메인 모듈로 분산**하여 godfile 자연
  해소 + 신규 telemetry 추가 마찰 제거.

## 1. Problem

### 1.1 Symptom — godfile gate가 모든 PR을 block

`lib/prometheus.ml` = **3059 LOC** (limit 3000). `Godfile size` CI gate 가
모든 open PR 에 fail 시그널을 매달고 있어 머지 마찰 누적.

최근 1-2주의 ratchet:

| PR | Date | Δ LOC | 누적 LOC |
|----|------|-------|----------|
| #14049 | 2026-05-04 | +9 | 2992 |
| #14112 | 2026-05-04 | +7 | 2999 |
| #14107 | 2026-05-05 | +9 | 3008 ← cap crossed |
| #14143 | 2026-05-06 | +5 | 3013 |
| #14147 | 2026-05-06 | +3 | 3016 |
| #13990 | 2026-05-06 | +43 | 3059 (HEAD) |

각 PR 은 자신의 telemetry 추가가 정당하나, *공통 file 에 누적* 되는 구조 자체가
ratchet 을 만든다. 도메인 owner (keeper, sse, oas, ...) 가 자기 metric 을 자기
파일에 두면 ratchet 자체가 사라진다.

### 1.2 Why PR #14166 가 closed (user-rejected)

PR #14166 은 365 metric-name 상수를 3 sub-module 로 split + re-export 으로
3016 → 188 LOC 압축 시도. 사용자가 명시 거부:

> "이거 해결책이 너무 바보같음"

본질적 비판: **metric 소유권은 그대로, 파일 이름만 분산**. central registry
패턴 유지. 새 telemetry PR 이 다시 sub-module 중 하나에 LOC 추가 → 같은 cap 을
sub-module 단위로 다시 만나게 됨. *문제 위치가 옮겨질 뿐 사라지지 않음*.

### 1.3 Root cause — central registry anti-pattern

```
lib/prometheus.ml:
  let metric_keeper_turn_total : metric_name = ...
  let metric_keeper_turn_failed : metric_name = ...
  let metric_keeper_receipt_unmapped_disposition : metric_name = ...
  ... (372 metric_* 상수)

  let inc_counter ~name ?labels () = ...
  let register_counter ~name ~help ?labels () = ...
  ...

lib/keeper/keeper_unified_turn.ml:
  Prometheus.inc_counter ~name:Prometheus.metric_keeper_turn_total ...

lib/keeper/keeper_execution_receipt.ml:
  Prometheus.inc_counter ~name:Prometheus.metric_keeper_receipt_unmapped_disposition ...
```

도메인 모듈 (`lib/keeper/*`) 이 자기 metric 의 *consumer* 이지만 *owner* 가 아니다.
새 metric 추가 = 도메인 코드 수정 + `lib/prometheus.ml` 수정 (cross-file).
Owner 분산이 안 되어 있어 다음 두 비용이 영구 발생:

1. **godfile ratchet** — 새 telemetry 마다 `lib/prometheus.ml` 비대화
2. **변경 marshal 비용** — 도메인 PR 이 prometheus.ml 까지 건드려야 → conflict
   확률 증가, review surface 분산

## 2. Goals & non-goals

### Goals

| # | Goal |
|---|------|
| G1 | 도메인 모듈 (keeper / sse / oas / ws / cascade / ...) 이 자기 metric 을 자기 파일에 정의 |
| G2 | `lib/prometheus.ml` 은 *runtime registry* + *wire format* (collect / expose) 만 |
| G3 | godfile cap 위반 자연 해소 (3059 → 예상 ~600 LOC) |
| G4 | 신규 telemetry 추가 시 도메인 모듈 single-file 변경으로 완료 |
| G5 | `/metrics` HTTP endpoint 의 wire output 변경 0 |

### Non-goals

| # | Non-goal |
|---|---------|
| NG1 | metric 이름 변경 (label 호환성 유지) |
| NG2 | Prometheus client library 교체 (현재 구현 유지) |
| NG3 | metric 정의를 자동 생성하는 framework 도입 (over-engineering) |
| NG4 | godfile cap 정책 자체 수정 (`scripts/lint/godfile-size-regression.sh` 그대로) |

## 3. Design

### 3.1 도메인 분포 (오늘 측정, prefix 기준)

```
keeper:    187 metrics (50.3%)
sse:        16
oas:        15
llm:        15
ws:         12
cascade:     9
grpc:        8
inference:   7
tool:        6
gc:          6
auth:        6
provider:    4
memory:      4
dashboard:   4
coord:       4
telemetry:   3
mcp:         3
http:        3
cache:       3
... (lower)
```

`keeper_*` 단독으로 절반 — `lib/keeper/keeper_metrics.ml` 신설이 가장 큰 단일
이전. 나머지 도메인은 5-15 metric 단위라 작음.

### 3.2 새 모듈 패턴

```ocaml
(* lib/keeper/keeper_metrics.mli *)
val metric_turn_total              : Prometheus.metric_name
val metric_turn_failed             : Prometheus.metric_name
val metric_receipt_unmapped_disposition : Prometheus.metric_name
... (187개)

val register_all : unit -> unit
(** Idempotent. Called once during keeper subsystem init. *)
```

```ocaml
(* lib/keeper/keeper_metrics.ml *)
let metric_turn_total =
  Prometheus.metric_name_unsafe "masc_keeper_turn_total"
let metric_turn_failed =
  Prometheus.metric_name_unsafe "masc_keeper_turn_failed"
...

let register_all () =
  Prometheus.register_counter
    ~name:metric_turn_total
    ~help:"Total keeper turns initiated"
    ~labels:["keeper"; "cascade"]
    ();
  ...
```

### 3.3 prometheus.ml 잔여 contents

이전 후 `lib/prometheus.ml` 에 남는 것:

| 구성 | 예상 LOC |
|------|---------|
| `metric_name` abstract type + smart constructor | ~30 |
| `register_counter / register_gauge / register_histogram` | ~150 |
| `inc_counter / set_gauge / observe` runtime API | ~100 |
| Collect / Wire format (`/metrics` endpoint) | ~250 |
| Bucket sets (default histogram buckets) | ~40 |
| **합계** | **~570** |

godfile cap 3000 대비 큰 여유.

### 3.4 호환성

- `Prometheus.metric_keeper_turn_total` 같은 직접 reference 가 **372 emit
  site** 에 산재. 일괄 변경 = `Keeper_metrics.metric_turn_total` 등으로
  rename. `sed` 가능한 mechanical refactor.
- alias 단계 (PR-N): `lib/prometheus.ml` 에 `let metric_keeper_turn_total =
  Keeper_metrics.metric_turn_total` 같은 thin re-export 한 release 동안 유지
  → 모든 caller 마이그 후 alias 제거.

### 3.5 Init 순서

`Prometheus.register_all_metrics ()` 같은 단일 entry 가 main_eio.ml 에서 1회
호출되도록 정리. 각 도메인 모듈의 `register_all` 을 collect.

```ocaml
(* lib/prometheus_init.ml *)
let register_all_metrics () =
  Keeper_metrics.register_all ();
  Sse_metrics.register_all ();
  Oas_metrics.register_all ();
  ...
```

## 4. Migration plan (5 PRs)

| PR | Title | Files (estimate) | LOC delta | Compile-clean? |
|----|-------|------------------|-----------|----------------|
| **PR-1** | introduce empty domain modules + `register_all` no-op | ~10 신규 | +200 | ✅ |
| **PR-2** | move 187 `metric_keeper_*` 상수 to `Keeper_metrics`; `Prometheus` 에 alias 유지 | 1 (prometheus.ml 큰 감소) + 1 신규 + N (call site는 alias 사용) | -1500 / +700 (net -800) | ✅ |
| **PR-3** | move sse/oas/llm/ws/cascade (~70 metrics) to 5 domain modules; alias 유지 | 5 신규 + 1 prometheus.ml | -300 / +300 (net 0, but prometheus.ml -300) | ✅ |
| **PR-4** | move 나머지 (~115 metrics) | 10+ 신규 + 1 prometheus.ml | -700 / +500 | ✅ |
| **PR-5** | call site 마이그 (Prometheus alias → 도메인 module 직접) + alias 제거 | ~50 caller files + 1 prometheus.ml | net 0, alias drop | ✅ |

PR-2 만에 godfile cap 자연 해소 (3059 → ~1500). 나머지 PR 은 *cleanup*.

### 4.1 Test plan

- **PR-1**: `register_all` no-op 호출 후 metric registry empty 확인 (golden test)
- **PR-2**: `/metrics` endpoint output diff = 0 (PR 전후 byte-equal)
- **PR-3, PR-4**: 동일 (`/metrics` byte-equal 유지)
- **PR-5**: caller 마이그 후 build clean + `/metrics` byte-equal

`/metrics` byte-equal 보장 수단:
1. `bin/cdal_label.ml` 또는 별도 test 가 `/metrics` 를 호출, sorted output dump
2. PR 전후 dump diff 0

## 5. Trade-offs & open questions

### 5.1 Init time 변화

도메인 모듈 `register_all` 가 lazy 가 아니라 main_eio.ml 에서 명시 호출이라면
init 비용 분산. 현재 prometheus.ml 의 register 는 *file load 시점 side effect*
인지 (`let _ = register_counter ...`) 또는 *명시 호출* 인지 확인 필요 — PR-1
시작 전 `rg 'let _ = register' lib/prometheus.ml` 로 측정.

### 5.2 Cyclic dependency 위험

도메인 모듈이 `Prometheus` 를 의존하는 건 OK (leaf). 그러나 `Keeper_metrics`
가 `Keeper_unified_turn` 같은 도메인 코드를 의존하면 cycle. 따라서
`*_metrics.ml` 은 *metric name 상수 + register* 만, 도메인 로직 reference 0.

### 5.3 Metric 이름 prefix

현재 `masc_keeper_*` / `masc_sse_*` 형태 wire prefix 유지. 도메인 module 분리는
*OCaml namespacing* 만, wire 영향 0.

### 5.4 Telemetry 가 새 도메인을 가지면

새 도메인 (예: `audit`) 등장 시 `lib/audit/audit_metrics.ml` 신설 +
`Prometheus_init.register_all_metrics` 에 한 줄 추가. 새 도메인 첫 telemetry 가
자연스럽게 분산 module 만들도록 강제됨 (godfile cap 도 사실상 무관).

## 6. Decision

본 RFC 는 Draft. **PR-1 (empty 도메인 모듈 + no-op register_all)** 은 caller 0,
영향 0 이라 RFC 머지 전 독립 진행 가능. 단 PR-2 onwards 시작 전 다음 confirm
필요:

1. `lib/prometheus.ml` 의 register 가 init time side effect 인지 명시 호출인지
   (§5.1)
2. 187 `metric_keeper_*` 의 ownership 이 keeper subsystem 단일 인지 (cross-domain
   metric 없는지) — PR-2 base 에서 final 측정

## 7. References

- `lib/prometheus.ml` (3059 LOC, godfile cap 3000 위반)
- `scripts/lint/godfile-size-regression.sh` (gate 정의)
- PR #14166 closed (user-rejected file-split workaround)
- PR #14049, #14112, #14107, #14143, #14147, #13990 (telemetry ratchet)
- `instructions/MANIFEST.md` (회피형 fix 금지 원칙)
