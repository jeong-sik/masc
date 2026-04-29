# Performance Baseline 측정 프로토콜 (RFC PR-0.2)

masc-mcp v0.18.11 (OCaml 5.4 + Eio) 의 14 일 baseline 측정 인프라
정의. 본 문서는 향후 모든 최적화 PR (캐시, GC, WebSocket, MCP
latency 등) 의 머지 조건이 되는 baseline 계측 방법을 한 곳에 모은
SSOT 다.

본 PR 의 산출물:

- `scripts/perf-baseline.sh` — daily snapshot 수집 스크립트
- `reports/perf-baseline-template.md` — before/after 보고 템플릿
- `docs/design/perf-baseline-protocol.md` — 본 문서

코드 (`lib/`) 변경은 0. 신규 의존성 0.

## 1. 배경과 결정 사항

### 1.1 왜 본 PR 인가

외부 전략 문서가 권고한 ROI 수치 (캐시 41x, GC 18% 향상 등) 는 모두
**fictitious** 이다. 측정값이 0 인 상태에서 산출된 추정으로,
검증 가능한 baseline 없이 받아들이면 잘못된 우선순위로 인프라가
변형될 수 있다. 따라서 어떠한 최적화 PR 도 머지 전에:

1. 기존 baseline 표를 보여야 하고,
2. 그 표의 특정 행(들) 을 개선했음을 같은 단위로 증명해야 한다.

이를 강제하려면 **baseline 자체가 먼저 존재해야 한다**. 본 PR 은
"측정 자산만" 추가한다. 코드는 건드리지 않으며, 측정 결과를 어떤
임계값으로 강제하지도 않는다.

### 1.2 사용자 답변 (운영 전제)

| 항목 | 값 | 근거 |
|------|-----|------|
| 운영 keeper 수 | 12+ | 사용자 확인 |
| 50+ keeper | aspirational, baseline 가정 아님 | 사용자 확인 |
| 인프라 | 단일 Railway 인스턴스 | 사용자 확인 |
| 기존 prometheus | 존재 (`lib/prometheus.ml`, `/metrics`) | 코드 확인 |
| Runtime_events | 존재 (`lib/core/masc_runtime_events.ml`) | 코드 확인 |

본 baseline 은 12+ keeper 의 **현재 동작** 을 sample 하여 기록하는
것이지, 50+ keeper 의 가설적 동작을 기록하지 않는다.

## 2. 측정 대상 metric

다섯 영역 모두 `scripts/perf-baseline.sh` 가 한 번에 수집하며,
같은 보고 파일에 같은 timestamp 로 append 된다.

### 2.1 캐시 hit ratio

| metric | 출처 | 수집 방법 | 비고 |
|--------|------|----------|------|
| WS parse cache hit ratio | `masc_ws_parse_cache_{hits,misses}_total` | `/metrics` 카운터 합산 | 이미 export 됨 |
| WS bytes cache hit ratio | `masc_ws_bytes_cache_{hits,misses}_total` | `/metrics` 카운터 합산 | 이미 export 됨 |
| in-process caches | `lib/cache_eio.ml`, `lib/dashboard/dashboard_cache.ml` | **미export** | Phase 0.2.A |

`cache_eio` / `dashboard_cache` 는 hit/miss 카운터가 prometheus 에
등록되어 있지 않다. 사후 sampling (시점별 cache size 기록) 은
의미 없는 숫자가 되므로, **이 두 모듈에 카운터를 추가하는 것을
별도 PR (Phase 0.2.A) 로 명시하고**, 본 baseline 보고서에는 "not
exported" 로 기록한다. 추정 hit ratio 를 만들지 않는다.

### 2.2 WebSocket message size 분포 (P50/P95/P99) 와 RTT

