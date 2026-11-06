# 브라우저 기능 표 채우기 (capability parity)

상태: 초안. 구현 전에 운영자 확인이 필요하다. 아래 "열린 결정"이 답을 기다린다.
기준 코드: `lib/browser_capabilities.ml` (main `a3e12df277e`, 2026-10-22).

## 목표

`Browser_capabilities.catalog` 가 돌려주는 표에서 `Unsupported` 칸을 줄인다.
백엔드는 다음과 같다.

| 백엔드 | 코드 이름 | 실제 브라우저 |
|---|---|---|
| 확장 | `Connected Web_extension` | 운영자의 Zen/Firefox 에 설치된 확장 |
| BiDi | `Connected Webdriver_bidi` | 운영자의 Firefox 에 붙은 WebDriver BiDi |
| ego | `Connected Ego_task_space` | ego lite 의 task space |

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
| 우클릭, 가운데 클릭 | BiDi `input.performActions` 의 `pointerDown/Up.button`. 지금 `browser_pointer.ml` 은 `button 0` 만 쓴다 | 스펙 문장은 읽지 못했다. 2026-10-22 에 Firefox 158(헤드리스)에 `input.performActions` 를 직접 보내 확인했다: 버튼 0 은 `click`, 1 은 `auxclick`, 2 는 `contextmenu` 와 `auxclick` 이 왔고 모두 `isTrusted` 였다 |
| 터치 | BiDi `pointerType` 에 touch 가 있는지 | 스펙에서 못 읽었다 |
| 창 크기 | BiDi `browsingContext.setViewport` | 명령 이름은 확인했다. 인자는 못 읽었다 |
| 창 목록·만들기·닫기 | BiDi `browsingContext.create` | 명령 이름만 확인했다. `type` 값(tab/window)은 못 읽었다 |
| 클립보드 | BiDi 스펙에 명령이 없다 | 브라우저별 우회가 필요할 수 있다. 미정 |

출처: <https://w3c.github.io/webdriver-bidi/> (2026-10-22 확인, 명령·이벤트 이름 목록만 읽음).

## 이미 있는 기능에서 ✗ 인 칸

위 표에 없는 칸이다. 이 칸들은 "구조상 안 된다"인지 "안 만들었다"인지 먼저 가른다.

- 확장의 URL 이동, 글자 입력, 더블클릭, hover, drag: 구조상 안 된다. 확장 대신 BiDi 로 붙이는 길이 있다.
- BiDi 의 업로드, 다운로드: BiDi 연결에 없다.
- BiDi·ego 의 줌: 확장 전용이다.

## 새 백엔드

표의 칸이 아니라 백엔드 자체를 추가하는 일이다. 이 문서의 1차 범위에 넣지 않는다.

- ego-lite: live 연결 `ego_task_space` 가 읽기·탭·입력·대화상자·업로드·다운로드 목록·사람에게 넘기기를 한다(RFC-browser-live-ego). 프레임은 frame 경로 없이 snapshot 의 ref 와 role·글 대상으로 다룬다. 터치·줌·뷰포트·문서 원본은 하지 않는다.
- Safari: 코드가 "어댑터 없음"이라고 명시하고 있다.

## 측정 하네스 (먼저 만든다)

1. `catalog` 를 백엔드별로 찍어 `Available / Conditional / Unsupported` 개수와 칸 목록을 출력하는 도구.
2. 연산마다 실제 브라우저 fixture 를 돌려 통과/실패를 기록하는 도구.
3. 표의 값과 fixture 결과가 어긋나면 실패한다. 표가 거짓말하는 상태를 막는다.

화면 문구, 줄 배치, 행 순서를 고정하는 테스트는 만들지 않는다.

## 실행 단위 (스택 순서)

한 단위는 PR 하나이고 20k 토큰 안에서 끝낸다.

1. 이 문서.
2. 표 출력 도구와 현황 기록.
3. 우클릭, 가운데 클릭 (BiDi `button` 1, 2).
4. 창 크기, 창 목록·만들기·닫기.
8. 터치.
9. 클립보드.
10. BiDi 연결에 업로드, 다운로드 넓히기.

### 진행 현황 (2026-10-22)

| 단위 | 상태 | PR |
|---|---|---|
| 3 우클릭·가운데 클릭 | 올림 (BiDi) | #45111 |
| 4 창 크기 | `set_viewport` 만 올림 (BiDi) | #45114 |
| 탭 기록·닫기 (표의 `back`, `forward`, `reload`, `close_tab`) | 올림 (BiDi, 이 연결이 연 탭만) | #45115 |
| 8 터치 | 올림 (BiDi) | #45116 |
| 2 표 출력 도구 | 도구는 안 만들고, 이 표의 수치를 손으로 한 번 뽑았다(아래) | 이 문서 |
| 4 창 목록 | 올림 (BiDi 의 `tabs.list` 행에 `windowId`). 만들기·닫기는 아직 | #45118 |
| 9 클립보드 | 안 함. 아래 | |
| 10 BiDi 의 업로드·다운로드 | 안 함. 아래 | |
| 창 만들기·닫기 | 안 함. 아래 | |

