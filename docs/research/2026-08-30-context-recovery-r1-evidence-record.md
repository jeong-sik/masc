# Context recovery R1 근거 기록

## 공통 헤더

- 날짜(ISO8601): `2026-08-30T11:50:01+09:00`
- 작성자: `Codex`
- 결정 ID: `context-recovery-r1`
- 적용 대상: `MASC_BASE_PATH=~/me` 의 `.masc`, `~/me/workspace/yousleepwhen/masc`
- 결정 상태: `추적 필요`

## 근거

- 항목: [근거] prompt 경고와 뒤쪽 operator note는 qwen3:8b의 완료
  workspace를 고치지 못했다. pre-prompt revision 교체는 오래된 claim을
  제거하고 live claim만 주입했다.
- 출처: `docs/research/2026-08-30-context-recovery-runtime-poc-r1.md`,
  `benchmarks/context_recovery/results/20260830-r1/summary.json`,
  https://arxiv.org/abs/2605.06527,
  https://arxiv.org/abs/2608.01619
- 확인일시: `2026-08-30T11:50:01+09:00`
- 신뢰도: `High` for recorded prompt/workspace facts; `Low` for comparative
  performance because every condition is below `n=5`.
- 제한조건: 두 로컬 Ollama 모델과 세 작은 coding workspace에 한정한다.

## 검증

- 1차: 원저자 글, STALE, StateAuditor, PMLR 논문을 확인했다.
- 2차: source HEAD, binary sha256, memory revision 1/2,
  `last-prompt.json` block을 확인했다.
- 3차: 격리 서버를 반복 기동하고 실제 workspace verifier를 실행했다.
- 재현 결과: filtered mode는 stale claim 0건, live claim 1건을 만들었다.
  qwen3:8b는 0/1, Qwen3.8-27B는 1/1이었다.

## 불확실성

- 미확인 항목: 모델별 `n>=5`, 다른 provider, 장기 memory 의존 관계.
- 영향: `n=1` 통과를 엔진의 일반 성능 향상으로 오판할 수 있다.
- 추가 확인 필요: answer-only 축과 source-bound production refresh를
  분리해 반복한다.

## 적용범위

- 영향 받는 영역: context-recovery harness, 세 case, 1차 보고서.
- 제약/배제: production Memory OS schema와 recall 문구는 바꾸지 않는다.
- 롤백 조건: prompt에서 stale claim이 남거나 live claim이 빠진 filtered
  run은 무효로 처리한다.

## Delta

이전의 문제 서술을 prompt, note, pre-prompt refresh 세 PoC와 실제
workspace 결과로 교체했다.
