# Browser Lane 사용 흐름

Browser는 사이트 구분 없이 페이지를 읽는 공통 도구다. Keeper에 보이는
이름은 `BrowserTabs`, `BrowserRead`, `BrowserSession`, `BrowserGoto`,
`BrowserAct`, `BrowserInteract`이며, 등록 이름은 각각 `masc_browser_tabs`, `masc_browser_read`,
`masc_browser_session`, `masc_browser_goto`, `masc_browser_act`,
`masc_browser_interact`다.

## 연결

운영자가 사용하는 Firefox/Zen은 `live`, Keeper가 URL을 열어 조사하는
설정한 Gecko 브라우저의 격리 세션은 `automation`이다. 두 브라우저는 로그인 세션을 공유하지 않는다.

Live 호스트를 설치하고 Firefox 또는 Zen의 `about:debugging`에서 확장을 적재한다.

```sh
masc browser-lane-setup --mode extension --base-path /path/to/workspace
```

확장 manifest: `<base-path>/.masc/browser-lane/extension/manifest.json`.
Automation은 resolved configuration directory의 `runtime.toml`에 geckodriver
실행 파일 경로를 적고 MASC를 재시작한다. 서버가 그 geckodriver를 빈 loopback
포트로 직접 띄우고, 서버가 끝날 때 같이 내린다.
`masc browser-lane-setup --mode automation` 이 이 표를 쓴다. 이미 있는 값은 바꾸지
않고(있던 자리 `[browser.automation]` 또는 `[browser]` 에서 고친다), host 와 확장은
설치하지 않는다.

```toml
[browser.automation]
geckodriver = "/absolute/path/to/geckodriver"
# Optional: an absolute path to the installed Zen executable/app bundle.
# binary = "/path/to/Zen.app/Contents/MacOS/zen"
```

자세한 연결 계약은 [native Firefox](native-firefox-lane.md)에 있다.
TUI에서는 `:` → `go Browser Lane`, `l` / `a`로 source를 선택한다.

## 출처별 설정과 켜고 끄기

browser 출처마다 Lane Add-on 패키지와 worker 가 따로 있다(`browser-automation`,
`browser-stagehand`, `browser-firefox`, `browser-ego`, `browser-external`). `runtime.toml`
의 표는 출처를 어떻게 띄울지만 담는다.

```toml
[browser.automation]
geckodriver = "/absolute/path/to/geckodriver"

[browser.stagehand]
chrome = "/absolute/path/to/chromium"
extension = "/absolute/path/to/stagehand-extension"
# profile = "/absolute/path/to/profile"
```

출처를 켜고 끄는 것은 그 출처 선언(`browser-<출처>.toml`)의 최상위 `enabled` 하나다.
TUI 의 Lanes 화면에서 `browser-<출처>` 패키지 줄을 골라 선언 편집기로 바꾸거나, 웹 All Lanes
의 그 패키지 상세에서 바꾼다([package activity](../guides/lane-package-activity.md)). 끄면 그 출처의 worker 만 멈추고 다른 출처는 그대로다. 표가 없는
출처의 선언은 시작하지 못하고, 패키지 줄이 그 이유를 보여 준다.

Live lane 의 BiDi 연결(hover·drag)을 쓰려면 `[browser.live.bidi]` 를 더한다.
`browser-firefox` worker 가 시작할 때 그 프로필로 Firefox 를 `--remote-debugging-port`
로 띄우고 자기 BiDi peer 로 붙는다. 자세한 것은 [BiDi host](browser-bidi-live-host.md)에
있다.

`masc browser-lane-setup --mode bidi --base-path /path/to/workspace` 가 lane 을
설치하고 이 표를 쓴다. 표가 이미 있으면 값을 바꾸지 않고, 값을 지정한 옵션
(`--firefox`, `--profile`, `--port`)만 바꾼다. 서버를 다시 띄워야 표를 읽는다.

```toml
[browser.live.bidi]
firefox = "/Applications/Firefox.app/Contents/MacOS/firefox"
profile = "/absolute/path/to/keeper-profile"
# port = 9222
```

