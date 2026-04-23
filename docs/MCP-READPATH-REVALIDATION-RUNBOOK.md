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
- keeper가 하나 이상 있을 때, 정렬된 keeper list 앞쪽 `KEEPER_STATUS_SAMPLE_LIMIT`개 이름만 결정론적으로 status probe 후보로 본다.
- 위 후보 중 첫 `masc_keeper_status` 성공 payload에 다음 필드가 존재한다.
  - `coordination.joined_room_ids`
  - `runtime.proactive_enabled`
- `/api/v1/dashboard/execution`의 keeper row는 `diagnostic` object를 포함한다.
- `/api/v1/dashboard/execution`에서 `keepalive_running=false` 이고 `proactive_enabled=true` 인 keeper는 `diagnostic.quiet_reason="disabled"`로 분류되지 않는다.
- harness가 직접 띄운 서버(`START_SERVER=1`)에서는 mode별 `/health.transport` shape도 검증한다.
- 외부 서버(`START_SERVER=0`)에 붙을 때는 transport mode check를 기본적으로 강제하지 않는다. 필요하면 `EXPECT_HEALTH_MODE=1`로 켤 수 있다.

주의:
- 이 harness는 read-path smoke/contract check다. keeper 전수검사가 아니라 representative single-sample 상세 status 검증을 한다.

## Output

실행이 끝나면 마지막 줄에 아래 형식으로 summary path를 출력한다.

```text
summary=/abs/path/to/logs/mcp_readpath_revalidation/<run-id>/summary.json
```

summary에는 모드별 timing, backend mode, fallback reason, health transport 상태, keeper list 이름 샘플, keeper status sampling metadata, `masc_keeper_status` 조회 시도 이름 목록, `masc_keeper_status` 샘플, execution keeper 샘플이 들어간다.

## Useful Overrides

```bash
MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
BASE_PATH=/abs/path/to/repo ./scripts/harness_mcp_readpath_revalidation.sh
KEEP_SERVER=1 ./scripts/harness_mcp_readpath_revalidation.sh
START_SERVER=0 TARGET_BASE_URL=http://127.0.0.1:8946 MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
START_SERVER=0 TARGET_BASE_URL=http://127.0.0.1:8946 EXPECT_HEALTH_MODE=1 MODES=http_only ./scripts/harness_mcp_readpath_revalidation.sh
KEEPER_STATUS_SAMPLE_LIMIT=5 ./scripts/harness_mcp_readpath_revalidation.sh
```
