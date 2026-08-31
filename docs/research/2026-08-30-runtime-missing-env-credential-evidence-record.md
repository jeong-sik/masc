# Runtime missing env credential 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T18:56:06+09:00`
- 작성자: `Codex`
- 결정 ID: `runtime-missing-env-credential-linux-r1`
- 적용 대상: Agent Core runtime provider dispatch
- 결정 상태: `추적 필요`

## 근거

- 항목: provider가 env credential을 선언했지만 값이 비어 있으면 HTTP 요청 전에
  typed config error로 끝내야 한다.
- 출처: exact-head Linux fresh/restart/air-gap 로그와 health, focused tests
- 확인일시: `2026-08-30T18:56:06+09:00`
- 신뢰도: `High`
- 제한조건: one-click classic preset의 Ollama Cloud Agent Core runtime에서 측정했다.
- Delta: runtime materialization은 유지하고 실제 dispatch 직전에 credential을
  검사한다.

## 검증

- 1차: baseline은 빈 key로 약 82KB 요청 네 건을 보내고 401을 받았다.
- 2차: provider config 52개, keeper turn driver 38개, runtime resolver 11개
  focused tests가 통과했다.
- 3차: fixed fresh/restart와 `--network none` 컨테이너에서 provider HTTP 흔적 없이
  모두 `provider_credential` 오류로 끝났다.
- 재현 결과: 성공. dashboard `missing_auth`, dispatch-time transform, credential-free
  provider 계약도 유지됐다.

## 불확실성

- 미확인 항목: 실제 non-empty Ollama Cloud credential을 쓴 성공 호출.
- 영향: 성공 경로의 외부 provider 응답은 이번 측정에 포함되지 않는다.
- 추가 확인 필요: Draft PR CI와 review bot 결과를 확인한다.

## 적용범위

- 영향 받는 영역: Agent Core runtime resolver와 Keeper Agent Core turn dispatch.
- 제약/배제: official clients, runtime TOML materialization, dashboard probing,
  deployed 8935 runtime은 바꾸지 않았다.
- 롤백 조건: credential-free provider 또는 transformed provider가 거부되거나,
  dashboard `missing_auth`가 HTTP를 실행하면 롤백한다.
