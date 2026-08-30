# One-click host-port authority 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T17:57:04+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-host-port-authority-linux-r1`
- 적용 대상: one-click compose published HTTP identity
- 결정 상태: `추적 필요`

## 근거

- 항목: one-click compose가 광고하는 mapped host port는 server의 explicit trusted
  HTTP identity와 같아야 한다.
- 출처: rendered compose JSON, exact-head Linux image identity, same-image A/B,
  fresh/restart health와 adversarial Host responses
- 확인일시: `2026-08-30T17:57:04+09:00`
- 신뢰도: `High`
- 제한조건: local Linux/arm64 Docker port mapping과 HTTP loopback identity에서
  측정했다.
- Delta: one-click service에 mapped localhost URL을 `MASC_HTTP_BASE_URL`로
  전달한다.

## 검증

- 1차: 공식 compose projection이 published 9546/target 8080이면서 explicit base
  URL을 같은 9546으로 렌더링하는지 확인했다.
- 2차: 같은 image에서 env 없는 control은 정상 mapped Host 400, internal Host 강제
  시 200임을 확인했다.
- 3차: fixed fresh/two restarts는 정상 mapped Host와 dashboard 200을 유지하고,
  foreign Host와 wrong-port loopback Host는 400으로 차단했다.
- 재현 결과: 성공. advertised identity가 usable해졌고 fail-closed Host boundary는
  유지됐다.

## 불확실성

- 미확인 항목: HTTPS reverse proxy와 public DNS deployment.
- 영향: proxy의 canonical scheme/host/port가 compose local default와 다르면
  operator override가 필요하다.
- 추가 확인 필요: reverse proxy fixture에서 explicit public base URL과 Origin/OAuth
  metadata를 별도 검증한다.

## 적용범위

- 영향 받는 영역: `docker-compose.yml`의 `masc-oneclick` environment와 그 public
  request-authority projection.
- 제약/배제: global authority classifier, forwarded headers, image package set,
  deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: mapped localhost가 다시 거절되거나, 다른 host/port가 admitted되거나,
  internal keeper transport가 mapped host port를 listener로 오인하면 롤백한다.
