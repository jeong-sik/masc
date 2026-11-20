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

- `lib/runtime/runtime_observation.ml`은 agent core 스트리밍 관측 이벤트를 수집하며,
  `lib/llm_metric_bridge.ml`의 `on_streaming_first_chunk` 콜백은 response chunk가
  도착한 시점(`ttfrc_ms`)만 기록한다.

노출 메트릭:

- `masc_llm_provider_streaming_first_chunk_seconds` — TTFRC histogram (seconds)
- `gen_ai.client.operation.time_to_first_chunk` — OpenTelemetry GenAI semconv TTFRC

**TTFT-to-client**(= provider TTFT + transport overhead)는 현재 측정되지 않는다.
agent core RFC-AC-020이 요구하는 consumer SLO를 추가하려면 agent core `Streaming_summary`를
파싱하거나 `Metrics.t` 콜백 계약에 TTFT 필드를 추가해야 한다.

## 경고 기준
- MCP P95가 1s 이상 지속되면 장애로 간주
- REST API P95가 1s 이상이면 대시보드 사용성 붕괴
- SSE drop/reconnect가 5분 내 3회 이상이면 안정성 이슈

## 개선 힌트
- REST 페이지네이션/필터 적극 사용
- 메시지/태스크 조회는 limit을 낮춘다
- JSONL hot path를 줄이고 filesystem runtime contract 안에서 compaction/rotation/replay 비용을 낮춘다.
