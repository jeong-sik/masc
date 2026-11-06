# L6 요청 차단 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L6 의 확인이다.
ego 연결의 block_requests·unblock_requests 가 기대는 `Network.setBlockedURLs` 를 쟀다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space 에서 돌렸다(42~45). 모두 시험 끝에 `finish({keep: []})` 로 닫았다.
- [`page.html`](page.html) 를 `index.html` 로 두고, [`frame.html`](frame.html), [`x.txt`](x.txt) 와 함께 `python3 -m http.server 18773 --bind 127.0.0.1` 로 띄웠다.
- 다른 호스트는 `localhost`, `a.localhost`, `blocked.localhost` 처럼 `*.localhost` 를 썼다. Chromium 은 이 이름들을 루프백으로 푼다.
- 요청이 갔는지는 `fetch(url, {mode: "no-cors"})` 로 봤다. 요청이 가면 opaque 답으로 끝나고, 브라우저가 막으면 `TypeError: Failed to fetch` 가 난다.
- b·c 는 요청이 왜 실패했는지 보려고 `Network.enable` 을 불렀다. masc 는 부르지 않는다. a 와 d 는 부르지 않았다.
- 권한 창이나 대화상자를 여는 호출은 없다.

## 명령과 시각

모두 `ego-browser nodejs < <probe> > <result> 2>&1` 로 돌렸다. 결과 파일 첫 줄의 `[ego-browser:notice]` 는 ego 업데이트 안내다.
시각은 결과 파일 마지막 줄의 시각(UTC)이다. 결과 파일 끝의 빈 줄 하나는 저장소 공백 검사 때문에 지웠다.

| probe | 결과 | 끝난 시각 |
|---|---|---|
| `probe-block-a.mjs` | `result-block-a.jsonl` | 12:50:51Z |
| `probe-block-b.mjs` | `result-block-b.jsonl` | 12:51:31Z |
| `probe-block-c.mjs` | `result-block-c.jsonl` | 12:52:05Z |
| `probe-block-d.mjs` | `result-block-d.jsonl` | 13:02:19Z |

## 1. urlPatterns 는 그 호스트만 막는다 (a)

`Network.setBlockedURLs({urlPatterns: [{urlPattern: "*://blocked.localhost:*/*", block: true}]})` 를 `Network.enable` 없이 불렀다.

| 요청 | 결과 |
|---|---|
| `blocked.localhost` | 막힘 |
| `blocked.localhost` 의 질의·해시가 붙은 주소 | 막힘 |
| `sub.blocked.localhost` | 감 |
| `other.localhost` | 감 |
| `127.0.0.1` 주소의 질의에 `http://blocked.localhost/` 가 든 것 | 감 |

deprecated 인 `urls: ["*://blocked.localhost:*/*"]` 도 견줬다(a 의 F). 마지막 줄의 요청도 막았다.
`*` 가 주소 문자열 어디에나 맞아서다. 그래서 masc 는 `urlPatterns` 를 쓴다.

## 2. 포트 (b 의 G·H)

이유는 `Network.loadingFailed` 의 `blockedReason` 으로 봤다. 막힌 요청은 `inspector` 였다.

| 패턴 | `:18773` | 기본 포트 |
|---|---|---|
| `*://blocked.localhost:*/*` | 막힘 | 막힘 |
| `*://blocked.localhost/*` | 감 | 막힘 |

막지 않은 `free.localhost` 의 기본 포트 요청은 `net::ERR_CONNECTION_REFUSED` 였다. 위 기본 포트의 "막힘" 은 연결 실패가 아니다.
masc 는 호스트마다 `*://<host>:*/*` 하나를 보낸다.

## 3. 다시 부르면 목록이 바뀐다 (a 의 B·C)

`blocked.localhost` 를 막은 뒤 `other.localhost` 만 넣어 다시 불렀다. `blocked.localhost` 요청이 다시 갔다.
setBlockedURLs 는 그 Page 의 목록을 통째로 바꾼다.
그래서 masc 스크립트는 SDK 프로세스 안에 Page label 마다 막은 호스트를 두고, 부를 때마다 합친 목록을 보낸다.
두 호스트를 같이 넣은 목록은 새로고침 뒤에도 남았다.

## 4. 하위 요청만 막힌다 (a, b 의 I, c)

| 요청 | 결과 |
|---|---|
| 페이지의 fetch | 막힘 |
| 이미지 | 막힘(`type: Image`, `inspector`) |
| favicon | 막힘 |
| 같은 origin iframe 안의 fetch | 막힘 |
| 다른 site(`localhost`) iframe 안의 fetch | 감 |
| `page.goto` 로 막은 호스트로 이동 | 문서가 열림(본문 `hello`) |
| 페이지 스크립트의 `location.assign` 으로 이동 | 문서가 열림 |
| 막은 호스트의 문서를 연 iframe | 열림 |

이동(navigation)은 막히지 않는다. 다른 site 의 iframe 은 자기 프로세스에서 돌아서 Page 의 CDP 세션이 그 요청을 보지 못한다.
지워진 automation Firefox 의 block_requests 는 "그 탭과 frame 의 요청" 을 막았다. ego 는 범위가 좁다. masc 는 답과 도구 설명에 이 범위를 적는다.

## 5. masc 스크립트를 실제 Page 에서 돌렸다 (d)

[`block.js`](block.js) 는 `lib/browser_ego_peer.ml` 의 `request_block_script` 와 같은 글이다. `probe-block-d.mjs` 가 그 글을 앞에 붙여 돌렸다.

| 단계 | 답 | p1 의 요청(a, b, c) |
|---|---|---|
| `a.localhost` 차단 | `blocked: [a.localhost]` | |
| `b.localhost`, `a.localhost` 차단 | `blocked: [a.localhost, b.localhost]` | 막힘, 막힘, 감 |
| 같은 space 의 다른 Page(p2) | | 감, 감, 감 |
| p1 을 다른 site(`localhost`)로 이동한 뒤 | | 막힘, 막힘, 감 |
| 해제 | `unblocked: 2` | 감, 감, 감 |
| 다시 해제 | `unblocked: 0` | |

차단은 그 Page 에만 걸렸고, 다른 site 로 이동해도 남았다.
새 SDK 프로세스에서 차단이 사라지는 것은 RFC §2 의 첫 측정([README](../README.md))에서 확인했다.

## masc 와의 관계

masc 서버의 `page.block_requests` 단계를 통째로 돌리지는 않았다. d 가 그 단계의 스크립트 글을 그대로 돌렸다.
`test/test_browser_ego_page_management.cjs` 는 같은 스크립트를 가짜 Page 로 돌려 합치기, Page 별 목록, 해제 개수, CDP 오류 때 목록을 바꾸지 않는 것을 본다.
