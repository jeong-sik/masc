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
3. 응답 본문은 h2 에 16 KiB 조각 둘까지만 넣는다. 90초는 본문 전체가 아니라 조각에 걸린다. 창이 병목이면 조각 하나, 소켓이 병목이면 쓰기 한 번에 실리는 조각 둘이다(D3).
4. accept 한 소켓의 쓰기 조각마다 기한을 둔다. 넘기면 연결을 닫는다(D4).
5. 바뀌지 않는 본문은 문자열 하나를 모든 응답이 참조하고 원장을 쓰지 않는다. 대시보드 정적 asset 이 첫 사용처다(D5).
6. 연결 준비(TLS handshake, 프로토콜 판별, 첫 읽기)는 30초 안에 끝나야 한다(D6).
7. SSE 응답이 생산자 수명을 가진다(D7).
8. TLS 암호문을 소켓에 바로 쓴다. tls-eio 를 그렇게 고친 포크로 고정한다. 암호 순서는 측정해 보고 그대로 뒀다(D8).
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
  - 닫기는 응답이 끝났다는 라우트의 선언이다. 실패한 라우트는 닫지 않는다. 그래야 예외가 열린 응답과 함께 ingress 에 닿고, `Streaming_open` 갈래가 응답을 끊는다. `Server_sse_response.close_after` 는 라우트가 정상으로 끝날 때만 닫는다. GitHub 로그인 스트림과 계정 로그인 스트림이 `Fun.protect ~finally` 로 닫던 것을 이것으로 바꾼다.
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

- **상한은 90초다.** 기다리는 flush 중 가장 오래된 것이 맨 앞에 선 뒤 90초 안에 답을 받지 못하면 D1 으로 끊는다(`Stalled`). 요청 메서드와 경로를 warn 한 줄로 남긴다. 경로에서는 쿼리를 뺀다. 쿼리에는 토큰이 들 수 있다.
  - 요청은 레지스트리 `dispatch` 가 h2 의 request handler 안에서 한 번 읽어 `Stream_end` 에 넘긴다. h2 는 스스로 닫은 스트림의 요청을 주지 않는다(reqd.ml 100~107줄). 스트림 fiber 는 그 뒤에 돌므로, 요청 lane 선택·`Http_reqd.of_h2`·authority 분류·본문 길이도 h2 에 다시 묻지 않고 `Stream_end.request` 를 읽는다.
  - 맨 앞에 선 때는 그 flush 의 등록과 바로 앞 flush 의 답 가운데 늦은 쪽이다. h2 는 한 본문의 flush 에 오래된 것부터 답한다. 기다리는 flush 뒤에 등록한 flush 는 이 시각을 옮기지 않는다.
  - flush 하나만 기다리면 등록부터 잰다. D3 은 응답 본문을 조각으로 나눠 h2 에 둘까지 넣고, 조각마다 flush 를 건다. 뒤 조각의 90초는 앞 조각이 답을 받은 때부터 잰다. 창을 닫은 상대의 SSE 스트림에 keepalive 를 계속 써도 그 프레임은 앞 프레임 뒤에서 기다릴 뿐이라, 스트림은 첫 프레임부터 90초에 끊긴다.
  - h2 는 flush 에 그 바이트를 소켓에 쓴 뒤에 답한다(body.ml 216~220줄). 그래서 창을 닫아 둔 상대의 스트림도, 소켓을 읽지 않는 상대의 스트림도 상한에 범위가 끝난다. RST_STREAM 은 앞의 상대에게만 닿는다. 막힌 소켓에서는 연결 writer 에 쌓인 바이트 뒤에서 기다리고, 그 연결은 D4 가 닫는다.
- **`Stream_end` 는 레지스트리가 스트림마다 만든다.** 지금은 `Http_reqd.of_h2` 가 만든다(`http_reqd.ml` 121줄). 레지스트리가 스트림 switch 를 열 때 만들고, 감시 daemon 하나를 그 switch 에 둔다. daemon 은 switch 를 붙잡지 않는다.
  - 범위가 끝나면 기다리던 flush 가 모두 `` `Closed `` 답을 받는다. 답 하나가 예외를 내도 나머지가 받고, 예외는 모두 답한 뒤에 다시 난다.
  - h2 는 flush 의 답을 연결의 쓰기 루프에서 부른다. 거기서 예외가 나가면 gluten 은 쓰기 루프를 끝내고(gluten_eio.ml 151~169줄), 그 연결의 모든 스트림이 멈춘다. 그래서 답이 낸 예외는 그 스트림의 실패로 다룬다. handler 가 낸 예외처럼 D1 으로 그 스트림만 끊고 error 한 줄을 남긴다. 취소는 그대로 올린다.
  - `Stream_end` 는 그 연결이 도는 domain 에서만 부른다. h2 의 body writer 가 그렇고, 그래서 잠금을 두지 않는다.
- **`Stream_end` 를 fiber-local 로 묶는다.** `Eio.Fiber.with_binding` 은 fork 한 fiber 에도 이어진다(eio 1.3 `eio__core.mli` 387~394줄). 그래서 스트림 fiber 에서 건 flush 가 모두 여기 걸린다.
  - `Http_reqd` 가 쓰는 응답 본문의 조각 flush(D3)
  - masc 가 스트림 fiber 에서 보고해 연 오류 응답의 `Http_h2_stream.close_after_flush`(gateway error handler, `server_h2_gateway.ml` 25줄)
  - 요청 본문 콜백을 스트림 switch 로 미루는 `Http_h2_stream.dispatch`(`http_reqd.ml` 421줄). 이 fork 는 연결 reader fiber 에서 일어나므로 원장처럼 명시적으로 다시 묶는다.
- **H2 request handler 와 `Http_reqd.of_h2` 는 레지스트리가 만든 `Stream_end` 를 인자로 받는다.** handler 의 타입이 `stream_end:Http_h2_stream.Stream_end.t -> ...` 라서 `Stream_end` 없이 부를 수 없다. 묶이지 않았을 때 쓸 기본값을 만들지 않는다.
  - 레지스트리 없이 gateway 나 `of_h2` 를 부르는 시험은 `Stream_end.create` 로 요청마다 하나 만든다(예: `test_dashboard_http_core.ml` 의 `stream_end_of`). 이 시험들은 연결 없이 h2 를 메모리 안에서 돌려서 frame tap 과 레지스트리가 없다.
  - 정체를 보지 않는 시험은 아무도 움직이지 않는 mock 시계나, 시험이 90초 안에 끝나는 실제 시계를 쓴다.
- **원장 예약은 범위가 끝나면 풀린다.** `with_request` 의 release hook 이 남은 예약을 모두 푼다(`http_h2_response_ledger.ml` 52~60줄). 그래서 D1 이 범위를 끝내면 예약도 풀린다. 원장의 `write_reserved` 가 거는 flush 는 `Stream_end` 를 거치지 않는다(69줄). 이 함수는 gateway 의 오류 진단 한 줄만 쓴다(D3).
- **gRPC 응답의 flush 도 `Stream_end` 를 거치지 않는다.** gRPC 리스너의 응답은 `Grpc_eio` 가 h2 에 바로 쓴다. 그 flush 는 D2 상한을 받지 않는다. 스트림 switch 는 레지스트리가 주므로, D1 으로 스트림이 끝나면 그 fiber 도 끝난다.
- **h2 가 연결 reader fiber 에서 여는 오류 응답은 masc 범위 밖이다.** 프레임 해석 중 오류에 h2 는 reader fiber 에서 error handler 를 부른다(server_connection.ml 157~160줄). 그 `close_after_flush` 에는 `Stream_end` 가 묶이지 않는다. 본문은 고정 진단 문구 하나다(`server_h2_gateway.ml` 17~24줄). 창을 열지 않는 상대가 쥐는 이 응답은 연결 단위 상한(§7.4)에 맡긴다.
- **SSE `send` 의 자체 타이머는 HTTP/1.1 에서만 돈다.** HTTP/2 에서 같은 상한의 타이머 둘이 겨루지 않는다. 로그 스트림의 자체 send 와 정체 판정은 지우고 `Server_sse_response` 를 쓴다.
- **상한은 lib/ 의 상수 하나다.** 값은 지금과 같은 90초다. `sse_stalled_after_s`(`server_mcp_transport_http_headers.ml` 294줄)다. HTTP/2 리스너의 레지스트리가 이 값을 기본으로 쓰고, `observer_idle_timeout_ms`(299줄)와 SSE 응답도 이 값을 쓴다. 로그 스트림은 `Server_sse_response` 를 거쳐 같은 값을 쓴다. 이름은 SSE 에서 왔다. 이 값을 바꾸면 HTTP/2 응답 전체의 최소 배출 속도(§5)도 같이 바뀐다. `server_mcp_transport_http_agui.ml` 16줄의 따로 적은 `30.0` 은 `sse_ping_interval_s` 로 바꾼다. 핑 간격(30초)은 상한보다 짧다.
- **로그 스트림의 keepalive 는 보낸 것이 없는 30초마다 나간다.** 로그 스트림은 질의에 안 맞는 로그에도 깨어난다. 그때마다 30초를 처음부터 다시 세서, 그런 로그가 30초 안쪽 간격으로 이어지면 keepalive 가 나가지 않았다. 읽는 클라이언트는 조용한 스트림과 죽은 연결을 가를 수 없었고, 떠난 클라이언트의 fiber 는 다음 `send` 가 없어 남았다. 다음 keepalive 시각을 보낸 것이 없는 깨어남 너머로 유지한다. 그 시각은 벽시계 값이다. 시계가 뒤로 가면 그만큼 늦어지므로, 깨어날 때마다 지금부터 핑 간격 안으로 당긴다. 떠난 상대는 길어도 핑 간격 뒤에 `send` 를 만난다. 멈춘 상대에게는 keepalive 13 B 가 창이나 소켓 버퍼에 들어가는 동안 `send` 가 답을 받고, 상한은 더 들어가지 못한 프레임부터 센다.

### D3. 응답 본문은 h2 에 16 KiB 조각 둘까지 넣는다

- **조각 크기는 16 KiB 다.** 기본 `SETTINGS_MAX_FRAME_SIZE` 의 DATA 프레임 하나다. 선 위에서는 프레임 헤더 9 B 를 더해 16,393 B 라 TLS 레코드(평문 최대 16,384 B) 둘에 걸친다.
- **D2 만 걸면 긴 본문을 천천히 읽는 정상 클라이언트가 끊긴다.** 본문 전체를 flush 하나로 기다리기 때문이다. 링크 속도 × 90초보다 큰 본문은 다 나가기 전에 상한에 닿는다. 그래서 D2 와 D3 을 한 PR 로 낸다.
- **h2 는 창이 허락하는 만큼을 한 번에 소켓에 넘긴다.** h2 는 스트림마다 연결 창과 스트림 창 가운데 작은 쪽만큼을 본문에서 꺼내 연결 writer 에 넣고(scheduler.ml 351~378줄), 그 묶음에 flush 하나를 건다(body.ml 200~221줄). gluten-eio 는 묶음을 `Eio.Flow.write` 한 번으로 쓴다(gluten_eio.ml 37~47줄). 본문에 건 flush 는 묶음 전체가 소켓에 들어간 뒤에 한꺼번에 답을 받는다. 본문을 h2 에 통째로 넣어 두면 두 가지가 생긴다.
  - 창이 본문보다 큰 상대는 꾸준히 읽어도 묶음 전체를 90초 안에 받아야 한다. 창이 6 MiB 면 약 70 KB/s 다(계산값).
  - 그 쓰기가 끝날 때까지 연결 writer 는 다른 스트림의 프레임을 쓰지 못한다. 같은 연결의 SSE 스트림은 keepalive 의 flush 가 90초를 넘겨 끊긴다.
- **그래서 h2 에는 본문마다 조각 둘까지만 둔다(`Http_h2_stream.Response_body`).** 본문에 쓴 payload 는 쓴 순서대로 큐에서 기다린다. 큐 맨 앞에서 16 KiB 씩 h2 에 넣고 조각마다 `Stream_end` flush 를 건다. 조각 하나가 답을 받으면 다음 조각을 넣는다. 큐에 payload 가 남아 있으면 flush 와 close 도 큐에서 제 차례를 기다린다. 남은 payload 가 없으면 h2 에 바로 건다. h2 는 한 본문의 기다리는 flush 에 건 순서대로, 그 앞 바이트가 나간 뒤에 답한다(faraday.ml 389~416줄).
  - 답은 h2 의 연결 writer 나 범위의 끝이 부른다. 그래서 조각을 기다리는 fiber 가 없다. 여러 fiber 가 한 응답에 쓰는 SSE 프레임의 순서와 경계도 잠금 없이 그대로다.
  - 소켓 쓰기 한 번에는 한 스트림의 조각 둘까지 들어간다. h2 는 쓰기마다 보낼 것이 있는 스트림 하나를 고른다(scheduler.ml 418~479줄, server_connection.ml 1441~1443줄). 고르는 순서는 스트림마다 보낸 바이트로 매기는 공정 큐다(nghttp2 의 방식, scheduler.ml 293~304줄). 그래서 한 연결의 본문들은 연결 writer 를 조각 둘까지씩 번갈아 쓴다. 쓰기 하나는 진행 중인 쓰기와, 같이 나가는 다른 본문마다 조각 둘까지를 기다린다. 새로 시작한 응답의 첫 쓰기도 같다.
  - 작은 payload 여럿은 한 조각에 같이 담긴다. 그 사이에 걸린 flush 는 그 조각이 나갈 때 답을 받는다.
  - close 는 앞의 조각이 모두 나간 뒤에 h2 에 닿는다. h2 는 보낼 바이트가 남은 본문을 닫으면 창에서 자른다(h2#278). route 가 close 를 부른 뒤로 그 본문은 닫혔다고 답하고, 뒤에 쓴 것은 버린다.
  - h2 가 스스로 닫은 본문에는 더 넣지 않는다. h2 는 닫힌 본문에 쓴 것을 버리고, 보낼 것이 없는 본문의 flush 에는 바로 `` `Written `` 으로 답한다(body.ml 161~183줄, faraday.ml 209~213줄).
