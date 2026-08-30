# Docker Runtime_events writable directory Linux R1

## 결과

r70 production-shaped image는 deployment preflight를 통과한 직후 exit 134로 죽었다. appuser가
root-owned `/app`에 `6.events`를 만들지 못한 것이 원인이었다. `OCAML_RUNTIME_EVENTS_DIR`를 volume의
쓰기 가능한 디렉터리로 지정한 진단 실행은 1.099초에 current-ready가 됐다.

최종 변경은 ring file을 lease/PID 파일과 섞지 않는다. 두 Docker image가
`OCAML_RUNTIME_EVENTS_DIR=/app/.masc/runtime/events`를 설정하고, 두 entrypoint가 해당 디렉터리를
mode 0700으로 준비한다.

r71 production-shaped image는 별도 override 없이 preflight handoff를 거쳐 1.067초에
current-ready가 됐다. ring file은 `/app/.masc/runtime/events/7.events`에 생겼다. 같은 volume의
두 번째 process는 preflight helper에서 67ms 만에 exit 124로 거부됐다. token hash와 첫 runtime
auth/current 상태는 바뀌지 않았다. 후계와 다른 volume runtime도 정상 부팅·종료했다.

r72 one-click image도 같은 exact source에서 1.185초에 current-ready가 됐고 전용 디렉터리에
`6.events`를 만들었다. exit 0/OOM false로 끝났다.

r73은 production-shaped image를 SIGKILL했다. 64MiB `6.events`가 volume에 남았지만 후계
runtime은 이를 stale dump로 판정해 지우고 `7.events`를 만들었다. 후계는 1.078초에 ready가 됐고,
정상 종료 뒤 events directory의 ring file 수는 0이었다.

## 공식 근거

