---
status: reference
last_verified: 2026-04-17
code_refs:
  - lib/cdal/
  - lib/keeper/keeper_cdal_contract.ml
  - lib/keeper/keeper_accountability.ml
---

# CDAL Contract Kernel and Advisory Split

**Status**: Draft, design-ready
**Date**: 2026-03-28
**Scope**: MASC evaluator surface, OAS proof surface, cross-repo boundary
**One sentence**: Make contract judgment deterministic and replayable; keep recommendation, explanation, and exploration explicitly nondeterministic.

## Related Documents

- `./contract-driven-agent-loop-rfc.md`
- `./check-evaluation-spec.md`
- `./proof-bundle-check-mapping.md`
- `./cross-run-loader-and-window-spec.md`
- `./error-handling-and-operations-spec.md`
- `./mode-violations-evidence-v1.schema.json`
- `./CDAL-PHASE1A-TEAM-START-HERE.md`
- `./contract-driven-agent-loop-rfc-review.md`
- `./oas-masc-state-boundary.md`
- `../../../oas/docs/schemas/cdal-proof-bundle-v1.json`
- `../../../oas/CDAL-ENHANCEMENT-ANALYSIS.md`

## 1. Problem Statement

Current CDAL evaluation in MASC is not a contract checker. It is a metadata check with recommendation-like strings attached.

Today:

- `cdal_eval.ml` counts artifact refs by substring instead of reading proof content.
- keeper metrics treat `raw_evidence_refs` length as a violation count.
- OAS performs runtime enforcement, but proof artifacts do not yet preserve enough typed facts for deterministic replay of every contract-relevant conclusion.
- verdict and advice are mixed into one surface.

The goal is not "make the whole evaluator deterministic."
The goal is:

- deterministic for contract semantics and contract satisfaction
- nondeterministic for advice, prioritization, explanation, and repair exploration

## 2. Design Principle

### 2.1 Deterministic Inside the Contract Boundary

The following must be deterministic:

- which contract-bound checks apply
- whether those checks are satisfied, violated, or impossible to decide
- which evidence witnesses support that conclusion
- whether evidence is complete enough to decide the scoped proposition
- replayability for the same proof bundle, contract snapshot, and loader semantics

This is the **contract kernel**.

### 2.2 Nondeterministic Outside the Contract Boundary

The following may vary:

- repair suggestions
- prioritization of repair options
- natural-language summaries
- debugging narratives
- operational recommendations
- clustering and interpretation over traces or token usage

This is the **advisory layer**.

The advisory layer may use LLMs, heuristics, ranking, or human input.

### 2.3 Non-Deterministic Autonomy as Default

Agent systems are fundamentally non-deterministic. The LLM decides what to do, which tools to call, and how to interpret results. This non-deterministic autonomy is the default operating mode.

The deterministic contract kernel is a thin guardrail on that autonomy, not the primary driver of behavior. If the guardrail determines what the agent does rather than what it must not do, the system has inverted its priorities.

Implications:

- the advice surface is not an optional addon to the verdict surface; it is an essential observation plane of agent autonomy
- a system that produces only verdicts and no advisory/friction output is operationally incomplete, even if technically correct
- the verdict answers "did the guardrail hold?"; the friction and advice surfaces answer "what is the agent actually doing and why?"

### 2.4 Three-Repo Independence

The dependency direction is strictly unidirectional:

```text
MCP Protocol SDK  <--  OAS (Agent SDK)  <--  MASC (Coordinator)
     (wire)              (execution)           (supervision)
```

- MCP SDK does not know OAS or MASC exist. It owns wire protocol semantics only.
- OAS does not know MASC exists. It is a general-purpose agent execution SDK. Any coordinator can consume its proof bundles.
- MASC depends on OAS (via opam `agent_sdk`) and MCP SDK (via `mcp_protocol`). It is the consumer, not the definition authority for execution or protocol semantics.

Module ownership:

- `Cdal_loader`, `Cdal_judge`, `Cdal_friction`, `Cdal_advice` belong to MASC.
- `Proof_store`, `Proof_capture`, `Mode_enforcer`, `Contract_runner` belong to OAS.
- Wire types and transport belong to MCP Protocol SDK.

Anti-patterns:

