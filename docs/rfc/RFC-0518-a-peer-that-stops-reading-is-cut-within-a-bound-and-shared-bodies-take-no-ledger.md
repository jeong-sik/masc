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

창 0 을 알린 HTTP/2 클라이언트의 SSE 스트림은 90초에 정체로 판정된다. 그런데 끝나지 않는다. 판정 뒤 masc 는 "남은 바이트를 다 보낸 뒤 닫기"만 할 수 있다. 창이 0 이면 그 조건이 오지 않는다. 그래서 보류한 바이트와 원장 예약이 상대가 움직이거나 연결이 끝날 때까지 남는다. 읽지 않는 클라이언트 하나는 대시보드 번들 77개로 응답 원장 64 MiB 를 채운다. 그동안 다른 연결의 큰 응답은 모두 503 이다. 연결 준비와 소켓 쓰기에는 시간 상한이 없고, TLS 는 암호문을 4 KiB 씩 쓴다.

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

- **reset 은 함수 하나다.** masc 가 HTTP/2 스트림을 끊는 일곱 곳이 모두 이 함수를 부른다. 레지스트리 35·56줄, `server_bootstrap_http.ml` 334·335줄, `http_h2_stream.ml` 10줄, `http_reqd.ml` 295줄(원장 거절)과 474줄(`Http_reqd.report_exn`)이다.
  - `H2.Reqd.error_code` 가 이미 있으면 아무것도 보내지 않는다. 이미 에러를 보고한 스트림에 다시 `report_exn` 을 부르면 h2 는 `failwith "h2.Reqd.report_exn: NYI"` 다(포크 reqd.ml 369줄).
  - 아니면 `H2.Reqd.report_exn` 을 부른다. 응답이 시작된 스트림이면 h2 는 본문을 닫고 RST_STREAM(INTERNAL_ERROR)을 보낸다(355줄). RST_STREAM 은 흐름 제어를 받지 않아 창 0 에서도 나간다(RFC 9113 §6.9). 응답 전이면 h2 는 error handler 로 500 을 연다(345줄).
  - 이 호출이 `Eio.Cancel.Cancelled` 가 아닌 예외를 내면 잡아서 debug 로 남긴다.
  - 끝에서(예외가 나도) 스트림 switch 를 `Stream_reset cause` 로 실패시킨다. `Eio.Switch.get_error` 가 이미 있으면 건너뛴다. 그래서 `Eio.Exn.Multiple` 이 생기지 않는다.
- **내보낸 RST_STREAM 도 스트림을 끝낸다.** frame tap 은 나가는 RST_STREAM 과 END_STREAM 을 이미 가른다(`server_h2_frame_tap.ml` 197·198줄). 나가는 RST_STREAM 이면 레지스트리가 `response_ended` 를 풀고 스트림 switch 를 `Stream_reset Reset_by_us` 로 실패시킨다(같은 조건). h2 가 스스로 보낸 stream error 와 masc 의 reset 이 같은 길로 끝난다. 지금은 switch 가 그 안의 fiber 를 기다리고, 그 fiber 는 h2 가 답하지 않는 flush 를 기다린다(조사 §1.3).
- **reset 이유는 타입 하나다.** `Peer_reset_stream` 을 지우고 `Http_reqd.Stream_reset of reset_cause` 로 합친다.

  ```ocaml
  type reset_cause =
    | Reset_by_peer
    | Reset_by_us
    | Stalled
    | Out_of_capacity of Http_h2_response_ledger.refusal
  ```

  레지스트리 `dispatch` 는 `Stream_reset _` 를 조용히 받는다. `peer_reset` 도 `get_error` 가 있으면 건너뛴다.
