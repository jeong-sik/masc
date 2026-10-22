# 브라우저 기능 표 채우기 (capability parity)

상태: 초안. 구현 전에 운영자 확인이 필요하다. 아래 "열린 결정"이 답을 기다린다.
기준 코드: `lib/browser_capabilities.ml` (main `a3e12df277e`, 2026-10-22).

## 목표

`Browser_capabilities.catalog` 가 돌려주는 표에서 `Unsupported` 칸을 줄인다.
표는 백엔드 4개 × 연산 53개다. 백엔드는 다음과 같다.

| 백엔드 | 코드 이름 | 실제 브라우저 |
|---|---|---|
| 확장 | `Connected Web_extension` | 운영자의 Zen/Firefox 에 설치된 확장 |
| BiDi | `Connected Webdriver_bidi` | 운영자의 Firefox 에 붙은 WebDriver BiDi |
| 자동화 | `Owned_gecko` | 서버가 띄우는 Firefox |
| Stagehand | `Owned_chromium` | 서버가 띄우는 Chromium |

"된다"의 기준은 표에 적힌 값이 아니라, 실제 브라우저에서 돌린 fixture 결과다.
표가 `Available` 이어도 fixture 가 통과하지 않으면 채운 것으로 세지 않는다.

## 칸을 세 종류로 나눈다

모든 칸을 ✅ 로 만들 수는 없다. 칸마다 아래 중 하나로 분류하고 이유를 적는다.

1. **구현한다.** 브라우저 프로토콜에 명령이 있고 우리 어댑터에 아직 없다.
2. **구조상 안 된다.** 그 백엔드의 구조가 막는다. `Unsupported` 로 두고 이유를 남긴다.
   - 확장은 신뢰된 입력(hover, drag, 글자 입력)을 만들 수 없다. 코드가 이미 이렇게 적고 있다.
   - 연결된 운영자 브라우저는 직접 URL 이동을 열어 두지 않기로 했다.
3. **측정이 먼저다.** 지금 표가 `Unsupported` 인 이유가 "안 만들어서"인지 "해 봤더니 실패해서"인지 구분되지 않는다.
   - 예: Firefox 의 HTML5 drop 은 "시험한 시나리오가 실패한다"고 코드에 적혀 있다.

## 모든 백엔드에 없는 연산

| 연산 | 프로토콜 근거 | 상태 |
|---|---|---|
| 우클릭, 가운데 클릭 | BiDi `input.performActions` 의 `pointerDown/Up.button`. 지금 `browser_pointer.ml` 은 `button 0` 만 쓴다 | 버튼 번호 규칙은 스펙에서 아직 못 읽었다 |
| 터치 | BiDi `pointerType` 에 touch 가 있는지 | 스펙에서 못 읽었다 |
| 창 크기 | BiDi `browsingContext.setViewport` | 명령 이름은 확인했다. 인자는 못 읽었다 |
| 창 목록·만들기·닫기 | BiDi `browsingContext.create` | 명령 이름만 확인했다. `type` 값(tab/window)은 못 읽었다 |
| 네트워크 읽기 | BiDi `network.beforeRequestSent`, `responseCompleted`, `fetchError` 이벤트 | 이름 확인 |
| 네트워크 가로채기 | BiDi `network.addIntercept`, `continueRequest`, `provideResponse`, `failRequest` | 이름 확인 |
| 콘솔 읽기 | BiDi `log.entryAdded` 이벤트 | 이름 확인 |
| 쿠키 | BiDi `storage.getCookies`, `setCookie`, `deleteCookies` | 이름 확인 |
| localStorage, sessionStorage | BiDi `storage` 모듈에는 없다 | 스크립트 실행으로 읽어야 한다. 방법은 미정 |
| 클립보드 | BiDi 스펙에 명령이 없다 | 브라우저별 우회가 필요할 수 있다. 미정 |

Chromium 쪽은 DevTools Protocol(`Input`, `Network`, `Runtime`, `Emulation`) 로 같은 일이 가능할 것으로 보이지만,
이 문서를 쓰는 시점에 공식 문서에서 명령 이름과 인자를 읽지 못했다. 구현 전에 읽는다.

출처: <https://w3c.github.io/webdriver-bidi/> (2026-10-22 확인, 명령·이벤트 이름 목록만 읽음).

## 이미 있는 기능에서 ✗ 인 칸

위 표에 없는 칸이다. 이 칸들은 "구조상 안 된다"인지 "안 만들었다"인지 먼저 가른다.

