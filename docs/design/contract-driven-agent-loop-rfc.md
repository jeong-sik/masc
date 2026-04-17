---
status: live
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/
  - lib/server/
---

# Contract-Driven Agent Loop RFC

**Status**: Design-complete for pre-production single-run scope; production-incomplete
**Date**: 2026-03-27
**Scope**: OAS / MASC / MCP Protocol SDK
**One sentence**: `contract -> run -> proof -> eval -> policy update` 루프를 OAS, MASC, MCP SDK로 분리해 하네스와 내부 구조를 개선한다.

## Related Documents

- `../../../oas/docs/architecture.md`
- `../../../oas/docs/provider-capabilities-spec.md`
- `../SUPERVISOR-MODE.md`
- `../BENCHMARK-RUNBOOK.md`
- `../COMMAND-PLANE-RUNBOOK.md`
- `../../../mcp-protocol-sdk/docs/COMPARATIVE-ANALYSIS-AND-IMPROVEMENTS.md`
- `../../../mcp-protocol-sdk/docs/RELEASE-POLICY.md`
- `./oas-masc-state-boundary.md`
- `./cdal-contract-kernel-and-advisory-split.md`
- `./check-evaluation-spec.md`
- `./proof-bundle-check-mapping.md`
- `./cross-run-loader-and-window-spec.md`
- `./error-handling-and-operations-spec.md`
- `./mode-violations-evidence-v1.schema.json`
- `./CDAL-PHASE1A-TEAM-START-HERE.md`
- `./contract-driven-agent-loop-labeling-protocol.md`
- `./contract-driven-agent-loop-implementation-checklist.md`
- `./contract-driven-agent-loop-rfc-review.md`

## Readiness Snapshot

- `single-run scoped audit` 기준의 pre-production 문서 상태는 `Go`다.
- `full production CDAL` 상태는 아직 `No-Go`다.
- production go 이전에 최소 다음이 닫혀야 한다.
  - `check-evaluation-spec.md`
  - `proof-bundle-check-mapping.md`
  - `cross-run-loader-and-window-spec.md`
  - `error-handling-and-operations-spec.md`
  - OAS evidence v2 and read-side API
- 현재 경계 건강도 평가는 `B+`다. 구현 중 convenience-driven leakage가 보이면 즉시 중단하고 재검토한다.

## 1. Problem Statement

현재 스택은 실행 primitive는 강하지만, 실행 전에 무엇이 허용되는지와 실행 후 무엇을 증명해야 하는지에 대한 공통 계약이 약하다.

그 결과:

- 생성 속도가 검증 속도를 앞지른다.
- unsupported claim, tool misuse, execution drift가 run 간에 일관되게 보이지 않는다.
- supervisor는 상태를 볼 수 있지만 `왜 멈춰야 하는지`를 구조적으로 못 본다.
- MCP wire와 state transition은 여전히 일부가 runtime discipline에 기대고 있다.
- benchmark는 존재하지만 `계약`, `proof`, `policy update`가 하나의 루프로 묶여 있지 않다.

이 RFC의 목적은 `더 똑똑한 한 번의 에이전트 실행`이 아니라 `더 잘 틀리고, 더 잘 잡히고, 더 잘 개선되는 반복 구조`를 만드는 것이다.

## 2. Non-Goals

이 RFC는 다음을 하지 않는다.

- 새로운 범용 자율 에이전트 플랫폼을 만들지 않는다.
- 모든 workload를 완전 자동화하겠다고 약속하지 않는다.
- 모든 모델/프로바이더에 동일한 autonomy를 허용하지 않는다.
- MASC에 inference prompt logic을 누적하지 않는다.
- OAS에 cross-run orchestration과 room/domain state를 넣지 않는다.
- MCP SDK에서 workload policy나 supervisor semantics를 소유하지 않는다.

## 3. Current State

### OAS

OAS는 single-run execution engine이다.

- `Agent`, `Pipeline`, `Provider`, `Guardrails`, `Hooks`, `Metrics`, `Context_reducer`를 갖고 있다.
- provider capability truth에 가장 가깝다.
- 하지만 현재는 explicit한 per-run `risk contract`와 `execution mode`가 없다.

### MASC

MASC는 supervision, orchestration, proof, benchmark 쪽 substrate를 이미 갖고 있다.

- `snapshot -> diagnose -> preview -> human confirm -> execute -> re-check` supervisor loop가 있다.
- command-plane과 team-session, benchmark runbook이 있다.
- 하지만 `ambiguity`, `evidence_gap`, `drift_risk` 같은 risk-aware digest는 아직 1급 개념이 아니다.
- `coding_task` stage graph는 문서상 canonical이지만 gate로 완전히 강제되진 않는다.

### MCP Protocol SDK

MCP SDK는 protocol substrate다.

- 타입 안전성과 conformance 지향이 이미 강하다.
- 하지만 일부 중요한 상태 전이는 여전히 runtime predicate에 의존한다.
- validation error ergonomics도 더 강화할 수 있다.

## 4. Proposed Loop

```text
contract
  -> run
  -> proof
  -> eval
  -> policy update
```

### Contract

실행 전에 하나의 flat blob이 아니라 아래 두 표면을 고정한다.

- `runtime_constraints`
  - `requested_execution_mode`
  - `risk_class`
  - `allowed_mutations`
  - `review_requirement`
- `eval_criteria`
  - `success_criteria`
  - `required_evidence`

OAS는 `runtime_constraints`만 집행한다.
`eval_criteria`는 OAS가 opaque하게 proof bundle까지 운반하고, MASC가 사후 평가에 사용한다.
초기 contract author는 caller 또는 MASC-side composer일 수 있지만, run 시작 시 OAS에 전달된 exact snapshot이 authoritative input contract가 된다.
contract author는 `runtime_constraints`와 `eval_criteria`가 서로 양립 가능한지 사전에 검증할 책임이 있다.

#### Risk Class Canonical Reference

`risk_class`의 canonical definition은 아래 `Working Risk Taxonomy`를 따른다.
이 섹션은 정책 표면만 제공하며, 별도의 의미를 추가하지 않는다.
해석이 충돌하면 `Working Risk Taxonomy`가 우선한다.

### Run