- **조각을 하나만 두면 프레임이 잘게 쪼개진다.** 처음 올린 큐(`a30bc89c29aa`)는 조각을 하나만 뒀다. h2 는 쥐고 있는 바이트로 DATA 프레임을 채운다(serialize.ml 551~561줄). 그래서 조각이 하나뿐이면 상대의 창이 남아도 프레임이 조각 끝에서 끊긴다.
  - 프레임을 읽을 때마다 그만큼 창을 돌려주는 클라이언트가 있다. ocaml-h2 의 client 가 그렇다(client_connection.ml 306~322줄). 이런 클라이언트가 돌려준 창 하나는 조각 끝에서 프레임 둘이 되어 돌아온다. 나뉜 창은 다시 합쳐지지 않아서 프레임이 계속 작아진다.
  - 8 MiB 본문을 창 65,535 B 인 그런 클라이언트에 보냈다. 조각 하나일 때 DATA 프레임이 33,152개였고 그중 32,640개가 1 KiB 미만이었다. 11.0~13.5초 걸렸다. 조각 둘이면 513개, 0.09~0.34초다. payload 를 h2 에 통째로 넣으면 513개, 0.09~0.20초다. main 이 쓰는 방식이고, 큐가 payload 를 한 번에 넘기게 바꿔서 쟀다.
  - 조각 둘이면 프레임이 앞 조각의 끝에 닿을 때 뒤 조각이 이미 h2 에 있다. 그래서 프레임이 조각 끝에서 끊기지 않는다. 큐가 비어 있다가 작은 payload 둘 뒤에 큰 payload 가 오면, 그 작은 조각 둘이 나갈 때까지는 h2 가 쥔 양이 프레임 하나보다 적다. 그때 프레임이 한 번 짧게 나간다.
  - 창을 몰아서 돌려주는 클라이언트는 조각 하나일 때도 이렇게 느려지지 않는다. 돌려준 창이 다시 합쳐지기 때문이다. Go 는 4 KiB 가 밀리거나 밀린 양이 남은 창 이상이면 돌려준다(x/net/http2 flow.go `inflow.add`). 그 규칙으로는 조각 하나가 프레임 1,021개, 조각 둘이 513개였고 시간 차이는 측정 흔들림 안이었다.
  - 한 번에 돌려준 창이 h2 가 쥔 양(32 KiB)을 넘으면 조각 둘이어도 그 끝에서 프레임이 한 번 끊긴다. 받은 양이 창의 반 이상일 때 돌려주는 규칙(nghttp2 의 `nghttp2_should_send_window_update`)으로 창 65,535 B 를 쓰면 프레임이 767개였다. 통째로는 513개다. 창이 다시 합쳐지므로 더 작아지지는 않는다.
  - 조건: 평문 TCP loopback, 양쪽 `TCP_NODELAY`, 손으로 쓴 HTTP/2 클라이언트를 다른 domain 에서 실행, 3회(32 MiB 장면은 5회) 중앙값을 3~4번 잼, 2026-11-10. 같은 장비에서 다른 빌드가 돌아 시간은 2~3배 흔들렸고 프레임 수는 매번 같았다. 탐침과 결과는 `docs/evidence/research/2026-11-09-h2-sse-tls/` 의 run7 이다.
- **`Http_reqd` 가 쓰는 본문은 모두 이 큐를 거친다.** 통째 본문과 스트리밍 writer 두 곳이고, 아래 셋을 덮는다.
  - 통째 본문(`h2_respond_with_string`)
  - MCP POST 결과. `safe_respond_chunked`(`server_mcp_transport_http.ml` 58~62줄)는 스트리밍 writer 에 결과를 한 번 쓰고 닫는다.
  - SSE 프레임. `stream_post_sse_json` 은 tools/call 결과 전체를 프레임 하나로 보낸다(`server_mcp_transport_http.ml` 175~177줄).
  - gateway error handler 의 진단 한 줄은 큐를 거치지 않는다. 원장 쓰기(`write_reserved`)로 한 번에 쓰고 `close_after_flush` 로 닫는다. 그 응답의 감시 flush 는 `close_after_flush` 하나다.