- OAS code referencing MASC domain concepts (keeper, room, supervisor, friction, verdict)
- MASC hardcoding OAS internal storage layout without an adapter interface
- MCP SDK embedding workload or domain semantics into wire types
- string substring/suffix matching to classify proof artifacts (use typed artifact kinds or structured ref parsing)
It must not change the contract verdict.

## 3. Current Gaps

### 3.1 MASC Uses Metadata Counts Instead of Proof Content

Current MASC evaluation counts `mode_violations` refs by string matching and never dereferences artifacts.

Immediate consequence:

- the result is not a proof-content judgment
- the same pattern is repeated in keeper metrics

### 3.2 Violation Evidence Loses Contract-Relevant Semantics

Current OAS violation records keep:

- `tool_name`
- `input_summary`
- `effective_mode`
- `violation_kind`

This is not enough for deterministic replay of all contract-relevant conclusions.

Known limitation:

- `mutating_in_diagnose` conflates workspace mutation and external effect
- `bash` classification depends on full tool input, but proof keeps only truncated input summary
- violation records do not carry a stable trace join key

Any kernel that reconstructs missing facts from traces by filename, timestamp proximity, or tool name would reintroduce heuristics.

### 3.3 `eval_criteria` Is Opaque

`Risk_contract.eval_criteria` is currently `Yojson.Safe.t`.

That is acceptable for transport.
It is not acceptable as part of a deterministic contract kernel unless the participating subset is typed and fail-closed.

### 3.4 Proof Integrity and Loading Are Weak

`proof-store://` is currently a write-side naming convention, not a full read-side public API.

Current gaps:

- no public dereference surface
- no typed artifact readers
- no artifact digest in the manifest
- no strict fail-closed handling for unsupported schema versions

## 4. Proposed Architecture

```text
Deterministic lane
contract snapshot
  + typed contract-relevant facts
  + loader semantics
  -> contract_verdict
  -> friction_projection

Explanatory lane
contract_verdict
  + friction_projection
  + tool traces
  + outputs
  + token usage
  + broader context
  -> advice / recommendation / explanation
```

### 4.1 Deterministic Contract Kernel

The deterministic kernel has one job:
replay a scoped contract judgment from contract data and normalized contract facts.

Suggested output shape:

```text
type contract_status =
  | Satisfied
  | Violated
  | Inconclusive

type completeness_impact =
  | Blocks_verdict
  | Annotation_only

type contract_finding = {
  check_id : string;
  event_id : string option;
  observed : Yojson.Safe.t;
  expected : Yojson.Safe.t;
  trace_ref : string option;
}

type completeness_gap = {
  artifact : string;
  reason : string;
  impact : completeness_impact;
}

type contract_verdict = {
  run_id : string;
  contract_id : string;
  claim_scope : string;
  judgment_basis_hash : string;
  judgment_hash : string;
  loader_semantics_version : string;
  schema_compat_mode : string;
  status : contract_status;
  findings : contract_finding list;
  completeness_gaps : completeness_gap list;
}
```

Properties:

- pure and replayable
- no LLMs
- no free-text recommendation
- fail-closed when contract-relevant evidence is missing
- absence of evidence is never success

Phase-1 claim scope:

- `claim_scope = phase1_scoped_runtime_audit`
- this is a typed reminder that the verdict is about the active phase-1 check set, not about world-level safety or full contract satisfaction

Hash roles:

- `judgment_basis_hash` identifies the deterministic input basis that was judged
- `judgment_hash` identifies the canonical deterministic verdict artifact that was produced

Phase-1 `judgment_basis_hash` should cover at least:

- contract snapshot identity
- contract-relevant artifact identities or digests
- loader semantics version
- schema compatibility mode

Phase-1 `judgment_hash` should be the hash of the canonical serialized `contract_verdict`, excluding the `judgment_hash` field itself.

### 4.2 Deterministic Friction Projection

`friction_projection` is not `advice`.
It is a typed, non-authoritative observability projection over persisted eval artifacts and a declared window.
Its job is not to explain "why" the system is misaligned.
Its job is to deterministically summarize which blocked-attempt and completeness structures recurred over a declared scope.

Suggested output shape:

