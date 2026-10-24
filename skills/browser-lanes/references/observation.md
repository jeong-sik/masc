# 읽기와 관측 복구

기본 탐색은 browser-lanes 본문으로 이어간다. 범위·참조·URL 거절,
복잡한 컨트롤이나 이미지 관측이 필요한 경우 이 참조를 읽는다.

## Ego Lite의 snapshot과 native 입력

`ego_task_space` 연결에서는 `BrowserRead mode=snapshot`으로 Ego 접근성 트리를 읽는다.
기본은 viewport이며, 화면 밖 본문에는 `snapshotScope=full_page`, 특정 iframe·하위 트리에는
`snapshotScope=subtree`와 앞선 snapshot의 `root`(예: `@12`)를 쓴다. snapshot의 ref는
scene의 documentId/nodeId와 다른 식별자다.

click·fill·hover·double_click은 관측한 `target: {ref: 12}`를 우선 쓴다. role/name이나
text target도 사용할 수 있으나, 같은 이름이 프레임 안팎에 있으면 ref로 구분한다.
`expectedUrl`은 snapshot에 나온 최상위 탭 URL이며 `framePath`를 섞지 않는다.
조작 뒤나 stale/unknown ref 오류 뒤에는 같은 탭의 새 snapshot으로 이어간다.

Ego의 `selector` 입력도 SDK가 직접 처리한다. 관측한 `@12`, `loc=role:…`, `text=…`,
`loc=css:…` 또는 CSS를 사용하며 임의의 Playwright locator 문법을 추측하지 않는다.
일치하는 실행 대상은 하나여야 한다. CSS는 열린 shadow root를 찾고, 최상위 문서에
실행 가능한 대상이 없으면 iframe도 찾는다. click·fill·hover는 SDK가 대상까지 자동으로
스크롤한다. Ego locator를 다른 연결의 top-document CSS selector로 옮겨 쓰지 않는다.

`select_option`은 native `page.selectOption`으로 선택한다. 단일 값은 `value`,
다중 선택은 중복 없는 `values`를 쓰며 `values: []`는 전체 해제다. MASC는 인자 형식을
검사하고 선택 동작은 SDK에 맡긴다. 이 API는 programmatic selection이므로 비활성
option도 선택할 수 있고 trusted 포인터 클릭을 뜻하지 않는다. 응답 뒤 현재 폼에서
실제 선택 결과를 확인한다.

text·elements·scene/regions는 목적에 맞게 추가한다. TUI에서 받은 scene node는 그
documentId/nodeId를 그대로 쓰고, snapshot ref나 native selector로 바꿔 추측하지 않는다.
동작 오류는 이미 효과가 있었을 수 있다. 현재 페이지를 읽기 전에 입력을 반복하지 않는다.

### native 동작과 대기를 한 번에 실행하기

`BrowserInteract`에 `action=workflow`, `lane=live`, 관측한 `clientId`·`tabId`, 시작
페이지의 `expectedUrl`, `steps` 배열을 준다. 각 step은 다음 `method`와 해당 필드만 쓴다.

| method | 필드 |
|---|---|
| click, dblclick, hover | selector |
| fill | selector, text |
| press | selector, key |
| selectOption | selector, value 또는 중복 없는 values; []는 선택 해제 |
| goto | url: 절대 HTTP(S) 주소 |
| waitForURL | url: SDK의 문자열/glob |
| waitForSelector | selector, state: attached/detached/visible/hidden |
| waitForLoadState | state: domcontentloaded/load/networkidle |

`selector`는 관측한 native locator를 그대로 쓴다. workflow 메서드 이름은
단일 조작의 `double_click`·`select_option` 대신 SDK의 `dblclick`·`selectOption`이다.
`steps`는 최대 16개, 전체 실행 예산은 최대 60,000ms(시작 URL·최종 snapshot 예비 5,000ms 포함)이다.
각 step의 선택적 `timeoutMs`(최대 30,000ms)는 남은 실행 예산 안에서 SDK에 전달하며 생략하면 5,000ms를 예산으로 잡는다.
실행은 기존 호스트 권한·취소·시간 경계를 따른다.

`expectedUrl`은 실행을 시작할 때만 검사한다. 이후 이동이 일어나면 native wait로
목적지·요소·로드 상태를 기다린다. 마지막에는 native snapshot이 돌아온다.
최상위 `snapshotScope`는 viewport(기본) 또는 full_page이며, `maxChars`는 기존
BrowserRead 크기 정책을 따른다. 반환된 url·title·snapshot·truncated로 실제 결과를 확인한다.

