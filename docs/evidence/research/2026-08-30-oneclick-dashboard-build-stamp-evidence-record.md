# One-click dashboard build stamp 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T17:14:24+09:00`
- 작성자: `Codex`
- 결정 ID: `oneclick-dashboard-build-stamp-linux-r1`
- 적용 대상: one-click final dashboard bundle freshness identity
- 결정 상태: `추적 필요`

## 근거

- 항목: source-built server와 함께 shipping되는 one-click dashboard bundle은 final
  image에서 binary보다 오래되지 않은 `.build-stamp`를 가져야 한다.
- 출처: exact Git-context Linux image, container `build-commit`,
  `/health?full=1`, binary/index hashes, filesystem mtimes, 실제 restart logs
- 확인일시: `2026-08-30T17:14:24+09:00`
- 신뢰도: `High`
- 제한조건: unbound dashboard asset mode의 Linux/arm64 one-click image에서
  측정했다.
- Delta: runtime stage dashboard copy 직후 final image에 `.build-stamp`를 만든다.

## 검증

- 1차: baseline r12는 index가 있어도 fresh/restart 모두 surface `missing`과
  build-in-place recovery를 반환했다.
- 2차: Dockerfile ordering exact test 1/1이 통과했다. config_seed 전체는 10/11이며
  변경과 무관한 local binary prerequisite 1건이 실패했다.
- 3차: fixed r13 fresh/restart health가 모두 `ok`, recovery `none`, warning 0건이고
  stamp mtime이 binary보다 1초 새로웠다.
- 재현 결과: 성공. 실제 restart 뒤에도 immutable bundle freshness identity가
  유지됐다.

## 불확실성

- 미확인 항목: exact bound dashboard manifest/receipt deployment와 cross-platform
  Docker builders의 timestamp precision.
- 영향: second 단위 timestamp가 같더라도 server 계약은 `stamp < binary`일 때만
  stale이므로 equality는 fresh다.
- 추가 확인 필요: amd64 builder와 exact bound-asset release image를 별도
  측정한다.

## 적용범위

- 영향 받는 영역: `Dockerfile.oneclick` final dashboard bundle layer와 install
  contract test.
- 제약/배제: dashboard source/build output, exact asset manifest, frontend runtime,
  deployed `/Users/dancer/me/.masc`는 바꾸지 않았다.
- 롤백 조건: stamp가 binary보다 오래되거나, health가 `missing/stale`로 돌아가거나,
  index가 없는 image가 stamp만으로 `ok`가 되면 롤백한다.