- 확장의 URL 이동, 글자 입력, 더블클릭, hover, drag: 구조상 안 된다. 확장 대신 BiDi 로 붙이는 길이 있다.
- BiDi 의 select, iframe, 다이얼로그, 업로드, 다운로드: 자동화 Firefox 에만 있다. 같은 Gecko 어댑터를 BiDi 연결에도 쓸 수 있는지 확인한다.
- Stagehand 의 select, iframe, 다이얼로그, 업로드, 다운로드: Chromium 어댑터에 없다.
- 자동화·Stagehand 의 줌: 확장 전용이다.

## 새 백엔드

표의 칸이 아니라 백엔드 자체를 추가하는 일이다. 이 문서의 1차 범위에 넣지 않는다.

- Chrome(실제 설치본): 열려 있는 PR #44483 이 Add-on 경로에서 증명하고 있다. 겹치지 않게 그 PR 이 먼저 들어온 뒤 다룬다.
- ego-lite: `addons/ego-browser` 는 스냅샷을 읽는 Add-on 이고 입력 백엔드가 아니다.
- Safari: 코드가 "어댑터 없음"이라고 명시하고 있다.

## 측정 하네스 (먼저 만든다)

1. `catalog` 를 백엔드별로 찍어 `Available / Conditional / Unsupported` 개수와 칸 목록을 출력하는 도구.
2. 연산마다 실제 브라우저 fixture 를 돌려 통과/실패를 기록하는 도구. 자동화 Firefox 와 Stagehand 는 서버가 띄우므로 CI 에서 돈다.
3. 표의 값과 fixture 결과가 어긋나면 실패한다. 표가 거짓말하는 상태를 막는다.

화면 문구, 줄 배치, 행 순서를 고정하는 테스트는 만들지 않는다.

## 실행 단위 (스택 순서)

한 단위는 PR 하나이고 20k 토큰 안에서 끝낸다.

1. 이 문서.
2. 표 출력 도구와 현황 기록.
3. 우클릭, 가운데 클릭 (BiDi `button` 1, 2 와 Chromium 의 같은 동작).
4. 창 크기, 창 목록·만들기·닫기.
5. 콘솔 읽기.
6. 네트워크 읽기, 이어서 가로채기.
7. 쿠키, 이어서 web storage.
8. 터치.
9. 클립보드.
10. Gecko 전용 칸(select, iframe, 다이얼로그, 업로드, 다운로드)을 BiDi 연결과 Chromium 으로 넓히기.

각 단위는 공개 도구 스키마(`config/tools/masc_browser_*.toml`), 어댑터, 표, fixture 를 같이 바꾼다.
표만 바꾸고 어댑터가 없는 변경, 어댑터만 만들고 표를 안 바꾸는 변경은 받지 않는다.

## Add-on 스택과의 관계

브라우저 Add-on 스택(#44168 계열 54층)은 2026-10-22 16:59 KST 에 병합됐다.
스택은 `lib/browser_capabilities.ml` 과 `browser_of_string` 을 바꾸지 않았다. 이 표의 값은 그대로다.
바뀐 것은 어댑터의 위치다. 공개 브라우저 도구(`BrowserTabs`, `BrowserInteract` 등)는 이제
설치된 Add-on 으로 들어가고(`lib/tool_misc.ml` 의 `Browser_addon_tools.handle`, #44341),
브라우저 실행은 Add-on 워커(`bin/masc_browser_addon_worker.ml`, `lib/browser_addon_*`)가 한다.

그래서 각 단위의 첫 일은 "그 연산을 지금 어느 모듈이 실행하는가"를 코드에서 찾는 것이다.
이 문서는 그 위치를 아직 매핑하지 않았다. 매핑 없이 표의 `Unsupported` 를 바꾸지 않는다.

또 하나의 선행 조건: 라이브 브라우저는 서버가 Add-on 선언을 갖고 있을 때만 호스트 폴링에 응답한다
(2026-10-22 사고, #45072). 기능 단위의 fixture 는 Add-on 이 붙은 상태에서 돌아야 한다.

## 열린 결정

- 확장 백엔드의 ✗ 칸을 "구조상 안 된다"로 확정해도 되는가.
- Chrome, ego-lite, Safari 를 이 목표에 넣는가, 별도 목표로 두는가.
- 클립보드는 보안상 에이전트에게 열어도 되는가. 열면 어떤 승인을 거치는가.