```text
type digest_window =
  | Single_run of string
  | Last_n_runs of int
  | Session of string
  | Rolling_seconds of int

type blocked_attempt_key = {
  tool_name : string;
  violation_kind : string option;
  effect_class : string option;
  effective_mode : string;
  required_min_mode : string option;
  violated_rule_id : string option;
}

type evidence_gap_key = {
  artifact : string;
  reason : string;
  impact : completeness_impact;
}

type blocked_attempt_group = {
  key : blocked_attempt_key;
  count : int;
}

type evidence_gap_group = {
  key : evidence_gap_key;
  count : int;
}

type friction_tripwire =
  | Repeated_blocked_attempts of blocked_attempt_key * int
  | Repeated_rule_hits of string * int
  | Repeated_blocking_gaps of evidence_gap_key * int

type friction_projection = {
  window : digest_window;
  based_on_run_ids : string list;
  basis_hash : string;
  tripwire_policy_id : string;
  blocked_attempt_count : int;
  blocked_tool_counts : (string * int) list;
  blocked_effect_class_counts : (string * int) list;
  blocked_attempt_groups : blocked_attempt_group list;
  evidence_gap_groups : evidence_gap_group list;
  review_tripwires : friction_tripwire list;
}
```

Properties:

- deterministic for the same declared window and same underlying persisted artifacts
- non-authoritative
- operator-facing by default
- does not change `contract_verdict`

Blocked attempts belong here by default.
They are deterministic enforcement facts, not necessarily contract breaches.

Phase-1 support boundary:

- v1 proof evidence can deterministically populate `tool_name`, `effective_mode`, and `violation_kind`
- v1 proof evidence does not yet populate `effect_class`, `required_min_mode`, or `violated_rule_id`
- phase-1 implementations must leave unsupported fields as `None`
- no semantic reconstruction from truncated summaries is allowed

Deterministic computation contract:

- input
  - declared `digest_window`
  - phase-1 normalized blocked-attempt rows loaded from persisted proof artifacts
  - phase-1 `completeness_gaps`
  - projection semantics version
  - declared tripwire policy
- output
  - exact counts and exact groupings over those rows
  - no clustering, no similarity search, no free-text summarization
- exclusions
  - "why is this happening?"
  - "should the contract be changed?"
  - "which blocked-attempt groups belong to the same latent pattern?"

In other words:

- `friction_projection` answers "what repeated over the declared window?"
- `advice` answers "what might that mean and what should we do next?"

Suggested normalized source surface:

```text
type friction_source_row = {
  run_id : string;
  blocked_attempt : blocked_attempt_key option;
  completeness_gap : evidence_gap_key option;
}
```

Phase-1 projection rule:

- `blocked_attempt_count` is the count of rows where `blocked_attempt <> None`
- `blocked_tool_counts` is grouped exactly by `blocked_attempt.tool_name`
- `blocked_effect_class_counts` is grouped exactly by `blocked_attempt.effect_class`
- `blocked_attempt_groups` is grouped exactly by full `blocked_attempt_key`
- `evidence_gap_groups` is grouped exactly by full `evidence_gap_key`
- `review_tripwires` is computed deterministically from declared thresholds over those exact grouped counts

`contract-work mismatch` is not itself a deterministic field in phase 1.
It is an advisory interpretation that may be derived later from repeated blocked-attempt groups and contract context.

Tripwire note:

- a `review_tripwire` does not rewrite `contract_verdict`
- it is a deterministic review-escalation signal inside `friction_projection`
- it exists to prevent repeated blocked attempts or repeated blocking gaps from being normalized as harmless background noise

### 4.3 Nondeterministic Advisory Layer

The advisory layer consumes the deterministic verdict and broader evidence.

Suggested output shape:

```text
type advice = {
  based_on_judgment_hash : string;
  based_on_friction_window : string option;
  generator : string;
  generated_at : float;
  authority_level : string;
  mode : string;
  options : Yojson.Safe.t list;
  rationale : string list;
}
```

Properties:

- may use LLMs or heuristics
- may produce multiple repair options
- may be rerun independently
- must not rewrite deterministic findings
- phase-1 advice must be emitted with `authority_level = non_authoritative`

### 4.4 Advice Input Contract

The advice generator implementation may remain open in phase 1.
Its input contract should not remain open.

Minimum advisory input surface:

- `contract_verdict`
- `friction_projection`
- parsed violation records
- tool traces
- token snapshots
- proof manifest

## 5. What Phase 1 Actually Decides

