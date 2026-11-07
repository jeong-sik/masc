# HTTP 전송 스택 조사: masc 가 OCaml 생태계에서 HTTP/1.1·HTTP/2·TLS 를 어디까지 쓸 수 있나

- 확인 시각: 2026-11-07 09:00Z ~ 09:45Z. 설치된 opam switch `5.5.1` 의 `.mli` 를 직접 읽었다. 외부 문서는 §6 에 링크했다.
- 판정 대상 head: `origin/main` `f8dbd356759`. 라이브 서버 바이너리는 `~/.local/bin/masc` 0.68.0, build-commit `6afc364dd90`.
- 이 문서는 조사이고 결정이 아니다. 결정은 RFC-0512 에 적는다. 기준선 측정 기록은 `docs/evidence/http2-one-table-2026-11/baseline/` 에 있다.

## 0. 요약

- masc 는 한 포트(8935)에서 HTTP/1.1(httpun-eio)과 HTTP/2 h2c(h2-eio)를 같이 받는다. 경로 표는 둘이다. HTTP/1.1 은 `Http_server_eio.Router` 에 등록하고(36파일 394곳. 세는 명령: `git grep -c -E 'Server_route\.(get|post|put|delete|patch|prefix_[a-z_]+|add|ws_get)' f8dbd356759 -- 'lib/**/*.ml'` 의 합. `.mli` 의 1곳은 뺀다), HTTP/2 는 `Server_h2_gateway` 의 `match (meth, path)` 82갈래와 `_routes_extra` 의 14갈래가 다시 적는다. 격리 서버에 h2c 로 `/api/v1/stream/fleet` 을 열면 404 가 온다. HTTP/1.1 로는 200 이다(§1.3).
- 라이브 서버 로그 687개 파일, 리스너 통계 줄 126개를 합치면 h2 연결 1개, h1 연결 403,566개다(09:43Z 집계). HTTP/2 는 있지만 아무도 안 쓴다. 리스너에 TLS 가 없고, 브라우저는 ALPN 으로만 HTTP/2 를 고르며, Cloudflare 터널은 HTTPS origin 에만 HTTP/2 를 보내기 때문이다(§3).
- 생태계에는 필요한 부품이 다 있다. tls 2.1.2 와 tls-eio 2.1.2 가 TLS 1.3 과 ALPN 협상을 하고, x509 1.0.6 이 자체 서명 인증서를 만들며, h2 0.13.0(사용자 포크)과 httpun 0.2.0 이 같은 Eio 소켓 위에서 돈다. 없는 것은 HTTP/3·QUIC 와 WebSocket over HTTP/2(RFC 8441)다(§2).
- piaf 0.2.0 은 HTTP/1.1·HTTP/2·TLS 를 한 서버 API 로 주지만 핸들러가 응답을 반환하는 모델이라 지금의 콜백·스트리밍(RFC-0493 SSE) 모델과 맞지 않는다. ALPN 분기 코드만 참고한다(§2.4).
- 기준선 벤치 도구 `scripts/harness/perf/http_multiplex_probe.py` 를 만들었다. 설치된 바이너리를 격리 워크스페이스에 띄우고 같은 요청을 HTTP/1.1(6연결·무제한)과 h2c(한 연결)로 보낸다. 수치는 §4 와 evidence 묶음에 있다.

## 1. 지금 masc 의 전송

### 1.1 리스너

`Server_bootstrap_http` 가 세 모드를 가진다(`lib/server/server_bootstrap_http.ml`). `serve` 는 httpun-eio HTTP/1.1, `serve_h2` 는 h2-eio h2c(prior knowledge), `serve_auto` 는 첫 바이트를 읽어 `PRI * HTTP/2.0` 서문이면 h2, 아니면 h1 로 넘긴다(`Http_protocol_detect`, 읽은 바이트는 `Replay` 소켓으로 되돌린다). 기본은 `Auto` 다(`Env_config.Transport.h2_mode`, 환경 변수 `MASC_USE_H2`). TLS 는 없다. `Server_bootstrap_http.mli` 가 "No TLS, no ALPN" 이라고 적는다.