표 값(`Browser_capabilities.support` 를 세어 뽑은 수치, fixture 결과가 아니다). 스택 끝(#45116) 기준이다.
연산은 53개이고, `Unsupported` 는 확장 40, BiDi 27, Safari 53 이다(2026-10-22 에 실제로 세었다).

### 하지 않은 단위와 이유

- **클립보드(9)**: BiDi 스펙에 클립보드 명령이 없다(위 표). 운영자 브라우저의 클립보드를 읽으면
  운영자가 복사해 둔 비밀번호가 에이전트에게 간다. 열려면 승인 흐름을 먼저 정해야 한다.
- **창 만들기·닫기**: `Browser_lane.Action.t` 의 변형을 더해야 하고, `page.act` 를 나열하는 Add-on 모듈이 함께 바뀐다.
  창을 만들면 운영자 브라우저에서는 포커스를 가져간다. 에이전트 작업에서 탭으로 못 하는 일이 떠오르지 않아 만들지 않았다. 필요한 작업이 생기면 그때 연다.
- **BiDi 의 업로드·다운로드(10)**: 업로드는 `input.setFiles` 가 있지만 운영자 브라우저에 파일을 넣는 일이라
  `Upload_lease` 같은 승인 흐름이 먼저 필요하다.

### 남은 단위의 기본 방침

운영자의 실제 브라우저(연결된 BiDi, 확장)는 이 호스트가 모르는 로그인과 비밀 값을 갖는다.
아래는 이 구분으로 정한 기본값이고, 운영자가 뒤집을 수 있다.

- 창 목록·만들기·닫기: Firefox 158 의 BiDi `browser.getClientWindows`, `browsingContext.create` 의 `type: window`, `browsingContext.close` 가 돈다(프로브).
  `Browser_lane.Action.t` 에 창 동작을 더해야 해서 `page.act` 를 쓰는 Add-on 모듈 여럿이 바뀐다. 탭 정리와 같은 방침(이 연결이 만든 창만)으로 한다.

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

## 연산 경로 매핑: 클릭을 기준으로

클릭 한 번이 공개 도구에서 실제 브라우저까지 가는 길이다(main `a3e12df277e`에서 읽음). 다른 연산도 같은 모양이다.

| 단계 | 위치 | 하는 일 |
|---|---|---|
| 도구 스키마 | `config/tools/masc_browser_interact.toml` (`action` 열거) | 공개 인자를 정한다 |
| 해석 | `lib/browser_interaction.ml` `parse` | 문자열 `action` 을 타입으로 바꾼다. 마지막 `_ ->` 는 오류와 하드코딩된 이름 목록이다 |
| 타입 | `lib/browser_lane/browser_lane.ml` `interaction`, `lib/browser_lane/browser_pointer.ml` `gesture` | 포인터 단추 번호가 `browser_pointer.ml:45` 에 `Int 0` 으로 고정돼 있다 |
| 라이브 확장 | `connectors/browser/extension/background.js` | DOM `element.click()` 만 한다. 신뢰된 입력이 아니다 |
| 라이브 BiDi | `lib/browser_bidi_peer.ml` → `input.performActions` | `Browser_pointer.input_sources` 를 보낸다 |
| 표 | `lib/browser_capabilities.ml` | `Right_click`, `Middle_click` 은 이미 연산 목록에 있고 `missing` 이다 |

프로토콜 값: BiDi `input.performActions` 의 단추는 0 왼쪽, 1 가운데, 2 오른쪽이고, Firefox 158 에서 이벤트까지 확인했다(위 표).

### 우클릭·가운데 클릭 설계 (단위 3)

- 새 단추 타입 `Browser_pointer.button = Primary | Middle | Secondary` 를 만든다. 새 `gesture` 생성자(`Right_click` 등)를 늘리지 않고 `Click` 이 단추를 값으로 갖게 한다.
  - 이유: 어댑터(`bidi_peer.ml:259-264`)가 생성자를 나열하고 `Click` 을 기본으로 둔다. 새 `*_at` 생성자를 추가하면 컴파일은 되고 왼쪽 클릭이 나간다. 값으로 들고 있으면 모든 `Click` 자리가 컴파일 오류로 드러난다.
- 공개 인자는 새 `action` 을 늘리지 않고 `click`, `click_at` 에 선택 인자 `button`(`primary` 기본, `middle`, `secondary`)을 더하는 쪽을 권한다. `action` 열거가 이미 16개다. 확정은 열린 결정에 넣는다.
- 확장은 `Unsupported` 로 둔다. DOM 클릭으로 우클릭을 흉내 내지 않는다(코드가 이미 "신뢰된 hover 는 안 된다"고 적은 것과 같은 이유).
- 막히는 곳: `Browser_lane` 의 `interaction` 타입은 수백 모듈이 임포트한다. 이 타입을 바꾸면 로컬 단독 타입 검사가 신뢰되지 않아서, 단위 3 은 CI 의 `merge-compile` 로만 컴파일이 증명된다. 그래서 단위 3 은 한 번에 쓰지 않고, 타입과 BiDi 어댑터와 표 변경(단위 3a), 프로브(3b)로 쪼갠다.
- 검증 방법: 실제 Firefox 에 `oncontextmenu`·`onauxclick` 핸들러를 가진 픽스처를 띄워 `isTrusted` 와 `event.button` 을 본다. 헤드가 있는 Firefox 에서 우클릭이 운영체제 메뉴를 띄우는지는 확인하지 못했다.

## 열린 결정

- 확장 백엔드의 ✗ 칸을 "구조상 안 된다"로 확정해도 되는가.
- Safari 를 이 목표에 넣는가, 별도 목표로 두는가.
- 클립보드는 보안상 에이전트에게 열어도 되는가. 열면 어떤 승인을 거치는가.
