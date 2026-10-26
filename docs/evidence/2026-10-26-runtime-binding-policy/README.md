# Runtime capability authority — #27898 / #46006

A prepared config with a frozen missing model policy could still acquire later
model/provider facts through `Provider_runtime_binding`'s fallback. Its separate
wire table and registry lookup also allowed runtime capability projection to
disagree with actual request admission.

## Current capability contract

`Provider_config.resolve_request_capabilities` returns one capability record
and typed source. Explicit overrides and existing catalog/frozen model policy
answer first. With no model policy, anonymous OpenAI-compatible configs retain
their chat protocol defaults, including tools, streaming and structured output;
explicitly identified OpenAI-compatible providers remain conservative. Both
fallbacks are reported as `Provider_default_capability`, without inventing
catalog model facts. GLM keeps its protocol defaults. Anthropic, Kimi, Ollama
and Gemini keep native protocol features with all three forced-tool-choice
flags false, aligning runtime projection with request admission. Tool-choice and other capability-dependent
request admission, Common observers and the runtime binding projection consume
that same authority. The runtime projection no longer reopens a registry or
performs a second global model lookup. A selected binding still carries its
explicit provider declaration through `to_provider_config`; a raw provider id alone does
not activate a later provider overlay.

The model/provider catalog parser and registry construction are not globally
consolidated by this change. Request preparation still owns policy freezing;
this repair preserves its absent result through readers. Existing binding
metadata lookup APIs remain live metadata reads, not frozen request policy.

Pipeline selects native streaming only when the resolved capabilities declare
it; otherwise a requested stream uses the synchronous transport fallback. The
existing two controls now have separate Alcotest names, so a failure identifies
the declared-stream or undeclared-fallback case. Their assertions are unchanged.

The review cleanup combines the resolver's duplicate wire matches without
changing those policies. Source parsing, independent source review and native
execution are separate evidence. Run results must identify their own source
head and selected suites; they do not establish provider HTTP or installed
runtime behavior.

## Anonymous protocol regression repair

The restored anonymous chat defaults conflicted with older fixtures that
expected unknown models or recognizable URLs to disable schema and forced
tool choices. [40291347752](https://github.com/jeong-sik/masc/actions/runs/40291347752)
checked out `a1e8d00dbf4ba4aa5fcc659e203ddf757ac14242` and reproduced
**1 failure in 29 runtime-binding cases and 16 failures in 141 provider-config
cases**. Both selected suites compiled and executed; these were assertion
failures, not setup failures.

The repaired fixtures check that anonymous requests have no inferred model
policy, report `Provider_default_capability` and retain chat-schema/forced-tool
admission. Binding controls also check the actual named and required tool
choice JSON. Provider-specific rejection controls now declare the intended
provider identity; an explicit unsupported capability override still rejects
named tool choice. Schema validation and frozen-policy controls remain in
place. The corresponding backend inline fixtures use the same distinction.

[Candidate run 40292569538](https://github.com/jeong-sik/masc/actions/runs/40292569538)
compiled and executed `0291f1211754740b605136a8e08fd6e5a3099985`:

| Suite | Baseline failures / cases | Candidate failures / cases |
| --- | ---: | ---: |
| runtime binding | 1 / 29 | 0 / 34 |
| provider config | 16 / 141 | 0 / 142 |
| Pipeline | not selected | 0 / 82 |

The candidate is based on merged main
`726c619c426b6cf93f9b220963530627a4722579`, which also includes the declaration
snapshot and selection capture changes. Five binding cases come from those
merged layers; this repair adds one separately named anonymous config case and
separates the existing Pipeline stream/fallback controls. The 258 candidate
passes cover these three selected suites, not the entire regression suite.

[The machine-readable receipt](anonymous-chat-regression-repair.json) records
both run identities, exact suite selections, result counts, log excerpts,
selected source hashes and independent reviews. The repair is delivered by
[PR #46075](https://github.com/jeong-sik/masc/pull/46075). The delivered code head
`82a7e1ad266eedc895f581706aadccc69e9f7be1` adds only its required changelog
fragment after the executed candidate. This evidence layer also changes only
documentation; all non-documentation files and the 16 selected verification
inputs are identical to the tested candidate. No new execution on either
documentation revision is claimed. Current-head reviews are recorded in the
PR descriptions; earlier review records retain their original source identity.

Backend inline tests and the full regression suite were not selected. These
results do not establish provider HTTP, installed-runtime behavior, merge,
deployment or completion of the broader #27898 work.

## Earlier evidence

[Earlier authority and fixture observations](history.md) preserve the
pre-restoration run history and explain the original and corrected source
manifests. Neither historical manifest certifies the current candidate.
