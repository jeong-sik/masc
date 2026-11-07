# L5 창 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L5 의 확인이다.
ego 연결의 list_windows 가 기대는 `Browser.getWindowForTarget` 을 쟀다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(38~41). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
- 페이지는 [`page.html`](page.html) 를 `index.html` 로 두고 `python3 -m http.server 18772 --bind 127.0.0.1` 로 띄웠다.
- 권한 창이나 대화상자를 여는 호출은 없다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다. 결과 파일 첫 줄의 `[ego-browser:notice]` 는 ego 업데이트 안내다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-windows-a.mjs` | `result-windows-a.jsonl` | 12:05:13Z |
| `probe-windows-b.mjs` | `result-windows-b.jsonl` | 12:05:40Z |
| `probe-windows-c.mjs` | `result-windows-c.jsonl` | 12:13:41Z |

## 1. task space 하나가 창 하나다 (a 의 A·B·F, b)

`task.tabs()` 의 각 탭에 `task.cdp("Browser.getWindowForTarget", {targetId})` 를 불렀다.
답은 `windowId` 와 `bounds`(`left`·`top`·`width`·`height`·`windowState`)였다.

| 탭 | 만든 방법 | windowId |
|---|---|---|
| p1 | space 의 첫 Page | 1426150641 |
| p2 | `task.newPage()` | 1426150641 |
| p3 | `target="_blank"` 링크를 `page.click` | 1426150641 |
| p4 | `window.open(url, name, "popup,width=480,height=360")` 버튼을 `page.click` | 1426150641 |

p3·p4 는 click receipt 의 `popups` 에 label 과 함께 나왔다. 둘 다 agent 가 연 managed Page 였다.
popup 기능을 준 `window.open` 도 새 창이 아니라 같은 창의 탭이 됐다.

같은 프로세스에서 task space 둘을 열었다(b). space 39 의 탭은 1426150651, space 40 의 탭은 1426150653 이었다.
task space 마다 창이 따로 있다.

## 2. 페이지가 바빠도 답한다 (c)

p1 의 페이지에서 3초 동안 도는 반복문을 `setTimeout` 으로 걸고 200 ms 기다렸다.
그다음 `page.evaluate("Date.now()")`, `getWindowForTarget`, `task.tabs()` 를 한꺼번에 시작했다. 3번 했다.

| 읽기 | 걸린 시간(ms) |
|---|---|
| `page.evaluate` | 2800, 2799, 2800 |
| `getWindowForTarget` | 1, 0, 0 |
| `task.tabs()` | 2, 2, 1 |

`page.evaluate` 는 반복문이 끝날 때까지 기다렸다. 그동안 창 정보와 탭 목록은 바로 왔다.
창 정보는 renderer 가 아니라 브라우저 프로세스에서 온다. 그래서 탭 목록이 Page.info 를 기다리지 않는 지금의 성질을 지킨다.
a 의 D 도 같은 것을 재려 했지만, 그때 renderer 가 바빴다는 증거가 없어서 c 로 다시 쟀다.

## 3. 시간 (a 의 C)

탭 셋, 10번씩 쟀다(ms).

| 방법 | 값 |
|---|---|
| `task.tabs()` 만 | 0, 1, 5, 0, 1, 1, 1, 0, 2, 1 |
| 탭마다 차례로 | 2, 4, 5, 1, 3, 2, 1, 1, 1, 3 |
| 탭마다 한꺼번에(`Promise.all`) | 2, 1, 1, 1, 2, 3, 1, 1, 1, 0 |

masc 는 한꺼번에 묻는다.

## 4. 없는 탭 (a 의 E)

없는 targetId 에는 `No target with given id` 오류가 0 ms 에 왔다.
목록을 읽은 뒤 닫힌 탭이 이 경우다. masc 는 그 탭을 `windowId` 없이 목록에 둔다.

## 5. 새 창은 CDP 로 만들 수 없다 (b 의 G)

`task.cdp("Target.createTarget", {url, newWindow: true})` 는 `Target.createTarget is not allowed` 오류를 냈다. 탭도 창도 생기지 않았다.
L10(create_window) 이 기대던 길이다. 1번처럼 `window.open` 의 popup 도 같은 창의 탭이 된다.

## masc 와의 관계

masc 서버의 `tabs.list` 단계를 통째로 돌리지는 않았다.
그 스크립트는 `test/test_browser_ego_page_management.cjs` 가 가짜 task 로 돌린다. 창 번호를 붙이는지, 실패한 탭을 창 번호 없이 두는지, `task.cdp` 가 없어도 목록이 나오는지 본다.
`test/test_browser_ego_peer.ml` 은 masc 가 그 답을 읽어 `windowId` 로 옮기는지 본다.
