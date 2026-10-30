# 읽기와 관측 복구

기본 탐색은 browser-lanes 본문으로 이어간다. 범위·참조·URL 거절,
복잡한 컨트롤이나 이미지 관측이 필요한 경우 이 참조를 읽는다.

## 범위와 변경된 페이지

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


## 읽기 선택과 조작 대상

BrowserRead `mode=regions`는 화면의 의미 영역을 관측한다. 반환된 영역의
`documentId`·`nodeId`를 `scope`로 전달하면 그 요소 아래의 화면에 보이는 내용을 읽는다.
관측한 참조로 범위를 지정하며, 임의의 CSS selector나 role locator로 subtree를 지정하는
인자는 없다. RSS·Readability 전용 추출 인자도 없다. `scene`은 접근성 트리 전체나
영역의 전체 메시지 기록이 아니므로, 반환된 범위·잘림과 실제로 읽은 화면을 확인한다.

## 관측하고 조작하기

- 먼저 다음 결정에 필요한 정보를 정한다. 내용 확인은 `mode=text`, 화면 안의 조작 대상과
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
- live 조작은 `BrowserInteract`의 click/fill/scroll을 사용하고 직전 URL을
  `expectedUrl`로 전달한다. automation에서는 요청에 맞게 `BrowserInteract`나
  `BrowserAct`를 사용한다. 텍스트 입력과 Enter·제출은 별개의 동작이다.
- `page_url_changed`로 거절되면 현재 URL과 대상을 다시 관측한다. 목적지 URL을
  expectedUrl로 추측하거나 URL 검사만 통과시키려고 과거 값을 바꾸지 않는다.
- 조작 후 다시 읽어 실제 결과를 확인한다. 요소를 못 찾으면 같은 프레임에서
  scene이 지원되면 scene을, 그렇지 않으면 elements를 다시 읽어 대상을 고른다.
  입력·관측이 바뀌지 않은 실패 호출을 그대로 반복하지 않는다.
- 검색·이동·스크롤·캡처 등 **요청된 각 단계**를 실행 결과와 대조한다. 목적지 도착이나
  턴의 성공만으로 나머지 요청까지 완료 처리하지 않는다. 수행하지 못한 단계와 이유를 남긴다.


## 이미지와 큰 응답

화면 확인이 필요하면 관측된 `tabId`로 `BrowserRead mode=screenshot`을 호출한다.
Keeper 응답의 `artifact`를 `keeper_analyze_image`에 넘긴다. 텍스트만 읽고 이미지의
배치를 봤다고 하지 않는다. 큰 BrowserRead 응답이 artifact로 분리됐다면 그 응답이
가리킨 브라우저 자료만 읽어 관측을 이어간다.
다음 행동에 필요한 대상과 참조를 확보했다면 artifact의 끝까지 읽는 것을 선행 조건으로
삼지 않는다. 특정 대상을 찾았다는 것과 페이지 전체를 확인했다는 것은 다르다.
`maxChars`는 elements JSON 전체 크기를 제한한다고 가정하지 않는다. 현재 live
elements는 긴 selector를 포함하므로 작은 maxChars로도 큰 artifact가 나올 수 있다.

