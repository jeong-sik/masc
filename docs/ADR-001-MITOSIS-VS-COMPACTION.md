> **Historical**: The mitosis runtime was removed in v2.170+. This ADR is preserved for architectural context. Context transfer now uses the Relay/Handoff system.

# ADR-001: Mitosis vs Compaction - 컨텍스트 한계 대응 전략

**Status**: Accepted
**Date**: 2026-02-01  
**Reviewers**: BALTHASAR (skeptic), Human (arbiter)

---

## Context

컨텍스트 윈도우가 가득 찼을 때 어떻게 대응할 것인가?

두 가지 접근법이 있다:
1. **Compaction** (OpenClaw 방식): 같은 세션에서 히스토리 요약
2. **Mitosis** (MASC 방식): 새 에이전트에게 DNA 전달 후 분열

## BALTHASAR의 비판 (4.5/10)

### 핵심 질문
> "왜 새 에이전트를 spawn해야 하는가? 같은 세션에서 압축하면 안 되나?"
> "생물학적 메타포에 현혹되지 말 것. 가장 단순한 해결책이 가장 robust함."

### 비판 포인트
| 문제 | 심각도 |
|------|--------|
| Spawn 실패 시 컨텍스트 손실 위험 | 🔴 Critical |
| context_ratio 신뢰성 (MODEL이 자기 컨텍스트를 정확히 모름) | 🔴 Critical |
| 복잡도 증가 (cell, pool, prepared_dna 상태 관리) | 🟡 Medium |
| Magic numbers (50%, 80% threshold) | 🟡 Medium |

### Compaction의 장점
- 단순함: 상태 관리 최소화
- 안전함: 실패해도 원본 유지
- 예측 가능: 같은 세션 유지

---

## Mitosis의 반박

### 1. Compaction의 한계

**정보 손실 불가피**
```
Original: 100K tokens → Compacted: 20K tokens
손실률: 80%
```
- 요약은 필연적으로 정보를 버림
- 미묘한 맥락, 톤, 암묵적 결정 사항이 소실됨
- "요약의 요약"이 반복되면 drift 발생

**같은 모델의 한계 반복**
- 컨텍스트가 찬 모델이 요약하면, 이미 성능이 저하된 상태
- "지친 뇌"가 요약하는 것 vs "fresh 뇌"가 DNA를 받는 것

### 2. Mitosis의 실제 이점

**Clean Slate Advantage**
```
Compaction: 같은 세션, 누적된 bias, 지친 모델
Mitosis:    새 세션, fresh start, DNA만 계승
```

**Multi-Agent 확장성**
```
Compaction: 단일 에이전트 한계
Mitosis:    Agent A (분석) → Agent B (구현) → Agent C (검증)
           역할별 최적화된 에이전트 체인 가능
```

**Graceful Degradation with Fallback**
```ocaml
(* v2에서 구현: spawn 실패 시 compaction으로 fallback *)
if not spawn_result.success then
  fallback_to_compaction prepared_cell
```
- Mitosis 실패해도 compaction으로 안전하게 전환
- 두 전략의 장점을 모두 취함

### 3. 언제 Mitosis가 더 나은가?

| 상황 | 권장 전략 | 이유 |
|------|----------|------|
| 짧은 대화 (<30% 컨텍스트) | 불필요 | 오버헤드만 발생 |
| 단순 Q&A | Compaction | 복잡한 맥락 불필요 |
| 장기 프로젝트, 복잡한 작업 | **Mitosis** | 정보 손실 최소화 |
| Multi-agent 협업 | **Mitosis** | 역할 분리, 병렬 처리 |
| 실패 허용 불가 | Compaction | 단순함이 안전 |

---

## Decision

**Hybrid Approach 채택**

1. **Primary**: Mitosis (2-phase proactive)
2. **Fallback**: Compaction (spawn 실패 시)
3. **Config**: threshold를 설정 가능하게

```ocaml
type strategy = 
  | MitosisFirst   (* 기본: mitosis 시도, 실패 시 compaction *)
  | CompactionOnly (* 보수적: 항상 compaction *)
  | MitosisOnly    (* 공격적: compaction 없음 *)
```

## Consequences

### 긍정적
- 장기 작업에서 정보 손실 최소화
- Multi-agent 확장 가능
- 실패 시에도 graceful degradation

### 부정적
- 구현 복잡도 증가
- context_ratio 추정의 불확실성
- spawn 비용 (시간, 토큰)

### 미해결 과제
1. context_ratio를 어떻게 정확히 측정할 것인가?
2. DNA 품질을 어떻게 검증할 것인가?
3. 모델별 threshold 최적값은?

---

## 후대를 위한 교훈

### BALTHASAR가 옳았던 점
- **단순함의 가치**: 복잡한 시스템은 실패 모드가 많음
- **검증 필수**: "작동한다"와 "프로덕션 준비"는 다름
- **메타포 경계**: 생물학적 비유가 실제 해결책을 보장하지 않음

### 그럼에도 Mitosis를 선택한 이유
- **Compaction은 천장이 있음**: 요약의 한계는 근본적
- **Multi-agent가 미래**: 단일 에이전트 최적화보다 협업 구조
- **Fallback이 있음**: 실패해도 compaction으로 전환 가능

### 결론
> "가장 단순한 해결책이 가장 좋다"는 원칙은 유효하지만,
> "단순함"의 정의가 "구현의 단순함"인지 "결과의 단순함"인지에 따라 답이 달라진다.
> Compaction은 구현이 단순하지만, 장기적으로 정보 손실이라는 복잡한 문제를 남긴다.
> Mitosis는 구현이 복잡하지만, 정보 보존이라는 단순한 목표를 추구한다.

---

## References

- BALTHASAR Review: 2026-02-01 (4.5/10 평가)
- OpenClaw Compaction: `/concepts/compaction.md`
- Keeper continuity flow: `/docs/KEEPER-USER-MANUAL.md`
- Cellular Agent Pattern: `/docs/CELLULAR-AGENT.md`

---

## Changelog

| Date | Change | Author |
|------|--------|--------|
| 2026-02-01 | Initial ADR, BALTHASAR review 반영 | Vincent |
| 2026-02-01 | v2 개선 (fallback, validation) | Vincent |
