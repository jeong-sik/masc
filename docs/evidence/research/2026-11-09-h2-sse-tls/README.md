# HTTP/2·SSE 정체, 응답 원장 고갈, TLS 쓰기 실측 기록, 2026-11-09

[연구 문서](../../../research/2026-11-09-h2-sse-stalled-responses-and-tls-writes.md)가 이 기록을 해석한다.
여기에는 서버 로그 원문, 토큰, 프로파일러 출력을 넣지 않았다.
상태 코드, 바이트 수, 서버 카운터, CPU 시간만 남겼다.

## 환경

| 항목 | 값 |
| --- | --- |
| 호스트 | macOS, M3 Max 한 대. 측정하는 동안 다른 부하가 있었다 |
| masc 서버 | 설치된 바이너리를 `scripts/harness/perf/http_multiplex_probe.py` 의 `OwnedServer` 로 띄웠다 |
| 격리 | 새 base path(임시 디렉터리), loopback 빈 포트, Keeper 끔, gRPC·WS 끔, 빈 포트의 TLS 리스너 |
| build | 각 탐침이 `/health` 에서 읽었다. run1 `0a7164246935`, run3~run6 `57b928783c0b`. run2 는 기록하지 않았다. 두 build 의 전송 코드는 같다 |
| 인증 | 격리 서버가 loopback 운영자에게 주는 dashboard dev token(`/api/v1/dashboard/dev-token`). 어떤 파일에도 쓰지 않았다 |
| 탐침 클라이언트 | `uv run --script` 로 돌렸다. PEP 723 의존성은 `httpx[http2]==0.28.1` 이다(python-h2 포함). Python 3.14.4, OpenSSL 3.6.4 |
| TLS 벤치 | masc 밖 OCaml 실행 파일. OCaml 5.5.1 opam switch: eio 1.3, tls·tls-eio 2.1.2, x509 1.0.6, mirage-crypto 1.2.0, digestif 1.3.0. 인증서는 EC P-256 자체 서명(CN=127.0.0.1) |

## 무엇을 돌렸나

시각은 결과 파일을 쓴 때(UTC)다.

| 기록 | 끝난 시각 | 탐침 | 결과 | 내용 |
| --- | --- | --- | --- | --- |
| run1 | 02:27:58 | `h2_sse_leak_probe.py` | `run1-runs.json`, `run1-samples.jsonl` | SSE 스트림을 열고 RST_STREAM 으로 끊음: TLS h2 연결 하나에서 9,660개, h2c 연결 하나에서 2,250개. TLS 연결 200개 절단, TLS 포트에 평문 200번, 끝에 GET 300번. 시나리오 사이마다 `/health` 와 descriptor 표본 |
| run2 | 02:31:23 | `h1_sse_leak_probe.py` | `run2-h1.log` | HTTP/1.1 fleet 2,000 연결, 로그 스트림 2,000 연결. 표준 출력을 그대로 남김 |
| run3 | 02:37:10 | `tls_cipher_probe.py` | `run3-tls.json` | suite 하나로 묶은 `openssl s_client` 로 번들 60개 파이프라인. 모든 suite 를 낼 때 서버가 고른 suite, handshake 30번 |
| run4 | 02:39:54 | `tls_cpu_probe.py`, `tls_client.py` | `run4-tls-cpu.json` | suite 별 처리량과 서버 CPU(ms/MB), 연결 1개·4개, 3회 중앙값 |
| run5 | 02:41:17 | `ledger_starvation_probe.py` | `run5-ledger.json` | 느린 클라이언트가 번들 스트림 90개를 쥐는 동안 다른 연결의 번들·`/health` |
| run6 | 03:20:18 | `h2_stall_probe.py` | `run6-stall.json` | 창 0 을 알린 연결에서 로그 스트림 3개, 105 s 기다린 뒤 창을 엶 |
| 벤치 run1 | 03:05:18 | `tls-write-bench/harness.py` | `tls-write-bench/run1.jsonl` | 소켓 3종 × suite 2종 × 쓰기 크기 2종. 한 연결은 3회 중앙값, 4연결은 동시 실행 1회 |
| 벤치 run2 | 03:09:07 | `tls-write-bench/harness2.py` | `tls-write-bench/run2.jsonl` | 소켓 5종 × suite 2종 × 쓰기 크기 2종. 한 연결은 5회 중앙값, 4연결은 동시 실행 1회 |

`summarize.py` 는 run1 의 출력 디렉터리를 표로 바꾼다. run3 의 macOS `sample` 프로파일 두 개는 호스트 경로가 들어 있고 문서가 쓰지 않아서 남기지 않았다.

## 다시 돌리기

탐침은 출력을 `--out` 디렉터리에 쓴다. `OwnedServer` 도 같은 곳에 `server.log` 를 쓴다. 출력은 이 묶음 밖, 예를 들어 git 이 무시하는 `artifacts/h2-sse-tls/<run>/` 에 둔다.

