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
| build | 각 탐침이 `/health` 에서 읽었다. run1 `0a7164246935`, run3~run6 `57b928783c0b`. run8 `eb22878fa756`, run8b `c9b8e1af3cbe`, run9 `1c5524344b0f`, run10·run12 `c9b8e1af3cbe`, run11 `379d483de91a`, run13 `379d483de91a` 과 `e0f124c927a5`, run14 `379d483de91a` 과 `fa36c50f263f`·`31b43e9ebafa`. run2 는 기록하지 않았다. 두 build 의 전송 코드는 같다 |
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
| 벤치 run3 | 11-11 11:55~12:05 | `tls-write-bench/harness3.py`, `tls-write-bench/goclient/main.go` | `tls-write-bench/run3.jsonl` | tls 2.1.5. 소켓 4종(`pieces` = 호출마다 버퍼) × suite 2종 × 쓰기 크기 4종 × 클라이언트 2종(OpenSSL, Go `crypto/tls`). 한 연결 5회 중앙값. 다른 빌드가 돌던 장비에서 한 번 돌았다 |
| 벤치 run4 | 11-11 13:23~13:25 | `tls-write-bench/harness4.py` | `tls-write-bench/run4.jsonl` | tls 2.1.5. tls-eio 3종(릴리스, 릴리스 + `copy:262144` 소켓, `write_t` 를 고친 포크) × suite 2종 × 쓰기 크기 3종 × 클라이언트 2종. 한 연결 5회 중앙값. 다른 빌드가 돌던 장비에서 한 번 돌았다(load average 153→62) |
| run8 | 11-11 10:17:01 | `h2_stall_probe.py` | `run8-stall.json` | run6 과 같은 장면을 RFC-0518 D1·D2 가 든 build `eb22878fa756` 에서 다시 돌림. 탐침이 스트림마다 RST 를 받은 시각과 서버의 reset 로그 줄 수를 더 적는다 |
| run8b | 11-11 13:17:09 | `h2_stall_probe.py` | `run8b-stall.json` | run8 과 같은 장면을 D4·D5·D6·D8 까지 든 설치 build `c9b8e1af3cbe` 에서 한 번 더 돌림 |
| run9 | 11-11 10:14:44 | `h2_sse_leak_probe.py` | `run9-runs.json`, `run9-samples.jsonl` | run1 과 같은 장면을 RFC-0518 D1·D2·D3·D7·D9 가 든 build `1c5524344b0f` 에서 다시 돌림 |
| run10 | 11-11 13:02:09 | `ledger_starvation_probe.py` | `run10-ledger.json` | run5 와 같은 장면을 RFC-0518 D5 가 든 설치 build `c9b8e1af3cbe` 에서 다시 돌림 |
| run11 | 11-11 13:08:59 | `tls_cpu_probe.py`, `tls_client.py` | `run11-tls-cpu-before.json` | run4 와 같은 장면. D8 이 없는 build `379d483de91a`(main `b88dd6902027` 위의 다른 branch 빌드, tls 2.1.5) |
| run12 | 11-11 13:09:26 | `tls_cpu_probe.py`, `tls_client.py` | `run12-tls-cpu.json` | run11 바로 뒤에 같은 장면을 D4·D5·D6·D8 이 든 설치 build `c9b8e1af3cbe` 에서 돌림 |
| run13 | 11-11 15:36~15:48 | `tls_cpu_probe.py`, `tls_client.py` | `run13-tls-cpu-rounds.json` | run11·run12 와 같은 장면을 다섯 번. run11 의 실행 파일과 tls-eio 포크가 든 설치 build `e0f124c927a5` 를 한 번씩 잇달아 돌리고 순서를 번갈았다. 연결마다 요청 300개로 두 번 더 |
| run14 | 11-12 07:00~07:29 | `tls_cpu_probe.py`, `tls_client.py` | `run14-tls-cpu-rounds.json` | run13 과 같은 장면을 연결마다 요청 300개로 다섯 번. run11 의 실행 파일과 #51545 가 든 설치 build 를 한 번씩 잇달아 돌리고 순서를 번갈았다 |

`summarize.py` 는 run1 의 출력 디렉터리를 표로 바꾼다.

run3 의 `bench_server.ml` 은 run1·run2 것에 `pieces` 소켓을 더한 것이다. tls 2.1.5 는 EC 인증서에 EC 키를 쓰는 suite 가 없으면 설정을 거절해서 TLS 1.2 suite 하나를 목록 끝에 붙였다. 리스너는 1.3 만 받으므로 고르지 않는다. Go 클라이언트는 `go build -o ../bench_client_go .` 로 만든다. run3 의 macOS `sample` 프로파일 두 개는 호스트 경로가 들어 있고 문서가 쓰지 않아서 남기지 않았다.

