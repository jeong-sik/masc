# Preserve declared aggregation

The final source review of PR46001 head
`6373afb2e651d27312886866a2c2a7dd0060a3f3` found a P2 in the new prompt:
the instruction against combining different executions could also forbid a
metric that explicitly declares an aggregate. The
[FAIL](previous-source-fail.json) is preserved. Earlier source PASS reports and
the three successful single-record/report controls did not exercise that case.
Task2676 had already reached Done through normal verification; that lifecycle
fact did not clear this subsequent source finding. Task2680 links to Task2676
through `predecessor_task_id` and tracks the bounded follow-up.

The prompt now permits aggregation in the metric's declared scope and method
while preserving each execution identity. It forbids mixing results outside that
scope or substituting one execution as evidence for another. The exact source
patch response is retained in [source-response.json](source-response.json).

## Separate actual aggregation control

Two controlled Python commands were recorded once each: run-a produced stdout4
and run-b stdout6, both exit0. An index linked both records but claimed99. A fresh
isolated Goal explicitly required reading those two records and comparing their
sum with exactly10. The actual judge read the index and both records, preserved
their IDs, excluded99, and approved `4+6=10`. The committed state was
`proof_proven` / `awaiting_confirmation`; no human confirmation was sent.

[result.json](result.json), [actual-tool-sequence.json](actual-tool-sequence.json)
and [persisted-outcome.json](persisted-outcome.json) bind the request, retained
Original, actual provider input, tool results, structured verdict and typed state.
This was **one Goal run, four provider POSTs and four unique tool calls**. All
POSTs requested/reported `glm-5.3-flash`, without an unknown reported model.
The first provider System/User messages matched the retained Original exactly.

The candidate prompt was 7,672 bytes, SHA256
`529f84a6a36146eca2821e02ade8a9467b166b5d1ed25eea4b37493cc5579539`.
Its proof and lookup sections were applied through normal authenticated persisted
overrides in an isolated runtime using the existing3e binary, SHA256
`00f3fdc897bea8874dc21bd9f471aef80ef9e2aebd4321b4483ce83508ef84e8`.
The managed baseline files remained unchanged. This is a prompt-runtime control,
not a native build of the new PR head.

An initial read-only catalog GET raced server startup and was connection-refused
before any prompt POST or Goal submission. A subsequent explicit health read
preceded normal prompt application. That preparation failure is retained and is
not a model verdict or extra control.

The55 private originals are indexed by
[private-originals-manifest.json](private-originals-manifest.json); raw provider
responses and authentication material are not published. Protocol/state files
here are allowlisted projections. Both owned proxy/server PIDs were checked
against their recorded identities, signalled separately and observed absent;
see [owned-stop.json](owned-stop.json). No descendant or fleet claim follows.

## Limits

The [earlier cohort](../2026-10-26-goal-proof-provenance/README.md) used
prompt35b653 and remains valid for its three non-aggregate metrics. This new
control used prompt529f. The cohorts are separate and are not pooled into a
reliability rate or described as a single-prompt regression run. The old aggregate
restriction was a source finding, without an observed failing baseline model
judgment. No causal A/B, general aggregate correctness or model-weight
independence is established.

Original eleven-case Goal proof, final human confirmation, production application,
new-head native/build evidence and whole-stack approval remain separate. Source
wording and these controls do not provide a deterministic prompt-injection
defense.