세 모드 모두 accept 뒤 `disable_nagle` 로 `TCP_NODELAY` 를 켠다(132~147, 176, 294, 365줄).

### 1.2 경로 표가 둘

| | HTTP/1.1 | HTTP/2 h2c |
|---|---|---|
| 등록 | `Http_server_eio.Router`(`Make_typed`, GADT `_ auth`), 36파일 394곳 | `Server_h2_gateway.make_request_handler` 안 `match httpun_meth, path` 82갈래 + `_routes_extra` 14갈래 + `_artifact_routes`. H2 전용 `.ml` 8개 3,406줄 |
| 인증 | 등록 종류(`Always_public`, `Public_read`, `Read_auth`, `Permission`, `Tool`, …) | A4c `Server_h2_route_gate` 가 H1 표의 종류를 읽어 같은 인증을 적용. 응답 본문은 따로 짬 |
| 요청 값 | `Httpun.Request.t` | `H2.Request.t` 를 `Httpun.Request.create` 로 바꿔 씀(156~165줄) |
| 응답 | `Httpun.Reqd.t` | `H2.Reqd.t` + `Server_h2_response_resources`(64 MiB 응답 ledger, 503 선반영) |
| SSE | `Server_sse_response`(RFC-0493: 소켓 flush 를 기다림, Written·Closed·Stalled) | `Server_h2_response_resources.stream/offer/run` |

한쪽에만 경로를 더해도 컴파일이 통과한다. 그래서 전송마다 404·권한이 달라진 이슈가 쌓였다: #28161, #35592, #46676, #47255, #47348, #47534, #47551, #47609, #40063, #48713.

### 1.3 격리 서버에서 확인한 차이

설치된 바이너리를 격리 워크스페이스에 띄우고(§4 의 도구, 스모크 런 3회, 09:3xZ) `/api/v1/stream/fleet` 을 열었다.

| 전송 | 상태 | 비고 |
|---|---|---|
| HTTP/1.1 | 200, `text/event-stream` | 대시보드 fleet 스트림 |
| h2c | 404 `404 Not Found: /api/v1/stream/fleet` | `server_h2_gateway.ml` 2090줄의 기본 갈래. 게이트웨이 파일 3개에 `stream/fleet` 이 없다 |

대시보드의 주 스트림이 HTTP/2 에서 열리지 않는다. 같은 종류의 차이가 더 있는지는 A1 기준선(`scripts/auth-route-baseline/`, 경로 388개 × 요청 4개)으로 재야 한다.

### 1.4 라이브에서 HTTP/2 사용량

`~/me/.masc/logs/*.log` 687개 파일에서 `stats: h2=N h1=M` 줄(서버 종료 때 리스너가 찍음) 126개를 합쳤다(09:43Z).

| 프로토콜 | 연결 수 |
|---|---|
| h2 | 1 |
| h1 | 403,566 |

```
rg -o --no-filename 'stats: h2=[0-9]+ h1=[0-9]+' ~/me/.masc/logs/*.log
```

## 2. OCaml 생태계 조사

설치 버전은 `opam list --installed --columns=name,installed-version`(09:2xZ)이다.

### 2.1 HTTP/1.1 서버

| 패키지 | 버전 | 사실 |
|---|---|---|
| httpun, httpun-eio, httpun-types | 0.2.0 | 지금 쓰는 것. `Httpun_eio.Server.create_connection_handler` 는 `_ Eio.Net.stream_socket` 을 받는다 |
| gluten, gluten-eio | 0.5.2 | httpun-eio·h2-eio 의 공용 런타임. `Gluten_eio.Server.create_connection_handler : read_buffer_size:int -> protocol:'t Gluten.runtime -> sw -> 't -> Eio.Net.Sockaddr.stream -> _ Eio.Net.stream_socket -> unit`(gluten_eio.mli 34~41줄). `create_upgradable_connection_handler` 로 h2c Upgrade 도 된다 |
| cohttp, cohttp-eio | 6.2.1 | HTTP/1.1 만. 서버로는 안 쓴다 |
| dream | — | Lwt 기반. Eio 서버에 안 맞는다 |