- **끝난 스트림에는 응답을 열지 않는다.** `respond_*` 는 스트림이 끝났으면 h2 를 부르지 않고 닫힌 writer 를 돌려준다. `Body_writer` 에 생성자 `Ended` 를 더한다. 쓰기는 버리고, flush 는 `` `Closed `` 로 답하고, `is_closed` 는 true 다. h2 의 `Assert_failure`(reqd.ml 276줄)가 새지 않는다.
- **HTTP/1.1 에는 끊을 스트림이 없다.** `Httpun.Reqd.report_exn` 은 본문을 force-close 하고(마지막 chunk 를 보내지 않음) 연결을 non-persistent 로 만든다. 막힌 소켓 쓰기는 풀지 못한다. httpun 은 흐름 제어가 없고 flush 답은 소켓 쓰기 뒤에 온다. 그래서 HTTP/1.1 의 정체는 TCP 정체이고 D4 가 소켓을 닫는다.

### D2. HTTP/2 스트림 안의 flush 는 정체 상한 안에 답을 받는다

- **상한은 90초다.** 스트림의 flush 하나가 90초 안에 답을 받지 못하면 D1 으로 끊는다(`Stalled`). 요청 경로를 warn 한 줄로 남긴다.
- **`Stream_end` 는 레지스트리가 스트림마다 만든다.** 지금은 `Http_reqd.of_h2` 가 만든다(`http_reqd.ml` 121줄). 레지스트리가 스트림 switch 를 열 때 만들고, 감시 daemon 하나를 그 switch 에 둔다. daemon 은 switch 를 붙잡지 않는다.
- **`Stream_end` 를 fiber-local 로 묶는다.** `Eio.Fiber.with_binding` 은 fork 한 fiber 에도 이어진다(eio 1.3 `eio__core.mli` 387~394줄). 그래서 스트림 fiber 에서 건 flush 가 모두 여기 걸린다.
  - `Http_reqd` 의 writer flush
  - gateway error handler 의 `Http_h2_stream.close_after_flush`(`server_h2_gateway.ml` 25줄)
  - 요청 본문 콜백을 스트림 switch 로 미루는 `Http_h2_stream.dispatch`(`http_reqd.ml` 421줄). 이 fork 는 연결 reader fiber 에서 일어나므로 원장처럼 명시적으로 다시 묶는다.
- **SSE `send` 의 자체 타이머는 HTTP/1.1 에서만 돈다.** HTTP/2 에서 같은 상한의 타이머 둘이 겨루지 않는다. 로그 스트림의 자체 send 와 정체 판정은 지우고 `Server_sse_response` 를 쓴다.
- **상한은 lib/ 의 상수 하나다.** 값은 지금과 같은 90초다. `sse_stalled_after_s`(`server_mcp_transport_http_headers.ml` 294줄), `observer_idle_timeout_ms`(299줄), 로그 스트림의 `stalled_after_s` 가 이 상수를 쓴다. `server_mcp_transport_http_agui.ml` 16줄의 따로 적은 `30.0` 은 `sse_ping_interval_s` 로 바꾼다. 핑 간격(30초)은 상한보다 짧아서 읽는 클라이언트는 상한 안에 늘 프레임을 받는다.

### D3. 소유한 통째 본문은 16 KiB 조각으로 쓴다

- **조각 크기는 16 KiB 다.** 기본 `SETTINGS_MAX_FRAME_SIZE` 의 DATA 프레임 하나이고 TLS 레코드 하나다.
- **원장 예약은 지금처럼 본문 전체다.** 원본 문자열이 응답이 끝날 때까지 메모리에 있기 때문이다. h2 에 들어가는 사본은 16 KiB 이하가 된다.
- **헤더를 보낸 뒤 스트림 switch 의 fiber 가 조각을 쓴다.** 조각마다 flush 를 기다린다(D2 상한). 마지막 조각 뒤 본문을 닫고 예약을 푼다. 조각 하나에 들어가는 본문은 지금처럼 바로 쓴다.
- **MCP POST 결과도 같은 길로 간다.** `safe_respond_chunked`(`server_mcp_transport_http.ml` 58~62줄)의 HTTP/2 쪽이다. 지금은 큰 결과를 flush 하나로 기다린다. D2 를 그대로 걸면 천천히 읽는 정상 클라이언트가 90초에 끊긴다.
- **헤더 뒤 예외는 D1 reset 으로 끝낸다.** 지금의 `release; raise` 를 지운다.

### D4. 연결 쓰기 상한

- **`Server_connection_socket` 이 accept 한 소켓을 감싼다.** 평문·TLS, HTTP/1.1·HTTP/2 모두다. TLS 는 이 감싸개 위에서 돈다.
- **쓰기 조각마다 기한을 하나 건다.** 한 번에 넘기는 쓰기를 256 KiB 이하로 나눈다. 조각 하나의 쓰기 루프 전체가 D2 와 같은 90초 안에 끝나야 한다.
- **기한을 넘기면 연결을 닫는다.** `SO_LINGER 0` 을 걸고 양방향 shutdown 한다. 그 쓰기와 뒤의 모든 쓰기는 `End_of_file` 을 낸다. 읽기는 EOF 를 본다.
- **EPIPE·ECONNRESET 도 `End_of_file` 로 바꾼다.** gluten 은 `End_of_file` 만 `` `Closed `` 로 바꾸고 writer 를 drain 한다(gluten_eio.ml 47줄). 다른 예외는 `report_exn` 으로 가서 flush 콜백이 오지 않는다(조사 §2.1).
- **서버가 보내기 쪽을 닫은 뒤에도 같은 상한을 둔다.** 그 안에 상대가 닫지 않으면 양방향을 닫는다. gluten 의 마지막 EOF 읽기에는 기한이 없다(gluten_eio.ml 122~145줄).