execution runtime이 contract와 capability constraints를 반영해 run을 수행한다.
1차 PoC에서 run은 단일 black box가 아니라 `gather -> act -> verify`의 intra-run subloop를 포함한다.

- OAS hook / middleware는 tool call 전후에 deterministic verification을 수행할 수 있다.
- OAS hook / middleware는 필요한 live context를 주입할 수 있다.
- `allowed_mutations` 같은 runtime constraint 위반은 run path 안에서 막고, 사후 eval로 미루지 않는다.
- 이 intra-run verify는 run-local discipline이며, MASC의 cross-run acceptability eval과 역할이 다르다.

### Proof

OAS는 answer만이 아니라 proof bundle을 남긴다.
proof bundle 생성은 OAS hook / middleware가 자동 수행해야 하며, agent 코드에 proof-awareness 로직을 넣지 않는다.

### Eval

MASC는 proof bundle, traces, benchmark axis를 이용해 run을 평가한다.
여기서 중요한 점은 `eval`이 단일 출력이 아니라 **세 개의 서로 다른 출력 surface**를 가진다는 것이다.

- `contract_verdict`
  - deterministic
  - replayable
  - fail-closed
  - same proof bundle + same contract snapshot + same loader semantics이면 항상 같은 결과가 나와야 한다.
- `friction_projection`
  - deterministic
  - non-authoritative
  - operator-facing default
  - persisted eval artifacts와 declared history window를 기반으로 계산된다
- `advice` / `operator_narrative`
  - optionally nondeterministic
  - rerunnable
  - explanatory and optimization-facing
  - `contract_verdict`와 `friction_projection`을 소비하지만 둘을 덮어쓰거나 바꾸지 않는다.

1차 PoC에서는 free-form `advice` surface가 비어 있거나 생략될 수 있다.
하지만 `contract_verdict` surface는 비어 있을 수 없다.
또한 phase-1 operator value를 위해 최소 `friction_projection` surface도 비어 있지 않는 쪽이 바람직하다.

즉 판정은 판정이고, observability는 observability이며, 설명과 권고는 설명과 권고다.
이 셋을 같은 타입, 같은 상태 색, 같은 merge gate 입력으로 취급하면 안 된다.

Terminology rule:

- canonical schema term은 `friction_projection`이다.
- `friction digest`, `friction view`, `operator friction summary` 같은 표현은 UI 또는 prose alias일 뿐이며, spec surface 이름으로 쓰지 않는다.

추가 규칙:

- accept / reject / stage gate는 `contract_verdict`만 사용한다.
- manual or assisted contract refresh / policy tuning은 `friction_projection`과 `advice`를 사용할 수 있다. 다만 이는 gate authority가 아니다.
- contract-relevant evidence가 부족하면 verdict는 `satisfied`가 아니라 `inconclusive`여야 한다.
- `eval_criteria`는 typed deterministic subset이 정의되기 전까지 advisory 또는 completeness surface에 남을 수 있다.
- advisory artifact는 verdict reference를 가져야 하며, verdict를 override하지 못한다.
- deterministic kernel은 heuristic join이나 advisory-only data에서의 semantic reconstruction을 수행하지 않는다.
- `friction_projection`은 gate truth가 아니라 typed observability projection이다.

Eval-to-policy connection:

- `eval`은 최소 `contract_verdict`와 `friction_projection`을 산출한다.
- `policy update`는 gate semantics에 대해서는 `contract_verdict`만 읽는다.
- manual or assisted contract refresh는 `friction_projection`을 primary operator signal로 읽고, 필요하면 `advice`를 함께 읽는다.
- 따라서 `friction_projection`은 loop 바깥의 임의 관측값이 아니라, `eval -> policy update` 구간에 명시적으로 연결된 typed artifact다.

### Policy Update

실패 패턴은 다음 세 가지 중 하나로 환류한다.

- OAS execution policy
- MASC supervision / stage gate
- MCP SDK invariant / conformance

이 환류는 **명시적인 API / config / schema 경계**를 통해서만 이뤄져야 한다.

- MASC가 OAS 내부 저장소를 직접 수정하지 않는다.
- OAS가 MASC domain state를 직접 변경하지 않는다.
- MCP SDK가 workload-specific policy를 새 wire field로 끌어올리지 않는다.

### Async Boundary

`run -> proof`는 request path에 있을 수 있지만, `eval -> policy update`는 기본적으로 background pipeline으로 분리한다.

- run path는 evaluator completion을 기다리지 않는다.
- evaluator는 timeout, queue limit, backpressure policy를 가져야 한다.
- evaluator queue 포화 시 fail-open이 아니라 명시적 degraded mode 또는 fail-closed policy를 택해야 한다.
- benchmark/eval traffic과 live traffic은 가능하면 분리된 queue 또는 capacity class를 사용한다.
- 위 분리는 cross-run eval / policy update에 대한 것이다. rule-based intra-run verification과 hook-based context injection은 hot path에 남을 수 있다.
- 1차 PoC에서는 `policy update -> next contract` 자동 반영 경로를 구현하지 않는다. 초기 loop closure는 supervised/manual 또는 assisted contract refresh에 머문다.
- `contract_verdict`와 `advice`는 같은 queue를 공유할 수 있지만, lifecycle은 분리한다.
- `contract_verdict` 생성 실패는 fail-closed 또는 explicit `inconclusive` artifact로 처리한다.
- `advice` 생성 실패는 verdict를 바꾸지 않는다. 필요하면 생략하거나 나중에 재생성한다.

### Human Governance and Interpretation

기술 경계만으로는 충분하지 않다. 사람과 UI도 verdict와 advice를 다시 섞지 못하게 설계해야 한다.

이 RFC는 principle-level separation만 고정한다.
정확한 렌더링, 카드 구조, 색 규칙, dashboard interaction detail은 별도 UI / dashboard spec에서 정의한다.

