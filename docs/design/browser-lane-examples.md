# Browser Lane 사용 흐름

Browser는 사이트 구분 없이 페이지를 읽는 공통 도구다. Keeper에 보이는
이름은 `BrowserTabs`, `BrowserRead`, `BrowserSession`, `BrowserGoto`,
`BrowserAct`, `BrowserInteract`이며, 등록 이름은 각각 `masc_browser_tabs`, `masc_browser_read`,
`masc_browser_session`, `masc_browser_goto`, `masc_browser_act`,
`masc_browser_interact`다.

## 연결

Browser 의 출처는 `live` 하나이고, ego lite 의 task space 가 그 연결이다. TUI에서는
`:` → `go Browser Lane`으로 연다.

## 설정과 켜고 끄기

browser 출처는 Lane Add-on 패키지 `browser-ego` 와 그 worker 다. `runtime.toml` 의
`[browser.live.ego]` 표는 출처를 어떻게 띄울지만 담는다.

출처를 켜고 끄는 것은 선언(`browser-ego.toml`)의 최상위 `enabled` 하나다.
TUI 의 Lanes 화면에서 `browser-ego` 패키지 줄을 골라 선언 편집기로 바꾸거나, 웹 All Lanes
의 그 패키지 상세에서 바꾼다([package activity](../guides/lane-package-activity.md)). 표가 없으면
선언은 시작하지 못하고, 패키지 줄이 그 이유를 보여 준다.

`masc browser-lane-setup --mode ego --base-path /path/to/workspace` 가 이 표를 쓴다.
서버를 다시 띄워야 표를 읽는다.

표의 값은 worker 가 붙을 때 읽으므로, 값을 바꾼 뒤에는 서버를
재시작하고 기존 설치를 detach 한 뒤 다시 붙인다. All Lanes 의 browser 줄은 그 lane 의
출처 중 켜진 선언이 있는지와, 관측한 연결 수를 따로 보여 준다.
연결이 보인다는 표시는 브라우저 프로세스의 정상 동작을 보장하지 않는다.

## 열린 업무 화면에서 근거 찾기

TUI의 `y` 관측이 주어졌으면 그 clientId·tabId·URL과 선택 영역에서 이어간다.
관측이 없는 “열어둔 PR에서 실패한 CI 원인을 확인해줘” 같은 요청이면 탭 목록에서
해당 제목과 URL을 찾는다. 배열 순서로 id를 추측하지 않는다.

```json
BrowserTabs {"lane":"live"}
BrowserRead {"lane":"live","clientId":<관측한 UUID>,"tabId":73,"maxChars":12000}
```

위 `73`은 예시이며 실제 첫 호출이 반환한 id를 사용한다. 읽은 URL과
오류 내용을 연결해 설명한다. 목록에 있다는 사실만으로 페이지를 읽었다고
하지 않는다. 현재 렌더된 내용에 로그가 없으면 확인한 범위를 명시한다.

같은 흐름을 이슈, 문서, 대시보드, 대화 페이지에 쓴다. 사이트별 레인이
필요하지 않으며, 업무에 필요한 탭만 선택하면 된다.

## 여러 페이지 비교

“열어둔 요구사항 문서와 구현 설명의 차이를 찾아줘”라면 `BrowserTabs`에서
두 페이지를 찾고 각각의 id로 `BrowserRead`를 호출한다. 읽기 결과를 URL별로
구분해 차이와 근거를 작성한다. `truncated=true`이면 필요에 따라 `maxChars`를
늘려 다시 읽을 수 있다(최대 100,000 Unicode code points). 가상 스크롤이나
접힌 영역의 내용까지 포함된다고 가정하지 않는다.

## 직접 URL을 열어 조사

ego 연결은 `open_tab` 으로 작업용 탭을 연다.

```text
BrowserTabs {"lane":"live"}
BrowserAct {"lane":"live","clientId":<관측한 UUID>,"action":"open_tab","url":"https://ocaml.org/releases"}
BrowserRead {"lane":"live","clientId":<관측한 UUID>,"tabId":<반환된 id>,"maxChars":12000}
```

여러 Keeper가 동시에 조사할 수 있으므로 작업별 탭을 열고, 반환된 `tabId`를
읽기와 조작에 계속 사용한다. 같은 탭의 URL을 바꿀 때는 `BrowserGoto`에도
해당 id를 전달한다. ego 연결은 task space 가 관리하는 페이지만 이동한다. 이동 후 실제 읽기
결과로 내용을 확인하고 출처를 붙인다. 작업이 끝나면 `BrowserAct close_tab`으로
해당 탭을 닫는다.

## 입력과 화면 확인

`BrowserRead mode=elements`로 현재 컨트롤의 selector, 상태, 선택 항목의
실제 value를 관측한다. 그 결과로 `BrowserInteract`의 click, fill, select_option,
scroll을 호출하고 다시 읽어 결과를 확인한다. `BrowserAct`는 탭 열기·닫기,
back, forward, reload, 대화상자, 업로드처럼 브라우저 수준 동작만 맡는다.

```text
BrowserRead {"lane":"live","clientId":<id>,"tabId":<tab>,"mode":"elements"}
BrowserInteract {"clientId":<id>,"action":"fill","tabId":<tab>,"selector":<관측한 selector>,"text":"검색어"}
BrowserInteract {"clientId":<id>,"action":"press_key","tabId":<tab>,"expectedUrl":<읽은 URL>,"key":"Enter"}
BrowserRead {"lane":"live","clientId":<id>,"tabId":<tab>}
BrowserRead {"lane":"live","clientId":<id>,"tabId":<tab>,"mode":"screenshot"}
keeper_image_read {"artifact":<반환된 artifact>}
```

