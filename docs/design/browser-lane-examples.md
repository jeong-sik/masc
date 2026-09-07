# Browser Lane 사용 흐름

Browser는 사이트 구분 없이 페이지를 읽는 공통 도구다. Keeper에 보이는
이름은 `BrowserTabs`, `BrowserRead`, `BrowserSession`, `BrowserGoto`,
`BrowserAct`이며, 등록 이름은 각각 `masc_browser_tabs`, `masc_browser_read`,
`masc_browser_session`, `masc_browser_goto`, `masc_browser_act`다.

## 연결

운영자가 사용하는 Firefox/Zen은 `live`, Keeper가 URL을 열어 조사하는
격리 Firefox는 `automation`이다. 두 브라우저는 로그인 세션을 공유하지 않는다.

Live 호스트를 설치하고 Firefox `about:debugging`에서 확장을 적재한다.

```sh
bash connectors/browser/install-host.sh \
  --binary /path/to/masc-browser-host \
  --base-path /path/to/workspace \
  --server http://127.0.0.1:8935
```

확장 manifest: `connectors/browser/extension/manifest.json`.
Automation은 geckodriver를 실행하고, resolved configuration directory의
`runtime.toml`에 endpoint를 설정한 뒤 MASC를 재시작한다.

```sh
geckodriver --host 127.0.0.1 --port 4444
```

```toml
[browser]
webdriver_url = "http://127.0.0.1:4444"
```

자세한 연결 계약은 [native Firefox](native-firefox-lane.md)에 있다.
TUI에서는 `:` → `go Browser Lane`, `l` / `a`로 source를 선택한다.

## 열린 업무 화면에서 근거 찾기

“열어둔 PR에서 실패한 CI 원인을 확인해줘” 같은 요청이면 우선 탭 목록에서
해당 제목과 URL을 찾는다. 배열 순서로 id를 추측하지 않는다.

```json
BrowserTabs {"lane":"live"}
BrowserRead {"lane":"live","tabId":73,"maxChars":12000}
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
실제 value를 관측한다. 그 결과로 `BrowserAct`의 click, fill, press, select를
호출하고 다시 읽어 결과를 확인한다. scroll, back, forward, reload도 지원한다.
조작은 automation에서 지원하며, live는 읽기와 캡처를 제공한다.

```text
BrowserRead {"lane":"automation","tabId":<id>,"mode":"elements"}
BrowserAct {"action":"fill","tabId":<id>,"selector":<관측한 selector>,"text":"검색어"}
BrowserAct {"action":"press","tabId":<id>,"selector":<관측한 selector>,"key":"Enter"}
BrowserRead {"lane":"automation","tabId":<id>}
BrowserRead {"lane":"automation","tabId":<id>,"mode":"screenshot"}
keeper_analyze_image {"artifact":<반환된 artifact>,"query":"검색 결과와 화면 배치를 확인해줘"}
```

스크린샷은 명시한 탭의 viewport PNG를 Keeper의 이미지 저장소에 저장한다.
반환된 artifact를 Vision reader가 읽으며, BrowserRead의 텍스트 응답에 이미지
바이트를 넣지는 않는다. 스크린샷 저장에는 in-process Keeper 실행 문맥이 필요하다.
일반 도구 호출자의 표시 이름을 Keeper 소유권으로 간주하지 않는다.

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
| 탭 열기·이동·닫기 | 미지원 | 지원 |
| 클릭·입력·키·선택·스크롤·히스토리 | 미지원 | 지원 |
| iframe/shadow root 대상 지정·대화상자·업로드·다운로드 | 미지원 | 미지원 |

텍스트 모드는 URL, 제목, 전체 문자 수(`chars`)와 잘림 여부(`truncated`)를
반환하며 기본 한도는 50,000 code points다. 컨트롤 관측은 최대 200개이며
비밀번호와 파일 입력 값은 제외한다. 전체 접근성 트리나 접힌 영역의 내용까지
포함하지 않는다. 캡처는 전체 페이지를 이어 붙인 이미지가 아니며, 캡처 전후
URL 변경은 검출하지만 같은 URL에서의 화면 변경까지 보장하지 않는다.

동작별 필드와 검증 범위는 [Firefox interaction support](firefox-controls.md)를
참고한다. CI 통과, 배포된 실행 파일, 실제 Keeper/Vision 모델의 성공은 각각
별도로 확인해야 한다.
