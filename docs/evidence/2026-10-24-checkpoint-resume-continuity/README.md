# Checkpoint resume continuity (#27894, layer 2)

A checkpoint retains the actual response producer in its session binding and
per-message reasoning metadata. Resume now returns a typed Result and validates
all stored reasoning artifacts against the frozen exact caller target before
constructing a provider-bound Agent. Provider kind, canonical model, replay
contract and endpoint/path rotation use the existing typed Source contract;
no provider is inferred from a model or URL. Mixed-producer histories are checked
per artifact. A session binding cannot supply missing artifact provenance.
Validated inline Chat carriers are artifacts even with empty or text-only
canonical content. Native signed endpoint changes are refused; declared generic
text rotation and text-only failover remain available.

Caller `preserve_thinking=false` permits exclusion only if the actual resolved
dialect declares No_replay. Ignored knobs cannot authorize a drop. Canonical
history and recorded producers remain unchanged. An unconfigured target can
restore pending input without making a provider request. Both sync and streaming
Agent dispatch revalidate effective messages and target after hook overrides and
caller-owned model input projection, before provider-attempt callbacks or wire
serialization. This prevents a hook from re-enabling incompatible replay after
resume admitted explicit exclusion.

Production Runtime and Keeper callers propagate typed refusal, including the
HTTP status boundary. Tests adapt the public Result contract and cover source
mismatch, declared rotation, mixed histories, corrupt/absent provenance, direct
invalid checkpoint records, no-provider restoration and actual sync/stream hook
paths with a transport counter. Inline-carrier tests include empty bytes, empty
think tags and text-only payloads.

## Historical execution evidence

- Lower provenance layer: [run 40095848830](https://github.com/jeong-sik/masc/actions/runs/40095848830),
  exact head `61f24a9ff9c877a4e36f3baae0588d5bcfef5ec1`, SUCCESS. Direct logs show
  checkpoint 113, delta 11 and pipeline 69 tests passing. It was merged as
  `fde6f30f922bb5613f3cfea75be05fe2c833ce61`.
- Initial upper candidate: [run 40097601838](https://github.com/jeong-sik/masc/actions/runs/40097601838),
  exact head `746628b51582f4f747a9e9f31d47e5ca0ed58440`, FAILURE. It exposed an
  invalid test constructor, missing exhaustive refusal consumers, and two stale
  Timeout-origin assertions. The constructor and exhaustive matches were fixed.
- Baseline comparison: [run 40098805540](https://github.com/jeong-sik/masc/actions/runs/40098805540),
  exact main `fde6f30f922bb5613f3cfea75be05fe2c833ce61`, FAILURE. The same two
  elicitation assertions failed among 23 tests: durable input transitions / all
  typed responses, and owned current input / rejected resume and stale input.
  Agent_elicitation already emits Timeout with Recovery_instruction origin;
  expectations incorrectly used Conversation. The upper change corrects these
  expectations and the matching Keeper settlement fixture, without changing
  production Timeout semantics.

Selected follow-up CI is recorded on the PR at its exact candidate head. No local
Dune build or full regression was run. Parser/whitespace checks prove syntax and
patch hygiene only. Source review and selected CI do not establish installed
runtime, live provider conformance or deployment. Low-level lossy projection APIs
retain their existing contract; this change protects Agent resume and dispatch.
Native creation-prefix digest edits are not newly adjudicated by this layer.
