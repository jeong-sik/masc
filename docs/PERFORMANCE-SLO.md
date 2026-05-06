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
- raw local runtime 비용은 `masc_runtime_verify`로 MCP read-path와 분리해서 읽음

### REST API
- /api/v1/status P95 < 150ms
- /api/v1/tasks P95 < 250ms (limit=50)
- /api/v1/messages P95 < 250ms (limit=20)

### SSE
- 연결 성공 < 1s
- 이벤트 전달 지연 P95 < 500ms

## 측정 방법
- `benchmarks/quick-bench.sh`
- `benchmarks/benchmark.sh`

해석 규칙:

- 두 스크립트 모두 `initialize -> notifications/initialized -> Mcp-Session-Id 재사용` 흐름으로 측정한다.
- `quick-bench.sh`는 `mcp_session_init`, 주요 MCP read/write path, `masc_runtime_verify`를 한 번에 보여준다.
- `quick-bench.sh`는 `BENCH_ITERATIONS`, `BENCH_WARMUP_ITERATIONS`로 반복 수와 warmup 제외 횟수를 조정할 수 있다.
- `benchmark.sh`는 `session`, `read`, `coordination`, `runtime`, `a2a`, `lock` lane을 분리하고 `avg/p50/p95/max`를 CSV로 남긴다.
- `benchmark.sh`는 기본적으로 tool lane당 warmup 1회를 제외하고, 결과 CSV 옆에 metadata와 baseline diff를 같이 남긴다.
- `runtime` lane 숫자는 MCP transport가 아니라 local runtime ceiling 영향을 크게 받는다.
- `local64`는 target runtime profile 이름이지 achieved fact가 아니다. 실제 용량은 `masc_runtime_verify`의 `configured_capacity`, `healthy_runtime_count`로 확인한다.

환경 변수:
```
MASC_URL=http://127.0.0.1:8935/mcp
MASC_AGENT=bench
MASC_TOKEN=<optional>
```

## 경고 기준
- MCP P95가 1s 이상 지속되면 장애로 간주
- REST API P95가 1s 이상이면 대시보드 사용성 붕괴
- SSE drop/reconnect가 5분 내 3회 이상이면 안정성 이슈

## 개선 힌트
- REST 페이지네이션/필터 적극 사용
- 메시지/태스크 조회는 limit을 낮춘다
- JSONL hot path를 줄이고 filesystem runtime contract 안에서 compaction/rotation/replay 비용을 낮춘다.