| metric | 출처 | 수집 방법 | 비고 |
|--------|------|----------|------|
| total bytes sent | `masc_ws_bytes_sent_total` | counter | 이미 export 됨 |
| sessions total | `masc_ws_sessions_total` | counter | 이미 export 됨 |
| client buffered bytes | `masc_ws_client_buffered_bytes` | gauge | 이미 export 됨 |
| throttled deliveries | `masc_ws_throttled_deliveries_total` | counter | 이미 export 됨 |
| 메시지 size P50/P95/P99 | `masc_ws_message_bytes` (histogram) | **미정의** | Phase 0.2.B |
| RTT P50/P95/P99 | `masc_ws_rtt_seconds` (histogram) | **미정의** | Phase 0.2.B |

현재 export 는 평균 size 를 도출할 수 있는 수준 (`bytes_sent /
sessions`) 까지만 가능하다. percentile 분포를 baseline 에 넣으려면
histogram bucket 등록이 선행되어야 한다. 본 PR 은 그 사실을
보고서에 표시하고, 추정 percentile 을 만들어 적지 않는다.

### 2.3 MCP tool call latency (cold vs warm)

| metric | 출처 | 수집 방법 | 비고 |
|--------|------|----------|------|
| tool call count | `masc_tool_call_total` | counter | 이미 export 됨 |
| tool call duration histogram | `masc_tool_call_duration_seconds` | histogram | 이미 export 됨 |
| keeper tool call duration | `masc_keeper_tool_call_duration_seconds` | histogram | 이미 export 됨 |
| cold vs warm 분리 | `phase=cold|warm` label | **미부착** | Phase 0.2.C |

`benchmarks/quick-bench.sh` 와 `benchmarks/benchmark.sh` 가 lane
분리 (session/read/coordination/runtime/a2a/lock) 를 이미 한다.
이 lane 들은 cold vs warm 의 proxy 로 쓸 수 있지만, **dispatcher
레벨에서 phase label 이 붙은 histogram 이 더 정확하다**. 본
baseline 은 lane 별 percentile 을 quick-bench 출력으로 보존하고,
phase label 도입은 0.2.C 로 분리한다.

### 2.4 GC minor pause P99, major pause P99, RSS

| metric | 출처 | 수집 방법 | 비고 |
|--------|------|----------|------|
| host RSS (kB) | `/proc/<pid>/status` (Linux) / `ps -o rss=` | shell 호출 | placeholder |
| process open fds | `masc_process_open_fds` | gauge | 이미 export 됨 |
| GC minor pause P99 | `Gc.quick_stat` 주기 sampler | **미등록** | Phase 0.2.D |
| GC major pause P99 | 동일 | 동일 | 동일 |
| heap_words / live_words | 동일 | 동일 | 동일 |

OCaml 의 `Gc.quick_stat` 은 정량 정보가 풍부하지만 prometheus
gauge 로 export 되지 않은 상태다. 외부 권고 ("GC 18% 향상") 의
검증은 이 sampler 가 들어오기 전까지는 불가능하다. 본 PR 은 그
사실을 명시한다.

### 2.5 Eio fiber 활성 수, IO wait 분포

| metric | 출처 | 수집 방법 | 비고 |
|--------|------|----------|------|
| active agents | `masc_active_agents` | gauge | 이미 export 됨 |
| keeper turn span | `Masc_runtime_events.ev_turn` | runtime_events ring | OCAMLRUNPARAM=e 필요 |
| 활성 fiber 수 | runtime_events 신규 span | **미정의** | Phase 0.2.E |
| IO wait P95 | runtime_events 신규 span | **미정의** | Phase 0.2.E |

`Masc_runtime_events` 는 turn 단위 span 만 emit 한다. fiber 활성
수와 IO wait 분포는 별도의 span 또는 tracing 기반이 필요하므로
본 baseline 은 turn span 의 개수와 평균 길이만 보고한다 (olly 가
설치되어 있고 `OLLY_TRACE=1` 인 경우).

## 3. 수집 워크플로

### 3.1 단일 스냅샷

```bash
# server 가 :8935 에서 동작 중이어야 함
bash scripts/perf-baseline.sh
# → reports/perf-baseline-YYYY-MM-DD.md 에 append
```

