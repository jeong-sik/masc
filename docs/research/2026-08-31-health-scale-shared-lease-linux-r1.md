# Full-health scale and shared-volume BasePath lease Linux R1

## 결과

r66의 단일 프로세스 부하에서는 0.1 CPU에서 schedule 32/32개와 durable ledger row
32/32개가 일치했다. 그러나 r67은 같은 `/app/.masc` volume을 마운트한 두 컨테이너가
모두 `ready`가 되는 split brain과 internal-token hash 덮어쓰기를 재현했다.

r68/r69의 첫 수정은 lease와 PID lock을 모두 공유 `MASC_RUN_DIR`로 옮겼다. 기본
same-volume 충돌 검증은 통과했지만, r74의 반복 SIGKILL에서 PID namespace 충돌이 드러났다.
공유 파일의 stale PID 7을 새 컨테이너 안의 무관한 live PID 7로 오인해 세 번째 컨테이너가
그 PID에 SIGTERM을 보내고 스스로 exit 143으로 끝났다. 따라서 r68/r69 설계와 그 성공 판정은
폐기한다.

최종 수정은 책임이 다른 두 lock을 분리한다.

- BasePath ownership lease만 `MASC_BASE_PATH_LEASE_DIR`를 통해 volume에 공유한다.
- 포트별 PID lock과 takeover breadcrumb는 컨테이너 로컬 host temp directory에 둔다.

r75에서 같은 volume의 두 번째 runtime은 약 100ms 만에 exit 1로 거부됐고 token hash는
불변이었다. 첫 runtime과 다른 volume runtime, 정상 종료 뒤 후계 runtime은 모두
current-ready/auth ok였다. 공유 volume의 PID 파일 수는 전 구간 0이었다. 실제 `masc_config`
응답도 `MASC_BASE_PATH_LEASE_DIR=/app/.masc/runtime/base-path-lease`, source `env`를 반환했다.

r76은 같은 volume에서 컨테이너를 12번 새로 만들었다. 처음 11개를 SIGKILL하고 마지막을
정상 종료했다. 12/12개가 서로 다른 runtime ID로 ready/auth ok였고, 11개는 exit 137,
마지막은 exit 0, OOM은 0건이었다. 공유 PID 파일과 잘못된 takeover 로그도 0건이었다.

## 외부 근거와 적용

- [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/)은 틀린 분석 문맥이
  그럴듯한 이름과 설명으로 고정될 때 추론이 잘못된 방향으로 이어지는 사례를 보여준다.
  여기서는 r68/r69의 부분 성공을 최종 근거로 고정하지 않고 SIGKILL 재시작으로 반증했다.
