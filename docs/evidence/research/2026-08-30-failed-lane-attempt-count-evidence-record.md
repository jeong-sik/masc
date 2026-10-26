# Failed lane attempt count 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T21:00:59+09:00`
- 작성자: `Codex`
- 결정 ID: `failed-lane-attempt-count-linux-r1`
- 적용 대상: failed multi-candidate Keeper execution receipt
- 결정 상태: `추적 필요`

## 근거

- 항목: winner가 없는 lane도 실제 dispatch한 candidate 수를 receipt에 보존해야 하며,
  successful fallback 여부와 attempt count는 별도 사실이어야 한다.
- 출처: isolated two-candidate Linux 최초 기동/재시작 receipt와 focused OCaml test
- 확인일시: `2026-08-30T21:00:59+09:00`
- 신뢰도: `High`
- 제한조건: 두 candidate가 모두 HTTP 429로 실패하는 lane으로 측정했다.
- Delta: runtime-attempt callback이 마지막 candidate index를 receipt ref에 기록하고,
  fallback-applied는 turn success와 later index가 모두 있을 때만 true로 유지한다.

## 검증

- 1차: baseline은 Keeper당 두 provider POST를 관측했지만 4/4 receipt가
  `lane_attempt_count=1`을 기록했다.
- 2차: failed/successful two-candidate pure assertions와 terminal matrix 147,200건이
  통과했다.
- 3차: fixed 최초 기동과 실제 `docker restart`에서 총 8건이
  `lane_attempt_count=2`, `fallback_applied=false`, runtime outcome failed를 기록했다.
- 재현 결과: 성공. 마지막 candidate model과 candidate 수를 보존하면서 성공하지 않은
  fallback은 만들지 않았다.

## 불확실성

- 미확인 항목: 3개 이상 candidate가 모두 실패하는 exact Linux lane.
- 영향: callback은 max 0-based index를 쓰므로 pure logic상 확장되지만 runtime 측정은
  2-candidate lane에 한정한다.
- 추가 확인 필요: Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: runtime-attempt observation ref와 receipt lane facts.
- 제약/배제: lane routing, retry, disposition, provider call, selected model은 바꾸지 않는다.
- 롤백 조건: successful second candidate가 fallback false로 기록되거나 failed lane이
  runtime outcome passed-to-next-model로 오분류되면 롤백한다.