Phase 1 does **not** decide full contract satisfaction.
It decides a narrower proposition:

- whether the typed phase-1 contract surface was respected by the recorded run evidence
- whether the proof is complete enough to trust that scoped answer

In practice, Phase 1 is a post-hoc audit of:

- runtime enforcement outputs
- contract-bound proof completeness

It is valuable even if runtime enforcement exists, because it checks:

- whether the enforcement evidence was actually persisted
- whether the persisted evidence is parsable and internally consistent
- whether downstream consumers are seeing the same scoped result replayably

## 6. Phase-1 Check Registry

Phase 1 does not need a general clause registry.
It needs a small closed set of check IDs.

Suggested phase-1 `check_id` registry:

- `runtime.requested_execution_mode`
- `runtime.risk_class`
- `runtime.allowed_mutations`
- `runtime.review_requirement`
- `proof.contract_snapshot`
- `proof.required_artifact`

This keeps phase 1 concrete and avoids inventing a general clause system too early.

### 6.1 Phase-1 Active Checks in v1

The registry above is broader than the checks that are truly decidable from current proof bundle v1 plus evidence v1.

Active in phase-1 pre-production:

- `runtime.requested_execution_mode`
  - propagation / integrity only
- `runtime.risk_class`
  - propagation / integrity only
- `proof.contract_snapshot`
  - contract snapshot integrity only
- `proof.required_artifact`
  - artifact availability / parseability only

### 6.2 Unsupported in v1

Unsupported in phase-1 pre-production:

- `runtime.allowed_mutations`
- `runtime.review_requirement`

Reason:

- the contract surface contains these fields
- OAS enforces them at run time
- but proof bundle v1 and evidence v1 do not yet preserve enough typed facts to replay them as general deterministic checks

Implementations must not silently treat these checks as satisfied.
They must be marked `Unsupported_in_v1` in evaluation specs and omitted from phase-1 deterministic pass conditions.

## 7. Contract Surface vs Advisory Surface

### 7.1 Contract Surface

Only typed, contract-owned semantics may enter the deterministic kernel.

Full contract surface:

- `requested_execution_mode`
- `risk_class`
- `allowed_mutations`
- `review_requirement`

Phase-1 active deterministic subset:

- `requested_execution_mode`
- `risk_class`

Everything else stays outside the kernel until typed.

In particular:

- opaque `eval_criteria` does not participate in phase-1 verdict calculation
- phase-1 kernels should record this as an annotation-only completeness gap rather than silently skipping it

### 7.2 Advisory Surface

The following stays outside the deterministic kernel:

- token usage interpretation
- trace summarization
- operator-facing narrative
- prompt repair ranking
- alternative repair plans
- "why did the agent choose this?" analysis

The implementation strategy for advice may remain undecided in phase 1.
The input surface for advice should be fixed early even if the generator is not.

Authority rule:

- `advice` is non-authoritative by artifact kind in phase 1
- future promotion of an advisory signal into a gate input should create a new artifact kind, not reuse `advice` with flipped authority
- this keeps the meaning of `advice` stable across versions

## 8. Required Evidence for Deterministic Replay

The kernel should read typed contract-relevant facts, not raw trace blobs.
It must not perform heuristic joins over filenames, timestamps, or tool names.

Minimum additive evidence required for a strong kernel:

- `event_id`
- `trace_id`
- `turn`
- `tool_name`
- `effect_class`
- `effective_mode`
- `decision`
- `violated_rule_id` or `required_min_mode`
- `input_digest`

Required for phase-3 exit criteria:

- `contract_ref`
- artifact digests in manifest
- explicit `schema_version` compatibility gate

Known limitation in schema v1:

- `violation_kind` may still be sufficient for some **mode-only** conclusions
- it is not sufficient for general obligation inference
- phase 1 must not pretend otherwise

Closed-world phase-1 allowance:

- a typed, known `violation_kind` may be mapped to a mode-only requirement when that mapping is lossless
- unknown `violation_kind` values or findings that require richer semantics must produce `Inconclusive`

### 8.1 Evidence Trust Levels

Not all proof evidence has the same trust level.

- **SDK-captured evidence** (higher trust): timing, tool name, input/output interception, mode enforcement decisions. These are captured by OAS hooks at the SDK boundary, not by the agent itself.
- **Agent-reported evidence** (lower trust): tool input content is constructed by the agent. An agent can craft benign-looking inputs with malicious side effects that pass tool classification but produce harmful results.