- `contract_verdict`만 authoritative gate surface다.
- `friction_projection`은 non-authoritative but typed operator observability surface다.
- `advice`는 non-authoritative explanatory surface다.
- verdict, friction, advice는 presentation에서도 명확히 구분 가능해야 한다. detailed rendering rules는 dashboard or operator-facing spec에서 구체화한다.
- operator-facing UI는 세 surface를 세 개의 동등한 알림 스트림으로 노출하면 안 된다. 기본 UX는 prioritized review queue 또는 equivalent action queue로 수렴시키고, surface distinction은 drill-down과 provenance에서 유지한다.
- `inconclusive`는 explicit human handling이 필요하다. override 시 actor, reason, timestamp, linked incident를 남긴다.
- 기본 처리 규칙은 `operator review queue`다. configured SLA 내에 처리되지 않으면 auto-pass가 아니라 `blocked/defer`로 승격한다.
- contract author, contract approver, verdict consumer, `inconclusive` override actor를 구분해 기록한다.
- typed deterministic clause로 승격되지 않은 의미를 `eval_criteria`에 숨겨 넣고 authoritative gate에 사용하는 행위는 금지한다.
- `contract_verdict = satisfied`는 world-level safety claim이 아니다. operator-facing copy와 downstream automation은 이를 scoped contract claim으로만 해석해야 한다.
- `friction_projection`은 descriptive observability artifact다. direct model-training reward, sole auto-relaxation objective, or unsupervised contract widening signal로 사용하면 안 된다.
- 반복 blocked-attempt나 반복 evidence-gap이 configured threshold를 넘으면 별도 deterministic review tripwire를 발화시킬 수 있다. 이 tripwire는 `contract_verdict`를 덮어쓰지 않지만, explicit human review를 요구하는 policy input이 될 수 있다.
- boundary compliance는 naming convention이 아니라 tested property로 다룬다.

## 5. Layered Responsibilities

### OAS

OAS는 **how a run executes** 를 결정한다.

OAS MUST:

- per-run execution policy를 집행해야 한다.
- contract, risk class, capability snapshot에 따라 허용 가능한 action scope를 조정할 수 있어야 한다.
- hook / middleware를 통해 deterministic verification과 context injection을 수행할 수 있어야 한다.
- proof bundle을 표준 출력물로 만들 수 있어야 한다.
- proof bundle은 **raw execution evidence** 중심이어야 하며, 최종 accept / reject 판정은 소유하지 않는다.

OAS MUST NOT:

- cross-run acceptability를 최종 판정하지 않는다.
- room/task/governance 같은 domain state를 소유하지 않는다.

### MASC

MASC는 **whether a run is acceptable** 를 결정한다.

MASC MUST:

- run-level proof를 session/operation/room 단위로 종합해야 한다.
- risk-aware digest와 intervention surface를 제공해야 한다.
- baseline vs swarm 비교를 같은 budget에서 수행해야 한다.
- acceptability 판정은 OAS evidence를 소비해 계산하되, 그 판정 로직을 OAS session state 안으로 밀어 넣지 않아야 한다.
- deterministic `contract_verdict`를 first-class artifact로 생성해야 한다.
- `contract_verdict`는 `satisfied | violated | inconclusive` 중 하나여야 하며, evidence gap이 있으면 `inconclusive`를 허용해야 한다.
- `advice`와 `risk_digest`는 별도 surface로 생성해야 하며, verdict보다 authoritative한 것으로 취급하지 않아야 한다.
- operator UI와 downstream policy gate는 verdict와 advice를 명시적으로 구분해야 한다.

MASC MUST NOT:

- inference prompt logic과 provider-specific behavior를 깊게 소유하지 않는다.
- protocol invariant를 ad hoc runtime check로 중복 구현하지 않는다.
- advice output을 근거로 deterministic verdict를 암묵적으로 수정하지 않는다.
- evidence gap을 free-text 해석으로 메워서 `satisfied`를 선언하지 않는다.

### MCP Protocol SDK

MCP SDK는 **what invalid state cannot be expressed** 를 결정한다.

MCP SDK MUST:

- invalid state construction을 가능한 한 type level로 차단해야 한다.
- parse/validation failure를 field-path와 context를 가진 error로 노출해야 한다.
- stable / experimental surface를 구분하고 conformance를 유지해야 한다.
- state machine은 generic protocol semantics에 머물러야 하며, MASC workflow vocabulary를 직접 소유하지 않아야 한다.

MCP SDK MUST NOT:

- workload policy를 결정하지 않는다.
- OAS/MASC domain semantics를 wire layer로 끌고 오지 않는다.

### Boundary Leak Rejection Rules

다음 변경은 boundary leak로 간주하고 reject한다.

- MASC가 provider-specific prompt logic, model fallback order, tool-call formatting을 소유하려는 변경
- OAS가 room/task/governance/session acceptability를 영속 상태로 소유하려는 변경
- MCP SDK가 `coding_task`, `repo_synthesis`, supervisor digest 같은 workload/domain vocabulary를 wire type에 넣으려는 변경
- proof bundle schema에 room-local policy나 UI-specific wording을 직접 박아 넣는 변경
- proof / transcript artifact를 OAS hidden prompt / memory로 직접 주입하는 변경
- stage gate가 OAS 내부의 workflow policy로 고정되는 변경

### Boundary Note: Transcript Artifacts

proof bundle, transcript, intervention artifact는 harness / eval surface다.
이 artifact를 OAS hidden prompt / memory로 직접 주입하는 것은 1차 PoC 범위 밖이며 boundary leak로 간주한다.

### Policy Versioning Rule

policy update는 mutable singleton을 직접 덮어쓰지 않는다.

- policy는 immutable snapshot + monotonic version으로 다룬다.
- stale version update는 reject한다.
- version conflict는 fail-closed 한다.
- MASC는 어떤 policy version으로 평가했는지 artifact에 남겨야 한다.

## 6. First-Wave PoC Scope

이 RFC는 1차 PoC를 세 개만 다룬다.

### PoC Dependency Rule

세 PoC는 병렬 독립 과제가 아니다.

- PoC-1 `OAS Execution Mode + Risk Contract`가 선행한다.
- PoC-2 `MASC Risk-Aware Supervisor Digest + Stage Gate`는 PoC-1의 proof bundle을 읽는 후속 단계다.
- PoC-3 `MCP SDK Typed State Machine + Rich Validation Errors`는 앞선 두 단계의 실험 결과를 반영하는 substrate follow-up이다.

문서 PR은 세 PoC를 함께 다루지만, 구현은 이 순서를 따른다.

### PoC-1. OAS Execution Mode + Risk Contract

#### Summary

