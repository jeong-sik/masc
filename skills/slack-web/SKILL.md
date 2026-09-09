---
name: slack-web
description: Navigate Slack Web channels and collect messages or threads through Browser Lane, choosing channel search or message search and preserving the observed collection scope.
---

# Slack Web에서 채널과 메시지 읽기

Slack Web에서 채널을 찾거나 메시지를 수집할 때 쓴다. Available 목록의
`browser-lanes` instruction을 함께 읽어 연결·참조·조작 계약을 따른다.
identity와 선택 revision은 현재 목록에서 가져온다. 이 스킬은 instruction이며
composition 도구를 선언하지 않는다.
현재 목록과 같은 revision의 browser-lanes 본문을 이미 읽었고 그 지침을 가지고
있다면 다시 호출하지 않는다.

## 다음 행동에 필요한 화면만 읽는다

이미 관측한 clientId/tabId와 workspace를 이어 쓴다. 연결이 유효하고 목적지가
확인돼 있으면 습관적으로 모든 브라우저와 탭을 다시 열거하지 않는다.

채널로 이동하려면 현재 화면의 채널 링크나 채널 선택기를 찾는다. 목적 채널이
텍스트에 보이는 것만으로 클릭 참조가 확보된 것은 아니다. 지원되는 scene에서
대상의 documentId/nodeId를 얻거나 elements의 반환 selector를 그대로 쓴다.
현재 관측에 목적 채널 링크가 없다면 채널 선택기의 입력과 결과 목록을 읽는다.
입력 후 나타난 실제 후보를 선택하고 채널 제목·URL로 도착을 확인한다.
채널 이름이 DOM id라는 관례를 가정해 `#채널명` selector를 만들지 않는다.
expectedUrl은 현재 관측의 URL이다. 희망하는 목적지 URL을 넣어 클릭을 거부시킨 뒤
경로를 추측해서 바꾸지 않는다.

`Channel or user name` 같은 채널 선택 입력과 메시지 검색 입력은 목적이 다르다.
전체 검색식을 채널 선택기에 넣지 않는다. 이름은 사이트 언어에 따라 달라지므로
이 예시를 고정 selector로 사용하지 않는다.

기간·키워드가 있는 메시지 수집은 메시지 검색에서 `in:<channel>`과 요청에 맞는
`after:`, `before:`, `on:` 조건을 사용한다. 사용자 기간을 임의로 줄이지 않는다.
검색 입력, 결과 선택, 채널 메시지 작성란을 구분하고 현재 스키마가 제공하는
입력·제출 수단만 사용한다. fill 성공은 검색 실행의 증거가 아니다.

## 읽은 범위를 유지한다

검색 결과나 채널의 메시지 영역에서 작성자·시각·본문·관측된 링크를 수집한다.
필요한 스레드만 열고 새 관측에서 본문과 답글을 구분한다. 같은 메시지 링크가
있으면 그것으로 중복을 구분하고, 링크가 없으면 시각·작성자·본문을 함께 비교한다.

Slack의 화면에는 일부 메시지만 렌더링될 수 있다. BrowserRead의
`truncated=false`도 채널 전체나 요청 기간 전체를 읽었다는 뜻은 아니다.
결과의 다음 페이지·스크롤·스레드와 요청 범위를 대조하고 아직 읽지 않은 범위를
남긴다. 요약을 공유하는 작업은 별도의 수신 대상과 전송 권한을 따른다.
브라우저 조작 실패를 별도 Slack API 수집 버퍼로 우회하지 않는다. 같은 서비스
이름이어도 workspace·인증·수집 범위가 같다는 증거가 아니다. Browser Lane으로
요청받은 수집은 그 출처를 유지하고, 막힌 동작과 아직 못 읽은 범위를 보고한다.

## 반복 동선을 composition으로 옮길 때

관측에 따라 대상·후속 행동을 고르는 지점은 모델에게 남긴다. 검증된 도구 묶음만
별도 composition Skill의 단일 `toml composition` 블록으로 선언한다.
등록된 composable tool 이름과 입력 계약을 먼저 확인하며 `after`는 실행 순서,
output template은 실제 데이터 전달에 사용한다. read → 판단 → click을
무조건 실행하는 고정 흐름으로 만들지 않는다.

도구 호출을 묶는 것만으로 DOM 응답이 작아지지는 않는다. 필요한 영역·대상만
반환하는 도구 계약이 없다면 그 제한을 남긴다. 존재하지 않는 scope/selector
읽기 인자나 임의 JavaScript 실행을 이 스킬에서 만들어내지 않는다.

검색 문법: [Slack 공식 검색 안내](https://slack.com/help/articles/202528808-Search-in-Slack).
