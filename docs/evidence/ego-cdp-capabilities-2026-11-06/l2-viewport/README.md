# L2 화면 크기 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L2 의 확인이다.
ego 연결의 set_viewport 가 기대는 CDP 동작 세 가지를 쟀다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 실행마다 시험 전용 task space 를 만들고 끝에 `finish({keep: []})` 로 닫았다(space 23, 24, 25).
- 페이지는 [`../probe-page.html`](../probe-page.html) 를 `index.html` 로 두고 `python3 -m http.server 18768 --bind 127.0.0.1` 로 띄웠다. 자연 크기는 1548×990 이다.

## 명령

```sh
ego-browser nodejs < probe-viewport.mjs 2> result-viewport.json
ego-browser nodejs < probe-race.mjs 2> result-race.json
ego-browser nodejs < probe-settle.mjs 2> result-settle.json
```

시작 시각은 `viewport-started-at.txt`(04:20:02Z), `race-started-at.txt`(04:20:24Z), `settle-started-at.txt`(04:25:31Z) 에 있다.
ego 의 `console.log` 는 stderr 로 나온다. 결과 파일은 원본에서 끝의 빈 줄 하나만 지웠다(591→590, 1644→1643, 250→249 바이트).

## 결과

### 1. 설정은 한 프로세스 안에서 남는다 (`probe-viewport.mjs`)

masc 의 ego session 처럼 한 Node 프로세스에서 명령마다 `taskSpace(id)` 를 다시 열었다.

| 시점 | 크기 |
|---|---|
| 설정 전 | 1548×990 |
| `setDeviceMetricsOverride` 800×600 직후 | 800×600 |
| task space 를 다시 연 뒤 | 800×600 |
| 2초 뒤 다시 연 뒤 | 800×600 |
| 다른 주소로 이동한 뒤 | 800×600 |
| 새로고침한 뒤 | 800×600 |
| `clearDeviceMetricsOverride` 직후 | 1548×990 |
| 100×100, 4096×4096 | 그대로 받음 |
| 마지막 해제 직후 | 4096×4096 |

마지막 줄이 2번 시험의 이유다. 같은 스크립트의 앞선 실행(04:05:35Z, space 22)은 이 줄이 1548×990 이었다.

### 2. 해제 직후 읽기는 옛 크기를 볼 수 있다 (`probe-race.mjs`)

다섯 크기를 20번 돌며 설정과 해제를 각각 100번 했다.

| 동작 | 바로 읽기가 틀림 | 두 animation frame 뒤에도 틀림 |
|---|---|---|
| 설정 | 0 / 100 | 0 / 100 |
| 해제 | 13 / 100 | 2 / 100 |

### 3. 해제 뒤 크기가 바뀌기까지 (`probe-settle.mjs`)

해제한 뒤 10 ms 마다 크기를 읽어, 덮어쓴 크기에서 바뀔 때까지 걸린 시간을 쟀다.

- 100번 모두 바뀌었고, 바뀐 크기는 모두 1548×990 이었다.
- p50 0 ms, p90 63 ms, 최대 1,074 ms.
- 덮어쓴 크기가 없을 때 해제하면 1초 동안 바뀌지 않았다.

1,074 ms 는 배경 탭의 타이머가 1초 단위로 묶인 값일 수 있다. 이 시험으로는 가리지 못한다.

## masc 에 옮긴 것

- 설정 receipt 는 명령이 끝난 직후 읽는다(1번·2번의 설정 줄).
- 해제는 해제 전 크기를 읽고, 크기가 바뀌거나 2초가 지날 때까지 기다린 뒤 receipt 를 읽는다(`lib/browser_ego_peer.ml` 의 `viewport_restore_wait_ms`). 덮어쓴 크기가 없었으면 2초를 다 기다린다.
- 설정은 SDK 프로세스와 같이 산다. 답의 `sdkProcessStartedAt` 이 그 프로세스를 가리킨다.

## 이 시험이 보여 주지 않는 것

- masc 서버의 `page.viewport` 단계 스크립트를 그대로 돌리지 않았다. 그 스크립트는 `test/test_browser_ego_peer.ml` 의 가짜 runner 시험과 `node --check` 시험이 맡는다.
- 운영자가 보는 창에서 페이지가 어떻게 그려지는지는 보지 않았다.
