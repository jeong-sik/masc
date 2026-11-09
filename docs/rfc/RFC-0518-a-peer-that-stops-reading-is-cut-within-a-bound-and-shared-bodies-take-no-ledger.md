---
rfc: "0518"
title: "읽기를 멈춘 상대는 정해진 시간 안에 끊고, 바뀌지 않는 본문은 원장 없이 보낸다"
status: Draft
created: 2026-11-09
updated: 2026-11-09
author: claude
supersedes: []
superseded_by: null
related: ["0512", "0493", "0350"]
---

# RFC-0518: 읽기를 멈춘 상대는 정해진 시간 안에 끊고, 바뀌지 않는 본문은 원장 없이 보낸다

- 상태: 초안.
- 이슈: #50294(원장 고갈), #50295(생산자 수명), #50296(TLS 처리량), #49905(연결 준비 상한).
- 근거: 조사는 `docs/research/2026-11-09-h2-sse-stalled-responses-and-tls-writes.md`, 실측 기록은 `docs/evidence/research/2026-11-09-h2-sse-tls/` 다. 코드 좌표는 `origin/main` `1cab54b0abea` 에서 읽었다.
- 먼저 있는 결정: RFC-0493 이 SSE 프레임을 소켓 flush 까지 기다리게 했다(`Written`·`Closed`·`Stalled`). RFC-0512 가 응답 손잡이를 `Http_reqd.t` 로 합치고 TLS·ALPN 리스너와 HTTP/2 응답 원장을 더했다. RFC-0350 이 HTTP/2 요청 fiber 의 admission 을 정했다. 이 RFC 는 그 위에서 멈춘 상대를 끝내는 방법을 정한다.
- 사용자 요청(2026-11-09): 근본 원인을 고치고, 다른 OCaml 프로젝트가 HTTP/2·SSE 를 다루는 방식을 보고 개선한다.

## 0. 요약

창 0 을 알린 HTTP/2 클라이언트의 SSE 스트림은 정체 상한(코드의 90초)을 넘기면 정체로 판정된다. 그런데 끝나지 않는다. run6 에서는 105초까지 끝나지 않았다. 판정 뒤 masc 는 "남은 바이트를 다 보낸 뒤 닫기"만 할 수 있다. 창이 0 이면 그 조건이 오지 않는다. 그래서 보류한 바이트와 원장 예약은 상대가 움직이거나 연결이 끝날 때까지 남는다(코드 읽기). 읽지 않는 클라이언트 하나는 대시보드 번들 77개로 응답 원장 64 MiB 를 채운다. 그동안 다른 연결의 큰 응답은 모두 503 이다. 연결 준비와 소켓 쓰기에는 시간 상한이 없고, TLS 는 암호문을 4 KiB 씩 쓴다.

이 RFC 는 아홉 가지를 정한다.

1. 멈춘 HTTP/2 스트림은 닫지 않고 RST_STREAM 으로 끊는다. 누가 보낸 RST_STREAM 이든 그 스트림의 switch 를 끝낸다(D1).
2. HTTP/2 스트림 안의 flush 는 90초 안에 답을 받는다. 못 받으면 D1 으로 끊는다(D2).
3. 소유한 통째 본문은 16 KiB 조각으로 쓰고 조각마다 flush 를 기다린다(D3).
4. accept 한 소켓의 쓰기 조각마다 기한을 둔다. 넘기면 연결을 닫는다(D4).
5. 바뀌지 않는 본문은 bigstring 하나를 모든 응답이 참조하고 원장을 쓰지 않는다. 대시보드 정적 asset 이 첫 사용처다(D5).
6. 연결 준비(TLS handshake, 프로토콜 판별, 첫 읽기)는 30초 안에 끝나야 한다(D6).
7. SSE 응답이 생산자 수명을 가진다(D7).
8. TLS 암호문을 TLS 레코드 크기 이상으로 모아 쓴다. 암호 순서는 측정으로 정한다(D8).
9. tls·tls-eio 를 2.1.5 로, x509 를 1.2 로 올린다(D9).

## 1. 결정

### D1. 멈춘 HTTP/2 스트림은 닫지 않고 끊는다

- **스트림을 끊는 함수는 `Http_h2_stream` 에 모은다.** masc 가 `H2.Reqd.report_exn` 을 부르던 일곱 곳이 모두 이 함수를 부른다. 레지스트리 35·56줄, `server_bootstrap_http.ml` 334·335줄, `http_h2_stream.ml` 10줄, `http_reqd.ml` 295줄(원장 거절)과 474줄(`Http_reqd.report_exn`)이다.
  - `report reqd exn` 은 한 스트림에 한 번만 보고한다. `H2.Reqd.error_code` 가 이미 있으면 아무것도 보내지 않는다. 첫 보고가 응답 전 갈래(500)를 탔고 스트림이 아직 열려 있을 때 다시 부르면 h2 는 `failwith "h2.Reqd.report_exn: NYI"` 다(포크 reqd.ml 369줄). 스트리밍·통째 갈래 뒤에는 스트림이 `Closed` 라 다음 보고가 아무것도 하지 않는다(388줄).
  - 아니면 `H2.Reqd.report_exn` 을 부른다. 응답이 시작된 스트림이면 h2 는 본문을 닫고 RST_STREAM(INTERNAL_ERROR)을 보낸다(355줄). RST_STREAM 은 흐름 제어를 받지 않아 창 0 에서도 나간다(RFC 9113 §6.9). 응답 전이면 h2 는 error handler 로 500 을 연다(345줄).
  - 이 호출이 `Eio.Cancel.Cancelled` 가 아닌 예외를 내면 잡아서 warn 으로 남긴다. error handler 는 masc 코드라 예외를 낼 수 있다. 그 예외가 연결의 모든 스트림이 도는 switch 를 실패시키면 안 된다.
  - `reset ~stream_sw reqd cause` 는 보고한 뒤 스트림 switch 를 `Stream_reset cause` 로 실패시킨다(`end_scope`). 보고가 취소돼도 실패시킨다. `Eio.Switch.get_error` 가 이미 있으면 건너뛴다. 이미 실패했거나 끝난 switch 다. 그래서 reset 끼리는 `Eio.Exn.Multiple` 을 만들지 않는다. fork 한 fiber 의 예외와 release hook 의 예외는 지금처럼 합쳐진다(eio exn.ml 96~103줄).
  - 스트림 일이 낸 예외(`Raised`)는 `report_failure` 로 보고하고 error 로 한 번 남긴다. h2 는 응답도 오류도 없는 스트림의 보고만 error handler 에 넘긴다(reqd.ml 345줄). masc 가 다는 error handler 둘(gateway, grpc-direct)은 받은 예외를 스스로 남기므로, 그때는 여기서 남기지 않는다. 응답이 시작된 뒤에는 h2 가 error handler 없이 스트림을 끊는다. 그 예외는 여기서 남기지 않으면 아무도 남기지 않는다.
  - 스트림 switch 가 없는 두 곳은 switch 를 끝내지 않고 보고한다. frame tap 이 스트림 번호를 주지 못한 요청은 `report` 로 보고만 한다(`serve_h2_connection`). switch 가 끝난 뒤 그 위 fiber 가 낸 예외는 레지스트리 `dispatch` 가 `report_failure` 로 보고하고 error 로 남긴다.
  - peer 가 보낸 RST_STREAM 과 h2 가 쓴 RST_STREAM 에는 보고하지 않고 switch 만 끝낸다. RST_STREAM 에 RST_STREAM 으로 답하지 않는다(RFC 9113 §5.4.2).
