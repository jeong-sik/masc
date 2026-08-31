# One-click host-port authority Linux runtime R2

## 결과

R1은 mapped public Host를 복구했지만 explicit public URL이 wildcard bind의 자동
loopback identity를 대체해 container 내부 `localhost:8080` healthcheck를 400으로
만들었다. wildcard socket bind는 wire authority가 아니므로 configured identity를
공유 advertised-host 규칙으로 loopback peer에 접어, internal listener와 public
mapped URL을 서로 다른 trust class로 함께 유지했다.

최종 r18은 public mapped health, internal healthcheck, Docker HEALTHCHECK, public
MCP가 fresh와 실제 restart에서 모두 성공했다. foreign Host와 wrong-port loopback은
계속 fail-closed했다.

## exact identity

- compose identity commit: `da9e8d4f90988856f7bf56f23fd3c4584354bb38`
- wildcard bind identity commit: `e5d8bb9ba358d0c569926d2d85e888db6a645f73`
- Linux measurement composition/embedded commit:
  `24e2e5f00fe9b51853224fb8ffbd6b57b67a9205`
- Linux/arm64 image digest:
  `sha256:7844ae0dfb133736d7d50424847fef0089e7bc8efeea473680280c39c9cea29c`
- binary SHA-256:
  `2cfb8aaf7ddc054d54ef6546f421ce3ba49807b3ba37092ebd886da62f9eb144`
- fresh runtime instance: `01a051eb-812d-7000-84e3-3e42107a98ee`
- restarted runtime instance: `01a051ec-590c-7000-8162-bcc454e0fd89`
- isolated published/listener ports: `9548` / `8080`

Git remote context와
`--build-arg BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다. container
`build-commit`, public/internal `/health?full=1`, binary hash가 같은 composition
head를 가리켰다.

## trust identities

fresh와 restart에서 다음 결과가 같았다.

- public `http://localhost:9548/health?full=1` → 200
- internal container `http://localhost:8080/health?full=1` → 200
- public transport projection → `http://127.0.0.1:9548`
- internal transport projection → `http://127.0.0.1:8080`
- `Host: attacker.example:9548` → 400 `request_authority_untrusted`
- `Host: localhost:9999` → 400 `request_authority_untrusted`

configured internal listener는 `Configured_bind`, mapped public identity는
`Explicit_trusted_host`로 분리된다. request header를 trust-policy input으로 쓰지
않는다.

## Docker와 MCP

image의 기존 HEALTHCHECK `curl http://localhost:${PORT}/health`가 fresh와 restart
뒤 실제 `healthy`였다. public mapped URL에서 Host override 없이 MCP initialize와
39-tool `tools/list`를 완료했고, advertised read-only `masc_status`는 fresh와
restart 모두 `isError=false`, `resultType=complete`였다.

health의 `internal_mcp_auth`도 두 identity에서 `status=ok`,
`keeper_internal_runtime_mcp_ready=true`였다. authority 관련 오류 로그와 fatal
로그는 각각 0건이었다.

## focused 검증

- request-authority suite 26/26
- wildcard bind + internal 8080 + explicit public 9546 typed regression case
- `ocamlformat --check` on changed OCaml files
- `git diff --check`
- fresh/restart public and internal HTTP
- fresh/restart Docker HEALTHCHECK
- fresh/restart public MCP `masc_status`
- foreign Host and wrong-port loopback rejection

container는 graceful shutdown exit 0이고 volume은 정지·보존했다. 운영 중인 8935
server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 남은 경계

wildcard bind의 local configured identity는 loopback peer로만 접힌다. 이는
wildcard를 임의 DNS Host 신뢰로 바꾸지 않는다. reverse proxy/HTTPS/public DNS는
계속 operator의 explicit `MASC_HTTP_BASE_URL`과 인증 설정이 필요하다.

## 근거

- [근거] focused test output, Git remote-context build log, image inspect,
  container `build-commit`, fresh/restart public/internal health, Docker health,
  MCP responses, adversarial Host responses, 2026-08-30T18:08:04+09:00 확인,
  신뢰도 High.
