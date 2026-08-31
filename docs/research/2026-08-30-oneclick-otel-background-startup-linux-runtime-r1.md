# One-click OTLP background startup Linux runtime R1

## 결과

OTLP collector가 없을 때 `Otel_spans.setup_exporter`는 1/2/4/8/16초 간격으로
동기 재시도했다. `start_background_maintenance`가 이를 직접 호출해, 뒤에 있는
listener와 dashboard maintenance loop wiring이 fresh start와 restart마다 약 31초
멈췄다.

exporter setup을 server root switch 아래의 logged fiber로 옮겼다. 재시도와
collector recovery는 그대로 유지하고, maintenance wiring만 setup 완료를 기다리지
않는다. shutdown hook은 기존 우선순위와 위치를 유지한다.

## exact identity

- source change commit: `10e994faa6fe332c5e2902a09119685309dee879`
- Linux measurement composition/embedded commit:
  `5f5b3086349ba5c3206dc473beba50af4c377717`
- Linux/arm64 image digest:
  `sha256:0ca5b40b770641023cab274980f4f0d5effef0eba3c2a44aea7859de995d4ce2`
- binary SHA-256:
  `adfaca2806c57fafcfb13a201fd692feac01998f84f8f2abbb0d2346b4d8200f`
- first runtime instance: `01a051d3-8b7c-7000-83d5-0848e18e5eda`
- restarted runtime instance: `01a051d4-4182-7000-81c1-91b21433642a`
- effective base path: `/app`
- effective MASC root: `/app/.masc`

Git remote context와
`--build-arg BUILDKIT_CONTEXT_KEEP_GIT_DIR=1`로 이미지를 만들었다. container
`build-commit`, `/health?full=1`, binary hash가 같은 source head를 가리켰다.
Git metadata를 보존하지 않은 첫 build는 embedded commit이 비어 있어 측정
identity에서 제외했다.

## baseline

직전 composition `7991c5f022ff3a8c2f70f3b1d8094790dd82cbcc`의 r14는
OTLP retry 1부터 dashboard execution refresh 시작까지 fresh `31.017580s`, restart
`31.013894s`가 걸렸다. listener도 5회 retry와 recovery 전환 뒤에야 열렸다.

baseline image digest는
`sha256:1d4151e50ffe31808551e74d45588fe64300263d3b895ee108b0db070fb3ac0a`,
binary SHA-256은
`8151f9db68043a56139adb79aa8460d8d85ff772b953c2500f52d9c46a565227`였다.

## fixed 실측

fresh r15에서 listener 뒤 `0.215291ms`에 dashboard execution refresh loop가
시작했고, 그 뒤 `0.386375ms`에 OTLP retry 1이 기록됐다. 실제 restart에서도
listener 뒤 `0.809625ms`에 dashboard loop가 시작했고, `0.006125ms` 뒤 retry 1이
기록됐다.

두 실행 모두 1/2/4/8/16초의 5회 retry와 `recovery probe every 30s` 전환을
끝까지 유지했다. 31초 뒤 health는 `overall_status=ok`, startup
`serving/ready`, 같은 embedded commit과 binary hash를 보고했다. background fiber
crash와 fatal error는 각각 0건이었다.

Keeper와 provider turn은 실행하지 않았다. identity 측정 container
`masc-otel-background-fixed-r15-identity`와 volume
`masc-otel-background-fixed-r15-identity-data`는 정지·보존했다.

## 검증

- `scripts/dune-local.sh build test/test_server_runtime_bootstrap.exe`
- bootstrap exact test 24: 기존 exporter setup failure soft 계약 1/1
- bootstrap exact test 25: blocked setup 중 maintenance wiring return 계약 1/1
- `git diff --check`
- `ocamlformat --check` on changed OCaml files
- fresh Linux/arm64 start의 listener/dashboard/OTLP retry timeline
- 같은 container의 실제 restart와 전체 retry/recovery timeline

## 남은 경계

collector가 시작된 뒤 exporter가 active로 복구되는 network 성공 경로는 이번
측정에서 실행하지 않았다. 기존 recovery producer는 변경하지 않았으며, 이번
검증은 collector 부재 시 startup non-blocking과 retry 보존 경계만 다룬다. deployed
`/Users/dancer/me/.masc`는 바꾸지 않았다.

## 근거

- [근거] Git remote-context build log, image inspect, container `build-commit`,
  `/health?full=1`, binary SHA-256, fresh/restart nanosecond timestamp logs,
  2026-08-30T17:42:29+09:00 확인, 신뢰도 High.