run4 의 `patched` 서버는 같은 `bench_server.ml` 을 tls-eio 포크 커밋 `2c0f8615865a`(`jeong-sik/ocaml-tls`, v2.1.5 에 커밋 하나)의 `eio/` 소스에 링크한 것이다. 그 커밋은 `write_t` 가 암호문을 `Eio.Flow.write` 로 쓰게 한다. `harness4.py` 는 릴리스 쪽 서버를 `_build/default/bench_server.exe`, 포크 쪽을 `_build/default/p/bench_server.exe` 에서 찾는다. `p/dune` 은 `(copy_files ../bench_server.ml)` 로 같은 소스를 받고, 포크의 `eio/tls_eio.ml`·`x509_eio.ml` 과 그 `.mli` 로 만든 `(library (name tls_eio_patched) (wrapped false) (libraries tls eio ptime.clock.os))` 에 링크한다. 5.5.2 switch 에서 빌드했다.

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
- `tls_cpu_probe.py` 는 서버 CPU 를 macOS 에서 `ps -o time`(0.01초 단위), Linux 에서 `/proc/<pid>/stat`(1/`SC_CLK_TCK` 초 단위, `SC_CLK_TCK` 가 100 이면 0.01초)로 읽는다. Linux 의 `ps -o time` 은 1초 단위라 쓰지 않는다.
  - 읽은 눈금은 결과의 `cpu_clock_step_s` 에 남는다.
  - 두 시계 모두 서버가 띄운 자식 프로세스의 CPU 는 세지 않는다.
  - 평문 연결 하나의 서버 CPU 는 `--n 60` 에서 약 0.1초(눈금 10칸), `--n 300` 에서 약 0.5초(50칸)다(run13 의 1.92 ms/MB 기준).
  - 결과의 `runs` 에 실행마다 보낸 MB, 걸린 시간, 서버 CPU 초가 남는다. 중앙값이 눈금 몇 칸 위에 서 있는지 여기서 본다.
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

## run7: HTTP/2 본문을 h2 에 조각 몇 개씩 넣을 때의 프레임 수와 시간, 2026-11-10

RFC-0518 D3 이 본문을 h2 에 조각 둘까지 넣기로 한 근거다. 위의 run1~run6 과 달리 설치된 masc 서버를 띄우지 않았다.

| 항목 | 값 |
| --- | --- |
| 실행 파일 | `test/test_h2_request_fibers.ml` 에 `h2_body_slices_probe.ml` 을 붙여 링크한 시험 실행 파일. main `9d67e41d1c4f` 의 cmi 스냅숏에 #50765 의 바뀐 단위를 다시 컴파일했다. OCaml 5.5.2 switch |
| 서버 | 그 프로세스 안에서 `Server_bootstrap_http.serve_h2_connection` 을 TCP loopback 리스너에 붙였다. 평문 HTTP/2, 양쪽 `TCP_NODELAY` |
| 클라이언트 | 탐침에 든 손으로 쓴 HTTP/2 클라이언트. 다른 domain 에서 돈다. 창을 언제 돌려줄지 장면마다 정한다 |
| 비교한 셋 | `one`: 조각 하나만 h2 에 두는 큐(커밋 `cb6ab3d79b4b` 의 트리, `a30bc89c29aa` 의 큐와 같다). `two`: 조각 둘까지 두는 큐. `whole`: `cb6ab3d79b4b` 트리에서 `write_slice` 가 payload 전체를 한 번에 넣게 바꾼 것. main 의 통째 쓰기와 같다 |
| 끝난 시각(UTC) | limited3 04:08:20, open3 04:11:05, frame3 04:13:26 |
| 호스트 | macOS, M3 Max 한 대. 다른 세션의 빌드가 같이 돌았다. limited3 은 이 세션의 빌드도 같이 돌았다 |

결과는 `run7-body-slices.txt` 다. 장면은 `MiB:스트림 창:연결 창:창 반환 정책:busy_us:회차` 다.

