---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/
  - lib/keeper/keeper_context_core.ml
---

# Contract-Driven Agent Loop RFC Review

**Date**: 2026-03-27
**Scope**: pre-implementation validation memo

## Related

- [RFC](./contract-driven-agent-loop-rfc.md)
- [Implementation Checklist](./contract-driven-agent-loop-implementation-checklist.md)
- [Labeling Protocol](./contract-driven-agent-loop-labeling-protocol.md)

이 문서는 RFC를 구현 전에 단단하게 만들기 위한 세 가지 검증 관점을 기록한다.

- Boundary Auditor
- Measurement Skeptic
- Implementation Gatekeeper

## 0. External Fact-Check Corrections

외부 팩트 체크를 통해 다음 수정 사항을 반영했다.

- `keeper_meta`는 `106 fields`가 아니라 `54 direct fields`, nested까지 flat하게 보면 대략 `~83` 수준으로 정정
- `keeper_working_context.ml` / `keeper_exec_context.ml` 라인 수를 각각 `317 / 694`로 정정
- retired petition bridge의 decorative `Collaboration.t` 사용은 이미 resolved 상태로 변경
- labeling / judging protocol은 별도 문서로 분리
- rollout plan은 `OAS -> MASC -> MCP SDK` 순차 경로가 보이도록 조정

## 0.1 Technical Realizability Follow-up

후속 기술 리뷰를 통해 다음 구현 전제도 명시적으로 보강했다.

- contract를 `runtime_constraints`와 `eval_criteria`로 분리
- `requested_execution_mode`와 `effective_execution_mode`의 권한 분리 및 downgrade-only 규칙 추가
- proof bundle을 self-contained blob이 아니라 manifest + refs로 정의
- `result_status`를 execution termination state로 제한
- MASC digest의 1차 계산 방식을 structural-first로 제한
- `coding_task` gate를 structural checkpoint와 hard gate로 구분
- cross-repo shared surface를 shared package가 아니라 JSON schema + fixtures로 고정
- async eval의 policy propagation latency를 명시적 risk로 추가

## 0.2 Workshop Alignment and Boundary Health

워크숍 기반 후속 리뷰를 통해 다음을 추가로 고정했다.

- intra-run `gather -> act -> verify`는 OAS run path 안에서 hook / middleware로 수행
- proof bundle / transcript capture는 agent 코드가 아니라 OAS hook / middleware가 자동 수행
- fresh-context adversarial eval은 MASC-side separate evaluator profile로만 허용
- transcript reading은 rollout / harness 절차이며, OAS hidden memory 주입으로 다루지 않음

Boundary health는 `B+`로 본다.

- 문서상 분리는 건강하다.
- 가장 큰 위험은 workshop-inspired 기능을 편의상 OAS 안으로 몰아 넣는 구현 유혹이다.
- red line은 네 가지다.
  - OAS hook가 accept/reject나 policy update를 계산하지 않는다.
  - fresh-context evaluator는 README / design docs / room-task history를 읽지 않는다.
  - transcript는 artifact로 남기되 hidden prompt / memory로 주입하지 않는다.
  - MCP SDK는 hook / transcript / verdict 같은 workload semantics를 wire에 올리지 않는다.

## 1. Boundary Auditor

### Finding 1

**Severity**: High

`policy update` 문구만 두면 MASC가 OAS 내부 상태나 config를 직접 조작하는 방향으로 구현될 수 있다.

**Resolution**

RFC에 다음 원칙을 추가했다.

- 환류는 명시적 API / config / schema 경계로만 이뤄진다.
- MASC는 OAS 저장소를 직접 수정하지 않는다.
- OAS는 MASC domain state를 직접 변경하지 않는다.

### Finding 2

**Severity**: High

proof bundle이 acceptability score까지 품으면 평가 책임이 OAS로 새어 나갈 수 있다.

**Resolution**

RFC에 다음을 추가했다.

- OAS proof bundle은 raw execution evidence 중심이다.
- 최종 accept / reject는 MASC가 계산한다.

### Finding 3

**Severity**: Medium

MCP SDK typed state machine이 MASC workflow vocabulary를 직접 소유하면 protocol layer가 domain-specific 해진다.

**Resolution**

RFC에 다음을 추가했다.

- SDK state machine은 generic protocol semantics에 머문다.
- workflow semantics는 상위 레이어가 얹는다.

## 2. Measurement Skeptic

### Finding 1

**Severity**: High

`same model / same time / same tool budget`만으로는 benchmark fairness가 부족하다.

**Resolution**

RFC 비교 조건에 다음을 추가했다.

- same repo snapshot
- same harness seed / fixture set
- same provider capability snapshot

### Finding 2

**Severity**: High

`evidence_precision`, `unsupported_claim_penalty`는 labeling protocol 없이 쓰면 측정이 흔들린다.

**Resolution**

RFC에 다음을 추가했다.

- shared metrics는 사전 고정된 labeling / judging protocol 없이 사용하지 않는다.

### Finding 3

**Severity**: Medium

승격 기준이 수치로 미리 안 정해지면 PoC는 나중에 해석 싸움이 된다.

**Resolution**

RFC에 다음을 추가했다.

- 각 PoC는 실험 시작 전에 `adopt` 기준 수치를 명시해야 한다.

## 3. Implementation Gatekeeper

### Finding 1

**Severity**: High

rollback 조건이 흐리면 feature flag만 있고 실제로는 되돌리기 어려운 상태가 된다.

**Resolution**

RFC rollback 절에 다음을 추가했다.

- adoption threshold 미달
- latency overhead 과다
- false positive 과다

위 세 조건에서 즉시 이전 surface로 되돌린다.

### Finding 2

**Severity**: Medium

세 PoC를 동시에 구현하면 실패 원인을 분리하기 어렵다.

**Recommendation**

구현 순서는 다음으로 제한한다.

1. OAS `Execution Mode + Risk Contract`
2. MASC `Risk-Aware Supervisor Digest`
3. MCP SDK `Typed State Machine`

### Finding 3

**Severity**: Medium

문서만으로는 boundary discipline이 유지되지 않는다.

**Recommendation**

구현 시작 전에 checklist를 통과해야 한다.

- boundary invariant
- feature flag
- metric owner
- rollback path
- test plan

## 4. Final Assessment

현재 문서 세트는 docs PR 기준으로는 준비되었고, PoC-1 구현은 checklist gate를 잠근 뒤 시작할 수 있다.
실제 코딩 착수 전에는 다음 조건을 만족해야 한다.

1. implementation checklist가 작성되어 있어야 한다.
2. 첫 PoC의 adopt threshold가 숫자로 정해져 있어야 한다.
3. 경계 위반 금지 규칙이 코드 리뷰 기준으로 명시되어 있어야 한다.
4. contract split과 execution mode authority가 첫 구현에서 그대로 유지되어야 한다.
5. cross-repo schema sharing은 JSON schema + fixtures로 시작해야 한다.
6. workshop alignment red line이 구현에서 유지되어야 한다.
   - OAS hook는 accept/reject나 policy update를 계산하지 않는다.
   - fresh-context evaluator는 README / design docs / room-task history를 읽지 않는다.
   - transcript는 artifact로 남기되 hidden prompt / memory로 주입하지 않는다.
7. boundary health는 현재 `B+`이며, convenience-driven leakage가 보이면 구현 전 중단하고 재검토한다.
