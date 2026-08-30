# Source-bound Memory OS 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T12:42:25+09:00`
- 작성자: `Codex`
- 결정 ID: `memory-source-refresh-r1`
- 적용 대상: `keeper_memory_write`, Memory OS recall/search/status,
  `scripts/harness_coding_eval.sh`
- 결정 상태: `추적 필요`

## 근거

- 항목: source bytes가 바뀐 explicit memory claim은 model call 전에 빼고,
  새 claim을 쓸 때까지 typed invalidation을 유지한다.
- 출처: `https://pwning.systems/posts/llm-memory-program-analysis/`,
  `https://github.com/JordyZomer/lemmalog`,
  `https://arxiv.org/abs/2605.06527`,
  `https://arxiv.org/abs/2608.01619`, `git rev-parse HEAD`,
  `shasum -a 256 _build/default/bin/main_eio.exe`, isolated runtime artifacts
- 확인일시: `2026-08-30T12:42:25+09:00`
- 신뢰도: `High`
- 제한조건: file source만 지원한다. source는 Keeper sandbox 안의 regular
  file이어야 하며 1 MiB 이하여야 한다. 모델별 표본은 n<5다.
- Delta: ordinary fact schema를 바꾸는 대신 `source_path` opt-in current
  store를 추가했다. 기존 live snapshot 10개는 그대로 읽힌다.

## 검증

- 1차: Lemmalog 원문·저장소, STALE, StateAuditor의 provenance/retraction
  경계를 2026-08-30에 다시 확인했다.
- 2차: commit `b9633e8bc0e20d7ad96ae096fb21369e1e657a0c`, binary
  SHA-256 `d1ffd8611f371161c7e665f3a9b3c998970c248b2683d6d2ff8c10bbc0f0184a`,
  운영 `/health?full=1`, 격리 포트 종료 상태를 확인했다.
- 3차: exact binary로 stale source snapshot을 넣고 live file을 바꾼 뒤
  Gemma 4 31B Keeper episode를 실행했다. `/last-prompt`, final source
  snapshot, live digest, workspace verifier를 대조했다.
- 재현 결과: 성공. stale claim 0건, `source_changed` 2건, verifier exit 0,
  final fact 1건, invalidation 0건, live/final digest 일치. 비교 run에서는
  8B의 source 재생성 미호출도 관찰했다.

## 불확실성

- 미확인 항목: 여러 source가 하나의 claim을 함께 지지하는 경우,
  semantic summary 정확성, engine별 충분한 반복 표본, ordinary store가
  source write 뒤 커지는 동시성 경계.
- 영향: false claim은 prompt에 들어가지 않지만, 합산 budget 초과 시
  전체 memory block이 일시적으로 빠질 수 있다. weak model은 pending
  invalidation을 자동으로 해소하지 못할 수 있다.
- 추가 확인 필요: draft PR review 뒤 one-claim/multi-source 요구를 별도
  issue로 나눈다. 8B/27B/Gemma를 같은 exact head에서 최소 5회씩 돌리기
  전에는 성능 수치를 주장하지 않는다.

## 적용범위

- 영향 받는 영역: `keeper_memory_write(source_path)`, Memory OS first-round
  prompt, memory search, context status, coding eval source-bound mode.
- 제약/배제: ordinary facts, librarian selection, non-file source, semantic
  entailment, deployed `/Users/dancer/me/.masc` state는 바꾸지 않았다.
- 롤백 조건: stale claim이 `/last-prompt`에 나타나거나, source digest가
  다른데 fact가 current로 남거나, 기존 ordinary snapshot이 unreadable이
  되거나, 합산 byte budget을 넘는 부분 prompt가 주입되면 롤백한다.