- **90초는 본문 전체가 아니라 조각에 걸린다.** 앞 조각이 답을 받은 때부터 잰다(D2). 조각이 하나씩 90초 안에 나가면 본문 전체가 90초보다 오래 걸려도 끝까지 간다. 소켓이 병목이면 쓰기 한 번에 조각 둘이 같이 들어가고, 두 조각은 그 쓰기가 끝나야 답을 받는다. 그때는 조각 둘이 90초 안에 들어가야 한다. 창을 몰아서 돌려주는 클라이언트는 꾸준히 읽어도 한 번에 돌려주는 양을 90초 안에 읽어야 한다. 그동안 다음 조각이 나갈 창이 없기 때문이다(§5). 아무것도 읽지 않는 클라이언트는 첫 창 뒤의 조각에서 90초에 끊긴다. 조각의 flush 는 조각 전체가 나가야 답을 받으므로 1바이트 WINDOW_UPDATE 로는 늘어나지 않는다(§3.3).
- **원장 예약은 지금처럼 payload 전체다.** 문자열이 다 나갈 때까지 큐에 있기 때문이다. payload 의 마지막 조각이 소켓에 들어가면 예약을 푼다. h2 가 쥐는 사본은 조각 둘까지다.
- **원장이 거절하면 warn 한 줄을 남긴다.** 통째 본문은 빈 503 으로, 스트리밍 쓰기는 reset 으로 끝난다. 줄에는 요청 메서드와 경로, 거절한 바이트 수를 적는다. 응답이 시작된 뒤의 reset 은 error handler 를 거치지 않아 다른 흔적이 없다.
- **헤더를 보내기 전의 예외는 지금처럼 예약을 풀고 다시 낸다.** `http_reqd.ml` 231~249줄은 예약한 뒤 `H2.Reqd.respond_with_streaming` 을 부른다. `error_code` 가 이미 있으면 h2 는 헤더를 쓰기 전에 `currently handling error` 를 낸다(reqd.ml 280~285줄). 그때 예약을 풀지 않으면 최대 32 MiB(`tool_blob_store.ml` 343줄)가 응답 없이 남는다.
- **헤더를 보낸 뒤의 예외는 D1 reset 으로 끝낸다.** 그 자리의 `release; raise` 만 지운다.

### D4. 연결 쓰기 상한

- **`Server_connection_socket` 이 accept 한 소켓을 감싼다.** 평문·TLS, HTTP/1.1·HTTP/2 모두다. accept 루프(`server_bootstrap_http.ml` `run_accept_loop`)가 감싸고, 리스너는 감싼 소켓만 받는다. TLS 는 이 감싸개 위에서 돈다. `Tls_eio.server_of_flow` 가 받는 소켓이 이 감싸개다. tls-eio 위의 `Tls_stream_socket` 은 이 자리가 아니다.
- **쓰기 조각마다 기한을 하나 건다.** 한 번에 넘기는 쓰기를 256 KiB 이하로 나눈다. 조각 하나가 커널에 다 들어가는 데 D2 와 같은 90초를 준다. 조각을 계속 받는 상대는 쓰기 전체가 아무리 길어도 끊기지 않는다.
- **기한은 연결마다 감시 fiber 하나가 잰다.** 조각이 나가는 동안에만 있고, 쓰지 않는 연결에는 없다. 쓰기마다 타이머를 걸면 쓰기 하나에 CPU 약 5 µs 가 더 든다. 128 B 쓰기와 그 읽기 한 쌍이 10.3~12.1 µs 인데, 타이머를 걸면 16.3~23.0 µs 이고 시작 시각만 적으면 9.1~11.7 µs 다(조건과 벤치 코드는 이 층 PR 본문).
- **쓰기는 한 번에 하나만 나간다.** 두 번째 쓰기는 차례를 기다린다. tls-eio 는 읽기 경로에서도 레코드를 쓴다(tls_eio.ml 69·74줄). 감싸개는 쓰기 한 번에 받은 것을 차례를 쥔 채 조각마다 끝까지 쓰므로, 그 레코드가 writer 의 레코드 안에 끼어들지 않는다.
- **기한을 넘기면 연결을 끊는다.** `SO_LINGER 0` 을 걸고, 보내기 쪽과 받기 쪽을 따로 shutdown 한다. 그 쓰기와 뒤의 모든 쓰기는 `End_of_file` 을 낸다. 읽기는 EOF 를 본다. gluten 의 두 루프가 끝나면 accept 루프가 fd 를 닫는다. 아래 셋은 macOS 27.2 의 TCP loopback 과 socketpair 에서 쟀다(스크립트는 이 층 PR 본문).
  - 양방향을 한 번에 shutdown 하지 않는다. 상대가 FIN 을 보낸 뒤에는 macOS 가 그 호출 전체를 ENOTCONN 으로 거절한다. 보내기 쪽은 열린 채 남고, 자던 쓰기는 깨지 않는다. Eio 는 그 ENOTCONN 을 버린다. 한쪽씩 부르면 자던 쓰기가 EPIPE 로 깬다.
  - `SO_LINGER` 를 거는 호출은 상대가 이미 reset 했거나 닫은 소켓에서 EINVAL 을 낸다. 그런 상대에게 쥐고 있을 바이트는 없으므로 넘어간다.
  - `SO_LINGER 0` 이 없으면 fd 를 닫은 뒤에도 커널이 상대가 받지 않은 바이트를 쥔다. 옵션을 걸고 닫으면 상대는 큐의 612,520 B 중 406,000 B 를 읽고 ECONNRESET 을 받았다. 걸지 않고 닫으면 큐의 599,448 B 를 다 읽고 EOF 를 받았다.
