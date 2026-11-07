# L8 요청 목록 시험 (2026-11-07)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L8 의 확인이다.
ego 연결의 read_network(`BrowserRead mode=network`)가 기대는 것을 쟀다.
ego 가 Page 마다 모아 두는 event 버퍼(`page.events()`)가 무엇을 담는지, 그리고 masc 의 drain 스크립트가 실제 Page 에서 어떻게 답하는지다.

## 환경

- ego lite 0.6.2.9, Chromium 156.0.8078.74, node v24.22.1 (`ego-browser --version`), macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(8, 9, 10, 12). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
  - b1 은 space 9 를 일부러 열어 둔 채 끝났다. b2 가 이름(`masc-l8-network-b`)으로 다시 잡아 닫았다.
  - space 11 은 c 의 첫 실행이다. 그 뒤 스크립트를 고쳐서 결과를 남기지 않았다.
- [`server.py`](server.py) 를 `python3 -I server.py 18775` 로 띄웠다.
  - `window.fire(n, tag)` 는 `/x?tag=…&i=…&token=L8_SECRET_QUERY` 를 n 번 fetch 한다. 요청 헤더 `X-Masc-L8: L8_SECRET_HEADER` 를 붙인다.
  - 응답에는 `X-Masc-L8-Answer: L8_SECRET_ANSWER` 헤더가 붙는다.
  - `/redir` 은 302, `/slow` 는 2초 뒤 답한다. `/frame.html` 은 frame 안에서 한 번 fetch 한다.
