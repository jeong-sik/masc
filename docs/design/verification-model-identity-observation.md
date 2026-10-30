---
status: partial
updated: 2026-10-30
---

# Verification model identity observation

Runtime configuration keys do not establish which models emitted the
submitting tool call and accepted verdict call. Calibration therefore keeps runtime diversity separate from
captured provider/model identity diversity. Missing observations are excluded
from the model-pair denominator and remain visible in coverage and cause
counts. A submitting-response identity does not identify all models or
collaborators that authored an artifact across earlier turns. A provider/model
identity does not prove different model weights or statistical independence.

## Native capture and immutable binding

`Runtime_response_identity` in `masc_types` owns the validated immutable value:
a host execution ID, actor, actual runtime ID, SDK response correlation label, provider
ID, reported model ID, exact tool-use ID, provider-turn ordinal, and the
original ToolUse ordinal before name admission.

`response_id` copies SDK `api_response.id`. It does not attest a provider-native
or globally unique response ID. For example, the Ollama JSON parser uses the
wire model name (or its `ollama` fallback) as this label. It can repeat across
responses. Exact occurrence binding comes from the host execution, provider
turn and original ToolUse ordinal; pair measurement compares only the captured
provider and reported-model identities.

Capture coverage also depends on the SDK retaining response metadata. Native
Ollama streaming currently emits no `MessageStart` metadata into the response
accumulator, leaving its response ID and reported model empty. The Gemini JSON
parser also supplies an empty response ID. These paths remain unobserved under
the current capture contract, even when other output or wire metadata exists.
They are not same-model observations, and neither configured labels nor invented
provider IDs fill the gaps. Broader capture needs an explicit producer-owned
metadata contract; it is outside this change.

`Runtime_agent.config.execution_actor` is supplied by the named-runtime
driver from the host-owned Keeper name. It is independent of the synthetic
`agent_core-<runtime>` agent name. Direct native callers without a supplied
actor remain unobserved.

`Runtime_response_identity_scope` installs an execution-local scope for each
native runtime call. Its `AfterTurn` hook receives the live provider response
before tools execute. Capture requires the materialized provider ID and the
typed reported-model fact stamped by the raw JSON parser or stream accumulator,
before presentation fallback. Request/canonical model metadata is insufficient.
The measured model ID is that retained reported value. No current catalog lookup or
`last_model_used` read substitutes for either fact.

Each tool handler freezes that response with its own exact invocation through
`Agent_core.Tool.map_handler`, which also preserves producer-prepared resource
handlers and terminal contracts. The frozen fiber binding survives nested
work without being overwritten by another provider response. A new native
scope and the named-runtime dispatch boundary mask the invoking tool's
identity. `Invocation.planned_index` selects its entry in Agent Core's existing
`AfterTurn.tool_source_map`, which retains `source_tool_use_ordinal` across
name admission. The identity stores that original ordinal: a rejected sibling
sharing the same wire ID cannot be confused with the admitted occurrence.
Missing or ambiguous mappings stay unknown. An uncaptured official-client execution cannot borrow its caller's
model.

`Verification_protocol.create_submit_request` writes the current submitting
invocation under `output.producer_execution` only when its host actor equals
the request worker. It replaces any reserved field from the source output;
model/tool arguments cannot supply that host value. Missing capture is
`null`. The captured value remains in the submitted request file; the
calibration policy below does not remove or rewrite it.
`Verification.producer_execution` diagnoses malformed, duplicate, and
worker-mismatched metadata. The completion authority treats such diagnostics
as unknown observation; they do not block Task review or approve/reject it.

The retained Task verifier original currently uses schema
`verifier_review_original/v3`. It freezes the submitting runtime name when
available, but does not bind the full `producer_execution` identity. A
request file read by a later wake is therefore not proof of the exact identity
associated with that original, even if its actor and runtime name match.
Every newly written v3 Task calibration verdict row records
`producer_execution: null`, including a fresh review, to avoid assigning an
unbound identity. This is an observation loss for all such new rows, not a
claim that the original submission lacked an identity. The retained original's
`generator_runtime` and the request file's captured identity remain in place.
A v4 original or other durable binding of the full submitting identity has not
been implemented.

