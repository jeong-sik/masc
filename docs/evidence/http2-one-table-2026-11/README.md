# HTTP/2 한 표 캠페인 측정 (RFC-0512)

`baseline/` 은 경로 표 통합과 TLS 리스너 전(main `6afc364`)의 값이다. `after/` 는 스택(S0~S5)으로 만든 바이너리를 같은 호스트에 설치한 뒤 같은 인자로 잰 값을 둔다. 두 묶음은 같은 프로브, 같은 호스트, 같은 인자로만 비교한다.

## 전송

| 이름 | 뜻 |
|---|---|
| `h1-6` | HTTP/1.1, 연결 6개(브라우저의 origin 당 상한) |
| `h1` | HTTP/1.1, 동시 요청 수만큼 연결 |
| `h2c` | HTTP/2 prior knowledge, 연결 1개(cleartext 리스너) |
| `tls-h1` | HTTP/1.1 over TLS, 연결 6개(TLS 리스너, ALPN http/1.1) |
| `tls-h2` | HTTP/2 over TLS, 연결 1개(TLS 리스너, ALPN h2) |

`tls-*` 는 S4 의 TLS 리스너가 있어야 한다. 소유 서버(`--binary`)는 `MASC_HTTPS_PORT` 로 임의 loopback 포트에 TLS 리스너를 열고, 임시 base path 아래 `.masc/tls/` 에 자체 서명 인증서를 만든다. 클라이언트(httpx, curl `-k`)는 인증서를 검증하지 않는다. 붙는 서버(`--base-url`)에는 `--https-base-url` 로 TLS 리스너 주소를 같이 준다.

## `after/` 재는 절차

1. 스택 head 로 바이너리를 만들어 설치한다(`~/.local/bin/masc`). `masc --version` 의 build-commit 을 적는다.
2. 기준선과 같은 인자로 돌린다. 전송 다섯 개를 모두 적는다.

```bash
uv run scripts/harness/perf/http_multiplex_probe.py \
  --binary ~/.local/bin/masc --assets-dir ~/me/assets \
  --output artifacts/http-multiplex/$(date -u +%Y%m%dT%H%M%SZ) \
  --transports h1-6,h1,h2c,tls-h1,tls-h2 \
  --requests 600 --serial-requests 100 --concurrency 100 \
  --sse-streams 50 --sse-hold-s 32 --repeats 3
python3 scripts/harness/perf/summarize_http_multiplex.py artifacts/http-multiplex/<run>
```

3. `results.json`, `identity.json`, `summary.md`, `download-crosscheck/` 를 `after/` 에 복사하고 `after/README.md` 에 시각, 바이너리, 호스트, 라이브 서버가 같이 돌았는지를 적는다.
4. 기준선과 견준다: `h1`·`h1-6` 의 req/s 와 p50 이 떨어지지 않았는지, `h2c`·`tls-h2` 의 한 연결 동시 100 요청과 SSE 50 스트림 값이 어떤지 표로 둔다.

측정하지 않은 값은 적지 않는다.