실행 파일·확장·프로필 경로는 worker 가 붙을 때 읽으므로, 경로를 바꾼 뒤에는 서버를
재시작하고 기존 설치를 detach 한 뒤 다시 붙인다. All Lanes 의 browser 줄은 그 lane 의
출처 중 켜진 선언이 있는지와, 관측한 연결 수·executor 등록 여부를 따로 보여 준다.
등록됐다는 표시는 세션이나 브라우저 프로세스의 정상 동작을 보장하지 않는다.

Automation 경로는 `[browser.automation]`이 정본이다. 기존 `[browser]
geckodriver/binary`도 읽지만 두 자리를 함께 쓰면 거절한다.

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

```text
BrowserSession {"action":"open"}
BrowserAct {"action":"open_tab","url":"https://ocaml.org/releases"}
BrowserRead {"lane":"automation","tabId":<반환된 id>,"maxChars":12000}
```

여러 Keeper가 동시에 조사할 수 있으므로 작업별 탭을 열고, 반환된 `tabId`를
읽기와 조작에 계속 사용한다. 같은 탭의 URL을 바꿀 때는 `BrowserGoto`에도
해당 id를 전달한다. 이동 후 실제 읽기 결과로 내용을 확인하고 출처를 붙인다.
작업이 끝나면 `BrowserAct close_tab`으로 해당 탭을 닫는다. 세션 자체를 닫으면
다른 작업의 탭도 종료되므로 공유 중인 세션을 임의로 닫지 않는다.

## 입력과 화면 확인

`BrowserRead mode=elements`로 현재 컨트롤의 selector, 상태, 선택 항목의
실제 value를 관측한다. 그 결과로 `BrowserInteract`의 click, fill, select_option,
scroll을 호출하고 다시 읽어 결과를 확인한다. `BrowserAct`는 탭 열기·닫기,
back, forward, reload, 대화상자, 업로드처럼 브라우저 수준 동작만 맡는다.

```text
BrowserRead {"lane":"automation","tabId":<id>,"mode":"elements"}
BrowserInteract {"lane":"automation","action":"fill","tabId":<id>,"selector":<관측한 selector>,"text":"검색어"}
BrowserInteract {"lane":"automation","action":"press_key","tabId":<id>,"expectedUrl":<읽은 URL>,"key":"Enter"}
BrowserRead {"lane":"automation","tabId":<id>}
BrowserRead {"lane":"automation","tabId":<id>,"mode":"screenshot"}
keeper_analyze_image {"artifact":<반환된 artifact>,"query":"검색 결과와 화면 배치를 확인해줘"}
```

스크린샷은 명시한 탭의 viewport PNG를 Keeper의 이미지 저장소에 저장한다.
반환된 artifact를 Vision reader가 읽으며, BrowserRead의 텍스트 응답에 이미지
바이트를 넣지는 않는다. 스크린샷 저장에는 in-process Keeper 실행 문맥이 필요하다.
일반 도구 호출자의 표시 이름을 Keeper 소유권으로 간주하지 않는다.

`live`는 `BrowserTabs`에서 받은 `clientId`와 `tabId`를 한 쌍으로 유지한다.
Firefox와 Zen이 동시에 연결된 경우 읽기·캡처·조작마다 해당 `clientId`를
전달한다. 아래 예제의 `clientId`는 실제 관측한 연결 UUID로 채운다.

## 화면과 상호작용

선택한 탭의 화면을 보려면 `BrowserRead`에 `mode=screenshot`를 지정한다.
Keeper는 반환된 `artifact`를 `keeper_analyze_image`에 전달한다. TUI에서는
`Ctrl-O`로 같은 탭의 PNG를 미리 본다. 캡처 범위는 현재 viewport다.

```json
BrowserRead {"lane":"live","clientId":<관측한 UUID>,"tabId":73,"mode":"screenshot"}
BrowserInteract {"lane":"live","clientId":<관측한 UUID>,"tabId":73,"action":"scroll","x":0,"y":640}
```

페이지에서 확인한 CSS selector가 있을 때 click 또는 fill을 사용한다.
요소는 현재 문서에서 정확히 하나여야 한다. `expectedUrl`은 직전에
읽은 URL을 전달하며, 페이지가 바뀌었으면 동작을 거부한다.

