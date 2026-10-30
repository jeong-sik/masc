# One-click empty-key autoboot Linux runtime R1

## 결과

one-click entrypoint는 빈 `OLLAMA_CLOUD_API_KEY`를 이미 감지하면서도 warning만
남기고 classic team을 autoboot했다. sandbox admission이 정상인 image에서는 네
keeper가 각각 약 82KB autonomous request를 Ollama Cloud로 보내 401을 받고 모두
failing이 됐다.

classic + empty key + bootstrap gate 미지정일 때만 entrypoint가
`MASC_KEEPER_BOOTSTRAP_ENABLED=false`를 export한다. server/dashboard와 truthful
blocked health는 유지하되 known-unauthenticated provider request는 시작하지 않는다.
다른 preset과 operator의 explicit bootstrap 값은 보존한다.

## exact identity

- source change commit: `3526336b8e40b74f1497392a121134c74e850808`
- Linux measurement composition/embedded commit:
  `16920e65496614c86ef597b17454d57a79b6cecd`
- Linux/arm64 image digest:
  `sha256:fce749cd04b57c255696ca9f296e741d27fba8b8ac1e53e4877ba3ceaabb37d3`
- binary SHA-256:
  `da9792d29190f6d8c1b8af0aada8c052299f29d8722108d07d74e7e7f9fc549a`
- implicit fresh runtime instance: `01a051fb-5206-7000-9742-83d912470f71`
- implicit restarted runtime instance: `01a051fc-b072-7000-ab1b-a79495492a4a`
- explicit-override runtime instance: `01a051fc-4cff-7000-a5b8-7ad6c1568793`

Git remote context와
`--build-arg BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다. image inspect,
container `build-commit`, `/health?full=1`, binary hash가 같은 composition head를
가리켰다.

## baseline r20

직전 composition `d8a5809049a7ad63be8d256cba82a37a63d43d4f`, image
`sha256:4507f9b0f2e5fece391198c29bbcf01ced9b25ccc5b9f5b4934dffe19cae2650`,
binary `81eab09dfdd8dc65cb26a205a60cba585d2631c08d4fe68a32cd3918cff4249`
에서 empty key classic team은 4/4로 materialize된 뒤 첫 turn 네 개를 실제
전송했다.

- `chat/completions` → 401
- request body structural size: 81,822–81,988 bytes
- `keeper cycle FAILED ... Auth error: Unauthorized`: 4건
- health: `overall_status=blocked`, `keeper_fibers=0`

`startup verified 4 bootable keeper credential(s)`는 MASC 내부 token sync이며 provider
credential 성공을 뜻하지 않는다.

## fixed implicit 경로

fresh entrypoint는 missing-key warning과 함께
`classic keeper autoboot disabled until OLLAMA_CLOUD_API_KEY is set`을 1회 기록했다.
server는 global gate disabled를 명시하고 dashboard/health를 `serving/ready`로
열었다.

35초 관찰 창의 count는 다음과 같다.

- provider `chat/completions`: 0
- unauthorized terminal: 0
- keeper cycle failure: 0
- sandbox failure: 0
- autoboot-disabled marker: 1

health의 `overall_status=blocked`, `keeper_fibers=0`은 configured team이 credential
부재로 비활성이라는 사실을 숨기지 않는다. 오류 로그는 0이었다.

같은 volume의 실제 restart에서도 새 runtime instance, guard marker 1,
autoboot-disabled marker 1, provider request 0, keeper cycle failure 0을 유지했다.
container는 graceful shutdown exit 0이고 volume은 정지·보존했다.

## explicit override

별도 same-image control에 `MASC_KEEPER_BOOTSTRAP_ENABLED=true`를 명시했다. entrypoint
guard marker는 0이었고 `initial pass 4/4` 뒤 401 keeper failures가 관찰됐다. 즉
operator override를 silent rewrite하지 않는다.

## 검증

- `bash -n scripts/docker-entrypoint.sh`
- `scripts/dune-local.sh build test/test_install_script.exe`
- exact `config_seed 7`: empty-key implicit classic autoboot guard 1/1
- `ocamlformat --check test/test_install_script.ml`
- `git diff --check`
- fixed fresh 35초 no-provider window
- fixed actual restart
- explicit bootstrap=true same-image control

## 남은 경계

operator가 volume의 runtime default를 credential-free local provider로 바꿨지만
classic preset과 empty Ollama key를 유지하면 implicit guard가 보수적으로 autoboot를
막는다. 이 경우 `MASC_KEEPER_BOOTSTRAP_ENABLED=true`를 명시해야 한다. entrypoint가
runtime TOML을 추론해 다른 provider credential을 판정하는 기능은 추가하지 않았다.

운영 중인 8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] Git remote-context build, image inspect, container `build-commit`,
  fresh/restart/override health와 entrypoint/autoboot/provider logs,
  2026-08-30T18:25:20+09:00 확인, 신뢰도 High.
