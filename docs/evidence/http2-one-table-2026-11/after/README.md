# HTTP/1.1·h2c·TLS 뒤 측정 (경로 표 통합·TLS 리스너 뒤)

2026-11-08 23:29Z ~ 23:39Z, 설치된 바이너리 `~/.local/bin/masc` 0.69.0, build-commit `9c7452c0e2086d3c1b557cba9f7e649089bf86d7`(main: S0~S6 와 #49862·#49933·#50027 포함, #50056 미포함), sha256 `f6e3db697c5816f030359c3b926638c3576ff2f10bbc0db1a833dd6aef646c3a`. 기준선은 `../baseline/`(2026-11-07 09:43Z, 0.68.0 `6afc364`)이다.

## 조건

- 서버·클라이언트·호스트·인자는 기준선과 같다. `scripts/harness/perf/http_multiplex_probe.py` 가 임시 base path 와 임의 loopback 포트에 띄운 격리 서버, 요청 600개 동시 100, 직렬 100, 다운로드 4개 동시, SSE 50 스트림 32초, 반복 3회의 중앙값이다. 클라이언트는 httpx 0.28.1 / httpcore 1.0.9 / h2 4.4.1(`uv run` 임시 환경), 교차 확인은 curl 8.7.1(libcurl 8.7.1, SecureTransport). 프로브 스크립트는 S5 가 TLS 전송과 curl tls-h2 대상을 더한 판이다. serial·burst·download·sse 로직은 S0 병합본의 프로브(기준선 교차 확인 런이 쓴 판)와 같다. 기준선 본 런의 프로브(sha 2af4098f)는 git 에 없다.
- 전송 다섯 개. 기준선의 `h1-6`(HTTP/1.1 연결 6개)·`h1`(동시 요청 수만큼 연결)·`h2c`(prior knowledge 연결 1개)에 TLS 리스너의 `tls-h1`(ALPN http/1.1, 연결 6개)·`tls-h2`(ALPN h2, 연결 1개)를 더했다. 소유 서버는 `MASC_HTTPS_PORT` 로 임의 포트에 TLS 리스너를 열고 임시 base path 의 `.masc/tls/` 에 자체 서명 인증서를 만들었다. 클라이언트는 인증서를 검증하지 않는다.
- 호스트는 기준선과 같은 Apple M3 Max, macOS 27.2 arm64, loopback. 라이브 서버(8935·8938, 같은 바이너리, 11-08 23:07Z 재시작)는 같은 시간에 돌고 있었다.
- 기준선과 이 측정 사이에는 전송 층 말고도 이틀치 main 변경이 들어 있고 측정 시각도 다르다(기준선 18:43 KST, 이번 08:29 KST). 그래서 HTTP/1.1 값이 좋아진 것을 이 스택의 효과로 읽지 않는다. 같은 측정 안에서 전송끼리 견준 값만 전송의 차이로 읽는다.

## 결과

`summary.md` 는 `scripts/harness/perf/summarize_http_multiplex.py` 가 `results.json` 에서 만든 표다. 기준선(전) → 이번(후):

| 시나리오 | h1-6 전 → 후 | h1 전 → 후 | h2c 전 → 후 | tls-h1 | tls-h2 |
|---|---|---|---|---|---|
| serial `/favicon.svg` p50 (100개를 하나씩) | 1.2 → 1.0 ms | 2.1 → 0.7 ms | 3.8 → 0.9 ms | 0.8 ms | 1.3 ms |
| serial `/health` p50 | 6.4 → 1.8 ms | 4.4 → 1.4 ms | 7.9 → 2.1 ms | 2.0 ms | 2.3 ms |
| burst `/favicon.svg` p50 / p99 (600개, 100 동시) | 200 / 965 → 106 / 503 ms | 473 / 3,284 → 125 / 708 ms | 235 / 419 → 58 / 94 ms | 126 / 574 ms | 86 / 131 ms |
| burst `/favicon.svg` req/s | 366 → 683 | 129 → 548 | 414 → 1,557 | 556 | 1,073 |
| burst `/health` p50 / p99 | 320 / 1,325 → 144 / 673 ms | 726 / 7,065 → 245 / 1,411 ms | 330 / 617 → 93 / 199 ms | 133 / 569 ms | 129 / 217 ms |
| burst `/health` req/s | 246 → 517 | 69 → 262 | 293 → 934 | 566 | 793 |
| download 878,726 B × 4 동시 (Python) | 155 → 409 MB/s | 195 → 450 MB/s | 25 → 175 MB/s | 88 MB/s | 81 MB/s |
| sse `/api/v1/stream/fleet` 50개 32초, 열린 수 | 6 / 50 → 6 / 50 | 50 / 50 → 50 / 50 | 0 / 50 (404) → 50 / 50 (200) | 6 / 50 | 50 / 50 |

`download-crosscheck/`(23:40Z, 같은 조건, download·curl 시나리오만, 반복 3회): Python 4개 동시 다운로드 h1-6 423 / h1 426 / h2c 196 / tls-h1 93 / tls-h2 87 MB/s. curl 한 번에 하나씩 15표본 중앙값 h1 597 / h2c 436 / tls-h2 59 MB/s(본 측정에서는 495 / 416 / 56).

## 읽는 법

- RFC-0512 §5 가 보기로 한 것. SSE 50개는 `h2c` 와 `tls-h2` 에서 50개 다 열린다. 기준선의 `h2c` 는 50개 전부 404 였다(손 등록 갈래에 fleet 스트림이 없었다). `h1-6`·`tls-h1` 은 브라우저 상한인 6개만 열리고 나머지 44개는 hold 창 안에 연결을 받지 못한다(`PoolTimeout`). HTTP/1.1 의 burst req/s 와 p50 은 기준선보다 나빠지지 않았다.
- 같은 측정 안에서 100개 동시 burst 는 한 연결의 `h2c` 가 req/s 가 가장 높고 p99 가 가장 짧다. `/favicon.svg` 에서 h2c 1,557 대 h1-6 683 req/s, p99 94 대 503 ms. TLS 위에서도 같은 모양이다. tls-h2 1,073 대 tls-h1 556 req/s, p99 131 대 574 ms.
- 한 요청씩 보내면 `h2c` 가 `h1` 보다 0.2~0.7 ms 더 든다. 기준선에서는 1.7~3.5 ms 였다.
- 다운로드는 curl 한 번에 하나씩의 중앙값으로 `h2c` 가 `h1` 의 0.84배(본 측정 416 / 495), 교차 확인에서는 0.73배(436 / 597)다. 기준선의 0.84(233 / 278)는 기준선의 교차 확인 런 값이다. `tls-h2` 는 curl 로 56~59 MB/s 로 curl `h2c` 의 1/7.4~1/7.5 이다(curl `tls-h1` 은 재지 않았다). 같은 클라이언트끼리 보면 Python 4개 동시 다운로드가 `tls-h1` 88~93 / `tls-h2` 81~87 MB/s 로 비슷해서, TLS 위의 손실은 h2 의 비용이 아니라 TLS 리스너의 비용이다. TLS 는 프로세스 안의 ocaml-tls 가 처리한다. 어디까지가 암호화 비용이고 어디부터가 소켓 어댑터(`Tls_stream_socket`) 비용인지는 이 측정으로 가르지 않았다. Python h2 클라이언트의 다운로드(175 MB/s)는 curl(416 MB/s)보다 느리다. 기준선과 같은 모양이다.
- HTTP/1.1 연결 100개(`h1`)의 p99 가 여전히 다섯 전송 중 가장 길다(0.7~1.4초, 기준선 3~7초). 원인은 이 묶음에서 재지 않았다(RFC-0512 Q1).

## 재지 않은 것

- 원격 클라이언트가 보는 값, cloudflared 를 거친 값. 측정 시점에 터널은 아직 평문 origin(8935)으로 붙어 있었다. Keeper 가 도는 서버.
- 전송별 경로 차이의 전체 목록(`scripts/auth-route-baseline/`). `tools/auth_route_inventory` 실행 파일이 필요하다.
- 왜 HTTP/1.1 동시 연결에서 p99 가 길어지는지. 어디까지가 TLS 암호화 비용인지.

## 파일

- `identity.json`: 바이너리 digest·버전·build-commit, 리스너·transport health, 클라이언트 버전, 인자, 환경 변수 이름. 호스트 사용자 경로 `/Users/<user>` 를 `~` 로 바꾼 파생본이다. 자격 증명은 격리 서버가 loopback 에 내준 대시보드 dev-token 이고 기록하지 않았다.
- `results.json`: 시나리오·전송·반복마다 한 행(원본 그대로). SSE 행의 `sample_events` 는 프레임 앞 80바이트다.
- `summary.md`: 생성된 표. 바이너리 경로의 사용자 경로만 `~` 로 바꿨다.
- `download-crosscheck/`: 같은 세 파일, download·curl 시나리오만.
- `browser.md`: 브라우저가 보는 전송(문서·자원의 `nextHopProtocol`, 한 탭의 연결 수). 2026-11-09 측정.
- 서버 로그는 임시 경로가 들어 있어 남기지 않았다.

## 다시 재기

```bash
uv run scripts/harness/perf/http_multiplex_probe.py \
  --binary ~/.local/bin/masc --assets-dir ~/me/assets \
  --output artifacts/http-multiplex/$(date -u +%Y%m%dT%H%M%SZ) \
  --transports h1-6,h1,h2c,tls-h1,tls-h2 \
  --requests 600 --serial-requests 100 --concurrency 100 \
  --sse-streams 50 --sse-hold-s 32 --repeats 3
python3 scripts/harness/perf/summarize_http_multiplex.py artifacts/http-multiplex/<run>
```