The kernel must not treat agent-reported content as equivalent to SDK-captured enforcement data. Specifically:

- mode violation records are SDK-captured (the enforcement hook detected the violation) and carry higher trust
- tool output content is SDK-captured (intercepted at post_tool_use) but may still reflect agent-directed harmful actions
- the kernel's verdict is about contract enforcement, not about output quality or intent

Long-term consideration: integrity markers or cryptographic attestation on SDK-captured data (see Proof-of-Guardrail, arXiv:2603.05786).

## 9. `Inconclusive` Rules

The kernel must return `Inconclusive` when:

- contract snapshot cannot be loaded
- `contract_id` cannot be checked
- `contract_id` mismatches the loaded contract snapshot
- required deterministic artifact is missing and that gap blocks the scoped verdict
- required deterministic artifact fails to parse and that gap blocks the scoped verdict
- schema version is unsupported
- deterministic replay would require heuristic trace joins
- deterministic replay would require reconstructing effect class from truncated summaries
- the required conclusion depends only on opaque `eval_criteria`
- a conclusion would require more than the currently typed violation semantics can justify

Verdict derivation rule for phase 1:

- if there is evidence of an executed or admitted contradictory contract breach under an active phase-1 check, return `Violated`
- else if there is at least one `Blocks_verdict` completeness gap, return `Inconclusive`
- else return `Satisfied`

Interpretation note:

- a blocked forbidden attempt does not by itself change `contract_verdict`
- by default it contributes to `friction_projection`
- it affects `contract_verdict` only if a future typed contract check explicitly says the attempt itself is forbidden

This makes completeness precise:

- `Blocks_verdict` gaps can prevent `Satisfied`
- `Annotation_only` gaps stay attached to the result but do not force `Inconclusive`

That is why opaque `eval_criteria not evaluated` is an annotation in phase 1, not an automatic blocker.

`Satisfied` must never mean "we did not find a problem."
It must mean "the typed phase-1 surface was decidable and all relevant checks were satisfied."

Important phase-1 limitation:

- with current v1 evidence, many `mode_violations` rows are better interpreted as blocked attempted violations, not proof that a forbidden effect escaped into the world
- therefore phase-1 `Violated` may be rare
- this is acceptable if the docs say so explicitly and the findings remain visible

## 10. Legacy 4-Field Digest Factorization

The old supervisor digest fields should not remain as a single peer surface.
They factor through deterministic verdict and nondeterministic advice.

Recommended mapping:

- `evidence_gap`
  - deterministic
  - derived from `completeness_gaps`
- `ambiguity`
  - nondeterministic
  - advisory interpretation surface
- `drift_risk`
  - nondeterministic
  - advisory interpretation surface
- `unsafe_edit_risk`
  - split
  - admitted or contradictory forbidden effect belongs in deterministic findings or verdict
  - blocked attempt belongs in `friction_projection`
  - forecast risk or operator caution belongs in advice

Contract-logic note:

- a blocked forbidden attempt means the enforcement boundary held
- in phase 1, that does not by itself imply `contract_verdict = Violated`
- it is authoritative evidence of enforcement friction, so it belongs in `friction_projection`
- any stronger statement such as "the current contract is mismatched to intended work" belongs in `advice`, not in the deterministic projection

Operational implication:

- in phase 1, the highest-value operator signal is often enforcement friction rather than the raw verdict label
- a stream of `Satisfied` verdicts can still hide repeated blocked attempts across the declared window
- this does not mean the verdict is wrong; it means the verdict answers "was the enforced contract respected?" while the friction projection answers "what blocked-attempt and evidence-gap structure recurred over the declared window?"
- therefore dashboards and operator review flows should prioritize friction summaries and repeated blocked-attempt groups, while keeping `contract_verdict` as the authoritative audit surface

This projection is operator-facing and optimization-oriented.
It is not a second authoritative verdict surface.

Phase-1 risk guardrails:

- world-spec gap
  - `contract_verdict = Satisfied` means only that the typed phase-1 surface was decidable and satisfied
  - it must not be rendered or consumed as a world-level safety or correctness claim
