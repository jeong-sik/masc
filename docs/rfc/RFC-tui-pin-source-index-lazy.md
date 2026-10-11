---
rfc: "tui-pin-source-index-lazy"
title: "TUI 스크롤 위치 고정용 소스 색인은 필요할 때만 만든다"
status: Rejected
created: 2026-10-11
updated: 2026-10-11
author: claude
supersedes: []
superseded_by: null
related: ["tui-lazy-block-projection"]
implementation_prs: []
---

# RFC: 스크롤 위치 고정용 소스 색인을 필요할 때만 만든다

## 0. 요약

채팅 화면은 매 프레임 보이는 본문 행마다 원본 글자 위치(source position)를 찾아 스크롤
위치 고정(pin)에 저장한다. 이 색인을 만들려고 entry마다 마크다운을 한 번 더 렌더링하고,
PageUp 한 번이 화면 전체를 새 entry로 바꾸기 때문에 키마다 약 20개를 새로 만든다. 이
문서는 이 색인을 pin이 실제로 쓰이는 순간까지 미루는 안을 제안한다. 코드는 바꾸지 않는다.

## 1. 배경 (실측)

측정 조건: 한 대의 Mac, 60x200 PTY, 캡처한 이력(4563행)을 스텁 프록시로 서빙,
PageUp 300번 연속. TUI는 main에 #42262, #42275, #42286을 합친 빌드. 2026-10-11.

### 1.1 프레임에서 차지하는 몫

프레임 빌드는 p50 약 7.7ms, p95 약 18ms다. 그중 `chat.scroll_feedback`
(`scroll_position_for_window`)가 구간별 p50 3~5ms, p95 5~10ms다. chat 단계
(`rows`, `layout_entries`, `blocks`, `merge`, `window`) 합계는 3~4ms다.

`scroll_position_for_window` 안을 나누면 `points` 계산이 전부이고 `searched`, `held`,
`pin`은 0.0ms다.

### 1.2 `points`가 하는 일과 왜 비싼가

`window.body_positions`(보이는 본문 행 약 45개)마다 `source_body entry_index`로 그 행의
원본 위치를 찾는다. `source_body`는 entry마다 마크다운을 원본 위치 지도와 함께 다시 렌더링해서
색인(`source_body_index`)을 만들고, `Entry_cache`(용량 64)에 entry 객체로 캐시한다.

603번의 호출 중 390번에서 색인을 새로 만들었고(합계 3,800번, 한 번에 많으면 20개),
보이는 행이 처음 나타나는 프레임에서 생긴다. 색인 하나를 만드는 데는 화면에 그리는 렌더와
별개의 마크다운 렌더가 든다.

### 1.3 이 색인을 읽는 곳 (정정)

초안은 "새 내용이 없고 키도 없는 프레임에서 pin의 값은 읽히지 않는다"고 썼다. 이것은
틀렸다. `requested_scroll_from_pin`은 `pin_mode`가 `Follow_live`가 아니면 **매 프레임**
저장한 `pin_points`로 요청 스크롤 위치를 계산하고(`body_row_of_point`가 `source_body`를
부른다), 그 결과가 화면의 스크롤이다. 스크롤을 잡고 있는 동안(`Hold_scroll`) 색인은 프레임마다
읽힌다.

확인한 실험(2026-10-11, 합친 빌드에서 `scroll_position_for_window`를 `{ scroll =
window.scroll; pin = state.msg_scroll_pin }`로 바꿔 색인과 pin 갱신을 건너뜀): 키 300개 중
169개만 출력이 바뀌었다(합친 빌드는 300개). pin을 갱신하지 않으면 매 프레임 낡은 pin에서 요청
위치가 계산되어 PageUp이 진행하지 않는다. 즉 색인은 스크롤의 일부이고, 지연 생성은 스크롤 동작을
바꾼다. 앞서 `body_positions`를 비운 첫 실험도 `Follow_live`로 떨어져 스크롤이 0으로 돌아갔다.

## 2. 제안 (1.3의 정정으로 근거가 사라졌다)

pin을 프레임마다 완성해 저장하지 않고, 저장 시점에는 보이는 행의 entry 식별자와 본문 행
번호만 담는다(`scroll_anchor`, `body_row`, `rows_below`). 원본 글자 위치는 pin이 처음
읽히는 순간(새 내용 도착으로 위치를 되찾을 때, 다음 스크롤 키)에 `source_body`로 채운다.

그 순간에도 entry가 아직 목록에 있으면 같은 색인을 만들 수 있다. entry가 사라졌으면 지금도
되찾지 못하는 경우와 같다.

## 3. 위험

- pin이 읽히기 전에 entry의 본문이 바뀌면(보기 상태 변경, 폭 변경) 저장 시점의 행 번호와
  읽는 시점의 행 번호가 달라질 수 있다. 지금은 저장 시점에 원본 위치를 같이 붙여 두기
  때문에 이 경우에도 위치를 되찾는다. 미루면 이 보장이 약해질 수 있고, 어떤 경우인지
  테스트로 정해야 한다.
- 검색 pin(`Hold_search`)은 원본 위치가 의미 자체라서 미루지 않는다.

## 4. 대안

| 안 | 장점 | 단점 |
|---|---|---|
| 화면에 그린 마크다운 결과에서 색인을 같이 만든다 | 렌더 한 번 | 그리는 경로와 색인 경로를 하나로 묶는 큰 변경. 그리는 쪽 캐시 키와 색인 캐시 키가 다르다 |
| 보이는 행 수를 줄여 점을 몇 개만 저장 | 변경이 작다 | pin의 복구력이 줄어든다. "저장한 바이트가 모두 사라져도 오래된 거리가 성공한 pin이 되면 안 된다"는 현재 설계와 충돌한다 |
| `Entry_cache` 용량을 키운다 | 변경이 한 줄 | 문제는 용량이 아니라 처음 보이는 entry의 첫 색인이다. 효과가 없다 |

## 5. 열린 질문

1. pin이 처음 읽히는 순간들을 빠짐없이 센 목록. 이 문서는 `requested_scroll_from_pin`과 스크롤
   키 경로만 확인했다.
2. 제안 2의 "미루기"가 `Hold_scroll` 키 연타에서 오히려 더 비싸지는지(키마다 색인을 만든다).
   지금은 프레임마다 만들지만 연타 중에는 어차피 매 프레임 화면이 바뀐다.
3. 효과의 상한. 이 단계가 사라지면 프레임 빌드가 7.7ms에서 4ms대가 될 걸로 추정하지만
   구현으로 확인하지 않았다.

## 6. 검증 계획

- 단위 테스트: 저장한 pin이 새 내용 도착 뒤에 같은 글자 위치로 되찾아지는지, entry가 사라진
  경우, 폭·보기 상태가 바뀐 경우, 검색 pin.
- 변이 확인: 위치를 되찾지 않게 바꾸면 위 테스트가 실패해야 한다.
- 재측정: PageUp 300번 연속, origin/main과 12쌍 이상, load average 30 미만. 지표는 p50, p90,
  p95, p99.