### D5. 바뀌지 않는 본문은 참조로 보내고 원장을 쓰지 않는다

- **공유 본문 타입을 둔다.** `Shared_body.t` 는 만든 뒤 바꾸지 않는 bigstring 이다. private 타입이라 만드는 함수만 값을 만들 수 있다.
- **`Http_reqd.respond_with_shared` 를 더한다.**
  - HTTP/1.1 은 bigstring 을 복사 없이 건다.
  - HTTP/2 는 16 KiB `schedule_bigstring` 조각으로 보내고 조각마다 D2 상한을 건다. h2 는 이 bigstring 을 복사하지 않는다(h2.mli 385줄).
  - 요청마다 생기는 사본이 없으니 원장 예약도 없다.
- **대시보드 정적 asset 이 첫 사용처다.**
  - 읽을 때마다 receipt 와 digest 를 검증하는 계약은 그대로다(`lib/installed_dashboard.mli` 29줄).
  - 검증한 (경로, sha256) 의 표현 셋(identity, zstd, gzip)을 캐시에서 꺼내 보낸다. 캐시는 경로마다 한 항목이고 digest 가 바뀌면 바꾼다.
  - 압축은 asset 판마다 한 번이다. 지금은 요청마다 압축한다(`server_routes_http_pages.ml` 253줄).
- **#50294 의 측정 장면에서 원장 사용량이 0 이 된다.** 번들 77개를 쥔 클라이언트는 원장을 쓰지 않는다. cloudflared 연결 안의 다른 원격 사용자도 막지 않는다.

### D6. 연결 준비는 30초 안에 끝나야 한다

- 상한을 거는 곳: TLS handshake(`server_bootstrap_http.ml` 484줄), 평문 프로토콜 판별(391줄), HTTP/1.1 전용·h2c 리스너의 첫 읽기.
- 기한을 넘기면 연결을 닫고 리스너의 handshake 실패 카운터를 올린다(TLS 일 때).
- 근거: piaf `accept_timeout` 30 s, nginx `client_header_timeout` 60 s. Go 는 `ReadTimeout`·`ReadHeaderTimeout`·`WriteTimeout` 중 양수 최솟값을 handshake 에 건다(조사 §2.3, §3.1).

### D7. 응답이 생산자 수명을 가진다

- `Server_sse_response.serve ~sw t produce` 를 더한다. 생산자를 `await_closed t` 와 겨루게 하고, 어느 쪽이 먼저 끝나든 응답을 닫는다.
- switch 는 호출자의 것을 쓴다. pump 가 이미 이렇게 돈다. 스트림 switch 로 옮기지 않으므로 생산자가 스트림 switch 를 붙잡는 순환 대기가 없다.
- cleanup 은 fork 하기 전에 등록한다. fork 가 돌기 전에 switch 가 끝나도 응답이 닫힌다.
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
- 고칠 파일: `lib/server/server_tls_material.ml` 87줄, `packages/agent_core/test/test_tls_cancellability.ml` 32줄, `masc.opam`, `dune-project`(126~129줄의 상한 주석과 제약), `masc.opam.locked`.
- D8 보다 먼저 낸다. D8 은 2.1.5 위에서 재고, 2.1.5 의 `write_t` 를 다시 읽는다.

## 2. 지금 모습

조사 §1 이 줄 번호로 적었다. 결정과 닿는 것만 다시 적는다.

