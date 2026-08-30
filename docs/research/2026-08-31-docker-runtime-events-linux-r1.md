# Docker Runtime_events writable directory Linux R1

## 결과

r70 production-shaped image는 deployment preflight를 통과한 직후 exit 134로 죽었다. appuser가
root-owned `/app`에 `6.events`를 만들지 못한 것이 원인이었다. `OCAML_RUNTIME_EVENTS_DIR`를
쓰기 가능한 volume directory로 지정한 진단 실행은 current-ready가 됐다.

변경은 ring file을 lease/PID 파일과 섞지 않는다. 두 Docker image가
`OCAML_RUNTIME_EVENTS_DIR=/app/.masc/runtime/events`를 설정하고, 두 entrypoint가 전용
directory를 mode 0700으로 준비한다. BasePath lease는
`/app/.masc/runtime/base-path-lease`에 공유하지만 PID lock은 컨테이너 로컬 `/tmp`에 둔다.

r71-r73의 초기 성공은 옛 shared `MASC_RUN_DIR` 설계 위에서 측정됐다. runtime-events 쓰기/정리
동작은 보여주지만 최종 lock 조합의 승인 근거로는 쓰지 않는다. 그 공유 PID 설계가 반복
SIGKILL에서 새 컨테이너를 잘못 SIGTERM하는 r74 반례로 폐기됐기 때문이다.

최종 조합 r79는 fresh shared volume에서 12회 부팅했다. 처음 11개를 SIGKILL하고 마지막을
정상 종료했다. 12/12개가 unique runtime/current-ready/auth ok였고, SIGKILL 뒤에는 ring 1개가
남았으며 다음 runtime ready 시에도 current ring은 정확히 1개였다. 동일 PID filename을 재사용한
7번은 이전 ring과 새 ring의 SHA-256이 모두 달라 재초기화가 직접 확인됐다. 다른 filename을 쓴
4번은 stale file을 제거하고 새 ring을 만들었다. 마지막 정상 종료 뒤 ring은 0개였다.

같은 volume의 concurrent contender도 약 100ms 안에 exit 1로 거부됐고 token hash는 불변이었다.
12회 동안 shared PID file과 잘못된 takeover 로그는 0건이었다.

## 공식 근거

