# One-click local sandbox autoboot Linux runtime R1

## 결과

classic one-click preset의 4 keeper는 의도적으로 `sandbox_profile="local"`을
사용하지만 image가 `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND`를 명시하지 않았다. global
fail-closed gate가 모두를 거절해 fresh/restart 모두 `initial pass 0/4`였고,
supervisor가 30초마다 같은 materialization을 반복했다.

one-click image에만 `MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1`을 명시했다. container가
classic demo의 isolation boundary라는 기존 preset 계약을 실제 runtime admission과
맞춘다. 다른 image와 native server의 global default는 바꾸지 않았다.

## exact identity

- source change commit: `707183d7684c3578f783def8a98c481e0c99c867`
- Linux measurement composition/embedded commit:
  `d8a5809049a7ad63be8d256cba82a37a63d43d4f`
- Linux/arm64 image digest:
  `sha256:4507f9b0f2e5fece391198c29bbcf01ced9b25ccc5b9f5b4934dffe19cae2650`
- binary SHA-256:
  `81eab09dfdd8dc65cb26a205a60cba585d2631c08d4fe68a32cd3918cff4249`
- fresh runtime instance: `01a051f4-1b8d-7000-8df4-81ed1b9763cc`
- restarted runtime instance: `01a051f4-fb45-7000-b205-41e55bd93f98`
- isolated published port: `9550`

image inspect, container `build-commit`, `/health?full=1`, binary SHA가 같은
composition head를 가리켰다. image config Env에
`MASC_EXEC_ALLOW_LOCAL_PLAYGROUND=1`이 실제 포함됐다.

## baseline r19

직전 composition `24e2e5f00fe9b51853224fb8ffbd6b57b67a9205`, image
`sha256:7844ae0dfb133736d7d50424847fef0089e7bc8efeea473680280c39c9cea29c`,
binary `2cfb8aaf7ddc054d54ef6546f421ce3ba49807b3ba37092ebd886da62f9eb144`
에서 classic team을 key 없이 시작했다.

- initial autoboot: 각 keeper 1회 sandbox validation error
- reconcile: 각 keeper 즉시 1회 + 30초 뒤 1회 실패
- `initial pass 0/4 keepers started`
- health: `overall_status=blocked`, `keeper_fibers=0`
- 실제 restart: 새 runtime instance에서 다시 0/4와 같은 4개 실패

provider call 이전 sandbox admission에서 끝났으므로 API key 유무는 baseline
원인과 무관하다.

## fixed r20

fresh에서 backend, frontend, qa, tech_lead 모두 TOML에서 materialize되고 keepalive를
시작했다. `initial pass 4/4 keepers started`는 1회, sandbox validation failure와
missing-meta reconcile failure는 각각 0건이었다.

같은 volume의 실제 restart에서도 `initial pass 4/4`, sandbox/reconcile failure
0건을 유지했다. MASC container는 graceful shutdown exit 0이고 volume은
정지·보존했다.

## credential 경계

이번 adversarial run은 `OLLAMA_CLOUD_API_KEY`를 빈 값으로 유지했다. sandbox가
열린 뒤 각 keeper의 첫 turn은 Ollama Cloud에서 401을 받아 failing으로 전환했고,
health는 `overall_status=blocked`, `keeper_fibers=0`이었다. 이는 sandbox 수정과
분리된 credential admission 문제다. “team이 provider turn까지 건강하다”는 주장은
하지 않는다.

## 검증

- `scripts/dune-local.sh build test/test_install_script.exe`
- exact `config_seed 7`: one-click image local sandbox opt-in 1/1
- `ocamlformat --check test/test_install_script.ml`
- `git diff --check`
- fresh/restart Linux classic team autoboot
- baseline 30초 supervisor 반복과 fixed failure count 비교

## 남은 경계

one-click image는 shell Execute를 그 container 내부에서 허용한다. host Docker
socket은 mount하지 않았고 nested Docker 권한도 추가하지 않았다. production
isolation이 필요한 keeper는 기존 문서대로 native server + docker/microvm/remote
profile을 사용해야 한다.

empty provider key를 미리 알고도 네 번의 401 turn을 실행하는 경로는 별도
fail-fast 이슈로 다룬다. 운영 중인 8935 server와 deployed
`/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] Git remote-context build, image inspect, container `build-commit`,
  fresh/restart health와 autoboot/supervisor/provider logs,
  2026-08-30T18:17:12+09:00 확인, 신뢰도 High.