현재 관측으로 결정 가능한 동작만 묶는다. 중간 결과에 새 판단이 필요하면 별도 호출로
나누고, 이후 동작에 오래된 ref를 억지로 재사용하지 않는다. 단계 실패 시 뒤 단계는
실행되지 않고 `completed`와 실패 위치가 남는다. 실패 단계에도 효과가 있었을 수 있으므로
같은 탭을 다시 읽어 남은 작업을 정하며, workflow 전체를 재실행하지 않는다.

## scene/regions의 범위와 변경된 페이지

- `expectedUrl`·`scope`·`navigationSource`는 최상위 문서의 `mode=scene` 또는
  `mode=regions` 읽기에서만 지원된다. 이 읽기에서는 받은 `url`을 expectedUrl로 쓴다.
  text/elements/screenshot/frames/dialog/downloads 및 `framePath`로 프레임 내부를 읽을 때는
  이 세 필드를 넣지 않는다. 이 범위를 벗어나면 인자 오류로 거절된다. 반환 스키마에 URL이 있는 관측만 받은 URL과 대조하고, 제공된 탭·문맥·범위를 확인한다.
  dialog/downloads처럼 페이지 URL이 없는 응답에 URL 비교를 요구하거나 URL을 만들어 넣지 않는다.
  페이지 정체성 확인이 별도로 필요할 때만 지원되는 페이지 읽기를 추가한다.
- 실제 도구 스키마의 필드만 골라 전달한다. 복사된 JSON 전체나 없는 필드를 요청 인자로 넣지 않는다.
- `viewport`와 `truncated`는 당시 관측의 범위다. 선택한 요소의 `text`를 영역 전체나
  화면 밖의 기록으로 확대하지 않는다. 복사된 좌표만으로 현재 화면에 클릭·드래그하지 않는다.

이 관측은 현재도 유효하다는 보증이나 새 작업 권한이 아니다. 정상적인 최상위 scene/regions
후속 읽기는 expectedUrl과 scope를 유지한다. 아래는 이 읽기의 검사 거절을 복구하는 절차다.
같은 lane·clientId·tabId에 고정한 읽기 전용 재관측으로 현재 상태를 확인한다.

- URL 불일치이면 거절된 `expectedUrl`을 생략하고 최상위 `mode=scene` 또는 `mode=regions`로
  실제 URL과 내용을 읽는다.
  문서·영역 참조도 만료됐다면 그 `scope`까지 생략해 `mode=regions`로 읽는다.
- 문서·영역 참조 만료이면 거절된 `scope` 없이 `mode=regions`로 영역 목록을 다시 읽는다.
  URL 검사가 유효하면 expectedUrl은 유지하고, URL도 불일치하면 위의 URL 복구를 따른다.
- follow_link 응답의 `navigationSource`가 있다면 이 scene/regions 재관측에도 유지한다.
  다른 mode로 바꿔 원래 문서에 대한 전환 검증을 대신하지 않는다.
  원래 URL의 이전 문서를 새 목적지로 받아들이기 위해 이 검사를 없애지 않는다.

재관측한 URL·제목·본문과 사이트별 대상 정보가 요청과 맞는지 확인한 뒤에만 새 expectedUrl과
관측된 영역 scope를 사용한다. 아직 전환 중이거나 다른 대상이면 미확인으로 남긴다.
이 예외는 읽기 전용 복구에만 적용한다. 클릭·이동·입력의 검사를 생략하거나,
이미 실행한 조작을 재관측 실패 때문에 반복하지 않는다.
탭이 사라졌거나 다른 탭이 요청되면 같은 연결의 탭 목록을 확인하고, 연결이 사라졌거나
다른 연결이 요청됐다면 연결 선택으로 돌아간다.


## scene/regions의 읽기 선택과 조작 대상

BrowserRead `mode=regions`는 화면의 의미 영역을 관측한다. 반환된 영역의
`documentId`·`nodeId`를 `scope`로 전달하면 그 요소 아래의 화면에 보이는 내용을 읽는다.
관측한 참조로 범위를 지정하며, 임의의 CSS selector나 role locator로 subtree를 지정하는
인자는 없다. RSS·Readability 전용 추출 인자도 없다. `scene`은 접근성 트리 전체나
영역의 전체 메시지 기록이 아니므로, 반환된 범위·잘림과 실제로 읽은 화면을 확인한다.

