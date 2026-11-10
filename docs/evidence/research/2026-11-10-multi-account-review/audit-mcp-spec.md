> 파생본이다. 원본 조사 보고서를 [README](README.md)에 적은 대로 손질했다.

# MCP 서버 구현을 현재 명세에 대조한 감사

최신 명세는 2026-07-28(stateless)이고, 구현은 legacy와 2026을 함께 받는 dual-era다. 대부분 맞고 틈은 10개다.

## 기준

- 대상: worktree `.worktrees/authz-d1-1-20261108`, head `85b8af5b0453`. 읽기만 했다. 빌드와 테스트는 돌리지 않았다.
- 아래 파일 경로는 모두 저장소 루트 기준 상대 경로다.
- 웹은 모두 2026-11-10에 직접 열었다. 실제로 연 것은 각 URL의 `.md` 판이다.
- 전제 정정: 요청 목록의 session id header, GET stream, Last-Event-ID, DELETE, ping, initialize는 2025-11-25 이하(legacy) 요구다. 2026-07-28은 모두 지웠다.
- 신뢰도: spec facts는 High(원문 직독)다. 판정은 적은 줄을 직접 읽은 것만 썼다. `partial`과 "handler까지 추적" 표기는 Medium이다.
- "(기존 문서에 있음)" 표시는 `docs/research/2026-10-27-mcp-2026-07-28-parity.md`의 "Known gaps"와 겹친다는 뜻이다. 겹치는 범위는 3절 끝에 적었다.

## 1. Spec facts

- 최신 released는 **2026-07-28**이다(`https://modelcontextprotocol.io/specification/versioning`). draft `schema.ts`의 `LATEST_PROTOCOL_VERSION`도 같다(`https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/draft/schema.ts`, WebFetch 요약 기준).
- 2025-06-18(`https://modelcontextprotocol.io/specification/2025-06-18/changelog`): JSON-RPC batch 삭제, structured tool output, resource link, elicitation, 서버 = OAuth resource server(RFC 9728), client RFC 8707 필수, `MCP-Protocol-Version` 헤더 필수.
- 2025-11-25(`https://modelcontextprotocol.io/specification/2025-11-25/changelog`): CIMD(Client ID Metadata Documents), `WWW-Authenticate` scope 단계 상승, URL-mode elicitation, sampling tools, experimental tasks, 잘못된 Origin은 403, JSON Schema 2020-12 기본.
- 2026-07-28(`https://modelcontextprotocol.io/specification/2026-07-28/changelog`):
  - initialize, session, GET stream, `ping`, `logging/setLevel`, SSE 재개를 지웠다.
  - 요청마다 `_meta`에 version과 capability를 싣는다.
  - `server/discover`, `resultType`, `ttlMs`/`cacheScope`, `Mcp-Method`/`Mcp-Name` 헤더가 필수다.
  - `subscriptions/listen`과 MRTR(Multi Round-Trip Requests)이 생겼다.
  - 새 오류는 -32020/-32021/-32022다. resource not found는 -32602로 바뀌었다.
  - tasks는 extension으로 갔다. Roots, Sampling, Logging, DCR(Dynamic Client Registration), HTTP+SSE는 deprecated다.
- draft(`https://modelcontextprotocol.io/specification/draft/changelog`): 그 뒤 변경은 CIMD 참조 draft-03과 일부 `_meta` 복원 둘뿐이다.
- Roadmap(`https://modelcontextprotocol.io/development/roadmap`, 2026-08-22 갱신; `https://blog.modelcontextprotocol.io/posts/mcp-roadmap/`): 다음 release 날짜는 없다. 항목은 서버 발 이벤트(channels, webhooks)와 Tasks core 편입, HTTP over stdio, ETag caching, 표준 오류 처리, DPoP, WIF, token exchange, `tools/call` 결과 재설계, progressive discovery다.
- Not read first-hand: 2025-11-25판 security best practices, progress, cancellation 페이지, SEP 원문, tasks extension 정본.

## 2. Conformance

