# Browser CSS 범위 읽기 · 짧은 선택자 · live BiDi 이동과 활성화 실측

2026-10-22, macOS, Firefox 158.0.1. 두 가지를 돌렸어요.

## 1. 공개 페이지의 elements 크기 (`measure.mjs`)

Firefox 를 headless 임시 프로필로 띄우고 WebDriver BiDi 로 직접 붙었어요.
`https://en.wikipedia.org/wiki/OCaml` 에서 main(48415e079c7)의 요소 스크립트와
이 스택의 스크립트를 같은 탭에서 실행했어요. 원본 값은 `wikipedia-ocaml-elements.json` 이에요.

| 읽기 | 응답 크기 | 돌려준 개수 | 선택자 평균 / 최대 |
|---|---|---|---|
| main | 90,328 B | 200 / 744, 잘림 | 295 B / 402 B |
| 스택, within 없음 | 42,389 B | 200 / 744, 잘림 | 55 B / 198 B |
| `within: #vector-toc` | 6,629 B | 32, 안 잘림 | 41 B / 76 B |
| `within: nav` | 11,256 B | 51, 안 잘림 | 63 B / 198 B |

main 은 컨트롤 744개 중 앞 200개만 돌려줘요. 나머지 544개는 선택자를 얻을 길이 없었어요.
`within` 을 주면 그 영역의 컨트롤만 오고, 200개 안에 들어오면 잘리지 않아요.

다시 재는 법:

```
node measure.mjs <firefox> <main 의 browser_page_script.ml> <스택의 browser_page_script.ml> <url> [within ...]
```

## 2. 실제 Firefox 와 masc-browser-host (`test/test_browser_bidi_host.py`)

이 스택 head 로 빌드한 `masc_browser_host.exe` 를 임시 프로필 Firefox 에 붙였어요.
서버 역할은 테스트의 Python fixture 가 해요. 결과는 `host-test-outcome.json`(`passed: true`)과
`host-test-receipts.json` 이에요.

- `page.elements within=#message`: `withinMatches` 1, `total` 0. 그 안의 버튼은 hover 전이라 숨어 있어요.
- `within=#long`: 버튼 자신이 매치돼 1개. 선택자는 `#long` 이에요.
- `within=#message((`: `invalid_css_selector` 로 거절됐어요.
- 요소 목록의 `#react` 선택자로 click 했고, 페이지가 클릭을 받았어요.
- `page.goto` 를 운영자가 연 탭 1에 보내면 `effectPhase: not_started` 로 거절돼요. 이 연결이 연 탭 5는 `?went=1` 로 옮겨졌어요.
- 뒤에 있던 탭 2에 `activate_tab` 을 보낸 뒤, 활성 탭은 2 하나였어요. 그 직후 캡처가 `activated-tab.png` 예요.

이 실행은 Claude 샌드박스 밖에서만 Firefox 가 떠요. 운영 중인 Firefox 와 live 서버에는 닿지 않았어요.
