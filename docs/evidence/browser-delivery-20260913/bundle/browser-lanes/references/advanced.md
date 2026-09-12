# 고급 브라우저 조작

## 프레임

`BrowserRead mode=frames`에서 바깥 frame selector를 관측한다. 그 값을 `framePath`
배열에 넣어 안쪽 frames를 읽고, 필요한 깊이까지 바깥→안쪽 순으로 이어간다.
같은 경로의 `text`와 `elements`를 읽은 뒤 해당 탭·프레임에서 조작한다.

`framePath`는 automation의 `BrowserRead` text/elements/frames 읽기와
`BrowserAct` 요소·스크롤 조작에 사용한다. `BrowserInteract`는 최상위 문서 전용이며
`framePath`를 받지 않는다.
탭 이동, 히스토리, JS 대화상자와 screenshot에는 넣지 않는다. screenshot은
최상위 viewport를 캡처하므로 스크롤한 프레임의 입력란이 화면 밖일 수 있다.

## JavaScript 대화상자

alert/confirm/prompt를 여는 클릭은 실제로 대화상자를 연 뒤 오류를 반환할 수도 있다.
클릭을 반복하지 말고 `BrowserRead mode=dialog`로 현재 대화상자를 확인한다.
`BrowserAct accept_dialog` 또는 `dismiss_dialog`를 사용하며 prompt 입력은
`accept_dialog`의 `text`로 전달한다. 처리 후 페이지에서 결과를 확인한다.
HTML `<dialog>`와 OS 파일 선택창은 이 JS 대화상자 계약에 포함되지 않는다.

## 파일 선택과 업로드

`BrowserAct upload`는 관측된 `input[type=file]`에 Keeper가 읽을 수 있는 파일을
선택한다. `paths`는 자신의 sandbox에서 실제로 읽을 수 있는 경로다. 호스트의
임의 경로를 sandbox 경로로 가장하거나 다른 사용자의 파일로 대체하지 않는다.

파일 선택만 요청됐다면 선택 결과를 확인하고 멈춘다. 제출·업로드가 요청된 경우에는
허용된 대상에 실제로 제출하고 수신 결과를 확인한다. 선택 성공은 전송 완료가 아니다.

파일을 생성할 때 요청된 공백·마지막 LF까지 보존한다. `Write.bytes_written`이
기대값과 다르면 실제 인자를 확인한다. 바이트 수가 같아도 내용·해시 확인 없이
정확한 파일이라고 단정하지 않는다. 예를 들어 51바이트를 요청했는데 50바이트가
생성됐고 그대로 전송됐다면 **전송 보존은 성공, 요청한 파일 내용은 실패**다.
기대값을 바꿔 통과시키거나 요청되지 않은 줄바꿈을 자동 추가하지 않는다.

## 다운로드

현재 스키마가 지원할 때 `BrowserRead mode=downloads`를 명시적 automation
`tabId`로 호출한다. pending/completed/canceled/interrupted 등 반환된 상태를 따른다.
클릭·파일명·디렉터리 존재만으로 완료를 추측하지 않는다. 완료 상태와 파일 증거가
다르면 그대로 보고하며, 사용자의 실제 다운로드 폴더를 광범위하게 탐색하지 않는다.

공식 계약: [WebDriver](https://www.w3.org/TR/webdriver/),
[WebDriver BiDi](https://w3c.github.io/webdriver-bidi/),
[CSS selector의 escape](https://developer.mozilla.org/en-US/docs/Web/API/Document/querySelectorAll).
