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

### 3.1 도메인 분포 — 두 축 측정 (2026-05-08, base `7aa64dbc0e`)

#### A. Definition site (`lib/prometheus.ml` 의 `let metric_<domain>_*` 상수)

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

#### B. Use site (`Prometheus.metric_<domain>_*` reference, 다른 모듈에서)

`rg -o 'Prometheus\.metric_[a-z_]+' lib/ -t ml | sed 's/Prometheus\.metric_//' | awk -F_ '{print $1}' | sort | uniq -c | sort -rn`:

```
keeper:    480 references  (in lib/keeper/)
transport:  68
dashboard:  65 + 67 (lib/dashboard.ml + lib/dashboard/)
server:     24
cascade:    16
llm:        13
tool:       12
oas:        11
... (lower)

총 use site:  772 references across 140 files
inc_counter call sites: 449
```

**Definition (372) ↔ Use (772) 비율 ≈ 1:2** — 각 metric 평균 2 곳에서 사용. 마이그
범위는 *use site 까지*: caller 변경 (PR-5) 이 정의 이전 (PR-2~4) 보다 LOC 변경량
큼. RFC §4 의 PR-5 LOC 추정 정정 필요 (§4 표 참조).

`keeper_*` 단독으로 정의의 절반, use 의 60%. `lib/keeper/keeper_metrics.ml` 신설이
가장 큰 단일 이전. 나머지 도메인은 5-15 metric 단위라 작음.

### 3.2 새 모듈 패턴

현재 `lib/prometheus.ml` 의 metric 상수는 plain `string` (예:
`let metric_keeper_turns = "masc_keeper_turns_total"`) — smart constructor /
abstract `metric_name` 타입 없음. 본 RFC 는 그 패턴을 그대로 유지하고 *위치만*
이전한다.

```ocaml
(* lib/keeper/keeper_metrics.mli *)
val metric_turn_total : string
val metric_turn_failed : string
val metric_receipt_unmapped_disposition : string
(* ... 187개 *)

val register_all : unit -> unit
(** Idempotent. Called once during keeper subsystem init. *)
```

```ocaml
(* lib/keeper/keeper_metrics.ml *)
let metric_turn_total = "masc_keeper_turn_total"
let metric_turn_failed = "masc_keeper_turn_failed"
(* ... *)

let register_all () =
  Prometheus.register_counter
    ~name:metric_turn_total
    ~help:"Total keeper turns initiated"
    ~labels:[("keeper", ""); ("cascade", "")]
    ();
  (* ... *)
;;
```

**API 매개변수 정합성** (실제 [`lib/prometheus.mli`](../../lib/prometheus.mli) 시그니처 기준):

| API | 시그니처 |
|-----|---------|
| `register_counter` | `~name:string -> ~help:string -> ?labels:label list -> unit -> unit` |
| `inc_counter`      | `~name:string -> ?labels -> unit -> unit` |
| `label`            | `string * string` |

본 RFC 는 새 abstract 타입 (예: `metric_name`) 을 *도입하지 않는다*. 그건
별도의 type-discipline RFC 후보 — 본 RFC 의 scope 는 *소유권 이전* 만.

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

| PR | Title | Files | LOC delta (추정 vs 측정) | godfile? |
|----|-------|-------|--------------------------|----------|
| **PR-1** | introduce empty domain modules + `register_all` no-op | ~10 신규 (.ml/.mli pair × 5 도메인) | +200 (추정, 빈 모듈) | – |
| **PR-2** | 187 `metric_keeper_*` 상수 → `Keeper_metrics`; `Prometheus` 에 alias 유지 | 1 prometheus.ml (-) + 1 신규 (+) | prometheus.ml: 187 const × ~3 LOC 평균 = ~-560 *측정 base*; new module: ~600; alias: ~190 → net new module ~+800, prometheus net ~-560+190(alias)=−370 | ✅ **3059 → ~2700, cap 통과** |
| **PR-3** | sse/oas/llm/ws/cascade (~70 metrics) → 5 도메인 모듈; alias 유지 | 5 신규 + 1 prometheus.ml | prometheus.ml: −210; new modules: +210; alias: +70 | – |
| **PR-4** | 나머지 (~115 metrics) | 10+ 신규 + 1 prometheus.ml | prometheus.ml: −345; new modules: +345; alias: +115 | – |
| **PR-5** | call site 마이그 (`Prometheus.metric_*` → `<Domain>_metrics.metric_*`) + alias 제거 | **140 caller files (use site 측정)** + 1 prometheus.ml | use site rename ~772; prometheus alias drop ~−372 | – |