The reviewer hook in `workspace_metric_hooks.ml` freezes
`evaluator_execution` exactly when `report_review_verdict` records its single
accepted verdict. It does not use the final response of the review, which can
arrive after that tool call. On the ordinary response path, the winning reply
carries the same immutable identity through `Anti_rationalization.review_result`,
review notes, and the calibration ledger. In `Dispatch_pending` journal recovery,
the reconstructed result sets `evaluator_execution` to `None`, so the evaluator
is also unobserved. Goal proof review shares the result type; its completion and
person-confirmation policies are unchanged.

## Measurements

`distinct_runtime_count` and nullable `distinct_runtime_rate` remain diagnostic
comparisons of recorded runtime keys. They make no model-independence claim.

`model_identity_observation` reports:

- `observed_verdict_count` and `unobserved_verdict_count`;
- `same_model_identity_count` and `distinct_model_identity_count`, comparing
  the captured submitting-response/verdict-response provider/model pair;
- `distinct_model_identity_rate`, `null` when no complete pair was observed;
- `unobserved_causes`, separating absent producer, evaluator, and both.

The ledger checks producer actor and evaluator runtime consistency before a
pair can count. Missing or malformed identity data never becomes a measured
zero. The dashboard projects the ledger observation directly and exports no
raw provider/model identity in its overview.

A new v3 Task row is counted as producer-unobserved when a valid, matching
evaluator identity is present, or both-unobserved when that identity is absent
or invalid. It is excluded from the complete-pair denominator; the retained
runtime-name comparison is not a substitute for model identity. Earlier rows
are not rewritten and can still contribute their recorded pairs; this change
does not retrospectively verify their producer identities.

The ledger is not a census of attempts or judgments: a result without a verdict
writes no row, and already-Judged or commit recovery does not backfill a row
missed before recovery. Coverage counts describe the rows actually present.

## Remaining boundaries

Official clients do not yet provide an equally strong response-to-tool binding
through this native capture. Their submissions and verdicts remain unknown;
this implementation does not infer an identity from an assigned runtime, a
CLI configuration, a final turn summary, or mutable Keeper metadata. A later
implementation must extend each official-client's own pre-tool response
boundary with actual provider/model and invocation evidence before increasing
its observed coverage.

Raw parsers retain explicit missing/blank model evidence separately from
uncaptured evidence. `patch_telemetry` preserves this fact even when it fills
`api_response.model` from the configured request model. Repatching and cache
readback cannot promote that fallback into a reported model.

Provider model names can alias the same underlying weights across providers.
The present metric measures the reported identities, not weight independence,
model-family independence, or reviewer correctness. No new approval gate is
introduced: note-only Task judgment and Goal proof/person confirmation remain
as configured.

## Build source consumption

The changed parser sources are tracked in this repository.
`packages/agent_core/lib/llm_provider/dune` declares the local public library
`masc.agent_core.llm_provider`, and `packages/agent_core/lib/dune` declares
`masc.agent_core` with a dependency on that local `llm_provider` library.
`lib/runtime/dune` and `lib/dune` depend on those exact public names.
The root Dune directory selection includes `packages`; `dune-project` states
that Agent execution is built from `packages/agent_core`, and `masc.opam`
declares no external Agent Core dependency or pin.

The candidate build paths use this workspace: `linux-x64-probe.yml` builds
`bin/main_eio.exe`, and `merge-compile.yml` invokes Dune with `--root .`.
These source declarations establish which implementation the build selects;
they are not a claim that the changed candidate has built or run.

## Validation scope

Eighteen standalone checks compile and execute the actual pure identity module
against its interface: validation, strict JSON roundtrip, duplicate/negative
input rejection, same-model runtime aliases, a changed model under one alias,
all missing-pair cases, observed/unknown coverage and its nullable rate, and
immutable identity retention, including original-ordinal validation and
readback. This is actual-source
pure behavior evidence; it does not link the MASC runtime.

Authored native tests exercise the real provider/tool loop on fresh,
cooperative, and checkpoint entries; exact submitting response and invocation;
synthetic agent name versus host actor; missing actor; blank reported model
through presentation fallback; nested identity masking; a real pipeline with
registered and rejected ToolUse siblings sharing one ID and retained original
source ordinal;
immutable submit/reload; duplicate metadata without a review gate; actual
winning reviewer reply; and calibration observed/unknown coverage. OCaml
syntax and whitespace checks are local source evidence. Native linked tests,
CI, installed binaries, and live producer/judge readback remain unproved here.
