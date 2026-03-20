# MASC Quick Start

이 문서는 `서버를 어떻게 띄우는가`에 집중한다.

실제 MCP tool 사용 순서와 canonical workflow는 여기서 설명하지 않는다.

- merged 구조 요약: [MERGED-ARCHITECTURE-SSOT.md](./MERGED-ARCHITECTURE-SSOT.md)
- CPv2 benchmark / swarm: [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- benchmark 비교 실험: [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- supervised team-session: [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- swarm-driven implementation delivery: [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)

## 1. 서버 시작

```bash
cd ~/me/workspace/yousleepwhen/masc-mcp
./start-masc-mcp.sh --http
```

기본 포트:

- HTTP / MCP: `8935`

상태 확인:

```bash
curl http://127.0.0.1:8935/health
```

## 2. MCP 연결

`.mcp.json` 예시:

```json
{
  "mcpServers": {
    "masc": {
      "url": "http://127.0.0.1:8935/mcp"
    }
  }
}
```

## 3. 대시보드

- Command Plane dashboard: `http://127.0.0.1:8935/dashboard#/command`
- operator snapshot API: `GET /api/v1/operator`
- CPv2 snapshot API: `GET /api/v1/command-plane`
- CPv2 help API: `GET /api/v1/command-plane/help`

## 4. 보통 먼저 확인할 것

```bash
curl -s http://127.0.0.1:8935/api/v1/command-plane/help | jq '.golden_paths[].id'
curl -s http://127.0.0.1:8935/api/v1/command-plane | jq '.operations.summary'
```

## 5. 모드 확인

기본 모드는 `Full` (모든 도구 사용 가능). 제한이 필요하면 `Standard`나 `Coding`으로 전환한다.

```
masc_get_config                       # 현재 모드 확인
masc_switch_mode(mode="standard")     # 도구 수 제한 시
```

기존 `.masc/config.json`에 `"mode":"coding"`이 남아 있으면 도구가 차단될 수 있다. 삭제 후 서버 재시작하면 Full 모드로 초기화된다.

## 6. 주의

- `masc_set_room`은 repo-root room semantics를 따른다.
- `masc_transition(action="claim")`은 session `current_task`를 자동으로 안 잡는다. `masc_claim_next`는 current builds에서 auto-bind 한다.
- 긴 작업에서는 `masc_heartbeat`가 필요하다.

이 세부 usage는 Quick Start가 아니라 runbook 문서가 SSOT다.

## 관련 문서

- [COMMAND-PLANE-RUNBOOK.md](./COMMAND-PLANE-RUNBOOK.md)
- [BENCHMARK-RUNBOOK.md](./BENCHMARK-RUNBOOK.md)
- [SUPERVISOR-MODE.md](./SUPERVISOR-MODE.md)
- [SWARM-DELIVERY-RUNBOOK.md](./SWARM-DELIVERY-RUNBOOK.md)
- [README.md](../README.md)