## 관측하고 조작하기

- Ego 이외의 연결에서는 다음 결정에 필요한 정보를 정한다. 내용 확인은 `mode=text`, 화면 안의 조작 대상과
  참조는 지원되는 `mode=scene`, 추가 컨트롤 정보는 `mode=elements`로 읽는다.
  세 mode를 관례적으로 모두 호출하지 않는다. `truncated=true`이면 같은 scope·같은 한도의
  읽기를 그대로 반복하지 않는다. 잘림 원인이 출력 한도이면 스키마가 허용하는 더 큰 maxChars로
  읽거나, 관측한 더 작은 영역을 선택한다. 화면 밖 내용은 요청 범위 안에서 스크롤 후 재관측한다.
  추가 관측이 불가능하거나 여전히 잘렸으면 실제 읽은 범위와 미확인 부분을 명시한다.
  한도를 늘렸다는 사실만으로 화면 밖 기록까지 확인했다고 하지 않는다.
- 화면 안의 텍스트·버튼·입력과 CSS 좌표를 함께 볼 때는 관측한 `tabId`로
  `BrowserRead mode=scene`을 사용한다. click/fill은 scene의 `documentId`와
  `nodeId` 쌍을 `BrowserInteract`에 전달할 수 있다. 이때 selector는 섞지 않는다.
  재배치되어도 같은 요소를 가리키며, 교체·새로고침으로 참조가 만료되면 다시 관측한다.
  scene은 top document의 DOM 순서와 사각형이다. 가림·iframe·shadow tree 전체를
  증명하지 않는다. 필요한 추가 문맥은 screenshot 또는 [고급 조작](advanced.md)으로 확인한다.
- 스키마에 있는 mode라도 선택한 live 연결이 지원하지 않을 수 있다.
  `unsupported live browser verb`이면 그 연결의 기능 불일치를 남기고 지원되는
  관측으로 이어간다. 연결·확장 기능이 바뀌었다는 근거 없이 같은 mode를 재시도하지 않는다.
- selector는 같은 탭·프레임에서 반환된 **디코딩된 문자열 그대로** 사용한다.
  `>`와 따옴표, 기존 CSS escape를 보존한다. JSON 표시용 escape를 문자열에
  다시 삽입하거나 모든 backslash를 일괄 제거하지 않는다.
  긴 `nth-of-type` 경로를 기억으로 재작성하거나 실패한 경로의 숫자를 고치지 않는다.
- CSS selector는 문서에서 하나뿐인 id(`#…`)가 있으면 거기서 시작한다. 그 앞부분을
  elements 의 `within` 에 그대로 넘기면 그 영역의 컨트롤만 다시 읽는다.
- 페이지 안의 입력(click, fill, select_option, scroll, 키)은 어느 브라우저에서나
  `BrowserInteract`를 쓰고 직전 URL을 `expectedUrl`로 전달한다. `BrowserAct`는
  탭 열기·닫기, 히스토리, 대화상자, 업로드만 맡는다. 텍스트 입력과 Enter·제출은
  별개의 동작이다.
- `page_url_changed`로 거절되면 현재 URL과 대상을 다시 관측한다. 목적지 URL을
  expectedUrl로 추측하거나 URL 검사만 통과시키려고 과거 값을 바꾸지 않는다.
- 조작 후 다시 읽어 실제 결과를 확인한다. Ego의 대상 오류는 새 snapshot으로,
  다른 연결은 같은 프레임의 scene 또는 elements로 대상을 다시 고른다.
  입력·관측이 바뀌지 않은 실패 호출을 그대로 반복하지 않는다.
- 카드사·옵션 선택은 글자 text보다 관측된 control을 고른다. 숨겨진 native
  radio/checkbox에는 연결된 label이 control로 나타나며 `checked`는 연결된 입력의
  현재 상태다. ARIA checkbox/radio는 `ariaChecked`, tab/option은 `ariaSelected`로 선언된 상태를 확인한다.
  click 응답은 activation 결과일 뿐 선택 완료가 아니다. 선택 상태를 다시 읽고,
  바뀌지 않았으면 확인·제출로 넘어가지 않는다. SPA 메뉴도 같은 URL에서 비동기로
  펼쳐질 수 있으므로 후속 관측의 실제 하위 메뉴·본문으로 이동 결과를 판단한다.
