# Source-bound Memory purge 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T13:52:58+09:00`
- 작성자: `Codex`
- 결정 ID: `memory-source-purge-r1`
- 적용 대상: dashboard Keeper purge artifact plan과 source-bound Memory OS
  snapshot
- 결정 상태: `추적 필요`

## 근거

- 항목: dashboard purge가 source-bound current snapshot을 typed artifact로
  strict removal하여 같은 이름의 새 Keeper가 이전 fact/invalidation을
  상속하지 않게 한다.
- 출처: `https://pwning.systems/posts/llm-memory-program-analysis/`,
  `https://github.com/JordyZomer/lemmalog`,
  `https://arxiv.org/abs/2605.06527`, `git rev-parse HEAD`, binary
  `build-commit`, `shasum -a 256`, isolated dashboard purge response,
  lifecycle log, persisted snapshots, Keeper metrics/chat, `/last-prompt`,
  `/health?full=1`, `lsof`
- 확인일시: `2026-08-30T13:52:58+09:00`
- 신뢰도: `High`
- 제한조건: 64자 이하 Keeper name에서 확인했다. 64자 초과 mismatch는
  #31919다. file-backed source snapshot만 다루며 engine 표본은 qwen3:8b
  한 run이다.
- Delta: purge plan과 path projection에 source snapshot variant를 추가했다.
  store wire shape, reader, migration은 바꾸지 않았다.

## 검증

- 1차: Lemmalog와 STALE의 retraction/state-resolution 경계를 2026-08-30에
  확인했다.
- 2차: source/embedded binary commit
  `cadfbc6b47d7ea646c29df7f4d8eef82b9478f95`, binary SHA-256
  `f527230f8c0a5e93880d7507e96660df9cf9673d4d72c88da969f34b5080e472`,
  focused test 22/22, 포트 종료와 운영 health를 확인했다.
- 3차: revision 2 source invalidation을 만든 뒤 서버를 재기동해 dashboard
  purge를 호출했다. 완료 후 source snapshot/TOML/runtime/meta 부재를
  확인하고, 또 재기동해 같은 이름 Keeper의 새 turn을 실행했다.
- 재현 결과: 성공. purge는 HTTP 202였고 네 artifact가 사라졌다. same-name
  turn은 `Succeeded`, response `AFTER_PURGE_OK`, dynamic context 0 bytes,
  source snapshot absent였다. 추가 restart의 `/last-prompt`는 404였다.

## 불확실성

- 미확인 항목: 64자 초과 Keeper, credential artifact lifecycle, purge 중
  process crash timing, non-file source.
- 영향: long-name Keeper는 현재 dashboard purge할 수 없다. crash timing에
  따라 durable shutdown recovery가 추가로 필요할 수 있다.
- 추가 확인 필요: #31919에서 create/purge name contract를 통일하고
  long-name create→purge→fresh-create exact runtime을 별도로 측정한다.

## 적용범위

- 영향 받는 영역: dashboard Keeper purge artifact enumeration, source
  snapshot path projection, same-name Keeper fresh lifecycle.
- 제약/배제: ordinary Memory behavior, source revalidation, aggregate budget,
  auth credential purge, store migration, deployed `/Users/dancer/me/.masc`는
  바꾸지 않았다.
- 롤백 조건: purge 완료 뒤 source snapshot이 남거나, same-name fresh turn의
  dynamic context에 이전 invalidation/fact가 나타나거나, 다른 typed artifact
  removal이 중단되면 롤백한다.