| 자리 | 지금 | 이 RFC 뒤 |
|---|---|---|
| 정체 판정 뒤 HTTP/2 | `close_after_flush` 가 오지 않는 flush 를 기다린다 | RST_STREAM 을 보내고 스트림 switch 를 끝낸다 |
| masc·h2 가 보낸 RST_STREAM | `response_ended` 만 풀린다. switch 는 안의 fiber 를 기다린다 | switch 가 실패하고 기다리던 flush 가 `` `Closed `` 로 답을 받는다 |
| 통째 본문 | 본문 전체를 h2 에 한 번에 복사하고 flush 하나를 기다린다. 시간 상한 없음 | 16 KiB 조각, 조각마다 90초 |
| 대시보드 asset | 요청마다 읽고, 압축하고, 사본을 원장에 넣는다 | 요청마다 검증하고, 압축본 하나를 참조로 보낸다 |
| 로그·초안·실행 출력 생산자 | 다음 이벤트나 핑까지 산다 | 응답이 닫히면 바로 끝난다 |
| 소켓 쓰기 | 기한 없음 | 256 KiB 조각마다 90초 |
| handshake·첫 읽기 | 기한 없음 | 30초 |
| TLS 쓰기 | 암호문 4 KiB 마다 `writev` | 레코드 하나, 그 뒤 256 KiB 버퍼 |

## 3. 왜 이 모양인가

### 3.1 h2 포크를 먼저 고치지 않는다

`on_close_stream` 에서 응답 본문을 닫고 drain 하면 reset 때 flush 가 `` `Closed `` 로 끝난다. 원인 자리를 고치는 방법이다. 하지만 그 스트림의 DATA 가 연결 writer 에 남아 있으면 faraday 의 `assert (written = 0)`(faraday.ml 378줄)에 걸린다(추정). 그리고 h2 에는 timer 가 없다. 창을 안 여는 상대를 끊는 판단은 어차피 masc 몫이다. D1 은 지금 공개 API(`report_exn`, `error_code`)만 쓴다. 포크 정리는 따로 남긴다(§7).

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
- 소켓 쓰기가 90초 동안 끝나지 않는 연결은 닫힌다. 클라이언트는 TCP RST 를 본다.
- 30초 안에 handshake 나 첫 요청 바이트를 보내지 않는 연결은 닫힌다.
- 대시보드 asset 응답은 원장을 쓰지 않는다. 압축은 asset 판마다 한 번 한다.
- TLS 처리량과 서버 CPU 가 바뀐다. 설치 뒤 같은 탐침으로 잰 값을 기록한다.
- 설정 칸은 더하지 않는다. 상한은 코드 상수다.

## 5. 알려진 한계

- **연결 창.** 다른 스트림이 연결 창을 다 쓰면 모든 스트림이 늦는다. 그때는 가장 오래 기다린 스트림이 먼저 끊긴다.
- **최소 배출 속도.** 16 KiB 조각에 90초면 스트림당 182 B/s 다. 스트림 N 개가 느린 링크 하나를 나눠 쓰면 링크는 N × 182 B/s 를 넘어야 한다. 100개면 18 KiB/s 다.
- **그 속도 바로 위로 읽는 상대.** 소유 본문의 예약을 오래 쥔다. 861,256 B 본문이면 약 79분이다. D5 가 정적 asset 을 이 경우에서 뺀다. artifact 와 MCP 결과 같은 소유 본문은 인증 뒤에만 받는다.
- **HTTP/1.1 이탈.** httpun 은 응답 중에 읽지 않는다. 이탈은 여전히 쓰기 실패로만 안다.
- **reset 코드.** INTERNAL_ERROR 하나다(§3.4).

## 6. 확인 방법

