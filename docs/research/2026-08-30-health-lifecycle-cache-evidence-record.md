# Health lifecycle cache 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T23:29:06+09:00`
- 작성자: `Codex`
- 결정 ID: `health-lifecycle-cache-linux-r1`
- 적용 대상: cached full-health Keeper fleet projection
- 결정 상태: `추적 필요`

## 근거

- 항목: Keeper registry phase mutation 뒤 full health는 TTL 내 old ready fields를 재사용하면 안 된다.
- 출처: exact-source Linux ready/transition/immediate/refresh snapshots와 focused test
- 확인일시: `2026-08-30T23:29:06+09:00`
- 신뢰도: `High`
- 제한조건: one Keeper의 `Running -> Failing` typed accept rejection을 실측했다.
- Delta: successful registry event CAS가 server-installed full-health invalidation observer를 호출한다.

## 검증

- 1차: baseline은 live failure 뒤 age 27.5초 ready `ok` snapshot을 반환했다.
- 2차: Event_bus listener wiring은 turn-failed event 부재로 실측 실패해 폐기했다.
- 3차: registry observer wiring은 transition 직후 warming/refresh-requested를 반환하고 refresh 뒤
  failing/recovering/executable 1/1/1을 반환했다.
- 재현 결과: 성공. TTL이 current Keeper mutation을 숨기던 false-ready window를 제거했다.

## 불확실성

- 미확인 항목: multi-server process와 observer callback failure injection.
- 영향: global cache/global observer는 현재 one-server process contract에서 검증됐다.
- 추가 확인 필요: Draft PR CI/review와 #31960 합성 뒤 degraded status를 확인한다.

## 적용범위

- 영향 받는 영역: Keeper registry event CAS와 cached full-health response.
- 제약/배제: health policy, Keeper retry/lifecycle, refresh interval은 바꾸지 않는다.
- 롤백 조건: committed phase mutation 뒤 old ready fields가 재출현하거나 observer failure가
  registry transition을 실패시키면 롤백한다.