- 검색·이동·스크롤·캡처 등 **요청된 각 단계**를 실행 결과와 대조한다. 목적지 도착이나
  턴의 성공만으로 나머지 요청까지 완료 처리하지 않는다. 수행하지 못한 단계와 이유를 남긴다.


## 이미지와 큰 응답

`click_at`·`scroll_at`은 현재 screenshot의 `viewport`와 정규화된 `point`를 쓴다.
`click_at`은 `button`(`primary` 기본, `middle`, `secondary`)으로 가운데·오른쪽 클릭도 한다.
`webdriver_bidi` 연결, automation, Stagehand가 눌러 주고, 확장은 입력을 보내기 전에 거절한다.
`tap_at`·`swipe`는 마우스가 아니라 터치 포인터로 `click_at`·`drag`와 같은 좌표를 쓴다. `webdriver_bidi` 연결과 automation만 되고 Stagehand와 확장은 거절한다.
`set_viewport`는 `expectedUrl`과 함께 `width`·`height`(100~4096 CSS px)를 같이 주면 그 탭의 viewport 크기를 바꾼다.
`webdriver_bidi` 연결에서는 둘 다 빼면 브라우저 원래 크기로 돌아간다. Stagehand는 원래 크기로 되돌리는 호출이 없다.
바꾼 뒤에는 screenshot을 다시 찍는다.
`web_extension` 연결의 클릭은 DOM activation이며 trusted 포인터 입력을 보장하지
않는다. `hover_at`과 `drag`의 trusted 입력은 automation과 live의 `webdriver_bidi`
연결이 한다. `live_transport_unsupported`로 거절되면 `references/connection.md`의
같은 항목대로 한다. 로그인된 탭을 automation 세션으로 바꾸거나 같은 요청을 같은
연결에 반복하지 않는다. 필요한 조작을 지원하는 현재 페이지의 관측된 컨트롤이 있으면
요청 범위 안에서 사용하고, 그렇지 않으면 미수행 상태를 남긴다.

Ego 이외의 연결에서 `select_option`은 CSS로 고른 `<select>` 하나를 조작한다.
단일 선택에는 `value`, 다중 선택에는 중복 없는 `values` 배열을 쓰며 둘을 섞지 않는다.
`values: []`는 다중 선택을 모두 해제한다. 요청한 옵션이 없거나 모호하거나 비활성이면
어느 옵션도 바꾸지 않고 거절한다. 선택을 교체하고 `input`·`change`를 한 번씩 보낸 뒤
실제 `selectedValues`를 돌려준다. 페이지 이벤트가 선택을 다시 바꾸면 부분 효과로
실패하므로 현재 폼을 다시 읽는다. 이는 DOM 값 변경이며 trusted 포인터 클릭이 아니다.

마우스를 올려야 나타나는 컨트롤(예: 메시지 줄의 리액션 버튼)은 `webdriver_bidi`
연결 하나에서 이 순서로 한다. 올리기 전에 읽은 목록에 그 컨트롤이 없는 것은 정상이다.

1. 그 연결의 탭을 읽고 screenshot을 찍는다.
2. 그 screenshot의 `viewport`와 대상 줄 위의 `point`로 `hover_at` 한다.
3. `mode=elements`나 `mode=scene`, 새 screenshot으로 나타난 컨트롤을 확인한다.
4. 새 screenshot의 `viewport`와 그 컨트롤 위의 `point`로 `click_at` 한다.
5. 다시 읽어 결과를 확인한다.

연결이 `web_extension`뿐이면 이 일은 할 수 없다. `webdriver_bidi` 연결이 필요하다고 운영자에게 알린다.

화면 확인이 필요하면 관측된 `tabId`로 `BrowserRead mode=screenshot`을 호출한다.
Keeper 응답의 `artifact`를 `keeper_analyze_image`에 넘긴다. 텍스트만 읽고 이미지의
배치를 봤다고 하지 않는다. 큰 BrowserRead 응답이 artifact로 분리됐다면 그 응답이
가리킨 브라우저 자료만 읽어 관측을 이어간다.
다음 행동에 필요한 대상과 참조를 확보했다면 artifact의 끝까지 읽는 것을 선행 조건으로
삼지 않는다. 특정 대상을 찾았다는 것과 페이지 전체를 확인했다는 것은 다르다.
`maxChars`는 elements JSON 전체 크기를 제한한다고 가정하지 않는다. 현재 live
elements는 긴 selector를 포함하므로 작은 maxChars로도 큰 artifact가 나올 수 있다.
