# Keeper provider rejection disposition 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T20:39:38+09:00`
- 작성자: `Codex`
- 결정 ID: `provider-rejection-disposition-linux-r1`
- 적용 대상: terminal provider-runtime failure execution receipt
- 결정 상태: `추적 필요`

## 근거

- 항목: same-turn fallback이 없었던 terminal provider rejection은
  `fail_open_next_runtime` 대신 `retry_later`로 기록해야 한다.
- 출처: isolated fake-provider Linux 최초 기동/재시작 receipt와 focused OCaml test
- 확인일시: `2026-08-30T20:39:38+09:00`
- 신뢰도: `High`
- 제한조건: OpenAI-compatible HTTP 400 invalid request와 single-candidate lane으로
  측정했다.
- Delta: generic typed provider-runtime terminal arm만 `retry_later`로 바꾸고 reason은
  `provider_runtime_error`로 보존했다.

## 검증

- 1차: baseline 4건은 fallback false, `deferred_next_runtime=none`인데도
  `fail_open_next_runtime`을 기록했다.
- 2차: independent field matrix 147,200건이 mismatch 0으로 통과했다.
- 3차: fixed 최초 기동과 실제 `docker restart`에서 각각 4건, 총 8건이
  `retry_later / provider_runtime_error`를 기록했다.
- 재현 결과: 성공. 8건 모두 attempt/lane attempt 1/1, fallback false,
  degraded retry false, rotation empty였다.

## 불확실성

- 미확인 항목: HTTP 402/404와 provider response parse failure의 exact runtime surface.
- 영향: typed matrix는 같은 generic provider-runtime arm을 검증하지만 Linux 측정은 400
  invalid request 한 class에 한정한다.
- 추가 확인 필요: stacked Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: generic provider-runtime receipt classifier와 Keeper manuals.
- 제약/배제: transient network reason, config/auth operator action, retry cadence, failure
  accounting, fleet health는 바꾸지 않는다.
- 롤백 조건: actual same-turn fallback receipt가 `retry_later`로 오분류되거나 generic
  provider reason이 사라지면 롤백한다.