- 창 반환 정책 `frame` 은 DATA 프레임마다 돌려준다. ocaml-h2 의 client 가 이렇게 한다(client_connection.ml 306~322줄). `go` 는 x/net/http2 의 `inflow.add` 규칙이다. `half` 는 받은 양이 창의 반 이상이면 돌려준다. nghttp2 의 규칙이다(nghttp2_helper.c `nghttp2_should_send_window_update`). Chromium 은 반을 넘거나 정해 둔 시간이 지나면 돌려준다(net/spdy/spdy_stream.cc `IncreaseRecvWindowSize`). 탐침은 그 시간 조건을 흉내 내지 않는다. 두 소스는 2026-11-10 에 각 저장소의 기본 브랜치에서 읽었다.
- `busy_us` 는 서버 domain 의 다른 fiber 가 스케줄러 턴마다 쓰는 CPU 시간이다.

읽은 것:

- 8 MiB, 창 65,535 B, `frame`: `one` 은 프레임 33,152개(1 KiB 미만 32,640개)에 중앙값 11.0~13.5초, `two` 는 513개에 0.09~0.34초, `whole` 은 513개에 0.09~0.20초다.
- 같은 창, `go`: `one` 1,021개, `two`·`whole` 513개. 시간은 셋이 흔들림 안에서 같다.
- 같은 창, `half`: `one`·`two` 767개, `whole` 513개.
- 32 MiB, 스트림 창 6 MiB·연결 창 15 MiB, `half`: `one` 133~152 ms, `two` 39~62 ms, `whole` 24~78 ms.
- 8 MiB, 같은 창, 턴마다 1 ms 를 쓰는 fiber 가 있을 때: `one` 551~562 ms, `two` 281~320 ms, `whole` 27~33 ms.

한계:

- 시간은 같은 장면도 회차마다 2~3배 흔들렸다. 프레임 수는 매번 같았다.
- TLS 와 cloudflared 를 거친 값은 재지 않았다. 실제 서버의 스케줄러 턴 시간도 재지 않았다.
- 스트림 하나만 보냈다. 한 연결에 본문 여럿이 같이 나갈 때는 재지 않았다.

다시 돌리려면 탐침을 `test/test_h2_request_fibers.ml` 의 마지막 `let () = run ...` 앞에 붙이고, 그 목록에 `"throughput probe", tp_cases` 를 더해 빌드한다. `TP_SCENES`, `TP_LABEL`, `TP_OUT` 환경 변수로 장면, 줄 머리, 출력 파일을 준다.

```bash
TP_SCENES="8:65535:65535:frame:0:3" TP_LABEL=two ./test_h2_request_fibers.exe test "throughput probe"
```

## run8·run9: RFC-0518 층이 들어간 설치 build 로 다시 돌린 결과, 2026-11-11

설치된 바이너리를 run1·run6 과 같은 방식으로 격리해 띄웠다. 두 탐침 사이에 설치 바이너리가 바뀌어 build 가 다르다. 두 build 모두 #50765(D2·D3), #51049(D9), #51108, #51038, #51109(D7), #51218 을 담고 있고, #51208·#51209·#51228(D4·D6·D8)과 #51223(D5)은 담고 있지 않다. 원장 고갈과 TLS CPU 는 그 층이 설치된 뒤 run10~run12 로 쟀다.

### run8: 창 0 스트림은 90 s 에 끊긴다

| 항목 | run6 (`57b928783c0b`) | run8 (`eb22878fa756`) |
| --- | --- | --- |
| 105 s 안에 서버가 보낸 RST_STREAM | 0개 | 3개 (스트림 1·3·5) |
| RST 를 받은 시각 (스트림을 연 뒤) | 없음 | 90.0 s, 90.0 s, 90.0 s |
| 멈춘 동안 받은 DATA | 0 B | 0 B |
| 창을 연 뒤 | 스트림마다 36,839 B 와 END_STREAM | 이미 끊겨 받은 것 없음 |
| 서버 로그 | 정체 판정 3줄(`accepted no frame`) | reset 3줄(`resetting the stream`), 옛 문구 0줄 |

run8b 는 같은 장면을 build `c9b8e1af3cbe` 에서 돌린 것이고 값이 같다: RST 3개, 셋 다 90.0 s, reset 로그 3줄. 그보다 앞서 build `1c5524344b0f` 에서도 한 번 돌려 RST 3개를 받았는데, 그때의 탐침은 시각을 적지 않아 결과 파일을 남기지 않았다.

### run9: 스트림 reset 뒤 서버 카운터는 warm 값으로 돌아온다

