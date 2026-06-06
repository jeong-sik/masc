# RFC-0217: Telemetry Backend Otel 단일화 (Retired Backend Purge)

| | |
|---|---|
| **Status** | Accepted / implemented through PR #20189 |
| **Author** | Claude Opus 4.8 |
| **Date** | 2026-06-04 |
| **Supersedes** | RFC-0214 §4.3 Phase C + §7 (legacy metric 이름 변경) — genai dual을 전체 single로 일반화 |
| **Related** | RFC-0043 (metric-ownership), RFC-0049 (surface-telemetry), RFC-0215 (sublib campaign LANE 3 telemetry) |

## 1. Problem

RFC-0214가 genai 텔레메트리(`masc_llm_provider_*` 13개)를 OTel GenAI semconv로 **dual emission**(retired metrics backend + Otel 동시)으로 시작했다. dual의 근거는 *"기존 scrape 대시보드/alert 무중단, retired backend remains primary"*였다. 그러나:

1. **dual의 전제(다수 소비자 호환)가 성립하지 않는다.** scrape 소비처는 운영자 **본인 1명**(Grafana 대시보드 8개 + alert rules). dual(둘 다 emit)의 "기존 대시보드 무중단" 가치가, 소비자가 본인뿐이라 "내 datasource 한 줄 바꾸기"로 축소된다. dual은 비용(이중 emit 경로 유지)만 남고 이득이 사라진다.
2. **retired metrics backend가 mega-lib 경계 오염원이다.** telemetry 도메인 추출(RFC-0215 LANE 3 `masc_telemetry`)의 지배 블로커였다. 이를 untangle하는 것보다 **제거**가 근본 — 엉킴이 *소멸*한다.
3. **전체 metric call sites가 retired backend 전용이었다.** RFC-0214는 genai 13개만 dual. 나머지(keeper/tool/board/runtime metrics)는 legacy backend only 였다.

초기 측정 (2026-06-04): legacy backend 호출 **1008곳 / 226 파일 / metric 정의 75개 / 21 모듈 / infra(grafana+alert) 8 파일**. 구현 완료 후 active code 에서는 `scripts/lint/no-retired-metrics-backend.sh` 가 재도입을 막는다.

## 2. Decision

**dual emission(RFC-0214)을 Otel 단일화로 수렴하고 retired backend를 제거한다.** RFC-0214가 "dual = transitional, legacy backend primary"라 했으나, 단일 소비자 환경에서 dual의 정당성이 없으므로 end-state를 **Otel only**로 확정한다. 이는 RFC-0214의 부정이 아니라 그 Phase C(deprecation)의 완성이다.

## 3. 모델 차이 (load-bearing)

| | Retired backend | Otel |
|---|---|---|
| 모델 | **pull** (scrape) | **push** (OTLP) |
| 누적 | in-process counter 누적 → retired scrape renderer | data point + `send_metrics`, 또는 observable callback |
| API | `inc_counter name ~labels ()` (동기 증분) | `Metrics.sum/gauge/histogram` (배치) + `Metrics_callbacks` (observable) |

1008개 `inc_counter`는 **동기 in-process 누적**이다. Otel로 옮기는 것은 단순 치환이 아니라 누적 상태를 유지하고 OTLP push 시점에 보고하는 **semantic re-platform**이다. 이 모델 차이가 본 RFC가 codemod가 아니라 설계인 이유다.

## 4. Decisions

### 4.1 누적 semantics (load-bearing)

`inc_counter`(1008×)의 Otel 매핑:

- **(권장) Atomic accumulator + `Metrics_callbacks` observable.** retired backend의 in-process 누적 의미를 보존: counter는 `Atomic.t`로 누적, OTLP export 주기마다 `Metrics_callbacks`가 현재값을 보고. pull→push 전환에서 monotonic 누적 의미가 동일하게 유지된다. 기존 "in-process 누적 → scrape 시점 읽기"를 "in-process 누적 → export 시점 callback"으로 1:1 대응.
- (대안) push-per-inc: 매 inc마다 data point emit. 고빈도 metric(token usage 등)에 OTLP 부하 + 집계 책임이 collector로. **비권장.**

확정: §6 spike로 검증.

### 4.2 Metric text → OTLP topology

소비처 = 운영자 본인 (Grafana 대시보드 8개 + alert rules + metric text endpoint). 전환 옵션:

- **(A)** Otel → OTLP → collector/exporter → Grafana. Grafana datasource/대시보드/alert 변경을 최소화한다.
- **(B)** Otel → OTLP → Otel-native backend, Grafana OTLP datasource. 대시보드 query 재작성 필요.

본인 소유라 둘 다 가벼운 결정. **(A) 권장** (대시보드/alert 보존, collector 한 개 운영).

### 4.3 마이그레이션 메커니즘 vs end-state

