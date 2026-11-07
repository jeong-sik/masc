# L9 console 읽기 시험 (2026-11-07)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L9 의 확인이다.
ego 연결의 read_console(`BrowserRead mode=console`)이 기대는 것을 쟀다.
ego 가 console 메시지를 CDP 에서 숨길 때 무엇이 오고 무엇이 안 오는지, 숨김을 끄면 무엇을 다시 받는지, masc 의 읽기 스크립트가 실제 Page 에서 어떻게 답하는지다.

## 환경

- ego lite 0.6.2.9, Chromium 156.0.8078.74, node v24.22.1 (`ego-browser --version`), macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(15, 16, 17). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
  - b1 은 space 16 을 일부러 열어 둔 채 끝났다. p1 의 숨김을 끄고 Runtime 을 켠 채였다. b2 가 이름(`masc-l9-console-b`)으로 다시 잡아 닫았다.
- [`server.py`](server.py) 를 `python3 -I server.py 18776` 로 띄웠다.
  - 시험 페이지는 로드할 때 `console.log`·`warn`·`error` 를 한 줄씩 쓰고, 잡지 않는 오류와 잡지 않는 promise 거절을 하나씩 낸다.
  - `window.say(n, tag)` 는 `<tag>-<번호>` 를 n 줄 쓴다. `window.throwLater(tag)` 는 잡지 않는 오류를 낸다.
  - `/frame.html` 은 frame 안에서 `frame-line <host>` 를 쓴다.