| 표본 | run1 live MB | run9 live MB | run9 descriptor | run9 `sse_clients` |
| --- | --- | --- | --- | --- |
| warm-repeat | 164.4 | 132.9 | 55 | 0 |
| fleet 스트림 4,500개 reset 뒤 | 132.1 | 110.5 | 55 | 0 |
| 로그 스트림 4,500개 reset 직후 | 292.2 | 209.8 | 55 | 0 |
| 그 35 s 뒤 | 329.9 | 203.4 | 55 | 0 |
| MCP GET 300번 뒤 | 352.7 | 279.4 | 55 | 0 |
| h2c fleet 스트림 2,250개 reset 뒤 | 290.1 | 175.3 | 55 | 0 |
| TLS 연결 200개 절단 뒤 | 170.6 | 192.8 | 55 | 0 |
| 평문 200번 뒤 | 306.2 | 286.2 | 55 | 0 |
| final | 355.0 | 207.1 | 54 | 0 |

- descriptor, TCP descriptor, 리스너 활성 연결, `sse_clients` 는 run1 과 같이 모든 표본에서 warm 값이었다.
- 요청은 모두 200 이었다(fleet 4,500, 로그 4,500, MCP GET 300, h2c 2,250, 절단 연결의 스트림 1,000, 끝의 GET 300). `h1_fleet_close` 는 run1 과 같이 200 이 0개다.
- 로그 스트림을 reset 한 뒤 35 s 동안 live 는 run1 에서 37.7 MB 늘었고 run9 에서 6.4 MB 줄었다. 둘 다 아래에 적은 65 MB 흔들림 안이라 이 값으로 D7 을 판정하지 않는다.
- 평문 200번은 1,005 s 걸렸다(run1 1,004 s). 연결 준비 상한(D6)은 이 build 에 없다.

## run10~run12: D4·D5·D6·D8 이 든 설치 build 로 다시 돌린 결과, 2026-11-11

설치 build `c9b8e1af3cbe` 는 #51208·#51209·#51228·#51223 을 모두 담고 있다. dashboard asset 은 같은 날 17:49 에 빌드된 묶음의 사본을 썼다(번들 866,369 B, run4·run5 때는 861,256 B).

### run10: 번들을 쥔 느린 클라이언트가 다른 연결을 막지 않는다

| 항목 | run5 (`57b928783c0b`) | run10 (`c9b8e1af3cbe`) |
| --- | --- | --- |
| 느린 클라이언트의 번들 스트림 90개 | 200 이 77개, 503 이 13개 | 200 이 90개 |
| 그동안 다른 연결의 번들 3번 | 503 이 3개 | 200 이 3개 |
| 5 s 뒤 다른 연결의 번들 3번 | 503 이 3개 | 200 이 3개 |
| 그동안 `/health` | 200 | 200 |
| 느린 클라이언트가 떠난 뒤 번들 3번 | 200 이 3개 | 200 이 3개 |

### run11·run12: 한 쌍에서 TLS 서버 CPU 는 연결 하나에서 49~62% 낮았다

run11 을 끝내고 27 s 뒤에 run12 를 끝냈다. 값은 서버 CPU ms/MB 의 3회 중앙값이다.

| 장면 | run4 (`57b928783c0b`) | run11 (D8 없음) | run12 (D8 있음) | run11 → run12 |
| --- | --- | --- | --- | --- |
| 평문, 연결 1개 | 2.50 | 2.48 | 2.49 | +0.4% |
| AES-128-GCM, 연결 1개 | 11.49 | 12.00 | 4.59 | −61.7% |
| AES-256-GCM, 연결 1개 | 11.79 | 12.01 | 6.12 | −49.0% |
| ChaCha20-Poly1305, 연결 1개 | 9.66 | 8.74 | 3.45 | −60.5% |
| 평문, 연결 4개 | 1.54 | 2.63 | 1.82 | −30.8% |
| AES-128-GCM, 연결 4개 | 8.65 | 9.11 | 6.27 | −31.2% |
| AES-256-GCM, 연결 4개 | 10.04 | 10.17 | 7.94 | −21.9% |
| ChaCha20-Poly1305, 연결 4개 | 7.52 | 6.88 | 5.03 | −26.9% |

