# L11 쿠키 쓰기·지우기 시험 (2026-11-07)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L11 의 확인이다.
ego 연결의 write_storage(`BrowserAct action=set_cookie`, `delete_cookie`)가 기대는 것을 쟀다.
ego Page 의 CDP session 으로 부른 `Network.setCookie`·`deleteCookies`·`getCookies` 가 무엇을 받고 거절하는지, 쓴 쿠키가 어디까지 남는지, masc 의 쓰기 스크립트가 실제 Page 에서 어떻게 답하는지다.

## 환경

- ego lite 0.6.2.9, Chromium 156.0.8078.74, node v24.22.1 (`ego-browser --version`), macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(19, 20, 21, 23). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
  - c 는 두 번 돌렸다. 첫 번째(space 22, 닫음) 뒤에 c9 의 오류 문장을 고쳤다. 고친 글로 다시 돌린 결과만 남겼다.
  - 두 결과는 그 문장과 `getCookies` 가 준 쿠키 순서만 달랐다.
- [`server.py`](server.py) 를 `python3 -I server.py 18777` 로 띄웠다.
  - 시험 페이지의 `window.seen()` 은 `document.cookie` 에서 `masc_l11_` 로 시작하는 것만 준다.
  - `window.echo()` 는 요청이 실어 보낸 쿠키 중 `masc_l11_` 로 시작하는 것만 돌려준다.
- 시험 호스트는 `127.0.0.1:18777` 과 `a.l11.localhost:18777` 이다. Chromium 은 `*.localhost` 를 loopback 으로 보낸다.
- 쿠키는 모두 `masc_l11_` 로 시작한다. c11 의 `__Host-masc_l11_c11` 하나만 예외이고, 브라우저가 거절해 남지 않았다.
- 쿠키를 지울 때는 늘 이름·도메인·경로를 정확히 줬다.
  - 프로필 전체를 지우는 명령(`Network.clearBrowserCookies`, `browserContextId` 없는 `Storage.clearCookies`)은 부르지 않았다.
  - 프로필의 쿠키를 모두 읽는 `Network.getAllCookies` 도 부르지 않았다.
- 결과에는 시험 쿠키의 이름·속성과 시험이 쓴 값만 있다.
  - a0 에서 `127.0.0.1` 에 시험 쿠키가 아닌 쿠키가 하나 보였다. 그 쿠키는 개수만 적었다.
- 권한 창이나 대화상자를 여는 호출은 없다.

## 명령과 시각

