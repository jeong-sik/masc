# Earlier runtime capability authority evidence

These records retain their original source identities and observation scope.
See [the current repair evidence](README.md) for the anonymous chat regression.

## Historical baseline and review findings

The records below predate restoration of anonymous chat protocol defaults.
Their source identities and observed results remain historical evidence; they
do not describe the current anonymous fallback or certify a later restack.

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

## Verification scope and historical requests

`provider_config.ml` → shared request capability resolver → tool-choice/output
admission + Common observation + runtime binding → `test_provider_runtime_binding`.
`Provider_runtime_binding.capabilities_for_provider_config` → Pipeline stream
selection and MASC Provider_tool_support → `test_pipeline` and
`test_model_capability_presence`.

[40219173989](https://github.com/jeong-sik/masc/actions/runs/40219173989) was
dispatched for corrected8f294 source with exactly those three suites. Its result
is not yet verified here. Intermediate40218944547 targets sourcecf4 and cannot
certify the final authority or new full-admission controls. The initial ten source and direct-consumer hashes bind that historical8f
request; the refreshed request and fixture correction are recorded below. Changed OCaml parsing and whitespace passed locally. No local
Dune build/typecheck, provider HTTP, installed-runtime, whole-catalog hard cut,
full regression, formal independent approval, merge or issue completion claimed.


## Historical fixture correction and request

Actual intermediate [40218944547](https://github.com/jeong-sik/masc/actions/runs/40218944547)
checked outcf4b708c48ecea2edf121116e34fd5b27b7f47ae and ran binding27 with
**26 PASS / 1 FAIL**, Pipeline **68 PASS**, and the MASC direct-consumer suite
**3 PASS**. The beta shared-endpoint fixture still copied a raw provider id
then expected it to activate a provider overlay. That is exactly the fallback
this hard cut removes. Identity/alias lookup remains checked; policy assertions
now project both already-validated bindings through `to_provider_config` and
also verify that the raw beta id does not grant reasoning.

A later independent source review found a separate stale Gemini whole-record
comparison after8f's conservative forcing flags. The fixture now independently
checks native tools, all three forcing flags and public admission refusal for
anonymous and unknown identities while retaining the declared-alias control.
These are fixture corrections; production is byte-identical to8f. Earlier
SOURCE PASS assessments that missed them are superseded. Two corrected full
fixture source reviews atc891 found no remaining P0–P2. They are not execution
results or formal GitHub approvals.

[40219615509](https://github.com/jeong-sik/masc/actions/runs/40219615509) was
dispatched for exactly `c891e4aa26830a1622d96d3ca5f7525c6d24300b` and the
same three explicit suites. Its result is unverified. Intermediate requests
40219173989 and40219425794 precede one or both fixture corrections; do not
reuse their outcome as final-fixture acceptance. `corrected-source-sha256.json`
binds the ten source/fixture/direct-consumer inputs at `c891e4aa26830a1622d96d3ca5f7525c6d24300b`
and preserves the original8f manifest as history. No build, HTTP, installation, merge, full
regression or whole-issue completion follows from the source reviews or earlier
partial execution results.

The two manifests have distinct historical roles:

- `source-sha256.json` pins the initial shared-authority source at
  `8f2943803e9bc898c9413430299ea4bb0893c6b6`.
- `corrected-source-sha256.json` pins the corrected fixture request at
  `c891e4aa26830a1622d96d3ca5f7525c6d24300b`; production inputs were unchanged
  from the first manifest, while the binding fixture was corrected.

Neither manifest is a claim about the current PR head. Current head/base review
and any later execution receipts belong to the PR description, with their own
scope and source identity.
