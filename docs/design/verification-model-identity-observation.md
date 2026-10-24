---
status: partial
updated: 2026-10-24
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
a host execution ID, actor, actual runtime ID, provider response ID, provider
ID, reported model ID, exact tool-use ID, provider-turn ordinal, and the
original ToolUse ordinal before name admission.

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
`null`. This value is part of the original request file, so later turns,
configuration changes, process restarts, and retries do not replace it.
`Verification.producer_execution` diagnoses malformed, duplicate, and
worker-mismatched metadata. The completion authority treats such diagnostics
as unknown observation; they do not block Task review or approve/reject it.

The reviewer hook in `workspace_metric_hooks.ml` freezes
`evaluator_execution` exactly when `report_review_verdict` records its single
accepted verdict. It does not use the final response of the review, which can
arrive after that tool call. The winning reply carries the same immutable
identity through `Anti_rationalization.review_result`, review notes, and the
calibration ledger. Goal proof review shares the result type; its completion
and person-confirmation policies are unchanged.

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
