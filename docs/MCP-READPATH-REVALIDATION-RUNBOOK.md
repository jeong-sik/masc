# MCP Read-Path Revalidation

이 runbook은 `masc_status`, `masc_keeper_list`, `masc_transport_status`, dashboard cached surfaces, keeper continuity surface를 함께 재검증할 때 쓴다.

엔트리포인트:

```bash
./scripts/harness_mcp_readpath_revalidation.sh
```

기본 모드:

- `http_only`
  - `MASC_GRPC_ENABLED=0`
  - `MASC_WS_ENABLED=0`
  - `MASC_WEBRTC_ENABLED=0`
  - MCP read-path와 dashboard cache baseline 확인
- `default`
  - live HTTP + WebSocket + WebRTC startup 확인
  - gRPC는 기본적으로 꺼 둔다

기본 base path는 현재 repo root다. 즉 live `.masc` 상태와 keeper runtime surface를 같이 검증한다.

## Success Criteria

- `masc_status` 2회 연속 호출이 timeout 없이 끝난다.
- `masc_keeper_list(detailed=false)` 2회 연속 호출이 timeout 없이 끝난다.
- `masc_transport_status`가 빠르게 응답한다.
- `/api/v1/dashboard/execution`과 `/api/v1/dashboard/transport-health`의 `projection_diagnostics.cache_state`가 `fresh`다.
- `/health.startup.pending_lazy_tasks`가 빈 배열이다.
- keeper list `items`에 다음 필드가 존재한다.
  - `room_scope`
  - `proactive_enabled`
- `keepalive_running=false` 이고 `proactive_enabled=true` 인 keeper는 `diagnostic.quiet_reason="disabled"`로 분류되지 않는다.

## Output

실행이 끝나면 마지막 줄에 아래 형식으로 summary path를 출력한다.

```text
summary=/abs/path/to/logs/mcp_readpath_revalidation/<run-id>/summary.json
```

summary에는 모드별 timing, backend mode, fallback reason, health transport 상태, keeper sample payload가 들어간다.

## Useful Overrides

```bash
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
BASE_PATH=/abs/path/to/repo ./scripts/harness_mcp_readpath_revalidation.sh
KEEP_SERVER=1 ./scripts/harness_mcp_readpath_revalidation.sh
START_SERVER=0 TARGET_BASE_URL=http://127.0.0.1:8946 MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
```
