# 읽기 요청이 공유 풀에서 기다린 기록 (2026-10-27)

[RFC-0204](../../rfc/RFC-0204-dashboard-serving-isolation.md) 의 측정 근거다.
대화 본문, 체크포인트 본문, 토큰은 넣지 않았다. 요청 경로, 시간, 건수, 코드 경로만 있다.

## 대상 서버

| 구간 | PID | 바이너리 커밋 | 비고 |
|---|---|---|---|
| 수정 전 | 45284 | `9377c7f3025d68e3856d2afd3762468dabc77813` | 2026-10-27 02:28:22 KST 기동. Librarian 수정 #46242~#46244 없음 |
| 수정 후 | 8821 | `d0c79a5d83a51b3e4b30b67cb05342f10e20e2ea` | 2026-10-27 11:01:45 KST 기동. #46244 포함. 다른 세션이 배포했다 |

- 바이너리 커밋은 `GET /health` 의 `build.binary_commit` 이다.
- Keeper 42명. 장비는 16코어(`sysctl -n hw.ncpu`). 같은 시간에 다른 코딩 세션 6개와 Keeper microVM 이 돌았다.

## 파일

| 파일 | 내용 | 창 |
|---|---|---|
| `probe-after-fix-d0c79a5.json` | 수정 후 서버에서 `scripts/harness/perf/response_latency_probe.py` 원문 결과. 목표 경로 네 개와 `/health`, 경로마다 200번, 2초 간격, 30초 제한 | 11:06:54~11:20:08 KST |
| `sample-after-fix-thread-kinds.txt` | 수정 후 서버 `sample 8821 6` 을 스레드 종류별로 나눈 것. main 스레드의 runtime lock 대기와 systhread 의 masc 모듈 | 11:2x KST, 6초 |
| `probe-pooled-vs-main-domain.tsv` | 수정 전 서버에서 `gate/keepers?detailed=false&limit=1`(풀 경유)과 `/health`(main domain)를 번갈아 20번 부른 curl 결과 | 01:29:05~01:29:08 UTC |
| `tui-slow-requests-by-path.tsv` | TUI 가 1초 넘게 걸렸다고 적은 요청을 경로별로 센 것 | `masc-tui-59258.log` 02:29~10:59 KST (수정 전 서버의 수명) |
| `gate-keepers-by-hour.tsv` | 위 TUI 기록 중 `gate/keepers` 의 시간대별 값 | 같은 창 |
| `sample-top-of-stack.txt` | 수정 전 서버 `sample 45284 8` 의 leaf 상위 | 08:4x KST, 8초 |
| `sample-masc-modules.txt` | 같은 sample 의 `camlMasc__*` 프레임을 모듈별로 센 것 | 같은 sample |
| `sample-thread-kinds.txt` | 같은 sample 을 스레드 종류(main, domain, systhread)별로 나눠 JSON 파싱과 sha256 샘플을 센 것 | 같은 sample |
| `memprof-allocated-by-module.txt` | 수정 전 서버 `GET /api/v1/diagnostics/memprof` 의 `allocated` 표를 masc 모듈별로 묶은 것 | 직전 읽기 이후 누적. 시작 시각은 응답에 없다 |

## 읽을 때 주의할 점

- **TUI 기록은 서버 지연이 아니다.** `bin/masc_tui_http.ml` 첫 주석대로 TUI 의 elapsed 는 "서버 응답 + TUI 그리기 루프가 다음에 돌 때까지의 대기"다. 클라이언트 timeout 이 10초인데 45,564 ms 로 기록된 요청이 있다. 그러니 TUI 표는 사용자가 겪은 지연으로만 읽는다. 서버 지연은 `probe-*` 파일로 본다.
- TUI 는 1초 미만 요청을 기록하지 않는다. TUI 표의 평균은 1초 넘은 요청끼리의 평균이다.
- `memprof` 표에서 Librarian 호출자가 확인된 할당은 55.6%다. `lane_addon_store`(35.3%)는 같은 tool-request 저장소 읽기지만 스택이 잘려 호출자를 확인하지 못했다.
- 풀 대기 시간을 직접 잰 값은 없다. 서버에 그 계측이 없다.
- domain 수는 `sample-thread-kinds.txt` 에서 `domain_thread_func` 를 가진 스레드 30개다. main 을 더하면 31개다. 부팅 로그(`Native execution runtime created (14 codec domains)`, `Domain_pool created (14 shared domains, 1 independent snapshot codec domain)`)로 설명되는 것은 29개다.
