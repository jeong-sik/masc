# L7 쿠키·저장소 이름 시험 (2026-11-07)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L7 의 확인이다.
ego 연결의 read_storage(`BrowserRead mode=cookies`)가 기대는 두 가지를 쟀다.
하나는 `Network.getCookies` 이고, 다른 하나는 페이지가 읽는 저장소 이름이다.

## 환경

- ego lite 0.6.2.9, macOS (MacBook M3 Max). L6 뒤에 ego 가 0.6.2.7 에서 올라갔다. Chromium 버전은 읽지 못했다(`task.cdp("Browser.getVersion")` 은 `wasn't found`).
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(4~6). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
- [`server.py`](server.py) 를 `python3 -I server.py 18774` 로 띄웠다. 응답 헤더로 쿠키를 심는다. `document.cookie` 로는 HttpOnly 쿠키를 만들 수 없어서다.
  - `/set`: `masc_l7_http`(HttpOnly, SameSite=Strict), `masc_l7_persist`(Max-Age=600), `masc_l7_sub`(Path=/sub)
  - `/setframe`: `masc_l7_frame`
- 다른 site 는 `localhost`, 시험 페이지는 `127.0.0.1` 이다.
- 시험 쿠키는 모두 `masc_l7_` 로 시작한다. 결과에는 이 쿠키만 이름을 적었다. 운영자 프로필의 다른 쿠키 이름은 남기지 않았다.
- 쿠키 값은 `*_SECRET_VALUE` 같은 시험 문자열이다. c 는 답에 이 문자열이 하나라도 있는지 봤다(`leaks`).
- 끝에 시험 쿠키만 이름으로 지웠다(`Network.deleteCookies`). localStorage 키와 IndexedDB 도 지웠다. 지운 뒤 남은 것은 0개였다(`z.after`, `z.storageAfter`).
- 권한 창이나 대화상자를 여는 호출은 없다. `Network.enable` 은 부르지 않았다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-storage-a.mjs` | `result-storage-a.jsonl` | 02:07:30Z |
| `probe-storage-b.mjs` | `result-storage-b.jsonl` | 02:08:25Z |
| `probe-storage-c.mjs` | `result-storage-c.jsonl` | 02:19:17Z |

a 의 `b.*`·`e.*` 단계는 probe 결함으로 실패했다. 두 번째 Page 를 `task.page("p2")` 로 불렀는데, 그 Page 는 `task.newPage()` 로 만들어야 한다. b 가 같은 것을 다시 쟀다.

## 1. getCookies 는 Network.enable 없이 답한다 (a)

`page.cdp("Network.getCookies")` 는 HttpOnly 쿠키까지 줬다.

| 쿠키 | httpOnly | session | sameSite |
|---|---|---|---|
| `masc_l7_js` | false | true | 없음 |
| `masc_l7_http` | true | true | `Strict` |
| `masc_l7_persist` | false | false | 없음 |

- 쿠키마다 오는 필드는 `domain`·`expires`·`httpOnly`·`name`·`path`·`priority`·`secure`·`session`·`size`·`sourcePort`·`sourceScheme`·`value` 다. SameSite 를 적은 쿠키에만 `sameSite` 가 붙는다.
- `value` 가 온다. 그래서 masc 스크립트는 SDK 프로세스 안에서 값을 버린다.
- `Path=/sub` 쿠키는 `/set` 페이지의 목록에 없고, `urls: [".../sub/x"]` 로 물을 때만 왔다.

## 2. URL 없이 물으면 다른 site frame 의 쿠키도 온다 (b)

다른 탭에서 `localhost` 를 열어 `masc_l7_frame` 을 심었다. 그다음 `127.0.0.1` 페이지에 `localhost` frame 을 넣었다.

| 읽기 | 나온 쿠키 |
|---|---|
| frame 의 `document.cookie` | 없음 |
| `getCookies()` (URL 없음) | `masc_l7_frame@localhost`, `masc_l7_http@127.0.0.1`, `masc_l7_persist@127.0.0.1` |
| `getCookies({urls: [최상위 URL]})` | `masc_l7_http@127.0.0.1`, `masc_l7_persist@127.0.0.1` |

URL 없는 호출은 frame 의 주소에 걸린 쿠키도 준다. 그 frame 은 그 쿠키를 보지 못한다(SameSite 기본값 Lax).
그래서 masc 는 최상위 문서의 URL 을 넘긴다. 답의 쿠키는 그 탭의 최상위 문서가 보는 것이다.

## 3. 페이지가 바쁘면 기다린다 (a 의 D, b 의 G)

페이지에서 3초 반복문을 걸고 200 ms 뒤에 읽기를 한꺼번에 시작했다.

| 읽기 | 걸린 시간(ms) |
|---|---|
| `page.evaluate` | 2798~2800 (11번 모두) |
| `page.url()` | 2799~2801 (5번 모두) |
| `getCookies` (URL 없음) | 1~3 또는 2800~2802. 8번 중 3번 기다렸다 |
| `getCookies` (URL 있음) | 1~3 또는 2800. 8번 중 2번 기다렸다 |

`page.evaluate` 와 `page.url()` 은 늘 기다렸다. `getCookies` 는 때때로 기다렸다.
masc 의 읽기는 저장소 이름을 `page.evaluate` 로 읽어서 어차피 페이지를 기다린다. 다른 읽기(text, html)와 같다.

## 4. 저장소 이름 (a 의 C, b 의 H)

- `page.evaluate(async fn, arg)` 는 함수가 돌려준 promise 를 기다린다.
- 같은 호출에서 localStorage·sessionStorage 키 이름과 `indexedDB.databases()` 의 이름을 읽었다.
- `data:` 주소 페이지는 origin 이 `null` 이고, 세 저장소 모두 `SecurityError` 를 던졌다. getCookies(URL 없음)는 쿠키 0개였다.

## 5. masc 스크립트를 실제 Page 에서 돌렸다 (c)

[`storage.js`](storage.js) 는 `lib/browser_ego_peer.ml` 의 `storage_names_script` 와 같은 글이다. `probe-storage-c.mjs` 앞에 그 글이 그대로 들어 있다.
masc 와 같은 한도(쿠키 200, 이름 100, 이름 200자, IndexedDB 2초)로 불렀다.

| 페이지 | 답 |
|---|---|
| `127.0.0.1` 시험 페이지 | 시험 쿠키 3개(`masc_l7_js`, `masc_l7_http`, `masc_l7_persist`)와 `total: 4`. 넷째는 이 시험이 만들지 않은 `127.0.0.1` 쿠키다 |
| 같은 페이지의 저장소 | localStorage 키 107개 중 100개(`truncated: true`), 300자 키는 200자로 잘림. sessionStorage `masc_l7_session`, IndexedDB `masc_l7_db` |
| `data:` 페이지 | 쿠키 0개, 세 저장소 모두 `{error: "SecurityError"}` |
| `about:blank` | 쿠키 0개, 세 저장소 모두 `{error: "SecurityError"}` |

- 세 답 모두 시험 값 문자열이 하나도 없었다(`leaks: []`).
- 쿠키 행의 필드는 `name`·`domain`·`path`·`secure`·`httpOnly`·`sameSite`·`expiry` 뿐이었다. `sameSite` 는 `masc_l7_http` 에만, `expiry` 는 `masc_l7_persist` 에만 있었다.
- `localhost` frame 의 `masc_l7_frame` 은 목록에 없었다.
- `data:`·`about:blank` 주소로 `getCookies({urls: [...]})` 를 불러도 오류 없이 빈 목록이 왔다.

## masc 와의 관계

masc 서버의 `page.cookies` 단계를 통째로 돌리지는 않았다. c 가 그 단계의 스크립트 글을 그대로 돌렸다.

- `test/test_browser_ego_page_management.cjs` 는 같은 스크립트를 가짜 Page 로 돌린다. 값이 빠지는지, 최상위 URL 로 묻는지, 목록이 잘리는지, IndexedDB 가 늦거나 없을 때, CDP 오류 때를 본다.
- `test/test_browser_ego_peer.ml` 은 masc 가 그 답을 읽어 다시 만드는지 본다. 값이 든 쿠키나 모양이 다른 답은 거절해야 한다.