[OCaml 5.5 Runtime_events 공식 API](https://ocaml.org/manual/5.5/api/Runtime_events.html)는 tracing이
켜지면 `<pid>.events`를 만들며, `OCAML_RUNTIME_EVENTS_DIR`가 없으면 process working directory를
쓴다고 명시한다. [OCaml runtime tracing manual](https://ocaml.org/manual/latest/runtime-tracing.html)은
정상 종료 시 ring file을 지우며 `OCAML_RUNTIME_EVENTS_PRESERVE`로 보존을 선택할 수 있다고
설명한다.

MASC는 `MASC_RUNTIME_EVENTS` 기본값이 true이고 startup에서 `Runtime_events.start()`를 호출한다.
따라서 release image의 root-owned `/app`은 쓰기 가능한 기본 경로가 아니다. PID filename은
container PID namespace마다 반복될 수 있으므로, r79는 단순 file 존재뿐 아니라 같은 filename의
content 교체도 검증했다.

## r70: 쓰기 불가 반례

- issue: [#31998](https://github.com/jeong-sik/masc/issues/31998)
- source: `9b17b1c6eb63a53d7d3a4598aea42e036ab9d65b`
- image: `sha256:d831b61d99f28b66d645a2616bd61c789e35dc28dd34418732eadfef3cd99f2a`
- binary: `dc2efc123d2052d00ce0cb578230fb9c7bfff08bb13940a34fc9613e3eeeba75`
- process lifetime: 약 293ms
- exit 134/OOM false

stdout에는 preflight `OK`가 있었고 stderr는
`Fatal error: Couldn't open ring buffer loc: 6.events`였다. `/app`은 root:root mode 0755,
runtime user는 UID/GID 999였다. writable override 진단 runtime
`01a053f4-934a-7000-9f1b-8589b33177ac`은 1.099초에 current-ready/auth ok가 됐다.

## 변경

- 두 Dockerfile에 `OCAML_RUNTIME_EVENTS_DIR=/app/.masc/runtime/events`를 설정한다.
- 두 entrypoint가 `$LEASE_DIR`와 `$RUNTIME_EVENTS_DIR`를 만들고 mode 0700으로 제한한다.
- `MASC_BASE_PATH_LEASE_DIR`와 `OCAML_RUNTIME_EVENTS_DIR`는 shared volume 안의 별도 directory다.
- PID lock과 takeover breadcrumb는 host temp directory에 남긴다.
- Runtime_events enable/default 정책은 바꾸지 않는다.
- source contract test가 두 Dockerfile과 두 entrypoint의 조합을 고정한다.

## r71-r73: preliminary evidence

- r71/r73 source: `dee02ce57e556aa91f342e2701f5319fe0db7292`
- r71 production-shaped image: `sha256:3d90430e8a37551b3928cbad7a18b342bda316437f7262a44a4baaa7be1108db`
- r72 one-click image: `sha256:283acd754e507fcea2a47300bda75fa6e0ad05d6fab25982663cf0b7dffbabef`
- r71: current-ready 1.067초, `7.events`, same-volume contender exit 124
- r72: current-ready 1.185초, `6.events`, clean exit 뒤 ring 제거
- r73: first SIGKILL exit 137 뒤 64MiB `6.events` 잔류; successor가 stale dump를 제거하고
  `7.events`를 만든 뒤 1.078초에 ready; clean exit 뒤 ring 0개

이 측정은 runtime-events directory 문제를 분리하는 데는 유효하다. 그러나 lease와 PID lock을 함께
shared `MASC_RUN_DIR`에 둔 source였으므로 final composition 증거가 아니다. 최종 판단은 r79로
교체한다.

## r77: 측정 harness 폐기

r77 runtime 자체는 12/12 ready, 11 SIGKILL exit 137, 마지막 clean exit 0, shared PID 0,
contender exit 1을 보였다. 그러나 harness가 event 하나를 `path + stat` 두 줄로 저장한 뒤
`wc -l`을 file count로 사용해 2를 1과 비교했다. 최종 assertion이 exit 1이었으므로 acceptance
evidence에서 제외하고 artifact는 원인 추적용으로만 보존했다.

## r78: pre-rebase 조합 확인

r78은 최종 lock 조합에서 12/12 ready와 ring 교체를 통과했다. 이후 base PR의 evidence JSONL을
canonical one-object-per-line 형식으로 고치면서 stacked commit identity가 바뀌었으므로, 이 결과는
기능 회귀 비교용으로만 남기고 새 identity의 r79로 최종 근거를 교체했다.

## r79: 최종 조합 12회 재시작

- stacked product head: `b85c82ec976f175bc795db5a49cc1956d8e99b07`
- measurement head: `3c6c86a62b15cc663c2ebef8b69242b6682ff13d`
- image: `sha256:25b0aa9b39d4be1a8f63f05694a840fa776f95efc33797cf5071bcf4a9da0d9d`
- binary: `7956eda96b01c7c93bd54eed815b018c549cf818fc2e5f23cd79d56c016571e0`

이 image는 product head에 이미 main에 병합된 one-click build fix 3개를 더한 측정 합성본이다.
합성 커밋은 `cfdde57`, `90fa042`, `3c6c86a`이며 제품 기능 코드는 product head와 같다.

- ready/auth ok 및 unique runtime: 12/12
- current-ready: 최소 1.229초, 최대 1.645초, 평균 1.312초
- SIGKILL exit 137/OOM false: 11/11
- 마지막 clean exit 0/OOM false: 1/1
- ready 중 event file: 항상 1개
- SIGKILL 뒤 event file: 항상 1개
- 다음 ready에서 이전 ring 교체 입증: 12/12
- 같은 filename 재사용: 7회, 이전/새 ring SHA-256 변경 7/7
- 다른 filename 사용: 4회, stale cleanup log 4건
- final clean stop 뒤 event file: 0개
- shared PID file 최대: 0개
- `alive but unresponsive`/`sending SIGTERM` takeover log: 0건
- same-volume contender: exit 1/OOM false, token hash 불변

## 검증과 경계

- rebased product HEAD focused build: `main_eio`, `main_stdio_eio`,
  `deployment_preflight_helper`, `test_install_script`
- `test_install_script`: 44/44 pass
- `bash -n`, `ocamlformat --check`, `git diff --check`: pass
- JSON/JSONL parse, secret-string scan, SHA-256 manifest, evidence-record strict validation을 수행한다.
- r79는 Linux/arm64 Docker Desktop local volume과 one-click image를 사용했다.
- r71은 production-shaped local image였지만 폐기된 shared-PID base였다. 최종 product head의 release
  artifact image는 아직 측정하지 않았다.
- GitHub release published artifact, Kubernetes RWX, multi-host filesystem lock은 측정 범위 밖이다.
- full suite와 CI는 실행하거나 통과했다고 주장하지 않는다.

## 근거

- [근거] OCaml 5.5 공식 Runtime_events API와 runtime tracing manual, 2026-08-31 확인,
  신뢰도 High.
- [근거] r70 반례, r71-r73 preliminary artifacts, r77 rejected harness, r78 superseded run,
  r79 source/image/binary/runtime
  identity, health, Docker inspect, ring path/stat/hash, contender rejection, token hash,
  2026-08-31T04:28:14+09:00 확인, 신뢰도 High.