- **응답 전에 보고하면 오류 응답이 스트림을 가진다.** h2 는 error handler 로 응답을 연다. 그 응답의 END_STREAM 이 레지스트리로 범위를 끝낸다. h2 는 오류 응답 뒤에 RST_STREAM 을 하나 더 쓰고, 그것도 범위를 끝낸다. 코드는 저장한 오류 코드(INTERNAL_ERROR)이고, 요청이 열려 있든 반쯤 닫혔든 같다(reqd.ml 456~457줄). 그래서 `Raised`·`Out_of_capacity` 는 이때 switch 를 실패시키지 않는다. 먼저 끝내면 D2 의 `Stream_end` 가 그 응답의 flush 에 `` `Closed `` 로 답한다. 창이 본문보다 작으면 h2#278 처럼 본문이 잘린다. `Stalled` 는 이때도 끝낸다. 멈춘 것이 바로 그 응답이다.
  - 오류 응답인지는 응답과 오류 코드가 둘 다 있는지로 가린다. h2 가 아직 보내는 응답은 보고를 받으면 끊긴다. 통째 본문도 같다(reqd.ml 355~364줄). 그러면 스트림이 `Closed` 라 응답이 없다. h2 가 `Complete` 로 표시한 응답은 보고를 무시하고 오류 코드도 두지 않는다(370줄). 두 경우 모두 그 범위는 바로 끝낸다.
- **라우트의 예외는 ingress 가 응답 상태를 보고 처리한다.** `Server_http_ingress` 가 라우트의 예외를 잡으므로, 그 예외는 `dispatch` 까지 올라가지 않는다. ingress 는 `Http_reqd.response_state` 로 처리를 고른다.
  - `Not_started`: 500 으로 답하고 예외를 error 로 남긴다. `Auth.Auth_config_error` 는 지금처럼 503 으로 답한다.
  - `Streaming_open`: `Http_reqd.report_exn` 으로 끊는다. HTTP/2 는 `reset (Raised exn)` 이다. HTTP/1.1 은 본문을 멈추고 그 응답 뒤 연결을 닫는다. chunked 본문은 마지막 chunk 가 빠져 잘린 것이 보인다. 길이 없이 `connection: close` 로 끝을 알리는 본문(masc 의 SSE 응답들)은 끝난 것처럼 보인다(httpun reqd.ml 228~230줄, body.ml 195~199줄). 이미 나간 헤더 뒤에는 500 을 쓸 수 없다. 이 갈래가 없으면 h2 는 그 500 을 `response already started` 로 거절하고, 스트림은 상대가 끊거나 연결이 끝날 때까지 열려 있다.
  - `Answered`: 예외만 error 로 남긴다. 라우트가 writer 를 닫은 뒤 낸 예외도 여기다. 닫기 전에 쓴 바이트는 그대로 나간다.
  - 늦은 응답 모양(`Http_reqd.Late_response`)은 `Streaming_open` 이 아닐 때 지금처럼 warn 으로 남긴다.
  - `Http_reqd` 는 `respond_with_streaming` 이 연 writer 를 기억한다. 두 라이브러리 모두 그 writer 를 돌려주지 않는다.
- **내보낸 RST_STREAM 도 스트림을 끝낸다.** frame tap 은 나가는 RST_STREAM 과 END_STREAM 을 이미 가른다(`server_h2_frame_tap.ml` 197·198줄). 나가는 RST_STREAM 이면 레지스트리가 그 항목을 지우고 스트림 switch 를 `Stream_reset Reset_by_us` 로 실패시킨다(같은 조건).
  - 아직 범위를 열지 않은(`Admitted`) 항목도 지운다. 그 fiber 는 일을 건너뛴다. 지우지 않으면 handler 가 닫힌 스트림에서 `H2.Reqd.request` 의 `assert false`(reqd.ml 107줄)를 만난다.
  - h2 가 스스로 보낸 stream error, masc 의 reset, 완결한 응답 뒤의 RST_STREAM(NO_ERROR, reqd.ml 443~452줄)이 같은 길로 끝난다. frame tap 은 오류 코드를 읽지 않는다. 마지막 경우는 응답이 이미 끝났으므로 남은 fiber 를 취소한다. gRPC 리스너도 같은 연결 함수를 쓴다(`server_grpc_listener.ml` 49줄).
  - 지금은 daemon 이 아닌 fiber 가 flush 를 기다리면, 정체 감시(90초)가 끝낼 때까지 switch 가 풀리지 않는다(추정).
- **reset 이유는 타입 하나다.** `Peer_reset_stream` 을 지우고 `Http_h2_stream.Stream_reset of reset_cause` 로 합친다. `Http_h2_stream.dispatch` 가 예외를 reset 하므로 타입은 그 모듈에 둔다. `Http_reqd` 는 그 위에 있다.

  ```ocaml
  type reset_cause =
    | Reset_by_peer
    | Reset_by_us
    | Stalled
    | Out_of_capacity of Http_h2_response_ledger.refusal
    | Raised of exn
  ```

  `Raised` 는 스트림 일 자체가 낸 예외다. 요청 handler, 미룬 본문 콜백, 스트림 switch 에 fork 한 fiber 가 낸다. 레지스트리 `dispatch` 는 `Stream_reset _` 를 조용히 받는다. `peer_reset` 도 `get_error` 가 있으면 건너뛴다.
- **끝난 스트림에는 응답을 열지 않는다.** `respond_*` 는 스트림이 끝났으면 h2 를 부르지 않고 닫힌 writer 를 돌려준다. `Body_writer` 에 생성자 `Ended` 를 더한다. 쓰기는 버리고, flush 는 `` `Closed `` 로 답하고, `is_closed` 는 true 다. masc 가 아는 끝(reset, 내보낸 RST_STREAM, peer 의 RST_STREAM)에서는 h2 의 `Assert_failure`(reqd.ml 276줄)가 새지 않는다.
- **h2 안에서 끊은 스트림은 RST_STREAM 바이트가 소켓을 떠난 뒤에야 안다.** h2 의 stream error 는 `Stream.reset_stream` 을 바로 부른다(server_connection.ml 138~140줄). 상태는 바로 `Closed` 이고 `error_code` 는 그대로다. frame tap 은 `single_write` 뒤에 그 프레임을 본다.
  - 그 사이에 handler 가 `respond_*` 를 부르면 `assert false`(reqd.ml 276줄)다. 예: handler 가 일하는 동안 상대가 자기 자신에 의존하는 PRIORITY 를 보낸다(server_connection.ml 788~793줄).
  - 소켓이 막혀 있으면 RST_STREAM 이 나가지 않아 그 사이가 끝나지 않는다.
  - 이 `Assert_failure` 는 `Raised` 로 그 스트림만 끝낸다. 닫힌 스트림의 보고는 아무것도 하지 않는다(reqd.ml 388줄).
  - h2 의 공개 `Reqd` API 에는 닫힘을 묻는 함수가 없다. 근본 해결은 포크가 `Reqd.is_closed` 를 공개하는 것이다(§7.3).