- 다른 site 는 `localhost`, 시험 페이지는 `127.0.0.1` 이다.
- 결과에는 시험 서버 주소와 ego 시작 페이지의 `chrome://resources/…` 주소만 있다. 운영자 프로필의 다른 주소·헤더 값·쿠키는 남기지 않았다.
- 권한 창이나 대화상자를 여는 호출은 없다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-network-a.mjs` | `result-network-a.jsonl` | 05:19:39Z |
| `probe-network-b1.mjs` | `result-network-b1.jsonl` | 05:22:03Z |
| `probe-network-b2.mjs` | `result-network-b2.jsonl` | 05:22:21Z |
| `probe-network-b3.mjs` | `result-network-b3.jsonl` | 05:22:42Z |
| `probe-network-c.mjs` | `result-network-c.jsonl` | 05:33:24Z |

## 1. ego 는 Network.enable 없이 요청을 모은다 (a1~a3, a12)

- goto 와 reload 한 번 뒤 `page.events()` 가 event 140개를 줬다. `Network.enable` 을 부르기 전이다.
  - `Network.requestWillBeSent` 23개, `responseReceived` 24개, `loadingFinished` 30개, `Page.*` 들이 섞여 있었다.
- 곧바로 다시 읽으면 0개였다. 읽으면 버퍼가 빈다.
- `Network.enable` 은 `{}` 로 답했다. 그 뒤에도 같은 event 가 같은 모양으로 왔다.
- 새 Page 에서 `Network.enable` 전과 뒤, reload 뒤에 페이지가 보는 값을 견줬다. 모두 같았다.
  - `navigator.webdriver` false, console 로 넘긴 Error 의 `stack` getter 를 읽지 않음, plugins 5개, `window.chrome` 키 `app`·`csi`·`loadTimes`, window 키 240개

그래서 masc 는 `Network.enable` 을 부르지 않는다. ego 가 이미 모은 것을 읽는다.

## 2. 버퍼는 Page 마다, SDK 프로세스마다 따로다 (a4~a7, b1·b2)

| 확인 | 결과 |
|---|---|
| 두 Page 에서 각각 fetch | p1 에는 p1 의 것만, p2 에는 p2 의 것만 |
| `task.page(label)` 을 다시 부름 | 다른 객체(`===` false)인데 같은 버퍼를 읽는다 |
| `snapshot`·`url`·`title`·`info`·`evaluate`·`waitForTimeout` 뒤 | 버퍼가 그대로다 |
| 다른 site 로 goto 한 뒤 | goto 전 요청과 문서 요청이 함께 남는다 |
| b1 이 fetch 3번 하고 읽지 않은 채 끝남 → b2 가 같은 space 를 이름으로 다시 잡음 | b2 의 첫 읽기는 0개 |

버퍼는 SDK 프로세스 안에 있다. masc 의 읽기는 지금 SDK 프로세스가 본 요청만 보여 준다.
답의 `sdkProcessStartedAt` 이 그 프로세스를 가리킨다.

## 3. 버퍼는 최근 10,000개만 남긴다 (a11, b2 의 c)

- fetch 3,000번을 한꺼번에 보낸 뒤 읽으면 event 가 정확히 10,000개였다.
- b2 에서 요청 번호(`i`)로 보면 남은 요청은 1368번부터 2999번까지였다. 오래된 것이 소리 없이 빠졌다.
- 같은 때 서버가 일부 fetch 를 받지 못했다(a11 실패 1,948개, b2 실패 74개). 버퍼 크기를 재는 데는 영향이 없다.

그래서 masc 는 버퍼가 가득 찬 채 읽힌 횟수를 `fullBufferReads` 로 센다.

## 4. 요청 한 건의 event (a8~a10)

| 경우 | event |
|---|---|
| 302 redirect | 같은 requestId 로 `requestWillBeSent` 가 두 번 온다. 두 번째에 `redirectResponse`(status 302)가 붙는다 |
| 연결 거절 | `loadingFailed`, `errorText` `net::ERR_CONNECTION_REFUSED` |
| 느린 답 | 답이 오기 전에는 `requestWillBeSent` 만 있다 |
| 다른 site frame | frame 문서 요청(`/frame.html`)은 온다. frame 안의 fetch 는 오지 않는다 |
| `ExtraInfo` event | 요청·응답 헤더 원문과 쿠키를 담는다(`associatedCookies`, `headersText`) |

## 5. 바쁜 페이지 (a13)

페이지에서 3초 반복문을 걸고 200 ms 뒤에 세 호출을 한꺼번에 시작했다.

| 호출 | 걸린 시간(ms) |
|---|---|
| `page.evaluate` | 2799~2800 (3번 모두) |
| `Network.enable` | 2800~2801 (3번 모두) |
| `page.events()` | 2800, 2800, 0 |

`page.events()` 도 대개 페이지를 기다렸다. masc 의 읽기는 그 시간만큼 늦어진다.

## 6. 팝업 (b2 의 d, b3)

- b2: 링크로 연 팝업 Page 의 첫 읽기가 0개였다. 팝업의 첫 문서 요청이 없었다.
- b3: 첫 읽기에 요청 1개가 있었다. 그 주소는 기록하지 않았다.
- 둘 다 팝업이 그 뒤 보낸 fetch 와 reload 는 버퍼에 들어왔다.

그래서 팝업의 첫 문서 요청은 목록에 없을 때가 많다.

## 7. masc 스크립트를 실제 Page 에서 돌렸다 (c)

[`network.js`](network.js) 는 `lib/browser_ego_page_events.ml` 의 `script` 와 같은 글이다. 한도 선언 한 줄 뒤에 drain 글이 그대로 붙는다.
`probe-network-c.mjs` 는 그 글 뒤에 시험 단계를 붙였다. masc 와 같은 한도(요청 200, 경로 500 바이트, 헤더 이름 64, 버퍼 10,000)다.

| 단계 | 결과 |
|---|---|
| c1 첫 goto 뒤 | 요청 10개. 시험 페이지와 favicon 둘, 나머지 8개는 goto 전 ego 시작 페이지의 `chrome://resources/…` 다 |
| c2 fetch 3번 | `http://127.0.0.1:18775/x?tag=REDACTED&i=REDACTED&token=REDACTED`, completed, 헤더 이름만 |
| c3 `mascPageEvents` 와 `mascNetworkLog` 를 번갈아 | 어느 쪽도 다른 쪽의 event 를 잃지 않았다. network 읽기가 먼저 비운 Page event 도 다음 `mascPageEvents` 에 한 번만 나왔다 |
| c4 redirect | `/redir` completed 302(bytesReceived 171), 이어서 `/x…` responded 200 |
| c5 거절과 느린 답 | 거절은 failed `net::ERR_CONNECTION_REFUSED`. 느린 답은 pending, 2초 뒤 responded |
| c6 `Network.setBlockedURLs` 로 막은 주소 | failed `blocked: inspector` |
| c7 긴 경로 | `/` 와 `a` 498개, 그다음 `%E2%82%AC` 는 잘렸다. 경로 499 바이트, `urlCut: true` |
| c7 주소에 사용자 정보 | 사용자 정보는 빠졌다. 요청은 failed 였다 |
| c7 `data:` 이미지 | 목록에 없다. ego 가 event 를 주지 않았다 |
| c8 fetch 250번 | 행 200개, `dropped` 74 |
| c9 팝업 | 첫 읽기에 favicon 1개뿐. 첫 문서 요청은 없었다. 그 뒤 fetch 는 들어왔다 |

- 단계마다 답에 시험 비밀 문자열(`L8_SECRET_QUERY`, `L8_SECRET_HEADER`, `L8_SECRET_ANSWER`, `user:pass`, `L8_USER`)이 있는지 봤다. 하나도 없었다(`leaks: []`).
- 응답 본문이 끝까지 읽히지 않은 fetch 는 `loadingFinished` 가 오지 않았다(c4 의 `/x`). 그래서 `responded` 상태를 따로 뒀다.
- `malformedEvents.count` 는 모든 단계에서 0 이었다.

## masc 와의 관계

masc 서버의 `page.network` 단계를 통째로 돌리지는 않았다. c 가 그 단계가 쓰는 drain 글을 그대로 돌렸다.

- `test/test_browser_ego_page_events.cjs` 는 같은 글을 가짜 Page 로 돌린다. 값이 빠지는지, 다른 event 를 남기는지, 상태, 한도, 잘린 주소, 잘못된 event, 버퍼가 가득 찬 때를 본다.
- `test/test_browser_ego_workflow.cjs`·`test_browser_ego_raw_type.cjs` 는 workflow events 단계와 native 입력이 같은 drain 을 거치는지 본다.
- `test/test_browser_ego_peer.ml` 은 masc 가 그 답을 읽어 다시 만드는지 본다. query 값·사용자 정보·fragment 가 남은 주소나 모양이 다른 답은 거절해야 한다.