a, b, b-clean 은 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다.
c 는 `cat cookie-write.js probe-cookie-c.mjs | ego-browser nodejs > result-cookie-c.jsonl 2>&1` 로 돌렸다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-cookie-a.mjs` | `result-cookie-a.jsonl` | 08:19:03Z |
| `probe-cookie-b.mjs` | `result-cookie-b.jsonl` | 08:20:19Z |
| `probe-cookie-b-clean.mjs` | `result-cookie-b-clean.jsonl` | 08:20:40Z |
| `probe-cookie-c.mjs` | `result-cookie-c.jsonl` | 08:53:22Z |

## 1. setCookie 가 받는 것과 거절하는 것 (a1~a4, a6, b3)

`url` 만 주고 `domain` 을 주지 않으면 그 호스트에만 가는 쿠키(host-only)가 된다. `getCookies` 의 `domain` 은 앞에 점이 없는 호스트다(a1).

| 넣은 것 | 답 | 남았나 |
|---|---|---|
| 이름·값·`url`·경로 | `{success: true}` | 남았다. 페이지와 요청이 모두 봤다 |
| `httpOnly` | `{success: true}` | 요청에는 가고 `document.cookie` 에는 없다 |
| `expires` 와 `sameSite: "Strict"` | `{success: true}` | `session: false`, `expires` 는 소수 초 |
| `secure` (http `127.0.0.1`) | `{success: true}` | 남았다 |
| `sameSite: "None"` 과 `secure` | `{success: true}` | 남았다 |
| `sameSite: "None"`, `secure` 없음 | `{success: false}` | 없다. 던지지 않는다 |
| 같은 이름·경로로 다시 | `{success: true}` | 값이 바뀌었다(a3) |
| 값에 제어 문자, `;` | 던짐 `Sanitizing cookie failed` | 없다. 오류에 값이 없다 |
| 값에 빈칸·쉼표·따옴표 | `{success: true}` | 남았다 |
| 이름에 빈칸과 `=` | 던짐 `Sanitizing cookie failed` | 없다 |
| 이름과 값을 합쳐 4,109 바이트, 5,016 바이트 | 던짐 `Sanitizing cookie failed` | 없다 |
| 이름과 값을 합쳐 4,096 바이트 | `{success: true}` | 남았다(b3) |
| 이름 309 바이트 | `{success: true}` | 남았다(b3) |
| 경로 1,024 바이트 | `{success: true}` | 남았다(b3) |
| 경로 1,101 바이트 | 던짐 `Sanitizing cookie failed` | 없다(b3) |
| 지난 `expires` | `{success: true}` | 없다 |
| `url: "about:blank"` | 던짐 `URL must have scheme http or https` | 없다(a6) |

masc 는 이름 256 바이트(지워진 Firefox 와 같다), 이름과 값을 합쳐 4,096 바이트, 경로 1,024 바이트를 넘으면 브라우저에 보내기 전에 거절한다.

## 2. 지우기 (a5, b2, b4)

| 부른 것 | 결과 |
|---|---|
| `{name, domain: "127.0.0.1", path: "/"}` | 그 쿠키만 지웠다 |
| 같은 이름이 `/` 와 `/sub` 에 있을 때 `{name, domain, path: "/"}` | `/` 만 지웠다. `/sub` 는 남았다(b2) |
| `{name, url: <페이지 주소>}` | 그 이름과 호스트의 쿠키를 경로와 상관없이 지웠다. 페이지가 보지 않는 `/sub` 쿠키도 지웠다(a5) |
| 아무도 없는 이름 | `{}` 로 답했다 |
| `{name}` 만 | 던짐 `At least one of the url and domain needs to be specified` |
| 상위 도메인 쿠키를 `domain: "l11.localhost"` 로 | 지우지 않았다. `domain: ".l11.localhost"` 로는 지웠다(b4) |

그래서 masc 의 `delete_cookie` 는 `getCookies` 가 준 이름·도메인·경로를 그대로 넘겨 하나씩 지운다.

b4 는 `domain: "l11.localhost"` 로 `masc_l11_dom2` 를 썼다. 브라우저는 그 쿠키를 `l11.localhost` 호스트의 쿠키로 남겼고 `a.l11.localhost` 는 보지 않았다. b 의 마지막 정리는 그 쿠키를 찾지 못했다. b-clean 이 `l11.localhost` 주소로 찾아 지웠다.

## 3. 쿠키는 SDK 프로세스가 끝나도 남는다 (b1)

a 가 끝나기 전에 session 쿠키 `masc_l11_b` 를 남겼다. 다음 SDK 프로세스의 다른 task space(20)에서 `getCookies` 와 요청이 그 쿠키를 봤다.
RFC §2 에서 CDP 로 바꾼 다른 설정(화면 크기, Intl, 요청 차단)은 SDK 프로세스와 같이 끝났다. 쿠키는 ego 프로필에 쓰인다.

## 4. 바쁜 페이지 (a7, c14)

페이지에서 3초 반복문을 걸고 200 ms 뒤에 호출을 시작했다. 시작부터 각 호출이 끝날 때까지의 시간(ms)이다.

| 회 | `evaluate` | `setCookie` | `getCookies` | `deleteCookies` |
|---|---|---|---|---|
| a 1 | 2804 | 2 | 2805 | 2810 |
| a 2 | 2801 | 2 | 2802 | 2805 |
| a 3 | 3431 | 3433 | 3436 | 3440 |

c14 는 masc 의 쓰기 스크립트 전체를 잰다. 쓰기는 2,806 ms·2,802 ms, 이어서 부른 지우기는 8 ms·8 ms 였다. 스크립트가 먼저 페이지 주소를 `evaluate` 로 읽어서, 페이지가 풀릴 때까지 기다린다.

## 5. masc 스크립트를 실제 Page 에서 돌렸다 (c)

[`cookie-write.js`](cookie-write.js) 는 `lib/browser_ego_cookie_write.ml` 의 `script` 를 그대로 옮긴 글이다. `probe-cookie-c.mjs` 가 그 뒤에 붙어 시험 단계를 돌린다.

| 단계 | 결과 |
|---|---|
| c1 새 session 쿠키 | `domain: "127.0.0.1"`, `session: true`, `replaced: false`. 답에 값이 없다 |
| c2 같은 이름·경로로 다시 | `replaced: true` |
| c3 `secure`·`httpOnly`·`Strict`·3,600초 | `session: false`, 정수 `expiry`, `sameSite: "Strict"` |
| c4 페이지와 요청 | 페이지는 c1 만, 요청은 c1 과 c3(httpOnly) 을 봤다 |
| c5 페이지가 보지 않는 경로 `/sub` | 그 경로로 다시 읽어 답했다 |
| c6 하나 지우기 | `deleted: [127.0.0.1 /]` |
| c7 같은 이름이 `/`, `/page`, `/sub` 에 | 페이지가 보는 `/` 와 `/page` 를 지웠다. `/sub` 는 남았다 |
| c8 아무도 없는 이름 | `deleted: []` |
| c9 `SameSite=None`, `secure` 없음 | `before: true`, success false 라는 문장 |
| c10 값에 `;` | `before: true`, `Sanitizing cookie failed` |
| c11 `__Host-` 이름, `secure` 없음 | `before: true`, `Sanitizing cookie failed`. success false 가 아니라 던졌다 |
| c12 `about:blank` 탭 | `before: true`. CDP 를 부르지 않았다 |
| c13 `a.l11.localhost` 에 host 쿠키와 `.l11.localhost` 쿠키 | host 쿠키를 다시 쓰니 `replaced: true` 였다. 지우기는 둘 다 지웠다 |
| c14 바쁜 페이지 | 4절 |

- c10 이 값에 넣은 시험 문자열(`SECRET_L11`)은 결과에 없다.
- c9 의 문장은 첫 번째 c 뒤에 고쳤다. 첫 문장은 `__Host-` 이름도 success false 를 준다고 적었는데, c11 은 던졌다.

## 남긴 쿠키와 정리

- a 는 a8 에서 `masc_l11_b` 만 남기고 나머지를 지웠다. b 가 그것을 지웠다.
- b 는 `masc_l11_dom2` 를 남겼다(2절). b-clean 이 지웠다.
- c 의 마지막 단계는 두 호스트의 `/page` 와 `/sub/page` 에서 `masc_l11_` 쿠키를 찾아 지우고 다시 읽었다. 두 번 모두 남은 것이 없었다.

## 재지 않은 것

- 운영자 탭에서 본 것. b1 은 다른 task space 가 앞 space 의 쿠키를 보는 것만 확인했다. 같은 프로필이라 운영자 탭도 본다고 본다.
- secure 가 아닌 주소의 `secure` 쿠키. 시험 호스트는 모두 loopback 이라 secure 로 친다.
- https 사이트와 운영자의 실제 로그인 쿠키. 일부러 건드리지 않았다.
- `__Secure-` 이름, partitioned 쿠키. a1 의 `getCookies` 필드에는 `partitionKey` 가 없었다.
- 페이지가 이동하는 도중의 쓰기.

## masc 와의 관계

masc 서버의 `page.set_cookie`·`page.delete_cookie` 단계를 통째로 돌리지는 않았다. c 가 그 단계가 쓰는 글을 그대로 돌렸다.

- `test/test_browser_ego_cookie_write.cjs` 는 같은 글을 위의 측정대로 움직이는 가짜 쿠키 저장소로 돌린다.
- `test/test_browser_ego_peer.ml` 은 masc 가 그 답을 읽어 다시 만드는지 본다. 모양이 다른 답은 결과를 모르는 실패로 돌린다.