- **끝까지 오지 않은 HTTP/1.1 요청 본문은 라우트에 넘기지 않는다.** httpun 은 보고로 끊은 본문도 다 읽은 본문처럼 닫는다. 기다리던 읽기는 받은 데까지로 끝을 본다. 그래서 `Http_reqd.read_body` 가 본문이 다 왔는지 직접 가린다.
  - 길이가 있는 본문은 그 길이만큼 왔는지 본다. 길이는 httpun 파서가 읽는 기준(`Httpun.Request.body_length`)이다.
  - chunked 본문은 보고의 흔적을 본다. masc 의 `report_exn` 은 표시를 남기고, 응답 전 httpun 의 보고는 오류 코드를 남긴다.
  - httpun 이 응답 뒤에 스스로 끊은 chunked 본문은 흔적이 없어 그대로 넘어간다. 근본 해결은 httpun 읽기에 h2 처럼 완료 상태를 두는 것이다.
- **HTTP/1.1 에는 끊을 스트림이 없다.** `Httpun.Reqd.report_exn` 은 본문을 force-close 하고 연결을 non-persistent 로 만든다. chunked 본문이면 마지막 chunk 를 보내지 않는다. 연결 종료로 끝을 알리는 본문은 끝난 것처럼 보인다. 막힌 소켓 쓰기는 풀지 못한다. httpun 은 흐름 제어가 없고 flush 답은 소켓 쓰기 뒤에 온다. 그래서 HTTP/1.1 의 정체는 TCP 정체이고 D4 가 소켓을 닫는다.

### D2. HTTP/2 스트림 안의 flush 는 정체 상한 안에 답을 받는다

- **상한은 90초다.** 스트림의 flush 하나가 90초 안에 답을 받지 못하면 D1 으로 끊는다(`Stalled`). 요청 경로를 warn 한 줄로 남긴다.
- **`Stream_end` 는 레지스트리가 스트림마다 만든다.** 지금은 `Http_reqd.of_h2` 가 만든다(`http_reqd.ml` 121줄). 레지스트리가 스트림 switch 를 열 때 만들고, 감시 daemon 하나를 그 switch 에 둔다. daemon 은 switch 를 붙잡지 않는다.
- **`Stream_end` 를 fiber-local 로 묶는다.** `Eio.Fiber.with_binding` 은 fork 한 fiber 에도 이어진다(eio 1.3 `eio__core.mli` 387~394줄). 그래서 스트림 fiber 에서 건 flush 가 모두 여기 걸린다.
  - `Http_reqd` 의 writer flush
  - masc 가 스트림 fiber 에서 보고해 연 오류 응답의 `Http_h2_stream.close_after_flush`(gateway error handler, `server_h2_gateway.ml` 25줄)
  - 요청 본문 콜백을 스트림 switch 로 미루는 `Http_h2_stream.dispatch`(`http_reqd.ml` 421줄). 이 fork 는 연결 reader fiber 에서 일어나므로 원장처럼 명시적으로 다시 묶는다.
- **`Http_reqd.of_h2` 는 레지스트리가 만든 `Stream_end` 를 인자로 받는다.** 묶이지 않았을 때 쓸 기본값을 만들지 않는다. 레지스트리 없이 gateway 나 `of_h2` 를 부르는 시험(예: `test_dashboard_http_core.ml` 4983줄)은 L2b 에서 레지스트리를 거치게 고친다.
- **원장의 flush 는 `Stream_end` 를 거치지 않는다.** 원장은 h2 의 flush 를 바로 건다(`http_h2_response_ledger.ml` 69줄). 그 예약은 범위가 끝날 때 `with_request` 의 release hook 이 푼다(52~60줄). 그래서 D1 이 범위를 끝내면 예약도 풀린다.
- **h2 가 연결 reader fiber 에서 여는 오류 응답은 masc 범위 밖이다.** 프레임 해석 중 오류에 h2 는 reader fiber 에서 error handler 를 부른다(server_connection.ml 157~160줄). 그 `close_after_flush` 에는 `Stream_end` 가 묶이지 않는다. 본문은 고정 진단 문구 하나다(`server_h2_gateway.ml` 17~24줄). 창을 열지 않는 상대가 쥐는 이 응답은 연결 단위 상한(§7.4)에 맡긴다.
- **SSE `send` 의 자체 타이머는 HTTP/1.1 에서만 돈다.** HTTP/2 에서 같은 상한의 타이머 둘이 겨루지 않는다. 로그 스트림의 자체 send 와 정체 판정은 지우고 `Server_sse_response` 를 쓴다.
- **상한은 lib/ 의 상수 하나다.** 값은 지금과 같은 90초다. `sse_stalled_after_s`(`server_mcp_transport_http_headers.ml` 294줄), `observer_idle_timeout_ms`(299줄), 로그 스트림의 `stalled_after_s` 가 이 상수를 쓴다. `server_mcp_transport_http_agui.ml` 16줄의 따로 적은 `30.0` 은 `sse_ping_interval_s` 로 바꾼다. 핑 간격(30초)은 상한보다 짧아서 읽는 클라이언트는 상한 안에 늘 프레임을 받는다.