- 받는 version은 6개다: `2026-07-28`, `DRAFT-2026-v1`, `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`(`lib/mcp_transport_protocol/mcp_transport_protocol.ml:574-584`, SDK `mcp_protocol` 1.3.0, pin은 `masc.opam.locked:111`).
- 모르는 version에 대한 답:
  - legacy `initialize`는 `2025-11-25`로 응답한다(`lib/mcp_transport_protocol/mcp_transport_protocol.ml:640-648`).
  - stateless stdio는 `-32022` + `data.supported`다(`lib/mcp_server_eio_protocol.ml:840-853`).
  - HTTP 헤더는 400 + `-32600`이다(gap 1).

| 영역 | 요구 | 판정 | 근거 |
|---|---|---|---|
| lifecycle | legacy initialize 협상, `server/discover`, 요청별 `_meta`, `resultType`, 지운 method는 -32601 | conforms | `lib/mcp_transport_protocol/mcp_transport_protocol.ml:135-168,194-232`, `lib/mcp_server_eio_protocol.ml:299-318,855-859` |
| lifecycle | 미지원 version은 -32022 | stdio conforms, HTTP deviates | `lib/server/server_http_ingress.ml:93-108` |
| stdio | 줄 단위 JSON, `notifications/cancelled`, EOF 종료 | conforms | `lib/mcp_server_eio_protocol.ml:1594-1620,1751-1762` |
| HTTP | POST 단일 endpoint, 202, JSON 또는 SSE | conforms | `lib/server/server_mcp_transport_http.ml:560-648` |
| HTTP | Origin 검증과 403 | conforms | `lib/server/server_http_ingress.ml:76-92`, `lib/server/server_routes_http_common.ml:58-65` |
| HTTP | version, method, name 헤더 일치(-32020), -32601은 404 | conforms | `lib/server/server_mcp_transport_http_headers.ml:115-195,252-265` |
| HTTP | 연결 종료를 취소로 처리 | missing | `lib/server/server_mcp_transport_http.ml:504` |
| HTTP legacy | 모르는 session 404, GET SSE, Last-Event-ID 재생, DELETE | conforms(handler까지 추적) | `lib/server/server_mcp_transport_http.ml:419-434,722-1234,1256-1347` |
| HTTP legacy | session id 암호학적 안전 | deviates | `lib/mcp_session/mcp_session.ml:5,30-37` |
| listen | ack 먼저, filter, `subscriptionId` | conforms | `lib/mcp_transport_protocol/mcp_subscriptions.ml:63-182` |
| listen | 서버가 닫을 때 신호 | missing | `lib/mcp_transport_protocol/mcp_subscriptions.ml:187`(호출처 0건) |
| authz | Bearer 헤더, 401, token과 audience 검증 | conforms | `lib/server/server_auth.ml:62-91,225-263`, `lib/auth/auth_oauth.ml:1213-1216` |
| authz | PRM(RFC 9728), AS metadata, challenge, scope 단계 상승 | partial(loopback만) | `lib/server/server_oauth_http.ml:46-56`, `lib/server/server_oauth_metadata.ml:74-88`, `lib/server/server_mcp_transport_http.ml:475-501` |
| authz | RFC 8707 `resource`, PKCE S256, redirect 정확 일치, refresh 교체, `iss` | conforms | `lib/auth/auth_oauth.ml:622,662-674,1014-1021`, `lib/server/server_oauth_service.ml:243` |
| authz | CIMD 검증과 SSRF 방어, DCR `application_type` | conforms | `lib/auth/auth_oauth_client_metadata.ml:74,151`, `lib/server/server_oauth_client_metadata_fetch.ml:15`, `lib/server/server_oauth_service.ml:396` |
| authz | query string token 금지 | deviates | `lib/server/server_auth.ml:110-137` |
| tools | 정렬, pagination, cache hint, annotations/outputSchema 전달, result 형태 | conforms | `lib/mcp_server_eio_protocol.ml:385-450`, `lib/mcp_server_eio_call_tool.ml:945-962` |
| tools | 모르는 tool은 -32602 | deviates | `lib/mcp_server_eio_protocol.ml:1234,1292` |
| resources, prompts | list, read, templates, not found -32602, cursor 오류 -32602 | conforms | `lib/mcp_server_eio_resource.ml:493-508`, `lib/mcp_server_eio_protocol.ml:443,475-573` |
| completion, logging, tasks | 선택 기능 | missing(capability도 선언 안 함) | `lib/mcp_server.ml:141-147` |
| ping, progress | legacy ping, `progressToken` | ping conforms, progress deviates | `lib/mcp_server_eio_protocol.ml:972-999`, `lib/progress.ml:35-52` |
| error code | -32020~-32099는 명세 전용, -32002 금지 | deviates | `lib/mcp_error_code.ml:40`, `lib/server/server_mcp_transport_http_respond.ml:144-158` |

