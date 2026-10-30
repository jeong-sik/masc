# One-click host-port authority 근거 기록 R2

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T18:08:04+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-host-port-authority-linux-r2`
- 적용 대상: one-click public mapped identity와 wildcard internal listener identity
- 결정 상태: `확정`

## 근거

- 항목: explicit public base URL을 추가해도 wildcard listener의 local loopback
  identity와 Docker healthcheck가 유지돼야 한다.
- 출처: request-authority focused suite, exact-head Linux fresh/restart public/internal
  health, Docker health, public MCP responses
- 확인일시: `2026-08-30T18:08:04+09:00`
- 신뢰도: `High`
- 제한조건: Linux/arm64 Docker의 local HTTP port mapping에서 측정했다.
- Delta: wildcard bind configured identity를 shared advertised-host 규칙의 loopback
  peer로 표현한다.

## 검증

- 1차: R1 public-only 변경에서 internal `localhost:8080`이 400으로 퇴행함을
  재현했다.
- 2차: typed suite 26/26으로 internal `Configured_bind`, public
  `Explicit_trusted_host`, wrong-port `Untrusted`를 고정했다.
- 3차: r18 fresh/restart에서 public/internal 200, Docker healthy, public MCP status
  success, adversarial Host 400을 확인했다.
- 재현 결과: 성공. 두 정상 identity를 함께 유지하면서 다른 host/port는
  fail-closed했다.

## 불확실성

- 미확인 항목: HTTPS reverse proxy와 public DNS.
- 영향: canonical public scheme/host/port가 local compose default와 다르면
  operator override와 auth 정책이 필요하다.
- 추가 확인 필요: proxy fixture에서 external HTTPS authority와 internal loopback
  health를 함께 검증한다.

## 적용범위

- 영향 받는 영역: one-click compose public base URL, wildcard bind trust-policy
  construction, HTTP/1.1 and HTTP/2 shared authority policy.
- 제약/배제: arbitrary Host admission, forwarded headers, deployed runtime, global
  auth requirements는 바꾸지 않았다.
- 롤백 조건: internal/public 정상 identity 중 하나가 거절되거나 다른 host/port가
  admitted되거나 MCP/OAuth projection이 request authority와 어긋나면 롤백한다.
