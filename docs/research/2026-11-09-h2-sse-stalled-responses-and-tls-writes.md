# 읽지 않는 HTTP/2 상대가 스트림과 응답 원장을 놓지 않는 문제, 그리고 TLS 쓰기 조사

- 확인 시각: 2026-11-09. 다른 저장소 코드는 02:48Z ~ 03:13Z 에 읽었다. 읽기만 했고 빌드·실행은 하지 않았다. masc 측정은 격리 서버에서 했다(§4).
- 판정 대상 head: `origin/main` `1cab54b0abea`. 줄 번호는 이 트리 기준이다. 측정한 빌드 `0a7164246935`·`57b928783c0b` 와 이 head 사이에 전송 코드는 시작 배너 한 줄만 다르다.
- 이 문서는 조사이고 결정이 아니다. 결정은 RFC-0518 에 적는다. 실행 기록은 [`docs/evidence/research/2026-11-09-h2-sse-tls/`](../evidence/research/2026-11-09-h2-sse-tls/README.md) 에 있다.
- 관련 이슈: #50294(원장 고갈), #50295(생산자 수명), #50296(TLS 처리량), #49905(연결 준비 상한).

## 0. 요약

- 창 0 을 알린 HTTP/2 클라이언트가 로그 SSE 스트림 3개를 열었다. 서버는 90초에 셋 다 정체로 판정했다. 그런데 105초까지 RST_STREAM 을 하나도 보내지 않았다. 창을 열자 쌓인 36,839 B 와 END_STREAM 이 나갔다. 정체한 HTTP/2 스트림은 상대가 움직일 때까지 끝나지 않는다(§1.4, §4.3).
- 읽지 않는 클라이언트 하나가 대시보드 번들 77개(66.3 MB)로 리스너 원장 64 MiB 를 채웠다. 그동안 다른 연결의 큰 응답은 모두 503 이었다(§4.2, #50294).
- 로그·문서 초안·실행 출력의 생산자는 스트림이 끝난 뒤에도 다음 이벤트나 핑까지 산다(§1.5, #50295).
- TLS handshake 와 평문 프로토콜 판별에는 시간 상한이 없다(§1.7, #49905).
- TLS 처리량은 평문의 1/7~1/12 다. 원인은 tls-eio 가 암호문을 4 KiB 씩 쓰는 경로다. masc 밖 벤치에서 암호문을 16 KiB 이상으로 쓰면 서버 CPU 가 MB 당 41~45% 줄었다. AES-128 로 861 KB 를 한 번에 쓴 값이다(§1.8, §4.4, #50296).
- OCaml HTTP 서버·라이브러리 9개를 읽었다. 멈춘 응답의 시간 상한, 끊긴 상대 알림, SSE keepalive 를 다 갖춘 곳은 없다. 가져올 부품은 piaf 의 조각당 flush 대기, haha 의 reset 콜백, tiny_httpd 의 연결 semaphore 다(§2).
- 성숙한 서버는 쓰기 시간을 스트림이나 연결 단위로 잰다(Go `WriteTimeout`, nginx `send_timeout`). 2026-06 에 공개된 HTTP/2 bomb 는 1바이트 WINDOW_UPDATE 로 진척을 흉내 낸다. 그래서 진척마다 늘어나는 타이머로는 막지 못한다(§3).

## 1. 지금 masc 의 동작

### 1.1 응답 원장

HTTP/2 응답이 아직 상대에게 못 보낸 바이트는 `Http_h2_response_ledger` 가 센다(`lib/http_h2_response_ledger.ml`).

- 리스너마다 원장이 하나다(`Server_bootstrap_http.shared_h2_resources`, 197줄). 기본 용량은 64 MiB 다(`H2_response_limits.default_max_pending_bytes`, `lib/config/h2_response_limits.ml` 7줄).
- 통째 본문은 헤더를 보내기 전에 본문 전체를 예약한다(`Http_reqd.h2_respond_with_string`, 228줄). 예약이 안 되면 빈 503 `no-store` 로 답한다(`h2_refuse_for_capacity`, 210~226줄).
- 스트리밍 본문은 조각마다 예약한다(`Body_writer.write_string`, 283줄). 예약이 안 되면 그 스트림을 끊는다.
- 예약은 그 조각의 flush 콜백(`write_reserved`, 63줄)이나 스트림 switch 해제(`with_request`, 52줄)에서 풀린다.
- 원장 사용량은 `/health` 에도 메트릭에도 나오지 않는다.
- 응답에는 시간 상한이 없다. `docs/guides/h2-response-resources.md` 37줄이 "There is no response idle timeout." 이라고 적는다.

### 1.2 h2 가 본문을 내보내는 방식

h2 0.13.0 포크(`jeong-sik/ocaml-h2@d7601f2`)는 본문 Faraday 의 iovec 을 연결 writer 에 참조로 건다(`Body.Writer.transfer_to_writer`, body.ml 200~230줄). 연결 writer 가 그 바이트를 소켓에 쓴 뒤에야 본문 Faraday 를 비운다. 그래서 상대의 창이 0 이면 본문이 Faraday 에 그대로 남는다. 그 본문에 건 flush 콜백도 오지 않는다. flush 콜백이 오지 않는 경우는 §2.1 에 모았다.

- `Body.Writer.schedule_bigstring` 은 복사하지 않고 bigstring 을 건다(h2.mli 385줄). 공유하는 불변 bigstring 은 스트림마다 사본을 만들지 않는다.
- 서버가 스트림을 끊는 공개 API 는 `Reqd.report_exn` 하나다. INTERNAL_ERROR 로 RST_STREAM 을 보낸다(reqd.ml 390줄). CANCEL 로 끊는 공개 API 는 없다.
- RST_STREAM 은 흐름 제어를 받지 않는다. RFC 9113 §6.9 는 DATA 프레임만 흐름 제어 대상으로 둔다. 그래서 창이 0 이어도 나간다.

### 1.3 masc 가 스트림의 끝을 아는 길

h2 의 공개 API 는 스트림이 끝났다고 알려 주지 않는다(§2.1). masc 는 소켓을 감싸 프레임 머리만 읽는다(`Server_h2_frame_tap`).

- 들어오는 RST_STREAM 은 `on_peer_reset` 을 부른다(`server_h2_frame_tap.ml` 190줄). 레지스트리가 그 스트림 switch 를 `Peer_reset_stream` 으로 실패시킨다(`server_h2_stream_registry.ml` 67줄).
- 나가는 RST_STREAM 과 END_STREAM 은 `on_response_end` 를 부른다(197~199줄). 레지스트리가 `response_ended` 약속을 푼다(70~75줄).
- 스트림 switch 는 `run_scope` 가 연다(30~36줄). 핸들러가 돌아온 뒤에도 `response_ended` 를 기다린다. 그래서 응답 생산자가 그 switch 에서 계속 돈다.
- `Http_reqd.Stream_end` 는 스트림 switch 가 풀릴 때 기다리던 flush 를 모두 `` `Closed `` 로 답한다(`lib/http_reqd.ml` 16~63줄).
- masc 가 `H2.Reqd.report_exn` 을 부르는 곳은 일곱이다. 레지스트리 35·56줄, `server_bootstrap_http.ml` 334·335줄, `lib/http_h2_stream.ml` 10줄, `http_reqd.ml` 295줄(원장 거절)과 474줄(`Http_reqd.report_exn`)이다. `Http_reqd.report_exn` 을 부르는 곳은 시험(`test/test_h2_response_window.ml`)뿐이다.
- masc 가 RST_STREAM 을 보내면 `response_ended` 는 풀린다. 하지만 스트림 switch 는 실패하지 않는다. `Switch.run` 은 그 안의 fiber 가 모두 끝나야 돌아온다. h2 는 끊은 스트림의 flush 에 답하지 않는다. 그래서 flush 를 기다리는 fiber 가 있으면 switch 가 풀리지 않고, `Stream_end` 도 답하지 않는다.

### 1.4 정체한 HTTP/2 응답은 끝나지 않는다

SSE 응답은 한 프레임이 `sse_stalled_after_s`(90초) 안에 소켓에 닿지 않으면 정체로 본다(`server_mcp_transport_http_headers.ml` 294줄). 그때 `Server_sse_response.send` 는 응답을 `close` 한다(`server_sse_response.ml` 95줄). 로그 스트림은 자체 send 와 같은 90초 상수를 쓴다(`server_routes_http_routes_log_stream.ml` 6~7줄). 끝에서는 같은 `Body_writer.close` 를 부른다(124~127줄). HTTP/2 의 `close` 는 `close_after_flush` 다(`http_reqd.ml` 205줄). 남은 바이트가 다 나간 뒤 닫으려고 flush 를 건다. 이 대기는 고리를 이룬다.

1. 창이 0 이라 h2 는 flush 에 답하지 않는다.
2. `Stream_end` 는 스트림 switch 가 풀려야 답한다.
3. 스트림 switch 는 `response_ended` 를 기다린다.
4. `response_ended` 는 END_STREAM 이 나가야 풀린다.
5. END_STREAM 은 flush 뒤에 나간다.

고리를 끊는 것은 상대의 RST_STREAM, 창을 여는 WINDOW_UPDATE, 연결 종료뿐이다. 그때까지 원장 예약과 보류한 바이트가 남는다. §4.3 이 이것을 격리 서버에서 확인한다.

통째 본문에는 정체 판정이 아예 없다. 창을 열지 않는 상대에게 보낸 응답은 연결이 끝날 때까지 예약을 쥔다(§4.2).

### 1.5 SSE 생산자

| 스트림 | 파일 | 프레임을 보내는 곳 | 생산자가 도는 switch | 클라이언트가 떠난 것을 아는 때 |
|---|---|---|---|---|
| fleet, Keeper 대화, MCP `subscriptions/listen`, MCP GET·AG-UI·presence | `server_routes_http_routes_fleet_stream.ml` 외 | `Server_sse_pump.run ~closed` | 런타임 switch | 바로(#49862 뒤 `~closed`) |
| 로그 | `server_routes_http_routes_log_stream.ml` 72~137줄 | 자체 send·정체 판정 | 런타임 switch | 다음 로그 줄이나 핑(30초) |
| 문서 초안 | `server_routes_http_routes_artifact_draft_live.ml` 15~55줄 | `Server_sse_response.send`, daemon 둘 | 런타임 switch | 다음 초안이나 핑(30초) |
| 실행 출력 | `server_routes_http_routes_dashboard.ml` 123~238줄 | `Server_sse_response.send`, heartbeat | 런타임 switch | 다음 이벤트나 heartbeat(15초) |
| 질문 후속, 계정 로그인, Keeper API 로그인 | `server_routes_http_keeper_asks.ml` 외 | 핸들러 fiber | 요청 fiber | HTTP/2 는 바로, HTTP/1.1 은 다음 send |

런타임 switch 에서 도는 생산자는 스트림보다 오래 산다. HTTP/2 스트림이 끝나도 생산자는 다음 쓰기에서야 그것을 안다.

### 1.6 HTTP/1.1 은 응답하는 동안 소켓을 읽지 않는다

httpun 은 요청 입력이 끝나고 응답이 진행 중이면 읽지 않는다(server_connection.ml 278~286줄). 연결이 persistent 가 아니면 reader 를 닫고, persistent 면 `Yield` 한다. 그래서 응답 중에는 상대가 보낸 FIN 을 볼 수 없다. HTTP/1.1 은 다음 쓰기가 실패할 때(EPIPE) 클라이언트가 떠난 것을 안다.

httpun 에는 흐름 제어가 없다. 본문의 남은 바이트를 모두 연결 writer 로 넘긴다(body.ml 217줄 이하). HTTP/1.1 의 정체는 곧 TCP 송신 버퍼의 정체다. `Httpun.Reqd.report_exn` 은 본문을 force-close 하고 연결을 non-persistent 로 만든다. 그래도 막힌 소켓 쓰기는 풀지 못한다.

### 1.7 연결을 여는 동안의 시간 상한

TLS 리스너는 `Tls_eio.server_of_flow` 를 시간 상한 없이 부른다(`server_bootstrap_http.ml` 484줄, `serve_tls` 466줄). 평문 리스너도 프로토콜 판별의 첫 읽기(`Http_protocol_detect.detect`, 391줄)에 상한이 없다. 연결만 열고 아무것도 보내지 않는 상대는 fiber 와 descriptor 를 계속 쥔다(#49905). §4.1 의 handshake 실패 시나리오에서 서버는 연결마다 5초 동안 답하지도 닫지도 않았다. 탐침의 `recv` 가 5초 기한을 매번 다 썼다.

### 1.8 TLS 쓰기 경로

- tls-eio 는 암호문을 `Flow.copy_string` 으로 쓴다(tls_eio.ml 49줄 `write_t`).
- eio 판은 `masc.opam.locked` 의 1.3 이다. eio_posix 소켓의 `copy` 는 원천이 `Read_source_buffer` 를 주지 않으면 `Eio.Flow.Pi.simple_copy` 로 간다(eio_posix flow.ml 74~80줄). `simple_copy` 는 4096 바이트 버퍼로 읽고 쓴다(eio flow.ml 62~76줄). `String_source` 는 read method 가 없다(139줄).
- 그래서 TLS 응답은 암호문 4 KiB 마다 `writev` 를 한 번 부른다. accept 한 소켓은 `TCP_NODELAY` 라 조각마다 세그먼트가 따로 나간다.
- 받는 쪽 버퍼도 4096 바이트다(tls_eio.ml 192줄).
- masc 의 `Tls_stream_socket` 은 tls-eio 흐름을 그대로 넘긴다(`lib/server/tls_stream_socket.ml` 10줄 `copy`).
- upstream `mirleft/ocaml-tls` main 도 같은 경로다(2026-11-09 확인).

암호는 서버 목록 순서로 고른다. tls 서버는 자기 목록에서 클라이언트도 낸 첫 suite 를 고른다(handshake_server13.ml 66줄 `Utils.first_match`). 기본 목록은 AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305, AES-128-CCM 순서다(config.ml 103~108줄). 클라이언트가 셋을 다 내면 masc 는 AES-128-GCM 을 골랐다(§4.4 run3, `openssl s_client`). 이 arm64 빌드의 `Mirage_crypto.accelerated` 는 빈 목록이다. mirage-crypto 는 x86_64 에서만 AES·GHASH 가속을 켠다(mirage-crypto `config/cfg.ml` 34~38줄).

`masc.opam.locked` 의 tls 는 2.1.2 다. 그 뒤 릴리스가 고친 것 중 이 리스너와 닿는 것은 셋이다.

- 조작한 상대가 일으키는 메모리 누수(v2.1.5, mirleft/ocaml-tls#540)
- 16 KiB 경계의 빈 레코드(v2.1.5, #539)
- 중복 SupportedVersion 으로 서버가 멈추는 일(v2.1.4, #531)

opam 메타데이터로는 2.1.4 부터 x509 1.2.0 이상이 필요하다(2026-11-09 `opam show` 확인). 2.1.3 의 CHANGES 는 X509 1.2.0 에 맞췄다고 적지만 opam 제약은 1.0.0 이상이다. masc 는 x509 를 1.2 미만으로 묶었다(`dune-project` 126~129줄, #44339). 1.2 의 `CN` 생성자가 문자열 대신 `Common_name.t` 를 받기 때문이다. `CN` 을 쓰는 곳은 `lib/server/server_tls_material.ml` 87줄과 `packages/agent_core/test/test_tls_cancellability.ml` 32줄이다.

## 2. 다른 OCaml 서버

읽은 저장소와 커밋은 §6.1 에 있다. 줄 번호는 그 커밋 기준이다. "추정"은 코드를 읽고 끌어냈지만 실행으로 확인하지 않은 것이다.

### 2.1 h2·httpun·gluten 코어

세 판을 읽었다. [m] 은 h2 master `a5449e52ad00`, [t] 는 태그 0.13.0 `49c0591ce90e`, [f] 는 masc 가 쓰는 포크 `d7601f201da8` 다. 포크는 0.13.0 에 커밋 둘(`38293f3bb2d7`, `d7601f2`)을 더했고 master 의 커밋 7개는 없다.

응답 본문에는 상한이 없다.

- `write_string`·`write_bigstring` 은 Faraday 에 복사한다. 자리가 없으면 새 bigstring 을 할당한다(faraday.ml 231~248줄). `schedule_bigstring` 은 복사 없이 큐에 건다(221~229줄).
- `response_body_buffer_size`(4096)는 첫 버퍼 크기일 뿐이다(config.ml 62줄, reqd.ml 244줄). 스트림·연결 단위 상한은 없다.
- 창이 0 이면 `Scheduler.write` 가 `max_bytes:0` 을 넘기고 본문을 옮기지 않는다(scheduler.ml [t][f] 359~369줄).
- `` `Written `` 은 연결 writer 가 바이트를 소켓에 넘긴 뒤다. 상대가 받았다는 뜻이 아니다(serialize.ml [t][f] 617~620줄, gluten_eio.ml 37~47·150~158줄).

flush 콜백이 오지 않는 경우가 셋이다.

| 경우 | 근거 | 확인 |
|---|---|---|
| 창이 0 인 동안 | reqd.ml [f] 464줄 `flush_response_body` 가 옮기지 않음 | 코드, §4.3 측정 |
| 상대가 RST_STREAM 을 보낸 뒤 | `requires_output` 이 false(reqd.ml [f] 421줄), `flush_response_body` 가 0(520줄) | 코드 |
| 소켓 쓰기가 `End_of_file` 아닌 예외로 끝날 때 | eio_posix 가 EPIPE·ECONNRESET 을 `Connection_reset` 으로 올림(err.ml 24줄), gluten 은 `End_of_file` 만 `` `Closed `` 로 바꿈(gluten_eio.ml 47줄), 나머지는 `report_exn`(169줄) | 추정 |

`` `Closed `` 는 연결 writer 가 닫히거나 drain 될 때만 온다(body.ml [m] 145~150·170~173줄).

스트림의 끝은 공개 API 로 알 수 없다.

- `Reqd` 공개 API 에 stream id, reset 콜백, `on_close` 가 없다(h2.mli [f] 579~581줄). 세 판이 같다.
- `Reqd.error_code` 는 앱이 보고한 에러만 준다(stream.ml [f] 148줄). 상대가 보낸 코드는 `Closed { reason = ResetByThem }` 에만 남는다.
- 상대의 RST_STREAM 은 `finish_stream` 만 부른다(server_connection.ml [f] 865줄). `on_close_stream` 은 응답 writer 를 닫지 않는다([m][t] 168~176줄). 같은 보고가 h2#279(open, 2026-10-18)다.
- 닫힌 스트림에 `Reqd.request`·`respond_*` 를 부르면 `Assert_failure` 다(reqd.ml 107·221·276줄).
- 포크에만 있는 신호가 하나 있다. `Body.Reader.completion` 이 reset 뒤 `Aborted` 가 된다(h2.mli [f] 330~335줄, [f] 176~186줄). 요청 본문을 읽는 중이 아니면 이 값은 poll 로만 본다.
- 닫힌 본문에 쓰면 조용히 버린다(body.ml [m] 129~142줄). h2.mli 는 raise 한다고 적는다([m] 386줄, [f] 400줄).

h2#278 은 jeong-sik 이 연 이슈다(open). 창이 0 이고 본문이 남았는데 본문을 닫으면 END_STREAM 이 먼저 나간다. 세 판 모두 있다(reqd.ml [m] 459·467줄, [f] 464·472줄). masc 의 `close_after_flush` 가 이것을 피하는 우회다(§1.4).

httpun 0.2.0(`80755658e548`)은 흐름 제어가 없다. 남은 바이트를 모두 연결 writer 로 넘긴다(body.ml 217줄 이하). flush 는 연결 writer 의 flush 까지 기다린다(171~179줄). keep-alive 응답 중에는 reader 가 `Yield` 라 FIN 을 못 본다(server_connection.ml 284줄). `Connection: close` 일 때만 gluten 의 마지막 poll 이 EOF 를 본다(gluten_eio.ml 122~145줄). 그 밖에는 다음 쓰기가 실패해야 안다. httpun#155 는 flush 가 아예 돌지 않는 경우를 보고한다.

설정과 연결 수준 동작은 이렇다.

- `H2.Config` 기본값: `read_buffer_size` 16384, 본문 버퍼 4096, `enable_server_push` true, `max_concurrent_streams` `Int32.max_int`, `initial_window_size` 2^27(config.ml 75줄). 기본값인 항목은 SETTINGS 에 실리지 않는다(settings.ml 157·163~183줄). h2.mli [m] 677줄은 창 기본값을 65535 로 잘못 적는다.
- preface 처리가 연결 수신 창을 2^27 로 올린다([f] 1193~1202줄). 앱이 읽기 전에 연결당 128 MiB 까지 들어온다.
- GOAWAY 는 연결 에러 때만 보낸다. 우아한 종료 요청 h2#241 은 열려 있다. 서버가 PING 을 보내는 공개 API 는 없다(h2.mli [m] 689~799줄).
- rapid reset, CONTINUATION 개수, 헤더 블록 크기를 막는 코드는 없다(추정). 트래커에서 "44487", "rapid", "reset flood", "max_header_list_size", "DoS", "slowloris" 를 찾으면 0건이다.
- 포크의 `d7601f2` 는 upstream 의 동시 스트림 카운터 어긋남을 고친다. upstream 은 거절한 스트림도 카운터를 줄인다(추정). 닫힌 스트림 정리를 만료 큐로 바꾼 h2#265(`d93edba`)는 master 에만 있다.
- timer 는 h2 에도 gluten-eio 에도 없다. gluten#17(timeout PR)은 2020-12-10 부터 열려 있다.

### 2.2 서버별 비교

| 서버(커밋) | 기반 | 응답 backpressure | 멈춘 응답의 시간 상한 | 끊긴 상대 알림 | SSE | 연결 준비·수 상한 |
|---|---|---|---|---|---|---|
| piaf `c7428ec` | Eio, h2 0.13, httpun 0.2 | 스트림당 조각 하나, flush 를 기다림 | 없음 | writer 만 `` `Closed `` 에 멈춤. 생산자는 닫지 않음 | 도움 함수 없음 | TLS accept 30 s. 연결 수 상한 없음 |
| Dream `fc3d7d5` | Lwt, h2, httpun | 4096 B 나 명시 flush 마다 기다림. 결과는 버림 | 없음 | 없음. 루프가 끝나지 않음(추정) | 예제뿐. keepalive 없음 | 없음 |
| cohttp-eio `1193aae` | Eio, HTTP/1.1 | 없음. `Buf_write` 가 버퍼를 늘림 | 없음 | 소켓 쓰기 실패가 switch 를 실패시킴 | 없음 | `max_connections`(semaphore) |
| httpcats `83f71c1` | Miou, h2 0.13, h1 | 없음. 핸들러가 기다리지 않으면 Faraday 에 쌓임 | 없음 | ECONNRESET 은 EOF, EPIPE 는 `Closed_by_peer`. 핸들러 취소 없음 | 없음 | 없음 |
| vif `cbe2e06` | httpcats, flux | h2 sink 는 flush 없이 쓰기만 함 | 없음 | 없음 | 없음(WebSocket) | backlog 64 |
| paf `146470b` | Lwt, mimic, h2 ≥ 0.10 | 없음. `writev` 순서만 지킴 | 없음 | 쓰기 에러를 `report_exn` 으로 넘김 | 없음 | 없음. 들어온 연결은 크기 없는 큐 |
| ocaml-grpc main `b629b55` | Eio, h2 0.13 | 없음. flush 콜백을 버림 | 없음 | RST_STREAM 이 handler 에 안 닿음 | 해당 없음 | 없음 |
| ocaml-grpc `dialo` `3523809` + haha `a74876a` | Eio, 자체 HTTP/2 | pull 모델. 송신 흐름 제어 검사는 없음(추정) | 없음 | reset 을 `error_handler`·`on_close` 로 알림 | 해당 없음 | 없음 |
| tiny_httpd `7fc1f96` | 스레드·Eio, HTTP/1.1 | 이벤트마다 flush | Unix 판만 `SO_SNDTIMEO`(기본 0). Eio 판은 없음 | 다음 쓰기 예외 | `event:`·`id:`·`retry:`. keepalive 없음 | `max_connections` 64. Eio 판은 fork 전 semaphore |

그 밖에 nomad 는 2024-05-06 에 archived 됐다. `request_receive_timeout` 은 정의만 있고 쓰는 곳이 없다(nomad `4d9289e` config.ml 5·9줄). ocsigenserver(`534ca38`)는 cohttp-lwt-unix 만 쓰고 HTTP/2 가 없다.

### 2.3 서버별 메모

**piaf**(masc 와 같은 층)

- writer 는 조각마다 `schedule_bigstring` 뒤 flush 약속을 기다린다. `` `Closed `` 면 멈춘다(lib/body.ml 454~478줄). 스트림당 보내는 조각은 하나다.
- handler 가 `Stream.create capacity` 를 쓰면 `Eio.Stream` 이 찼을 때 `push` 가 막힌다(stream/piaf_stream.ml 59~71줄).
- writer 만 멈추고 생산자 stream 은 닫지 않는다(lib/body.ml 472~478줄). handler fiber 는 연결 switch 에서 돈다(lib/http_server_impl.ml 102줄). 막힌 생산자가 그 switch 를 붙잡는다(추정).
- TLS handshake 는 `accept_timeout` 30 s 다(lib/server_config.ml 86줄, lib/openssl.ml 425~450줄). read·idle·send timeout 은 없다.
- `max_concurrent_streams` 설정은 주석 처리돼 h2 기본값을 쓴다(server_config.ml 66줄). 그래서 동시 스트림 수가 무제한이다.
- ALPN 이 협상되지 않으면 `assert false` 다(openssl.ml 412~416줄).
- 종료는 listener 를 닫고 100 ms 마다 연결 수를 본 뒤 기한이 지나면 shutdown 한다(lib/server.ml 198~234줄). GOAWAY 는 없다.

**Dream**

- flush 결과를 버린다: `fun f -> H2.Body.Writer.flush body (fun _ -> f ())`(src/http/adapt.ml 77·88줄). 연결이 닫혀도 `Dream.write` 가 성공한다. 그래서 SSE 루프가 끝나지 않는다(추정).
- 저자 TODO 가 남아 있다. SSE 중 클라이언트가 떠나는 경우가 한때 서버를 죽였다는 내용이다(adapt.ml 20~21줄). 같은 종류의 WebSocket 문제가 #230(open)이다.
- SSE 예제는 `text/event-stream`, `data:`, 묶음마다 write+flush 뿐이다(example/w-server-sent-events). keepalive·`id:`·`retry:`·`Last-Event-ID` 가 없다. 도움 함수 요청 #455 가 열려 있다.
- 요청 본문 상한은 세 단계다. 기본 10 MiB, `Content-Length` 가 크면 바로 413, 아니면 읽은 바이트를 센다(src/server/body_size_limit.ml 21·39~54·81~83줄). 2026-11-02 에 병합됐다(`c558841`).

**cohttp-eio**

- 응답 본문을 `Eio.Buf_write` 에 넣고 끝에서 한 번 flush 한다(cohttp-eio/src/utils.ml 47~63줄). network 에서 생산자로 가는 backpressure 가 없다(추정).
- 소켓 쓰기 실패는 `with_flow` switch 를 실패시켜 handler 를 취소한다(eio lib_eio/buf_write.ml 518~532줄).

**httpcats**

- 핸들러는 h2 가 HEADERS 를 읽는 도중 reader 태스크 안에서 동기로 불린다(http_miou_server.ml 248~250줄). 핸들러가 막히면 그 연결은 WINDOW_UPDATE 와 RST_STREAM 도 못 읽는다(추정).
- TLS handshake 는 기한 없이 돈다(http_miou_server.ml 422~447줄). accept 는 상한 없이 태스크를 만든다. EMFILE·ENFILE 이면 `Miou.yield` 뒤 다시 시도한다(363~382줄).
- stop 은 accept 만 멈추고 남은 연결을 기다린다(runtime.ml 84~95줄). 오래 사는 스트림이 있으면 종료가 끝나지 않는다(추정).
- HTTP/1.1 에서 `SHUT_RD` 를 막아 파이프라이닝 중 RST 를 피한다(http_miou_server.ml 5~37줄).

**vif**

- GET·HEAD·OPTIONS·DELETE 는 httpcats 콜백 안에서 바로 돈다. 본문 있는 메서드만 큐로 넘긴다(vif.ml 276~305줄). 긴 GET 스트림은 그 h2 연결의 reader 를 붙잡는다(추정).
- h2 응답에도 `transfer-encoding: chunked` 를 붙인다(vif_response.ml 98~104줄). RFC 9113 §8.2.2 는 이런 메시지를 malformed 로 다룬다.
- 시작할 때 ALPN 목록을 검사하고 빠지면 실패한다(vif_config_unix.ml 32~45줄).
- chatroom 예제는 mutex 를 잡은 채 막히는 `put` 으로 broadcast 한다. 느린 구독자 하나가 broadcast 전체를 멈춘다(추정).

**paf**

- `alpn_service` 가 `?config` 를 버린다. H2 설정을 바꿀 수 없다(paf_mirage.ml 316줄).
- 쓸 때마다 iovec 을 복사한다(paf.ml 132~158줄). 바이트 상한과 timeout 이 없다. `mirage-time` 의존도 지웠다(`df07db6`).

**ocaml-grpc main 과 dialo·haha**

- main 은 메시지마다 `write_string` 뒤 `flush` 를 부르지만 콜백을 버린다(lib/grpc-eio/connection.ml 28~33줄). 송신 예외는 `traceln` 으로 찍고 끝낸다(server.ml 74~77줄). 그 줄이 가리키는 h2#175 는 2022-05-24 부터 열려 있다.
- haha 는 스트림마다 `body_writer` 를 불러 다음 조각을 받는다(lib/streams.ml 441~451줄).
- haha 는 모든 스트림 writer 와 소켓 읽기를 `Fiber.any` 로 겨룬다. 이긴 결과는 `Cancel.protect` 안에서 끝까지 쓴다(runtime.ml 435~452줄, writer.ml 36줄). 상대가 읽지 않으면 연결 루프 전체가 쓰기에서 멈춘다. 그동안 WINDOW_UPDATE 도 못 읽고 종료 취소로도 못 끊는다(추정). RFC 9113 §5.2.2 가 경고하는 교착 모양이다.
- haha 의 `incr_sent`·`is_overflow` 는 부르는 곳이 없다(flow_control.ml 24~32줄). 상대 창을 넘겨 DATA 를 보낼 수 있다(추정).
- haha 는 상대 RST_STREAM 이 오면 그 스트림의 `error_handler` 와 `on_close` 를 차례로 부른다. 그 뒤로는 writer 를 부르지 않는다(streams.ml 98~112·186~191줄). 취소를 예외가 아니라 콜백으로 알린다.

**tiny_httpd**

- SSE 는 첫 이벤트나 `set_headers` 때 200 을 보낸다(src/core/server.ml 206~228줄). data 를 줄마다 `data:` 로 나누고 빈 줄 뒤 flush 한다(234~243줄).
- `timeout` 은 Unix 판에만 있다. 걸면 `SO_RCVTIMEO`·`SO_SNDTIMEO` 가 된다(src/unix/tiny_httpd_unix.ml 90~91줄). 문서는 프록시 뒤에서는 권하지 않는다고 적는다(src/Tiny_httpd.mli 162~165줄).
- Eio 판(2026-02-15)은 fiber 를 만들기 전에 `Semaphore.acquire` 한다(src/eio/tiny_httpd_eio.ml 201~203줄).

### 2.4 가져올 것과 피할 것

| 가져올 것 | 근거 |
|---|---|
| 스트림당 조각 하나. flush 를 기다리고 `` `Closed `` 면 멈춘다 | piaf lib/body.ml 454~478줄 |
| TLS handshake 기한 30 s | piaf lib/server_config.ml 86줄 |
| 상대 reset 을 콜백으로 알린다 | haha streams.ml 98~112줄 |
| fork 전에 semaphore 로 연결 수를 묶는다 | tiny_httpd src/eio/tiny_httpd_eio.ml 201~203줄 |
| 요청 본문 상한을 세 단계로 건다 | Dream src/server/body_size_limit.ml |
| ALPN 목록을 시작할 때 검사한다 | vif vif_config_unix.ml 32~45줄 |

| 피할 것 | 근거 |
|---|---|
| flush 결과를 버린다 | Dream adapt.ml 77·88줄, grpc main connection.ml 28~33줄 |
| h2 응답에 `transfer-encoding: chunked` 를 붙인다 | vif vif_response.ml 98~104줄 |
| 취소할 수 없는 구간에서 소켓 쓰기를 기다린다 | haha runtime.ml 435~452줄 |
| 핸들러를 reader 태스크 안에서 동기로 돌린다 | httpcats http_miou_server.ml 248~250줄, vif vif.ml 276~293줄 |
| ALPN 이 없으면 `assert false` 로 끝낸다 | piaf openssl.ml 412~416줄 |

masc 는 피할 것 중 셋을 이미 피한다.

- h2 응답에서 connection-specific 필드를 지운다(`http_reqd.ml` 175~188줄).
- 핸들러는 h2 parser 밖의 fiber 에서 돈다(`server_h2_stream_registry.ml` 39~58줄, fork 뒤 `yield`).
- SSE pump 는 flush 결과로 `Written`·`Closed`·`Stalled` 를 가른다(`server_sse_response.ml` 58~97줄).

masc 는 동시 스트림 100 과 수신 창 2^27 을 명시한다(`lib/config/h2_response_limits.ml` 6·16줄). 그래서 h2 기본값의 무제한 스트림 문제는 없다.

## 3. 성숙한 서버, 공격, SSE 스펙

### 3.1 멈춘 상대를 다루는 기본값

| 서버 | 설정 | 기본값 | 동작 | 출처 |
|---|---|---|---|---|
| Go | `WriteTimeout`(HTTP/2) | 0, 없음 | 스트림을 만들 때 시작한다. 만료되면 그 스트림만 RST_STREAM. `ResponseController.SetWriteDeadline` 으로 스트림마다 늘린다 | internal/http2/server.go 2134~2140·2375~2376·3023~3046줄 |
| Go | `WriteByteTimeout` | 0, 없음 | 쓸 것이 있는데 그동안 한 바이트도 못 쓰면 연결을 닫는다 | http.go 287~290줄, internal/http2/http2.go 325~343줄 |
| Go | TLS handshake | `Read`·`ReadHeader`·`Write` 중 양수 최솟값 | 모두 0 이면 없음 | server.go 1055~1069줄 |
| Go | preface / 동시 스트림 | 10 s / 250 | | internal/http2/server.go 50·53줄 |
| Go | 수신 창(스트림 / 연결) | 1 MiB / 1 MiB | | internal/http2/config.go 52~60줄 |
| Go | 쌓인 control frame | 10000 | 넘으면 연결을 닫는다 | internal/http2/server.go 58·1034~1037줄 |
| nginx | `send_timeout` | 60 s | 연속한 두 쓰기 사이만 잰다 | ngx_http_core_module 문서 |
| nginx | TLS handshake | `client_header_timeout` 60 s | HTTP 모듈에는 `ssl_handshake_timeout` 이 없다 | ngx_http_request.c 675·720줄 |
| nginx | `http2_max_concurrent_streams` | 128 | | v2/ngx_http_v2_module.c 347줄 |
| nginx | `max_headers` | 1000 | 1.29.8(2026-04-07)부터, HTTP/2 포함 | ngx_http_core_module.c 3641줄 |
| Envoy | `stream_idle_timeout` | 5 min | 헤더·데이터 이벤트마다 다시 잰다 | http_connection_manager.proto 590~603줄 |
| Envoy | `stream_flush_timeout` | `stream_idle_timeout` 값 | end_stream 뒤 상대가 창을 안 열면 끊는다 | 같은 파일 627~641줄 |
| Envoy | `per_connection_buffer_limit_bytes` | 1 MiB, edge 권장 32 KiB | | listener.proto 249~251줄, edge.yaml 41줄 |
| Envoy | 스트림 수 / 스트림 창 / 연결 창 | 1024 / 16 MiB / 24 MiB. edge 권장 100 / 64 KiB / 1 MiB | 스트림 창이 스트림당 버퍼 상한을 겸한다 | protocol.proto 597~629줄, edge.yaml 67~69줄 |
| Envoy | `max_outbound_frames` / control | 10000 / 1000 | 넘으면 연결을 닫는다 | protocol.proto 643~654줄 |
| h2o | idle / 입력 창 | 10 s / 16 MiB | | http2_directives 문서 |

읽은 커밋은 Go `be57ebb`(x/net `3de643d` 도 같은 상수), nginx `d17f1d2`, Envoy `70a6007` 이다.

정리하면 두 갈래다.

- 시간으로 묶는다. Go `WriteTimeout` 은 스트림 하나를 묶는다. `WriteByteTimeout` 과 nginx `send_timeout` 은 연결을 묶는다. Envoy `stream_flush_timeout` 은 응답을 다 쓴 뒤 창을 안 여는 상대를 끊는다. masc §1.4 의 장면이 이것이다.
- 바이트로 묶는다. Envoy 는 연결 버퍼와 스트림 창으로 대기 바이트를 묶는다.

Envoy edge 예시는 `stream_idle_timeout` 과 `request_timeout` 을 300 s 로 둔다. 그러면서 오래 사는 스트리밍 요청에는 `request_timeout` 을 꺼야 한다고 적는다(edge.yaml 1~19줄). SSE 처럼 오래 사는 응답에는 스트림 전체 시간 상한이 맞지 않는다는 뜻이다.

### 3.2 공격

| 공격 | 공개 | 모양 | 대응 |
|---|---|---|---|
| Rapid Reset, CVE-2023-44487 | 2023-10 | 스트림을 열자마자 RST_STREAM 으로 닫기를 되풀이한다 | Go: 대기 handler 가 광고한 스트림 수의 4배를 넘으면 GOAWAY(internal/http2/server.go 2537~2546줄, CVE-2023-39325). nginx: 한 번 읽을 때 새 스트림이 2×max 를 넘으면 REFUSED_STREAM(v2/ngx_http_v2.c 1275~1281줄). Envoy 1.27.1: 요청 500개 뒤 1 s 안의 reset 이 50% 를 넘으면 연결을 닫는다 |
| CONTINUATION flood, CERT VU#421644 | 2024-04-03 | 끝나지 않는 CONTINUATION 으로 헤더 상태를 불린다 | Go: 남은 헤더 예산의 2배를 넘는 조각이 오면 연결을 닫는다(internal/http2/frame.go 1921~1935줄). Envoy 1.29.3: nghttp2 갱신(CVE-2024-30255) |
| MadeYouReset, CVE-2025-8671, CERT VU#767506 | 2025-08-13 | 잘못된 프레임으로 서버가 reset 을 보내게 만든다. 클라이언트 reset 만 세는 방어를 비켜 간다 | 영향 목록에 gRPC·Netty·Tomcat·Varnish |
| HTTP/2 bomb | 2026-06-02 | 1바이트 HPACK 참조로 헤더 상태를 불리고, 창 0 과 1바이트 WINDOW_UPDATE 로 send timeout 을 피한다 | 권고: cookie 조각까지 센 헤더 개수 상한, WINDOW_UPDATE 와 상관없는 멈춘 스트림 수명 상한. nginx `max_headers`, Envoy CVE-2026-47774, h2o CVE-2026-54340(필드 1000개를 넘으면 연결을 닫고 100개를 넘으면 400) |

masc 와 닿는 점은 둘이다.

- HTTP/2 bomb 는 진척이 있으면 늘어나는 타이머를 피한다. nginx `send_timeout` 과 Go `WriteByteTimeout` 이 그 모양이다. masc 의 정체 판정은 프레임 하나가 다 나가는 시간을 잰다. 그래서 1바이트 WINDOW_UPDATE 로는 늘어나지 않는다. 다만 이 판정은 SSE 에만 있고 통째 본문에는 없다(§1.4).
- 조각 하나에 상한을 두면 그것이 최소 배출 속도가 된다. 16 KiB 조각에 90초면 182 B/s 다. 그보다 빨리 읽는 상대는 조각 상한에 걸리지 않는다.
- MadeYouReset 은 서버가 보낸 reset 도 세야 한다는 뜻이다. h2 0.13 은 어느 쪽도 세지 않는다(§2.1).

### 3.3 SSE 스펙, 브라우저, Cloudflare

WHATWG HTML §9.2(server-sent events)의 규칙은 이렇다.

- 재연결 기본 간격은 구현이 정한다. 스펙은 몇 초 정도로 본다.
- `retry:` 는 ASCII 숫자만 받는다.
- 200 이 아니거나 Content-Type 이 `text/event-stream` 이 아니면 연결을 실패로 끝내고 다시 붙지 않는다. 204 는 재연결을 멈추는 신호다.
- 네트워크 오류면 다시 붙는다. 지수 backoff 를 둘 수 있다.
- 프록시가 연결을 끊지 않게 약 15초마다 `:` 주석 줄을 보내라고 권한다.

masc 의 SSE 핑은 30초다(`server_mcp_transport_http_headers.ml` 289줄). WHATWG 권고보다 길고, Cloudflare 의 origin 읽기 상한(아래)보다 짧다.

MDN 의 EventSource 문서는 HTTP/1.x 에서 브라우저·도메인당 6개라고 적는다(crbug 275955, bugzil.la 906896, 둘 다 Won't fix). HTTP/2 에서는 협상한 동시 스트림 수가 한도다. MDN 은 기본 100 이라고 쓰지만 RFC 9113 §6.5.2 는 처음에는 한도가 없고 100 이상을 권한다고만 적는다.

Cloudflare 연결 한도 문서(2026-11-09 확인)는 origin 쪽 Proxy Read Timeout 125 s, Proxy Write Timeout 30 s, 클라이언트 쪽 HTTP/2 idle 400 s 를 적는다. Tunnel 은 별도 origin 설정을 따른다고 적는다. cloudflared 가 masc 에 붙는 연결의 상한은 이 문서로 확정되지 않는다(확인 필요).

## 4. 측정

### 4.0 환경

- masc 측정은 모두 격리 서버에서 했다. `scripts/harness/perf/http_multiplex_probe.py` 의 `OwnedServer` 가 설치된 바이너리를 띄운다. 새 base path, loopback 포트, Keeper 끔, gRPC·WS 끔, 빈 포트의 TLS 리스너다.
- 바이너리 build 는 각 실행이 `/health` 에서 읽어 기록했다. run1 은 `0a7164246935`, run3~run6 은 `57b928783c0b` 다. run2 는 build 를 기록하지 않았다. 두 build 의 전송 코드는 같다.
- 장비는 M3 Max 한 대다. 호스트에 다른 부하가 있었다. 처리량은 표본마다 2배까지 흔들렸고 서버 CPU 는 안정적이었다.
- 탐침과 결과 원본은 evidence 묶음에 있다. 실행 명령은 묶음의 README 에 있다.

### 4.1 누수(run1, run2)

run1 은 TLS h2 연결 하나를 cloudflared 처럼 오래 열어 둔다. 그 위에서 SSE 스트림을 열고 응답 헤더를 받은 뒤 RST_STREAM(CANCEL)으로 끊는다.

| 시나리오 | 양 | 상태 |
|---|---|---|
| 데우기(fleet·로그) | 스트림 360개 | 200 ×360 |
| fleet, TLS | 스트림 4,500개, 4.4 s | 200 ×4,500 |
| 로그, TLS | 스트림 4,500개, 6.0 s | 200 ×4,500 |
| MCP GET, TLS | 세션 30개 × 10회 | 200 ×300 |
| fleet, h2c | 스트림 2,250개, 2.1 s | 200 ×2,250 |
| TLS 연결 절단 | 연결 200개 × 스트림 5개 | 200 ×1,000 |
| TLS handshake 실패 | TLS 포트에 평문 요청 200번 | 해당 없음 |
| 끝에 같은 TLS 연결로 GET | `/api/v1/openapi.json` 300번 | 200 ×300, 서버 reset 0 |

RST_STREAM 으로 끊은 스트림은 모두 11,910개다. 연결째 끊은 스트림이 1,000개 더 있다.

| 표본 | t s | descriptor | TCP descriptor | HTTPS 활성 연결 | HTTPS 누적 accept | handshake 실패 | `sse_clients` | live MB | RSS MB |
|---|---|---|---|---|---|---|---|---|---|
| cold | 2.1 | 54 | 3 | 0 | 0 | 0 | 0 | 20.9 | 279.4 |
| warm | 38.5 | 55 | 4 | 1 | 1 | 0 | 0 | 99.2 | 409.9 |
| fleet TLS 뒤 | 46.8 | 55 | 4 | 1 | 1 | 0 | 0 | 132.1 | 506.7 |
| 로그 TLS 바로 뒤 | 53.0 | 55 | 4 | 1 | 1 | 0 | 0 | 292.2 | 808.6 |
| 로그 TLS 35 s 뒤 | 88.3 | 55 | 4 | 1 | 1 | 0 | 0 | 329.9 | 836.0 |
| MCP GET 뒤 | 90.6 | 55 | 4 | 1 | 1 | 0 | 0 | 352.7 | 871.9 |
| fleet h2c 뒤 | 96.3 | 55 | 4 | 1 | 1 | 0 | 0 | 290.1 | 881.0 |
| TLS 연결 절단 뒤 | 166.1 | 55 | 4 | 1 | 201 | 0 | 0 | 170.6 | 908.6 |
| handshake 실패 뒤 | 1170.0 | 55 | 4 | 1 | 401 | 200 | 0 | 306.2 | 362.1 |
| 끝(오래 연 연결을 닫은 뒤) | 1212.0 | 54 | 3 | 0 | 401 | 200 | 0 | 355.0 | 563.8 |

- descriptor, TCP descriptor, 리스너 활성 연결은 모든 표본에서 warm 값이었다. 오래 연 연결을 닫은 뒤에는 cold 값이 됐다.
- MCP GET 은 회마다 `sse_clients` 가 30 까지 올랐다. RST_STREAM 뒤 0.01 s 안에 0 으로 돌아왔다.
- 끝에 보낸 GET 300개는 모두 200 이었다. 원장이 바닥나지 않았다.
- handshake 실패 200번은 1,004 s 가 걸렸다(166.1 → 1170.0 s). 연결마다 탐침의 `recv` 가 5 s 기한을 다 썼다. 서버는 그동안 답하지도 닫지도 않았다(§1.7).

run2 는 HTTP/1.1 대조다. 연결 2,000개로 fleet 를, 다시 2,000개로 로그 스트림을 열고 클라이언트가 닫았다. 모두 200 이었다. descriptor 는 54 그대로였다. run1 의 HTTP/1.1 대조(연결 200개)는 탐침의 요청 모양 탓에 200 을 하나도 받지 못해서 판정에 쓰지 않는다.

직접 생산자는 스트림보다 오래 산다.

| 실행 | 앞 표본 live MB | 로그 스트림 바로 뒤 | 35 s 뒤 |
|---|---|---|---|
| run1, TLS h2, 4,500개 reset | 132.1 | 292.2(+160.1) | 329.9(+197.8) |
| run2, HTTP/1.1, 2,000개 close | 38.7 | 195.4(+156.7) | 227.4(+188.7) |

fleet 스트림은 pump 가 바로 끝내서 이렇게 늘지 않았다. 로그 생산자가 다음 로그 줄이나 핑까지 남는 것은 코드로 확인했다(§1.5). 그 뒤의 해제는 이 값으로 보이지 않는다. `/health` 의 live 는 도달 가능한 메모리가 아니다. 부하 없이 잇달아 읽어도 65 MB 흔들리고, 쉬는 동안 줄지 않는다. RSS 도 279~909 MB 를 오갔다. 그래서 메모리 값은 이 묶음에서 누수 판정에 쓰지 않는다. 판정은 descriptor, 연결 수, `sse_clients`, 원장으로 한다.

### 4.2 원장 고갈(run5)

느린 클라이언트 하나가 TLS h2 연결 하나에서 대시보드 번들(861,256 B) 스트림 90개를 연다. 데이터를 확인하지 않는다(기본 창 65,535 B). 다른 연결의 정상 클라이언트가 같은 번들과 `/health` 를 3번씩 요청한다(#50294).

| 때 | 느린 클라이언트 | 정상 클라이언트 번들 | 정상 클라이언트 `/health` |
|---|---|---|---|
| 느린 클라이언트 전 | - | 200 ×3 | 200 ×3 |
| 느린 클라이언트가 쥐는 동안 | 200 ×77, 503 ×13, 서버 reset 0 | 503 ×3 | 200 ×3 |
| 5초 뒤 | 그대로 | 503 ×3 | 200 ×3 |
| 느린 클라이언트가 떠난 뒤 | - | 200 ×3 | 200 ×3 |

77개 × 861,256 B = 66,316,712 B 로 원장 64 MiB(67,108,864 B)가 찼다. 남은 자리보다 큰 응답은 느린 클라이언트가 떠날 때까지 모두 503 이다. 그 스트림들에는 시간 상한이 없다. 번들은 인증 없이 받는 정적 파일이다. 같은 응답을 77번 읽고 압축해서 77벌의 사본을 원장에 넣었다(§1.1).

### 4.3 정체한 SSE 스트림(run6)

TLS h2 연결 하나가 `SETTINGS_INITIAL_WINDOW_SIZE = 0` 을 알리고 로그 스트림 3개를 연다. 서버는 HEADERS(200)를 보내지만 DATA 는 보낼 수 없다.

| 관찰 | 값 |
|---|---|
| 서버 정체 로그("accepted no frame for 90 seconds") | 3줄, 90초 시점 |
| 105초 동안 서버가 보낸 RST_STREAM | 0개 |
| 105초 동안 받은 DATA | 스트림마다 0 B |
| 105초에 창을 연 뒤 스트림마다 받은 바이트 | 36,839 B |
| 그 뒤 END_STREAM | 3개 모두, reset 없음 |

서버는 90초에 스트림을 정체로 판정하고 생산자를 끝냈다. 그런데 스트림은 닫지 못했다. 보류한 프레임과 그 원장 예약을 상대가 창을 열 때까지 쥐었다. 창을 끝내 열지 않으면 연결이 끝날 때까지 쥔다(§1.4 의 고리). cloudflared 처럼 연결을 오래 쓰는 클라이언트에서는 이것이 연결 수명만큼 쌓인다.

### 4.4 TLS 쓰기 경로(run3, run4, 벤치)

run4 는 masc TLS 리스너의 처리량과 서버 CPU 를 잰다. 클라이언트는 같은 호스트의 Python 3.14.4·OpenSSL 3.6.4 다. 대시보드 번들 861,256 B 를 연결마다 60번 받는다. 값은 3회 중앙값이다.

| 연결 | 암호 | MB/s | 서버 ms/MB |
|---|---|---|---|
| 1 | 평문 | 292.0 | 2.50 |
| 1 | AES-128-GCM | 42.3 | 11.49 |
| 1 | AES-256-GCM | 23.6 | 11.79 |
| 1 | ChaCha20-Poly1305 | 29.1 | 9.66 |
| 4 | 평문 | 434.5 | 1.54 |
| 4 | AES-128-GCM | 48.0 | 8.65 |
| 4 | AES-256-GCM | 57.3 | 10.04 |
| 4 | ChaCha20-Poly1305 | 63.3 | 7.52 |

- 한 연결 TLS 처리량은 평문의 1/7(AES-128)~1/12(AES-256)이다.
- AES-128 한 연결은 42.3 MB/s × 11.49 ms/MB 로 한 코어의 약 49% 를 쓴다. 서버가 CPU 를 다 쓰지 않는데도 느리다.

run3 은 같은 번들을 HTTP/1.1 파이프라인으로 받았다. 클라이언트는 suite 하나로 묶은 `openssl s_client` 다. 중앙값은 평문 325.8 MB/s, AES-128-GCM 27.8 MB/s, AES-256-GCM 42.8 MB/s, ChaCha20-Poly1305 42.5 MB/s 다. TLS handshake 30번의 중앙값은 5.77 ms 다. 클라이언트가 suite 셋을 다 내면 서버는 AES-128-GCM 을 골랐다.

이 차이를 masc 밖에서 분리했다. 벤치 서버는 opam 라이브러리(tls-eio 2.1.2, eio_main, mirage-crypto 1.2.0)만 쓰는 OCaml 실행 파일 하나다. 연결마다 861,256 B 를 60번 쓰고 close_notify 를 보낸다. 암호는 서버 설정으로 하나만 연다. 바꾸는 것은 tls-eio 에 넘기는 소켓 하나다.

- `stock` 은 accept 한 소켓 그대로다. §1.8 의 4096 바이트 조각이다.
- `copy:N` 은 tls-eio 의 `copy` 를 N 바이트 버퍼로 읽어 소켓에 쓰는 감싸개다.

값은 run2(5회 중앙값)이다. run1(3회)도 방향이 같다. 서버 쓰기 크기는 861,256 B 다.

| suite | 소켓 | 한 연결 MB/s | 서버 ms/MB | 클라이언트 ms/MB | 서버+클라이언트 | 4연결 합계 MB/s | 4연결 서버 ms/MB |
|---|---|---|---|---|---|---|---|
| AES-128-GCM | stock | 31.2 | 9.69 | 4.19 | 13.88 | 97.8 | 7.01 |
| AES-128-GCM | copy:16384 | 142.5 | 5.58 | 1.19 | 6.77 | 103.4 | 5.53 |
| AES-128-GCM | copy:65536 | 83.2 | 5.70 | 0.81 | 6.51 | 116.7 | 4.91 |
| AES-128-GCM | copy:262144 | 115.6 | 5.44 | 0.60 | 6.04 | 113.4 | 4.93 |
| AES-128-GCM | copy:1048576 | 134.4 | 5.36 | 0.58 | 5.94 | 182.9 | 4.70 |
| ChaCha20-Poly1305 | stock | 42.7 | 8.64 | 4.76 | 13.40 | 135.5 | 5.45 |
| ChaCha20-Poly1305 | copy:16384 | 60.4 | 5.53 | 1.98 | 7.51 | 104.0 | 4.34 |
| ChaCha20-Poly1305 | copy:65536 | 109.4 | 4.38 | 1.37 | 5.75 | 210.5 | 3.55 |
| ChaCha20-Poly1305 | copy:262144 | 238.5 | 3.69 | 1.02 | 4.71 | 253.0 | 3.46 |
| ChaCha20-Poly1305 | copy:1048576 | 221.2 | 3.81 | 1.13 | 4.94 | 171.5 | 3.48 |

- stock AES-128 은 masc 리스너와 같은 크기다(벤치 9.69 ms/MB, masc 11.49 ms/MB). 원인은 masc 코드가 아니라 tls-eio 의 쓰기 경로다.
- 암호문을 16 KiB 이상으로 쓰면 AES-128 서버 CPU 가 MB 당 41~45% 준다. 클라이언트 CPU 도 MB 당 4.19 ms 에서 0.58~1.19 ms 로 준다. 4 KiB 세그먼트마다 양쪽이 깨어나는 비용이 사라진다.
- ChaCha20 이 AES-128 보다 싼 정도는 조각 크기에 따라 다르다. 서버 CPU 는 stock 에서 10.8%, 16 KiB 에서 0.9%, 64 KiB 에서 23.2%, 256 KiB 에서 32.2%, 1 MiB 에서 28.9% 적다.
- 이 클라이언트(OpenSSL)는 ChaCha20 에 CPU 를 더 쓴다. 서버와 클라이언트를 합치면 16 KiB 에서는 ChaCha20 이 10.9% 더 비싸다. 64 KiB~1 MiB 에서는 11.7~22.0% 싸다.
- 가장 좋은 조합(ChaCha20, 256 KiB)은 stock AES-128 보다 서버 CPU 가 MB 당 61.9% 적다.

서버가 64 KiB 씩 쓸 때(h2 DATA 묶음에 가까운 크기)는 효과가 작다.

| suite | stock 서버 ms/MB | copy:16384 | copy:65536 | copy:262144 | copy:1048576 |
|---|---|---|---|---|---|
| AES-128-GCM | 11.60 | 8.55(-26.3%) | 7.40(-36.2%) | 6.97(-39.9%) | 6.52(-43.8%) |
| ChaCha20-Poly1305 | 10.98 | 7.31(-33.4%) | 6.14(-44.1%) | 5.90(-46.3%) | 6.05(-44.9%) |

64 KiB 쓰기에서 서버와 클라이언트를 합친 값은 ChaCha20 과 AES-128 이 -7.9%~+3.7% 안에서 갈린다. 암호 순서의 이득은 조각 크기와 클라이언트에 달렸다. cloudflared 는 Go `crypto/tls` 로 복호화한다. Go 클라이언트로는 재지 않았다.

## 5. 판단

결정은 RFC-0518 이 한다. 여기서는 원인과 방향별 장단점만 적는다.

### 5.1 원인

| 문제 | 원인 | 근거 |
|---|---|---|
| 정체한 HTTP/2 스트림이 끝나지 않는다 | masc 가 스트림을 끝내는 방법이 "다 보낸 뒤 닫기" 하나다. 창이 0 이면 그 조건이 오지 않는다 | §1.4, §4.3 |
| 끊은 뒤에도 fiber 와 예약이 남을 수 있다 | masc 가 보낸 RST_STREAM 은 스트림 switch 를 실패시키지 않는다. flush 를 기다리는 fiber 가 switch 를 붙잡는다 | §1.3 |
| 원장이 바닥난다 | 통째 본문에는 시간 상한이 없다. 바뀌지 않는 정적 파일도 요청마다 사본을 원장에 넣는다 | §1.1, §4.2 |
| 생산자가 스트림보다 오래 산다 | 로그·초안·실행 출력 생산자가 응답과 다른 switch 에서 돈다 | §1.5, §4.1 |
| 연결 준비가 끝나지 않을 수 있다 | handshake 와 프로토콜 판별에 기한이 없다 | §1.7, §4.1 |
| TLS 가 느리다 | tls-eio 가 암호문을 4 KiB 씩 쓴다 | §1.8, §4.4 |

### 5.2 스트림을 끝내는 주체

**h2 포크를 고친다.** `on_close_stream` 에서 응답 본문을 닫고 drain 하면 reset 때 flush 가 `` `Closed `` 로 끝난다(h2-core 보고의 권고, h2#279).

- 장점: 원인이 있는 자리를 고친다. frame tap 없이도 끝을 알 수 있게 된다.
- 단점: 그 스트림의 DATA 가 연결 writer 에 남아 있을 때 drain 하면 faraday 의 `assert (written = 0)`(faraday.ml 378줄)에 걸린다(추정). 포크를 계속 지켜야 한다. 그리고 h2 에는 timer 가 없다. 창을 안 여는 상대를 끊는 판단은 여전히 masc 몫이다.

**masc 가 정체 판정 뒤 RST_STREAM 을 보낸다.** `H2.Reqd.report_exn` 을 쓴다.

- 장점: 지금 API 로 된다. RST_STREAM 은 흐름 제어 밖이라 창 0 에서도 나간다(§1.2).
- 단점: 코드는 INTERNAL_ERROR 하나뿐이다. `report_exn` 은 응답 상태에 따라 갈린다(reqd.ml [f] 343~370줄).
  - 응답 전이면 error handler 를 불러 500 응답을 연다(345줄).
  - 스트리밍 중이면 본문을 닫고 RST_STREAM 을 보낸다(355줄).
  - 이미 에러를 보고한 스트림에 다시 부르면 `failwith "h2.Reqd.report_exn: NYI"` 다(369줄).
  - 그래서 masc 의 일곱 곳(§1.3)을 한 함수로 모으고, 이미 보고한 스트림은 건너뛰어야 한다.
- 이 방법은 masc 가 보낸 RST_STREAM 이 스트림 switch 를 끝내야 완성된다. 그래야 flush 를 기다리는 fiber 와 원장 예약이 같이 풀린다(§1.3).

### 5.3 정체 상한의 모양

| 모양 | 예 | 장점 | 단점 |
|---|---|---|---|
| 스트림 전체 시간 | Go `WriteTimeout` | 단순하다 | SSE 처럼 오래 사는 응답과 맞지 않는다. Envoy edge 예시도 스트리밍에는 끄라고 적는다 |
| 진척이 있으면 연장 | nginx `send_timeout`, Go `WriteByteTimeout` | 느리지만 읽는 상대를 살린다 | HTTP/2 bomb 가 1바이트 WINDOW_UPDATE 로 피한다 |
| 조각 하나가 기한 안에 다 나감 | masc SSE 정체 판정, piaf 의 조각당 flush 에 기한을 더한 모양 | 최소 배출 속도를 정한다. 1바이트 WINDOW_UPDATE 로 늘어나지 않는다 | 그 속도 바로 위로 읽는 상대는 예약을 오래 쥔다 |

조각 상한의 남는 위험은 숫자로 보인다.

- 16 KiB 조각에 90초면 최소 배출 속도는 182 B/s 다.
- 그 속도로 읽는 상대는 대시보드 번들(861,256 B)의 예약을 약 79분 쥔다. 77개면 원장이 그만큼 찬다.
- 스트림 N 개가 느린 링크 하나를 나눠 쓰면 링크는 N × 182 B/s 를 넘어야 한다. 100개면 18 KiB/s 다.

그래서 조각 상한만으로는 #50294 의 장면이 사라지지 않는다. 원장을 쓰는 본문을 줄이는 일이 같이 필요하다(§5.4).

### 5.4 원장

**연결별 몫을 둔다.** h2-core 보고가 권한 방법이다. 한 연결이 원장의 일부만 쓰게 한다.

- 장점: 읽지 않는 연결 하나가 다른 연결을 503 으로 만들지 못한다.
- 단점: cloudflared 는 원격 사용자를 origin 연결 몇 개에 모은다. Go HTTP/2 Transport 는 연결의 동시 스트림 한도를 넘을 때만 연결을 더 연다(x/net `3de643d` http2/transport_common.go 142~153줄, `StrictMaxConcurrentStreams` 기본 false). 그래서 연결 몫으로는 원격 사용자를 가를 수 없다(추정). 몫이 원장의 절반이면 32 MiB artifact(`Tool_blob_store.max_served_bytes`)가 다른 응답과 같이 못 들어간다.

**바뀌지 않는 본문을 공유한다.** 대시보드 번들처럼 판마다 고정된 파일은 bigstring 하나를 모든 스트림이 참조한다.

- 장점: h2 `schedule_bigstring` 은 복사 없이 건다(§1.2). 스트림마다 사본이 없으니 원장에 넣을 바이트도 없다. §4.2 의 장면에서 원장 사용량이 0 이 된다. 압축도 판마다 한 번이면 된다.
- 단점: 소유 본문(artifact, MCP 결과)의 문제는 그대로다. 대시보드 asset 은 읽을 때마다 receipt 와 digest 를 검증하는 계약이 있다(`lib/installed_dashboard.mli` 29줄). 캐시는 검증한 digest 로 찾아야 이 계약을 지킨다.

### 5.5 생산자 수명과 연결 준비

- 생산자를 응답 수명에 묶는다. pump 사용처가 이미 `await_closed` 로 이렇게 돈다(#49862). 로그·초안·실행 출력도 같은 모양으로 바꿀 수 있다. 단점은 생산자마다 정리 순서를 다시 확인해야 한다는 점이다.
- 연결 준비에 기한을 둔다. piaf 는 30 s, nginx 는 60 s 다. 30 s 는 느린 링크의 정상 handshake 에도 넉넉하다(추정). 단점은 기한이 짧으면 정상 클라이언트를 끊는다는 점이다.

### 5.6 TLS

**쓰기 조각.**

- upstream 을 고친다. tls-eio 의 `write_t` 가 암호문을 `single_write` 로 바로 쓰면 된다. 장점은 원인 자리라는 점이다. 단점은 릴리스를 기다려야 한다는 점이다. upstream main 도 같은 경로다(§1.8).
- masc 소켓 감싸개의 `copy` 가 큰 버퍼로 읽어 쓴다. 벤치의 `copy:N` 이 이 모양이다. 장점은 지금 된다는 점이다. 벤치에서 서버 CPU 가 MB 당 41~45% 줄었다(§4.4). 단점은 우회라는 점이다. tls-eio 는 쓰기 잠금이 없고 읽기 경로도 쓸 수 있다. 그래서 버퍼를 연결마다 하나 두고 나눠 쓰면 안 된다(코드 읽기).

**암호 순서.** tls 서버는 자기 목록 순서로 고른다(§1.8). ChaCha20 을 앞에 두면 861 KB 를 한 번에 쓰는 벤치의 64 KiB 이상 조각에서 서버 CPU 가 23~32% 준다. 16 KiB 조각에서는 차이가 1% 안팎이다. 64 KiB 씩 쓰면 7~17% 다. OpenSSL 클라이언트는 ChaCha20 에 CPU 를 더 쓴다. cloudflared(Go) 쪽 비용은 재지 않았다. 순서를 바꾸려면 Go 클라이언트로 서버와 클라이언트의 합을 먼저 재야 한다.

**tls 2.1.5.** 조작한 상대의 메모리 누수, 16 KiB 경계의 빈 레코드, 중복 SupportedVersion 으로 서버가 멈추는 일을 고친다(§1.8). 단점은 x509 1.2 로 올려야 한다는 점이다. `CN` 생성자 쓰임 두 곳(`lib/server/server_tls_material.ml`, `packages/agent_core/test/test_tls_cancellability.ml`)과 lock 파일이 바뀐다.

### 5.7 이번 범위 밖

조사 중에 본 것 중 위 문제와 직접 닿지 않는 것은 따로 남긴다.

- 연결 수, idle, 헤더 시간 상한. TLS 뒤 h2 preface 대기도 여기 든다.
- 들어오는 창 2^27(연결당 128 MiB). Go 는 1 MiB, Envoy edge 권장은 스트림 64 KiB 다.
- rapid reset(양방향 reset 세기), CONTINUATION, 헤더 개수 상한(§3.2).
- HTTP/1.1 스트리밍 중 이탈 감지(§1.6).
- 우아한 종료 GOAWAY. h2 0.13 공개 API 에 없다(§2.1).
- h2 포크 정리: #278 조건 고침, `on_close_stream` 의 본문 drain, `Reqd.stream_id` 공개, upstream h2#265 이식.
- 사전 압축 JSON 스냅샷과 artifact 바이트도 요청마다 사본을 만든다.

## 6. 출처

### 6.1 읽은 저장소와 커밋

| 저장소 | 커밋 | 비고 |
|---|---|---|
| anmonteiro/ocaml-h2 | master `a5449e52ad00`, 태그 0.13.0 `49c0591ce90e` | |
| jeong-sik/ocaml-h2 | `d7601f201da8` | masc 가 쓰는 포크 |
| anmonteiro/httpun | 0.2.0 `80755658e548`, HEAD `37fdcd8fd09d` | 둘의 동작이 같다 |
| anmonteiro/gluten | 0.5.2 `6a438739280b` | |
| inhabitedtype/faraday | 0.8.2 `f5f63b542579` | |
| anmonteiro/piaf | `c7428ec14dc6` | 2025-09-30 |
| aantron/dream | `fc3d7d581fd6` | 2026-11-02, 1.0.0-29 |
| mirage/ocaml-cohttp | `1193aaeef7dc` | v6.3.0 뒤 3커밋 |
| robur-coop/httpcats | `83f71c18a56a` | 2026-10-01 |
| robur-coop/vif | `cbe2e066f518` | 2026-10-30 |
| dinosaure/paf-le-chien | `146470b12d31` | 2026-09-15 |
| robur-coop/flux | `c637c6b46bc0` | vif 의 스트림 |
| robur-coop/mhttp | `f9405ba9cda0` | vifu 가 쓰는 httpcats 파생판 |
| dialohq/ocaml-grpc | main `b629b55`(2025-07-28), `dialo` `3523809`(2026-09-15) | |
| dialohq/haha | `a74876a` | 2025-11-25 |
| c-cube/tiny_httpd | `7fc1f96` | |
| suri-framework/nomad | `4d9289e` | archived |
| ocsigen/ocsigenserver | `534ca38` | |
| ocaml-multicore/eio | v1.6 `1fc0efa41ccf` | 로컬 opam 의 eio_posix 사본도 읽었다 |
| mirleft/ocaml-tls | v2.1.5 `369b8c2714a9` | 설치본 2.1.2 도 읽었다 |
| mirage/mirage-crypto | `ec4206ca9bfc` | |
| golang/go | `be57ebb` | src/net/http |
| golang/net | `3de643d` | http2 |
| nginx/nginx | `d17f1d2` | src/http |
| envoyproxy/envoy | `70a6007` | |

### 6.2 문서

- RFC 9113 HTTP/2: https://www.rfc-editor.org/rfc/rfc9113.txt (§5.2.2, §6.5.2, §6.9, §8.2.2)
- WHATWG HTML, server-sent events: https://html.spec.whatwg.org/multipage/server-sent-events.html
- MDN EventSource: https://developer.mozilla.org/en-US/docs/Web/API/EventSource
- nginx core module: https://nginx.org/en/docs/http/ngx_http_core_module.html
- nginx HTTP/2 module: https://nginx.org/en/docs/http/ngx_http_v2_module.html
- h2o HTTP/2 directives: https://h2o.examp1e.net/configure/http2_directives.html
- Cloudflare connection limits: https://developers.cloudflare.com/fundamentals/reference/connection-limits/
- Go vulnerability GO-2023-2102(CVE-2023-39325): https://pkg.go.dev/vuln/GO-2023-2102
- Go vulnerability GO-2024-2687(CONTINUATION): https://pkg.go.dev/vuln/GO-2024-2687
- CERT VU#421644(CONTINUATION flood): https://kb.cert.org/vuls/id/421644
- CERT VU#767506(MadeYouReset): https://kb.cert.org/vuls/id/767506
- HTTP/2 bomb: https://blog.calif.io/p/codex-discovered-a-hidden-http2-bomb
- 트래커: anmonteiro/ocaml-h2#175, #240, #241, #247, #265, #278, #279; anmonteiro/httpun#138, #155; anmonteiro/gluten#17; aantron/dream#230, #455; mirleft/ocaml-tls#531, #539, #540
