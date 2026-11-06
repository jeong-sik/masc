# ego CDP 기능 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../rfc/RFC-browser-ego-cdp-capabilities.md) 가 근거로 쓰는 측정이다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max)
- 안내서: `ego-browser skill` v2.2.0
- 시작 시각: `run-started-at.txt` (2026-11-06T03:27:52Z)
- masc 연결을 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space `masc-capability-probe` 를 만들고 끝에 `finish({keep: []})` 로 닫았다(space 18). Keeper 의 space 9 은 건드리지 않았다.
- 페이지는 `python3 -m http.server 18767 --bind 127.0.0.1` 로 띄운 `probe-page.html` 이다.

## 명령

```sh
ego-browser nodejs < probe-a.mjs 2> result-a.json
ego-browser nodejs < probe-b.mjs 2> result-b.json
```

ego 의 `console.log` 는 stderr 로 나온다. 그래서 결과는 stderr 에 있다.
저장한 두 결과 파일은 원본에서 끝의 빈 줄 하나만 지웠다(1744→1743, 365→364 바이트). 나머지 바이트는 원본 그대로다.
`probe-b.mjs` 는 `probe-a.mjs` 가 끝난 뒤 새 Node 프로세스로 돈다.

## 결과

| 항목 | CDP | 값 |
|---|---|---|
| 화면 크기 | `Emulation.setDeviceMetricsOverride` | 1548×990 → 800×600 |
| 터치 | `Emulation.setTouchEmulationEnabled`, `Input.dispatchTouchEvent` | pointerdown(touch) · touchstart · pointerup(touch) · touchend · click(touch), 모두 `isTrusted` |
| html 원문 | `DOM.getDocument`, `DOM.getOuterHTML` | 597 바이트, `<!DOCTYPE html>` 로 시작 |
| 쿠키 이름 | `Network.getCookies` | `probe_cookie` |
| 언어·시간대·위치 | `Emulation.setLocaleOverride`, `setTimezoneOverride`, `setGeolocationOverride` | Intl locale `fr-FR`, 시간대 `America/New_York`. `navigator.language` 는 `ko-KR` 그대로 |
| 요청 차단 | `Network.setBlockedURLs` | `fetch("/blocked-probe.txt")` → `TypeError: Failed to fetch` |
| network 기록 | `Network.enable` + `page.events()` | reload 한 번에 105개(앞선 실행은 43개). `requestWillBeSent`, `responseReceived`, `loadingFinished` 등 |
| 창 | `task.cdp("Browser.getWindowForTarget")` | windowId 와 bounds, `windowState: "maximized"` |
| 확대 | `Emulation.setPageScaleFactor` | `visualViewport.scale` 2. 브라우저 확대가 아니라 핀치 배율이다 |
| console (기본) | `Runtime.enable` + `page.events()` | `Runtime.consoleAPICalled` 0개 |
| console (`egoAutomated.disable` 뒤) | 같음 | 3줄. 페이지가 처음 로드될 때 쓴 줄도 들어 있다 |

### 새 프로세스에서 다시 읽은 값 (`result-b.json`)

| 항목 | 값 |
|---|---|
| 화면 크기 | 1548×990 (원래 값) |
| Intl locale·시간대 | `ko`, `Asia/Seoul` (원래 값) |
| 차단한 주소 | HTTP 404. 차단이 풀렸다 |
| 핀치 배율 | 1 |

CDP 로 바꾼 설정은 바꾼 SDK 프로세스가 끝나면 모두 사라졌다.

## 재지 않은 것

- `Target.createTarget({newWindow: true})` 로 창 만들기, 창 닫기. ego task space 가 그렇게 만든 탭을 어떻게 관리하는지 모른다.
- `Network.setCookie`·`deleteCookies` 로 쿠키 쓰기. ego 는 운영자의 실제 프로필을 쓴다.
- `Browser.grantPermissions` 로 위치 권한 주기. 같은 이유다.
- `egoAutomated.enable` 이 자동화를 다시 숨기는지. 명령은 오류 없이 돌아왔다.
- `Network.enable` 이 사이트가 자동화를 알아채게 하는지.
- 한 프로세스 안에서 `page.events()` 를 두 곳이 읽을 때 무엇이 남는지. 안내서는 `events()` 가 버퍼를 돌려주고 비운다고 적었다.