OAS run에 `Diagnose | Draft | Execute` 모드와 risk contract를 추가한다.

#### Minimal Contract

```json
{
  "runtime_constraints": {
    "requested_execution_mode": "draft",
    "risk_class": "medium",
    "allowed_mutations": ["workspace_only"],
    "review_requirement": "human_if_execute"
  },
  "eval_criteria": {
    "success_criteria": ["tests pass", "no unsupported claims in summary"],
    "required_evidence": ["tool_trace", "checkpoint"]
  }
}
```

#### PoC-1 Eval Narrowing Rule

PoC-1 deterministic kernel은 `runtime_constraints`와 proof completeness를 우선 평가한다.

- opaque `eval_criteria`를 억지로 deterministic verdict에 넣지 않는다.
- typed subset이 없는 `eval_criteria`는 `not_evaluated` 또는 동등한 completeness gap으로 남긴다.
- PoC-1 priority는 "가짜 pass 제거"와 "deterministic verdict replay"다.
- recommendation 정교화는 PoC-1 primary gate가 아니다.
- 즉 PoC-1 kernel은 **full contract satisfaction engine**이 아니라, typed `runtime_constraints`와 proof completeness에 대한 **scoped post-hoc audit of runtime enforcement**로 시작한다.

#### Phase-1 Active Checks

PoC-1 v1 evidence에서 active한 deterministic check는 의도적으로 더 작다.

- `runtime.requested_execution_mode`
  - propagation / integrity only
- `runtime.risk_class`
  - propagation / integrity only
- `proof.contract_snapshot`
  - contract snapshot integrity only
- `proof.required_artifact`
  - availability / parseability only

PoC-1 v1 evidence에서 `Unsupported_in_v1`로 취급하는 check:

- `runtime.allowed_mutations`
- `runtime.review_requirement`

이 둘은 contract에는 존재하지만, current proof bundle v1과 evidence v1만으로는 일반형 deterministic replay를 제공하지 못한다.
따라서 phase-1 verdict에서 억지로 판정하지 않고 `unsupported_in_v1`로 남긴다.

#### Phase-1 Friction Scope

PoC-1 pre-production에서 `friction_projection`의 supported window는 `Single_run`만이다.

- `Last_n_runs`
- `Session`
- `Rolling_seconds`

는 cross-run enumeration, ordering, retention, aggregation error policy가 닫힌 뒤에만 활성화한다.
즉 cross-run friction은 architecture intent이고, PoC-1 ship target은 아니다.

#### Execution Mode Authority

`execution_mode`는 단순 config가 아니라 권한이 분리된 decision surface다.

- caller 또는 MASC는 `requested_execution_mode`를 contract로 제안할 수 있다.
- OAS는 capability snapshot, runtime constraints, risk class를 바탕으로 `effective_execution_mode`를 계산한다.
- OAS는 요청된 mode를 **downgrade만** 할 수 있고, 상향 조정하지 않는다.
- proof bundle에는 `requested_execution_mode`, `effective_execution_mode`, `mode_decision_source`를 남긴다.
- MASC는 OAS 내부 상태를 직접 바꾸지 않고, 다음 run에서 새 contract를 발행하는 방식으로만 mode에 영향 준다.

#### Intra-Run Verification and Hooks

PoC-1은 cross-run eval보다 앞서, run 내부의 deterministic verify를 먼저 강화한다.

- pre-tool hook: mutation scope, protected path, required precondition 검사
- post-tool hook: expected artifact 생성 여부, live context refresh, deterministic sanity check
- pre-exit hook: declared verification command 실행 여부와 exit status 확인
- proof capture middleware: tool trace, raw log, checkpoint ref를 자동 수집

여기서 hook는 runtime-local enforcement와 context injection만 담당한다.
acceptability 판정, risk digest 계산, policy update는 hook의 책임이 아니다.

#### Compatibility Policy

- execution contract와 proof bundle schema는 explicit version을 가져야 한다.
- unknown field 정책은 `ignore unless marked required`로 시작한다.
- 초기 rollout은 dual-read를 기본으로 하고, dual-write는 필요할 때만 명시적으로 켠다.
- unsupported capability는 silent downgrade가 아니라 `explicit degraded mode` 또는 `reject`로 처리한다.
- compile-time-only state와 wire-level state는 분리해 기록한다.

#### Working Risk Taxonomy

초기 PoC에서는 `risk_class`를 단일 라벨이 아니라 아래 세 축의 보수적 요약으로 본다.

- `blast_radius`: 변경 영향 범위
- `irreversibility`: 잘못 실행했을 때 되돌리기 어려운 정도
- `recovery_cost`: 실패 후 복구에 드는 비용

초기 working class는 다음처럼 둔다.

- `low`: blast radius 작고, 되돌리기 쉽고, recovery cost 낮음
- `medium`: 셋 중 하나 이상이 애매하거나 중간 수준
- `high`: 셋 중 하나라도 크고, 사람 review 없이는 execute 금지
- `critical`: 되돌리기 어렵거나 외부 시스템 피해 가능성이 있어 기본 동작은 `reject`

capability snapshot, contract, runtime state가 충돌할 때의 기본 규칙은 다음과 같다.

- `low/medium`: `degrade` 우선, 필요 시 `reject`
- `high`: `draft` 또는 `reject`
- `critical`: `reject`

이 taxonomy는 PoC 동안 고정하고, 이후 별도 revision으로만 바꾼다.

#### Why OAS

- tool permission
- guardrails
- capability-aware routing
- per-run hooks

이 네 가지를 OAS가 가장 가까이 소유한다.

여기서 autonomy는 공격적으로 올리는 것이 아니라, **불확실한 capability를 전제로 보수적으로 admission control** 하는 의미로 쓴다.

### PoC-2. MASC Risk-Aware Supervisor Digest + coding_task Stage Gate

#### Summary

Supervisor digest에 다음 필드를 추가한다.

- `ambiguity`
- `evidence_gap`
- `drift_risk`
- `unsafe_edit_risk`

그리고 `coding_task`의 canonical graph:

```text
decompose -> inspect -> implement -> verify -> review
```

를 soft gate에서 `structural checkpoint + hard gate` 조합으로 올린다.

#### First-Wave Computation Posture

