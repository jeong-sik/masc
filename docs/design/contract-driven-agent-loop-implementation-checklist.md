---
status: runbook
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/
  - lib/server/
---

# Contract-Driven Agent Loop Implementation Checklist

**Status**: Pre-implementation gate
**Related RFC**: [Contract-Driven Agent Loop RFC](./contract-driven-agent-loop-rfc.md)
**Related Labeling Protocol**: [Contract-Driven Agent Loop Labeling Protocol](./contract-driven-agent-loop-labeling-protocol.md)

이 문서는 구현 시작 전에 반드시 통과해야 하는 경계 / 계측 / 롤백 체크리스트다.

## 1. Go / No-Go Gate

구현 시작 전 아래 항목이 모두 `yes`여야 한다.

- [ ] 이번 변경이 OAS / MASC / MCP SDK 중 어느 레이어 책임인지 한 문장으로 설명할 수 있다.
- [ ] baseline workload, repo snapshot, model route, provider route가 고정되어 있다.
- [ ] 성공 지표와 중단 지표가 숫자로 정의되어 있다.
- [ ] metric owner와 labeling / judging protocol owner가 지정되어 있다.
- [ ] labeling / judging protocol 문서와 version freeze가 고정되어 있다.
- [ ] contract가 `runtime_constraints`와 `eval_criteria`를 구분하거나, passthrough 규칙이 명시되어 있다.
- [ ] contract author가 `runtime_constraints`와 `eval_criteria`의 호환성을 검증했다.
- [ ] `requested_execution_mode`와 `effective_execution_mode`의 결정 주체와 downgrade rule이 문서화되어 있다.
- [ ] RFC에 정의된 proof bundle minimal schema (field list + version)가 실험 기준으로 잠겨 있다.
- [ ] cross-repo schema sharing mechanism이 문서화되어 있다.
- [ ] feature flag 또는 experimental path가 있다.
- [ ] rollback path가 문서화되어 있다.
- [ ] artifact store backend와 proof artifact를 어디에 남길지 정해져 있다.

하나라도 `no`면 구현 시작 금지다.

## 2. Boundary Checklist

### OAS

- [ ] 이번 변경은 per-run execution policy, capability routing, proof bundle에만 닿는다.
- [ ] room/task/governance/session acceptability를 OAS가 영속 상태로 소유하지 않는다.
- [ ] provider-specific behavior는 OAS 안에서만 결정되고 MASC에 흘러나오지 않는다.
- [ ] OAS는 requested mode를 downgrade만 할 수 있고, upgrade하지 않는다.
- [ ] hook / middleware는 runtime-local deterministic verification과 context injection만 담당한다.
- [ ] proof bundle / transcript capture는 OAS hook / middleware가 자동 수행하고, agent code는 proof-aware하지 않다.
- [ ] proof bundle은 raw execution evidence 중심이고, 최종 accept / reject 판정을 포함하지 않는다.

### MASC

- [ ] 이번 변경은 cross-run supervision, proof aggregation, benchmark, intervention surface에만 닿는다.
- [ ] provider prompt logic, tool-call formatting, fallback order를 MASC가 소유하지 않는다.
- [ ] OAS evidence를 소비하지만 OAS session state를 직접 수정하지 않는다.
- [ ] MASC는 contract를 통해 requested mode를 제안할 수 있지만, OAS runtime state를 직접 바꾸지 않는다.
- [ ] stage gate는 MASC workflow policy로 유지되고 OAS 내부 run policy로 내려가지 않는다.
- [ ] fresh-context adversarial eval을 도입해도 README / design docs / room-task history를 주입하지 않는다.

### MCP Protocol SDK

- [ ] 이번 변경은 generic protocol invariant, state machine, validation ergonomics에만 닿는다.
- [ ] `coding_task`, `repo_synthesis`, supervisor digest 같은 workload vocabulary가 wire type에 들어가지 않는다.
- [ ] stable / experimental surface 구분이 유지된다.
- [ ] compatibility strategy가 있다.

## 3. Harness Checklist

- [ ] input contract가 artifact로 남는다.
- [ ] OAS proof bundle이 artifact로 남는다.
- [ ] replayable tool-call transcript가 artifact로 남는다.
- [ ] RFC에 정의된 proof bundle minimal schema (field list + version)가 실험 기준으로 잠겨 있다.
- [ ] proof bundle refs의 store namespace, retention window, dereference failure policy가 정의되어 있다.
- [ ] evaluator result가 artifact로 남는다.
- [ ] intervention summary가 artifact로 남는다.
- [ ] final acceptance verdict가 MASC evaluator artifact로 남는다.
- [ ] baseline과 candidate가 같은 model / time / tool budget으로 비교된다.
- [ ] repo snapshot과 fixture set이 고정되어 있다.
- [ ] judging protocol version이 artifact에 함께 기록된다.

## 4. Measurement Checklist

- [ ] `evidence_precision`
- [ ] `claim_coverage`
- [ ] `unsupported_claim_penalty`
- [ ] `latency_ms`
- [ ] `cost`
- [ ] `human_intervention_count`
- [ ] `human_review_minutes`
- [ ] `false_positive_risk_flag_rate`
- [ ] `false_negative_escape_rate`

위 지표 중 빠지는 항목이 있으면 그 이유와 대체 지표를 먼저 문서화해야 한다.
`claim_coverage` 정의와 예외(`drift` 제외 등)는 labeling protocol의 `Claim Coverage Definition`을 canonical source로 따른다.

- [ ] digest field별 computation method가 분류되어 있다.
  - `structural only`
  - `structural/historical`
  - `advisory hybrid`

## 5. Compatibility Checklist

- [ ] 기존 client / tool / harness를 깨지 않는다.
- [ ] SDK 변경은 experimental namespace 또는 module alias 뒤에 둔다.
- [ ] OAS 변경은 feature flag 뒤에 둔다.
- [ ] MASC 변경은 additive read surface로 시작한다.
- [ ] dual-read 또는 migration plan이 필요하면 사전에 적는다.

## 6. Merge Blockers

아래 항목이 모두 `yes`여야 merge 가능하다.

- [ ] boundary leak reject rule 위반이 없다.
- [ ] baseline lock이 있다.
- [ ] rollback rehearsal을 수행했다.
- [ ] false positive / false negative 측정이 있다.
- [ ] artifact뿐 아니라 재현 가능한 harness도 있다.
- [ ] feature flag 없이 canonical path를 직접 변경하지 않았다.

## 7. Exit Criteria

PoC 종료 시 아래 중 하나로만 판정한다.

- `adopt`: 품질 유지 또는 개선, cost/latency budget 충족, rollback 확인
- `defer`: 아이디어는 유효하지만 계측 부족 또는 compatibility 리스크 큼
- `drop`: baseline 대비 이득 없음, boundary leak 큼, 운영 복잡도 과도
