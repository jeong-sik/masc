# Keeper transient retry disposition Linux runtime R1

## 결과

single-candidate Keeper의 terminal DNS failure는 기존 receipt에서
`fail_open_next_runtime / transient_runtime_retry`로 기록됐다. 그러나 runtime facts는
attempt/lane attempt 1/1, fallback false, degraded retry false, rotation empty였고 로그는
`deferred_next_runtime=none`이었다.

새 `retry_later` wire value는 현재 turn이 끝났고 Keeper가 이후 keepalive cycle에서
재시도할 수 있다는 사실만 표현한다. 다른 lane candidate가 같은 turn에서 실행됐다는
주장은 하지 않는다.

## exact identity

- source change head: `3c197d2d9603d15d0bbeadafb631b3eab43875a5`
- stacked parent head: `511d669bc835573e005d09af349047dc8de1df2e`
- Linux measurement composition/embedded commit:
  `c64f3bd5fb5fdd9f7a73c1eff3fd5acce9b38dc8`
- Linux/arm64 image digest:
  `sha256:9d99dc0896391efd65f7f6554fbf87ae9adc7dcce7a92b553f31e932b1188ebf`
- binary SHA-256:
  `5096d6a5d764c9d855b7c6dd8c809d0840bac40b1c59735e250a27546c79b084`
- first-start runtime instance: `01a0525a-1ec8-7000-b712-1f00a1f364f7`
- restarted runtime instance: `01a0525a-7f87-7000-86af-d6fa43597ffe`

제품 변경은 #31956 head 위에 한 commit으로 작성했다. Linux build에는 main의 알려진
one-click source-copy 결함을 피하기 위한 기존 measurement composition을 사용했다.
container의 embedded `build-commit`, `/health?full=1`, binary hash는 모두 위 composition
identity를 직접 보고했다.

잘못 확장한 commit hash를 쓴 첫 remote-context 시도와 main-only one-click build는
각각 checkout 오류와 missing `opam-switch-rw-lock.sh`로 실패했다. 둘 다 image를 만들지
못했으며 성공 증거에 포함하지 않았다.

## baseline r27

composition `776be0009277a2935ec71de7f8aa656f50503b15`, image
`sha256:4db8aae5071aa2807bec5ca664b7627e81bf5abcf97cfc0b47a27793cc798ef3`,
binary `a61110401f8bfdbac14f9f1e2d96d2a9f341595090d02d558510418928876f54`
를 non-empty dummy credential과 `--network none`으로 실행했다.

- terminal DNS receipt: 4건
- disposition/reason: 4/4
  `fail_open_next_runtime / transient_runtime_retry`
- runtime attempt/lane attempt: 4/4 1/1
- fallback/degraded retry: 4/4 false/false
- fallback reason: 4/4 null
- rotation: 4/4 empty
- log `deferred_next_runtime=none`: 4건

같은 baseline을 5초 cadence로 실행한 별도 bounded observation은 59초에 44회 같은
failure를 만들면서 `consecutive=0`, health `ok`를 유지했다. 이 무제한 retry/health
문제는 #31958에 분리했다.

## fixed r28 최초 기동

fresh volume의 시작 시각 `2026-08-30T11:07:12Z` 이후 receipt만 분리했다.

- 새 terminal DNS receipt: 4건, Keeper별 1건
- disposition/reason: 4/4 `retry_later / transient_runtime_retry`
- runtime facts: 4/4 attempt 1, lane attempt 1, fallback false,
  degraded retry false, fallback reason null, rotation empty
- log `deferred_next_runtime=none`: 4건
- operator broadcast: 0건

## 실제 재시작

같은 container를 `docker restart --timeout 20`으로 재시작했다. runtime instance가
`01a0525a-1ec8-...`에서 `01a0525a-7f87-...`로 바뀌었다. 재시작 시각
`2026-08-30T11:07:37Z` 이후 receipt만 다시 분리했다.

- 새 terminal DNS receipt: 4건, Keeper별 1건
- disposition/reason: 4/4 `retry_later / transient_runtime_retry`
- runtime facts: 4/4 attempt 1, lane attempt 1, fallback false,
  degraded retry false, fallback reason null, rotation empty
- log `deferred_next_runtime=none`: 4건
- operator broadcast: 0건

최종 container는 graceful shutdown 후 exit code 0이었다. volume은 보존했다.

## focused 검증

- `scripts/dune-local.sh build test/test_keeper_terminal_reason_typed.exe
  test/test_keeper_runtime_trust_snapshot.exe`
- terminal-reason independent field matrix: 147,200 cases, mismatch 0
- terminal-reason suite: OK
- `test_keeper_runtime_trust_snapshot.exe test receipt_runtime_model 10`: 1/1
- `git diff --check`
- touched OCaml files `ocamlformat --check`

## 경계

이 변경은 receipt의 truthfulness만 고친다. transient error의 무제한 crash-accounting
면제, retry cadence, fleet health는 바꾸지 않으며 #31958에서 별도로 다룬다. 운영 중인
8935 server와 deployed `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] embedded build commit, image/binary identity, network-none 최초 기동/실제
  재시작 receipt와 logs, 2026-08-30T20:09:37+09:00 확인, 신뢰도 High.
