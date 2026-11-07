# L4 touch 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L4 의 확인이다.
ego 연결의 tap_at·swipe 가 기대는 CDP touch 동작을 쟀다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(32~35). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
- 페이지는 [`page.html`](page.html) 를 `index.html` 로 두고 `python3 -m http.server 18771 --bind 127.0.0.1` 로 띄웠다.
- 페이지는 touch·pointer·click 이벤트의 종류, pointerType, 좌표, isTrusted, 시각을 `window.__events` 에 쌓는다.
- 권한 창이나 대화상자를 여는 호출은 없다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다. 결과 파일 첫 줄의 `[ego-browser:notice]` 는 ego 업데이트 안내다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-touch-a.mjs` | `result-touch-a.jsonl` | 11:18:32Z |
| `probe-touch-b.mjs` | `result-touch-b.jsonl` | 11:19:42Z |
| `probe-touch-c.mjs` | `result-touch-c.jsonl` | 11:20:34Z |
| `probe-touch-d1.mjs` | `result-touch-d1.jsonl` | 11:21:09Z |
| `probe-touch-d2.mjs` | `result-touch-d2.jsonl` | 11:21:13Z |

## 1. touch 흉내는 필요 없다 (a 의 A·E, b 의 F)

흉내를 켜지 않고 `touchStart`·`touchEnd` 를 보냈다.
페이지는 pointerdown(touch)·touchstart·pointerup(touch)·touchend·click(touch) 를 받았다. 모두 isTrusted 였다.

흉내(`Emulation.setTouchEmulationEnabled`, maxTouchPoints 1)를 켜면 페이지가 보는 값이 바뀌었다.

| 값 | 켜기 전 | 켠 뒤 | 끈 뒤 |
|---|---|---|---|
| `navigator.maxTouchPoints` | 0 | 1 | 0 |
| `(pointer: coarse)` | false | true | false |
| `(any-pointer: coarse)` | false | true | false |
| `(hover: none)` | false | true | false |

받은 이벤트는 켜기 전과 같았다. 그래서 masc 는 흉내를 켜지 않는다.
켜 두면 그 SDK 프로세스가 끝날 때까지 페이지가 터치 기기용 화면으로 바뀔 수 있다.

## 2. swipe 는 페이지를 스크롤한다 (a 의 C, b 의 F·G)

(200, 500) 에서 (200, 200) 으로 끌었다.
페이지는 pointerdown·touchstart·pointermove 다음에 pointercancel 을 받았고, 나머지는 touchmove 와 touchend 였다. click 은 없었다.
브라우저가 스크롤을 넘겨받을 때 실제 손가락에서도 생기는 순서다.

| 보낸 점 | 스크롤 |
|---|---|
| 움직임 3번을 바로 (a 의 C, 흉내 켬) | 378 px |
| 움직임 3번을 바로 (b 의 F, 흉내 없음) | 1585 px |
| 25 ms 간격 20번으로 300 px (b 의 G, 흉내 없음) | 346 px |

점 사이 간격이 손가락을 놓을 때의 속도를 정한다.
그래서 swipe 는 BiDi 와 같은 구간(경유점, 없으면 가운데 점, 그리고 끝점)마다 `durationMs` 동안 16 ms 간격으로 점을 보낸다.

## 3. touchEnd 의 답은 페이지가 이벤트를 처리한 뒤에 온다 (a 의 D)

touchend 핸들러가 400 ms 동안 돌게 했다. 핸들러가 끝난 지 3 ms 뒤에 CDP 답이 왔다(touchEnd 호출 421 ms).

답이 오기까지 걸린 시간은 고르지 않았다.
a 의 B 는 22 ms, a 의 C 는 975 ms, b 의 H 는 1127 ms 였다. d2 의 tap 은 로그 시각 차로 약 2.3 s 였다.

## 4. 남은 touch 는 다음 touch 를 망가뜨리고, touchCancel 이 지운다 (b 의 H·I, c)

- touchStart 다음에 touchEnd 없이 다른 점에서 touchStart 를 보냈다(H). 페이지는 새 tap 대신 남은 touch 의 pointermove·touchmove·pointercancel·touchend 를 받았다.
- touchStart 다음에 touchCancel 을 보냈다(I). pointercancel·touchcancel 이 갔고, 다음 tap 은 click 까지 정상이었다.
- 누른 것이 없을 때 touchCancel 은 `Must send a TouchStart first to start a new touch.` 오류를 냈다(c). 페이지에는 아무것도 가지 않았다.

그래서 누른 뒤 실패한 gesture 는 touchCancel 을 보낸다.

## 5. 새 SDK 프로세스에는 남은 touch 가 없다 (d1, d2)

d1 은 touchStart 만 보내고 프로세스를 끝냈다.
같은 Page 를 연 d2 의 tap 은 정상이었고, touchCancel 은 위 오류를 냈다.
페이지에는 d1 의 pointerdown·touchstart 만 남았고, 그 짝이 되는 이벤트는 오지 않았다.

## masc 와의 관계

masc 서버의 `page.touch` 단계를 통째로 돌리지는 않았다.
그 스크립트는 `test/test_browser_ego_peer.ml` 이 `node --check` 로 본다. 보내는 점과 대기 시간도 같은 시험이 본다.