- 로컬 dune 빌드는 하지 않는다. 타입 검사와 시험 실행은 cmi 스냅샷과 실제 링크 도구로 한다. 전체 빌드와 시험은 CI 가 한다.
- 시험 하네스를 고친다. `test/test_h2_response_window.ml` 의 메모리 안 h2 펌프는 root switch 를 스트림 switch 로 넘기고, 조각 writer 가 돌 틈을 주지 않는다. 스트림마다 `Switch.run` 을 두고 `Fiber.yield` 나 mock clock 진행을 넣는다.
- 새 시험은 프로토콜·자원 경계만 본다. clock 은 `Eio_mock` 이다.
  - 창 0 SSE 스트림: 상한 뒤 RST_STREAM 이 오고 원장 사용량이 0 이 된다.
  - 응답을 시작한 handler 가 예외를 내면 조각 writer 와 예약이 바로 풀린다.
  - 창보다 큰 통째 본문: 창을 안 여는 클라이언트는 상한 뒤 RST_STREAM 을 받고, 창을 여는 클라이언트는 본문 전체를 받는다.
  - 큰 MCP POST 결과를 천천히 읽는 클라이언트도 끝까지 받는다.
  - 창 0 에서 연 오류 응답은 상한 뒤 RST_STREAM 으로 끝난다.
  - 공유 본문 응답 둘을 보내는 동안 원장 사용량이 0 이다.
  - 이벤트를 기다리는 생산자는 스트림 reset 과 close 에 바로 취소된다.
  - 소켓 감싸개: `copy` 가 모든 바이트를 순서대로 쓴다. 상대가 안 받는 쓰기는 상한 뒤 `End_of_file` 이고, 뒤 쓰기도 같고, 읽기도 EOF 다(socketpair). 아무것도 안 보내는 연결은 준비 상한 뒤 닫힌다.
  - 음성 대조: reset 함수, 내보낸 RST_STREAM 규칙, 감시 daemon, 조각 기다림을 각각 뺀 변이에서 해당 시험이 실패한다.
- 설치 뒤 실측. 사용자가 층별 빌드를 설치하고 재시작하면 evidence 묶음의 탐침을 같은 호스트에서 다시 돌린다.
  - `h2_stall_probe.py`: 90초쯤 RST_STREAM 3개가 온다.
  - `ledger_starvation_probe.py`: 번들 90개를 쥔 클라이언트가 있어도 정상 클라이언트의 번들이 200 이다.
  - `h2_sse_leak_probe.py`: descriptor, 연결 수, `sse_clients` 가 지금처럼 제자리로 온다.
  - `tls_cpu_probe.py` 와 벤치: 서버 ms/MB 와 클라이언트(OpenSSL, Go) ms/MB 의 전·후 표를 남긴다.
  - 결과는 `docs/evidence/` 에 새 묶음으로 남긴다.

## 7. 하지 않는 것

아래는 `gh issue create` 로 따로 남긴다.

1. 사전 압축 JSON 스냅샷(`Http_response_payload.prepared` 사용처)을 공유 본문으로 옮긴다.
2. artifact 바이트를 범위 읽기로 바꾼다. 지금은 32 MiB blob 을 요청마다 통째로 올린다.
3. h2 포크 정리: `on_close_stream` 의 본문 drain, `Reqd.stream_id` 공개, #278 조건 고침으로 `close_after_flush` 와 frame tap 을 지움, upstream h2#265 이식.
4. 연결 수, idle, 헤더 시간 상한. TLS 뒤 h2 preface 대기, 여러 연결이 같이 읽지 않을 때의 소유 본문과 descriptor 고갈도 여기 든다.
5. 들어오는 창 2^27(연결당 128 MiB)을 줄인다. Go 는 1 MiB, Envoy edge 권장은 스트림 64 KiB 다.
6. HTTP/2 DoS 완화: rapid reset(양방향 reset 세기), CONTINUATION, 헤더 개수.
7. HTTP/1.1 스트리밍 중 이탈 감지.
8. pump 와 HTTP/1.1 생산자의 domain 문제(#48907 의 나머지).

## 8. 층

worktree `.worktrees/h2-backpressure` 에서 gh stack 으로 쌓는다. 맨 아래가 main 이다. 층마다 Draft 를 열고 현재 head 의 독립 리뷰를 받는다.

| 층 | 브랜치 | 결정 | PR |
|---|---|---|---|
| L0 | `research/h2-sse-stalled-responses` | 조사 문서와 실측 기록 | #50417 |
| L1 | `rfc/0518-stalled-peer-bounds` | 이 RFC | |
| L2a | `http/h2-stream-reset` | D1 | |
| L2b | `http/h2-flush-bound` | D2 | |
| L2c | `http/h2-body-slices` | D3, 시험 하네스 | |
| L3 | `deps/tls-2.1.5` | D9 | |
| L4 | `http/connection-socket-bounds` | D4, D6, D8 | |
| L5 | `http/sse-producer-scope` | D7 | |
| L6 | `http/shared-payloads` | D5 | |