```json
BrowserInteract {"lane":"live","clientId":<관측한 UUID>,"tabId":73,"action":"fill","selector":"#search","text":"OCaml","expectedUrl":"https://example.org/"}
BrowserInteract {"lane":"live","clientId":<관측한 UUID>,"tabId":73,"action":"click","selector":"#search-button","expectedUrl":"https://example.org/"}
```

텍스트나 이미지에서 selector를 추측하지 않는다. `BrowserRead mode=elements`로
현재 DOM 컨트롤과 selector를 관측하거나 `mode=scene`의 documentId/nodeId를 쓴다.
좌표 클릭·스크롤은 screenshot의 현재 `viewport`와 정규화된 `point`를 전달하는
`click_at`·`scroll_at`으로 수행한다. `web_extension` 연결의 클릭은 DOM activation이다.
trusted `hover_at`·`drag`는 automation과 live의 `webdriver_bidi` 연결이 한다. fill은
input/change 이벤트를 발생시키며 Enter나 submit을 호출하지 않는다.
페이지의 이벤트 핸들러는 동작할 수 있으므로 결과를 다시 읽거나 캡처한다.

## 반복 관측

동일 페이지를 나중에 다시 확인하려면 `masc_schedule_create`로 후속 작업을
예약하고, 깨어난 턴에서 페이지를 새로 읽는다. 이전 관측과 현재 관측을
비교해 달라진 내용을 근거와 함께 보고한다. Browser가 자체적으로 모든
탭을 감시하거나 특정 웹앱을 주기적으로 수집하지는 않는다.

## 관측 범위

| 기능 | live Firefox 확장 | automation Firefox |
|---|---|---|
| 탭 목록·텍스트·컨트롤 관측 | 지원 | 지원 |
| 명시한 탭의 viewport 캡처 | 지원 | 지원 |
| 세션 관리·직접 URL 이동·탭 열기/닫기 | 미지원 | 지원 |
| 관측된 같은 탭 링크 따라가기 | 지원 | 지원 |
| 클릭·입력·스크롤 (`BrowserInteract`) | 지원 | 지원 |
| screenshot 좌표 클릭·스크롤 | 지원 | 지원 |
| trusted pointer drag | 미지원 | 지원 |
| 네이티브 키·선택·히스토리 (`BrowserAct`) | 미지원 | 지원 |
| framePath로 중첩 iframe 대상 지정·JavaScript 대화상자·파일 업로드 | 미지원 | 지원 |
| 다운로드 완료 관측·artifact 읽기 | 미지원 | 지원 |
| 전용 shadow-root locator | 미지원 | 미지원 |

텍스트 모드는 URL, 제목, 전체 문자 수(`chars`)와 잘림 여부(`truncated`)를
반환하며 기본 한도는 50,000 code points다. 컨트롤 관측은 최대 200개이며
비밀번호와 파일 입력 값은 제외한다. 전체 접근성 트리나 접힌 영역의 내용까지
포함하지 않는다. 캡처는 전체 페이지를 이어 붙인 이미지가 아니며, 캡처 전후
URL 변경을 검출한다. live에서는 documentId·viewport 크기·스크롤 위치도 비교하지만,
이 값들이 같은 상태의 모든 픽셀 변경을 검출하는 것은 아니다.

다운로드 링크를 클릭한 뒤 `BrowserRead`에 `lane=automation`, 관측한 `tabId`,
`mode=downloads`를 전달하면 완료 상태와 artifact 참조를 읽는다. 반환된
`artifact.arguments`로 `keeper_artifact_read`를 호출하고 `next_offset`부터
`eof=true`까지 이어 읽는다. 바이너리 페이지는 `encoding`을 확인한다.
자세한 수명과 실패 계약은 [Firefox downloads](firefox-downloads.md)를 참고한다.

동작별 필드와 검증 범위는 [Firefox interaction support](firefox-controls.md)를
참고한다. CI 통과, 배포된 실행 파일, 실제 Keeper/Vision 모델의 성공은 각각
별도로 확인해야 한다.