- **EPIPE·ECONNRESET 도 `End_of_file` 로 바꾼다.** gluten 은 `End_of_file` 만 `` `Closed `` 로 바꾸고 writer 를 drain 한다(gluten_eio.ml 47줄). 다른 예외는 `report_exn` 으로 가서 flush 콜백이 오지 않는다(조사 §2.1).
- **서버가 보내기 쪽을 닫은 뒤에도 같은 상한을 둔다.** 그 안에 상대가 닫지 않으면 연결을 끊는다. gluten 의 마지막 EOF 읽기에는 기한이 없다(gluten_eio.ml 122~145줄).
  - TLS 연결에서는 감싸개가 이 shutdown 을 보지 못한다. tls-eio 의 `shutdown` 은 close_notify 만 쓰고 아래 flow 를 닫지 않는다(tls_eio.ml 177~185줄). `Tls_stream_socket.shutdown` 도 tls 로만 넘긴다(tls_stream_socket.ml 11줄).
  - 그래서 TLS 의 이 상한은 `Tls_stream_socket.shutdown` 이 감싸개에 알려서 건다. 리스너가 `Tls_stream_socket.wrap ~on_send_shutdown` 에 `Server_connection_socket.send_side_closed` 를 넘긴다.
- **gRPC 리스너의 accept 루프도 같은 감싸개를 쓴다**(`server_grpc_listener.ml` `serve_socket`, #50487). accept 한 소켓을 감싸고, 감싼 소켓만 `serve_h2_connection` 에 넘긴다. 상수와 함수는 HTTP 리스너와 같다. 응답 본문의 D2·D3 은 여전히 밖이다(§7.9).

### D5. 바뀌지 않는 본문은 참조로 보내고 원장을 쓰지 않는다

- **공유 본문 타입을 둔다.** `Shared_body.t` 는 OCaml 문자열을 감싼 추상 타입이다.
  - OCaml 문자열은 바꿀 수 없다. 그래서 응답 여럿이 한 문자열을 읽어도 안전하다.
  - bigstring 으로 두지 않는다. 압축 codec 과 파일 읽기가 문자열을 내므로 bigstring 으로 옮기면 사본이 하나 더 생긴다. bigstring 은 OCaml heap 밖에 있어 GC 통계에도 잡히지 않는다.
  - 요청 하나를 위해 만든 본문은 이 타입에 넣지 않는다. 넣으면 그 바이트가 원장에서 빠질 뿐이다.
- **`Http_reqd.respond_with_shared` 를 더한다.**
  - HTTP/1.1 은 소유 본문과 똑같이 쓴다. 원장은 HTTP/2 에만 있다.
  - HTTP/2 는 D3 의 큐로 보낸다. h2 에 16 KiB 조각을 둘까지 넣고, 조각마다 D2 상한이 걸린다. 조각은 h2 버퍼로 복사된다. 응답 하나가 따로 쥐는 것은 그 두 조각뿐이다.
  - 본문 전체는 응답이 없어도 소유자가 쥐고 있다. 그래서 원장에 예약하지 않고, 용량 때문에 503 으로 거절하지도 않는다.
- **대시보드 정적 asset 이 첫 사용처다.**
  - 읽을 때마다 receipt 와 digest 를 검증하는 계약은 그대로다(`lib/installed_dashboard.mli`).
  - 서버는 asset 이름마다 읽은 바이트와 그 zstd·gzip 형태를 쥔다. 방금 읽어 검증한 바이트가 쥐고 있는 바이트와 같을 때만 그 항목을 쓰고, 다르면 바꾼다.
  - 압축은 내용과 인코딩마다 한 번이고, 그 인코딩을 처음 받는 요청이 CPU pool 에서 한다. 전에는 `accept-encoding` 을 보낸 요청마다 압축했다.
  - 압축이 끝나기 전에 같은 asset 을 같은 인코딩으로 요청한 나머지는 그 결과를 기다린다. 요청마다 압축본을 따로 쥐지 않는다. 압축하던 요청이 취소되거나 실패하면 기다리던 요청 하나가 다시 한다.
  - 인코딩을 받지 않는 클라이언트, 이미 압축된 형식, codec 최소 크기보다 작은 asset 은 전처럼 CPU pool 을 기다리지 않는다.
  - `Installed_dashboard.load` 는 요청마다 파일 전체를 읽는다. 그래서 요청마다 사본 하나와 sha256 계산은 남는다. 그 사본은 비교 뒤 버리고, 응답은 서버가 쥔 문자열만 읽는다.
  - 표는 256 MiB 까지만 쥔다. 측정한 번들 66.3 MB 의 약 네 배다. 자리를 내려고 항목을 내보내지 않는다.
  - 표에 안 들어가는 것은 전처럼 요청의 본문으로 답한다. 요청마다 압축하고 원장에 예약한다. 그래서 응답이 원장 밖에서 쥐는 바이트는 표가 쥔 것뿐이고 표의 상한 안이다.
  - 예외는 돌고 있는 서버 아래에서 파일 내용이 바뀐 경우다. 그 이름의 항목을 바꾸고, 진행 중인 응답은 끝날 때까지 이전 바이트를 쥔다. 설치된 release 는 읽을 때마다 digest 를 검증하므로 이 경우가 없다.
- **#50294 의 측정 장면에서 원장 사용량이 0 이 된다.** 번들 77개를 쥔 클라이언트는 원장을 쓰지 않는다. cloudflared 연결 안의 다른 원격 사용자도 막지 않는다.

### D6. 연결 준비는 30초 안에 끝나야 한다

- 상한을 거는 곳: TLS handshake, 평문 프로토콜 판별, HTTP/1.1 전용·h2c 리스너의 첫 바이트. 모두 `Server_connection_socket.prepare` 를 거친다(`server_bootstrap_http.ml` 의 `serve_tls`·`serve_auto`·`serve`·`serve_h2`).
- HTTP/1.1 전용·h2c 리스너는 첫 바이트를 읽지 않고, 읽을 수 있을 때까지만 기다린다(`await_first_bytes`). 바이트는 httpun 과 h2 가 읽는다. gRPC 리스너도 h2c 리스너와 같은 방법으로 첫 바이트를 기다린다(`server_grpc_listener.ml` `serve_socket`).
- 기한을 넘기면 연결을 끊고(D4 와 같은 방법) debug 한 줄을 남긴다. TLS 는 리스너의 handshake 실패 카운터도 올린다.
- 근거: piaf `accept_timeout` 30 s, nginx `client_header_timeout` 60 s. Go 는 `ReadTimeout`·`ReadHeaderTimeout`·`WriteTimeout` 중 양수 최솟값을 handshake 에 건다(조사 §2.3, §3.1).

### D7. 응답이 생산자 수명을 가진다

- `Server_sse_response.serve ~sw ?release t produce` 를 더한다. 생산자를 `await_closed t` 와 겨루게 한다.
  - 응답이 먼저 닫히면 생산자를 취소한다. HTTP/2 는 상대의 reset, 정체, 연결 종료가 응답을 닫는다. HTTP/1.1 은 응답 밑의 끝을 알리지 않아서, 생산자가 다음 `send` 에서 안다(§7.7).
  - 생산자가 돌아오면 응답을 완결로 닫는다.
  - 생산자가 예외로 끝나면 닫지 않고 끊는다. 라우트 handler 가 응답 도중 실패했을 때와 같은 길(`Http_reqd.report_exn`)이다. HTTP/2 스트림은 RST_STREAM 을 받고 HTTP/1.1 은 본문을 멈추고 연결을 닫는다. 예외는 거기서 error 로 한 번 남고, 호출자의 switch 는 실패하지 않는다.
  - `release` 는 생산자가 쥔 것(구독, 세션)을 놓는 정리다. 생산자가 끝나고 응답이 닫힌 뒤 한 번 부른다.
- 생산자는 호출자의 switch 에 fork 하고, 그 fiber 안에 응답마다 자식 switch 를 연다. pump 가 이렇게 돈다(`server_mcp_transport_http_conn.ml` 313~331줄). 스트림 switch 로 옮기지 않으므로 생산자가 스트림 switch 를 붙잡는 순환 대기가 없다.
- 호출자의 switch 에는 hook 을 걸지 않는다. 그 switch 는 서버 수명이다. 라우터의 switch(`server_routes_http.ml` 9·42줄)이거나, 문서 초안 라우트처럼 서버 state 의 switch 다. eio 는 `on_release` hook 을 switch 가 끝날 때까지 쥔다(eio switch.ml 101~111줄). 응답마다 걸면 서버가 끝날 때까지 쌓인다.
- fork 하기 전에 `Switch.get_error` 를 본다. 이미 끝나는 중이면 생산자를 돌리지 않고, 응답을 닫고 `release` 를 부른다. 그 밖에는 응답을 닫고 `release` 를 부르는 cleanup 을 자식 switch 의 `on_release` 에 건다.
- 쓰는 곳은 셋이다: 로그(`server_routes_http_routes_log_stream.ml`), 문서 초안(`server_routes_http_routes_artifact_draft_live.ml`), 실행 출력(`server_routes_http_routes_dashboard.ml` `handle_execute_output_stream`).

### D8. TLS 쓰기 조각과 암호 순서

- **쓰기 조각.** tls-eio 가 암호문을 아래 소켓에 `Eio.Flow.write` 로 쓴다. 감싸개(D4)가 그것을 256 KiB 조각으로 커널에 넘긴다.
  - tls-eio 2.1.5 의 `write_t` 는 암호문을 `Eio.Flow.copy_string` 으로 쓴다. Eio 의 문자열 source 는 읽기 메서드가 없어서 소켓은 `Eio.Flow.Pi.simple_copy` 로 받는다. 4096 B 버퍼라 4 KiB 마다 쓰기 한 번이다.
  - `write_t` 를 `Flow.write t.flow [ Cstruct.of_string s ]` 로 바꾼 포크를 쓴다. `jeong-sik/ocaml-tls` 의 `2c0f8615865a`, v2.1.5 에 커밋 하나다. `scripts/opam-pin-external-deps.sh` 와 `masc.opam.locked` 가 tls-eio 2.1.5 를 이 커밋에 고정한다. `tls` 패키지는 opam 의 2.1.5 그대로다.
  - `Eio.Flow.write` 는 `single_write` 가 남긴 것을 다시 넘긴다. 그래서 감싸개의 `single_write` 는 받은 것을 한 차례 안에서 다 쓴다. 조각 사이에 차례를 놓으면 읽기 경로의 레코드가 writer 의 레코드 안에 낄 수 있다.
  - 서버 CPU(ms/MB, 5회 중앙값, 벤치 run4): 본문 통째 쓰기 AES-128-GCM 5.28(4 KiB 경로 10.58), ChaCha20 4.14(8.01). HTTP/2 조각 둘 AES-128-GCM 8.19(12.67), 조각 하나 6.93(11.76). 줄어든 폭은 클라이언트 둘을 합쳐 32~53% 다. 벤치의 소켓은 감싸개가 아니라 accept 한 소켓이다.
  - 포크를 넣은 설치 build(`e0f124c927a5`)의 서버 CPU 는 스택 전 build 보다 TLS 연결 하나에서 27.6~41.8%, 연결 넷에서 16.4~32.9% 낮았다(run13, 번갈아 다섯 쌍의 중앙값). 평문 연결 하나는 39~42% 높게 읽혔고 원인은 가리지 않았다(#51400).
  - 감싸개에서 256 KiB 버퍼로 모아 쓰는 방식과는 −9~+14% 로 엇갈린다(같은 순서로 5.10, 3.96, 7.59, 6.73). 포크 쪽은 연결마다 256 KiB 버퍼를 쥐지 않는다.
  - run4 는 다른 빌드가 돌던 장비에서 한 번 돌았다(load average 153→62). 처리량(MB/s)은 출렁여서 쓰지 않고 CPU 만 쓴다.
  - 조각을 16,375 B 로 줄여 레코드에 맞추는 것은 하지 않는다. run3 의 조각 둘에서 8.8~9.0 으로 차이가 없었다.
  - masc 가 TLS 클라이언트로 쓰는 연결도 같은 tls-eio 를 쓴다. 그쪽 암호문도 소켓 쓰기로 바로 나간다. 재지 않았다.
  - upstream(mirleft/ocaml-tls)에는 내지 않았다. tls-eio 릴리스가 암호문을 이렇게 쓰게 되면 pin 을 지운다.
- **암호 순서는 바꾸지 않는다.** 이 arm64 빌드는 `Mirage_crypto.accelerated` 가 빈 목록이다.
  - cloudflared 는 같은 호스트에서 Go `crypto/tls` 로 복호화한다. 그래서 Go 클라이언트로 masc 와 클라이언트의 CPU 합을 쟀다(run3, 감싸개에서 256 KiB 로 모아 쓴 서버).
  - ChaCha20 을 AES-128-GCM 과 견준 합(ms/MB): 본문 통째 6.58 대 6.98, 조각 둘 10.73 대 10.43, 조각 하나 12.50 대 13.80, 레코드에 맞춘 조각 둘 10.69 대 10.78. −9%~+3% 로 엇갈린다.
  - 한 번 돈 값이고 방향이 갈려서 합이 준다고 말할 수 없다. 순서는 tls 기본값 그대로 둔다.

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
| 통째 본문 | 본문 전체를 h2 에 한 번에 복사하고 flush 하나를 기다린다. 시간 상한 없음 | h2 에 16 KiB 조각 둘까지, 조각마다 90초 |
| 대시보드 asset | 요청마다 읽고, `accept-encoding` 이 있으면 압축하고, 사본을 원장에 넣는다 | 요청마다 검증하고, 압축본 하나를 참조로 보낸다 |
| 로그·초안·실행 출력 생산자 | 다음 이벤트나 핑까지 산다 | 응답이 닫히면 바로 끝난다 |
| 소켓 쓰기 | 기한 없음 | 256 KiB 조각마다 90초 |
| TLS handshake·평문 첫 읽기 | 기한 없음 | 30초. TLS handshake 뒤의 첫 읽기는 그대로다(§7.4) |
| TLS 쓰기 | 암호문 4 KiB 마다 `writev` | tls-eio 가 넘긴 암호문을 256 KiB 조각으로 |

## 3. 왜 이 모양인가

### 3.1 h2 포크를 먼저 고치지 않는다

`on_close_stream` 에서 응답 본문을 닫고 drain 하면 reset 때 flush 가 `` `Closed `` 로 끝난다. 원인 자리를 고치는 방법이다. 하지만 그 스트림의 DATA 가 연결 writer 에 남아 있으면 faraday 의 `assert (written = 0)`(faraday.ml 378줄)에 걸린다(추정). 그리고 h2 에는 timer 가 없다. 창을 안 여는 상대를 끊는 판단은 어차피 masc 몫이다. D1 은 지금 공개 API(`report_exn`, `error_code`, `response`)만 쓴다. 포크 정리는 따로 남긴다(§7). h2 가 쓰는 프레임 자체가 RFC 9113 과 다른 곳(§5)은 masc 에서 고칠 수 없어 그 정리에 넣는다.

