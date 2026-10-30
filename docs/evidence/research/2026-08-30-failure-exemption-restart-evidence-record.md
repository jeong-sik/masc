# Failure exemption restart 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T22:44:51+09:00`
- 작성자: `Codex`
- 결정 ID: `failure-exemption-restart-linux-r1`
- 적용 대상: Keeper bounded crash-accounting exemptions
- 결정 상태: `추적 필요`

## 근거

- 항목: deterministic failure의 bounded exemption consumption은 process restart보다 오래 살아야 한다.
- 출처: exact-source Linux BuildKit image, internal fake provider, durable exemption/streak
  records, Keeper log, `/health?full=1`
- 확인일시: `2026-08-30T22:44:51+09:00`
- 신뢰도: `High`
- 제한조건: 한 Keeper와 typed HTTP 400 InvalidRequest path를 실측했다.
- Delta: process-local InvalidRequest/empty-completion counters를 current-only durable record로 교체했다.

## 검증

- 1차: baseline restart가 exhausted budget을 reset해 durable streak 5를 그대로 유지함을 확인했다.
- 2차: focused tests에서 두 budget, reset, per-Keeper isolation, process boundary, unknown schema
  fail-closed가 통과했다.
- 3차: fixed Linux restart 전 budget 3, restart 첫 failure 뒤 budget 4와 streak 1을 확인했다.
- 재현 결과: 성공. restart로 exemption을 다시 얻는 escape가 닫혔다.

## 불확실성

- 미확인 항목: empty-completion wire-level restart와 durable write/remove I/O fault injection.
- 영향: typed unit boundary는 통과했지만 별도 provider dialect와 filesystem failure 관측을 더할 수 있다.
- 추가 확인 필요: Draft PR CI/review bot과 transient-transport counter의 별도 restart lifetime.

## 적용범위

- 영향 받는 영역: InvalidRequest/empty-completion failure accounting, successful turn/operator clear reset.
- 제약/배제: retry scheduler, provider protocol, runtime lane, checkpoint, transient-transport budget은
  바꾸지 않는다.
- 롤백 조건: restart 첫 failure가 carried budget을 쓰지 않거나 malformed record가 exemption을
  주거나 successful reset 뒤 record가 부활하면 롤백한다.
