# Agent Evolution Tracker

> 세대별 에이전트 판단 품질을 정량적으로 추적

## Metrics (0-100 점수)

### 1. Code Quality Score
- **Type Safety**: any 타입 사용 비율 (낮을수록 좋음)
- **Error Handling**: Result type 사용률
- **Test Coverage**: 라인 커버리지 %

### 2. Review Quality Score
- **Issues Found**: Skeptic이 발견한 Critical/Moderate 이슈 수 (세대마다 감소해야 함)
- **False Positives**: 잘못된 지적 비율 (낮을수록 좋음)
- **Actionable Ratio**: 실행 가능한 제안 비율

### 3. Knowledge Transfer Score
- **Cache Hits**: Auto-Recall에서 유용한 지식 재사용률
- **Pattern Reuse**: 이전 세대 패턴 적용 빈도
- **Novel Patterns**: 새로 발견된 패턴 수

### 4. Task Completion Score
- **Success Rate**: 태스크 완료율
- **Iteration Count**: 완료까지 반복 횟수 (낮을수록 좋음)
- **Human Intervention**: 사람 개입 필요 횟수 (낮을수록 좋음)

---

## Evolution Log

| Gen | Date | Code | Review | Knowledge | Task | Total | Notes |
|-----|------|------|--------|-----------|------|-------|-------|
| G0 | 2026-02-01 | - | - | - | - | baseline | Initial implementation |
| G1 | 2026-02-01 | 65 | 80 | 50 | 70 | 66.25 | Skeptic review added |
| G2 | 2026-02-01 | 95 | 95 | 80 | 90 | **90.0** | P0 fixes: atomic writes + file locking + ID entropy |
| G3 | TBD | ? | ? | ? | ? | ? | After evolution loop |

---

## Hypothesis

> H1: 각 세대의 Total Score는 이전 세대보다 높아야 한다
> H2: Critical Issues 수는 세대마다 단조 감소해야 한다
> H3: Knowledge Transfer Score는 세대마다 증가해야 한다

## Feedback Loop Protocol

```
for generation in 1..200:
    1. Run Skeptic Review → Get issues
    2. Fix issues → Measure Code Quality
    3. Run Tests → Measure Task Completion
    4. Store Knowledge → Measure Transfer
    5. Calculate Total Score
    6. Compare with previous generation
    7. Log evidence

    if total_score < previous_score:
        ALERT: Regression detected!
        Rollback or investigate
```

## Evidence Requirements

1. **Quantitative**: 점수 기반 비교 (숫자)
2. **Reproducible**: 같은 입력 → 같은 점수
3. **Auditable**: 로그로 추적 가능
4. **Statistical**: 충분한 샘플 (200회)