- sampling, elicitation, roots, MRTR: 서버가 부르지 않는다(rg 0건). continuation 필드가 오면 -32602다(`lib/mcp_server_eio_protocol.ml:946-952`).
- confused deputy: 서버가 자체 AS(authorization server)라 proxy가 아니다. 동의 화면은 frame을 막는다(`lib/server/server_oauth_service.ml:192-204`).

## 3. Top 10 gaps

상호운용성과 보안 영향이 큰 순서다. 각 항목 끝의 URL이 해당 명세 절이다.

1. **HTTP 미지원 version 응답.** HTTP에서 미지원 `MCP-Protocol-Version`을 ingress가 400 + `-32600`으로 먼저 끊는다. 명세는 `-32022` + `data.supported`다(MUST). 2026 client가 version을 낮춰 다시 시도하지 못한다. HTTP/1.1과 h2 모두 이 ingress를 지난다.
   - 근거: `lib/server/server_http_ingress.ml:93-108`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http`
2. **legacy session id를 맞힐 수 있다.** 형식이 `mcp_<ms>_<pid>_<0~999999>`이고 `Random.State`로 만든다. query `session_id`와 cookie로도 받고, cookie에 HttpOnly와 Secure가 없다. 인증을 켜면 요청마다 token을 먼저 본다(`lib/server/server_mcp_transport_http.ml:357-371`).
   - 근거: `lib/mcp_session/mcp_session.ml:30-37`, `lib/server/server_mcp_transport_http_session.ml:625-672`, `lib/server/server_mcp_transport_http_headers.ml:330-333`
   - 명세: `https://modelcontextprotocol.io/specification/2025-11-25/basic/transports`
3. **access token을 query string으로 받는다.** 대상은 `GET /mcp?sse_kind=observer&token=`과 `/events/presence`다.
   - 근거: `lib/server/server_auth.ml:110-137`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization`
4. **OAuth 발견이 loopback authority에서만 된다.** 다른 host로 오면 PRM(Protected Resource Metadata)과 AS metadata가 404이고, 401 challenge는 `Bearer`뿐이며, scope 단계 상승도 평가하지 않는다. 원격 client는 static bearer만 쓸 수 있다.
   - 근거: `lib/server/server_oauth_http.ml:46-56`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery`
5. **HTTP 요청을 취소할 길이 없다.** 2026은 연결이 끊기면 취소다(MUST). 처리 fiber는 서버 switch에 fork되고, `lib/server/server_mcp_transport_http.ml:290-720`에 끊김과 잇는 코드가 없다. legacy HTTP의 `notifications/cancelled`는 dispatcher가 버린다.
   - 근거: `lib/server/server_mcp_transport_http.ml:504`, `lib/mcp_server_eio_protocol.ml:918-929`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/cancellation`
6. **모르는 tool의 오류 코드.** (기존 문서에 있음) 모르는 tool에 `-32601`을 주고 stateless HTTP에서는 404가 된다. 명세는 `-32602`다. client가 `tools/call` 자체가 없다고 읽을 수 있다.
   - 근거: `lib/mcp_server_eio_protocol.ml:1234,1292`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/server/tools`
7. **listen stream 종료 신호.** (기존 문서에 있음) listen stream을 서버가 닫을 때 신호를 안 보낸다. cancellation 페이지는 `notifications/cancelled`를 MUST로, subscriptions 페이지는 성공 response를 SHOULD로 적는다(두 페이지가 다르다).
   - 근거: `lib/server/server_mcp_listen_stream.ml:44-50`, `lib/mcp_server_eio_protocol.ml:1646-1660`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions`
8. **error code가 명세 범위를 벗어난다.** 기동 중 503에 `-32002`를 쓴다(2026은 emit 금지). 401과 403 body에 `-32001`, `-32007`을 쓴다(legacy 범위, SHOULD NOT). `-32099`는 정의만 있고 보내는 곳은 못 찾았다.
   - 근거: `lib/server/server_mcp_transport_http_respond.ml:144-158`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic`
