# HTTP response side streaming audit (cohttp-eio / H2)

Date: 2026-05-12
Scope: `lib/server/server_*` HTTP response shapes — backpressure, streaming, memory accumulation.
Related: PR-A (#14706 streaming JSONL reader), PR-C (#14711 credential blocking IO), PR-B (#14718 RFC-0059 PR-7-pilot Domain pool).

## TL;DR

| 영역 | 상태 | 다음 단계 |
|---|---|---|
| **SSE backpressure** | ✅ 잘 됨 — bounded `Eio.Stream` + overflow→disconnect. | (note) RFC-0059 PR-7 활성 시 single-domain 가정 깨짐 — 별도 PR 에서 cross-domain race 검토. |
| **JSON response (대형)** | ⚠️ sync `write_string body` — 전체 메모리 누적 후 전송. | dashboard `runtime_info`, telemetry `model_inference_metrics` 같은 대형 응답에 streaming serializer 도입 후보. |
| **HTTP write_string call sites (H2 helpers)** | 정상 — `h2_respond_*` 경유 응답은 size-bounded (`content-length` known) 후 close. | 변경 불필요. |
| **HTTP/1.1 fallback error handler** | ⚠️ `server_bootstrap_http.ml:129/258` 의 `Httpun.Body.Writer.write_string` 응답은 `content-type` 만 세팅, `content-length` 없음 (chunked transfer-encoding 으로 떨어짐). | error path 한정 — 정상 응답 경로는 영향 없음. 필요 시 별도 PR 에서 명시적 size header 추가 검토. |
| **Httpun body writer** | `Body.Writer.write_string` 동기. SSE 외의 streaming 없음. | Anthropic-style chunked encoding 도입 시 `Body.Writer.write_string` 반복 또는 새 helper 필요. |

## 1. Response shape inventory

`rg -lc 'write_string' lib/server/` 기준 — 10개 파일에 분산. 패턴별 분류:

**(a) H2 helper 경유 single-shot (size-bounded, content-length known):**

| 파일 | 사이트 수 | 패턴 |
|---|---|---|
| `lib/server/server_h2_gateway_helpers.ml` | 4 (`h2_respond_json/text/html/...`) | `H2.Body.Writer.write_string writer body; H2.Body.Writer.close writer` |
| `lib/server/server_h2_gateway.ml` | 8 | 동일 패턴 (직접 H2 응답) |
| `lib/server/server_h2_gateway_routes_extra.ml` | 3 | 동일 |
| `lib/server/server_routes_http_routes_legendary_bash.ml` | 1 | 동일 |
| `lib/server/server_routes_http_routes_dashboard.ml` | 1 | 동일 |
| `lib/server/server_ide_http.ml` | 1 | 동일 |
| `lib/server/server_mcp_transport_http_conn.ml` | 1 | 동일 |

**(b) SSE event push (streaming, per-event flush — not size-bounded):**

| 파일 | 사이트 수 | 패턴 |
|---|---|---|
| `lib/server/server_activity_http.ml` | 1 | `Httpun.Body.Writer.write_string info.writer data` (SSE frame) |
| `lib/server/server_routes_http_keeper_stream.ml` | 1 | SSE keeper event stream |

**(c) HTTP/1.1 fallback error handler (no content-length, falls back to chunked):**

| 파일 | 사이트 수 | 패턴 |
|---|---|---|
| `lib/server/server_bootstrap_http.ml` | 2 (lines 129, 258) | `Httpun.Body.Writer.write_string body msg` with only `content-type` header set |

**즉**: SSE 이벤트 push 를 제외한 모든 HTTP 응답이 **이미 직렬화된 string 을 한 번에 write_string** 함. `H2.Reqd.respond_with_streaming` 을 쓰지만 *streaming as in chunked transfer with delayed body* 가 아닌, *streaming as in headers-then-body* 의 H2 API 이름일 뿐.

## 2. SSE backpressure (잘 됨)

`lib/sse.ml`:

- `stream_capacity = 256` (default), env knob `MASC_SSE_STREAM_CAPACITY` 로 8-1024 clamp.
- `Eio.Stream.create stream_capacity` per-client bounded queue.
- Broadcast 시 `Eio.Stream.length` 사전 체크 → overflow 면 `failed := session_id :: !failed` → loop 끝에 `unregister`. 클라이언트는 `EventSource` 자동 재연결 + `Last-Event-Id` 로 gap 회복.
- 이전 silent-drop 모드 → 명시적 disconnect 로 전환됨 (Tier-A perf fix).

**잘 된 점**: bounded + observable failure mode. operator 가 broadcast_failure counter 로 backpressure 감지 가능.

**RFC-0059 PR-7 cross-domain 리스크**: `lib/sse.ml:832` 의 comment
> "single-domain Eio cooperative scheduling has no yield point between Stream.length and Stream.add"

이 가정이 keeper Domain pool 활성 시 깨짐. keeper 가 worker Domain 에서 broadcast 호출 (예: `Keeper_event_queue.enqueue_event` 가 SSE 로 흘러갈 경우) → `Stream.length` 과 `Stream.add` 사이에 다른 Domain 의 broadcast 가 끼어들 수 있음. TOCTOU race.

**조치 권고** (PR-B follow-up): `Eio.Stream.length` 가 cross-domain safe 인지 eio docs 확인. 아니면 try/catch 의 defense-in-depth 가 실제로 trigger 되도록 (try Eio.Stream.add → busy/full exception caught → unregister 같은 경로).

## 3. JSON 응답의 메모리 누적

`Yojson.Safe.to_string` 가 전체 JSON 트리 → 단일 string. 대형 응답에서 메모리 spike + first-byte latency.

### 대형 응답 후보

| 엔드포인트 | 추정 응답 크기 | 비고 |
|---|---|---|
| `/dashboard/runtime_info` | < 100 KB | 모든 keeper meta + cascade snapshot |
| `/dashboard/keeper/list` | 100 KB+ (N keeper × meta) | 64 keeper × ~2KB per meta |
| `/telemetry/inference_metrics` | 변동 (대용량 가능) | bucketed metrics, time window 따라 |
| `/activity/feed` | 변동 | 페이지네이션 있음 (good) |

dashboard runtime info / keeper list 가 가장 hot. 64 keeper 이상 prod 에서 단일 응답 100KB+ → 전체 메모리 적재 후 전송.

### 개선 후보

**A. Yojson streaming encoder** (jsonm 또는 custom). 한 객체씩 직렬화 + chunked write. 메모리 O(1), TTFB 개선.

**B. Pagination 강제**: 큰 응답은 cursor-based pagination 으로 분할. Activity feed 가 이미 이렇게 함.

**C. h2_respond_json_streaming 신규 helper**: `H2.Body.Writer.write_string` 을 반복 호출하면서 yojson_encoder 이벤트 시퀀스 emit. 단점: 추가 라이브러리 의존 (jsonm 또는 custom). 이득 정량 측정 후 결정.

**조치 권고**: 측정 먼저. dashboard runtime_info / keeper list 의 p95 latency 와 메모리 footprint 를 prod 에서 측정한 후 streaming 도입 ROI 평가.

## 4. Anthropic streaming 응답 backpressure (다른 축)

본 audit 범위는 *masc-mcp 서버 응답* 측. *Anthropic API 호출 응답* (oas/agent_sdk 의 streaming) 은 별도 repo. 외부 `oas` (Open Agent Stack) 의 streaming.ml 에 ToolUse JSON 을 block 완성 후 일괄 파싱하는 패턴 보고됨 — 그건 oas repo 의 별도 PR 대상. (구체 위치는 oas repo 의 lib/streaming.ml 참조.)

## 5. 권고 우선순위

1. **HIGH**: PR-B (#14718) flag=true soak 시 `lib/sse.ml:832` TOCTOU 검증. cross-Domain `Stream.length` 안전성 확인. 별도 PR 으로 spec 추가 또는 try/catch 강화.
2. **MEDIUM**: 측정 우선 — `/dashboard/keeper/list` 응답 p95 + 메모리 측정. > 200KB 또는 p95 > 500ms 이면 streaming 도입.
3. **LOW**: 코드 변경 즉시 가능한 streaming 후보 없음. 모든 대형 응답이 비즈니스 로직 마지막에 `to_string` 호출 — refactor 가 광범위.

## 6. 본 audit 의 코드 변경

없음. audit-only doc. 측정 기반 follow-up PR 으로 진행.

## 참고 자료

- `lib/sse.ml:826-873` SSE backpressure 로직
- `lib/server/server_h2_gateway_helpers.ml:1-50` h2_respond_* helpers
- RFC-0059 §10 Tier A Integration risk table
- eio 1.2 [Stream docs](https://ocaml-multicore.github.io/eio/eio/Eio/Stream/index.html)
- eio 1.2 [multicore.md](https://github.com/ocaml-multicore/eio/blob/main/doc/multicore.md)
