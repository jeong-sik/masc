# 읽기 요청이 공유 풀에서 기다린 기록 (2026-10-27)

[RFC-0204](../../rfc/RFC-0204-dashboard-serving-isolation.md) 의 측정 근거다.
대화 본문, 체크포인트 본문, 토큰은 넣지 않았다. 요청 경로, 시간, 건수, 코드 경로만 있다.

## 대상

- 서버: `masc start --base-path ~/me`, PID 45284, 2026-10-27 02:28 KST 기동.
- 바이너리 커밋 `9377c7f3025d68e3856d2afd3762468dabc77813` (`GET /health` 의 `build.binary_commit`).
  Librarian 수정 스택 #46242~#46244 는 이 바이너리에 없다.
- Keeper 42명 (`GET /api/v1/gate/keepers` 의 `total`).
- 장비: 16코어(`sysctl -n hw.ncpu`). 같은 시간에 다른 코딩 세션 6개와 Keeper microVM 이 돌고 있었다.

## 파일

| 파일 | 내용 | 집계 창 |
|---|---|---|
| `tui-slow-requests-by-path.tsv` | TUI 가 1초 넘게 걸린 요청을 경로별로 센 것. TUI 는 1초 넘는 요청만 로그에 남긴다 | `masc-tui-59258.log` 01:34:45 ~ 10:29:04 KST |
| `gate-keepers-by-hour.tsv` | `GET /api/v1/gate/keepers` 의 시간대별 평균·최대·10초 timeout | 같은 창 |
| `probe-pooled-vs-main-domain.tsv` | 같은 순간에 `gate/keepers?detailed=false&limit=1`(풀 경유)과 `/health`(main domain) 을 번갈아 20번 부른 결과 | 01:29:05 ~ 01:29:08 UTC |
| `sample-top-of-stack.txt` | `sample 45284 8` 의 leaf 상위 | 08:4x KST, 8초 |
| `sample-masc-modules.txt` | 같은 sample 에서 `camlMasc__*` 프레임을 모듈별로 센 것 | 같은 sample |
| `memprof-allocated-by-module.txt` | `GET /api/v1/diagnostics/memprof` 의 `allocated` 표를 masc 모듈별로 묶은 것 | 직전 읽기 이후 누적. 시작 시각은 응답에 없다 |

## 만든 방법

- TUI 로그: `took (\d+) ms elapsed` 가 붙은 `[Transport] http GET|POST` 줄을 경로별로 셌다. 10,000 ms 이상을 timeout 으로 셌다(TUI 의 `Pool.request: timeout after 10.0s`).
- 탐침: `curl -s -o /dev/null -m 30 -w '%{time_total}'`. `/health` 는 응답 헤더 `server-timing` 의 `health_response` 도 적었다.
- 이 표보다 앞서(09시 전후 KST, 정확한 시각은 남기지 않았다) 같은 탐침을 8번 돌렸을 때 풀 경유 요청은 0.49~5.2초, `/health` 는 1.5~11 ms 였다. 이 표에는 10:29 KST 의 20번만 있다. 그때는 풀 경유 요청도 4~527 ms 였다. 지연은 계속되지 않고 몰려서 나타난다.
- domain 수: 같은 sample 에서 `domain_thread_func` 프레임을 가진 스레드가 30개였다. main domain 을 더하면 31개다.

## 한계

- 풀 대기 시간을 직접 잰 값이 아니다. 서버에 그 계측이 없다. "풀 경유 요청은 느리고 main domain 요청은 빠르다"는 대조만 있다.
- memprof 할당 표는 표본(rate 1e-5)에서 추정한 값이다. 비율로만 읽는다.
- TUI 로그는 1초 미만 요청을 남기지 않아서 p50·p99 를 구할 수 없다.
