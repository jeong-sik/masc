# Full-health scale and shared-volume lease Linux R1

## 결과

r66은 32 Keeper와 같은 시각의 schedule 32개를 0.1 CPU에서 넣었다. 32개 요청과 durable
ledger row가 모두 남았고, final current snapshot의 stimulus ID 집합도 ledger와 같았다. 64번의
generation 변경 동안 이미 계산 중이던 결과 9개를 폐기하고 worker 12개만 제출했다. timeout은
없었다.

하지만 이 성공은 단일 프로세스에 한정됐다. r67에서 두 컨테이너가 같은 `/app/.masc` volume을
마운트하자 둘 다 `ready`가 됐다. 두 번째 프로세스는 durable row가 생긴 뒤에도 약 12초 동안
queue 32를 `ready`로 반환했다. 첫 번째 프로세스의 queue는 이미 33이었다. 두 번째 프로세스가
shared internal-token hash도 덮어써서 첫 번째 프로세스의 auth가 `token_hash_mismatch`로 망가졌다.

r68은 Docker의 BasePath lease를 volume 안에서 공유한다. 같은 volume의 두 번째 프로세스는
93ms 안에 exit 1로 끝났고, token hash는 바뀌지 않았다. 첫 번째 프로세스의 auth와 current
snapshot도 유지됐다. 첫 번째 프로세스를 정상 종료한 뒤 후계 프로세스는 1.016초에 current-ready가
됐다. 다른 volume을 쓴 프로세스는 첫 번째 프로세스와 동시에 정상 실행됐다.

r69는 같은 수정에 운영 진단을 더했다. `masc_config` server snapshot이 실제
`MASC_RUN_DIR=/app/.masc/runtime/host-run`과 source `env`를 반환했다. 코드 HEAD가 바뀌었으므로
새 image에서 공유-volume 배타성 네 조건을 다시 측정했고 모두 유지됐다.

## 외부 근거와 적용