`--dry-run` 은 의존성과 endpoint 가용성만 검증하고 종료한다.
의존성: `curl`, `awk`, `date`, `mkdir`, `tee`. `jq`, `olly` 는
선택. 모두 macOS / Linux 표준.

### 3.2 14 일 baseline

운영 환경 (Railway 단일 인스턴스, 12+ keeper) 에서 매일 1 회
실행을 14 일 누적한다. 실행 시각은 일 단위 동일 시각을 권장
(예: UTC 03:00). 결과는 `reports/perf-baseline-YYYY-MM-DD.md`
파일 14 개로 남는다. 14 일 평균과 분산은 향후 0.2.F 단계에서
스크립트로 계산한다.

### 3.3 cron 등록 (선택)

```cron
# 매일 03:00 UTC, OCAMLRUNPARAM=e 로 서버가 실행 중일 때
0 3 * * * cd /path/to/masc-mcp && \
  OLLY_TRACE=0 bash scripts/perf-baseline.sh \
  >> /var/log/masc-mcp/perf-baseline.cron.log 2>&1
```

`OLLY_TRACE=1` 은 30 초 동안 olly 가 마스터 process 에 attach
하므로, 운영 환경에서는 기본 0 을 권장한다.

## 4. PR 머지 조건 (향후 최적화 PR 에 적용)

`reports/perf-baseline-template.md` 의 **2 절 "Required metric
table"** 을 PR 본문에 그대로 복사하고, baseline / after / delta /
source 칸을 모두 채워야 한다. 비어 있는 셀은 `not exported` 로
표기하고 follow-up phase (0.2.A ~ 0.2.E) 를 명시한다.

머지 가능성은 reviewer 판단으로 강제한다. 본 PR 단계에서 CI 자동
diff 는 wiring 하지 않는다 (Phase 0.2.F).

### 4.1 강제하지 않는 것

- 절대 임계값 (예: P95 < 80ms) 강제. baseline 이 있어야 임계값을
  도출할 수 있고, 임계값 없이 baseline 만 먼저 쌓는다.
- 외부 전략 문서의 ROI 수치 (41x, 18% 등). 본 baseline 의 표만이
  유효한 비교 단위다.

## 5. 본 PR 이후의 단계 (참고)

| Phase | 산출물 | 선행 조건 |
|-------|--------|----------|
| 0.2.A | `cache_eio` / `dashboard_cache` 에 hit/miss 카운터 등록 | 본 PR 머지 |
| 0.2.B | `masc_ws_message_bytes`, `masc_ws_rtt_seconds` histogram | 본 PR 머지 |
| 0.2.C | tool call dispatcher 에 `phase=cold|warm` label | 본 PR 머지 |
| 0.2.D | `Gc.quick_stat` 주기 sampler → gauge family | 본 PR 머지 |
| 0.2.E | `Masc_runtime_events` 에 io-wait span 추가 | 본 PR 머지 |
| 0.2.F | CI 가 PR 본문의 baseline 표 형식을 검사하고 daily 보고서를 diff | 0.2.A~E 일부 머지 |

각 phase 는 별도 PR 로 분리한다. 본 PR 은 그 어느 phase 의 코드도
포함하지 않는다.

## 6. 한계

- 본 baseline 은 **단일 Railway 인스턴스 + 12+ keeper** 의 측정
  값만 보고한다. 환경이 다르면 (다중 region, 50+ keeper) 새 baseline
  을 다시 14 일 쌓아야 한다.
- prometheus counter 는 server restart 시 0 으로 초기화된다.
  daily 보고서는 누적이 아니라 **순간 snapshot** 이며, rate 는
  14 일 분량에서 계산한다.
- macOS 와 Linux 의 RSS 측정 경로가 다르다 (`ps` vs `/proc`). 두
  환경 모두 지원하지만, 비교 단위로는 같은 OS 안에서만 의미가
  있다.