9. **progress 알림 형식.** `notifications/progress`가 `progressToken` 없이 `taskId`만 담겨 legacy SSE로 broadcast된다. 요청의 `progressToken`은 쓰지 않는다. agent stream 도달은 filter까지만 추적했다.
   - 근거: `lib/progress.ml:35-52`, `lib/server/server_bootstrap_loops.ml:1550`
   - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/progress`
10. **version 표면이 어긋난다.**
    - `supportedVersions`와 `data.supported`에 `DRAFT-2026-v1`이 있다(현재 draft schema에 없다).
    - legacy version을 `_meta`로 보내면 `-32022` 대신 `-32602`다.
    - 헤더가 없으면 2025-03-26이 아니라 2025-11-25로 본다.
    - stdio는 진행 중인 id와 겹치면 오류의 id를 null로 준다(`lib/mcp_server_eio_protocol.ml:1764-1773`).
    - 근거: `lib/mcp_transport_protocol/mcp_transport_protocol.ml:575,591,714`
    - 명세: `https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning`

### 기존 문서와 겹치는 범위

대조한 문서는 `docs/research/2026-10-27-mcp-2026-07-28-parity.md`의 "Known gaps"(29-98줄)다.

- gap 6은 일부만 겹친다. 기존 문서의 "HTTP profile response" 항목은 tool 거절이 404로 나간다는 점을 적었다. JSON-RPC 코드가 `-32602`여야 한다는 점은 없다.
- gap 7은 일부만 겹친다. 기존 문서의 "Notifications and streaming" 항목은 서버가 구독을 닫을 때 성공 response를 안 보낸다는 점을 적었다. cancellation 페이지의 MUST(`notifications/cancelled`)는 없다.
- gap 1, 2, 3, 4, 5, 8, 9, 10은 기존 문서에 없다. 기존 문서의 cancellation 문장은 client transport와 stdio 얘기이고, HTTP 서버가 연결 종료를 취소로 다루는지는 적지 않았다.
- 결론이 같은 항목(gap 아님): 서버는 server-to-client 요청을 보내지 않아 MRTR producer가 필요 없다. HTTP 서버는 `x-mcp-header` mirror를 검증하지 않지만 서버 tool에 그 선언이 없어 지금은 영향이 없다(`lib/server/server_mcp_transport_http_headers.ml:115-195`에 `Mcp-Param-*` 검증 없음, 서버 코드 rg 0건).
- 기존 문서와 다른 점: 기존 문서는 "ordinary stdio requests run synchronously so an in-flight call cannot be cancelled"라고 적었다. 이 head에서는 stdio가 `notifications/cancelled`로 실행 중인 `tools/call`, `resources/read`, `prompts/get`을 취소한다(`lib/mcp_server_eio_protocol.ml:1594-1620,1751-1762`).

## 4. 명세 밖

- transport: WebSocket `/ws`(dashboard 이벤트와 JSON-RPC, 과부하 시 `-32000`), `POST /`, `/mcp/managed`, `/mcp/operator`, `/mcp/play`, stdio Content-Length framing(`lib/mcp_server_eio_protocol.ml:1431,1459-1462`). gRPC provider가 MCP를 싣는지는 미확인.
- header: `x-masc-internal-token`(대체 credential), `x-masc-agent`류, `x-masc-force-json`, `Server-Timing`, `Set-Cookie: mcp-session-id`.
- query: `session_id`, `token`, `sse_kind`, `agent`.
- method와 field: `dashboard/*`, tools/list의 `names`, `include_hidden`, `include_usage`, discover의 top-level `serverInfo`, 모르는 session 404에 싣는 새 `Mcp-Session-Id`.

## 5. Did not read

- `lib/mcp_server_eio_protocol.ml:620-800`, `lib/server/server_mcp_transport_ws.ml` 본문, `lib/server/server_mcp_transport_http_session.ml:40-580`, `lib/auth/auth_oauth.ml:153-510,733-920`.
- `Http_reqd`와 router(405 응답), Log 출력처(stdio stdout 순수성), `Sse.session_kind_matches_target`.
- tool별 `inputSchema`와 이름 규칙, `outputSchema` 검증, POST의 session과 사용자 묶음, 받은 token을 밖으로 넘기는지, 기본 bind host, AS endpoint의 TLS 여부.