PoC-2는 `LLM-as-judge everywhere`로 시작하지 않는다. 1차는 structural signal 우선이다.

- `evidence_gap`: **structural only**
  - `required_evidence`와 proof bundle ref 존재 여부 비교
- `drift_risk`: **structural/historical only**
  - provider snapshot, policy version, model route, prompt template hash, harness cohort drift 탐지
- `unsafe_edit_risk`: **structural only**
  - protected path touch, mutation scope 위반, verify artifact 부재, test delta 부재
- `ambiguity`: **advisory-only hybrid**
  - 1차에서는 gate source가 아니라 operator-facing hint로만 기록
  - LLM judge는 이후 ablation으로 추가할 수 있지만, 초기 승격 기준은 structural signal에 의존한다

PoC-2 mapping rule:

- `evidence_gap` is a digest projection over `contract_verdict.completeness_gaps`
- `unsafe_edit_risk` is a digest projection over deterministic findings plus friction projections related to mutation scope, verification absence, protected-surface contact, or repeated blocked attempts
- `drift_risk` remains an advisory structural/historical digest, not a verdict field
- `ambiguity` remains advice territory and must not be promoted into contract truth in PoC-1

Operational guidance:

- `contract_verdict` remains the authoritative audit/gate artifact
- operator-facing default surfaces may prioritize `friction_projection` views over raw verdict repetition
- the canonical definition of `friction_projection` belongs in the contract-kernel split design doc, not in this RFC

즉 1차 PoC에서 gate를 닫는 근거는 deterministic structural signal이어야 하고, LLM judge는 설명 보조 또는 후속 실험에 머문다.
여기서 structural signal은 pure in-memory check만 뜻하지 않는다. artifact 존재 확인, dereference, minimal schema validation 같은 **minimal I/O**와 repo-local deterministic heuristic을 포함할 수 있다.

#### Stage Gate Semantics

모든 전이를 `measurable`이라고 부르지 않는다. 1차 분류는 다음과 같다.

- `decompose -> inspect`: structural checkpoint
  - task statement, contract, intended read scope artifact 존재
- `inspect -> implement`: structural checkpoint
  - inspected file manifest, intended edit scope, protected-path check 완료
- `implement -> verify`: structural checkpoint
  - diff artifact, changed file manifest, declared verification plan 존재
- `verify -> review`: hard gate
  - verification artifact 존재 + declared verification command exit status pass
  - known-flaky suite는 explicit allowlist 또는 annotated partial-pass artifact가 있을 때만 예외적으로 통과할 수 있다
  - allowlist 없이 non-zero exit를 무시하는 것은 금지한다
- `review`: operator or policy review surface
  - 1차에서는 accept/reject hard gate가 아니라 annotated decision surface로 둔다

#### Fresh-Context Adversarial Eval

1차 primary gate는 full-context structural eval이지만, 후속 ablation으로 fresh-context adversarial eval profile을 둘 수 있다.

- 입력은 diff, 현재 changed file state, type signature, interface contract 같은 structural surface로 제한한다.
- README, design docs, room/task history, governance history는 주지 않는다.
- 이 profile은 Layer 3 adversarial review처럼 domain-aware reviewer가 놓치는 structural defect를 찾기 위한 별도 MASC evaluator다.
- 1차에서는 advisory / comparison 용도이며, canonical acceptability gate로 승격하지 않는다.

#### Why MASC

- run 간 비교
- operator intervention
- session/operation proof aggregation
- benchmark harness ownership

이 네 가지는 MASC 책임이다.

### PoC-3. MCP SDK Typed State Machine + Rich Validation Errors

#### Summary

다음 상태를 phantom type / GADT 후보로 끌어올린다.

- terminal vs non-terminal task state
- preview vs confirmed action state
- version-gated capability surface

동시에 validation error에 다음을 추가한다.

- field path
- expected vs actual
- protocol version hint

#### Why SDK

이건 pure protocol ergonomics와 wire invariant 문제다.

#### Wire-Level Note

GADT / phantom type은 compile-time state를 강하게 만들 수 있지만 wire는 별도다.
1차 설계는 **typed wrapper + explicit wire enum** 분리를 기본으로 둔다.

```ocaml
type preview
type confirmed

type _ action_state =
  | Preview : preview action_state
  | Confirmed : confirmed action_state

type packed_action_state = Pack : _ action_state -> packed_action_state

let action_state_to_wire : type a. a action_state -> string = function
  | Preview -> "preview"
  | Confirmed -> "confirmed"

let action_state_of_wire = function
  | "preview" -> Ok (Pack Preview)
  | "confirmed" -> Ok (Pack Confirmed)
  | other -> Error ("unknown action_state: " ^ other)
```

즉 wire compatibility는 string/JSON enum으로 유지하고, typed state는 SDK 내부 API 안전성에 사용한다.

## 7. Harness Changes

하네스는 결과 수집기가 아니라 루프의 일부가 되어야 한다.

### New Recorded Artifacts

- input contract
- OAS proof bundle
- replayable tool-call transcript
- evaluator result
- intervention summary
- final acceptance verdict

### Proof Bundle Minimal Schema

proof bundle은 최소한 다음 필드를 가져야 한다.

- `schema_version`
- `run_id`
- `contract_id`
- `requested_execution_mode`
- `effective_execution_mode`
- `mode_decision_source`
- `risk_class`
- `provider_snapshot`
- `capability_snapshot`
- `tool_trace_refs`
- `raw_evidence_refs`
- `checkpoint_ref`
- `result_status`
- `started_at`
- `ended_at`

`contract_id`는 full input contract artifact를 가리키는 **immutable snapshot ID**다.
1차 PoC에서는 mutable logical name이 아니라 content-addressed hash 또는 동등한 immutable snapshot ID를 권장한다.
이 snapshot에는 `runtime_constraints`와 `eval_criteria`가 함께 포함되어야 하며, MASC는 항상 이 snapshot 기준으로 평가한다.
`result_status`의 allowed values는 `completed | errored | timed_out | cancelled`다.
이 필드는 **실행 종료 상태만** 기록하며, 품질 판정(`pass` / `fail` / `acceptable`)은 포함하지 않는다.
hook / policy gate가 run continuation을 **의도적으로 차단**한 경우는 `cancelled`로 기록한다.
hook 자체의 예외, verifier crash, unexpected runtime failure는 `errored`로 기록한다.

