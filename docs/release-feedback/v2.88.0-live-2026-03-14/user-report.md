# 사용자 리포트

Date: 2026-03-14
Target: live MCP `2.88.0`

## Executive Summary

`2.88.0` 은 사용자 입장에서 “운영 read path 신뢰도는 좋아졌고, execution은 조금 더 정직해졌다”로 요약할 수 있다.

- 좋은 점: 버전 표기가 맞고, dashboard current 가 살아있다.
- 여전히 좋은 점: 단일 worker coding flow는 실무적으로 쓸 수 있다.
- 아직 남은 점: 여러 worker를 이어 붙이는 순간 readiness 와 max-turn 한계가 다시 드러난다.

## Live Snapshot

| 항목 | 관찰값 | 사용자 영향 |
|------|--------|-------------|
| Health version | `2.88.0` | live service 기준 버전 판단 가능 |
| Agent card version | `2.88.0` | 클라이언트 버전 표기도 일치 |
| Auth state | disabled | onboarding은 쉽지만 운영 정책은 느슨함 |
| Dashboard current | compact summary 정상 반환 | 운영자가 최소 요약은 바로 읽을 수 있음 |

## Case Matrix

| Case | Goal | Result | 사용자 해석 |
|------|------|--------|-------------|
| Single worker coding | temp repo 코드 수정 + 검증 + proof | 성공 | 권장 경로 유지 |
| Sequential multi-worker | implementer patch + verifier 재검증 | 부분 성공 | 실험적이지만 이전보다 낫다 |
| Batch follow-up delegate | batch 후 implementer delegate | 계약 개선 | still experimental |

## Case 1: Single Worker Coding Passed Again

Observed behavior:

- worker가 `file_read`, `shell_exec`, `file_write`, `shell_exec` 순서로 실제 tool을 사용했다.
- temp repo `calc.py` 를 `return 4` 에서 `return 5` 로 수정했다.
- `python3 check.py` 가 `ok 5` 로 통과했다.
- proof는 다시 `proved`, `score_pct=100.0` 이었다.

User interpretation:

- 이 버전에서도 가장 추천 가능한 패턴은 바뀌지 않았다.
- 작은 범위 patch, blocking completion, proof 확인 조합은 여전히 유효하다.

## Case 2: Sequential Multi-worker Improved But Is Still Experimental

Observed behavior:

- implementer worker는 읽기 단계와 patch delegate를 모두 성공했다.
- 실제 두 파일이 수정되었고 로컬 `python3 check.py` 는 `ok 14.00 ...` 로 통과했다.
- 하지만 verifier worker는 `Max turns exceeded` 로 끝났고 독립 verification turn은 실패했다.

User interpretation:

- “작업 분업” 자체는 예전보다 더 현실적이 되었다.
- 다만 “검증 전용 두 번째 worker도 안정적으로 끝난다”고 보기엔 아직 이르다.

Current recommendation:

- multi-worker를 쓰더라도 최종 성공 판정은 proof와 실제 산출물 검증으로 함께 본다.
- verifier를 추가하는 것은 실험적 옵션으로 취급한다.

## Case 3: Batch Follow-up Delegate Is More Honest Now

Observed behavior:

- `spawn_batch` 응답은 두 worker 모두 `accepted` 와 `ready:false` 를 명시했다.
- 후속 delegate는 더 이상 opaque target-worker lookup failure 로 실패하지 않았다.
- 대신 `target worker ... is not ready for delegation yet` 라는 명시적 에러를 반환했다.

User interpretation:

- 아직 즉시 delegate는 안 되지만, 실패 이유가 이제 public contract 수준에서 이해 가능하다.
- 즉 “broken” 보다는 “아직 준비 안 됨”에 가까워졌다.

Current recommendation:

- batch worker는 `ready:true` 또는 성공적인 `team_step_spawn` 증거를 보기 전에는 follow-up 하지 않는다.

## Product Readout

### Fixed in 2.88.0

- version truth mismatch
- dashboard current immediate lock failure

### Improved but still experimental

- batch follow-up delegate
- sequential multi-worker coding

### Still safest

- single worker coding + proof

## User Message For This Version

- "이번 버전에서는 운영 read path와 버전 표기가 더 신뢰 가능해졌습니다."
- "단일 worker 실무 경로는 계속 추천합니다."
- "다중 worker 협업은 이전보다 정직한 실패/상태 신호를 주지만, 아직 실험적입니다."
