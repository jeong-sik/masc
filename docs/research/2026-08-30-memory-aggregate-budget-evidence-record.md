# Memory OS aggregate budget 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T13:32:06+09:00`
- 작성자: `Codex`
- 결정 ID: `memory-aggregate-budget-r1`
- 적용 대상: ordinary/source-bound Memory OS writer, recall budget,
  source invalidation persistence
- 결정 상태: `추적 필요`

## 근거

- 항목: 두 current store의 writer를 keeper별 aggregate lock으로 직렬화하고,
  상대 store의 exact rendered payload를 같은 commit 구간에서 읽어 합산
  budget 초과 snapshot 조합을 저장 전에 거절한다.
- 출처: `https://pwning.systems/posts/llm-memory-program-analysis/`,
  `https://github.com/JordyZomer/lemmalog`,
  `https://arxiv.org/abs/2605.06527`,
  `https://arxiv.org/abs/2608.01619`, `git rev-parse HEAD`, binary
  `build-commit`, `shasum -a 256`, isolated raw tool logs, source snapshots,
  `/last-prompt`, `/health?full=1`, `lsof`
- 확인일시: `2026-08-30T13:32:06+09:00`
- 신뢰도: `High`
- 제한조건: file-backed explicit claims만 다룬다. engine 표본은 Gemma 4
  31B 한 run씩이며 성능 비교가 아니다. purge lifecycle은 #31917에 남아
  있다.
- Delta: 별도 store shape는 유지하면서 aggregate writer lock만 추가했다.
  source revalidation은 strictly shorter invalidation만 만들기 때문에 lock
  밖에서 실행한다.

## 검증

- 1차: Lemmalog, STALE, StateAuditor의 deterministic provenance/retraction
  경계를 2026-08-30에 확인했다.
- 2차: source commit과 embedded binary commit
  `e57f5ac581249e21ea0aba98698f6b20bf1b3d95`, binary SHA-256
  `65342273d818dff5f7abd41ed25ad49649de65a4b1d19a4141cd6caa5c6a86c0`,
  focused test 16/16·22/22, 격리 포트 종료와 운영 health를 확인했다.
- 3차: 합산 budget 256에서 real Keeper turn으로 ordinary write를 시도하고,
  같은 config/target의 서버를 재기동한 뒤 두 번째 turn을 보냈다. 별도
  정상 source-refresh episode도 실행했다.
- 재현 결과: 성공. 실제 208-byte ordinary input은 합산 364 bytes로
  계산돼 `persistence_failed`였고 ordinary snapshot은 생기지 않았다.
  source invalidation은 restart 뒤에도 revision 2로 prompt에 남았다. 정상
  refresh는 verifier 0, final fact 1개, invalidation 0개였다.

## 불확실성

- 미확인 항목: 장기 file-lock contention, process crash timing, 여러 source가
  한 claim을 지지하는 경우, semantic entailment, source snapshot purge.
- 영향: contention은 write latency를 늘릴 수 있다. semantic 오류는 digest가
  맞아도 남을 수 있다. purge 누락은 keeper lifecycle 밖에 source memory를
  남길 수 있다.
- 추가 확인 필요: #31917을 별도 small PR로 고치고 purge→restart에서 source
  snapshot 부재를 실측한다. 여러 engine 반복 전에는 성능 수치를 주장하지
  않는다.

## 적용범위

- 영향 받는 영역: ordinary current replace/upsert, source-bound write,
  combined recall byte budget, source invalidation rendering.
- 제약/배제: store migration, compatibility reader, deployed
  `/Users/dancer/me/.masc`, non-file source, claim semantics, Keeper purge는 이
  변경에 포함하지 않았다.
- 롤백 조건: 두 writer가 합산 budget을 넘는 snapshot을 commit하거나,
  rejected write가 어느 store든 변경하거나, restart 뒤 pending invalidation이
  사라지거나, 정상 source refresh가 current fact를 재생성하지 못하면
  롤백한다.