Important limitation:

- proof bundle v1 top-level manifest는 `allowed_mutations`와 `review_requirement`를 직접 노출하지 않는다.
- 따라서 해당 check의 deterministic replay는 joined contract snapshot and/or future evidence v2에 의존한다.
- 어떤 check가 v1에서 truly active한지는 `check-evaluation-spec.md`와 `proof-bundle-check-mapping.md`가 우선한다.

### Artifact Lifecycle

artifact는 ownership과 lifecycle이 분명해야 한다.

- OAS는 raw execution evidence artifact를 생성한다.
- OAS는 run 시작 시점에 exact full input contract snapshot도 artifact로 영속화한다.
- MASC는 `contract_verdict` artifact를 생성한다.
- MASC는 typed `friction_projection` artifact를 생성하거나 집계한다.
- MASC는 필요하면 별도 `advice` / `operator_narrative` / `intervention_summary` artifact를 생성한다.
- 1차 PoC에서 proof bundle은 self-contained document가 아니라 **manifest**다.
- proof bundle과 transcript capture는 OAS hook / middleware가 자동으로 수행한다.
- artifact는 stable ID, producer, schema version, created_at을 가져야 한다.
- artifact는 owner를 가져야 한다.
- input contract artifact와 proof bundle은 같은 declared artifact store namespace 안에서 join 가능해야 한다.
- OAS는 full contract JSON을 받아 runtime_constraints를 집행하고, 그 exact snapshot의 `contract_id`만 proof bundle로 운반한다.
- ref는 declared artifact store namespace 안에서만 해석한다.
- ref dereference 실패는 evaluator error가 아니라 `evidence_gap`으로 기록한다.
- evidence gap은 deterministic verdict surface에서 명시적으로 보이게 해야 하며, free-text advice로만 숨기면 안 된다.
- `friction_projection` artifact는 declared window, based-on runs, and aggregation basis를 가져야 한다.
- `advice` artifact는 `based_on_judgment_hash`, `based_on_friction_window`, `generator`, `generated_at`, `authority_level = non_authoritative`를 가져야 한다.
- future gate-authoritative promotion must create a new artifact kind rather than flipping the authority of `advice`.
- 승격 후보 artifact는 minimum retention window를 가져야 하며, 1차 PoC 기본값은 experiment closeout 또는 30일 중 더 긴 쪽으로 둔다.
- 대용량 trace는 chunked artifact로 저장하고, proof bundle은 summary + refs만 가진다.
- retention, max size, truncation policy를 문서화해야 한다.
- redaction policy, access control, data classification도 함께 문서화해야 한다.

### Cross-Repo Schema Sharing

1차 PoC에서 OAS와 MASC 사이의 shared surface는 **공유 OCaml 라이브러리**가 아니라 **versioned JSON schema + conformance fixtures**로 둔다.

- OAS는 producer이므로 execution contract / proof bundle schema의 canonical JSON shape를 소유한다.
- MASC는 동일 schema를 소비하고, fixture-based decoder/conformance test로 호환성을 검증한다.
- shared opam package는 schema가 안정화된 뒤에만 고려한다.
- OAS는 keeper, room, governance, board 같은 MASC domain semantics를 알 필요가 없다.
- MASC는 OAS runtime internals를 직접 읽거나 수정하지 않고, versioned contract / proof / evidence artifacts만 소비한다.

이 선택은 초기 실험 단계에서 repo release cadence를 느슨하게 유지하고, boundary를 schema와 artifact 수준에서 고정하기 위한 것이다.

### Required Comparison Mode

모든 1차 PoC는 최소한 다음 비교를 제공해야 한다.

- same model
- same time budget
- same tool budget
- same repo snapshot
- same harness seed / fixture set
- same provider capability snapshot
- baseline vs supervised / gated path

`baseline`과 `candidate`의 차이는 PoC에서 제안한 control surface만으로 제한한다.

### Experiment Lock

실험은 다음이 잠기지 않으면 시작하지 않는다.

- task cohort
- run count
- seed sweep policy
- failure-case stratification rule
- judging protocol version
- adopt threshold

### Ablation Matrix

가능한 경우 최소한 다음 비교를 남긴다.

- baseline only
- OAS only
- OAS + MASC
- OAS + MASC + MCP SDK follow-up

### Initial Workloads

우선순위는 다음 순서로 둔다.

1. `coding_task`
2. `repo_synthesis`
3. `research_pipeline`

## 8. Success Metrics

### Shared Metrics

- `evidence_precision`
- `claim_coverage`
- `unsupported_claim_penalty`
- `latency_ms`
- `cost`
- `human_intervention_count`
- `human_review_minutes`
- `false_positive_risk_flag_rate`
- `false_negative_escape_rate`

이 지표는 사전에 고정된 labeling / judging protocol 없이 사용하지 않는다.
1차 PoC에서 `evidence_precision`의 canonical reported value는 labeling protocol의 `precision_strict`다.
`evidence_precision`은 evidence 충족도를 측정하는 integrity metric이지 outcome correctness의 직접 측정값은 아니다. outcome quality는 `defect_escape_rate`와 workload별 success signal을 함께 봐야 한다.
`claim_coverage`는 material output claim 중 explicit label(`supported` / `unsupported` / unresolved `ambiguous`)이 붙은 claim의 비율이다.
즉 `claim_coverage = labeled_material_claims / total_material_claims`로 둔다.
`claim_coverage`의 canonical measurement source는 labeling protocol이며, `drift` 제외 같은 예외 규칙도 그 문서를 따른다.
1차 PoC에서는 `human_intervention_count`를 supervision cost proxy로 사용하고, 더 좋은 proxy 탐색은 후속 과제로 둔다.
`claim_coverage`와 `evidence_precision`만으로는 laconic output을 과보상할 수 있으므로, material claim volume collapse나 지나치게 보수적인 output은 workload success signal 또는 defect escape signal과 함께 읽어야 한다.

### Labeling and Judging Protocol

프로토콜은 최소한 다음을 포함해야 한다.

- positive / negative class 정의
- 경계 사례 adjudication rule
- conflict resolution rule
- golden set
- evaluator drift re-check cadence
- backtesting trigger

