# One-click host-port authority Linux runtime R1

## 결과

공식 one-click compose는 `${MASC_HOST_PORT:-8935}:8080`을 publish하고
`http://localhost:8935/dashboard`를 안내하지만, server에는 container listener
`:8080`만 configured identity로 전달했다. 따라서 browser와 curl의 정상
`Host: localhost:8935`가 HTTP 400 `request_authority_untrusted`로 거절됐다.

one-click service에
`MASC_HTTP_BASE_URL=http://localhost:${MASC_HOST_PORT:-8935}`를 명시했다. 이는
compose가 광고하는 mapped identity만 explicit trust policy에 추가한다. 전역 Host
검증이나 request-derived trust는 바꾸지 않았다.

## exact identity

- source change commit: `da9e8d4f90988856f7bf56f23fd3c4584354bb38`
- Linux measurement composition/embedded commit:
  `0c18efde2e953e80d04dd1c7555a808cc3e1cce2`
- Linux/arm64 image digest:
  `sha256:22a5ea44acf8afef75508599c317d3fc0b3f92dc74b97123c49fd0c66ab1e92e`
- binary SHA-256:
  `5fa2a1e7b64af77b95dab38f063234949c26c9588793ed6786ccf559e0d3e77d`
- fixed runtime instances:
  - `01a051e1-73a7-7000-a13d-f56ed911d570`
  - `01a051e1-ba33-7000-b983-b08133510994`
  - `01a051e2-c549-7000-837f-d07cd4196da3`
- isolated published port: `9546`
- container listener port: `8080`

Git remote context와
`--build-arg BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다. container
`build-commit`, `/health?full=1`, binary hash가 같은 composition head를 가리켰다.

## compose projection

`MASC_HOST_PORT=9546 docker compose --profile oneclick config --format json`은
아래 두 값을 함께 렌더링했다.

```text
published = 9546, target = 8080
MASC_HTTP_BASE_URL = http://localhost:9546
```

운영 중인 8935 server는 건드리지 않았다.

## same-image A/B

같은 r17 image와 binary를 두 container에 사용했다.

- control: `MASC_HTTP_BASE_URL` 없음
  - 정상 `Host: 127.0.0.1:9547` → 400 `request_authority_untrusted`
  - 진단용 강제 `Host: 127.0.0.1:8080` → 200
- fixed: `MASC_HTTP_BASE_URL=http://localhost:9546`
  - 정상 `Host: 127.0.0.1:9546` → 200
  - 정상 `Host: localhost:9546` → 200
  - dashboard redirect 뒤 final → 200

따라서 차이는 binary가 아니라 compose가 explicit mapped identity를 제공하는지다.

## adversarial Host

fixed container에서도 아래 입력은 fresh와 restart에서 계속 400이었다.

- `Host: attacker.example:9546`
- `Host: localhost:9999`

loopback alias는 같은 configured port에서만 허용되고, host 또는 port가 다른
authority는 신뢰되지 않는다.

## restart

fixed container를 두 번 실제 restart했다. 매번 Host 조작 없는
`http://localhost:9546/health?full=1`이 200이었고 runtime instance가 바뀌었다.
첫 restart 뒤 startup은 `ready`로 수렴했고 transport projection은 mapped request
authority의 `http://localhost:9546` 또는 동등한 loopback alias를 유지했다.

fixed와 control container는 모두 graceful shutdown exit 0이었다. 두 volume은
정지·보존했다.

## 검증

- `MASC_HOST_PORT=9546 docker compose --profile oneclick config -q`
- rendered compose JSON의 published/target/base URL 일치
- same-image no-env control
- fixed fresh start와 두 번의 실제 restart
- 정상 localhost/127.0.0.1 mapped Host
- adversarial foreign Host와 wrong-port loopback Host
- dashboard redirect와 final 200

## 남은 경계

이번 compose 값은 공식 문서가 안내하는 local HTTP identity를 대상으로 한다.
reverse proxy, HTTPS, public DNS를 쓰는 deployment는 기존처럼 operator가 자신의
canonical `MASC_HTTP_BASE_URL`을 명시해야 한다. 이 변경은 proxy header를 trust
source로 승격하지 않는다.

## 근거

- [근거] `docker compose config`, Git remote-context build log, image inspect,
  container `build-commit`, fresh/restart health, A/B와 adversarial curl responses,
  2026-08-30T17:57:04+09:00 확인, 신뢰도 High.
