# One-click local sandbox autoboot 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T18:17:12+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-local-sandbox-autoboot-linux-r1`
- 적용 대상: one-click image와 classic keeper preset sandbox admission
- 결정 상태: `추적 필요`

## 근거

- 항목: one-click classic preset의 documented local sandbox는 해당 image에서만
  명시적으로 opt-in돼야 한다.
- 출처: preset 문서/TOML, exact-head image Env, fresh/restart autoboot와 supervisor
  logs
- 확인일시: `2026-08-30T18:17:12+09:00`
- 신뢰도: `High`
- 제한조건: Linux/arm64 Docker one-click image와 classic preset에서 측정했다.
- Delta: Dockerfile.oneclick에 local playground hatch를 명시한다.

## 검증

- 1차: baseline fresh/restart가 0/4이고 supervisor가 30초마다 같은 네
  materialization failure를 반복함을 확인했다.
- 2차: install-script focused test가 image opt-in 선언을 고정했다.
- 3차: fixed fresh/restart가 4/4이며 sandbox/reconcile failure 0임을 확인했다.
- 재현 결과: 성공. sandbox admission loop가 사라졌다.

## 불확실성

- 미확인 항목: valid provider key를 사용한 장기 keeper turn과 Execute command.
- 영향: provider/turn/command 경로 회귀는 이번 empty-key run만으로 배제할 수 없다.
- 추가 확인 필요: disposable credential-backed environment에서 한 turn과 bounded
  in-container Execute를 별도 검증한다.

## 적용범위

- 영향 받는 영역: Dockerfile.oneclick image Env, classic preset 설명, static
  regression test.
- 제약/배제: global local sandbox default, host Docker socket, nested container,
  native/deployed runtime은 바꾸지 않았다.
- 롤백 조건: classic autoboot가 다시 0/4이거나 image 밖에서 local sandbox가
  자동 허용되거나 in-container Execute가 host boundary를 벗어나면 롤백한다.