세부 운영 규칙은 별도 문서 [contract-driven-agent-loop-labeling-protocol.md](./contract-driven-agent-loop-labeling-protocol.md)에서 정의한다.

### OAS Metrics

- tool misuse rate
- fallback frequency
- retry count
- provider mismatch reduction
- proof bundle completeness
- hook gate block count
- pre-exit verification pass rate

### MASC Metrics

- intervention precision / recall
- time-to-detect drift
- defect escape rate
- rework rate
- post-merge regression rate

### MCP SDK Metrics

- compile-time caught invalid state count
- runtime invalid state bug reduction
- conformance pass rate
- integration debugging time

### Adoption Gates

PoC 승격은 다음 조건을 모두 만족할 때만 고려한다.

- baseline 대비 핵심 품질 지표가 개선되거나 최소 유지
- `latency_ms`와 `cost` 증가가 사전 합의된 budget 안에 있음
- `false_positive_risk_flag_rate`와 `false_negative_escape_rate`가 측정됨
- backward compatibility plan이 문서화됨
- rollback path가 실제로 검증됨
- 최소 효과 크기 또는 사전 등록된 합격선이 있다
- claim volume collapse 없이 workload success signal이 유지되거나 개선된다

초기 placeholder 합격선 예시는 다음처럼 둔다.

- `unsupported_claim_penalty` baseline 대비 악화 금지
- `evidence_precision` baseline 대비 유지 이상
- `latency_ms` p95 증가는 15% 이내
- `cost` 증가는 20% 이내

placeholder gate는 1차 PoC의 default다. 한 budget 축이 초과되더라도 품질 개선 폭이 크면 operator override with recorded rationale로 `defer for follow-up` 또는 controlled continuation을 선택할 수 있다.

## 9. Rollout Plan

### 0-30 Days

- labeling / judging protocol v0을 고정하고 artifact version을 기록한다.
- baseline measurement lock을 고정한다.
- 현재 시스템 output 10개를 proof bundle 없이 수동 라벨링해 baseline을 만든다. 이 수동 라벨링 시간은 baseline `human_review_minutes`에 포함한다.
- OAS 최소 `Execution Mode + Risk Contract`와 proof bundle skeleton을 추가한다.
- baseline proof bundle / transcript 10개를 직접 읽고 failure taxonomy seed를 수동으로 도출한다.
- OAS PoC-1만 구현한다.

### 31-60 Days

- MASC digest field 초안과 stage gate를 추가한다.
- same workload에서 `OAS only` vs `OAS + MASC` ablation 수행
- failure taxonomy 수집
  - `unsupported_claim`
  - `drift`
  - `tool_misuse`
  - `invalid_state`
- PoC-1과 PoC-2의 결과를 비교한다.

### 61-90 Days

- MCP SDK typed state candidate와 validation error format 초안 작성
- MCP SDK conformance + fuzz/property test 초안 추가
- OAS + MASC + MCP SDK follow-up ablation을 수행한다.
- PoC 결과를 baseline과 비교
- 수치로 개선되면 canonical path candidate로 승격
- 개선되지 않으면 rollback
- `adopt / defer / drop` 결정 기록

각 PoC는 실험 시작 전에 `adopt` 기준 수치를 명시해야 한다.

### Promotion Rule

다음 중 하나라도 만족하지 못하면 canonical 승격 금지다.

- baseline lock이 없었다
- false positive / false negative 측정이 빠졌다
- rollback rehearsal을 하지 않았다
- boundary leak reject 항목이 하나라도 발견되었다
- artifact만 있고 재현 가능한 harness가 없다

## 10. Risks and Rollback

### Risks

- gate bureaucracy가 생겨 latency만 늘어날 수 있다.
- proof bundle이 과도하게 verbose해질 수 있다.
- risk digest false positive가 operator 신뢰를 깎을 수 있다.
- typed state API가 초기 통합 비용을 올릴 수 있다.
- baseline drift 때문에 PoC가 좋아 보이는 착시가 생길 수 있다.
- review time 증가를 품질 향상으로 착각할 수 있다.
- async eval과 policy update 사이의 propagation latency 때문에 같은 실패가 여러 run에서 반복될 수 있다.
- proof / transcript artifact가 민감 정보나 내부 경로를 포함할 수 있어 redaction / access control이 부실하면 운영 리스크가 커진다.

### Rollback

- OAS execution mode는 feature flag 뒤에 둔다.
- MASC risk digest는 additive read surface로 시작한다.
- MCP typed state는 experimental namespace 또는 module alias 뒤에 둔다.
- adoption threshold 미달, latency overhead 과다, false positive 과다 시 즉시 이전 surface로 되돌린다.

이 RFC는 canonical path를 바로 바꾸지 않는다. 먼저 계측하고, 그 다음 승격한다.

## 11. Open Questions

- proof bundle의 canonical schema는 어디까지 노출할 것인가?
- raw chain-of-thought를 직접 다룰 것인가, 아니면 trace summary만 표준화할 것인가?
- 어떤 `risk_class` taxonomy가 실제 intervention 품질과 가장 잘 맞는가?
- provider capability가 낮을 때 autonomy를 어디까지 강등할 것인가?
- `coding_task` 외 workload에도 동일한 stage gate 개념을 적용할 것인가?
- shared schema가 안정화된 뒤 shared package가 필요한 시점은 언제인가?
- `human_intervention_count`보다 더 좋은 supervision cost proxy는 무엇인가?
- LLM judge ablation을 도입한다면 raw evidence를 어떤 in-distribution surface(diff, logs, test output)로 변환할 것인가?

## 12. Decision Summary

이 RFC는 다음을 제안한다.

1. OAS는 per-run execution contract를 집행한다.
2. MASC는 run acceptability와 cross-run supervision을 판단한다.
3. MCP SDK는 invalid state를 더 적게 표현 가능하게 만든다.
4. 하네스는 output collector가 아니라 `contract -> proof -> eval` 루프의 일부가 된다.
5. PoC는 철학이 아니라 baseline 대비 수치 개선으로만 승격된다.

### Evidence Tiers

