# Deferred runtime restart 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T21:34:34+09:00`
- 작성자: `Codex`
- 결정 ID: `deferred-runtime-restart-linux-r1`
- 적용 대상: Keeper next-cycle frozen runtime suffix
- 결정 상태: `추적 필요`

## 근거

- 항목: checkpoint 이후 defer된 runtime suffix는 checkpoint와 같은 process-restart lifetime을
  가져야 하며, 실패한 lane prefix를 restart가 다시 선택하면 안 된다.
- 출처: exact-source Linux BuildKit image, internal fake-provider request log,
  Keeper execution receipt, durable suffix snapshot, `/health?full=1`
- 확인일시: `2026-08-30T21:34:34+09:00`
- 신뢰도: `High`
- 제한조건: two-candidate lane과 typed thinking-only `Accept_rejected`로 측정했다.
- Delta: process-local ref였던 frozen suffix를 strict Keeper별 durable record로 승격하고,
  typed turn outcome 뒤에만 consume한다.

## 검증

- 1차: baseline source와 runtime에서 clean restart 후 4/4 provider POST가 실패한 GLM primary를
  반복하는 것을 확인했다.
- 2차: focused test 49건과 current-only codec save/load/clear 및 malformed schema fail-closed가
  통과했다.
- 3차: fixed exact-source Linux restart가 suffix 4개를 복원하고 4/4 최초 POST를 DeepSeek로
  전환한 뒤 suffix file을 0개로 settlement했다.
- 재현 결과: 성공. restart가 checkpoint는 유지하면서 routing authority만 잃던 gap을 닫았다.

## 불확실성

- 미확인 항목: 3개 이상 candidate suffix의 다단계 restart, durable write/remove I/O fault injection.
- 영향: 다단계 suffix ordering이나 filesystem fault 경계에서 fail-closed 로그/재시도 계약을 추가로
  확인해야 한다.
- 추가 확인 필요: Draft PR CI/review bot과 `#31966` failure-count restart persistence를 별도로
  추적한다.

## 적용범위

- 영향 받는 영역: autonomous Keeper heartbeat의 deferred runtime lane restore/record/settle.
- 제약/배제: runtime lane 선언, same-turn retry authority, provider protocol, receipt disposition,
  failure-count persistence는 바꾸지 않는다.
- 롤백 조건: restart가 failed primary를 다시 dispatch하거나, settled suffix가 파일에 남거나,
  malformed record를 무시하고 fresh lane을 실행하면 롤백한다.
