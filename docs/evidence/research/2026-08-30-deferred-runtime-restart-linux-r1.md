# Deferred runtime restart Linux R1

## 결과

thinking-only provider 응답은 AGENT_CORE checkpoint를 먼저 쓴 뒤 MASC accept contract에서
거절된다. 같은 turn에서 input을 다시 admit할 수 없어 lane successor는 다음 Keeper cycle로
defer된다. 기존 구현은 그 suffix를 heartbeat fiber의 OCaml `ref`에만 보관해 clean process
restart가 실패한 primary runtime을 다시 선택했다.

이번 변경은 frozen suffix를 Keeper별 strict JSON에 durable atomic write한다. restart가 파일을
읽어 successor에서 시작하고, 실제 attempt가 typed outcome에 도달한 뒤에만 파일을 durable
remove한다. attempt 중 process가 사라지면 파일이 남으므로 이미 실패한 prefix가 부활하지
않는다. 알 수 없는 schema나 malformed 파일은 fresh lane으로 fallback하지 않고 Keeper turn을
fail-closed한다.

## exact identity

- issue: `#31965`
- source base head: `b4e0f6073909b2f84f71f15957b9368e077cdbb9`
- source change head: `6fa7d730eba9f59b1a6b79fbd5df5facd979d1ec`
- Linux measurement composition/embedded commit:
  `739b74b70cb408e0dfae5a5259b7e65397a5a6bd`
- Linux/arm64 image digest:
  `sha256:e894da37947d844bfbc7c1ca957ea879ad6fb874451a29b0b294321a6b7848b6`
- binary SHA-256:
  `7449701d56587e30118933314b9a1e77e6de417d330779ba3008277cb646b722`
- fixed first start: `2026-08-30T12:30:27Z`
- fixed restart: `2026-08-30T12:32:08Z`
- restarted runtime instance: `01a052a7-ddfd-7000-950e-551d35d588ca`

제품 변경은 `origin/main`에서 독립적으로 작성했다. measurement composition에는 앞선
Docker source-build, receipt, health 변경도 포함하지만 이 PR의 delta는 deferred runtime
suffix의 restart lifetime뿐이다. BuildKit은 GitHub의 full commit을 직접 checkout했고,
image digest와 `/app/masc` hash를 별도로 고정했다.

## isolated provider

외부 provider를 호출하지 않았다. Docker internal network의 OpenAI-compatible fake provider가
SSE 200을 반환했다. assistant visible text와 tool call은 없고 `reasoning_content`와
`reasoning`에만 26자를 보내 `finish_reason=stop`으로 정상 종료했다.

lane 순서는 다음과 같다.

1. `ollama_cloud.ollama-cloud-glm-5-3-flash`
2. `ollama_cloud.deepseek-v4-flash`

## baseline r36

composition `8ca359b870c7bb78c01f762717ad3eead00e480b`, image
`sha256:588c862ee3c2d0ff79f16aec1faebf00c1d43b7f48323d4a7f461dae7db18820`,
binary `73636f643d4206edfbc7495b5e924e2065ca8d83db19d0fb643cb72c54bbc9f3`에서
최초 실행 4/4 receipt가 다음을 기록했다.

- selected model: `glm-5.3-flash`
- terminal reason: `accept_rejected`
- disposition: `fail_open_next_runtime / degraded_retry`
- deferred runtime: `ollama_cloud.deepseek-v4-flash`

같은 container/volume을 clean restart했지만 restart 후 최초 provider POST 4건도 전부
`glm-5.3-flash`였다. 로그는 `resume checkpoint_turn_count=1` 뒤 동일 DeepSeek suffix를 다시
만들었다. 실패한 context는 보존됐지만 escape authority만 사라졌다.

## fixed r37 최초 기동

- provider POST: 4건, 4/4 `glm-5.3-flash`
- receipt: 4건, 4/4 `accept_rejected`
- deferred runtime: 4/4 `ollama_cloud.deepseek-v4-flash`
- durable suffix file: 4개
- durable codec: 4/4 current schema + typed `masc_internal/accept_rejected`

## 실제 재시작

앱을 정상 종료해 exit code 0을 확인한 뒤 같은 image, volume, runtime config, provider payload로
재기동했다.

- startup restore log: 4/4 `next_runtime=ollama_cloud.deepseek-v4-flash`
- restart 최초 provider POST: 4건, 4/4 `deepseek-v4-flash`
- GLM POST: 0건
- runtime log: 4/4 `agent_core-ollama_cloud.deepseek-v4-flash`,
  `resume checkpoint_turn_count=1`
- settled receipt: 4건, selected model 4/4 `deepseek-v4-flash`,
  `degraded_retry_applied=true`
- outcome 후 durable suffix file: 0개
- health: `overall_status=degraded`, blocker `turn_failure_recovering`,
  failing/recovering/executable 4/4/4, operator action false

fake provider도 마지막 DeepSeek 응답을 thinking-only로 만들었으므로 restart turn 자체는
실패했다. 이 결과는 성공 답변을 주장하는 검사가 아니라, 실패한 primary를 재실행하지 않고
동결된 successor를 실제 dispatch했는지 보는 검사다.

## focused 검증

- `scripts/dune-local.sh build test/test_keeper_turn_driver_failover.exe`
- `scripts/dune-local.sh exec ./test/test_keeper_turn_driver_failover.exe`
- 49/49 pass
- durable typed save/load/clear pass
- unknown schema fail-closed pass
- touched OCaml `ocamlformat --check` pass
- `git diff --check` pass

## 경계

- restart의 operator-visible consecutive failure count는 1에서 다시 1이었다. suffix persistence와
  별개이며 `#31966`으로 기록했다.
- opaque non-MASC failures는 provider prose를 저장하지 않는다. restart suffix selection에는
  frozen runtime ids만 사용하고 fallback reason은 generic durable-defer로 복원한다.
- provider container는 Node가 SIGTERM을 처리하지 않아 10초 stop 뒤 exit 137이었다. MASC 앱은
  exit 0이고 provider request/receipt는 그 전에 모두 고정했다.
- 운영 중인 8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] exact-source BuildKit checkout/build log, image/binary identity, isolated provider wire,
  first/restart receipts, durable suffix files, restart restore log, `/health?full=1`,
  2026-08-30T21:34:34+09:00 확인, 신뢰도 High.
