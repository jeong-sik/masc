# Keeper config-error disposition 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T19:50:50+09:00`
- 작성자: `Codex`
- 결정 ID: `config-error-disposition-linux-r1`
- 적용 대상: Keeper execution receipt의 terminal config-error operator disposition
- 결정 상태: `추적 필요`

## 근거

- 항목: fallback을 실행하지 않은 terminal config error는
  `fail_open_next_runtime`이 아니라 `operator_action_required`로 기록해야 한다.
- 출처: exact-head Linux 최초 기동/재시작 execution receipt와 focused OCaml tests
- 확인일시: `2026-08-30T19:50:50+09:00`
- 신뢰도: `High`
- 제한조건: one-click classic preset의 missing `OLLAMA_CLOUD_API_KEY`로 측정했다.
- Delta: closed operator disposition을 추가하고 receipt parser, dashboard display,
  operator broadcast, 영문/한국어 manual을 같은 wire value에 맞췄다.

## 검증

- 1차: baseline receipt 4건은 fallback/rotation이 없는데도
  `fail_open_next_runtime`을 기록했다.
- 2차: terminal-reason field matrix 147,200건과 dashboard display focused case가
  통과했다.
- 3차: fixed exact-source Linux 최초 기동과 실제 `docker restart`에서 각각
  4건, 총 8건의 새 receipt가 `operator_action_required`를 기록했다.
- 재현 결과: 성공. 모든 fixed receipt는 provider attempt 0, fallback false,
  rotation empty를 유지했고 fleet health는 `blocked`였다.

## 불확실성

- 미확인 항목: credential을 수정한 뒤 같은 persisted Keeper가 자동 회복하는 경로.
- 영향: 이번 기록은 terminal failure의 truthfulness만 증명하며 recovery latency는
  주장하지 않는다.
- 추가 확인 필요: Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: execution receipt wire/parser, operator broadcast 판정,
  dashboard disposition display, Keeper manual.
- 제약/배제: provider routing, fallback 실행, keepalive cadence, one-click entrypoint,
  deployed 8935 runtime은 바꾸지 않았다.
- 롤백 조건: 새 wire value를 기존 receipt consumer가 읽지 못하거나 non-terminal
  fallback receipt가 closed disposition으로 오분류되면 롤백한다.