### D3. 소유한 통째 본문은 16 KiB 조각으로 쓴다

- **조각 크기는 16 KiB 다.** 기본 `SETTINGS_MAX_FRAME_SIZE` 의 DATA 프레임 하나다. 선 위에서는 프레임 헤더 9 B 를 더해 16,393 B 라 TLS 레코드(평문 최대 16,384 B) 둘에 걸친다.
- **원장 예약은 지금처럼 본문 전체다.** 원본 문자열이 응답이 끝날 때까지 메모리에 있기 때문이다. h2 에 들어가는 사본은 16 KiB 이하가 된다.
- **헤더를 보낸 뒤 스트림 switch 의 fiber 가 조각을 쓴다.** 조각마다 flush 를 기다린다(D2 상한). 마지막 조각 뒤 본문을 닫고 예약을 푼다. 조각 하나에 들어가는 본문은 지금처럼 바로 쓴다.
- **MCP POST 결과도 같은 길로 간다.** `safe_respond_chunked`(`server_mcp_transport_http.ml` 58~62줄)의 HTTP/2 쪽이다. 지금은 큰 결과를 flush 하나로 기다린다. D2 를 그대로 걸면 천천히 읽는 정상 클라이언트가 90초에 끊긴다.
- **큰 SSE 프레임도 조각으로 쓴다.** `stream_post_sse_json` 은 tools/call 결과 전체를 프레임 하나로 보낸다(`server_mcp_transport_http.ml` 175~177줄). 지금 HTTP/2 의 `Stalled` 는 `close_after_flush` 만 불러서(`server_sse_response.ml` 87~95줄) 느린 클라이언트도 프레임 전체를 받는다. D2 를 그대로 걸면 50 KB/s 로 읽는 클라이언트가 5 MB 결과를 90초에 잃는다. 그래서 `Server_sse_response.send` 의 HTTP/2 쪽도 16 KiB 조각마다 flush 를 기다린다.
- **헤더를 보내기 전의 예외는 지금처럼 예약을 풀고 다시 낸다.** `http_reqd.ml` 231~249줄은 예약한 뒤 `H2.Reqd.respond_with_streaming` 을 부른다. `error_code` 가 이미 있으면 h2 는 헤더를 쓰기 전에 `currently handling error` 를 낸다(reqd.ml 280~285줄). 그때 예약을 풀지 않으면 최대 32 MiB(`tool_blob_store.ml` 343줄)가 응답 없이 남는다.
- **헤더를 보낸 뒤의 예외는 D1 reset 으로 끝낸다.** 그 자리의 `release; raise` 만 지운다.

### D4. 연결 쓰기 상한