스크린샷은 명시한 탭의 viewport PNG를 Keeper의 이미지 저장소에 저장한다.
반환된 Keeper-local 이미지 artifact 핸들을 그대로 `keeper_image_read`로 읽는다.
성공하면 별도 모델 호출 없이 현재 모델에 이미지 블록을 전달한다. BrowserRead의
텍스트 응답 자체에는 이미지 바이트를 넣지 않는다. 메시지에 이미지 블록이 이미
첨부됐으면 그 입력을 직접 읽는다.
스크린샷 저장에는 in-process Keeper 실행 문맥이 필요하다.
일반 도구 호출자의 표시 이름을 Keeper 소유권으로 간주하지 않는다.

현재 런타임 capability와 실제 제공 도구 목록에서 이미지 입력 미지원으로
`keeper_image_read`가 제외됐음이 확인되거나, native image admission이 명시적으로
거절했거나, 다른 모델의 텍스트 해석이 필요하면 `keeper_analyze_image`에 artifact와
query를 전달한다. 정상 제외는 deferred/discovery 목록에도 적용되므로 거절된 호출을
먼저 만들 필요는 없다. 단순 스키마 미로드나 도구 검색 실패만으로 미지원 제외를
추측하지 않는다. 모델·provider 이름, 과거 스킬 안내, 파일·아티팩트 조회 실패나
계정 한도 오류도 이미지 미지원의 근거가 아니다.

`live`는 `BrowserTabs`에서 받은 `clientId`와 `tabId`를 한 쌍으로 유지한다.
연결이 둘 이상이면 읽기·캡처·조작마다 해당 `clientId`를
전달한다. 아래 예제의 `clientId`는 실제 관측한 연결 UUID로 채운다.

## 화면과 상호작용

선택한 탭의 화면을 보려면 `BrowserRead`에 `mode=screenshot`를 지정한다.
Keeper는 반환된 `artifact`를 먼저 `keeper_image_read`에 전달한다. TUI에서는
`Ctrl-O`로 같은 탭의 PNG를 미리 본다. 캡처 범위는 현재 viewport다.

```json
BrowserRead {"lane":"live","clientId":<관측한 UUID>,"tabId":73,"mode":"screenshot"}
BrowserInteract {"clientId":<관측한 UUID>,"tabId":73,"action":"scroll","x":0,"y":640}
```

페이지에서 확인한 CSS selector가 있을 때 click 또는 fill을 사용한다.
요소는 현재 문서에서 정확히 하나여야 한다. `expectedUrl`은 직전에
읽은 URL을 전달하며, 페이지가 바뀌었으면 동작을 거부한다.

```json
BrowserInteract {"clientId":<관측한 UUID>,"tabId":73,"action":"fill","selector":"#search","text":"OCaml","expectedUrl":"https://example.org/"}
BrowserInteract {"clientId":<관측한 UUID>,"tabId":73,"action":"click","selector":"#search-button","expectedUrl":"https://example.org/"}
```

텍스트나 이미지에서 selector를 추측하지 않는다. `BrowserRead mode=elements`로
현재 DOM 컨트롤과 selector를 관측하거나 `mode=scene`의 documentId/nodeId를 쓴다.
좌표 클릭·스크롤은 screenshot의 현재 `viewport`와 정규화된 `point`를 전달하는
`click_at`·`scroll_at`으로 수행한다. fill은 Enter나 submit을 호출하지 않는다.
페이지의 이벤트 핸들러는 동작할 수 있으므로 결과를 다시 읽거나 캡처한다.

## 반복 관측

동일 페이지를 나중에 다시 확인하려면 `masc_schedule_create`로 후속 작업을
예약하고, 깨어난 턴에서 페이지를 새로 읽는다. 이전 관측과 현재 관측을
비교해 달라진 내용을 근거와 함께 보고한다. Browser가 자체적으로 모든
탭을 감시하거나 특정 웹앱을 주기적으로 수집하지는 않는다.

## 관측 범위

ego 연결이 하는 일은 [ego SDK coverage](../guides/ego-sdk-coverage.md)에 있다.

텍스트 모드는 URL, 제목, 전체 문자 수(`chars`)와 잘림 여부(`truncated`)를
반환하며 기본 한도는 50,000 code points다. 컨트롤 관측은 최대 200개이며
비밀번호와 파일 입력 값은 제외한다. 전체 접근성 트리나 접힌 영역의 내용까지
포함하지 않는다. 캡처는 전체 페이지를 이어 붙인 이미지가 아니며, 캡처 전후
URL 변경을 검출한다. live에서는 documentId·viewport 크기·스크롤 위치도 비교하지만,
이 값들이 같은 상태의 모든 픽셀 변경을 검출하는 것은 아니다.

ego 연결에서 다운로드 링크를 클릭한 뒤 `BrowserRead`에 그 `clientId`, 관측한 `tabId`,
`mode=downloads`를 전달하면 완료 상태와 artifact 참조를 읽는다. 반환된
`artifact.arguments`로 `keeper_artifact_read`를 호출하고 `next_offset`부터
`eof=true`까지 이어 읽는다. 바이너리 페이지는 `encoding`을 확인한다.

동작별 필드와 검증 범위는 [Browser Lane](browser-lane.md#browser-controls)을
참고한다. CI 통과, 배포된 실행 파일, 실제 Keeper/Vision 모델의 성공은 각각
별도로 확인해야 한다.
