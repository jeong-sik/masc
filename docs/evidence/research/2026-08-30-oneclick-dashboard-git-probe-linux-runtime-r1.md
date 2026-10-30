# One-click dashboard Git probe Linux runtime R1

## 결과

dashboard runtime projection은 path 존재만 확인하고 Git rev-parse/upstream
subprocess를 실행했다. source checkout이 아니고 Git CLI도 없는 one-click `/app`은
repo projection이 `None`인 정상 deployment인데도 background refresh 때마다
missing-executable ERROR를 남겼다.

rev-parse와 upstream probe가 공유하는 shell-free command capability를 추가했다.
Git이 없으면 두 producer 모두 process spawn 전에 `None`을 반환한다. Git이 있는
checkout의 argv, cache, stale-first background refresh는 그대로 유지한다. test hook은
capability gate보다 먼저 적용돼 deterministic probe tests도 유지된다.

## exact identity

- source change commit: `08e56f3cb02c15f759c58f68972ef8ea4a3bb2fc`
- Linux measurement composition/embedded commit:
  `7991c5f022ff3a8c2f70f3b1d8094790dd82cbcc`
- Linux/arm64 image digest:
  `sha256:1d4151e50ffe31808551e74d45588fe64300263d3b895ee108b0db070fb3ac0a`
- binary SHA-256:
  `8151f9db68043a56139adb79aa8460d8d85ff772b953c2500f52d9c46a565227`
- first runtime instance: `01a051c3-b8bb-7000-b422-be04aaf7194a`
- restarted runtime instance: `01a051c4-6a7f-7000-82f4-edac0c19733d`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와 `BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다.
container `build-commit`, `/health?full=1`, binary hash가 같은 source head를
가리켰다. build context의 Git metadata는 binary에 embed됐지만 final runtime
image에는 Git CLI와 source checkout을 싣지 않았다.

## baseline

직전 composition `bc24e2872aba9effc70cab75b23ae23656ff9c00`의 r12는
background dashboard refresh가 시작될 때 아래 ERROR를 기록했다.

```text
[Process_eio] argv error: 'git' '-C' '/app' '--no-optional-locks' 'rev-parse' '--short' 'HEAD' — Eio.Io Process Executable "git" not found
```

baseline image digest는
`sha256:7688c5ab6c64f9ae4db31de0c9e0f20e622d0729cb6d89fc6c645182d9fd9eda`,
binary SHA-256은
`d3e7c5e13f79c8ad6e00e3132621884fe3019b8b74fba700ad3998cd5055ce65`였다.

## fixed 실측

fresh r14에서 background execution refresh 시작과 warm completion까지 기다렸다.
Git missing-executable ERROR는 0건이었다.

같은 exact-head container를 실제 restart해 runtime instance가
`01a051c3-b8bb-...`에서 `01a051c4-6a7f-...`로 바뀌었다. 두 번째 background
execution refresh 시작과 warm completion 뒤에도 Git missing-executable ERROR는
0건이었다. repo commit/upstream projection은 꾸며내지 않고 `None`을 유지했다.

Keeper와 provider turn은 실행하지 않았다. container
`masc-dashboard-git-probe-fixed-r14`와 volume
`masc-dashboard-git-probe-fixed-r14-data`는 정지·보존했다.

## 검증

- `scripts/dune-local.sh build test/test_dashboard_cache.exe`
- dashboard cache concurrency group 6/6
  - stale-first rev-parse/upstream cache와 worker-domain guard 통과
  - exact argv 계약 통과
  - empty deployment PATH capability=false
- fresh Linux/arm64 background dashboard refresh
- 같은 container의 실제 restart 뒤 background dashboard refresh

## 남은 경계

Git CLI는 있지만 `/app`이 repository가 아닌 deployment는 기존처럼 process를
실행해 non-repository 결과를 `None`으로 만든다. command availability와 repository
discovery는 다른 계약이므로 이번 변경은 missing executable만 차단한다. deployed
`/Users/dancer/me/.masc`는 바꾸지 않았다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary SHA-256, background refresh markers, fresh/restart logs,
  2026-08-30T17:24:40+09:00 확인, 신뢰도 High.