- **메커니즘 (shim-first).** Legacy facade를 Otel-backed로 교체: `inc_counter`/`register_counter`/`observe`가 내부에서 `Otel_metrics`를 호출. call site **무편집**으로 backend만 Otel로 전환. PR-S3 `set_span_wrapper`와 동형 (facade 이름 유지, 구현 교체). 이 단계에서 backend 내부 엉킴이 제거된다.
- **end-state (purge).** shim 후 call site를 `Otel_metrics.X`로 점진 전환하고 legacy facade 이름을 제거. **완료 기준: active code 에 legacy backend 명칭 0건.**
- shim은 CLAUDE.md가 금지하는 영구 symptom-suppression 워크어라운드가 **아니다** — removal target이 명시된 마이그레이션 단계다(그 bar는 *대체 없는 영구* 증상 억제용). shim 자체가 모델 gap(pull→push) 때문에 non-trivial하므로 본 RFC의 설계 대상이다.

### 4.4 Rollback

각 단계 PR은 격리 빌드 + `@check` green을 통과한다. Otel export 실패는 metric 손실이지 데이터 손실이 아니다 — JSONL이 durable truth로 유지(RFC-0214 §7). shim 단계(S2)는 legacy facade 이름 유지라 call site rollback 불필요(구현만 되돌림). topology 전환(S3)은 collector 롤백(datasource 되돌림). purge(S4)는 비가역이므로 S2/S3 안정화 확인 후 진입.

## 5. Staging

| 단계 | 범위 | 검증 |
|---|---|---|
| **S0 spike** | 1 counter Atomic → observable → OTLP 도달 (throwaway, site #1 아님) | OTLP 인코딩/전송 확인 |
| **S1 인프라** | `lib/otel/otel_metrics.ml` (`Metrics.sum/gauge/histogram` + Atomic accumulator + `Metrics_callbacks`). `lib/otel/dune` 신설(`masc_otel` leaf) | green island |
| **S2 shim** | legacy facade → Otel-backed. backend 엉킴 제거. call site 무편집 | `@check`, metric 값 일치(shim 전후 동일) |
| **S3 collector** | OTLP collector, Grafana datasource/alert 전환 (본인) | 대시보드 live |
| **S4 purge** | call site → `Otel_metrics.X`, legacy backend modules 제거 | `scripts/lint/no-retired-metrics-backend.sh` green |
| **S5 LANE 3** | telemetry 도메인(`tool_telemetry`/`tool_assignment_telemetry`/`tool_metrics_persist` + `lib/otel/` + `telemetry_unified`) → `masc_telemetry` leaf | RFC-0056 G1 |

S2가 backend를 다 바꾸는 핵심 단계(엉킴 소멸). S4가 이름 숙청. S5가 LANE 3 telemetry 도메인 추출 — S2로 legacy backend 엉킴이 사라져 untangle 없이 가능.

## 6. Spike (pre-implementation de-risk)

S1 전에 throwaway spike로 push 모델을 검증한다: 단일 counter를 `Atomic.t` 누적 → `Metrics_callbacks` observable 등록 → `Opentelemetry.Metrics.sum` → `send_metrics`(OTLP). collector 부재 시 인코딩+전송 시도까지 확인. 목적은 §4.1 누적 semantics 확정. **명시적 throwaway** — 1008의 site #1이 아니라 버리는 검증 코드.

**검증 완료 (2026-06-04).** `bin/otel_spike/`(opentelemetry-only, masc 무관 → broken-main 격리). `Atomic.fetch_and_add` accumulator + `Metrics_callbacks.register` observable + cumulative-monotonic `Metrics.sum` + `Metrics.emit` 가 `dune build` 통과 및 실행(`accumulated=7`). §4.1 권장(Atomic accumulator + observable callback으로 pull metric 의미 보존)이 API 레벨에서 실증. spike는 검증 후 삭제 — S1 `otel_metrics.ml`이 이 패턴을 labels 지원 형태로 일반화한다.

## 7. Non-Goals

- JSONL durable 제거 (RFC-0214 §7 유지 — JSONL = durable truth, Otel = export 경로).
- OTel Logs 통합 (별도).
- semconv 매핑 정합(genai 외 metric을 `gen_ai.*` 같은 표준명으로) — S4 후 별도 RFC. 본 RFC는 backend 교체이지 metric 명명 표준화가 아니다.

## 8. RFC-0214 관계

RFC-0214 = genai dual emission (transitional, retired backend primary). RFC-0217 = 전체 Otel single (end-state, retired backend purge). RFC-0214 §4.3 Phase C(deprecate `masc_llm_provider_*`) + §7(legacy metric 이름 변경 = separate RFC)를 본 RFC가 흡수한다. dual은 S2 shim까지의 transitional 상태이며 S4에서 종료된다.

## 9. References

- RFC-0214 (genai dual emission), RFC-0043 (metric-ownership-distribution), RFC-0049 (surface-telemetry-foundation), RFC-0215 (sublib campaign LANE 3 telemetry)
- 설계 ledger: jeong-sik/masc-oas-docs (telemetry 통합 트랙, LANE 6 §27 인접)
- `opentelemetry` opam v0.11.1 — `Opentelemetry.Metrics` (sum/gauge/histogram + `Metrics_callbacks`), OTLP via `opentelemetry-client-cohttp-eio`
- `lib/llm_metric_bridge.ml` (RFC-0214 bridge), `lib/otel_metric_store*.ml`
- 초기 측정: 1008 call sites / 226 파일 / 75 metric defs / 21 legacy backend modules / 8 infra files (origin/main, 2026-06-04)
