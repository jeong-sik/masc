# Transport Practical Playbook

`masc`의 transport는 많지만, 다 같은 문제를 풀지 않는다. 이 문서는 실제 운영에서 어떤 경로를 우선 쓰고, 어떤 지표를 보며, 어떤 명령으로 검증하는지에 집중한다.

## Quick View

| 시나리오 | 권장 transport | 이유 | 대시보드에서 볼 것 |
| --- | --- | --- | --- |
| 현황판, wallboard, read-mostly viewer | `observer SSE` (`GET /mcp?sse_kind=observer`) | 브라우저 친화적이고 단방향 freshness에 충분함 | `SSE observer`, `queue max`, `broadcast avg` |
| optional Keeper heartbeat canary, subscribe 검증 | `gRPC` (`:8936`) **Experimental / advisory** | typed stream을 검증하되 canonical workspace freshness를 대체하지 않음 | `gRPC subscribers`, `active streams` |
| browser/operator duplex bridge | same-origin `WebSocket` (`/ws`) **Experimental** | request/response를 한 socket에서 처리하기 좋음; H2-only listener에서는 미지원 | `WebSocket sessions`, `listen_status` |
| peer-to-peer fast lane, edge a2a | `WebRTC` (`/webrtc/offer`, `/webrtc/answer`) **Experimental** | signaling 후 DataChannel로 직접 통신 | `connected channels`, `active peers` |
| stateless scripting, queue trigger, worker bootstrap | `Streamable HTTP` (`POST /mcp`) | curl/harness에서 가장 단순하고 canonical | `primary path`, `recent messages`, `active ops` |
| 브라우저 다중 탭 / 다중 stream | `HTTP/2 h2c` (`MASC_USE_H2=1` 또는 `auto`) | SSE multiplexing으로 브라우저 connection limit 회피 | `HTTP listener_mode`, `multiplex_ready` |

## Dashboard

- overview: `http://127.0.0.1:8935/dashboard#/overview`
- transport snapshot API: `http://127.0.0.1:8935/api/v1/dashboard/transport-health`

이 surface는 다음을 한 번에 보여준다.

- live SSE observer/agent stream 수
- gRPC subscriber/heartbeat 상태
- WebSocket/WebRTC 활성도
- queue/backpressure hot session
- 현재 cluster / workspace / managed unit / active operation
- transport별 practical path 추천

## Truth Harness

Before changing transport health reporting, run the truth harness:

```bash
./scripts/harness/transport/verify_truth.sh
```

This is the explicit drift harness. It is included in
`./scripts/harness/transport/run_all.sh` and therefore also runs in the CI
transport harness suite. Run it directly when iterating on transport truth so
reported truth vs. live probe drift fails fast without waiting for the full
suite. It returns non-zero when those surfaces disagree.

It bootstraps an isolated server when needed and compares:

- `/health`
- dashboard read model: `/api/v1/dashboard/transport-health`
- MCP read model: `masc_transport_status`
- live reachability probes for Streamable HTTP, observer SSE, gRPC TCP, WebSocket handshake, and h2c when advertised

Mismatch output names the transport and the disagreeing surfaces, for example:
`grpc truth mismatch: dashboard=true tool=true actual=false tcp=127.0.0.1:8936`.
Use that output as the regression proof before and after transport truth fixes.

## Recipes

### 1. Streamable HTTP POST

```bash
curl -sS http://127.0.0.1:8935/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"tools/call",
    "params":{
      "name":"masc_status",
      "arguments":{}
    }
  }'
```

### 2. Observer SSE for dashboard/wallboard

```bash
curl -N http://127.0.0.1:8935/mcp?sse_kind=observer\&session_id=playbook-observer \
  -H 'Accept: application/json, text/event-stream' \
  -H 'Authorization: Bearer <agent-token>'
```

### 3. HTTP/2 h2c path

```bash
MASC_USE_H2=1 ./start-masc.sh --http --port 8935

curl --http2-prior-knowledge -sS http://127.0.0.1:8935/mcp \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <agent-token>' \
  -d '{
    "jsonrpc":"2.0",
    "id":1,
    "method":"initialize",
    "params":{
      "protocolVersion":"2025-03-26",
      "capabilities":{},
      "clientInfo":{"name":"h2c-playbook","version":"1.0"}
    }
  }'
```

### 4. gRPC health and subscribe

```bash
grpcurl -plaintext 127.0.0.1:8936 list
grpcurl -plaintext \
  -import-path proto \
  -proto grpc_health_v1.proto \
  -d '{"service":"masc.workspace.v1.MascWorkspace"}' \
  127.0.0.1:8936 grpc.health.v1.Health/Check

./scripts/harness/transport/verify_grpc_subscribe.sh
```

계약 SSOT는 `proto/masc_workspace.proto`다. workload RPC는 per-agent bearer
credential이 필요하며, `agent_name`을 보내는 요청은 credential owner와 같아야
한다. 외부 서버를 대상으로 harness를 실행할 때는 해당 agent의 raw token
파일을 `MASC_GRPC_SUBSCRIBER_TOKEN_FILE`로 지정한다.

현재 서비스 RPC는 bidi `Heartbeat`, server-streaming `Subscribe`, unary
`ToolCall`/`Broadcast`/`GetStatus`다. in-tree production client는
`MASC_AGENT_TRANSPORT=grpc`일 때 optional Keeper `Heartbeat` sidecar만 사용한다.
나머지 client wrapper는 production callsite가 없고, Dashboard IDE LSP는
same-origin WebSocket `/api/v1/ide/lsp`를 사용한다. health/reflection 및 짧은
harness 성공만으로 gRPC heartbeat를 production-ready로 판단하지 않는다.

### 5. WebSocket discovery

```bash
curl -sS http://127.0.0.1:8935/ws
```

응답은 same-origin `/ws`의 `listening`, `listen_status`, `ws_url`을 제공한다.
별도 standalone WS port는 없다.

### 6. WebRTC signaling

offer:

```bash
curl -sS http://127.0.0.1:8935/webrtc/offer \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <agent-a-token>' \
  -d '{
    "agent_name":"agent-a",
    "ice_candidates":["127.0.0.1:5000"],
    "dtls_fingerprint":"demo"
  }'
```

answer:

```bash
curl -sS http://127.0.0.1:8935/webrtc/answer \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <agent-b-token>' \
  -d '{
    "offer_id":"<offer_id>",
    "agent_name":"agent-b",
    "ice_candidates":["127.0.0.1:5001"]
  }'
```

각 signaling bearer의 credential owner가 payload의 `agent_name`과 일치해야 한다.

## Operating Notes

- queue pressure가 `watch` 이상이면 먼저 SSE `hot_sessions`를 본다.
- `gRPC subscribers`가 높고 `broadcast avg`도 같이 오르면 fanout source는 SSE bridge일 가능성이 크다.
- multi-node / distributed mode에서는 transport 자체보다 `cluster`, `managed_units`, `active_operations`, `stale_units`를 같이 봐야 한다.
- canonical public control path는 여전히 `POST /mcp`다. gRPC heartbeat는 production
  rollout 전까지 advisory canary이며, WS/gRPC/WebRTC는 각 experimental 경계와
  실제 consumer를 확인한 뒤 사용한다.
