# Runtime capability authority — #27898 / #46006

A prepared config with a frozen missing model policy could still acquire later
model/provider facts through `Provider_runtime_binding`'s fallback. Its separate
wire table and registry lookup also allowed runtime capability projection to
disagree with actual request admission.

## Candidate

`Provider_config.resolve_request_capabilities` returns one capability record
and typed source. Explicit overrides and existing catalog/frozen model policy
answer first. When absent, unknown OpenAI-compatible endpoints acquire no
capability-dependent options; native wires keep their prior request defaults
and conservative forcing flags. Tool-choice and other capability-dependent
request admission, Common observers and the runtime binding projection consume
that same authority. The runtime projection no longer reopens a registry or
performs a second global model lookup. A selected binding still carries its
explicit provider declaration into the config; a raw provider id alone does
not activate a later provider overlay.

The model/provider catalog parser and registry construction are not globally
consolidated by this change. Request preparation still owns policy freezing;
this repair preserves its absent result through readers. Existing binding
metadata lookup APIs remain live metadata reads, not frozen request policy.

## Actual baseline and review findings

- [40218767565](https://github.com/jeong-sik/masc/actions/runs/40218767565)
  checked out322b4a7db4ca6d7ceadb4b0176943a59ee32712a and failed before tests:
  the first fixture named a private Common helper. This is not a behavioral
  failure. The fixture was corrected to the public config policy API.
- [40218847399](https://github.com/jeong-sik/masc/actions/runs/40218847399)
  checked out994fd40bd4b1a2de9276e81c1a6d74234b38ce5e and actually executed
  **27 cases:25 PASS / 2 FAIL**. Frozen missing model policy changed after a
  model catalog replacement; frozen missing provider policy acquired a later
  provider overlay. The selected-binding retention control passed.
- The initialcf4 repair delegated to Common's observation helper. Independent
  source review then found that helper used OpenAI's permissive wire preset
  while actual forced-tool admission used conservative defaults. The prior
  SOURCE PASS missed this P2 and is superseded. This was a source finding,
  not an executed forcing failure: its full-admission fixture did not yet exist.
- The corrected8f2943803e9bc898c9413430299ea4bb0893c6b6 source moves the shared
  authority into Provider_config. New full-admission controls compare advertised
  ANY/named support against `Complete_common.validate_all` across all six wire
  kinds and check unknown-endpoint JsonSchema rejection.

## Verification scope

`provider_config.ml` → shared request capability resolver → tool-choice/output
admission + Common observation + runtime binding → `test_provider_runtime_binding`.
`Provider_runtime_binding.capabilities_for_provider_config` → Pipeline stream
selection and MASC Provider_tool_support → `test_pipeline` and
`test_model_capability_presence`.

[40219173989](https://github.com/jeong-sik/masc/actions/runs/40219173989) was
dispatched for corrected8f294 source with exactly those three suites. Its result
is not yet verified here. Intermediate40218944547 targets sourcecf4 and cannot
certify the final authority or new full-admission controls. The ten source and
direct-consumer hashes bind the corrected request; evidence-only additions do
not change them. Changed OCaml parsing and whitespace passed locally. No local
Dune build/typecheck, provider HTTP, installed-runtime, whole-catalog hard cut,
full regression, formal independent approval, merge or issue completion claimed.