- [STALE](https://arxiv.org/abs/2605.06527)과
  [Supersede](https://arxiv.org/abs/2606.27472)는 오래된 memory/context를 검증하고 명시적으로
  supersede해야 한다는 관점을 제공한다. r74가 r68/r69를 supersede하며, 최종 판정은 r75/r76에만
  의존한다.
- [CUP의 update coalescing](https://www.usenix.org/legacy/publications/library/proceedings/usenix03/tech/full_papers/roussopoulos/roussopoulos_html/node7.html)은
  중복 invalidation을 합쳐도 최신 update를 전달해야 함을 전제로 한다. r66은 한 프로세스 안의
  coalescing만 증명하며, 여러 writer를 허용하는 근거가 아니다.
- [OCaml 5.5 Runtime_events API](https://ocaml.org/manual/5.5/api/Runtime_events.html)는 runtime
  event ring 이름에 PID를 사용한다. PID가 namespace-local이라는 사실과 결합하면, PID 기반
  lifecycle 파일을 공유 volume에 두는 설계는 안전하지 않다. r74가 이 경계를 직접 재현했다.

## r66: 32 Keeper 부하

- source: `79a3254a81cf857f69d3888e3c87e13017d48c50`
- image: `sha256:111b409d8764b1d9f28318a1e7824a75e967f986883a07a66924ea24de7f883f`
- binary: `feff50c3ef1d1ae6b5e2b8b5a315efe5b69063c469099525548f3db8d0e2057d`
- runtime: `01a053d6-3433-7000-b871-f338670ea944`
- cold startup at 0.5 CPU: current-ready 1.637초
- load at 0.1 CPU: 32/32 accepted, ledger 32 rows, unique stimulus 32/32
- final: queue 32, generation 64, worker submissions 12, dirty result discard 9, timeout 0
- exit 0/OOM false

모든 Keeper가 `autoboot_enabled=false`인 fixture였으므로 final overall health는 degraded였다.
여기서 증명한 것은 currentness와 durable 집합 일치이며 fleet health 정상은 아니다.

## r67: 공유 volume 반례

- issue: [#31996](https://github.com/jeong-sik/masc/issues/31996)
- source/image/binary: r66과 같음
- runtime A: `01a053d8-bee3-7000-8367-512b866de7a0`
- runtime B: `01a053d9-4a38-7000-b967-92a7801ef98e`

같은 `/app/.masc` volume, 서로 다른 `/tmp`에서 둘 다 ready가 됐다. durable row가 생긴 뒤
A는 queue 33, B는 queue 32를 약 12초 동안 current-ready로 반환했다. B의 generation은 0이었고
stale/error 표시는 없었다. B가 shared internal-token hash도 덮어써 A의 auth가
`token_hash_mismatch`가 됐다.

## r68/r69: 폐기한 첫 수정

- r68 measurement source/image: `da6f0b6a8bd695a39b68b0d586deb3ec8fca97e2`,
  `sha256:b732b674773a732be91bbaf41a4b9342d08a2e16bd6a6cccfbb3f53b16261eb3`
- r69 measurement source/image: `9b17b1c6eb63a53d7d3a4598aea42e036ab9d65b`,
  `sha256:50632be4481bf8b8184855b4bd918be2d5a0fe3d9c9dd7e4a7fc41c0f8c13d47`
- 당시 결과: same-volume 두 번째 runtime exit 1, token hash 불변, successor와 different-volume
  runtime ready/auth ok

이 수정은 `MASC_RUN_DIR=/app/.masc/runtime/host-run` 하나에 BasePath lease와
`masc-8080.pid`를 함께 뒀다. 기본 happy-path는 통과했지만 PID namespace가 반복되는 restart
조건을 다루지 못했으므로 최종 근거가 아니다.

## r74: 공유 PID lock 설계 반증

- regression issue: [#32000](https://github.com/jeong-sik/masc/issues/32000)
- source: `dee02ce57e556aa91f342e2701f5319fe0db7292`
- production-shaped image: `sha256:3d90430e8a37551b3928cbad7a18b342bda316437f7262a44a4baaa7be1108db`
- binary: `dc2efc123d2052d00ce0cb578230fb9c7bfff08bb13940a34fc9613e3eeeba75`

첫 runtime `01a05404-f551-7000-96a6-9977a06ae776`은 1.195초에 ready가 된 뒤 SIGKILL
exit 137이었다. 두 번째 `01a05404-ffdc-7000-925c-a6e7b3b6c6d0`은 stale runtime-event
file 1개를 정리하고 1.137초에 ready가 된 뒤 다시 SIGKILL exit 137이었다.

공유 `/app/.masc/runtime/host-run/masc-8080.pid`에는 7이 남았다. 세 번째 컨테이너의
초기 MASC 프로세스도 PID 7이었다. startup takeover가 이를 이전 owner가 아직 살아 있는 것으로
오인해 `[WARN] PID 7 alive but unresponsive on port 8080; sending SIGTERM to reclaim`을 남겼고,
컨테이너는 ready가 되지 못한 채 약 346ms 뒤 exit 143/OOM false로 끝났다.

## 최종 변경

- `Host_config.run_dir`는 다시 host temp directory만 사용한다.
- 새 `Host_config.base_path_lease_dir`가 `MASC_BASE_PATH_LEASE_DIR`를 읽는다.
- HTTP/stdio server와 deployment preflight helper는 BasePath lease에만 새 경로를 사용한다.
- 일반 Docker와 one-click image가
  `MASC_BASE_PATH_LEASE_DIR=/app/.masc/runtime/base-path-lease`를 설정한다.
- 두 entrypoint가 lease directory를 만들고 mode `0700`으로 맞춘다.
- `masc_config` server snapshot이 새 설정값과 출처를 노출한다.
- PID lock과 takeover breadcrumb는 `/tmp`에 남는다.

## r75: 최종 lock 분리 실런타임

- stacked base: `933b169732a14ca76e2a3f6d307979125d197daa` (`#31995` head)
- product head: `407288a23a624514a3aa97fde976d1450e57ece8`
- measurement head: `962541b20b`
- image: `sha256:027aaa432abca63d973272b2964246b93e99f9922e959605df0c48ff31ea2b17`
- binary: `1aef80025ae9bd65f1076346ed3c962f70015d7fcc4c048cc4810558ef88361b`

이 image는 product head에 이미 main에 병합된 one-click build 수정 3개를 더한 측정 합성본이다.
product stack이 그 main 커밋들보다 먼저 갈라져 순수 product head에서는 현재 one-click Dockerfile의
필수 helper가 없기 때문이다. 합성 커밋은 `6c53626`, `b832d34`, `962541b`이며 기능 코드는
product head와 같다.

- 첫 runtime `01a0540e-4607-7000-a969-e3c740471612`: current-ready 1.667초
- same-volume 두 번째 runtime: 약 100ms 뒤 exit 1/OOM false
- successor `01a0540e-5aa4-7000-bcb2-baecfc463a10`: current-ready 1.273초
- concurrent different-volume `01a0540e-5078-7000-9aed-94c9668c0a1d`: 1.755초
- config proof runtime `01a05411-bbe3-7000-a923-c0142e686422`: 1.399초, exit 0

두 번째 시작 전후 token hash는 같았고 첫 runtime의 auth/current도 유지됐다. 실행 중 PID lock은
`/tmp/masc-8080.pid`에 있었고 shared volume의 `masc-*.pid`는 0개였다. 실제 MCP
`masc_config` server row는 새 lease directory의 value, source `env`,
`raw_env_present=true`를 반환했다.

## r76: 12회 SIGKILL 재시작

r75와 같은 image/source composition, fresh shared volume을 사용했다.

- iteration: 12
- ready/auth ok 및 unique runtime ID: 12/12
- SIGKILL exit 137/OOM false: 11/11
- 마지막 clean exit 0/OOM false: 1/1
- current-ready: 최소 1.256초, 최대 1.647초, 평균 1.402초
- shared BasePath lease file: 매 iteration 1개
- shared PID file 최대: 0개
- `alive but unresponsive`, `sending SIGTERM`, `already owns` 로그: 0건

## 검증과 경계

- focused build: `bin/main_eio.exe`, `bin/main_stdio_eio.exe`,
  `bin/deployment_preflight_helper.exe`, 관련 Host_config/env snapshot/takeover tests pass
- Host_config env 7/7, resolution 6/6, env snapshot 6/6, takeover 28/28 pass
- 두 entrypoint `bash -n`, `ocamlformat --check`, `git diff --check` pass
- r75/r76는 Linux/arm64 Docker Desktop local volume과 one-click image를 사용했다.
- 일반 release Dockerfile은 static contract와 focused build만 확인했다. 최종 product head의 release
  artifact image 실런타임은 아직 재지 않았다.
- Kubernetes RWX storage와 여러 host의 filesystem lock 동작은 측정 범위 밖이다.
- full suite와 CI는 실행하거나 통과했다고 주장하지 않는다.

## 근거

- [근거] r66-r76 source/image/binary/runtime identity, canonical HTTP health, MCP config snapshot,
  ledger/timeseries, Docker inspect, token hash, lock filesystem, 2026-08-31T04:07:34+09:00 확인,
  신뢰도 High.
- [근거] 위 원문·논문·OCaml 공식 문서, 2026-08-31 확인, 신뢰도 High.
