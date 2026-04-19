# Transport Practical Playbook

`masc-mcp`의 transport는 많지만, 다 같은 문제를 풀지 않는다. 이 문서는 실제 운영에서 어떤 경로를 우선 쓰고, 어떤 지표를 보며, 어떤 명령으로 검증하는지에 집중한다.

## Quick View

| 시나리오 | 권장 transport | 이유 | 대시보드에서 볼 것 |
| --- | --- | --- | --- |
| 현황판, wallboard, read-mostly viewer | `observer SSE` (`GET /mcp?sse_kind=observer`) | 브라우저 친화적이고 단방향 freshness에 충분함 | `SSE observer`, `queue max`, `broadcast avg` |
| agent heartbeat, subscribe, fast fanout | `gRPC` (`:8936`) | 양방향 스트림, backlog replay, typed contract | `gRPC subscribers`, `active streams` |
| browser/operator duplex bridge | `WebSocket` (`/ws`, standalone port `8937`) | request/response를 한 socket에서 처리하기 좋음 | `WebSocket sessions` |
| peer-to-peer fast lane, edge a2a | `WebRTC` (`/webrtc/offer`, `/webrtc/answer`) | signaling 후 DataChannel로 직접 통신 | `connected channels`, `active peers` |
| stateless scripting, queue trigger, worker bootstrap | `Streamable HTTP` (`POST /mcp`) | curl/harness에서 가장 단순하고 canonical | `primary path`, `recent messages`, `active ops` |
| 브라우저 다중 탭 / 다중 stream | `HTTP/2 h2c` (`MASC_USE_H2=1` 또는 `auto`) | SSE multiplexing으로 브라우저 connection limit 회피 | `HTTP listener_mode`, `multiplex_ready` |

## Dashboard

- overview: `http://127.0.0.1:8935/dashboard#/overview`
- transport snapshot API: `http://127.0.0.1:8935/api/v1/dashboard/transport-health`

이 surface는 다음을 한 번에 보여준다.

- live SSE observer/coordinator 수
- gRPC subscriber/heartbeat 상태
- WebSocket/WebRTC 활성도
- queue/backpressure hot session
- 현재 cluster / room / managed unit / active operation
- transport별 practical path 추천

## Truth Harness

Before changing transport health reporting, run the truth harness:

```bash
./scripts/harness/transport/verify_truth.sh
```

This is an explicit drift harness, not part of `run_all.sh` by default. It
returns non-zero when reported truth and live probe truth disagree.

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
  -H 'Accept: application/json, text/event-stream'
```

### 3. HTTP/2 h2c path

```bash
MASC_USE_H2=1 ./start-masc-mcp.sh --http --port 8935

curl --http2-prior-knowledge -sS http://127.0.0.1:8935/mcp \
  -H 'Content-Type: application/json' \
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
grpcurl -plaintext 127.0.0.1:8936 grpc.health.v1.Health/Check
```

`Subscribe` / `Heartbeat`는 `proto/masc_coordination.proto` 기준으로 client를 붙인다. dashboard `transport-health`에서 `subscribers`, `active_streams`가 즉시 증가해야 한다.

### 5. WebSocket discovery

```bash
curl -sS http://127.0.0.1:8935/ws
```

응답에 standalone WS port와 URL이 들어간다. duplex UI나 browser bridge는 이 경로를 우선 본다.

### 6. WebRTC signaling

offer:

```bash
curl -sS http://127.0.0.1:8935/webrtc/offer \
  -H 'Content-Type: application/json' \
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
  -d '{
    "offer_id":"<offer_id>",
    "agent_name":"agent-b",
    "ice_candidates":["127.0.0.1:5001"]
  }'
```

## Operating Notes

- queue pressure가 `watch` 이상이면 먼저 SSE `hot_sessions`를 본다.
- `gRPC subscribers`가 높고 `broadcast avg`도 같이 오르면 fanout source는 SSE bridge일 가능성이 크다.
- multi-node / distributed mode에서는 transport 자체보다 `cluster`, `managed_units`, `active_operations`, `stale_units`를 같이 봐야 한다.
- canonical public control path는 여전히 `POST /mcp`다. WS/gRPC/WebRTC는 특정 latency/duplex/p2p 문제가 있을 때 올린다.
