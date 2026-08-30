# Health lifecycle cache Linux R1

## 결과

`/health?full=1`의 60초 snapshot TTL은 Keeper registry가 이미 `Running -> Failing`으로
전이한 뒤에도 이전 `ok/running` fields를 반환했다. lifecycle Event_bus listener에만
invalidation을 붙인 첫 시도는 `turn_failed`가 그 bus에 발행되지 않아 실측에서 실패했다.

최종 변경은 Keeper registry의 성공한 event CAS 뒤 process-wide non-yielding observer를
호출한다. server bootstrap이 observer를 full-health invalidation에 연결한다. 무효화 뒤 다음
full response는 old ready fields 대신 `warming` placeholder와 `refresh_requested=true`를
반환하고, background refresh가 current registry facts를 다시 채운다. observer 예외는 이미
commit된 registry transition을 롤백하지 않는다.

## exact identity

- issue: `#31974`
- source base: `f883b015cd`
- product change head: `f9725bee1457a419001ed4eab255595956339812`
- measurement composition: `8c5c6f6b36d74bd7f809d939c84fc42545086a22`
- Linux/arm64 image: `sha256:5d1a8a0d10651d7a150455fe470597497686036c2ea617ce803e2bd815eedf7f`
- binary SHA-256: `f657dd28551d1fe70f8b04d04f6c6d1d63a2bb87be0ed01a8b55e18150b4dfdc`

measurement composition은 제품 head에 old-stack Docker source-build input 보완만 더한다.

## baseline

network-none r41에서 `turn_failed(1)`은 `2026-08-30T14:03:04Z`에 commit됐지만 약 10초 뒤
full health는 `overall/fleet=ok/ok`, running 1, failing 0을 반환했다. snapshot은
14:02:48Z 계산본, age 27,526ms, TTL 60,000ms, `stale_reason=null`, refresh request false였다.

## failed PoC

첫 PoC는 dashboard lifecycle Event_bus listener에서 cache를 무효화했다. r42 실측에서
`turn_failed` 뒤 새 lifecycle listener log가 없었고 old ready snapshot이 유지됐다. 이 wiring은
폐기하고 증거로 사용하지 않았다.

## fixed r44

한 Keeper와 internal reasoning-only provider를 사용해 첫 turn을 typed `accept_rejected`로
끝냈다. 외부 provider 호출은 0이다.

1. failure 전: ready snapshot, overall/fleet `ok/ok`.
2. `2026-08-30T14:28:10Z`: `consecutive=1`, `Running -> Failing`, `turn_failed(1)`.
3. transition 뒤 첫 probe: overall/fleet/snapshot `warming`, refresh request true,
   computed time와 snapshot age null, last-good false.
4. background refresh 뒤: failing/recovering/executable 1/1/1 current facts.

refresh 뒤 overall/fleet `ok`는 이 base에 아직 #31960의 failing→degraded policy가 없기
때문이다. 이 PR은 stale running snapshot 제거만 담당하며 해당 health policy를 주장하지 않는다.

## 검증과 경계

- focused server build: pass
- snapshot invalidation focused case: bootstrap 51, 1/1 pass
- `git diff --check`, touched OCaml format: pass
- MASC app exit 0; provider는 stop timeout exit 137
- deployed 8935와 `/Users/dancer/me/.masc`는 건드리지 않았다.

## 근거

- [근거] exact-source BuildKit checkout, image/binary identity, ready-before snapshot,
  `turn_failed(1)` log, immediate warming snapshot, refreshed current facts,
  2026-08-30T23:29:06+09:00 확인, 신뢰도 High.