### 3.2 연결별 원장 몫을 두지 않는다

한 연결이 원장의 일부만 쓰게 하면 연결 사이는 갈린다. 하지만 cloudflared 는 원격 사용자를 origin 연결 몇 개에 모은다. Go HTTP/2 Transport 는 연결의 동시 스트림 한도를 넘을 때만 연결을 더 연다(x/net http2 `StrictMaxConcurrentStreams` 기본 false). 그래서 연결 몫은 원격 사용자를 가르지 못한다(추정). 몫이 원장의 절반이면 32 MiB artifact(`Tool_blob_store.max_served_bytes`)가 다른 응답과 같이 못 들어간다. 측정 장면의 원인은 같은 불변 파일의 사본 77벌이다. D5 가 그 사본을 없앤다.

### 3.3 상한은 조각마다 둔다

| 모양 | 예 | 맞지 않는 이유 |
|---|---|---|
| 스트림 전체 시간 | Go `WriteTimeout` | SSE 는 오래 산다. Envoy edge 예시도 스트리밍에는 끄라고 적는다 |
| 진척이 있으면 연장 | nginx `send_timeout`, Go `WriteByteTimeout` | HTTP/2 bomb 가 1바이트 WINDOW_UPDATE 로 피한다 |

조각 하나가 기한 안에 다 나가야 한다는 규칙은 1바이트 WINDOW_UPDATE 로 늘어나지 않는다. 대가는 최소 배출 속도다. 16 KiB 조각에 90초면 182 B/s 다. 소켓이 병목이면 쓰기 한 번에 조각 둘이라 364 B/s 다. 창을 B 바이트씩 몰아서 돌려주는 클라이언트에게는 max(B, 16 KiB)/90초다(§5).

조각은 h2 에 둘까지만 넣는다. 본문을 통째로 넣고 16 KiB 마다 flush 만 걸면 상한이 조각이 아니라 h2 가 한 번에 소켓에 넘기는 묶음에 걸린다(D3). 쓰는 쪽을 받는 쪽 속도에 맞추는 것은 다른 서버도 같다. piaf 는 스트림마다 조각 하나를 쓰고 flush 를 기다린다(조사 §2). Go 는 프레임이 나갈 때까지 handler 의 `Write` 를 막고, hyper 는 스트림 보내기 버퍼에 상한을 둔다. masc 는 fiber 를 막지 않고 flush 답에서 다음 조각을 넣는다. 그래서 여러 fiber 가 한 응답에 쓰는 SSE 프레임의 순서에 잠금이 필요 없다.

### 3.4 RST_STREAM 코드는 INTERNAL_ERROR 다

정체로 끊는 스트림에는 CANCEL 이 더 맞다. h2 의 공개 API 는 `report_exn` 하나이고 INTERNAL_ERROR 를 보낸다(포크 reqd.ml 390줄). 코드를 바꾸려면 포크를 고쳐야 한다. 두 코드를 다르게 다루는 클라이언트가 있는지는 확인하지 않았다. 지금 API 를 쓰고, 코드는 포크 정리(§7)에서 다시 본다.

### 3.5 TLS 쓰기는 tls-eio 포크에서 고친다

upstream tls-eio main 도 같은 4 KiB 경로다(조사 §1.8). 고칠 곳은 `write_t` 한 줄이다. 그 한 줄을 고친 포크를 고정해 쓴다. upstream 에는 내지 않았다. 감싸개의 `copy` 에서 256 KiB 버퍼로 모아 쓰는 길도 CPU 는 같았다(D8). 그 길은 TLS 연결마다 256 KiB 를 쥐고, tls-eio 가 만든 문자열을 한 번 더 복사한다. 포크는 릴리스가 따라올 때까지 pin 하나를 더 관리해야 한다.

## 4. 운영자에게 보이는 변화

- 긴 HTTP/2 응답 하나가 다 나갈 때까지 같은 연결의 다른 스트림이 기다리지 않는다. 소켓 쓰기 한 번에 한 스트림의 32 KiB 까지만 들어가고, 스트림들이 번갈아 쓴다. 전에는 한 스트림의 창이 허락하는 만큼이 한 번에 들어갔다.
- 응답 원장이 응답을 거절하면 warn 한 줄이 남는다. 통째 본문의 빈 503 과 스트리밍 응답의 reset 둘 다다. 전에는 로그 줄이 없었다.
- 창을 열지 않거나 읽지 않는 HTTP/2 클라이언트의 스트림은 90초 뒤 RST_STREAM(INTERNAL_ERROR)을 받는다. 서버 로그에 메서드와 경로(쿼리 뺌)가 든 warn 한 줄이 남는다. 멈춘 것이 오류 응답이면 창이 받은 바이트와 빈 END_STREAM 뒤에 RST_STREAM 이 간다(§5).
- handler 가 응답 도중 예외를 내거나 h2 가 스트림을 끊으면, 그 스트림에서 돌던 남은 일(본문 생산자, 미룬 본문 콜백)이 바로 취소된다. 완결한 응답 뒤 h2 가 RST_STREAM(NO_ERROR)을 보낼 때도 같다.
- 라우트가 스트리밍 응답 도중 예외를 내면, HTTP/2 스트림은 RST_STREAM(INTERNAL_ERROR)을 받고 HTTP/1.1 연결은 닫힌다. chunked 본문은 마지막 chunk 가 빠진다. masc 의 HTTP/1.1 SSE 는 연결 종료로 끝을 알리므로, 클라이언트에게는 끝난 스트림처럼 보인다. 전에는 스스로 닫지 않는 라우트의 응답이 열린 채 남았다. 라우트 예외는 error 로 한 번 남는다(늦은 응답 모양은 지금처럼 warn). 응답 전 예외는 전에는 500 본문에만 있었다.
- HTTP/1.1 클라이언트가 요청 본문 도중 떠나면 라우트는 받은 데까지의 본문으로 돌지 않는다. 응답 전이면 httpun 이 400 으로 답한다. 응답이 시작됐으면 그 응답이 끊긴다. 전에는 잘린 본문이 온전한 본문처럼 라우트에 넘어갔다. 읽기가 EOF·reset 이 아닌 오류로 끝나면 gluten 이 보고하고 500 이 된다(gluten_eio.ml 149줄).
- GitHub 로그인 스트림과 계정 로그인 스트림이 예외로 끝나면 HTTP/2 스트림은 RST_STREAM(INTERNAL_ERROR)을 받는다. 전에는 응답을 닫은 뒤 예외를 냈다. 그래서 쓴 바이트가 다 나간 스트림은 끝난 스트림처럼 보였다.
- 필터를 건 로그 스트림도 30초마다 keepalive 한 줄을 받는다. 전에는 질의에 안 맞는 로그가 30초 안쪽 간격으로 이어지면 keepalive 가 나가지 않았다. 떠난 클라이언트의 로그 스트림은 HTTP/2 면 스트림이 끝날 때, HTTP/1.1 이면 다음 keepalive 때 끝난다.
- 로그·문서 초안·실행 출력 스트림은 HTTP/2 클라이언트가 스트림을 reset 하거나 연결을 끊으면 바로 끝난다. 구독과 편집 세션도 그때 놓는다. 전에는 다음 keepalive(30초, 실행 출력은 15초)를 쓸 때 알았다. HTTP/1.1 은 지금처럼 다음 쓰기 때 안다.
- 이 세 스트림의 생산자가 예외로 끝나면 HTTP/2 스트림은 RST_STREAM(INTERNAL_ERROR)을 받고 HTTP/1.1 연결은 닫힌다. 예외는 error 로 한 번 남는다. 전에는 warn(초안은 debug) 한 줄을 남기고 응답을 끝난 것처럼 닫았다.
- 소켓 쓰기 조각 하나(256 KiB 이하)가 90초 안에 커널에 다 들어가지 않는 연결은 끊긴다. 리스너와 상대 주소가 든 warn 한 줄이 남는다. 상대는 RST 를 받고, 보내지 못한 바이트는 버려진다. shutdown 의 FIN 은 밀린 바이트 뒤에 줄을 서므로 나가지 않는다. 연결을 놓으며 fd 를 닫을 때(`server_bootstrap_http.ml` `on_connection_release`) `SO_LINGER 0` 이라 RST 가 간다.
- 서버가 보내기 쪽을 닫은 뒤 90초 안에 닫지 않는 연결은 끊긴다. info 한 줄이 남는다. TLS 연결에서는 서버가 close_notify 를 보낸 때부터 센다(D4).
- HTTP/1.1 SSE 프레임이 나가길 기다리는 동안 클라이언트가 떠나면, 그 `send` 는 바로 `Closed` 로 끝난다. 전에는 90초 뒤 `Stalled` 로 끝났고 warn 한 줄이 남았다. 쓰기가 EPIPE·ECONNRESET 으로 실패하면 이제 gluten 이 기다리던 flush 에 답하기 때문이다(D4).
- TLS 연결은 handshake 가 30초 안에 끝나지 않으면 끊긴다. 평문 연결은 30초 안에 첫 바이트를 보내지 않으면 끊긴다. auto 리스너는 30초 안에 HTTP/1.1 요청 줄인지 HTTP/2 preface 인지 가릴 만큼 받지 못해도 끊는다. 셋 다 debug 한 줄이 남는다. TLS handshake 뒤의 첫 읽기에는 기한이 없다(§7.4).
- gRPC 리스너의 연결에도 같은 상한이 걸린다. 30초 안에 첫 바이트를 보내지 않는 연결은 debug 한 줄을 남기고 끊긴다. 쓰기 조각을 90초 동안 받지 않는 연결은 `[grpc]` 로 시작하는 warn 한 줄을 남기고 끊긴다(D4, D6).
- 대시보드 asset 응답은 원장을 쓰지 않는다. 압축은 asset 판마다 한 번 한다.
- TLS 처리량과 서버 CPU 가 바뀐다. 설치 뒤 같은 탐침으로 잰 값을 기록한다.
- 설정 칸은 더하지 않는다. 상한은 코드 상수다.