- 다른 site 는 `localhost`, 시험 페이지는 `127.0.0.1` 이다.
- 결과에는 시험 페이지가 쓴 줄과 시험 서버 주소만 있다. 운영자 프로필의 다른 탭이나 주소는 남기지 않았다.
- 권한 창이나 대화상자를 여는 호출은 없다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-console-a.mjs` | `result-console-a.jsonl` | 06:47:00Z |
| `probe-console-b1.mjs` | `result-console-b1.jsonl` | 06:48:07Z |
| `probe-console-b2.mjs` | `result-console-b2.jsonl` | 06:48:08Z |
| `probe-console-c.mjs` | `result-console-c.jsonl` | 07:16:14Z |

## 1. 숨김이 켜져 있으면 console event 가 오지 않는다 (a1~a2, a4~a5)

- goto 뒤 `page.events()` 에는 `Network.*` 와 `Page.*` 만 있었다. 로드 때 쓴 줄은 없었다.
- `Runtime.enable` 을 불렀다. `Runtime.executionContextCreated` 1개만 왔다.
- 그 뒤 `say(3)` 과 잡지 않는 오류를 냈다. `Runtime.consoleAPICalled` 도 `Runtime.exceptionThrown` 도 오지 않았다.
- 숨김을 다시 켠 뒤(a4)에도, 다시 `Runtime.enable` 을 불러도(a5) 같았다.

## 2. 숨김을 끄고 Runtime 을 껐다 켜야 모아 둔 줄을 다시 준다 (a3, a6, b2)

| 순서 | 결과 |
|---|---|
| `egoAutomated.disable` 만 | event 0개 |
| 이어서 `Runtime.enable` (이미 켜져 있음) | event 0개 |
| 이어서 `Runtime.disable` → `Runtime.enable` | console 7줄과 잡지 않은 오류 3개 |

- 다시 받은 줄에는 숨김이 켜져 있을 때 쓴 줄(로드 때 줄, `a2-*`)도 들어 있었다.
- 잡지 않은 오류와 promise 거절은 `Runtime.exceptionThrown` 으로 왔다.
- 숨김을 끈 동안 쓴 줄은 바로 왔다(a3 의 live).
- 다음 읽기(a6)는 앞에서 받은 줄을 다시 줬다. 읽는다고 비워지지 않는다.

native 입력(`browser_ego_raw_type`)은 `Runtime.enable` 을 부르고 끄지 않는다. 그래서 masc 의 읽기는 늘 `Runtime.disable` 부터 부른다.

## 3. 숨김은 Page 마다, SDK 프로세스마다다 (b1·b2)

| 확인 | 결과 |
|---|---|
| b1: p1 의 숨김만 끄고 p2 에서 Runtime 을 껐다 켬 | p2 는 0줄 |
| b1: p1 에서 Runtime 을 껐다 켬 | 로드 때 3줄 |
| b2: 새 SDK 프로세스가 같은 space 를 이름으로 다시 잡음 | 첫 `page.events()` 0개 |
| b2: 숨김을 끄지 않고 `say(2)` 뒤 읽기, Runtime 을 껐다 켜기 | 둘 다 0줄. 숨김이 다시 켜져 있다 |
| b2: 숨김을 끄고 Runtime 을 껐다 켬 | 로드 때 3줄, b1 이 쓴 `b1-*`, b2 가 쓴 `b2-*` |

b1 이 숨김을 끈 채 끝나도 다음 SDK 프로세스에서는 숨김이 다시 켜져 있었다.
브라우저가 모아 둔 줄은 SDK 프로세스가 바뀌어도 남았다.

## 4. 브라우저가 모아 두는 줄 (a7~a9)

| 확인 | 결과 |
|---|---|
| reload 뒤 | 새 문서가 로드 때 쓴 3줄과 오류 2개만. 앞 문서의 줄은 없다 |
| 같은 site frame, 다른 site frame | `frame-line 127.0.0.1:18776` 만. `localhost` frame 의 줄은 없다 |
| `say(1500)` 뒤 | consoleAPICalled 정확히 1,000개. `a9-501` 부터 `a9-1499` 까지와 긴 줄 하나 |
| 20,005 글자 줄 | 자르지 않고 왔다 |

## 5. 모양 (a3 의 shape)

- `consoleAPICalled` 의 params 는 `args`, `executionContextId`, `stackTrace`, `timestamp`(ms 숫자), `type` 이다.
- 인자는 문자열이면 `{type, value}`, 숫자면 `{description, type, value}`, 객체면 `{className, description, objectId, preview, type}` 이다.
- 숨김을 끄고 Runtime 을 켠 채로도 `navigator.webdriver` 는 false, console 로 넘긴 Error 의 `stack` getter 는 읽히지 않았다(a3, a4 의 fingerprint).

## 6. 바쁜 페이지 (a10)

페이지에서 3초 반복문을 걸고 200 ms 뒤에 다섯 호출을 시작했다. 시작부터 각 호출이 끝날 때까지의 시간이다.

| 회 | `evaluate` | `egoAutomated.disable` | `Runtime.enable` | `Runtime.disable` | `egoAutomated.enable` |
|---|---|---|---|---|---|
| 1 | 3001 | 3003 | 3695 | 3699 | 4487 |
| 2 | 3001 | 4304 | 8714 | 11441 | 11445 |
| 3 | 4584 | 5770 | 5788 | 5791 | 5793 |

명령이 페이지를 기다린다. 숨김을 끈 구간도 그만큼 길어진다.

## 7. masc 스크립트를 실제 Page 에서 돌렸다 (c)

[`console.js`](console.js) 는 `lib/browser_ego_page_events.ml` 의 `script` 와 `lib/browser_ego_console.ml` 의 `script` 를 이은 글이다. 한도는 masc 와 같다(줄 200, 4,000 바이트, 답 2,031,616 단위).
`probe-console-c.mjs` 는 그 글 뒤에 시험 단계를 붙였다.
c 를 돌린 뒤 `browser_ego_console.ml` 의 이 글에 주석 두 줄(두 번째 drain 의 이유)만 더했다. 동작은 같다.

| 단계 | 결과 |
|---|---|
| c1 첫 읽기 | 로드 때 3줄과 오류 2개. `hiding.offMs` 8, `restored: true` |
| c2 다시 읽기 | 같은 5개. `offMs` 3 |
| c3 읽은 뒤 `say(2)` | `page.events()` 에 Runtime event 가 없다. 숨김이 다시 켜졌다 |
| c4 읽은 뒤 `mascPageEvents` | Runtime event 0개. 읽기가 일으킨 event 는 workflow `events` 로 가지 않는다 |
| c5 Runtime 을 미리 켜 둠 | 7개를 다 읽었다. native 입력이 남긴 상태에서도 읽힌다 |
| c6 `가` 2,000자 | 3,999 바이트에서 잘렸다(`textCut: true`). 글자 가운데에서 자르지 않았다 |
| c8 인자 여러 종류 | `args 5 true null undefined 5n NaN Object Array(2) () => 1 Symbol(s)`. `%s fmt x` 처럼 형식 지정자는 풀지 않는다 |
| c9 오류 | `Uncaught Error: c9-uncaught` 와 stack, `Uncaught c9-string`, `Uncaught (in promise) Error: c9-rejected` 와 stack |
| c7 `say(1500)` | 200개, `dropped` 800. `c7-1300` 부터 `c7-1499` |
| c10 4,000 글자 제어 문자 300줄 | 84개, `dropped` 916. JSON 으로 2,023,267 단위라 답 한도 안이다 |
| c11 reload 뒤 frame 둘 | 로드 때 5개와 `frame-line 127.0.0.1:18776` 만 |
| c12 바쁜 페이지 | 2,803 ms 걸렸고 `offMs` 2803, `restored: true` |
| c13 읽은 뒤 network 목록 | `http://127.0.0.1:18776/x?token=REDACTED completed`. console 읽기가 network 기록을 잃지 않는다 |

- c1·c2 의 `malformedEvents.count` 는 0 이었다. 다른 단계는 이 값을 기록하지 않았다.
- c13 이 질의에 넣은 시험 비밀 문자열(`L9_SECRET`)은 결과 파일에 없다.

## 재지 않은 것

- 숨김을 끈 동안 사이트가 실제로 자동화를 알아채는지. `navigator.webdriver` 와 stack getter 둘만 봤다.
- 되돌리기(`egoAutomated.enable`)가 실패하는 경우. 실패를 일으키는 방법을 찾지 못했다. 그 경로는 가짜 Page 시험(`test/test_browser_ego_console.cjs`)으로만 본다.
- 페이지가 이동하는 도중의 읽기.

## masc 와의 관계

masc 서버의 `page.console` 단계를 통째로 돌리지는 않았다. c 가 그 단계가 쓰는 글을 그대로 돌렸다.

- `test/test_browser_ego_console.cjs` 는 같은 글을 가짜 Page 로 돌린다. 명령 순서, 다른 event 를 남기는지, 늦게 온 줄, 한도와 자르기, 인자와 오류의 글, 잘못된 event, 실패마다 숨김이 돌아왔는지를 본다.
- `test/test_browser_ego_peer.ml` 은 masc 가 그 답을 읽어 다시 만드는지 본다. 모양이 다른 답은 거절하고, 숨김이 꺼진 채 남았으면 답에 그렇게 적는다.