[OCaml 5.5 Runtime_events 공식 API](https://ocaml.org/manual/5.5/api/Runtime_events.html)는 tracing이
켜지면 `<pid>.events` 파일을 만들며, `OCAML_RUNTIME_EVENTS_DIR`가 없으면 process working directory를
쓴다고 명시한다. MASC는 `MASC_RUNTIME_EVENTS` 기본값이 true이고 startup에서
`Runtime_events.start()`를 호출한다. 따라서 release image의 root-owned `/app`은 쓰기 가능한 기본
경로가 아니다.

## r70 반례와 진단

- issue: [#31998](https://github.com/jeong-sik/masc/issues/31998)
- source: `9b17b1c6eb63a53d7d3a4598aea42e036ab9d65b`
- image: `sha256:d831b61d99f28b66d645a2616bd61c789e35dc28dd34418732eadfef3cd99f2a`
- binary: `dc2efc123d2052d00ce0cb578230fb9c7bfff08bb13940a34fc9613e3eeeba75`
- preflight helper: `10e76b3801729f95d8aa832e4bf3745d69c4151d8d5db6310c49b7205dddf7bc`
- process start: `2026-08-30T18:34:11.996494334Z`
- process finish: `2026-08-30T18:34:12.289844459Z`
- exit 134/OOM false

stdout에는 preflight `OK`가 있었고 stderr의 실제 실패는
`Fatal error: Couldn't open ring buffer loc: 6.events`였다. `/app`은 root:root mode 0755였고
runtime user는 UID/GID 999였다.

두 번째 fresh-volume 진단은 `OCAML_RUNTIME_EVENTS_DIR=/app/.masc/runtime/host-run`만 추가했다.
runtime `01a053f4-934a-7000-9f1b-8589b33177ac`은 1.099초에 current-ready/auth ok가 됐고
`7.events`를 만들었다. 이로써 writable directory 경계는 확인했지만, lease와 PID 파일을 한
디렉터리에 섞으므로 최종 배치로 채택하지 않았다.

## 변경

- 두 Dockerfile에 `OCAML_RUNTIME_EVENTS_DIR=/app/.masc/runtime/events`를 설정한다.
- 두 entrypoint가 `MASC_RUN_DIR`와 runtime-events directory를 함께 만들고 각각 mode 0700으로
  제한한다.
- Runtime_events 자체와 `MASC_RUNTIME_EVENTS` default-on 동작은 바꾸지 않는다.
- source contract test가 두 Dockerfile과 두 entrypoint의 설정을 고정한다.

## r71 production-shaped 실런타임

- stacked base: `f2fbe3a12bed531874a157060ab55b811a164e37` (`#31997` head)
- product change: `6279fd92d47795fe067b37b78cf663b82d5e8281`
- measurement source: `dee02ce57e556aa91f342e2701f5319fe0db7292`
- image: `sha256:3d90430e8a37551b3928cbad7a18b342bda316437f7262a44a4baaa7be1108db`
- binary/helper: r70과 같음
- image kind: production-shaped local build, published release artifact 아님

첫 runtime `01a053fa-16ac-7000-9291-c9fc1b05ebc6`은 1.067초에 current-ready/auth ok가 됐다.
config root는 release image 계약대로 `/app/config`였다. events directory는 mode 700, UID/GID
999였고 `7.events`를 담았다.

같은 volume의 두 번째 container는 preflight helper에서
`workspace writer lease is already owned`를 남기고 exit 124/OOM false로 끝났다. 시작부터 종료까지
약 67ms였다. server가 시작되기 전이므로 token hash는 불변이었고 첫 runtime도 auth ok/current-ready를
유지했다.

첫 runtime을 exit 0/OOM false로 끝낸 뒤 후계
`01a053fa-ce8b-7000-b29c-fe9152106bf4`은 1.066초에 ready가 됐다. 다른 volume의
`01a053fa-c6fd-7000-8059-0b5ad68227da`도 동시에 1.064초에 ready가 됐다. 둘 다 exit 0/OOM false였다.

## r72 one-click 실런타임

- source: `dee02ce57e556aa91f342e2701f5319fe0db7292`
- image: `sha256:283acd754e507fcea2a47300bda75fa6e0ad05d6fab25982663cf0b7dffbabef`
- binary: `dc2efc123d2052d00ce0cb578230fb9c7bfff08bb13940a34fc9613e3eeeba75`
- runtime: `01a053fc-df3b-7000-b293-2dc7b4101730`
- current-ready: 1.185초
- events directory: mode 700, UID/GID 999, file `6.events`
- auth ok, exit 0/OOM false

## r73 SIGKILL 후계 복구

- source/image: r71과 같음
- first runtime: `01a05400-3d9a-7000-9652-beee7d59cccc`, current-ready 1.075초
- fault: Docker SIGKILL, exit 137/OOM false
- crash remnant: `6.events`, inode 2729492, 68,167,744 bytes
- successor: `01a05400-b76a-7000-8932-9dfe30e1995b`, current-ready 1.078초
- successor log: `removed stale dump 6.events (pid 6 no longer exists)`
- successor ring: `7.events`, 68,167,744 bytes
- successor clean stop: exit 0/OOM false, 남은 `.events` 파일 0개

SIGKILL 직후 hash는 process 종료 시 mmap의 마지막 변경이 반영돼 실행 중 hash와 달랐다. inode,
size, mtime은 같았고 파일 존재를 직접 확인했다. 후계가 stale file을 삭제한 뒤 다른 PID 이름으로
새 ring을 만들었으므로 이전 hash를 current ring 증거로 재사용하지 않았다.

이 결과에 맞춰 `Masc_runtime_events.mli`도 고쳤다. 정상 종료에서는 OCaml runtime이 ring file을
지우며, stale pruning의 실제 대상은 SIGKILL 같은 비정상 종료가 남긴 파일이다.

## 검증과 경계

- `test_install_script`: 44/44 pass
- 첫 실행은 required `bin/main_eio.exe`가 없어 contract case 뒤 fixture 25개가 연쇄 실패했다. 오류가
  지시한 target을 focused build한 뒤 같은 suite를 다시 실행해 44/44를 확인했다.
- `bash -n`, `ocamlformat --check`, `git diff --check`: pass
- r71은 production Dockerfile의 final-stage 계약과 preflight helper를 사용했지만, binary를 local
  Linux builder에서 만들었다. GitHub release가 게시한 artifact 자체는 아직 측정하지 않았다.
- full suite와 CI는 실행/주장하지 않는다.

## 근거

- [근거] OCaml 5.5 공식 Runtime_events API, 2026-08-31 확인, 신뢰도 High.
- [근거] r70/r71/r72/r73 source, image, binary/helper, runtime health, Docker inspect, ring file,
  preflight rejection, token hash, SIGKILL/clean-stop recovery,
  2026-08-31T03:50:00+09:00 확인, 신뢰도 High.