- [Lemmalog 원문](https://pwning.systems/posts/llm-memory-program-analysis/)은 틀린 분석 문맥이
  그럴듯한 이름과 설명으로 고정될 때 추론이 잘못된 방향으로 이어지는 사례를 보여준다. MASC에서는
  `ready`라는 표지가 실제 durable producer와 다른 상태를 가리키지 못하게 해야 한다.
- [STALE](https://arxiv.org/abs/2605.06527)과
  [Supersede](https://arxiv.org/abs/2606.27472)는 오래된 memory/context가 뒤의 판단에 남는 문제를
  각각 검증과 명시적 supersession 관점에서 다룬다. r67은 stale 표시조차 없는 반례였으므로 단순
  TTL 단축보다 두 writer를 먼저 막는 쪽을 택했다.
- [CUP의 update coalescing](https://www.usenix.org/legacy/publications/library/proceedings/usenix03/tech/full_papers/roussopoulos/roussopoulos_html/node7.html)은
  같은 downstream invalidation을 합쳐도 최신 update를 전달해야 함을 전제로 한다. r66의 coalescing은
  한 프로세스 안에서는 맞았지만, 프로세스 사이 observer가 없던 r67에는 적용되지 않았다.

## r66: 32 Keeper 부하

- source: `79a3254a81cf857f69d3888e3c87e13017d48c50`
- image: `sha256:111b409d8764b1d9f28318a1e7824a75e967f986883a07a66924ea24de7f883f`
- binary: `feff50c3ef1d1ae6b5e2b8b5a315efe5b69063c469099525548f3db8d0e2057d`
- runtime: `01a053d6-3433-7000-b871-f338670ea944`
- cold startup at 0.5 CPU: current-ready 1.637초
- load at 0.1 CPU: 32/32 accepted, ledger 32 rows, unique schedule/stimulus 32/32
- ledger 기록 구간: 15.501초
- due 시각부터 final current까지: 27.292초
- final: queue 32, pending 32, generation 64, submissions 12, joins 0, compute 605ms
- dirty result 폐기 9, timeout 0, exit 0/OOM false

모든 Keeper를 `autoboot_enabled=false`로 둔 부하 fixture였기 때문에 final overall health는 degraded였다.
32개 stimulus가 owner 없이 retained된 상태가 원인이다. 여기서 증명한 것은 currentness와 durable
집합 일치이며 fleet health 정상은 아니다.

## r67: 공유 volume 반례

- issue: [#31996](https://github.com/jeong-sik/masc/issues/31996)
- source/image/binary: r66과 같음
- runtime A: `01a053d8-bee3-7000-8367-512b866de7a0`
- runtime B: `01a053d9-4a38-7000-b967-92a7801ef98e`
- 같은 `/app/.masc` volume, 컨테이너마다 별도 `/tmp`
- schedule `r67-shared-one`: ledger 1 row, A dispatch 1, B dispatch 0

`18:06:08.415897Z`에 A는 queue 33, B는 queue 32였지만 둘 다 current-ready였다. B는
`18:06:19.360390Z`까지 queue 32를 유지했고 `18:06:20.543048Z`에야 33으로 바뀌었다. B의
generation은 계속 0이었고 stale/error 표시는 없었다.

`Host_config.run_dir`가 `Filename.get_temp_dir_name()`으로 고정돼 있었다. 기존
`Server_startup_takeover.acquire_base_path_lock`은 올바르게 배타적이지만, 두 컨테이너가 서로 다른
`/tmp`에 lease 파일을 만들었기 때문에 같은 BasePath를 함께 소유했다.

## 변경

- `Host_config.host`와 `Host_config.resolve`가 명시적 `MASC_RUN_DIR`를 읽는다.
- `masc_config` server snapshot이 `MASC_RUN_DIR`의 적용값과 출처를 보여준다.
- 일반 Docker 이미지와 one-click 이미지가
  `MASC_RUN_DIR=/app/.masc/runtime/host-run`을 설정한다.
- 두 entrypoint가 서버 시작 전에 이 디렉터리를 만들고 mode `0700`으로 맞춘다.
- 기존 lease의 owner, permission, canonical identity 검증은 그대로 사용한다.
- 다른 임시 파일을 BasePath로 옮기지 않는다.

## r68: 수정 후 Linux 실런타임

- stacked base: `933b169732a14ca76e2a3f6d307979125d197daa` (`#31995` head)
- product change: `ed0786e75453e36c9893a9a285f04538de189ee2`
- config visibility change: `01ffbdb83f625b6e638f433c0e51175a515461b8`
- measurement source: `da6f0b6a8bd695a39b68b0d586deb3ec8fca97e2`
- image: `sha256:b732b674773a732be91bbaf41a4b9342d08a2e16bd6a6cccfbb3f53b16261eb3`
- binary: `ddc3013a505423bb8c4ed7a60d6338138077120488727129ffd258458f1abd5b`
- shared run dir: `/app/.masc/runtime/host-run`, mode 700, UID/GID 999

첫 번째 runtime `01a053e4-3fdf-7000-9368-2e8512d18394`는 1.693초에 current-ready가 됐다.
같은 volume의 두 번째 컨테이너는 `Another MASC runtime (PID 7) already owns base path /app`을
남기고 exit 1/OOM false로 끝났다. Docker inspect의 start/finish 차이는 약 93ms다.

두 번째 시작 전후 `internal_keeper.token.hash` SHA-256은
`62cad42059d1796ee10188d486fc061eceb60716bdb9a4d386eefe407353ee25`로 같았다. 첫 번째
runtime도 auth `ok`, `env_token_verifies=true`, full snapshot `ready`를 유지했다.

첫 번째 runtime을 exit 0/OOM false로 끝낸 뒤 같은 volume에서 후계
`01a053e5-8575-7000-bc14-05691bf51461`이 1.016초에 current-ready가 됐다. 동시에 다른 volume의
`01a053e5-2601-7000-a064-b7895abef368`도 ready/auth ok였고, 둘 다 exit 0/OOM false로 끝났다.

## r69: 설정 가시성을 포함한 exact-head 재검증

- measurement source: `9b17b1c6eb63a53d7d3a4598aea42e036ab9d65b`
- image: `sha256:50632be4481bf8b8184855b4bd918be2d5a0fe3d9c9dd7e4a7fc41c0f8c13d47`
- binary: `dc2efc123d2052d00ce0cb578230fb9c7bfff08bb13940a34fc9613e3eeeba75`
- first runtime: `01a053ee-949d-7000-8703-b575d6564ee4`, current-ready 1.590초
- second same-volume runtime: 약 98ms 뒤 exit 1/OOM false
- successor: `01a053ef-8c6f-7000-a7d2-ffd8c04ddf42`, current-ready 1.568초
- concurrent different-volume runtime: `01a053ef-82e4-7000-add0-68b246c39511`,
  current-ready 1.704초

MCP `masc_config`를 실제 runtime에 호출했다. server category의 `MASC_RUN_DIR` row는 value
`/app/.masc/runtime/host-run`, source `env`, `raw_env_present=true`를 반환했다. 같은 volume의 두 번째
runtime 전후 token hash는 같았고 첫 runtime auth/current도 유지됐다. 첫 runtime, successor,
different-volume runtime은 exit 0/OOM false였다.

## 검증과 경계

- focused build: `test_rfc_0085_pr6_host_config_from_env.exe`,
  `test_host_config_resolution.exe`, `bin/main_eio.exe`,
  `bin/deployment_preflight_helper.exe` pass
- Host_config cases: 7/7 + 6/6 pass
- env snapshot cases: 6/6 pass
- 두 entrypoint `bash -n`, `git diff --check`: pass
- Linux/arm64 one-click image에서 fresh shared volume과 fresh different volume을 사용했다.
- 일반 release Dockerfile은 `MASC_RUN_DIR` 설정과 entrypoint shell만 확인했다. release artifact image
  실런타임은 아직 재지 않았다.
- Kubernetes RWX storage와 여러 host의 filesystem lock 동작은 이 측정 범위 밖이다.
- full suite와 CI는 실행/주장하지 않는다.

## 근거

- [근거] r66/r67/r68/r69 source, Linux image/binary/runtime identity, canonical HTTP health,
  MCP config snapshot, ledger, timeseries, Docker inspect, token hash,
  2026-08-31T03:31:00+09:00 확인, 신뢰도 High.
- [근거] 위 원문·논문·CUP 1차 자료, 2026-08-31 확인, 신뢰도 High.