## 5. 알려진 한계

- **연결 창.** 다른 스트림이 연결 창을 다 쓰면 모든 스트림이 늦는다. 그때는 가장 오래 기다린 스트림이 먼저 끊긴다.
- **최소 배출 속도.** 상대의 창이 병목이면 16 KiB 조각에 90초라 스트림당 182 B/s 다. 소켓이 병목이면 쓰기 한 번에 조각 둘까지 들어가고 둘 다 그 쓰기가 끝나야 답을 받으므로 364 B/s 다. h2 는 쓰기마다 스트림 하나를 고른다(D3). 그래서 본문 N 개가 한 연결에서 같이 나가면 쓰기 하나는 다른 본문마다 조각 둘까지를 기다리고, 그 연결의 링크는 N × 364 B/s 를 넘어야 한다. 100개면 36 KiB/s 다. 쓰기 한 번을 줄이는 길도 있다. 조각을 4 KiB 로 줄이고 h2 에 프레임 하나와 조각 하나(20,480 B)를 두면 소켓이 병목일 때 228 B/s 다. 조각 수와 답 콜백은 네 배가 된다. 재지 않았고 택하지 않았다. 364 B/s 를 못 내는 링크는 3 kbit/s 아래다. 창을 B 바이트씩 몰아서 돌려주는 클라이언트는 그 묶음을 90초 안에 읽어야 하므로 최소 속도가 max(B, 16 KiB)/90초다. 32 KiB 씩이면 약 364 B/s, 3 MiB 씩이면 약 35 KB/s 다(계산값). 클라이언트가 창을 언제 돌려주는지는 재지 않았다.
- **바쁜 스케줄러에서의 처리량.** 연결 writer 는 소켓 쓰기마다 스케줄러 한 턴을 쓴다. eio_posix 가 쓰기 syscall 앞에서 한 번 양보하기 때문이다(low_level.ml 46~48줄). 큐는 한 턴에 한 본문의 조각 둘(32 KiB)까지만 넘긴다. 그래서 그 domain 이 바쁘면 큰 본문의 처리량이 32 KiB ÷ 턴 시간에 묶인다. 다른 fiber 가 턴마다 CPU 1 ms 를 쓰게 하고 8 MiB 를 보내면 0.28~0.32초(약 27 MiB/s)였다. 통째로 넣으면 0.03초다. 한가할 때는 32 MiB 가 조각 둘로 0.04~0.06초, 통째로 0.02~0.08초다(D3 의 측정 조건, 스트림 창 6 MiB·연결 창 15 MiB). 실제 서버의 턴 시간은 재지 않았다. 설치 뒤에 잰다. 모자라면 h2 가 쥐는 조각 수(`slices_in_h2`)를 늘린다. 늘리면 쓰기 한 번이 커져서 위의 최소 속도와 다른 스트림이 기다리는 양도 같이 늘어난다.
- **큰 프레임을 받겠다는 상대.** 상대가 SETTINGS_MAX_FRAME_SIZE 를 16,384 보다 크게 알리면 h2 는 그 크기까지 프레임을 채운다(server_connection.ml 940~949줄). 큐는 h2 에 32 KiB 까지만 두므로 프레임은 그보다 길어지지 않는다. 통째로 넣는 main 은 상대가 허락한 크기까지 채운다. 그런 클라이언트가 얼마나 있는지는 확인하지 않았다.
- **조각마다 버퍼 하나.** h2 의 본문 버퍼는 다 비어야 다시 쓰인다(faraday.ml 231~237줄, 375~382줄). 조각 둘을 두면 앞 조각이 남은 채 다음 조각을 쓰므로, 조각마다 16 KiB Bigstring 을 새로 만든다. 본문 전체로 보면 통째로 복사할 때 만드는 양과 같다. 처리량 측정에서 조각 하나보다 느리지 않았다. GC 에 주는 영향은 따로 재지 않았다.
- **`Http_reqd` 밖에서 쓴 본문.** h2 는 한 번에 넘기는 양에 스트림별 상한이 없다(scheduler.ml 351~378줄). gRPC 리스너의 응답과 gateway 의 오류 진단은 h2 에 한 번에 들어간다. 진단은 한 줄이다. gRPC 연결에서는 큰 메시지 하나가 다 나갈 때까지 같은 연결의 다른 스트림이 기다린다. 그 연결의 flush 에는 D2 상한이 없어서 끊기지는 않는다. 스트림별 몫은 h2 포크에서 고친다(§7).
- **시계.** 기다림 자체는 벽시계를 따라가지 않는다. Eio 의 두 백엔드는 float 시계의 sleep 을 단조 시계의 상대 sleep 으로 바꾼다(eio_posix time.ml 21~25줄, eio_linux v1.3 도 같다). D6 의 30초와 보내기 쪽을 닫은 뒤의 90초는 sleep 하나라서 시계가 바뀌어도 그대로다. 벽시계를 타는 것은 `Eio.Time.now` 두 값을 비교하는 자리다.
  - D2 는 조용해진 시각과 지금을 비교한다(`http_h2_stream.ml` 181~183줄). 시계가 앞으로 뛰면 그만큼 일찍 끊고, 뒤로 가면 그만큼 늦게 끊는다.
  - D4 는 조각이 나가기 시작한 시각을 적어 둔다. 시계가 뒤로 가면 기다린 시간을 0 으로 보므로 최대 한 상한(90초)만큼 늦게 끊는다. 앞으로 뛰면 그만큼 일찍 끊는다.
  - 둘을 단조 시계(`Eio.Time.Mono`)로 옮기려면 리스너를 여는 곳부터 시계를 하나 더 넘겨야 한다. 따로 한다(§7.10, #51174).
- **원장이 거절한 응답.** handler 가 답을 다 만든 뒤에 거절된다. 통째 본문은 빈 503 이 나가고 스트리밍 쓰기는 스트림이 끊긴다. 요청이 한 일은 되돌리지 않는다. warn 한 줄이 남는다(D3).
- **연결 단위 최소 속도.** D4 는 256 KiB 이상이 밀려 있으면 90초에 256 KiB 를 요구한다. 약 2.9 KB/s 다.
- **TLS 연결의 쓰기 조각.** tls-eio 의 암호문은 D8 전까지 4 KiB 씩 감싸개에 온다(`Eio.Flow.Pi.simple_copy` 의 버퍼). 조각마다 90초이므로 TLS 연결이 끊기지 않는 최소 속도는 약 46 B/s 다(4,096 B ÷ 90초). D8 이 조각을 키우면 평문과 같아진다.
- **EPIPE·ECONNRESET 이 아닌 쓰기 오류.** gluten 이 `report_exn` 으로 넘긴다. 기다리던 flush 는 답을 받지 못한다. 그때 HTTP/1.1 SSE 프레임은 90초 뒤 `Stalled` 로 끝난다.
- **연결 fiber 의 예외.** accept 루프는 `serve_connection` 본문의 예외만 잡는다. 연결 switch 의 다른 fiber 가 낸 예외는 그 switch 를 실패시키고, accept 루프의 fiber 를 거쳐 리스너 switch 까지 간다. D4 의 감시 fiber 는 잰 커널 답(ENOTCONN, EINVAL)을 넘기므로 그 길로 가지 않는다. accept 루프가 연결 하나로 가두는 일은 따로 한다(§7.11, #51173).
- **그 속도 바로 위로 읽는 상대.** 소유 본문의 예약을 오래 쥔다. 861,256 B 본문이면 약 79분이고, 32 MiB 본문이면 약 51시간이다(계산값). 32 MiB 둘이면 그동안 원장 64 MiB 가 다 차서, 원장을 쓰는 다른 응답은 503 이거나 끊긴다. 조각마다 상한을 재면 꾸준히 읽는 느린 상대가 끊기지 않는 대신 이 시간이 길어진다. D5 가 정적 asset 을 이 경우에서 뺀다. artifact 와 MCP 결과 같은 소유 본문은 인증 뒤에만 받는다. artifact 를 범위로 읽으면(§7 의 2, #50481) 예약이 본문 전체가 아니게 된다.
- **keep-alive HTTP/1.1 이탈.** keep-alive 응답 중에는 쓰기 실패로만 안다. `Connection: close` 응답(masc SSE 대부분)은 gluten 의 마지막 읽기가 FIN 을 보고 본문을 닫는다(조사 §1.6).
- **reset 코드.** INTERNAL_ERROR 하나다(§3.4).
- **h2 안에서 끊은 스트림.** RST_STREAM 바이트가 소켓을 떠난 뒤에야 범위가 끝난다(D1).
- **완결한 응답 뒤의 RST_STREAM(NO_ERROR).** 요청 쪽이 아직 열려 있을 때만 나간다(reqd.ml 443~452줄). 반쯤 닫힌 요청에는 나가지 않는다(453~454줄). 그래서 응답 뒤 스트림 switch 에서 도는 fiber 는 요청 쪽이 열려 있었을 때만 취소된다. frame tap 의 콜백은 gluten 이 h2 에 쓰기를 알리기 전에 돈다(gluten_eio.ml 155~156줄). 그래서 마지막 flush 를 기다리는 fiber 는 바이트가 나간 뒤에도 h2 의 `` `Written `` 보다 먼저 취소되거나 `` `Closed `` 를 받는다. 응답 뒤에 스트림 switch 에서 일하는 masc handler 는 찾지 못했다.
- **응답을 열지 않는 error handler.** gRPC 리스너의 error handler(grpc-direct)는 응답을 열지 않는다. 응답 전에 실패한 스트림은 응답도 RST_STREAM 도 없이 열린 채 남는다. masc 는 다시 보고할 수 없고, h2 에는 다른 reset API 가 없다(#50515).
- **h2 가 다시 보고하는 스트림.** masc 가 보고해 오류 응답이 아직 나가는 중인 스트림에, 클라이언트가 h2 의 보고를 부르는 프레임을 보내면 h2 의 `NYI` 가 연결 전체를 끊는다(#50514).
- **h2 가 reader fiber 에서 연 오류 응답.** 그 응답(400 등)에는 masc 범위와 상한이 없다(D2). 그 스트림의 masc handler 가 응답을 열려다 `currently handling error` 로 예외를 내면, 응답 전 보고 규칙대로 범위는 그 오류 응답이 끝날 때까지 남는다(D1). 쥐는 것은 fiber 하나와 레지스트리 항목이고 원장 예약은 없다(D3). 창을 열지 않는 상대에게는 연결이 끝날 때까지다. 연결 단위 상한(§7.4)이 덮는다.
- **범위가 끝난 뒤의 보고.** 스트림 switch 에 fork 한 fiber 가 응답 전에 예외를 내면, 범위가 먼저 끝나고 레지스트리가 그 뒤에 보고한다. 그때 h2 가 여는 오류 응답에는 `Stream_end` 가 묶이지 않아 상한이 없다. 창을 열지 않는 상대에게는 연결이 끝날 때까지 남는다. 그 보고를 새 범위 안에서 하면 상한이 걸린다. 응답 전에 스트림 switch 에 fork 하는 masc 코드를 찾지 못해서 넣지 않았다. 포크에 reset API 를 두면(§7.3) 오류 응답 대신 RST_STREAM 으로 끝낼 수 있다.
- **정체한 오류 응답의 끝.** `Stalled` 가 오류 응답을 쥔 범위를 끝내면 `Stream_end` 가 그 본문을 닫는다. 창이 0 이면 h2 는 빈 END_STREAM 과 RST_STREAM(INTERNAL_ERROR)을 보낸다(scheduler.ml 359~370줄, reqd.ml 456·464~500줄). 이것은 h2#278 동작이다. §7.3 에서 #278 을 고치면 이 스트림을 선 위에서 끝낼 길을 포크에 같이 둔다.
- **h2 가 RFC 9113 과 다르게 쓰는 프레임.** raw 프레임 클라이언트로 `serve_h2_connection` 을 지나 선 위의 프레임을 적었다(PR #50765 본문).
  - 오류 응답 뒤의 RST_STREAM. h2 는 error handler 가 연 응답의 END_STREAM 뒤에 저장한 오류 코드로 RST_STREAM 을 쓴다(reqd.ml `close_stream`). 요청도 끝난 스트림은 그때 이미 닫혀 있고, §5.1 은 닫힌 스트림에 PRIORITY 만 허용한다. 요청이 열려 있으면 RST_STREAM 은 허용되지만 코드가 INTERNAL_ERROR 다. §8.1 이 완결한 응답 뒤에 적은 코드는 NO_ERROR 이고, 클라이언트가 받은 응답을 버리지 못하게 한 것도 그 코드일 때다.
  - 두 번째 RST_STREAM. h2 가 이미 끊은 스트림에 오류가 되는 프레임(증분 0 인 WINDOW_UPDATE)이 오면 RST_STREAM 을 한 번 더 쓴다. 닫힌 스트림에 쓴 프레임이고(§5.1), §5.4.2 는 RST_STREAM 을 둘 넘게 보내지 말라고 한다.
  - 이 길을 타는 것은 h2 가 스스로 답하는 잘못된 요청과 ingress 밖에서 난 masc 예외다(코드 읽기). 라우트의 예외는 ingress 가 정상 응답으로 500 을 쓴다(D1).
  - 정상으로 끝난 응답, 완결한 응답 뒤의 RST_STREAM(NO_ERROR), 정체 절단의 RST_STREAM 하나는 규격대로다. 고칠 자리는 포크다(§7.3, #50482).

## 6. 확인 방법

- 로컬 dune 빌드는 하지 않는다. 타입 검사와 시험 실행은 cmi 스냅샷과 실제 링크 도구로 한다. 전체 빌드와 시험은 CI 가 한다.
- 시험 하네스는 층마다 그 층이 고친다. L2a·L2b 의 시험은 `serve_h2_connection` 을 거치는 하네스(`test_h2_request_fibers.ml`, `test_h2_response_resources.ml`)를 쓴다. D3 의 큐는 h2 가 flush 에 답할 때 다음 조각을 넣는다. 메모리 안 h2 펌프(`test/test_h2_response_window.ml` 등)는 쓰기를 보고할 때마다 다음 조각을 받으므로 고치지 않는다.
- 새 시험은 프로토콜·자원 경계만 본다. clock 은 `Eio_mock` 이다.
  - 창 0 SSE 스트림: 상한 뒤 RST_STREAM 이 오고 원장 사용량이 0 이 된다.
  - 응답을 시작한 handler 가 예외를 내면 조각 writer 와 예약이 바로 풀린다.
  - 응답 전에 handler 가 예외를 내면 오류 응답이 끝까지 나가고, 그 뒤 범위가 끝난다.
  - 이미 보고한 스트림을 다시 reset 해도 예외가 나지 않는다.
  - h2 가 스스로 RST_STREAM 을 쓰면 그 스트림 범위가 `Reset_by_us` 로 끝나고, 연결은 다음 요청에 답한다.
  - 창이 조각 하나인 클라이언트가 1분에 한 조각씩 읽으면 3분 걸리는 본문을 끝까지 받는다. 통째 본문과 스트리밍 writer 둘 다다. 큰 MCP POST 결과는 스트리밍 writer 에 한 번 쓰고 닫으므로 스트리밍 경우가 덮는다.
  - 같은 본문을 하나도 읽지 않는 클라이언트는 상한 뒤 RST_STREAM 을 받고, 예약이 원장으로 돌아간다.
  - 창보다 긴 오류 응답을 읽지 않으면, 상한 뒤 범위가 끝나고 예약이 돌아가고 클라이언트 쪽 응답도 끝난다(§5).
  - 창이 본문보다 큰 클라이언트가 느린 소켓으로 1분에 조각 둘씩 받으면 3분 걸리는 본문을 끝까지 받는다. 시험의 소켓은 mock 시계로 1분마다 조각 둘과 조금 더를 받는다.
  - 조각 하나보다 짧은 통째 본문을 읽지 않는 클라이언트도 상한에 끊긴다.
  - 창을 닫은 상대의 스트림에 프레임을 계속 써도 첫 프레임부터 상한에 끊긴다.
  - route 가 close 한 본문은 닫혔다고 답하고, 그 뒤에 쓴 것은 클라이언트에 가지 않는다.
  - 범위가 끝날 때 기다리던 flush 의 답 하나가 예외를 내도 나머지 flush 가 답을 받는다. h2 에서 기다리던 flush 와, 큐에서 payload 뒤에 기다리던 flush 둘 다다.
  - 소켓이 바이트를 받은 뒤 flush 답이 예외를 내면 그 스트림만 RST_STREAM 을 받고, 같은 연결의 다음 요청은 답을 받는다.
  - 두 fiber 가 한 본문에 쓴 긴 payload 는 섞이지 않고 하나씩 도착한다.
  - 공유 본문 응답은 원장 용량이 본문보다 작아도 전부 도착한다. 같은 바이트의 소유 본문은 503 이다.
  - 같은 asset 을 같은 인코딩으로 다시 요청하면 CPU pool 이 잡혀 있어도 답이 온다. 첫 압축이 끝나기 전에 온 둘째 요청도 그 압축 하나로 답을 받는다.
  - 이벤트를 기다리는 생산자는 스트림 reset 과 close 에 바로 취소된다.
  - 소켓 감싸개(`test_server_connection_socket.ml`, socketpair 와 TCP loopback).
    - 쓴 바이트가 모두 순서대로 도착한다. 조각 여럿인 쓰기 둘, `copy` 둘이 같이 돌아도 섞이지 않는다.
    - 상대가 안 받는 조각은 상한에 끊긴다. 그 쓰기와 뒤 쓰기는 `End_of_file` 이고 읽기는 EOF 다. 상대가 자기 보내기 쪽을 먼저 닫았어도 같다.
    - 끊긴 연결을 닫으면 상대는 reset 을 받는다(TCP).
    - 조각을 1분에 하나씩 받는 상대는 세 조각짜리 쓰기를 끝까지 받는다.
    - 닫힌 상대에게 쓰면 `End_of_file` 이다.
    - 서버가 보내기 쪽을 닫은 뒤 자기 쪽을 열어 두는 상대는 상한에 끊긴다.
    - 준비 단계는 제때 온 첫 바이트를 통과시키고, 안 오면 상한에 끊는다. 상대가 먼저 떠난 연결에서 준비를 포기해도 예외가 나지 않는다.
    - HTTP/1.1 전용, h2c, auto 리스너에 아무것도 안 보내는 연결은 준비 상한에 끝난다. auto 리스너에 HTTP/2 preface 앞부분만 보낸 연결도 같다.
  - HTTP/1.1 SSE 프레임이 나가길 기다리는 동안 클라이언트가 떠나면 `send` 가 `Closed` 로 끝난다(`test_server_sse_response.ml`, 실제 리스너).
  - TLS 리스너(`test_https_listener.ml`). ClientHello 를 보내지 않는 연결은 준비 상한에 끝나고 handshake 실패가 하나 늘어난다. 응답과 close_notify 를 받고도 자기 쪽을 열어 두는 클라이언트는 상한에 끊긴다.
  - 큰 프레임 뒤에 건 flush 는 마지막 조각이 나간 뒤에 답을 받는다.
  - 창이 조각 하나 반인 클라이언트가 프레임 하나를 읽고 창을 돌려주면, 다음 프레임은 조각 끝을 넘어 16 KiB 를 채운다.
  - 느린 소켓을 긴 응답과 짧은 응답이 나눠 쓰면, 짧은 응답은 긴 본문의 조각 둘 뒤에 나간다. 본문을 통째로 넣으면 긴 본문이 다 나갈 때까지 기다린다.
  - 음성 대조: reset 함수, 내보낸 RST_STREAM 규칙, 감시 daemon, 조각 크기, h2 에 두는 조각 수(전부, 하나), close 와 flush 의 차례, close 뒤의 닫힘 답, 조각 flush 의 감시, close 의 감시 flush, 답을 끝까지 돌리기, flush 답의 예외 가두기를 각각 빼거나 뒤집은 변이에서 해당 시험이 실패한다. 내보낸 RST_STREAM 규칙의 시험은 `serve_h2_connection` 을 거친다. h2 가 스스로 스트림을 끊을 때(반쯤 닫힌 스트림의 DATA → STREAM_CLOSED, server_connection.ml 758~764줄) masc fiber 가 기다리고 있어야 한다. 메모리 안 하네스는 frame tap 과 레지스트리를 거치지 않는다(`test_h2_response_window.ml` 99~123줄).
  - 음성 대조(소켓 감싸개): 감시 fiber, 조각 나누기, reset 을 `End_of_file` 로 바꾸기, 한쪽씩 하는 shutdown, EINVAL 넘기기, `SO_LINGER 0`, 보내기 쪽을 닫은 뒤의 상한, 준비를 포기할 때 끊기, `copy` 의 차례, 리스너 셋의 준비 단계를 각각 빼거나 바꾼 변이 열둘에서 해당 시험이 실패한다. 쓰기가 조각 사이에 차례를 놓는 변이에서는 쓰기 둘 시험이 실패한다.
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
3. h2 포크 정리: `on_close_stream` 의 본문 drain, `Reqd.stream_id`·`Reqd.is_closed` 공개(D1), #278 조건 고침으로 `close_after_flush` 와 frame tap 을 지움, #278 을 고칠 때 정체한 오류 응답을 끊을 길(§5), 오류 응답 뒤 RST_STREAM 을 §5.1·§8.1 에 맞추기와 끊은 스트림에 RST_STREAM 을 다시 쓰지 않기(§5), 스트림이 한 번에 넘기는 양의 상한(§5), upstream h2#265 이식(#50482).
4. 연결 수, idle, 헤더 시간 상한. TLS 뒤 h2 preface 대기, 여러 연결이 같이 읽지 않을 때의 소유 본문과 descriptor 고갈도 여기 든다. h2 가 reader fiber 에서 연 오류 응답과 그 뒤에 남는 범위(§5)도 여기 든다(#50483).
5. 들어오는 창 2^27(연결당 128 MiB)을 줄인다. Go 는 1 MiB, Envoy edge 권장은 스트림 64 KiB 다(#50484).
6. HTTP/2 DoS 완화: rapid reset(양방향 reset 세기), CONTINUATION, 헤더 개수(#50485).
7. keep-alive HTTP/1.1 스트리밍 중 이탈 감지(#50486).
8. pump 와 HTTP/1.1 생산자의 domain 문제(#48907 의 나머지).
9. gRPC 리스너 응답 본문의 flush 상한(D2)과 본문 큐(D3). 연결 쓰기·준비 상한(D4·D6)은 이 리스너에도 건다(#50487).
10. D2·D4 의 상한을 단조 시계로 잰다(§5 의 시계, #51174).
11. accept 루프가 연결 switch 의 예외를 연결 하나로 가둔다(§5 의 연결 fiber 의 예외, #51173).

## 8. 층

worktree `.worktrees/h2-backpressure` 에서 gh stack 으로 쌓는다. 맨 아래가 main 이다. 층마다 Draft 를 열고 현재 head 의 독립 리뷰를 받는다.

| 층 | 브랜치 | 결정 | PR |
|---|---|---|---|
| L0 | `research/h2-sse-stalled-responses` | 조사 문서와 실측 기록 | #50417 |
| L1 | `rfc/0518-stalled-peer-bounds` | 이 RFC | #50428 |
| L2a | `http/h2-stream-reset` | D1: `Http_h2_stream` 의 reset 함수, 내보낸 RST_STREAM 규칙 | #50489 |
| L2a2 | `http/h2-ended-writer` | D1 의 나머지: `http_reqd.ml` 의 보고 두 곳(295·474줄), `Ended` writer | #50505 |
| L2b | `http/h2-flush-bound` | D2, D3(한 PR) | #50765 |
| L2b2 | `http/sse-h1-stall-timer` | D2 의 나머지: SSE `send` 타이머는 HTTP/1.1 에서만, 로그 스트림은 `Server_sse_response`, 로그 스트림 keepalive 시각, 핑 상수 하나 | |
| L3 | `deps/tls-2.1.5` | D9 | |
| L4a | `http/connection-socket-bounds` | D4, D6. TLS 연결의 보내기 쪽을 닫은 뒤 상한은 L4a2 |#51208 |
| L4a2 | `http/tls-send-shutdown-bound` | D4 의 나머지: `Tls_stream_socket.shutdown` 이 감싸개에 알린다 |#51209 |
| L4b | `http/tls-write-pieces` | D8: 쓰기 조각. 암호 순서는 측정 뒤 그대로 둠 | #51228 |
| L4c | `deps/tls-eio-fork-write` | D8: tls-eio 포크 고정, 감싸개의 복사 버퍼 삭제 | #51374 |
| L5 | `http/sse-producer-scope` | D7 | |
| L6 | `http/shared-payloads` | D5 | |
