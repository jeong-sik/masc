---
rfc: "0512"
title: "경로 표 하나가 HTTP/1.1 과 HTTP/2 를 다 받고, TLS·ALPN 리스너가 HTTP/2 를 실제로 쓰이게 한다"
status: Implemented (S0~S6 병합 2026-11-07~08, after 측정 2026-11-08. 경로 패리티는 #50192)
created: 2026-11-07
updated: 2026-11-09
author: claude
supersedes: []
superseded_by: null
related: ["typed-route-auth", "0493", "0350", "0281", "0204"]
---

# RFC-0512: 경로 표 하나가 HTTP/1.1 과 HTTP/2 를 다 받고, TLS·ALPN 리스너가 HTTP/2 를 실제로 쓰이게 한다

- 상태: 구현됨. S0~S6 병합 2026-11-07~08, after 측정 2026-11-08. 남은 증거(전송별 경로 차이)는 #50192, Q1 은 #50198 이 추적한다.
- 이슈: #35592, #46676, #47255, #47348, #47534, #47551, #47609, #28161, #40063, #48713(전송별 경로 차이), #39050(h2 stream id)
- 근거: 조사는 `docs/research/2026-11-07-http-transport-stack.md`, 기준선은 `docs/evidence/http2-one-table-2026-11/baseline/`(2026-11-07 09:43Z~09:52Z, 설치 바이너리 0.68.0 build-commit `6afc364dd90`). 코드 좌표는 `origin/main` `f8dbd356759` 에서 읽었다.
- 먼저 있는 결정: `typed-route-auth` 가 HTTP/1.1 경로의 인증 종류를 등록 타입으로 적었다(`Router.Make_typed`). A4c 가 HTTP/2 게이트웨이에게 그 종류를 읽게 했다(`Server_h2_route_gate`). RFC-0493 이 SSE 프레임을 소켓 flush 까지 기다리게 했다. RFC-0350 이 H2 요청 fiber 의 admission 을 정했다. 이 RFC 는 그 위에서 응답 쪽을 전송 중립으로 만들고 리스너에 TLS 를 더한다.
- 사용자 결정(2026-11-07): HTTP/2 를 지우는 안은 받지 않았다. 목표는 멀티플렉싱·대역폭·처리량이고, 지원할 수 있는 전송은 다 지원한다.

## 0. 요약

HTTP/1.1 경로는 `Http_server_eio.Router` 에 394곳(36파일)이 등록돼 있고, HTTP/2 는 `Server_h2_gateway` 안의 `match (meth, path)` 96갈래(게이트웨이 82, `_routes_extra` 14)가 같은 경로를 다시 적는다. 한쪽에만 더해도 컴파일이 통과해 전송마다 404·권한이 달라지는 이슈가 10개 쌓였다. 기준선에서 h2c 로 대시보드 fleet 스트림 `/api/v1/stream/fleet` 을 열면 404 다.

그런데 HTTP/2 는 아무도 안 쓴다. 라이브 로그 통계 줄 126개를 합치면 h2 연결 1개, h1 연결 403,566개다. 리스너에 TLS 가 없어서다. 브라우저는 ALPN 으로만 HTTP/2 를 고르고, Cloudflare 터널은 HTTPS origin 에만 HTTP/2 를 보낸다. 경로 표만 합치면 "맞게 돌지만 아무도 안 쓰는 HTTP/2" 가 된다.

이 RFC 는 둘을 같이 한다.

1. 핸들러가 받는 응답 손잡이를 `Httpun.Reqd.t` 에서 masc 소유 닫힌 합타입 `Http_reqd.t`(`Http1 | Http2`)로 바꾼다. 요청 값 타입(`Httpun.Request.t`, `Status`, `Headers`, `Response`)은 그대로 공유한다. 등록 394곳의 몸통은 거의 그대로다. HTTP/2 어댑터는 `H2.Request.t` 를 `Httpun.Request.t` 로 바꿔 같은 `Router.dispatch` 를 부른다. 손 등록 96갈래와 `Server_h2_route_gate`, `_routes_extra`, `_artifact_routes` 는 지운다.
2. 8938 포트에 TLS 1.3 리스너를 더한다(tls-eio). ALPN 목록은 `h2`, `http/1.1` 이고 협상 결과로 h2 또는 httpun 연결 핸들러를 고른다. 인증서는 TOML 로 받고 없으면 자체 서명(x509)을 만든다. 8935 cleartext(HTTP/1.1 + h2c `Auto`)는 그대로 둔다.
3. h2 엔진을 RFC 9113 대로 맞춘다. server push 를 끄고, 응답의 connection 전용 헤더를 떼고, flow-control 창과 프레임 크기를 TOML 로 둔다.
4. 전·후를 같은 벤치(`scripts/harness/perf/http_multiplex_probe.py`)로 재서 `docs/evidence/http2-one-table-2026-11/` 에 남긴다. 구조 목표는 손 등록 갈래 0개, 전송별 경로 차이 0건이다. 성능 숫자 목표는 미리 정하지 않고 측정값으로 보고한다.

## 1. 결정

- D1. **응답 손잡이는 `Http_reqd.t` 다.** `lib/http_reqd.ml` 에 `type t = Http1 of Httpun.Reqd.t | Http2 of h2_stream` 을 둔다. `h2_stream` 은 `H2.Reqd.t`, 요청 switch(RFC-0350 의 request fiber), 응답 자원 ledger(`Server_h2_response_resources`)의 손잡이다. 닫힌 합타입이고 생성자 밖으로 `Httpun.Reqd.t`·`H2.Reqd.t` 를 꺼내는 함수는 두지 않는다. 핸들러 서명은 `Httpun.Request.t -> Http_reqd.t -> unit` 이다. `Router.Wrappers`·`Typed`·`Response`·`Request`·`Server_sse_response` 가 모두 이 타입을 받는다.
- D2. **응답 함수는 `Http_reqd` 가 제공하고 두 생성자를 `match` 로 나눈다.** `respond_with_string`, `respond_with_streaming`(중립 `Body_writer`: `write_string`, `flush : ([`Written | `Closed] -> unit) -> unit`, `close`, `is_closed`), `request_body`(중립 `Body_reader`: `schedule_read ~on_eof ~on_read`, `close`), `request`, `upgrade : t -> Router.upgrade option`(H1 만 `Some`). 두 라이브러리의 writer·reader 가 같은 모양이라 어댑터는 호출을 옮기기만 한다. H2 쪽 `respond_with_string` 은 ledger `reserve` 가 실패하면 빈 503 `cache-control: no-store` 를 보낸다(지금 `h2_respond_*` 와 같다). H2 writer 의 `close` 는 `h2_close_after_flush`(anmonteiro/ocaml-h2#278) 를 맡는다. 상태·헤더 변환(`H2.Status.of_code`, `H2.Headers.of_list`)과 connection 전용 헤더 제거(`connection`, `keep-alive`, `transfer-encoding`, `upgrade`, RFC 9113 §8.2.2)는 H2 갈래 안에서만 한다.
- D3. **진입 절차는 하나다.** `bin/main_eio.ml` 의 HTTP/1.1 전처리(클라이언트 IP 토큰 버킷, agent 토큰 버킷, origin 분류, `Server_request_authority.with_current`, `Server_workspace_precondition` 검사, `Router.dispatch`)를 `lib/server/server_http_ingress.ml` 로 옮기고 두 어댑터가 같은 함수를 부른다. 전송 라벨(메트릭 `protocol`, `auth_refusal_response ~protocol`, 로그)은 `request.version`(`{major=2; minor=0}` 은 H2)에서 읽는다.
- D4. **HTTP/2 어댑터는 연결 층만 남긴다.** `serve_h2_connection`(stream registry, request fiber, frame tap), `Server_h2_response_resources`(ledger), `classify_h2_request`(`:scheme`, `:authority` 검사)가 남는다. 어댑터가 만드는 `Httpun.Request.t` 는 `:path` 를 target 으로, `:authority` 를 `host` 헤더로 옮긴다. 그래서 canonical host 리다이렉트가 HTTP/2 에서도 돈다(#46676 의 둘째 항목). 지우는 것: 게이트웨이 96갈래, `h2_gate_*`, `with_h2_*`, `h2_respond_*`, `h2_read_body*`, `serve_subscriptions_listen_h2`, `server_h2_route_gate.ml/.mli`, `server_h2_gateway_routes_extra.ml`, `server_h2_artifact_routes.ml`, `Server_auth` 의 h2 전용 응답자. 호환용 reader·래퍼는 만들지 않는다.
- D5. **WebSocket 경로는 HTTP/2 에서 426 이다.** `Router.dispatch ?upgrade` 에 H2 어댑터는 `upgrade` 를 주지 않는다(지금 동작). h2 포크에 RFC 8441 extended CONNECT 가 생기면 별 RFC 로 한다.
- D6. **TLS·ALPN 리스너.** `Env_config.Transport` 에 `https_port`(TOML `transport.https_port`, 환경 `MASC_HTTPS_PORT`, 기본 8938, 0 이면 끔), `tls_cert_file`, `tls_key_file`(TOML `transport.tls_cert_file`·`transport.tls_key_file`, PEM 경로)을 둔다. 둘 다 비어 있으면 부팅 때 `<base-path>/.masc/tls/server.{crt,key}` 를 x509 로 만든다(자체 서명, SAN `localhost`·`127.0.0.1`·bind host, 유효 1년, 만료 30일 전부터 재생성). 하나만 있으면 부팅을 거부한다. `Tls.Config.server ~alpn_protocols:["h2"; "http/1.1"]` 로 받고 `Tls_eio.epoch` 의 ALPN 결과로 핸들러를 고른다. ALPN 이 없으면 HTTP/1.1 이다. 8937 은 쓰지 않는다: standalone WebSocket 리스너의 기본값(`MASC_WS_PORT`, `lib/config/env_config_snapshot.ml`, `start-masc.sh` 의 포트 검사)이라 기본 구성에서 두 리스너가 한 포트를 잡게 된다. 기본 포트 표: 8935 HTTP/1.1+h2c, 8936 gRPC, 8937 WebSocket, 8938 HTTPS. TLS flow 는 `Eio.Flow.two_way` 라 `Http_protocol_detect.Replay` 와 같은 `Eio.Net.Pi.stream_socket` 어댑터로 gluten 에 넘긴다. RNG 는 `Mirage_crypto_rng_unix.use_default ()` 로 부팅 때 켠다. TLS 1.3 만 받는다.
- D7. **h2 엔진 설정.** `H2.Config` 의 `enable_server_push = false`. `initial_window_size` 는 TOML `transport.h2_initial_window_size`(환경 `MASC_H2_INITIAL_WINDOW_SIZE`)로 두고 기존 `transport.h2_max_concurrent_streams`·`transport.h2_max_pending_response_bytes` 옆에 등록한다. 기본값은 h2 라이브러리 기본(134,217,728)이고 측정으로 바꾼다. `max_frame_size` 키는 두지 않는다: 핀된 h2 는 상대가 MAX_FRAME_SIZE 를 보내기 전까지 우리 설정 크기로 DATA 프레임을 써서, 16,384 위 값은 Chrome·curl 연결을 끊는다(#49940).
- D8. **측정.** 바꾸기 전 값은 `baseline/`, 바꾼 뒤 값은 같은 도구·같은 호스트로 `after/` 에 둔다(HTTP/1.1, h2c, TLS 위 h2). 구조 목표: `rg -c '"/' lib/server/server_h2_gateway.ml` 가 0, A1 `scripts/auth-route-baseline/` 비교에서 HTTP/1.1 과 HTTP/2 의 상태 코드 차이 0건. 성능은 보고하되 목표 숫자를 미리 적지 않는다. "빨라졌다" 는 기준선 대비 수치가 있을 때만 쓴다.
- D9. **코드는 이 RFC 가 받아들여진 뒤에 쓴다.** 층은 §8 에 있다.

### 1.1 동작

```
cleartext 8935 (지금과 같음)
  accept → TCP_NODELAY → 첫 바이트 읽기
    PRI * HTTP/2.0 서문 → h2 연결 핸들러
    아니면            → httpun 연결 핸들러 (읽은 바이트는 Replay 로 되돌림)

https 8938 (새로움)
  accept → TCP_NODELAY → Tls_eio.server_of_flow (ALPN 목록 h2, http/1.1)
    epoch.alpn_protocol = Some "h2" → h2 연결 핸들러
    그 밖                          → httpun 연결 핸들러
  두 핸들러는 TLS flow 를 감싼 stream_socket 을 받는다

요청 하나 (두 전송 공통)
  어댑터: 요청 값을 Httpun.Request.t 로 (H2 는 :authority → host, version 2.0)
          응답 손잡이를 Http_reqd.t 로 (Http1 reqd | Http2 {reqd; request_sw; ledger})
  Server_http_ingress.handle ~routes ~trust_policy request reqd
    클라이언트 IP 토큰 버킷 → 429
    agent 토큰 버킷 → 429
    origin 분류, authority 바인딩
    workspace 전제조건 → 409/503
    Router.dispatch routes ?upgrade request reqd
      Plain handler → handler request reqd     (handler 는 Http_reqd 로만 응답)
      Ws handler   → upgrade 가 Some 이면 업그레이드, None 이면 426
```

## 2. 지금 모습

`docs/research/2026-11-07-http-transport-stack.md` §1·§4 에서 가져왔다.

| 항목 | 값 |
|---|---|
| HTTP/1.1 경로 등록 | 394곳, 36파일(`Server_route.get/post/prefix_*/add/ws_get`) |
| HTTP/2 손 등록 갈래 | 96(게이트웨이 82, `_routes_extra` 14) |
| HTTP/2 전용 `.ml` | 8파일 3,406줄 |
| 라이브 연결(로그 통계 126줄 합) | h2 1, h1 403,566 |
| 격리 서버에서 h2c `GET /api/v1/stream/fleet` | 404 (HTTP/1.1 은 200) |
| 브라우저 상한(6연결)에서 SSE 50개 | 6개 열림, 44개 대기 |
| 100개 동시 burst `/favicon.svg` req/s | h1-6 366, h1 129, h2c 414 |
| 100개 동시 burst `/favicon.svg` p99 | h1-6 965 ms, h1 3,284 ms, h2c 419 ms |
| 878,726 B 다운로드, curl 중앙값 | h1 278 MB/s, h2c 233 MB/s |

## 3. 왜 이 모양인가

### 3.1 응답 쪽만 중립으로 만든다

게이트웨이는 이미 `H2.Request.t` 를 `Httpun.Request.t` 로 바꿔 쓴다(`server_h2_gateway.ml` 156~165줄). 요청 값은 공유되고, 갈라진 것은 `Httpun.Reqd.t` 하나다. 두 라이브러리의 `Body.Writer.flush`, `Body.Reader.schedule_read`, `respond_with_streaming`, `request_body` 가 같은 모양이고 `H2.Method = Httpun_types.Method` 다. 그래서 중립 손잡이는 얇다. 요청까지 새 타입으로 감싸면 394곳의 `request.Httpun.Request.target`·`headers` 접근을 전부 고쳐야 하고 얻는 것이 없다.

### 3.2 합타입이고 레코드-of-클로저가 아니다

`Http_reqd.t` 를 함수 레코드(`respond : ...; stream : ...`)로 만들면 세 번째 전송을 더하기 쉽지만, 어느 전송인지 `match` 로 못 보고 지연 응답 실패 분류(`Late_response.classify_write_failure` 는 httpun 의 `Failure` 문자열을 본다)를 생성자 갈래 안에 둘 수 없다. 전송은 둘이고 셋째(HTTP/3)는 OCaml 에 없다. 닫힌 합타입으로 하고 갈래마다 전부 적는다.

### 3.3 TLS 를 프로세스 안에 둔다

대안은 Cloudflare 터널만 믿는 것인데, 터널은 origin 에 HTTPS 가 있어야 HTTP/2 를 보낸다. 그러니 어느 쪽이든 서버에 TLS 가 있어야 한다. 로컬 브라우저(개발 대시보드)도 TLS 없이는 HTTP/2 를 안 쓴다. tls-eio 는 이미 의존성이고 TLS 1.3·ALPN 을 한다. 포트를 따로 두는 이유는 8935 를 쓰는 클라이언트(cloudflared 현재 설정, 시험, 스크립트)를 깨지 않기 위해서다.

### 3.4 piaf 로 바꾸지 않는다

piaf 0.2.0 은 HTTP/1.1·HTTP/2·TLS 를 한 API 로 주지만 핸들러가 `Response.t` 를 반환한다. masc 는 핸들러가 writer 를 직접 몰고 RFC-0493 의 flush 대기를 쓴다. 394곳과 SSE 의미를 다 바꾸는 비용이 중립 손잡이보다 크다.

### 3.5 HTTP/2 를 지우지 않는다

사용자 결정이다. 지우면 경로 표는 하나가 되지만 멀티플렉싱도 없다. 브라우저 상한 6연결에서 SSE 44개가 대기하는 것(§2)이 지금 대시보드의 상한이다.

## 4. 운영자에게 보이는 변화

- 새 포트 8938 이 열린다. 끄려면 `transport.https_port = 0`. `MASC_HTTPS_PORT` 로도 바꿀 수 있다.
- `<base-path>/.masc/tls/server.crt`·`server.key` 가 생긴다(운영자 인증서를 TOML 에 적지 않았을 때). 자체 서명이라 브라우저가 경고한다. 경고 없이 쓰려면 mkcert 인증서 경로를 `transport.tls_cert_file`·`transport.tls_key_file` 에 적는다.
- Cloudflare 터널로 HTTP/2 를 쓰려면 운영자가 `config.yml` 의 `service` 를 `https://127.0.0.1:8938` 로 바꾸고 `originRequest.http2Origin: true` 와 `noTLSVerify: true`(또는 `caPool`)를 적는다. 이 RFC 는 그 파일을 건드리지 않는다. 절차는 `docs/guides/https-and-http2.md` 에 적는다.
- `/health` `http_listener` 에 `https` 섹션(`port`, `alpn` 별 연결 수, `tls_source: configured | self_signed`)이 생긴다. `Transport_metrics` 의 `mode` 라벨에 `tls` 가 더해진다. 대시보드 transport-health 카드가 그것을 보인다.
- TOML 키 4개가 생긴다: `transport.https_port`, `transport.tls_cert_file`, `transport.tls_key_file`, `transport.h2_initial_window_size`(마지막은 S5).
- HTTP/2 응답이 바뀌는 곳: 손 등록에 없던 경로가 HTTP/1.1 과 같은 답을 준다(fleet 스트림 200 등). 게이트웨이에만 있던 별명 경로는 없다: 지운 H2 모듈 세 개가 맞추던 경로 리터럴 89개가 모두 살아 있는 등록에 있다(S3 PR 본문의 정적 비교). A1 의 전·후 비교는 아직 하지 않았다. `tools/auth_route_inventory` 빌드가 필요하고 그것을 돌리는 CI 워크플로가 없다(#50192).

## 5. 측정

- 전(이미 있음): `docs/evidence/http2-one-table-2026-11/baseline/`.
- 후(2026-11-08, 바이너리 `9c7452c0e208` = main 에 S0~S6 과 #49862·#49933·#50027 이 들어간 뒤): `docs/evidence/http2-one-table-2026-11/after/`. 전송 `h1-6`·`h1`·`h2c`·`tls-h1`·`tls-h2`, 기준선과 같은 인자. 절차는 그 디렉터리의 README 에 있다.
- 본 것: SSE 50개가 `h2c`·`tls-h2` 에서 50/50 열린다(기준선의 h2c 는 50개 모두 404). HTTP/1.1 의 burst req/s·p50 은 기준선보다 나빠지지 않았다. 같은 측정 안에서 100개 동시 burst 는 한 연결의 h2c·tls-h2 가 h1-6·tls-h1 보다 req/s 1.4~2.3배이고 p99 는 그 19~38% 다. curl 다운로드(한 번에 하나씩)는 h2c 가 h1 의 0.84배(본 측정)·0.73배(교차 확인)이고 기준선(교차 확인 런)은 0.84 였다. tls-h2 는 curl 로 56~59 MB/s(curl h2c 의 1/7.4~1/7.5, curl tls-h1 은 재지 않음)이고 Python 4개 동시로는 tls-h1 88~93 / tls-h2 81~87 MB/s 라, TLS 위의 손실은 TLS 리스너의 비용이다. 한 요청 왕복에서 h2c 는 h1 보다 0.2~0.7 ms 더 든다(기준선 1.7~3.5 ms). 기준선과 사이에 이틀치 main 변경과 측정 시각 차이가 있어 HTTP/1.1 값의 개선은 이 스택의 효과로 읽지 않는다.
- 전송별 경로 차이: 아직 재지 않았다. `tools/auth_route_inventory` 를 빌드해야 하고 그것을 돌리는 CI 워크플로가 없다. #50192 가 추적한다.
- 브라우저(2026-11-09, `docs/evidence/http2-one-table-2026-11/after/browser.md`): ego lite 0.6.2.9(Chromium 156)로 연 대시보드 한 탭이 TLS 리스너에서는 문서와 자원 35개를 모두 `h2` 로 받고, load 5초 뒤 측정 순간 연결 1개를 열고 있었다. 같은 탭이 평문 리스너에서는 `http/1.1` 로 받고 같은 순간 연결 4개를 열고 있었다. 연 연결의 총수는 재지 않았다.

## 6. 열린 질문

- Q1. 동시 HTTP/1.1 연결 100개에서 p99 가 3~7초로 떨어지는 원인. 전송이 아니라 서버의 동시 처리 경로일 수 있다. S5 는 따로 재지 않았다. after 측정에서 `h1` 의 p99 는 0.7~1.4초로 여전히 다섯 전송 중 가장 길다. 원인 측정은 #50198, 고치는 일은 이 RFC 밖이다.
- Q2. h2 포크에 `Reqd.stream_id`·peer reset 콜백을 더해 `Server_h2_frame_tap`(#39050) 을 지울 수 있는지. 별 이슈로 남긴다.
- Q3. 자체 서명 인증서의 SAN 에 bind host 외에 무엇을 넣을지(운영자가 `--host 0.0.0.0` 으로 띄우는 경우).
- Q4. `Public_read` 같은 strict 인증 종류가 TLS 리스너와 cleartext 리스너에서 같은지. 같아야 한다. A1 을 두 포트에 돌려 확인한다.

## 7. 하지 않는 것

- gRPC(8936)를 TLS 리스너로 옮기는 일. WebSocket over HTTP/2. HTTP/3. 바깥 클라이언트 스택 통합(RFC-0107).
- 옛 게이트웨이 동작을 위한 호환 reader·fallback·feature flag. 지운 모듈을 "폐기됐다" 고 적은 주석.
- 성능 숫자 목표. 측정값만 적는다.
- `test_h2_journal.ml`·`test_h2_composition_resume.ml`(이름의 H2 는 하네스 작업 번호)·`test_pool_h2_request_body.ml`(piaf 클라이언트)은 건드리지 않는다.

## 8. 층과 닫는 이슈

| 층 | 브랜치 | 내용 |
|---|---|---|
| S0 | `research/http-transport-ecosystem` | 조사 문서, 벤치 도구, 기준선(들어 있음) |
| S1 | `rfc/one-route-table-both-transports` | 이 문서 |
| S2 | `http/neutral-reqd` | `Http_reqd`, `Http_server_eio` 의 `Response`·`Request`·`Router`·`Wrappers`·`Typed`, `Server_sse_response`, 직접 호출 ~25곳, 시험 픽스처 `Http_reqd.of_httpun`. H2 쪽은 안 건드림 |
| S3 | `http/shared-ingress-and-gateway-fold` | `Server_http_ingress`, H2 어댑터 55줄, 삭제 목록(D4). H2 end-to-end 시험은 접힌 어댑터를 그대로 치고, H2 역학 시험은 `Http_reqd.of_h2` 손잡이 위의 공용 `Response` 를 친다. 두 전송 공용 픽스처는 만들지 않는다: 표가 하나라 같은 케이스를 두 번 돌려도 잡을 차이가 없다 |
| S4 | `http/tls-alpn-listener` | D6. `Server_tls_material`(설정 파일 쌍 또는 `.masc/tls/` 자체 서명 P-256, 365일, 만료 30일 전 재생성), `Tls_stream_socket`(TLS 세션을 h2-eio·httpun-eio 가 받는 소켓으로), `Server_bootstrap_http.serve_tls`(ALPN 결과로 h2·httpun 선택, accept 루프는 네 리스너가 `run_accept_loop` 하나를 씀), `Https_listener_metrics`(`/health`·transport-health 의 `https_listener`, OTel `masc_https_*`), 대시보드 HTTPS 카드, `docs/guides/https-and-http2.md`. 포트가 잡혀 있으면 부팅은 계속되고 `bind_failed` 로 보인다 |
| S5 | `http/h2-engine-tuning` | D7: `Server_bootstrap_http.h2_config`(push 끔, `H2_response_limits` 의 윈도), TOML 키 1개와 registry 1행, 프로브의 `tls-h1`·`tls-h2` 전송(소유 서버는 `MASC_HTTPS_PORT` 로 TLS 리스너를 염), 측정 절차 `docs/evidence/http2-one-table-2026-11/README.md`. `after/` 는 설치 뒤 같은 호스트에서 |
| S6 | `docs/http2-one-table` | `docs/spec/09-server-transport.md`, `01-system-overview.md`(OQ-SYS-002), `TRANSPORT-PRACTICAL-PLAYBOOK.md`, `guides/h2-response-resources.md`, `verify_h2c_autodetect.sh` |

S3 병합으로 닫는 이슈: #35592, #46676, #47609, #47255. #47348, #47534, #47551 은 S5 의 `after/` 측정(fleet SSE 가 h2c 로 열리는지, 전송별 경로 차이 0건)이 보여 준 뒤 닫는다. #40063·#35579 는 HTTP/2 부분만 코멘트. 새 이슈: h2 포크 stream id(#39050 후속), WebSocket over HTTP/2, gRPC 를 TLS 리스너로, Q1.
