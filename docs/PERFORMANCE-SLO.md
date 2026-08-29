# Performance SLO (MASC MCP)

## 목표
- 로컬/단일 머신 기준의 체감 지연 최소화
- 대시보드 통합 시 안정적인 조회/스트림 유지

## 대상 지표

### MCP JSON-RPC (tools/call, established session)
- P50 < 80ms
- P95 < 300ms
- P99 < 800ms

추가 지표:

- `initialize + notifications/initialized` 세션 생성 비용은 별도 추적
- raw local runtime 비용은 Admin-only effectful diagnostic인 `masc_runtime_verify`로 MCP read-path와 분리해서 측정

### REST API
- /api/v1/status P95 < 150ms
- /api/v1/tasks P95 < 250ms (limit=50)
- /api/v1/messages P95 < 250ms (limit=20)

### SSE
- 연결 성공 < 1s
- 이벤트 전달 지연 P95 < 500ms

### LLM Provider Streaming Latency

현재 MASC는 agent core provider의 **TTFRC**(Time To First Response Chunk)만 측정한다.
agent core `Streaming_summary.ttft_ms`(Time To First Token)는 MASC가 직접 소비하지 않는다.

- `keeper_telemetry_consumer.ml`은 agent core telemetry event를 counter-only로 관찰하며,
  provider model-bearing payload는 역직렬화하지 않는다.
- `llm_metric_bridge.ml`의 `on_streaming_first_chunk` 콜백은 response chunk가
  도착한 시점(`ttfrc_ms`)만 기록한다.

노출 메트릭:

- `masc_llm_provider_streaming_first_chunk` — TTFRC histogram (seconds)
- `gen_ai.response.time_to_first_chunk` — OpenTelemetry GenAI semconv TTFRC

**TTFT-to-client**(= provider TTFT + transport overhead)는 현재 측정되지 않는다.
agent core RFC-AC-020이 요구하는 consumer SLO를 추가하려면 agent core `Streaming_summary`를
파싱하거나 `Metrics.t` 콜백 계약에 TTFT 필드를 추가해야 한다.

## 측정 방법
- `benchmarks/quick-bench.sh`
- `benchmarks/benchmark.sh`

해석 규칙:

- 두 스크립트 모두 `initialize -> notifications/initialized -> Mcp-Session-Id 재사용` 흐름으로 측정한다.
- `quick-bench.sh`는 `mcp_session_init`, 주요 MCP read/write path, `masc_runtime_verify`를 한 번에 보여준다.
- `quick-bench.sh`는 `BENCH_ITERATIONS`, `BENCH_WARMUP_ITERATIONS`로 반복 수와 warmup 제외 횟수를 조정할 수 있다.
- `benchmark.sh`는 `session`, `read`, `workspace collaboration`, `runtime`, `a2a`, `lock` lane을 분리하고 `avg/p50/p95/max`를 CSV로 남긴다.
- `benchmark.sh`는 기본적으로 tool lane당 warmup 1회를 제외하고, 결과 CSV 옆에 metadata와 baseline diff를 같이 남긴다.
- `runtime` lane 숫자는 MCP transport가 아니라 local runtime ceiling 영향을 크게 받는다.
- 인증이 켜진 서버에서 `quick-bench.sh` 또는 `runtime` lane을 실행할 때는
  `MASC_TOKEN`에 Admin credential이 필요하다. `masc_runtime_verify`는 endpoint마다
  실제 chat completion을 호출하므로 read-only benchmark가 아니다.
- `local64`는 target runtime profile 이름이지 achieved fact가 아니다. 실제 용량은 `masc_runtime_verify`의 `configured_capacity`, `healthy_runtime_count`로 확인한다.

환경 변수:
```
MASC_URL=http://127.0.0.1:8935/mcp
MASC_AGENT=bench
MASC_TOKEN=<Admin token required for quick-bench/runtime lane when auth is enabled>
```

## 경고 기준
- MCP P95가 1s 이상 지속되면 장애로 간주
- REST API P95가 1s 이상이면 대시보드 사용성 붕괴
- SSE drop/reconnect가 5분 내 3회 이상이면 안정성 이슈

## 개선 힌트
- REST 페이지네이션/필터 적극 사용
- 메시지/태스크 조회는 limit을 낮춘다
- JSONL hot path를 줄이고 filesystem runtime contract 안에서 compaction/rotation/replay 비용을 낮춘다.
