# Long-name Keeper purge 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T14:14:04+09:00`
- 작성자: `Codex`
- 결정 ID: `keeper-purge-long-name-r1`
- 적용 대상: dashboard Keeper purge resolver와 completion artifact cleanup
- 결정 상태: `추적 필요`

## 근거

- 항목: creation-valid Keeper name은 resolver와 completion 전 구간에서 같은
  typed Keeper-name 계약을 사용한다. plain-agent 64자 계약은 보존한다.
- 출처: `Keeper_id.Keeper_name.max_length`, `git rev-parse HEAD`, binary
  `build-commit`, `shasum -a 256`, isolated purge response/log/post-state,
  Keeper metrics/chat
- 확인일시: `2026-08-30T14:14:04+09:00`
- 신뢰도: `High`
- 제한조건: 75자에서 실측했다. 최대 128자 전체와 non-ASCII는 측정하지
  않았다. portable grammar만 지원한다.
- Delta: Keeper resolver와 Keeper-owned agent artifact bundle만 typed
  Keeper validator로 바꿨다. plain-agent route는 그대로다.

## 검증

- 1차: creation max 128과 generic agent max 64의 source contract를 추적했다.
- 2차: exact commit `f04d50dff57b3a49143f8786aebdec5f321a426b`, binary
  SHA-256 `39ceeef14183564c97527e66eff17105f8da3592a3d27b0a2d1b202e7d81521b`,
  focused resolver/completion 2/2를 확인했다.
- 3차: exact binary로 75자 Keeper 생성→source fact 생성→purge→server
  restart→same-name fresh turn을 실행했다.
- 재현 결과: 성공. purge 202, 네 artifact absent, recovery error 0,
  fresh turn `Succeeded`, dynamic context 0 bytes였다.

## 불확실성

- 미확인 항목: 128자 boundary runtime, filesystem별 NAME_MAX 차이.
- 영향: 극단 boundary에서 별도 path suffix가 NAME_MAX를 넘을 수 있다.
- 추가 확인 필요: 128자 exact create/purge probe를 다음 반복에 추가한다.

## 적용범위

- 영향 받는 영역: dashboard Keeper purge admission, durable completion의
  Keeper-owned agent artifacts.
- 제약/배제: plain-agent purge, Keeper name grammar, store migration,
  deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: 75자 purge가 400/blocked가 되거나 completion record가
  재기동에 남거나 plain namespaced agent fallthrough가 깨지면 롤백한다.
