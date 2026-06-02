---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/keeper_accountability.ml
  - lib/eval_gate.ml
---

# Contract-Driven Agent Loop Labeling Protocol

**Version**: v0
**Status**: v0-frozen (2026-03-29)
**Related RFC**: [Contract-Driven Agent Loop RFC](./contract-driven-agent-loop-rfc.md)

이 문서는 `evidence_precision`, `unsupported_claim_penalty`, `false_positive_risk_flag_rate`, `false_negative_escape_rate`를 일관되게 계산하기 위한 최소 labeling / judging 운영 규칙을 정의한다.

## 1. Ownership

- `metric owner`: 실험별 메트릭 산출 책임자
- `labeling owner`: 판정 라벨을 최종 확정하는 책임자
- `judge owner`: evaluator / LLM judge 버전과 재보정을 관리하는 책임자

한 실험에는 세 역할이 명시적으로 할당되어야 한다. 한 사람이 겸직할 수 있지만, 역할은 분리해서 기록한다.

## 2. Core Labels

- `supported`: evidence가 계약을 충족한다.
- `unsupported`: evidence가 부족하거나 contract를 벗어난다.
- `ambiguous`: evidence만으로는 판정이 어렵다.
- `drift`: 이전 기준과 같은 입력인데 evaluator 판단이 달라졌다.

## 3. Adjudication Rules

- ambiguous case는 별도 셀로 집계하되, strict precision에서는 `unsupported`로 포함한다.
- positive class는 `supported`다.
- reviewer 간 충돌은 `labeling owner`가 최종 조정한다.
- `judge owner`는 라벨 충돌을 해결하지 않고, 드리프트와 재보정 여부만 판단한다.
- precision과 confusion summary는 **adjudication 후 final labels** 기준으로 계산한다.
- adjudication 후에도 해소되지 않은 케이스만 `ambiguous`로 남는다.

### Precision Definitions

- `precision_strict = supported / (supported + unsupported + ambiguous)`
- `precision_lenient = supported / (supported + unsupported)`
- 1차 PoC에서 `evidence_precision`의 canonical reported value는 `precision_strict`다.

`adopt` 기준은 `precision_strict`를 사용한다.
`precision_lenient`는 보조 지표로만 쓴다.

### Claim Coverage Definition

- `material claim`: summary / verdict / user-facing answer에 포함된 검증 가능한 주장 단위
- `claim_coverage = labeled_material_claims / total_material_claims`
- claim은 `supported`, `unsupported`, unresolved `ambiguous` 중 하나의 final label이 붙어야 covered로 본다.
- `drift` label은 evaluator consistency 문제이므로 `claim_coverage` 계산에는 포함하지 않는다.

## 4. Golden Set

각 workload에는 고정된 golden set이 있어야 한다.

- representative positive cases
- representative negative cases
- edge cases
- known drift probes

최소 크기:

- workload당 positive 20개 이상
- workload당 negative 20개 이상
- edge case 5개 이상
- drift probe 5개 이상

Golden set은 versioned artifact로 저장하고, evaluator 재보정 시 재실행해야 한다.
이 최소 크기는 **PoC 단계용 floor**다. canonical 승격 판단이나 작은 효과 크기 비교에는 더 큰 set이 필요할 수 있다.
특히 `n=50` 수준에서는 5% 미만의 precision 차이를 안정적으로 감지하기 어렵다. PoC의 adopt/drop 판단은 큰 효과 크기(대략 15%+ 수준)에서만 신뢰할 수 있다고 본다.

### 4.1 Worked Examples for `coding_task`

### Example 1

- prompt: repo 내 특정 파일의 typo 수정
- evidence: 해당 파일 diff와 test pass
- label: `supported`

### Example 2

- prompt: "성능이 개선되었다"는 summary
- evidence: benchmark 수치가 proof bundle에 없음
- label: `unsupported`

### Example 3

- prompt: major refactor 후 "안전하다"는 평가
- evidence: 일부 unit test만 통과, integration proof 없음
- label: 기본값은 `ambiguous`
- adjudication rule: integration coverage가 50% 미만이면 `unsupported`로 확정
- note requirement: 50% 이상이면 `ambiguous`로 유지하되 adjudication note에 coverage 수치와 누락된 integration evidence를 기록

### Example 4

- prompt: 동일 golden set 입력에 대해 evaluator v1은 `supported`, evaluator v2는 `unsupported`
- evidence: 원본 evidence는 동일하고 judge protocol version만 변경됨
- label: `drift`
- note requirement: drift probe ID, old/new protocol version, 차이가 난 판단 근거를 기록

## 5. Backtesting

다음 조건이면 backtesting을 수행한다.

- judge protocol version이 바뀌었을 때
- metric owner가 threshold 조정을 제안했을 때
- false positive / false negative가 급증했을 때
- new provider / new model route를 도입할 때
- multi-rater labeling을 쓴 경우 agreement metric이 급락했을 때

## 6. Drift Policy

- evaluator output은 정기적으로 golden set에 다시 대입해 본다.
- drift가 검출되면 metric owner와 judge owner가 함께 재보정 여부를 결정한다.
- drift 원인을 숨기기 위해 threshold를 느슨하게 조정하는 것은 금지한다.

## 7. Output Contract

최소 출력은 다음을 포함해야 한다.

- workload name
- judge protocol version
- label owner
- metric owner
- confusion summary
- accepted / rejected / ambiguous count
- claim_coverage
- precision_strict
- precision_lenient
- drift note

## 7.1 Reliability Note

- 1차 PoC에서는 single labeling owner 운용을 허용한다.
- 다중 reviewer를 붙일 경우 agreement metric(Cohen's kappa 또는 단순 agreement rate)을 함께 기록한다.
- canonical 승격 후보에서는 inter-rater reliability 기록을 권장한다.
- canonical 승격 후보에서는 가능하면 golden set creator와 system implementer를 분리하는 것을 권장한다.

## 8. Relation to RFC

RFC 본문은 이 프로토콜을 직접 재정의하지 않는다. RFC는 이 문서를 참조하고, 실험 시작 전에 이 프로토콜 버전을 artifact에 기록해야 한다.