- normalization-of-deviance risk
  - blocked attempts are not automatically benign just because enforcement held
  - repeated blocked-attempt groups may indicate underscoped contracts, misuse, or intent misalignment
  - interpretation of that risk belongs in `advice` or explicit review policy, not in the projection itself
- alert-fatigue risk
  - the three-surface architecture is not a requirement that operators consume three equal alert streams
  - the default UX should collapse to a prioritized review queue with drill-down into verdict, friction, and advice provenance
- Goodhart risk
  - `friction_projection` must not be used as a direct training reward or as the sole automatic contract-relaxation objective
  - contract widening should require explicit human review plus additional success/safety evidence beyond lower friction
- tripwire rule
  - a declared policy may fire deterministic review tripwires from `friction_projection` over a declared window
  - such a tripwire does not rewrite `contract_verdict`
  - it does require explicit operator review before assisted or manual contract widening

## 11. Loader and Reader Boundary

### 11.1 Phase-1 MASC Loader

Short-term, MASC may own a local proof loader to stop the current fake eval immediately.

Responsibilities:

- load `mode_violations.json`
- load `token_usage.json`
- load `tool_traces/*.jsonl`
- load `contract.json` by run convention
- emit typed or semi-typed contract facts

Constraint:

- the loader must not invent facts missing from artifacts
- the loader must sit behind a small adapter interface so OAS read APIs can replace it later without changing the judge

Suggested phase-1 boundary:

```text
Cdal_loader
  -> loaded_bundle

Cdal_judge
  loaded_bundle -> contract_verdict

Cdal_advice
  advisory_input -> advice option
```

### 11.2 Long-Term OAS Reader API

Long-term, OAS should own the read side for the `proof-store://` scheme.

Required public APIs:

- `Proof_store.resolve_ref`
- `Proof_store.read_json`
- `Proof_store.read_jsonl`
- `Proof_store.load_contract`

This keeps the proof-store scheme and layout authoritative in OAS rather than MASC.

## 12. Rollout Plan

### Phase 1A: Single-Run Deterministic Audit in MASC

Preconditions:

- freeze `check-evaluation-spec.md`
- freeze `proof-bundle-check-mapping.md`
- explicitly list `Unsupported_in_v1` checks before coding

- add `Cdal_loader`
- add `Cdal_judge`
- stop substring/ref-count evaluation
- return `Satisfied | Violated | Inconclusive`
- remove recommendation-like text from the deterministic result
- keep `friction_projection.window = Single_run`
- keep advisory empty or explicitly exploratory
- fix keeper metrics so they no longer use evidence-ref length as violation count
- keep the local MASC reader behind an adapter; do not block phase 1 on an OAS PR
- treat `eval_criteria` as annotation-only input unless and until a typed subset exists
- mark `runtime.allowed_mutations` and `runtime.review_requirement` as `Unsupported_in_v1`
- allow a narrow deterministic mapping from **known** `violation_kind` values to **mode-only** requirements when that mapping is closed-world and lossless

Phase-1A exit criteria:

- no deterministic path may count ref names instead of reading proof content
- no missing required blocking artifact may yield `Satisfied`
- verdict and advice must be stored and rendered as separate surfaces
- deterministic judgment must be replayable from the same bundle and contract semantics
- only documented active checks may participate in deterministic pass/fail logic

### Phase 1B: Single-Run Friction Projection

- add deterministic `friction_projection`
- support only `Single_run`
- populate v1-supported blocked-attempt fields only
- add deterministic review tripwires over single-run grouped counts

Phase-1B exit criteria:

- `friction_projection` does not require cross-run indexing
- unsupported blocked-attempt fields remain `None` rather than inferred
- operator-facing review queue can consume verdict + friction without treating them as equal authority

### Phase 2: OAS Read API

- upstream `Proof_store` read-side APIs
- switch MASC loader to OAS-owned ref resolution
- keep schema v1 compatibility

### Phase 3: Typed Evidence v2 and Check Expansion

- add additive fields to contract-relevant evidence
- preserve v1 artifact compatibility
- enable deterministic findings stronger than "violation exists"
- activate `runtime.allowed_mutations` and `runtime.review_requirement` only after required evidence exists

Phase-3 additive evidence should cover at least:

- `event_id`
- `trace_id`
- `turn`
- `tool_name`
- `effect_class`
- `effective_mode`
- `decision`
- `violated_rule_id` or `required_min_mode`
- `input_digest`