| Decision | Tier |
|---|---|
| OAS는 per-run execution contract를 집행한다 | Architecture choice |
| MASC는 run acceptability와 cross-run supervision을 판단한다 | Architecture choice |
| MCP SDK는 invalid state를 더 적게 표현 가능하게 만든다 | Architecture choice |
| contract / proof / eval 분리와 background eval pipeline | Paper-informed inference |
| execution-based harness와 tool-use conformance를 중시하는 평가 방식 | Direct paper support |
| strict precision, golden set, backtesting, adoption gate | Paper-informed inference |

## 13. Evidence Posture

이 문서의 근거 강도는 세 층으로 구분한다.

- **Direct paper support**: execution-based harness, tool-use evaluation, process supervision, scalable oversight처럼 논문이나 공식 리포트가 직접 필요성을 뒷받침하는 부분
- **Paper-informed inference**: capability-aware autonomy, proof bundle, benchmark lock처럼 연구가 방향은 지지하지만 정확한 구현 형태는 우리가 설계로 선택하는 부분
- **Architecture choice**: OAS / MASC / MCP SDK 경계 분리, typed state API shape처럼 연구가 직접 답을 주지 않고 우리가 유지보수성과 경계 보존을 위해 선택하는 부분

이 RFC는 연구를 `직접 증명`으로 사용하지 않는다. 연구는 필요성을 보여주고, 구체 구조는 아키텍처 선택으로 명시한다.

| Decision | Evidence tier | Validated by |
|---|---|---|
| OAS는 per-run execution contract를 집행한다 | Architecture choice | PoC-1 |
| MASC는 run acceptability와 cross-run supervision을 판단한다 | Architecture choice | PoC-2 |
| MCP SDK는 invalid state를 더 적게 표현 가능하게 만든다 | Architecture choice | PoC-3 |
| execution-based harness가 필요하다 | Direct paper support | Harness baseline lock |
| proof / eval를 분리하고 fail-closed로 운영한다 | Paper-informed inference | PoC-1 + PoC-2 |
| PoC는 baseline lock과 sequential rollout으로 간다 | Architecture choice | Rollout plan + ablation |

## Appendix A. Research Basis

### 2025-2026 Update

- `Why SWE-bench Verified no longer measures frontier coding capabilities`
  - https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/
- `Introducing the SWE-Lancer benchmark`
  - https://openai.com/index/swe-lancer/
- `The Berkeley Function Calling Leaderboard (BFCL): From Tool Use to Agentic Evaluation of Large Language Models`
  - https://proceedings.mlr.press/v267/patil25a.html
- `Multi-turn Function-calling via Graph-based Execution and Translation`
  - https://research.google/pubs/multi-turn-function-calling-via-graph-based-execution-and-translation/
- `TRACT: Regression-Aware Fine-tuning Meets Chain-of-Thought Reasoning for LLM-as-a-Judge`
  - https://research.google/pubs/tract-regression-aware-fine-tuning-meets-chain-of-thought-reasoning-for-llm-as-a-judge/
- `Towards a science of scaling agent systems: When and why agent systems work`
  - https://research.google/blog/towards-a-science-of-scaling-agent-systems-when-and-why-agent-systems-work/

### Planning / Deliberation

- `PlanBench: An Extensible Benchmark for Evaluating Large Language Models on Planning and Reasoning about Change`
  - https://arxiv.org/abs/2206.10498
- `Tree of Thoughts: Deliberate Problem Solving with Large Language Models`
  - https://arxiv.org/abs/2305.10601
- `Devil's Advocate: Anticipatory Reflection for LLM Agents`
  - https://arxiv.org/abs/2405.16334

### Tool Use / Software Engineering

- `Toolformer: Language Models Can Teach Themselves to Use Tools`
  - https://arxiv.org/abs/2302.04761
- `SWE-bench: Can Language Models Resolve Real-World GitHub Issues?`
  - https://arxiv.org/abs/2310.06770
- `SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering`
  - https://arxiv.org/abs/2405.15793
- `SWE-Lancer: Can Frontier LLMs Earn $1 Million from Real-World Freelance Software Engineering`
  - https://arxiv.org/abs/2502.12115
- `DevEval: A Manually-Annotated Code Generation Benchmark Aligned with Real-World Code Repositories`
  - https://arxiv.org/abs/2403.08604
- `SkillsBench: Benchmarking How Well Agent Skills Work Across Diverse Tasks`
  - https://arxiv.org/abs/2602.12670

### Evaluation / Oversight / Reflection

- `Reflexion: Language Agents with Verbal Reinforcement Learning`
  - https://arxiv.org/abs/2303.11366
- `Autonomous Evaluation and Refinement of Digital Agents`
  - https://openreview.net/forum?id=Y9uGznsgIU
- `Improving mathematical reasoning with process supervision`
  - https://openai.com/index/improving-mathematical-reasoning-with-process-supervision/
- `On scalable oversight with weak LLMs judging strong LLMs`
  - https://arxiv.org/abs/2407.04622
- `Detecting misbehavior in frontier reasoning models`
  - https://openai.com/index/chain-of-thought-monitoring/
- `A Benchmark for Evaluating Outcome-Driven Constraint Violations in Autonomous AI Agents`
  - https://arxiv.org/abs/2512.20798

### Benchmarks / Harness / Conformance

- `AgentBench`
  - https://arxiv.org/abs/2308.03688
- `AgentBoard`
  - https://arxiv.org/abs/2401.13178
- `WebArena`
  - https://arxiv.org/abs/2307.13854
- `GAIA`
  - https://arxiv.org/abs/2311.12983
- `OSWorld`
  - https://arxiv.org/abs/2404.07972
- `AndroidWorld`
  - https://arxiv.org/abs/2405.14573
- `Berkeley Function Calling Leaderboard`
  - https://gorilla.cs.berkeley.edu/leaderboard

### Search / Self-Improvement

- `Voyager: An Open-Ended Embodied Agent with Large Language Models`
  - https://arxiv.org/abs/2305.16291
- `Competition-Level Code Generation with AlphaCode`
  - https://arxiv.org/abs/2203.07814
- `Self-Play Fine-Tuning Converts Weak Language Models to Strong Language Models`
  - https://arxiv.org/abs/2401.01335
- `Trial and Error: Exploration-Based Trajectory Optimization for LLM Agents`
  - https://arxiv.org/abs/2403.02502
