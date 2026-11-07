# HTTP/1.1 과 HTTP/2 h2c 기준선 (경로 표 통합·TLS 리스너 전)

2026-11-07 09:43Z ~ 09:52Z, 설치된 바이너리 `~/.local/bin/masc` 0.68.0, build-commit `6afc364dd901726af020c84d491f33b139477d78`, sha256 `87e13646e1e41b9785441e33b808a59bf4de8cb5b9ba2fe4a1af4e843c842ae7`. 조사 문서는 `docs/research/2026-11-07-http-transport-stack.md`, 결정은 RFC-0511 이다. 이 묶음은 바꾸기 전 값이다. 바꾼 뒤 값은 같은 도구로 재서 `../after/` 에 둔다.

## 조건

- 서버: `scripts/harness/perf/http_multiplex_probe.py` 가 임시 base path 와 임의 loopback 포트에 띄운 격리 서버. 런타임 설정은 `scripts/fixtures/release-evidence/runtime.toml`(Keeper 없음, provider 는 죽은 포트 9). 환경 변수로 gRPC·WebSocket 을 끄고, 클라이언트 토큰 버킷을 1,000,000 으로 키웠다(기본 100/s·burst 150 이면 600개 burst 가 429 를 받아 버킷을 재게 된다). `MASC_USE_H2` 는 두지 않아 리스너는 기본 `auto`(HTTP/1.1 + h2c 한 포트)다. 대시보드 자산은 `MASC_ASSETS_DIR=~/me/assets`(라이브 서버가 쓰는 트리, 번들 `index-Z7C9n29H.js` 878,726 B). 서버는 두 런 모두 exit 0 으로 끝났다.
- 클라이언트: Python 3.14, httpx 0.28.1, httpcore 1.0.9, h2 4.4.1(`uv run` 임시 환경). `accept-encoding: identity`. 자격 증명은 격리 서버가 loopback 에 내주는 대시보드 dev-token 이고 기록하지 않았다. 교차 확인은 curl 8.7.1(nghttp2 1.69.0).
- 호스트: Apple M3 Max 16코어, 128 GiB, macOS 27.2 arm64. 서버·클라이언트가 같은 호스트의 loopback 이다. 라이브 서버(8935)는 같은 시간에 돌고 있었다.
- 전송: `h1-6` HTTP/1.1 연결 6개(브라우저의 origin 당 상한), `h1` HTTP/1.1 동시 요청 수만큼 연결, `h2c` HTTP/2 prior knowledge 연결 1개.
- 반복 3회, 전송 순서는 반복마다 돌렸다. 표의 값은 반복 중앙값이다.

## 결과

`summary.md` 는 `scripts/harness/perf/summarize_http_multiplex.py` 가 `results.json` 에서 만든 표다. 요약:

| 시나리오 | h1-6 | h1 | h2c |
|---|---|---|---|
| serial `/favicon.svg` p50 (100개를 하나씩) | 1.2 ms | 2.1 ms | 3.8 ms |
| serial `/health` p50 | 6.4 ms | 4.4 ms | 7.9 ms |
| burst `/favicon.svg` p50 / p99 (600개, 100 동시) | 200 / 965 ms | 473 / 3,284 ms | 235 / 419 ms |
| burst `/favicon.svg` req/s | 366 | 129 | 414 |
| burst `/health` p50 / p99 | 320 / 1,325 ms | 726 / 7,065 ms | 330 / 617 ms |
| burst `/health` req/s | 246 | 69 | 293 |
| download 878,726 B × 4 동시 (Python) | 155 MB/s | 195 MB/s | 25 MB/s |
| sse `/api/v1/stream/fleet` 50개 32초, 열린 수 | 6 / 50 | 50 / 50 | 0 / 50 |

`download-crosscheck/`(09:51Z, 같은 조건, 반복 3회): Python 4개 동시 다운로드 h1-6 143 / h1 117 / h2c 51 MB/s. curl 한 번에 하나씩 15표본 중앙값 h1 278 MB/s, h2c 233 MB/s.

## 읽는 법

- SSE 는 지금 HTTP/2 로 열리지 않는다. h2c 의 50개 전부가 `404 Not Found: /api/v1/stream/fleet` 이다. `server_h2_gateway.ml` 의 손 등록 갈래에 fleet 스트림이 없다(경로 표가 둘인 결과). `h1-6` 은 브라우저 상한 그대로 6개만 열리고 44개는 연결을 기다리다 hold 창 안에 열리지 못했다(`PoolTimeout`).
- 100개 동시 burst 에서는 h2c 한 연결이 req/s 가 가장 높고 p99 가 가장 짧다. HTTP/1.1 연결 100개가 p99 3~7초로 가장 나쁘다. 서버의 동시 연결 처리에 병목이 있다는 뜻이고 원인은 이 묶음에서 재지 않았다.
- 한 요청씩 보내면 h2c 가 2~3 ms 더 든다.
- Python h2 클라이언트의 다운로드가 느리다. curl 로는 h2c 가 h1 의 0.84 배다. 서버 쪽 h2 비용은 그 안에 있다.

## 재지 않은 것

- TLS·ALPN 경로(리스너가 없다). 원격 클라이언트가 보는 값. Keeper 가 도는 서버. 전송별 경로 차이의 전체 목록(A1 `scripts/auth-route-baseline/` 가 재는 것).
- 왜 HTTP/1.1 동시 연결에서 처리량이 떨어지는지.

## 파일

- `identity.json`: 바이너리 digest·버전·build-commit, 리스너·transport health, 클라이언트 버전, 인자, 환경 변수 이름. 호스트 사용자 경로 `/Users/<user>` 를 `~` 로 바꾼 파생본이다.
- `results.json`: 시나리오·전송·반복마다 한 행(원본 그대로). SSE 행의 `sample_events` 는 프레임 앞 80바이트다.
- `summary.md`: 생성된 표.
- `download-crosscheck/`: 같은 세 파일, download·curl 시나리오만.
- 서버 로그는 임시 경로가 들어 있어 남기지 않았다.

## 다시 재기

```bash
uv run scripts/harness/perf/http_multiplex_probe.py \
  --binary ~/.local/bin/masc --assets-dir ~/me/assets \
  --output artifacts/http-multiplex/$(date -u +%Y%m%dT%H%M%SZ) \
  --requests 600 --serial-requests 100 --concurrency 100 \
  --sse-streams 50 --sse-hold-s 32 --repeats 3
python3 scripts/harness/perf/summarize_http_multiplex.py artifacts/http-multiplex/<run>
```