- **`Server_connection_socket` 이 accept 한 소켓을 감싼다.** 평문·TLS, HTTP/1.1·HTTP/2 모두다. TLS 는 이 감싸개 위에서 돈다. `Tls_eio.server_of_flow` 가 받는 소켓이 이 감싸개다(`server_bootstrap_http.ml` 484줄). tls-eio 위의 `Tls_stream_socket` 은 이 자리가 아니다.
- **쓰기 조각마다 기한을 하나 건다.** 한 번에 넘기는 쓰기를 256 KiB 이하로 나눈다. 조각 하나의 쓰기 루프 전체가 D2 와 같은 90초 안에 끝나야 한다.
- **기한을 넘기면 연결을 닫는다.** `SO_LINGER 0` 을 걸고 양방향 shutdown 한다. 그 쓰기와 뒤의 모든 쓰기는 `End_of_file` 을 낸다. 읽기는 EOF 를 본다.
- **EPIPE·ECONNRESET 도 `End_of_file` 로 바꾼다.** gluten 은 `End_of_file` 만 `` `Closed `` 로 바꾸고 writer 를 drain 한다(gluten_eio.ml 47줄). 다른 예외는 `report_exn` 으로 가서 flush 콜백이 오지 않는다(조사 §2.1).
- **서버가 보내기 쪽을 닫은 뒤에도 같은 상한을 둔다.** 그 안에 상대가 닫지 않으면 양방향을 닫는다. gluten 의 마지막 EOF 읽기에는 기한이 없다(gluten_eio.ml 122~145줄).
  - TLS 연결에서는 감싸개가 이 shutdown 을 보지 못한다. tls-eio 의 `shutdown` 은 close_notify 만 쓰고 아래 flow 를 닫지 않는다(tls_eio.ml 177~185줄). `Tls_stream_socket.shutdown` 도 tls 로만 넘긴다(tls_stream_socket.ml 11줄).
  - 그래서 TLS 의 이 상한은 `Tls_stream_socket.shutdown` 에서 건다.
- **gRPC 리스너의 accept 루프는 D4·D6 밖이다**(`server_grpc_listener.ml` 40~57줄). D1 의 변화는 닿는다(§7.9).

### D5. 바뀌지 않는 본문은 참조로 보내고 원장을 쓰지 않는다

- **공유 본문 타입을 둔다.** `Shared_body.t` 는 만든 뒤 바꾸지 않는 bigstring 을 감싼 추상 타입이다. `Bigstringaf.t` 의 `private` 약칭은 쓰지 않는다. `:>` 로 변환하면 바이트를 고칠 수 있다. 바이트는 이 모듈 안에서만 h2·httpun 에 넘긴다.
- **`Http_reqd.respond_with_shared` 를 더한다.**
  - HTTP/1.1 은 bigstring 을 복사 없이 건다.
  - HTTP/2 는 16 KiB `schedule_bigstring` 조각으로 보내고 조각마다 D2 상한을 건다. h2 는 이 bigstring 을 복사하지 않는다(h2.mli 385줄).
  - 요청마다 생기는 사본이 없으니 원장 예약도 없다.
- **대시보드 정적 asset 이 첫 사용처다.**
  - 읽을 때마다 receipt 와 digest 를 검증하는 계약은 그대로다(`lib/installed_dashboard.mli` 29줄).
  - 검증한 (경로, sha256) 의 표현 셋(identity, zstd, gzip)을 캐시에서 꺼내 보낸다. 캐시는 경로마다 한 항목이고 digest 가 바뀌면 바꾼다.
  - 압축은 asset 판마다 한 번이다. 지금은 `accept-encoding` 을 보낸 요청마다 압축한다(`server_routes_http_pages.ml` 253~255줄).
  - `Installed_dashboard.load` 는 요청마다 파일 전체를 읽는다(mli 28~31줄). 그래서 요청마다 사본 하나와 sha256 계산은 남는다. 그 사본은 검증 뒤 버리고, 응답은 공유 본문만 쥔다.
- **#50294 의 측정 장면에서 원장 사용량이 0 이 된다.** 번들 77개를 쥔 클라이언트는 원장을 쓰지 않는다. cloudflared 연결 안의 다른 원격 사용자도 막지 않는다.

### D6. 연결 준비는 30초 안에 끝나야 한다

- 상한을 거는 곳: TLS handshake(`server_bootstrap_http.ml` 484줄), 평문 프로토콜 판별(391줄), HTTP/1.1 전용·h2c 리스너의 첫 읽기.
- 기한을 넘기면 연결을 닫고 리스너의 handshake 실패 카운터를 올린다(TLS 일 때).
- 근거: piaf `accept_timeout` 30 s, nginx `client_header_timeout` 60 s. Go 는 `ReadTimeout`·`ReadHeaderTimeout`·`WriteTimeout` 중 양수 최솟값을 handshake 에 건다(조사 §2.3, §3.1).

### D7. 응답이 생산자 수명을 가진다

- `Server_sse_response.serve ~sw t produce` 를 더한다. 생산자를 `await_closed t` 와 겨루게 하고, 어느 쪽이 먼저 끝나든 응답을 닫는다.
- 생산자는 호출자의 switch 에 fork 하고, 그 fiber 안에 응답마다 자식 switch 를 연다. pump 가 이렇게 돈다(`server_mcp_transport_http_conn.ml` 313~331줄). 스트림 switch 로 옮기지 않으므로 생산자가 스트림 switch 를 붙잡는 순환 대기가 없다.
- 호출자의 switch 에는 hook 을 걸지 않는다. 그 switch 는 서버 수명이다(`server_routes_http.ml` 9·42줄). eio 는 `on_release` hook 을 switch 가 끝날 때까지 쥔다(eio switch.ml 101~111줄). 응답마다 걸면 서버가 끝날 때까지 쌓인다.
- fork 하기 전에 `Switch.get_error` 를 본다. 이미 끝나는 중이면 응답만 닫는다. 응답을 닫는 cleanup 은 자식 switch 의 `on_release` 에 건다.
- 쓰는 곳은 셋이다: 로그(`server_routes_http_routes_log_stream.ml`), 문서 초안(`server_routes_http_routes_artifact_draft_live.ml`), 실행 출력(`server_routes_http_routes_dashboard.ml` `handle_execute_output_stream`).

### D8. TLS 쓰기 조각과 암호 순서

- **쓰기 조각.** D4 감싸개의 `copy` 가 tls-eio 의 암호문을 버퍼로 읽어 쓴다.
  - 첫 버퍼는 TLS 1.3 레코드 하나(16,384 + 22 B)다. 그것이 차면 256 KiB 버퍼를 쓴다.
  - 버퍼는 `copy` 호출마다 만든다. tls-eio 는 쓰기 잠금이 없고 읽기 경로도 쓸 수 있다. 연결마다 버퍼 하나를 나눠 쓰면 안 된다.
  - 코드에 `WORKAROUND` 주석과 upstream 이슈 링크를 단다. 근본 해결은 tls-eio `write_t` 가 암호문을 `single_write` 로 바로 쓰는 것이다. upstream 이슈를 쓰기 전에 사용자에게 묻는다.
- **암호 순서.** 이 arm64 빌드는 `Mirage_crypto.accelerated` 가 빈 목록이다.
  - 후보: `accelerated` 에 `AES` 와 `GHASH` 가 둘 다 있으면 기본 순서, 아니면 ChaCha20-Poly1305 를 먼저 둔다.
  - 벤치(OpenSSL 클라이언트)에서 ChaCha20 의 이득은 조각 크기에 달렸다. 서버 CPU 는 16 KiB 조각에서 0.9%, 64 KiB 이상에서 23~32% 적었다. 서버와 클라이언트를 합치면 16 KiB 에서 10.9% 더 비쌌다.
  - cloudflared 는 같은 호스트에서 Go `crypto/tls` 로 복호화한다. 그래서 D8 층은 Go 클라이언트로 masc 와 클라이언트의 CPU 합을 잰다. 합이 줄지 않으면 이 층은 쓰기 조각만 바꾼다.

### D9. tls·tls-eio 2.1.5, x509 1.2

- 2.1.2 뒤에 고쳐진 것 중 이 리스너와 닿는 것: 조작한 상대가 일으키는 메모리 누수(mirleft/ocaml-tls#540, v2.1.5), 16 KiB 경계의 빈 레코드(#539, v2.1.5), 중복 SupportedVersion 으로 서버가 멈추는 일(#531, v2.1.4).
- tls 2.1.4 부터 opam 제약이 x509 1.2.0 이상이다. 1.2 의 `CN` 생성자는 문자열 대신 `Common_name.t` 를 받는다.
- 고칠 파일: `lib/server/server_tls_material.ml` 87줄, `packages/agent_core/test/test_tls_cancellability.ml` 32줄, `masc.opam`(41~42줄의 tls·tls-eio 하한), `dune-project`(112~113줄의 하한, 126~129줄의 상한 주석과 제약), `masc.opam.locked`.
- D8 보다 먼저 낸다. D8 은 2.1.5 위에서 재고, 2.1.5 의 `write_t` 를 다시 읽는다.

## 2. 지금 모습

조사 §1 이 줄 번호로 적었다. 결정과 닿는 것만 다시 적는다.

| 자리 | 지금 | 이 RFC 뒤 |
|---|---|---|
| 정체 판정 뒤 HTTP/2 | `close_after_flush` 가 오지 않는 flush 를 기다린다 | RST_STREAM 을 보내고 스트림 switch 를 끝낸다 |
| masc·h2 가 보낸 RST_STREAM | `response_ended` 만 풀린다. switch 는 안의 fiber 를 기다린다 | switch 가 실패해 그 안의 fiber 가 취소된다. switch 밖에서 기다리던 flush 는 `Stream_end` 로 `` `Closed `` 를 받는다(D2) |
| 통째 본문 | 본문 전체를 h2 에 한 번에 복사하고 flush 하나를 기다린다. 시간 상한 없음 | 16 KiB 조각, 조각마다 90초 |
| 대시보드 asset | 요청마다 읽고, `accept-encoding` 이 있으면 압축하고, 사본을 원장에 넣는다 | 요청마다 검증하고, 압축본 하나를 참조로 보낸다 |
| 로그·초안·실행 출력 생산자 | 다음 이벤트나 핑까지 산다 | 응답이 닫히면 바로 끝난다 |
| 소켓 쓰기 | 기한 없음 | 256 KiB 조각마다 90초 |
| TLS handshake·평문 첫 읽기 | 기한 없음 | 30초. TLS handshake 뒤의 첫 읽기는 그대로다(§7.4) |
| TLS 쓰기 | 암호문 4 KiB 마다 `writev` | 레코드 하나, 그 뒤 256 KiB 버퍼 |