**LOC 추정 근거**:
- prometheus.ml 내 metric 상수 영역 line 211-1429 (~1218 LOC, RFC body §1.2 의
  PR #14166 본문 인용) ÷ 365 상수 ≈ 평균 3.3 LOC/const (주석 포함).
- PR-5 caller 변경량은 use site 770+ × 1줄 sed = ~770 LOC 변경. 실제 수치는
  PR-5 시작 전 `git diff --stat` 시뮬레이션으로 재측정 필요.

**자연 해소 시점**: PR-2 시점에 prometheus.ml 약 −370 LOC → 3059 → ~2690.
godfile cap (3000) 은 PR-2 단독으로 통과. PR-3/4 가 추가로 prometheus.ml 을
−555 더 줄여서 최종 ~2135 LOC 예상. 모든 추정은 *기대치*; PR-2 base에서
재측정 필요.

### 4.1 Test plan

- **PR-1**: `register_all` no-op 호출 후 metric registry size 변화 0 (golden
  test). 빈 모듈만 도입.
- **PR-2**: `/metrics` HTTP endpoint output **byte-for-byte stable** (PR 전후
  diff 0).
- **PR-3, PR-4**: 동일 (`/metrics` byte-equal 유지).
- **PR-5**: caller 마이그 후 build clean + `/metrics` byte-equal.

#### `/metrics` byte-equal 검증 수단

1. **현재 collect 함수**: `lib/prometheus.ml` 의 collect/expose API
   (`get_metric_value`, `metric_value_or_zero`, `metric_total`)
   가 출력하는 wire format. Prometheus exposition format 표준 (도메인 sort,
   label sort) 을 자체 구현하는지, 아니면 Prometheus client lib 위임인지는
   PR-2 전 측정 필요 (`rg 'expose|/metrics' lib/prometheus.ml lib/server/`).
2. **기준 dump**: PR-2 base 에서 서버 부팅 → `curl /metrics > before.txt`,
   sort label keys, save.
3. **diff 검증**: PR-2 변경 후 동일 절차 → `diff before.txt after.txt` 가
   비어있어야 함.
4. **포맷 안정**: label key 가 `HashMap` 순서로 emit 되면 byte-equal 못 잡음.
   PR-2 시작 전 emit 순서가 결정적인지 확인 (소스 코드 또는 client lib spec).
   non-deterministic 이면 *sorted-label diff* 로 완화.

## 5. Trade-offs & open questions

### 5.1 Init time 변화

도메인 모듈 `register_all` 가 lazy 가 아니라 main_eio.ml 에서 명시 호출이라면
init 비용 분산. 현재 prometheus.ml 의 register 는 *file load 시점 side effect*
인지 (`let _ = register_counter ...`) 또는 *명시 호출* 인지 확인 필요 — PR-1
시작 전 `rg 'let _ = register' lib/prometheus.ml` 로 측정.

### 5.2 Cyclic dependency 위험

의존성 방향:

```
<Domain>_metrics.ml  →  Prometheus  (leaf)
<Domain> 도메인 코드 (예: keeper_unified_turn)
   ─→ <Domain>_metrics  (use site, 새 경로)
   ─→ Prometheus        (inc_counter, 변경 X)
```

**검증해야 할 것**: `<Domain>_metrics.ml` 이 register 시점에 도메인 코드
reference 가 *전혀 없어야* leaf 유지. 본 RFC 는 `<Domain>_metrics.ml` 의
contents 를 `(상수 정의) + (register_counter / register_gauge / register_histogram
호출)` 두 가지로 한정. 도메인 코드 import 0.

label value (예: keeper 이름) 는 *register 시점이 아니라 inc 시점* 에 주입되므로
register_all 가 도메인 의존하지 않음. 이 invariant 는 PR-2 시작 전
`rg '\bopen Keeper_' new_keeper_metrics.ml` = 0 등으로 검증.

`lib/dune` 의 `include_subdirs unqualified` 와 단일 `masc_mcp` library 구조 덕에
sub-library 분리도 불필요. 모듈 간 import 만 검증.

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
