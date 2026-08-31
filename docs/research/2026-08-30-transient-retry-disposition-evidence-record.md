# Keeper transient retry disposition 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T20:09:37+09:00`
- 작성자: `Codex`
- 결정 ID: `transient-retry-disposition-linux-r1`
- 적용 대상: terminal transient provider failure execution receipt
- 결정 상태: `추적 필요`

## 근거

- 항목: same-turn fallback이 없었던 terminal network/timeout failure는
  `fail_open_next_runtime` 대신 `retry_later`로 기록해야 한다.
- 출처: exact-head network-none Linux 최초 기동/재시작 receipt와 focused OCaml tests
- 확인일시: `2026-08-30T20:09:37+09:00`
- 신뢰도: `High`
- 제한조건: one-click classic preset, single-candidate lane, DNS failure로 측정했다.
- Delta: typed disposition wire/parser/display/manual을 추가하고 transient terminal arm만
  새 값으로 분리했다.

## 검증

- 1차: baseline 4건은 `deferred_next_runtime=none`, fallback false인데도
  `fail_open_next_runtime`을 기록했다.
- 2차: independent field matrix 147,200건과 typed display focused case가 통과했다.
- 3차: fixed Linux 최초 기동과 실제 `docker restart`에서 각각 4건, 총 8건의 새
  receipt가 `retry_later / transient_runtime_retry`를 기록했다.
- 재현 결과: 성공. 8건 모두 attempt/lane attempt 1/1, fallback false,
  degraded retry false, rotation empty였다.

## 불확실성

- 미확인 항목: 실제 network recovery 후 성공 turn으로 전환되는 end-to-end 경로.
- 영향: 새 disposition은 관측된 현재 turn과 이후 keepalive 가능성만 표현하며 recovery
  성공이나 latency를 주장하지 않는다.
- 추가 확인 필요: stacked Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: receipt disposition wire/parser, operator broadcast 판정,
  dashboard display, Keeper manual.
- 제약/배제: retry cadence, crash accounting, fleet health는 바꾸지 않는다. 무제한
  transient retry와 false-health loop는 #31958에서 별도로 추적한다.
- 롤백 조건: actual same-turn fallback receipt가 `retry_later`로 오분류되거나 새 wire를
  current consumer가 읽지 못하면 롤백한다.
