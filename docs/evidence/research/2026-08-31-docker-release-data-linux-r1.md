# Production Docker bulk data directory Linux R1

## 결과

r81은 Linux AArch64 ELF main/helper로 deployment preflight와 HTTP startup을 통과했지만,
non-root appuser가 `/app/data/tool-metrics`를 만들 수 없어 `startup.phase=degraded`에 고정됐다.
production Dockerfile이 `/app/.masc`와 assets만 appuser 소유로 만들고 RFC-0121의 bulk data
sibling `/app/data`는 준비하지 않은 것이 원인이었다.

수정은 production image에서 `/app/data`를 만들고 `/app/.masc`와 함께 appuser 소유로 둔다.
OCaml resolver, one-click image, BasePath lease, PID lock, Runtime_events 경로는 바꾸지 않는다.

r82 production-shaped image는 fresh shared volume에서 4번 부팅했다. 4/4 deployment preflight,
unique runtime, startup ready, full-health ready, auth ok였다. `/app/data`와
`/app/data/tool-metrics`는 매번 mode 755, UID/GID 999였다. 처음 3개는 SIGKILL exit 137,
마지막은 clean exit 0, OOM은 0건이었다.

같은 volume의 contender는 preflight helper에서 exit 124로 거부됐고 token hash는 불변이었다.
공유 PID file과 잘못된 takeover log는 0건이었다. SIGKILL 뒤 Runtime_events ring 1개가 남고
다음 ready에서 교체됐으며 마지막 clean stop 뒤 ring은 0개였다.

## r81 반례

- issue: [#32001](https://github.com/jeong-sik/masc/issues/32001)
- product head: `b85c82ec976f175bc795db5a49cc1956d8e99b07`
- image: `sha256:1b564539795b0ff568867d685959bd47615ea2a8ac2e453e2e8ead45e48ed44c`
- runtime: `01a0542e-9508-7000-b1f7-e5f5666d20aa`
- preflight: OK
- startup: degraded
- error: permission denied creating `/app/data/tool-metrics`
- clean exit 0/OOM false; event ring 1→0

`Config_dir_resolver.data_dir ~base_path:"/app"`는 의도대로 `/app/data`를 반환한다. 환경변수만
추가하는 우회는 이 직접 경로를 바꾸지 않으므로 채택하지 않았다. one-click image는 `/app` 전체를
appuser에 chown해 같은 결함이 가려져 있었다.

## 변경

- production Dockerfile이 `/app/.masc /app/data`를 함께 만든다.
- 두 directory를 `appuser:appgroup` 소유로 둔다.
- source contract test가 mkdir/chown 경로를 고정한다.
- immutable `/app/config`와 `/app/assets`, container-local PID lock, shared lease/events directory는
  그대로 둔다.

## r82 production-shaped 실런타임

- stacked product head: `2922aba3b643f538993e5514a561865f1051c3c0`
- measurement context head: `3d5f25aeebc4f8609db9c1e70c5248ea3e5f8022`
- Linux builder: `sha256:61a827bacdf302a2de7ee2cecf2d276c76043b7e99b1a97eb9b2259417df80ac`
- image: `sha256:89fff286971ca8aee856543d950815572bc33c80eb1eff5858f7dd4a4dab12b5`
- binary: `7956eda96b01c7c93bd54eed815b018c549cf818fc2e5f23cd79d56c016571e0`
- preflight helper: `d0db776eb1b8596a53c0551a25ba89a945a288253f651e8d9d0558095b84eb77`
- artifact kind: ELF 64-bit ARM aarch64

Runtime IDs:

- `01a05439-7061-7000-9fe5-c64812714a57`, ready 1.327초, SIGKILL 137
- `01a05439-884b-7000-80a2-791b4662c603`, ready 1.316초, SIGKILL 137
- `01a05439-9f02-7000-8da1-c5ae639cc9ff`, ready 1.257초, SIGKILL 137
- `01a05439-b4e9-7000-9917-cceddf5e79e3`, ready 1.321초, clean exit 0

집계:

- ready/auth ok, unique runtime, preflight OK: 4/4
- startup ready: 최소 1.257초, 최대 1.327초, 평균 1.305초
- `/app/data`, `/app/data/tool-metrics`: 4/4 mode 755, UID/GID 999
- SIGKILL exit 137/OOM false: 3/3
- clean exit 0/OOM false: 1/1
- same-volume contender: exit 124/OOM false, token hash 불변
- event ring replacement: 4/4; final clean stop 뒤 0개
- shared PID file 최대 0, 잘못된 takeover log 0

## 검증과 경계

- focused build: `main_eio`, `main_stdio_eio`, `deployment_preflight_helper`,
  `test_install_script`
- `test_install_script`: 44/44 pass
- `ocamlformat --check`, `git diff --check`: pass
- JSON/JSONL parse, secret-string scan, SHA-256 manifest, evidence-record strict validation을 수행한다.
- r82는 Linux/arm64 Docker Desktop local volume과 production Dockerfile로 만들었다.
- `/app/data`는 현재 declared `/app/.masc` volume 밖의 container writable layer다. 이 PR은 startup
  permission을 고치며 container replacement 사이 bulk telemetry persistence를 주장하지 않는다.
- GitHub published artifact, Kubernetes RWX, multi-host filesystem lock은 측정 범위 밖이다.
- full suite와 CI는 실행하거나 통과했다고 주장하지 않는다.

## 근거

- [근거] r81/r82 source, Linux builder/image/binary/helper/runtime identity, preflight/health,
  data directory stat, Docker inspect, token hash, ring lifecycle,
  2026-08-31T04:52:22+09:00 확인, 신뢰도 High.