판단: httpun 유지.

### 2.2 HTTP/2 서버

| 항목 | 사실 |
|---|---|
| 패키지 | h2 0.13.0, h2-eio 0.13.0. `scripts/opam-pin-external-deps.sh` 199~200·392~394줄이 `jeong-sik/ocaml-h2` `d7601f201da809857f3878172eea513aaea498ac` 에 고정한다. `opam pin list` 도 같다 |
| 포크 내용 | upstream `anmonteiro/ocaml-h2` 보다 2 커밋 앞(stream 계수, body 완료·flow credit 보존), 7 커밋 뒤(이전 세션 확인). `h2.mli` 는 upstream 0.13.0 과 같다 |
| 설정(`H2.Config`, h2.mli 680~690줄) | `read_buffer_size`, `enable_server_push`(기본 `true`), `max_concurrent_streams`, `initial_window_size`, `max_frame_size`. masc 는 `max_concurrent_streams` 만 바꾼다(`H2_response_limits`, 기본 100). server push 는 RFC 9113 §8.4 가 권하지 않고 Chrome 이 끊었다. 끄는 게 맞다 |
| 없는 것 | `Reqd` 에 stream id·peer reset 콜백이 없다. masc 는 `Server_h2_frame_tap` 으로 프레임을 엿본다(#39050). RFC 8441 extended CONNECT 가 없어 WebSocket over HTTP/2 를 못 한다 |
| 알려진 결함 | anmonteiro/ocaml-h2#278(닫힌 body 의 남은 바이트가 윈도에 잘림)이 열려 있어 `h2_close_after_flush` 로 돈다(`server_h2_gateway_helpers.mli` 17줄, `test_h2_response_window.ml`) |
| 공통점 | `H2.Body.Writer.flush : t -> ([`Written | `Closed] -> unit) -> unit`, `Body.Reader.schedule_read ~on_eof ~on_read`, `respond_with_streaming`, `request_body` 가 httpun 과 같은 모양이다. `H2.Method = Httpun_types.Method` 로 메서드 타입을 공유한다 |

판단: h2 유지. push 끄기. stream id 는 포크에 더하는 별도 작업.

### 2.3 TLS·인증서

| 패키지 | 버전 | 사실 |
|---|---|---|
| tls | 2.1.2 | TLS 1.3. `Tls.Config.server ?alpn_protocols:string list`(config.mli 79~91줄). 서버 목록 순서가 선호 순서다(105줄) |
| tls-eio | 2.1.2 | `server_of_flow : Tls.Config.server -> [> Eio.Flow.two_way_ty | Eio.Resource.close_ty] r -> t`(tls_eio.mli 28~30줄). 반환은 TLS flow 이고 `Eio.Net.stream_socket` 이 아니다. gluten 핸들러에 넘기려면 `Http_protocol_detect.Replay` 처럼 `Eio.Net.Pi.stream_socket` 으로 감싼다. `epoch : t -> (Tls.Core.epoch_data, unit) result`(67줄)로 협상된 ALPN 을 읽는다. RNG 는 `Mirage_crypto_rng_unix.use_default ()` 로 먼저 켠다 |
| x509 | 1.0.6 | `Private_key.generate : ?seed -> ?bits -> Key_type.t -> t`(190줄), `Signing_request.create`·`sign`(218줄), `Certificate.encode_pem`. 자체 서명 인증서를 프로세스 안에서 만들 수 있다 |
| ca-certs | 1.0.1 | 시스템 신뢰 저장소. 클라이언트 쪽에서만 쓴다 |
| mirage-crypto | 1.2.0 | tls 의 암호 |

판단: 프로세스 안 TLS 리스너가 된다. 운영자 인증서(mkcert, Let's Encrypt)를 TOML 로 받고, 없으면 자체 서명.

### 2.4 둘 다 하는 서버: piaf

piaf 0.2.0 `Server.Config` 가 `max_http_version`, `h2c_upgrade`, `allow_insecure` 를 가진다(piaf.mli 274~278·780~798줄). TLS 위 ALPN 으로 HTTP/2 를 고르고 h2c Upgrade 도 한다. 그러나 핸들러가 `Request.t -> Response.t` 를 반환하는 모델이다. masc 는 핸들러가 `Reqd.t` 를 받아 스트리밍 writer 를 직접 몰고(RFC-0493 의 flush 대기), 등록 394곳이 그 모양이다. piaf 로 바꾸면 그 의미를 버리거나 다시 감싸야 한다. piaf 는 쓰지 않고 ALPN 분기 코드만 참고한다.

### 2.5 WebSocket·gRPC

- httpun-ws 0.2.0, ws-direct(자체 포크 `jeong-sik/ws-direct`): HTTP/1.1 Upgrade 만. HTTP/2 에서 WebSocket 경로는 426 이고(`Router.dispatch` 의 `Ws` 갈래), h2 에 extended CONNECT 가 없어 지금은 바꿀 수 없다.
- grpc-direct 0.2.6(자체): 8936 포트 h2c. HTTPS 리스너로 합치는 일은 따로 RFC 로 한다.

### 2.6 HTTP/3·QUIC

opam 에 QUIC 구현이 없다. NLnet 이 지원한 "OCaml-QUIC" 은 "Early research demo" 이고 공개 저장소·릴리스가 없다. 브라우저는 Cloudflare 엣지와 HTTP/3 로 말하고, 엣지와 origin 사이는 HTTP/1.1 또는 HTTP/2 다. origin 쪽 HTTP/3 는 지금 할 수 없다.

### 2.7 압축·측정 도구

- zstd 0.4, decompress 1.5.3 을 쓴다. brotli 패키지는 없다.
- curl 8.7.1(`nghttp2/1.69.0`)이 `--http2-prior-knowledge` 를 지원한다. `h2load` 는 없다(`brew install nghttp2` 는 운영자 결정).
- Python 쪽은 `uv run --with 'httpx[http2]'` 로 임시 환경에 httpx 0.28.1·h2 4.4.1·httpcore 1.0.9 를 받는다. `http1=False, http2=True` 가 h2c prior knowledge 다. 라이브 `/health` 에 보내 `HTTP/2 200` 을 확인했다(09:2xZ).

## 3. 브라우저·터널 쪽 제약

- 브라우저는 cleartext HTTP/2(h2c)를 말하지 않는다. TLS 위 ALPN 에서 `h2` 가 골라져야 HTTP/2 다. Chrome 은 NPN 을 버리고 ALPN 만 남겼다(2016).
- Cloudflare 터널 `originRequest.http2Origin: true` 는 origin 에 HTTP/2 를 시도하지만 공식 문서가 "HTTP/2 to the origin requires HTTPS" 라고 적는다. 자체 서명이면 `noTLSVerify: true` 나 `caPool` 이 필요하다.
- 지금 `~/.cloudflared/config.yml` 은 `masc.crying.pictures`·`masc-dev.crying.pictures` 를 `http://127.0.0.1:8935` 로 보낸다. `http2Origin` 은 없다(11-07 읽음).
- 따라서 지금 구조에서 HTTP/2 로 들어올 수 있는 클라이언트는 h2c prior knowledge 를 아는 CLI(curl, 자체 시험)만이다. §1.4 의 h2=1 이 그 결과다.
- HTTP/1.1 은 브라우저가 origin 당 연결을 6개로 묶는다. 대시보드 한 탭이 fleet 스트림, keeper chat 스트림, execute output, artifact draft live 같은 장수 연결을 여럿 열면 그 상한에 닿는다. HTTP/2 한 연결은 `max_concurrent_streams`(지금 100)까지 스트림을 싣는다. §4 의 SSE 시나리오가 이 차이를 숫자로 보인다.

## 4. 기준선 벤치

### 4.1 도구

`scripts/harness/perf/http_multiplex_probe.py`(uv 스크립트). 설치된 바이너리를 임시 base path·임의 loopback 포트에 띄운다. 런타임 설정은 `scripts/fixtures/release-evidence/runtime.toml`(Keeper 없음, provider 는 죽은 포트)이고, 환경 변수로 gRPC·WS 를 끄고 클라이언트 토큰 버킷을 비울 수 없게 키운다(`MASC_RATE_LIMIT`·`MASC_RATE_BURST` 1,000,000). 대시보드 자산은 `--assets-dir` 로 라이브 서버가 쓰는 `~/me/assets` 를 가리킨다(없으면 `/dashboard/` 가 503 이고 download 시나리오를 건너뛴다). 부팅은 `/health` 와 `/favicon.svg` 가 200 을 줄 때 끝난 것으로 본다(Public_read 경로는 서버 상태가 설치될 때까지 503 을 준다).

| 시나리오 | 내용 | 값 |
|---|---|---|
| serial | 경로 하나를 한 번에 하나씩 N 번 | 큐 없는 왕복 시간 p50·p99 |
| burst | 경로 하나를 C 개 동시에 N 번 | p50·p95·p99(연결 대기 포함), req/s |
| download | 대시보드 번들 `index-*.js`(878,726 B)을 4개 동시에 | MB/s |
| sse | `/api/v1/stream/fleet` S 개를 32초 유지 | 열린 스트림 수, 프레임 수 |

| 전송 | 클라이언트 |
|---|---|
| h1-6 | HTTP/1.1, 연결 6개(브라우저 상한) |
| h1 | HTTP/1.1, 동시 요청 수만큼 연결 |
| h2c | HTTP/2 prior knowledge, 연결 1개 |
| h2 | HTTPS 위 ALPN(TLS 리스너가 생긴 뒤) |

같은 바이너리로 전·후를 재는 것이 조건이다. 수치는 loopback 한 호스트 값이고 원격 클라이언트가 보는 값이 아니다.

### 4.2 기준선 결과

본 측정은 `docs/evidence/http2-one-table-2026-11/baseline/`(09:43Z~09:48Z, 3회 반복, 반복 중앙값)에 있다. 설치 바이너리 0.68.0, 리스너 `auto`, 요청 600개를 100개씩 동시에, 직렬 100개, 다운로드 4개 동시, SSE 50개 32초.

| 시나리오 | h1-6 | h1 | h2c |
|---|---|---|---|
| serial `/favicon.svg` p50 | 1.2 ms | 2.1 ms | 3.8 ms |
| serial `/health` p50 | 6.4 ms | 4.4 ms | 7.9 ms |
| burst `/favicon.svg` p50 / p99 | 200 / 965 ms | 473 / 3,284 ms | 235 / 419 ms |
| burst `/favicon.svg` req/s | 366 | 129 | 414 |
| burst `/health` p50 / p99 | 320 / 1,325 ms | 726 / 7,065 ms | 330 / 617 ms |
| burst `/health` req/s | 246 | 69 | 293 |
| download 878,726 B × 4 | 155 MB/s | 195 MB/s | 25 MB/s |
| sse 50 스트림 열림 | 6 / 50 | 50 / 50 | 0 / 50 (404) |

읽는 법:

- 한 요청씩이면 h2c 가 요청마다 2~3 ms 더 든다. 프레임·HPACK·응답 ledger 의 값이다.
- 100개를 동시에 보내면 h2c 한 연결이 req/s 가 가장 높고 p99 가 가장 짧다. HTTP/1.1 연결 100개(h1)는 p99 가 3~7초로 가장 나쁘다. 서버의 동시 연결 처리 경로에 병목이 있다는 뜻이고, 전송 교체만으로 풀리는 문제가 아니다. 원인은 재지 않았다.
- 큰 몸체 내려받기는 Python 클라이언트에서 h2c 가 HTTP/1.1 의 1/6 이다. 같은 격리 서버에서 curl(nghttp2, C)로 받으면 h2c 가 HTTP/1.1 의 0.84 배다(§4.3). 차이의 큰 몫은 Python h2 클라이언트고, 서버 쪽 h2 비용은 16% 안팎이다. h2 엔진의 flow-control 창(`initial_window_size` 기본 65,535)·프레임 크기·응답 ledger 의 쓰기 단위가 그 16% 의 어디인지는 S5 에서 잰다.
- 브라우저 상한(h1-6)에서는 SSE 50개 중 6개만 열린다. HTTP/2 는 한 연결에 50개를 실을 수 있지만 지금은 경로가 404 라 0개다. 경로 표를 합치고 TLS 리스너를 더해야 이 칸이 50 이 된다.

### 4.3 다운로드 교차 확인(curl)

`docs/evidence/http2-one-table-2026-11/baseline/download-crosscheck/`(09:51Z, 격리 서버, 반복 3회 × 표본 5개). 한 번에 한 파일, `accept-encoding: identity`.

| 클라이언트 | h1 | h2c |
|---|---|---|
| curl 8.7.1 중앙값 | 278 MB/s | 233 MB/s |
| curl 최소 ~ 최대 | 25 ~ 439 MB/s | 42 ~ 345 MB/s |
| Python httpx(4개 동시) 중앙값 | 117 MB/s | 51 MB/s |

loopback 한 호스트 값이라 표본 사이 편차가 크다(최소값은 다른 프로세스와 겹친 표본이다). 전·후 비교는 같은 도구·같은 호스트로만 한다.

## 5. 판단

- 유지: httpun(HTTP/1.1), h2 포크(HTTP/2), gluten-eio, Eio 소켓.
- 더함: tls-eio 리스너(ALPN `h2`, `http/1.1`), x509 자체 서명, `enable_server_push = false`.
- 안 함: piaf 로 교체, HTTP/3, WebSocket over HTTP/2(h2 에 extended CONNECT 가 생기면 다시 본다).
- 열린 질문: (1) 동시 HTTP/1.1 연결에서 처리량이 떨어지는 원인. (2) h2 포크에 `Reqd.stream_id`·peer reset 콜백을 더해 frame tap 을 지울 수 있는지. (3) Cloudflare 가 자체 서명 origin 에 `http2Origin` 으로 붙을 때 `noTLSVerify` 대신 `caPool` 로 갈 수 있는지(운영자 결정).

## 6. 출처

- 설치 인터페이스: `~/.opam/5.5.1/lib/{h2,h2-eio,httpun-eio,gluten-eio,tls,tls-eio,x509,piaf}/*.mli`(2026-11-07 09:3xZ 직접 읽음).
- 포크 고정: `scripts/opam-pin-external-deps.sh` 199~200·392~394줄, `opam pin list`.
- Cloudflare origin parameters — `http2Origin`: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters/origin-parameters/ (11-07 읽음).
- Chrome NPN 제거, ALPN 전용: https://ma.ttias.be/chrome-drops-npn-support-for-http2-alpn-only/ (11-07 읽음).
- NLnet OCaml-QUIC: https://nlnet.nl/project/OCaml-QUIC/ (11-07 읽음).
- RFC 9113 §8.4(server push), §8.2.2(connection 전용 헤더 금지): https://www.rfc-editor.org/rfc/rfc9113
- RFC 8441(WebSocket over HTTP/2): https://www.rfc-editor.org/rfc/rfc8441
- anmonteiro/ocaml-h2#278 — 열려 있음(11-07 확인).