```bash
uv run --script h2_sse_leak_probe.py --repo <masc worktree> --binary <masc 바이너리> --out <dir>
uv run --script h1_sse_leak_probe.py --repo <masc worktree> --binary <masc 바이너리> --out <dir>
uv run --script tls_cipher_probe.py --repo <masc worktree> --binary <masc 바이너리> --assets <asset 루트> --out <dir>
uv run --script tls_cpu_probe.py --repo <masc worktree> --binary <masc 바이너리> --assets <asset 루트> --out <dir>
uv run --script ledger_starvation_probe.py --repo <masc worktree> --binary <masc 바이너리> --assets <asset 루트> --out <dir>
uv run --script h2_stall_probe.py --repo <masc worktree> --binary <masc 바이너리> --out <dir>
python3 summarize.py <h2_sse_leak_probe 의 --out dir>
```

- `--repo` 는 `scripts/harness/perf/http_multiplex_probe.py` 를 가진 masc 트리다.
- `--assets` 는 `dashboard/assets/index-*.js` 를 가진 asset 루트다. `OwnedServer` 가 `MASC_ASSETS_DIR` 로 넘긴다.
- `tls_cpu_probe.py` 는 클라이언트를 `/opt/homebrew/bin/python3` 로 띄운다. 다른 호스트에서는 그 경로를 바꾼다.
- `tls_cipher_probe.py` 는 PATH 의 `openssl` 을 부른다. OpenSSL 의 `openssl` 이 PATH 에서 먼저 와야 한다. macOS 의 `/usr/bin/openssl` 은 LibreSSL 3.3.6 이고, 그 `s_client` 에는 `-ciphersuites` 가 없다.
- run5 와 run6 는 각각 `h2_sse_leak_probe.py` 의 `H2Conn` 을 가져다 쓴다. 같은 디렉터리에 둔다.

TLS 벤치는 이 묶음 밖의 빈 디렉터리로 복사해서 빌드한다. 저장소의 dune 이 `docs/` 의 빌드 파일을 읽지 않도록, 아래 dune 파일은 묶음에 넣지 않았다.

```
; dune-project
(lang dune 3.0)

; dune
(executable
 (name bench_server)
 (ocamlopt_flags (:standard -O3))
 (libraries eio_main tls-eio mirage-crypto-rng.unix x509 digestif.c unix))

; accel/dune
(executable (name accel) (libraries mirage-crypto))
```

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout key.pem -out cert.pem -days 2 -subj /CN=127.0.0.1
dune build ./bench_server.exe ./accel/accel.exe
./_build/default/accel/accel.exe        # 빈 줄이면 mirage-crypto 가속 없음
python3 harness2.py > run2.jsonl
```

`-O3` 는 flambda 컴파일러에서만 뜻이 있다. 벤치를 빌드한 5.5.1 switch 는 flambda 가 아니다(`ocamlfind ocamlopt -config` 의 `flambda: false`). 그래서 이 플래그는 결과에 아무 영향이 없다. 돌린 그대로 남겼다.

`bench_server` 의 소켓 종류는 이렇다.

- `stock`: accept 한 소켓을 그대로 tls-eio 에 넘긴다. eio 의 4096 바이트 `simple_copy` 를 탄다.
- `copy:N`: tls-eio 의 `copy` 를 N 바이트 버퍼 하나로 읽어 소켓에 쓰는 감싸개다. 버퍼는 연결마다 하나다. 쓰는 fiber 가 하나뿐인 벤치에서만 맞는 모양이다.

## 관찰과 한계

- run1 의 descriptor, TCP descriptor, 리스너 활성 연결, `sse_clients` 는 모든 표본에서 warm 값이었다. 오래 연 연결을 닫은 뒤 cold 값이 됐다.
- run1 의 `live_mb`·`rss_mb` 는 누수 판정에 쓰지 않는다. 부하 없이 잇달아 읽어도 65 MB 흔들렸고, 쉬는 동안 줄지 않았다.
- run1 의 HTTP/1.1 대조(`h1_fleet_close`)는 200 을 하나도 받지 못했다. 탐침의 요청 모양 탓이다. run2 가 HTTP/1.1 대조를 대신한다.
- run1 의 handshake 실패 200번은 1,004 s 걸렸다. 연결마다 탐침의 `recv` 가 5 s 기한을 다 썼다.
- run5 의 느린 클라이언트는 데이터를 확인하지 않는다. 기본 창 65,535 B 만큼만 받는다.
- run6 은 스트림 3개, 한 번 실행이다. 정체 로그 줄 수는 서버 로그에서 셌고 로그 원문은 남기지 않았다.
- 처리량은 표본마다 2배까지 흔들렸다. 서버 CPU(ms/MB)는 안정적이었다.
- 벤치 클라이언트는 harness 를 돌린 Python 이다. 판 문자열은 결과에 남기지 않았다.
- cloudflared 가 쓰는 Go `crypto/tls` 클라이언트로는 재지 않았다.
