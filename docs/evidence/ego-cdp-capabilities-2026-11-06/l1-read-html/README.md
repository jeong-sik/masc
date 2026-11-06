# L1 read mode html 시험 (2026-11-06)

[RFC-browser-ego-cdp-capabilities](../../../rfc/RFC-browser-ego-cdp-capabilities.md) §5 L1 의 확인이다.
ego 연결이 read mode html 에서 보내는 문서 스크립트를 ego 에서 그대로 돌렸다.

## 환경

- ego lite 0.6.2.7, Chromium 156.0.8078.74, macOS (MacBook M3 Max), Node v22.22.0, OCaml 5.5 toplevel
- 시작 시각: `run-started-at.txt` (2026-11-06T03:58:28Z)
- masc 서버를 거치지 않았다. `ego-browser nodejs` 를 직접 불렀다.
- 시험 전용 task space `masc-l1-read-html` 를 만들고 끝에 `finish({keep: []})` 로 닫았다(space 20).
- 페이지는 `python3 -m http.server 18768 --bind 127.0.0.1` 로 띄웠다.

## 스크립트를 만드는 방법

`build.sh` 는 OCaml toplevel 로 masc 소스를 직접 불러 스크립트 문자열을 만든다.

- `lib/browser_scene_script.ml` 와 `lib/browser_lane/browser_document.ml` 은 `#mod_use` 로 통째로 읽는다.
- `lib/browser_page_script.ml` 은 `Browser_lane` 에 기대서 혼자 읽히지 않는다. 문서 읽기가 쓰는 `parsed` 한 줄만 `sed` 로 뽑는다.
- `page_function` 의 감싸기, 답 한도 `8 MiB / 4`, step 본문은 `lib/browser_ego_peer.ml` 에서 옮겨 적었다. 이 세 곳은 소스가 바뀌면 같이 바꿔야 한다.
- `probe.template.mjs` 는 `lib/browser_ego_peer.ml` 의 `on_page`·`evaluate` 순서를 따른다. `page.evaluate(pageCall(fn, input))` 를 부른다.

## 명령

```sh
bash docs/evidence/ego-cdp-capabilities-2026-11-06/l1-read-html/build.sh . "$TMPDIR/l1"
(cd "$TMPDIR/l1/site" && python3 -m http.server 18768 --bind 127.0.0.1) &
ego-browser nodejs < "$TMPDIR/l1/probe.mjs" 2> result.json
```

ego 의 `console.log` 는 stderr 로 나온다. 저장한 `result.json` 은 원본에서 끝의 빈 줄 하나만 지웠다(839→838 바이트).
같은 `fn.js`(바이트 단위로 같음)를 03:49:48Z 에 한 번 먼저 돌렸고(space 19), 숫자가 모두 같았다.

## 결과

| 페이지 | 파일 크기 | 답 JSON | html | `htmlComplete` | 페이지의 `outerHTML` 과 같음 |
|---|---|---|---|---|---|
| `index.html` (`../probe-page.html`) | 559 B | 804 B | 582 B | true | 예 |
| `near.html` | 563 KB | 657,286 B | 576,086 B | true | 예 |
| `big.html` | 1,000 KB | 223 B | null (`document_html_exceeds_1_mib`) | false | — |

- html 은 doctype 없이 `<html>` 로 시작한다. 다른 연결의 html mode 와 같다.
- `near.html` 의 답을 masc 의 한 줄 답(`{ok, value: {label, answer}}`)으로 다시 감싸면 810,370 바이트다. ego 연결의 출력 한도 6,356,992 바이트 안이다.
- 문서 JSON 이 1 MiB 를 넘으면 페이지 안에서 html 을 버린다. 그래서 ego 답 한도(2 Mi UTF-16 단위)에 닿기 전에 끝난다.

## 이 시험이 보여 주지 않는 것

- masc 서버의 ego session 과정(`lib/browser_addon_live_ego.ml`)을 지나지 않았다. 그 길은 `test/test_browser_ego_peer.ml` 의 가짜 runner 시험과 `node --check` 시험이 맡는다.
- `documentLoading` 거절은 부르지 않았다. 세 페이지 모두 다 읽힌 뒤에 불렀다.