- 연결 하나의 TLS 처리량은 49.6~66.4 MB/s 에서 153.7~274.5 MB/s 가 됐다. 처리량은 부하에 따라 크게 흔들리므로 판정은 CPU 로 한다.
- 평문 연결 4개는 run11 과 run12 사이에 30.8% 움직였다. 두 build 의 평문 경로에서 달라진 것은 D4 의 소켓 감싸개와 D5 의 공유 본문인데 연결 하나에서는 차이가 없으므로, 이 줄은 흔들림으로 읽는다. 연결 4개의 TLS 줄에도 같은 크기의 흔들림이 섞였을 수 있다.
- run12 를 재기 6분 전에 같은 설치 build 로 한 번 더 쟀다. 실행 직후 load average 가 245 였고 평문 연결 하나가 4.55 ms/MB, AES-128-GCM 연결 하나가 6.05 ms/MB 였다. run11·run12 때는 68~77 이었다. 그 실행은 파일로 남기지 않았다.
- 이 한 쌍의 폭은 크게 읽힌 값이다. run13 에서 run11 의 실행 파일을 일곱 번 다시 돌리니 AES-128-GCM 연결 하나가 6.69~7.47 ms/MB 였다(run11 은 12.00). 같은 실행 파일이 왜 다르게 읽혔는지는 확인하지 못했다. 줄어든 폭은 run13 의 값으로 읽는다.
- run11 의 build 는 main 의 커밋이 아니다. main `b88dd6902027` 위에 문서 커밋 둘을 얹은 다른 branch 의 작업 트리에서 14:48 에 빌드된 실행 파일의 사본이다. 그 커밋은 D2·D3·D9 를 담고 있고 D4·D5·D7·D8 을 담고 있지 않다. 빌드할 때 작업 트리에 커밋되지 않은 변경이 있었는지는 확인하지 못했다.

## 벤치 run4: tls-eio 가 암호문을 소켓에 바로 쓸 때의 서버 CPU, 2026-11-11

서버 CPU(ms/MB, 5회 중앙값). `릴리스` 는 tls-eio 2.1.5 를 accept 한 소켓에 그대로 얹은 것, `감싸개` 는 같은 라이브러리에 `copy:262144` 소켓, `포크` 는 고친 tls-eio 를 accept 한 소켓에 얹은 것이다.

| 쓰기 크기(B) | suite | 클라이언트 | 릴리스 | 감싸개 | 포크 | 포크 대 릴리스 | 포크 대 감싸개 |
|---|---|---|---|---|---|---|---|
| 861,256 | AES-128-GCM | OpenSSL | 10.58 | 5.10 | 5.28 | −50.1% | +3.5% |
| 861,256 | AES-128-GCM | Go | 9.69 | 5.13 | 5.31 | −45.2% | +3.5% |
| 861,256 | ChaCha20 | OpenSSL | 8.01 | 3.96 | 4.14 | −48.3% | +4.5% |
| 861,256 | ChaCha20 | Go | 7.94 | 4.22 | 4.15 | −47.7% | −1.7% |
| 32,786 | AES-128-GCM | OpenSSL | 12.67 | 7.59 | 8.19 | −35.4% | +7.9% |
| 32,786 | AES-128-GCM | Go | 12.75 | 7.59 | 7.29 | −42.8% | −4.0% |
| 32,786 | ChaCha20 | OpenSSL | 10.93 | 5.26 | 6.01 | −45.0% | +14.3% |
| 32,786 | ChaCha20 | Go | 8.32 | 6.23 | 5.65 | −32.1% | −9.3% |
| 16,393 | AES-128-GCM | OpenSSL | 11.76 | 6.73 | 6.93 | −41.1% | +3.0% |
| 16,393 | AES-128-GCM | Go | 12.39 | 7.12 | 6.47 | −47.8% | −9.1% |
| 16,393 | ChaCha20 | OpenSSL | 8.66 | 5.41 | 5.61 | −35.2% | +3.7% |
| 16,393 | ChaCha20 | Go | 10.38 | 5.40 | 4.91 | −52.7% | −9.1% |

- 포크는 릴리스보다 32.1~52.7% 적게 썼다. 감싸개와는 −9.3~+14.3% 로 엇갈린다. 한 번 돈 값이라 둘 사이의 차이는 말할 수 없다.
- 포크 쪽 소켓은 masc 의 연결 감싸개가 아니라 accept 한 소켓이다. masc 에서는 감싸개가 받은 쓰기를 256 KiB 조각으로 넘긴다. 포크를 넣은 masc 설치 build 는 run13 에서 쟀다.
- 처리량(MB/s)은 장비 부하에 따라 출렁여서 쓰지 않는다.

## run13: tls-eio 포크가 든 설치 build 의 TLS 서버 CPU, 2026-11-11