Phase-3 exit criteria:

- contract-relevant evidence can be joined without heuristics
- deterministic findings no longer depend on truncated summaries
- v2 bundles expose enough typed facts for obligation-level replay

### Phase 4: Cross-Run Friction and Advisory Layer

Preconditions:

- freeze `cross-run-loader-and-window-spec.md`
- freeze `error-handling-and-operations-spec.md`
- add run enumeration, ordering, and retention support before enabling any cross-run window

- add cross-run enumeration and window semantics
- add `Last_n_runs`, `Session`, and `Rolling_seconds`
- add `Cdal_advice`
- key all advice by `judgment_hash`
- allow model-based or heuristic exploration
- keep advisory out of merge gates and contract verdict
- keep the advice generator pluggable; choosing between rule-based, model-based, or hybrid generation is a separate implementation decision

### Phase 5: Operations Hardening

- define error taxonomy for loader, aggregation, and artifact corruption
- define retention and migration policy for v1/v2 artifacts
- define monitoring and SLOs for eval latency, failure rate, and aggregation lag
- define rollback / forward-fix policy for contract and evaluator schema changes

## 13. Testing Strategy

### Deterministic Kernel Tests

- replay test: same proof bundle and contract yield the same `judgment_hash`
- replay condition is "same bundle + same contract + same loader semantics", not merely the same binary name
- fixture test: real stored proof bundle replays to the same verdict
- temp-store integration: OAS writes proof, MASC loads it, kernel judges it
- fail-closed test: missing blocking artifact produces `Inconclusive`, not `Satisfied`

### Cross-Repo Consistency Tests

- differential test between local MASC loader and future OAS reader API
- property test between `Mode_enforcer` behavior and typed evidence replay once v2 exists

### Spec Consistency Tests

- cross-reference test: every named surface in the RFC resolves to a canonical definition in a referenced design doc
- mapping coverage test: every phase-1A active check has a row in `check-evaluation-spec.md`
- schema coverage test: every phase-1A active check depends only on fields present in proof bundle v1 plus evidence v1
- unsupported coverage test: every contract surface field not replayable in v1 is explicitly marked `Unsupported_in_v1`

### Advisory Tests

- advisory must reference `judgment_hash`
- advisory must not alter deterministic findings
- avoid exact-text golden tests
- advisory may be absent without failing the deterministic contract path

## 14. Non-Goals

This design does not:

- make recommendation deterministic
- guarantee a single repair plan
- interpret all of `eval_criteria` in phase 1
- recover missing contract facts from raw traces
- allow advisory output to affect contract verdict
- force a specific advice engine in phase 1

## 14b. Open Decisions

- whether manifest v2 should include artifact digests
- whether `contract_ref` should become explicit in the manifest (recommended for phase 3)
- how much of `eval_criteria` should be promoted into a typed deterministic subset
- whether `required_min_mode` or `violated_rule_id` is the better v2 evidence primitive
- whether advice should first ship as empty, heuristic, model-based, or hybrid
- whether to extend the verdict domain to 4-valued (RV-LTL: Presumably Satisfied / Presumably Violated) in future phases (see Bauer, Leucker, Schallhart 2010)
- the theoretical framing of `friction_projection` as a novel application of security observability patterns to agent contract systems (no direct prior publication found; closest analogues are ABC soft-violation counting and security blocked-request monitoring)

## 15. Human and Operator Boundary

The social boundary matters as much as the type boundary.

- operators must be able to tell verdict from advice at a glance
- reviewers must not treat exploratory advice as a merge gate
- dashboards should label `Inconclusive` as a missing-evidence condition, not as a soft pass
- operator action on advice is allowed, but advice is never policy truth
- unresolved `Inconclusive` should escalate to explicit operator review, then to blocked/defer by policy if the SLA expires
- ownership must stay explicit:
  - OAS produces raw evidence
  - MASC produces deterministic contract verdict
  - advisory output is secondary and may be regenerated

Decision rights:

- contract author
- contract approver
- verdict consumer
- `Inconclusive` override actor
- postmortem owner

Override rule:

- overriding `Inconclusive` requires actor, reason, timestamp, and linked incident or follow-up record

Anti-gaming rule:

- meanings that are not promoted into typed deterministic clauses must not be smuggled into `eval_criteria` and later treated as authoritative gate semantics

Common failure mode:

- teams will treat any green-looking text as a pass if the UI does not force a distinction

Design implication:

- `Satisfied`, `Violated`, and `Inconclusive` must be visually primary
- advice must be visually secondary
- `Inconclusive` must never be styled as a soft success

## 16. Cost and Shipping Constraint

The phase-1 goal is to remove fake evaluation, not to perfect advice generation.

Therefore:

- shipping a strong deterministic kernel with empty advice is acceptable
- blocking the kernel on an advice-engine decision is not acceptable
- blocking phase 1 on an OAS reader PR is not acceptable if the MASC-side reader is isolated behind an adapter

## 17. Stress-Test Perspectives

This design was intentionally pressure-tested from several extreme viewpoints.

- Agent systems expert:
  phase 1 needs a closed check registry, not a vague clause system
- ML evaluation expert:
  partial observability requires explicit blocker vs annotation semantics
- Model/LLM systems expert:
  model-aware advice must stay replaceable and downstream of verdict
- Senior engineering reviewer:
  the smallest unblocking convention beats an abstract framework here
- Turing-style formalist:
  identifiers, judgments, evidence, and annotations must be distinguished explicitly
- Reliability pessimist:
  missing evidence, unsupported schema, or ambiguous replay must become `Inconclusive`, not soft success
- Sociologist:
  teams will treat any green-looking prose as a pass unless verdict and advice are visibly and structurally separated
- Profit-minded developer:
  phase 1 must fix the fake eval without waiting on cross-repo purity work
- Founder-speed view:
  phase 1 and phase 3 need explicit exit criteria

These perspectives pull in different directions.
The design keeps them compatible by making the deterministic kernel small and strict, and the advisory layer optional and replaceable.

## 18. Recommended Decision

Adopt the split.

Specifically:

- ship a deterministic contract kernel in MASC first
- treat current schema limitations as reasons for `Inconclusive`
- upstream OAS read APIs next
- introduce typed evidence v2 after the fake eval is removed
- keep recommendation and interpretation as a separate advisory surface permanently

This is the smallest design that is:

- replayable
- auditable
- compatible with the user's "contract only deterministic" rule
- safe to extend without reintroducing hidden heuristics

## 19. External References

### Policy Engine Foundations
- Cedar authorization and diagnostics: <https://docs.cedarpolicy.com/auth/authorization.html>
- Cedar verification-guided development: <https://www.amazon.science/publications/how-we-built-cedar-a-verification-guided-approach>
- Open Policy Agent configuration and decision-log model: <https://www.openpolicyagent.org/docs/configuration>

### Runtime Verification Theory
- Leucker and Schallhart, "A Brief Account of Runtime Verification" (JLAP 2009): three-valued runtime verification semantics
- Bauer, Leucker, Schallhart, "Comparing LTL Semantics for Runtime Verification" (JLC 2010): four-valued RV-LTL (T, F, presumably T, presumably F)
- Runtime verification survey: <https://www.research-collection.ethz.ch/items/7c1687f4-bd0d-4bb5-a9f0-58b58a647bf6>

### Agent Runtime Governance (2025-2026)
- Agent Behavioral Contracts (ABC): <https://arxiv.org/abs/2602.22302> -- (P,I,G,R) formalization, Drift Bounds Theorem, AgentContract-Bench (200 scenarios, 7 models)
- AgentSpec (ICSE 2026): <https://arxiv.org/abs/2503.18666> -- DSL for specifying and enforcing runtime constraints on code agents
- MI9 Agent Intelligence Protocol: <https://arxiv.org/abs/2508.03858> -- six-component runtime governance framework
- Pro2Guard: <https://arxiv.org/abs/2508.00500> -- proactive enforcement via probabilistic model checking
- Runtime Governance Policies on Paths: <https://arxiv.org/abs/2603.16586> -- compliance as deterministic function on partial paths

### Proof Integrity
- Proof-of-Guardrail: <https://arxiv.org/abs/2603.05786> -- cryptographic attestation that guardrails executed; self-report shown insufficient

### Contract-Based Design
- Benveniste et al., "Contracts for System Design" (Foundations and Trends in EDA, 2018): assume/guarantee meta-theory