## 3. 왜 이 모양인가

### 3.1 h2 포크를 먼저 고치지 않는다

`on_close_stream` 에서 응답 본문을 닫고 drain 하면 reset 때 flush 가 `` `Closed `` 로 끝난다. 원인 자리를 고치는 방법이다. 하지만 그 스트림의 DATA 가 연결 writer 에 남아 있으면 faraday 의 `assert (written = 0)`(faraday.ml 378줄)에 걸린다(추정). 그리고 h2 에는 timer 가 없다. 창을 안 여는 상대를 끊는 판단은 어차피 masc 몫이다. D1 은 지금 공개 API(`report_exn`, `error_code`, `response`)만 쓴다. 포크 정리는 따로 남긴다(§7).

### 3.2 연결별 원장 몫을 두지 않는다

한 연결이 원장의 일부만 쓰게 하면 연결 사이는 갈린다. 하지만 cloudflared 는 원격 사용자를 origin 연결 몇 개에 모은다. Go HTTP/2 Transport 는 연결의 동시 스트림 한도를 넘을 때만 연결을 더 연다(x/net http2 `StrictMaxConcurrentStreams` 기본 false). 그래서 연결 몫은 원격 사용자를 가르지 못한다(추정). 몫이 원장의 절반이면 32 MiB artifact(`Tool_blob_store.max_served_bytes`)가 다른 응답과 같이 못 들어간다. 측정 장면의 원인은 같은 불변 파일의 사본 77벌이다. D5 가 그 사본을 없앤다.

### 3.3 상한은 조각마다 둔다

| 모양 | 예 | 맞지 않는 이유 |
|---|---|---|
| 스트림 전체 시간 | Go `WriteTimeout` | SSE 는 오래 산다. Envoy edge 예시도 스트리밍에는 끄라고 적는다 |
| 진척이 있으면 연장 | nginx `send_timeout`, Go `WriteByteTimeout` | HTTP/2 bomb 가 1바이트 WINDOW_UPDATE 로 피한다 |

조각 하나가 기한 안에 다 나가야 한다는 규칙은 1바이트 WINDOW_UPDATE 로 늘어나지 않는다. 대가는 최소 배출 속도다. 16 KiB 조각에 90초면 182 B/s 다(§5).

### 3.4 RST_STREAM 코드는 INTERNAL_ERROR 다

정체로 끊는 스트림에는 CANCEL 이 더 맞다. h2 의 공개 API 는 `report_exn` 하나이고 INTERNAL_ERROR 를 보낸다(포크 reqd.ml 390줄). 코드를 바꾸려면 포크를 고쳐야 한다. 두 코드를 다르게 다루는 클라이언트가 있는지는 확인하지 않았다. 지금 API 를 쓰고, 코드는 포크 정리(§7)에서 다시 본다.

### 3.5 TLS 쓰기는 masc 감싸개에서 고친다

upstream tls-eio main 도 같은 4 KiB 경로다(조사 §1.8). 릴리스를 기다리지 않고 D4 감싸개의 `copy` 에서 모아 쓴다. 벤치에서 AES-128 서버 CPU 가 MB 당 41~45% 줄었다(조사 §4.4). 우회이므로 WORKAROUND 주석과 근본 해결을 적는다.

## 4. 운영자에게 보이는 변화

- 창을 열지 않거나 읽지 않는 HTTP/2 클라이언트의 스트림은 90초 뒤 RST_STREAM(INTERNAL_ERROR)을 받는다. 서버 로그에 경로가 든 warn 한 줄이 남는다.
- handler 가 응답 도중 예외를 내거나 h2 가 스트림을 끊으면, 그 스트림에서 돌던 남은 일(본문 생산자, 미룬 본문 콜백)이 바로 취소된다. 완결한 응답 뒤 h2 가 RST_STREAM(NO_ERROR)을 보낼 때도 같다.
- 라우트가 스트리밍 응답 도중 예외를 내면, HTTP/2 스트림은 RST_STREAM(INTERNAL_ERROR)을 받고 HTTP/1.1 연결은 닫힌다. chunked 본문은 마지막 chunk 가 빠진다. masc 의 HTTP/1.1 SSE 는 연결 종료로 끝을 알리므로, 클라이언트에게는 끝난 스트림처럼 보인다. 전에는 스스로 닫지 않는 라우트의 응답이 열린 채 남았다. 라우트 예외는 error 로 한 번 남는다(늦은 응답 모양은 지금처럼 warn). 응답 전 예외는 전에는 500 본문에만 있었다.
- HTTP/1.1 클라이언트가 요청 본문 도중 떠나면 라우트는 받은 데까지의 본문으로 돌지 않는다. httpun 이 400 으로 답한다. 전에는 잘린 본문이 온전한 본문처럼 라우트에 넘어갔다.
- 소켓 쓰기가 90초 동안 끝나지 않는 연결은 닫힌다. 먼저 shutdown 이 FIN 을 보낸다. 연결을 놓으며 fd 를 닫을 때(`server_bootstrap_http.ml` 122~133줄) `SO_LINGER 0` 이라 RST 가 간다.
- TLS 연결은 handshake 가 30초 안에 끝나지 않으면 닫힌다. 평문 연결은 30초 안에 첫 바이트를 보내지 않으면 닫힌다. TLS handshake 뒤의 첫 읽기에는 기한이 없다(§7.4).
- 대시보드 asset 응답은 원장을 쓰지 않는다. 압축은 asset 판마다 한 번 한다.
- TLS 처리량과 서버 CPU 가 바뀐다. 설치 뒤 같은 탐침으로 잰 값을 기록한다.
- 설정 칸은 더하지 않는다. 상한은 코드 상수다.

## 5. 알려진 한계

- **연결 창.** 다른 스트림이 연결 창을 다 쓰면 모든 스트림이 늦는다. 그때는 가장 오래 기다린 스트림이 먼저 끊긴다.
- **최소 배출 속도.** 16 KiB 조각에 90초면 스트림당 182 B/s 다. 스트림 N 개가 느린 링크 하나를 나눠 쓰면 링크는 N × 182 B/s 를 넘어야 한다. 100개면 18 KiB/s 다.
- **연결 단위 최소 속도.** D4 는 256 KiB 이상이 밀려 있으면 90초에 256 KiB 를 요구한다. 약 2.9 KB/s 다.
- **그 속도 바로 위로 읽는 상대.** 소유 본문의 예약을 오래 쥔다. 861,256 B 본문이면 약 79분이다. D5 가 정적 asset 을 이 경우에서 뺀다. artifact 와 MCP 결과 같은 소유 본문은 인증 뒤에만 받는다.
- **keep-alive HTTP/1.1 이탈.** keep-alive 응답 중에는 쓰기 실패로만 안다. `Connection: close` 응답(masc SSE 대부분)은 gluten 의 마지막 읽기가 FIN 을 보고 본문을 닫는다(조사 §1.6).
- **reset 코드.** INTERNAL_ERROR 하나다(§3.4).
- **h2 안에서 끊은 스트림.** RST_STREAM 바이트가 소켓을 떠난 뒤에야 범위가 끝난다(D1).
- **완결한 응답 뒤의 RST_STREAM(NO_ERROR).** 요청 쪽이 아직 열려 있을 때만 나간다(reqd.ml 443~452줄). 반쯤 닫힌 요청에는 나가지 않는다(453~454줄). 그래서 응답 뒤 스트림 switch 에서 도는 fiber 는 요청 쪽이 열려 있었을 때만 취소된다. frame tap 의 콜백은 gluten 이 h2 에 쓰기를 알리기 전에 돈다(gluten_eio.ml 155~156줄). 그래서 마지막 flush 를 기다리는 fiber 는 바이트가 나간 뒤에도 h2 의 `` `Written `` 보다 먼저 취소되거나 `` `Closed `` 를 받는다. 응답 뒤에 스트림 switch 에서 일하는 masc handler 는 찾지 못했다.
- **응답을 열지 않는 error handler.** gRPC 리스너의 error handler(grpc-direct)는 응답을 열지 않는다. 응답 전에 실패한 스트림은 응답도 RST_STREAM 도 없이 열린 채 남는다. masc 는 다시 보고할 수 없고, h2 에는 다른 reset API 가 없다(#50515).
- **h2 가 다시 보고하는 스트림.** masc 가 보고해 오류 응답이 아직 나가는 중인 스트림에, 클라이언트가 h2 의 보고를 부르는 프레임을 보내면 h2 의 `NYI` 가 연결 전체를 끊는다(#50514).
- **h2 가 reader fiber 에서 연 오류 응답.** 그 응답(400 등)에는 masc 범위와 상한이 없다(D2). 그 스트림의 masc handler 가 응답을 열려다 `currently handling error` 로 예외를 내면, 응답 전 보고 규칙대로 범위는 그 오류 응답이 끝날 때까지 남는다(D1). 쥐는 것은 fiber 하나와 레지스트리 항목이고 원장 예약은 없다(D3). 창을 열지 않는 상대에게는 연결이 끝날 때까지다. 연결 단위 상한(§7.4)이 덮는다.
- **정체한 오류 응답의 끝.** `Stalled` 가 오류 응답을 쥔 범위를 끝내면 `Stream_end` 가 그 본문을 닫는다. 창이 0 이면 h2 는 빈 END_STREAM 과 RST_STREAM(INTERNAL_ERROR)을 보낸다(scheduler.ml 359~370줄, reqd.ml 456·464~500줄). 이것은 h2#278 동작이다. §7.3 에서 #278 을 고치면 이 스트림을 선 위에서 끝낼 길을 포크에 같이 둔다.
- **tls-eio 읽기 경로의 쓰기.** tls-eio 는 읽다가 암호문을 쓸 수 있다(tls_eio.ml 69·74줄). 그 쓰기는 writer 의 조각 사이에 끼어든다. 지금도 그렇다.

## 6. 확인 방법

- 로컬 dune 빌드는 하지 않는다. 타입 검사와 시험 실행은 cmi 스냅샷과 실제 링크 도구로 한다. 전체 빌드와 시험은 CI 가 한다.
- 시험 하네스는 층마다 그 층이 고친다. L2a·L2b 의 시험은 `serve_h2_connection` 을 거치는 하네스(`test_h2_request_fibers.ml`, `test_h2_response_resources.ml`)를 쓴다. L2c 는 `test/test_h2_response_window.ml` 의 메모리 안 h2 펌프를 고친다. 그 펌프는 root switch 를 스트림 switch 로 넘기고, 조각 writer 가 돌 틈을 주지 않는다. 스트림마다 `Switch.run` 을 두고 `Fiber.yield` 나 mock clock 진행을 넣는다.
- 새 시험은 프로토콜·자원 경계만 본다. clock 은 `Eio_mock` 이다.
  - 창 0 SSE 스트림: 상한 뒤 RST_STREAM 이 오고 원장 사용량이 0 이 된다.
  - 응답을 시작한 handler 가 예외를 내면 조각 writer 와 예약이 바로 풀린다.
  - 응답 전에 handler 가 예외를 내면 오류 응답이 끝까지 나가고, 그 뒤 범위가 끝난다.
  - 이미 보고한 스트림을 다시 reset 해도 예외가 나지 않는다.
  - h2 가 스스로 RST_STREAM 을 쓰면 그 스트림 범위가 `Reset_by_us` 로 끝나고, 연결은 다음 요청에 답한다.
  - 창보다 큰 통째 본문: 창을 안 여는 클라이언트는 상한 뒤 RST_STREAM 을 받고, 창을 여는 클라이언트는 본문 전체를 받는다.
  - 큰 MCP POST 결과를 천천히 읽는 클라이언트도 끝까지 받는다.
  - 창 0 에서 연 오류 응답은 상한 뒤 RST_STREAM 으로 끝난다.
  - 공유 본문 응답 둘을 보내는 동안 원장 사용량이 0 이다.
  - 이벤트를 기다리는 생산자는 스트림 reset 과 close 에 바로 취소된다.
  - 소켓 감싸개: `copy` 가 모든 바이트를 순서대로 쓴다. 상대가 안 받는 쓰기는 상한 뒤 `End_of_file` 이고, 뒤 쓰기도 같고, 읽기도 EOF 다(socketpair). 아무것도 안 보내는 연결은 준비 상한 뒤 닫힌다.
  - 음성 대조: reset 함수, 내보낸 RST_STREAM 규칙, 감시 daemon, 조각 기다림을 각각 뺀 변이에서 해당 시험이 실패한다. 내보낸 RST_STREAM 규칙의 시험은 `serve_h2_connection` 을 거친다. h2 가 스스로 스트림을 끊을 때(반쯤 닫힌 스트림의 DATA → STREAM_CLOSED, server_connection.ml 758~764줄) masc fiber 가 기다리고 있어야 한다. 메모리 안 하네스는 frame tap 과 레지스트리를 거치지 않는다(`test_h2_response_window.ml` 99~123줄).
- 설치 뒤 실측. 사용자가 층별 빌드를 설치하고 재시작하면 evidence 묶음의 탐침을 같은 호스트에서 다시 돌린다.
  - `h2_stall_probe.py`: 창을 열기 전(105초 안)에 RST_STREAM 3개가 온다. 지금 탐침은 로그 스트림의 정체 줄("accepted no frame")을 세고 프레임 도착 시각을 적지 않는다. D2 가 그 줄을 지우므로, 탐침이 RST_STREAM 을 도착 시각과 함께 세게 고친다.
  - `ledger_starvation_probe.py`: 번들 90개를 쥔 클라이언트가 있어도 정상 클라이언트의 번들이 200 이다.
  - `h2_sse_leak_probe.py`: descriptor, 연결 수, `sse_clients` 가 지금처럼 제자리로 온다.
  - `tls_cpu_probe.py` 와 벤치: 서버 ms/MB 와 클라이언트(OpenSSL, Go) ms/MB 의 전·후 표를 남긴다.
  - 결과는 `docs/evidence/` 에 새 묶음으로 남긴다.

## 7. 하지 않는 것

아래는 이슈로 따로 남겼다. 8번은 #48907 이 다룬다.

1. 사전 압축 JSON 스냅샷(`Http_response_payload.prepared` 사용처)을 공유 본문으로 옮긴다(#50480).
2. artifact 바이트를 범위 읽기로 바꾼다. 지금은 32 MiB blob 을 요청마다 통째로 올린다(#50481).
3. h2 포크 정리: `on_close_stream` 의 본문 drain, `Reqd.stream_id`·`Reqd.is_closed` 공개(D1), #278 조건 고침으로 `close_after_flush` 와 frame tap 을 지움, #278 을 고칠 때 정체한 오류 응답을 끊을 길(§5), upstream h2#265 이식(#50482).
4. 연결 수, idle, 헤더 시간 상한. TLS 뒤 h2 preface 대기, 여러 연결이 같이 읽지 않을 때의 소유 본문과 descriptor 고갈도 여기 든다. h2 가 reader fiber 에서 연 오류 응답과 그 뒤에 남는 범위(§5)도 여기 든다(#50483).
5. 들어오는 창 2^27(연결당 128 MiB)을 줄인다. Go 는 1 MiB, Envoy edge 권장은 스트림 64 KiB 다(#50484).
6. HTTP/2 DoS 완화: rapid reset(양방향 reset 세기), CONTINUATION, 헤더 개수(#50485).
7. keep-alive HTTP/1.1 스트리밍 중 이탈 감지(#50486).
8. pump 와 HTTP/1.1 생산자의 domain 문제(#48907 의 나머지).
9. gRPC 리스너의 연결 쓰기·준비 상한(D4·D6 밖, #50487).

## 8. 층

worktree `.worktrees/h2-backpressure` 에서 gh stack 으로 쌓는다. 맨 아래가 main 이다. 층마다 Draft 를 열고 현재 head 의 독립 리뷰를 받는다.

| 층 | 브랜치 | 결정 | PR |
|---|---|---|---|
| L0 | `research/h2-sse-stalled-responses` | 조사 문서와 실측 기록 | #50417 |
| L1 | `rfc/0518-stalled-peer-bounds` | 이 RFC | #50428 |
| L2a | `http/h2-stream-reset` | D1: `Http_h2_stream` 의 reset 함수, 내보낸 RST_STREAM 규칙 | |
| L2a2 | `http/h2-ended-writer` | D1 의 나머지: `http_reqd.ml` 의 보고 두 곳(295·474줄), `Ended` writer | |
| L2b | `http/h2-flush-bound` | D2 | |
| L2c | `http/h2-body-slices` | D3, 시험 하네스 | |
| L3 | `deps/tls-2.1.5` | D9 | |
| L4 | `http/connection-socket-bounds` | D4, D6, D8 | |
| L5 | `http/sse-producer-scope` | D7 | |
| L6 | `http/shared-payloads` | D5 | |