설치 build `e0f124c927a5` 는 #51374 를 담고 있다. tls-eio 가 암호문을 소켓에 바로 쓰고, 연결 감싸개는 복사 버퍼를 쥐지 않는다. 견준 쪽은 run11 의 실행 파일(`379d483de91a`, D4·D5·D7·D8 없음)이다. 감싸개가 256 KiB 버퍼로 모아 쓰던 build `c9b8e1af3cbe` 의 실행 파일은 남아 있지 않아서 그 build 와는 견주지 못했다.

두 실행 파일을 한 번씩 잇달아 돌리는 것을 다섯 번 했고 순서를 번갈았다. 값은 서버 CPU ms/MB 이고, 괄호는 다섯 번의 최소~최대다. `낮은 쌍` 은 같은 회차에서 새 build 가 더 낮게 나온 횟수다.

| 장면 | 스택 전 (`379d483de91a`) | 포크 (`e0f124c927a5`) | 중앙값 차이 | 낮은 쌍 | run12 (`c9b8e1af3cbe`) |
| --- | --- | --- | --- | --- | --- |
| 평문, 연결 1개 | 1.92 (1.91~2.49) | 2.49 (2.30~2.67) | +29.7% | 0/5 | 2.49 |
| AES-128-GCM, 연결 1개 | 6.88 (6.69~7.47) | 4.98 (4.41~6.30) | −27.6% | 5/5 | 4.59 |
| AES-256-GCM, 연결 1개 | 8.41 (7.07~8.98) | 5.56 (5.18~6.87) | −33.9% | 5/5 | 6.12 |
| ChaCha20-Poly1305, 연결 1개 | 5.93 (5.15~7.42) | 3.45 (3.26~4.20) | −41.8% | 5/5 | 3.45 |
| 평문, 연결 4개 | 2.16 (2.06~2.40) | 1.97 (1.58~2.44) | −8.8% | 3/5 | 1.82 |
| AES-128-GCM, 연결 4개 | 6.32 (6.18~7.66) | 5.23 (4.75~5.75) | −17.2% | 5/5 | 6.27 |
| AES-256-GCM, 연결 4개 | 6.94 (6.65~8.48) | 5.80 (5.66~6.99) | −16.4% | 5/5 | 7.94 |
| ChaCha20-Poly1305, 연결 4개 | 6.21 (5.41~7.80) | 4.17 (3.45~4.84) | −32.9% | 5/5 | 5.03 |

연결마다 요청을 300개로 늘려 두 번 더 돌렸다(`--n 300`, 순서는 스택 전·포크, 포크·스택 전). `ps` 의 CPU 시간은 0.01 s 단위라 요청 60개의 평문 줄은 한 칸이 0.19 ms/MB 다.

| 장면 | 스택 전 | 포크 | 차이 |
| --- | --- | --- | --- |
| 평문, 연결 1개 | 1.92, 1.77 | 2.73, 2.46 | +42.2%, +39.0% |
| AES-128-GCM, 연결 1개 | 7.35, 6.81 | 4.34, 4.41 | −41.0%, −35.2% |
| AES-256-GCM, 연결 1개 | 6.81, 7.27 | 4.99, 4.98 | −26.7%, −31.5% |
| ChaCha20-Poly1305, 연결 1개 | 5.21, 5.28 | 3.18, 3.07 | −39.0%, −41.9% |
| 평문, 연결 4개 | 1.91, 1.75 | 1.57, 1.56 | −17.8%, −10.9% |
| AES-128-GCM, 연결 4개 | 5.95, 5.86 | 4.62, 4.48 | −22.4%, −23.5% |
| AES-256-GCM, 연결 4개 | 6.60, 6.42 | 5.46, 5.47 | −17.3%, −14.8% |
| ChaCha20-Poly1305, 연결 4개 | 4.58, 4.63 | 3.34, 3.61 | −27.1%, −22.0% |

- TLS 여섯 줄은 일곱 쌍 모두에서 포크 build 가 낮았다. 연결 하나는 중앙값으로 27.6~41.8%, 연결 넷은 16.4~32.9% 낮다.
- 평문 연결 하나는 포크 build 가 일곱 쌍 중 다섯에서 높고 둘에서 같았다. 요청 300개에서는 1.77~1.92 가 2.46~2.73 이 됐다(+39.0~42.2%). 평문 연결 넷은 요청 300개에서 10.9~17.8% 낮았다. 두 build 사이에는 D4 의 소켓 감싸개, D5 의 공유 본문, 그 뒤 main 에 들어간 다른 변경이 다 있다. 어느 것 때문인지는 가리지 않았다(#51400).
- run12 열은 다른 날 다른 부하에서 잰 한 번이다. 포크 build 의 값과 가깝지만 두 build 를 견준 것이 아니다.
- 다섯 번 도는 동안 load average 는 75~142 였고, 요청 300개 때는 64~120 이었다(결과 파일의 `load_log`).

## run14: #51545 가 든 설치 build 의 서버 CPU, 2026-11-12

설치 build 는 #51545 를 담고 있다. manifest 없이 뜬 서버(탐침의 `MASC_ASSETS_DIR` 실행)는 대시보드 asset 파일이 그대로면 본문을 다시 읽지 않고, asset 표는 본문을 견주지 않는다. 견준 쪽은 run11·run13 의 실행 파일(`379d483de91a`)이다. 탐침은 #51515 의 판이고, 결과의 `cpu_clock_step_s` 는 열 번 모두 0.01 이다.

재는 동안 설치 바이너리가 바뀌었다. 1·2회차는 `fa36c50f263f`, 3~5회차는 `31b43e9ebafa` 다. 둘 다 #51545 를 담고 있다. 두 build 사이의 커밋 13개가 바꾼 `lib/` 파일은 Keeper, librarian, verifier, lane addon, 계정 로그인, TUI decode 쪽 스무 개다. asset 읽기, 응답 쓰기, 연결 감싸개 파일은 그 안에 없다.

두 실행 파일을 한 번씩 잇달아 돌리는 것을 다섯 번 했고 순서를 번갈았다(`--n 300`). 값은 서버 CPU ms/MB 이고, 괄호는 다섯 번의 최소~최대다. `낮은 쌍` 은 같은 회차에서 설치 build 가 더 낮게 나온 횟수다.

| 장면 | 스택 전 (`379d483de91a`) | 설치 build | 중앙값 차이 | 낮은 쌍 | 회차별 차이(%) |
| --- | --- | --- | --- | --- | --- |
| 평문, 연결 1개 | 2.38 (1.92~3.05) | 3.25 (3.02~3.87) | +36.6% | 0/5 | +8, +22, +70, +27, +58 |
| AES-128-GCM, 연결 1개 | 9.83 (6.44~12.75) | 6.20 (5.54~7.36) | −36.9% | 5/5 | −43, −51, −25, −35, −14 |
| AES-256-GCM, 연결 1개 | 10.79 (7.74~13.64) | 7.37 (6.80~8.33) | −31.7% | 5/5 | −30, −45, −34, −31, −5 |
| ChaCha20-Poly1305, 연결 1개 | 8.44 (6.42~10.75) | 4.71 (4.50~5.36) | −44.2% | 5/5 | −40, −56, −40, −30, −39 |
| 평문, 연결 4개 | 2.31 (1.99~2.36) | 2.54 (2.16~3.11) | +10.0% | 1/5 | +9, +10, +48, +13, −7 |
| AES-128-GCM, 연결 4개 | 8.87 (7.26~9.33) | 6.17 (5.86~6.27) | −30.4% | 5/5 | −33, −30, −24, −16, −34 |
| AES-256-GCM, 연결 4개 | 9.78 (8.45~11.11) | 7.50 (7.19~7.72) | −23.3% | 5/5 | −30, −31, −14, −26, −15 |
| ChaCha20-Poly1305, 연결 4개 | 6.60 (5.14~8.42) | 4.68 (4.47~5.17) | −29.1% | 5/5 | −41, −39, −28, −13, −17 |

run14 를 재기 전에 `fa36c50f263f` 로 같은 장면(평문 연결 하나)의 macOS `sample` 프로파일을 10초씩 세 번 떴다. 견준 쪽은 #51545 가 없는 설치 build `e0f124c927a5` 의 프로파일 셋이다.

| 센 것 | `e0f124c927a5` | `fa36c50f263f` |
| --- | --- | --- |
| `dashboard_asset_of` 아래 `caml_string_equal` 샘플 | 94, 114, 83 | 0, 0, 0 |
| `read_exact_file_descriptor` 가 든 줄 | 15, 17, 16 | 0, 0, 0 |
| `read` 에서 멈춘 샘플 | 158, 84, 129 | 3, 4, 1 |

- 평문 연결 하나는 다섯 쌍 모두 설치 build 가 높았다. run13 의 요청 300개 두 쌍(+39.0%, +42.2%)과 같은 방향이다. #51545 가 든 build 에서도 차이가 남아 있다(#51400).
- 프로파일에서 본문 비교와 asset 읽기는 보이지 않는다(세 번 모두 0). 이 다섯 쌍에서 CPU 차이는 남아 있다.
- 그 둘이 차이에서 차지하던 몫은 이 측정으로 알 수 없다. run13 의 설치 build 와 run14 의 설치 build 사이에도 다른 변경이 있어서, 줄어든 몫을 다른 변경이 가렸을 수 있다.
- RFC #51531 §1.3 의 가설은 요청마다 하는 866 KB 할당이 GC 일감을 키운다는 것이다. 이 가설은 판정하지 못했다. GC 일감(`Runtime_events`)을 재지 않았고, 같은 커밋에서 그 할당만 다른 실행 파일끼리 견주지도 않았다.
- TLS 여섯 줄은 다섯 쌍 모두 설치 build 가 낮았다. 연결 하나는 중앙값으로 31.7~44.2%, 연결 넷은 23.3~30.4% 낮다.
- 평문 연결 넷은 다섯 쌍 중 넷에서 설치 build 가 높았다. run13 의 요청 300개 두 쌍에서는 낮았다(−17.8%, −10.9%). 어느 쪽이 맞는지 가리지 못했다.
- load average 는 101~393 이었다(결과 파일의 `load_log`, run13 은 64~142). 스택 전 실행 파일의 평문 연결 하나가 1.92~3.05 로 흩어졌다(run13 의 요청 300개에서는 1.77, 1.92). 그래서 이 표의 값을 run13 의 값과 견주지 않고, 같은 회차 안의 차이만 읽는다.
- 프로파일을 뜰 때 load average 는 319~336 이었다. `sample` 은 CPU 를 받지 못하고 밀려난 스레드도 세므로 샘플 수를 CPU 시간으로 읽지 않는다. 위 표는 그 함수가 있는지 없는지만 보여 준다. 프로파일은 호스트 경로가 들어 있어 남기지 않았다. 그래서 표의 샘플 수는 다시 계산할 수 없다.
- run14 결과 파일은 서버 CPU 시간만 담는다. 파일이 그대로일 때 본문을 다시 읽지 않는다는 것은 이 파일로 확인할 수 없다. 근거는 위 프로파일 표와 #51545 의 시험이다. 읽기 횟수를 세는 값은 서버에 없다.
- 설치 build 의 idle CPU 는 0.007~0.024 s/s, 스택 전 실행 파일은 0.003~0.006 s/s 다. 탐침은 이 값을 빼고 계산한다.
- 두 실행 파일 사이에는 RFC-0518 스택 말고도 하루 동안 main 에 들어간 다른 변경이 있다. 이 비교로는 차이가 어느 변경 것인지 가리지 못한다. 가리려면 같은 커밋에서 한 곳만 바꾼 실행 파일끼리 견줘야 한다(#51400).

## 관찰과 한계

- run1 의 descriptor, TCP descriptor, 리스너 활성 연결, `sse_clients` 는 모든 표본에서 warm 값이었다. 오래 연 연결을 닫은 뒤 cold 값이 됐다.
- run1 의 `live_mb`·`rss_mb` 는 누수 판정에 쓰지 않는다. 부하 없이 잇달아 읽어도 65 MB 흔들렸고, 쉬는 동안 줄지 않았다.
- run1 의 HTTP/1.1 대조(`h1_fleet_close`)는 200 을 하나도 받지 못했다. 탐침의 요청 모양 탓이다. run2 가 HTTP/1.1 대조를 대신한다.
- run1 의 handshake 실패 200번은 1,004 s 걸렸다. 연결마다 탐침의 `recv` 가 5 s 기한을 다 썼다.
- run5 의 느린 클라이언트는 데이터를 확인하지 않는다. 기본 창 65,535 B 만큼만 받는다.
- run8·run8b·run9·run10 은 각각 한 번 실행이다. run11·run12 는 탐침 한 번(줄마다 3회)씩이다. run13 은 build 마다 탐침 일곱 번, run14 는 build 마다 탐침 다섯 번이다.
- run6 은 스트림 3개, 한 번 실행이다. 정체 로그 줄 수는 서버 로그에서 셌고 로그 원문은 남기지 않았다.
- 처리량은 표본마다 2배까지 흔들렸다. 서버 CPU(ms/MB)는 안정적이었다.
- 벤치 클라이언트는 harness 를 돌린 Python 이다. 판 문자열은 결과에 남기지 않았다.
- cloudflared 가 쓰는 Go `crypto/tls` 클라이언트로는 재지 않았다.
