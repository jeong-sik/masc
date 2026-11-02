# Selected HTTP runtime credentials

Bounded repair [#47113](https://github.com/jeong-sik/masc/pull/47113) for
[#27898](https://github.com/jeong-sik/masc/issues/27898), against
`9731fad3219a622f8cacdf62b59d709c1b0280eb`.

The adapter selected an Env alias, then reread its value. Runtime construction
selected the alias again for quota ownership, and dispatch selected it again
for the missing-auth error. Dispatch also reread the current provider registry
to decide whether the retained runtime required a credential. A later catalog
or environment change could therefore change an existing selection's admission
or identify an account that the request never used.

`Runtime_credential_selection` now observes an Env reference and its value
together, once. The HTTP adapter uses its already selected registry entry and
returns the complete provider config with opaque, non-secret admission facts.
Execution materialization carries those facts into `Runtime_instance`; quota
ownership and empty-final-secret admission use the same selected authority.
Dispatch does not read the registry, environment or credential file again.
Inline secret text and file contents are absent from admission metadata.

The old reconstruction APIs and config-only materialization APIs are removed;
production consumers and test fixture projections use the new products.
Missing HTTP selection authority is an invalid runtime configuration, with no
fallback to mutable globals. Missing Env/Inline values remain materializable
for existing dashboard projection. Unknown provider requirements remain
distinct from keyless declarations and retain their prior runtime admission.
Fresh discovery continues to refuse an unknown or missing required credential.
A nonempty transformed final key remains sufficient for a selected runtime.
File validation, deferred Vertex refresh and official-client ownership retain
their separate boundaries.

## Executions

| Test execution | Exact head | Result |
|---|---|---|
| [Initial baseline 41273488270](https://github.com/jeong-sik/masc/actions/runs/41273488270) | `afb071f95b90b1cd06e01f21c7d1efabc18240ff` | FAILURE: 73 PASS/5 FAIL; four real catalog failures and one invalid Env fixture |
| [Corrected baseline 41274072075](https://github.com/jeong-sik/masc/actions/runs/41274072075) | `8a39bd9abe4a60315fc078100a69cabc9f09f8ee` | FAILURE: 73 PASS/5 FAIL, all five intended reproductions |
| [First candidate 41274333574](https://github.com/jeong-sik/masc/actions/runs/41274333574) | `0aba348609a3ca754eab2cac4126018d6cc70a1a` | FAILURE: 434 Alcotest PASS/1 FAIL, plus 19 Python unittest PASS |
| [Parent account check 41275401536](https://github.com/jeong-sik/masc/actions/runs/41275401536) | `9731fad3219a622f8cacdf62b59d709c1b0280eb` | FAILURE: 12 PASS/1 FAIL, the same shared-list parity failure |
| [Shared-set repair 41275518210](https://github.com/jeong-sik/masc/actions/runs/41275518210) | `392514a12acb106f5c625611983184974626691e` | SUCCESS: 191 PASS/0 FAIL, account declaration13/runtime configuration178 only |

Both baselines leave production identical to the parent. The initial alias
fixture used `value` instead of the runtime TOML Env field `key`; it failed
parsing and does not establish the alias defect. The corrected baseline keeps
the other four cases unchanged and uses the real credential declaration.

The corrected baseline shows retained keyless and unknown selections becoming
keyed, and keyed selections losing their requirement after a keyless catalog
replacement or catalog removal. The alias request uses the selected fallback
`OLLAMA_API_KEY`; after environment mutation the missing-auth error wrongly
names `OLLAMA_CLOUD_API_KEY`. Each baseline case stops at its failing retained
selection assertion; it does not establish later fresh-selection assertions.

All five reproducer/helper source bytes are identical between the corrected
baseline and candidate (5079 bytes; hash in `manifest.json`). Candidate coverage
also checks a fresh alias request against its own quota owner, retained File
admission after deleting the source file, strict fresh File selection, deferred
refresh, and verification's selected-carrier diagnostic mapping. The previous
verification fixture materialized empty Inline and rewrote only its declaration;
it now selects the actual valid File or Env carrier before emptying the final
execution secret. Invalid File materialization remains tested separately.

The first candidate passes provider/auth80, credential requirement4, quota17,
verification22, setup credentials4, setup spec16, routing101 and runtime
configuration178. Python model discovery separately runs 19 tests against the
compiled fixture CLI. Account declaration passes12/fails1, so the complete
ten-suite execution is a failure. Its existing shared-list parity assertion
finds six already-shipped GPT-6.1 Terra tiers absent from `model_sets.codex`.
The parent and current main `716d22c3ef7243cee7a29d8650c2b2b8cba61c37`
contain the same incomplete set. The follow-up adds those six declared IDs:
50 unique shared profiles cover all 17 explicit binding overrides, with no
other parsed configuration change. The original account assertion is intact.
`Runtime_account_declaration.declare` already copies explicit overrides, so
this does not establish that copied accounts previously lost Terra models.
The final focused check passes the original account assertion and all 178
runtime configuration cases. It does not rerun or relabel the earlier
ten-suite workflow. The credential implementation and its tests are unchanged
from that earlier execution, including the 80 passing provider/auth cases and
the separate 19-case Python CLI discovery run.

`manifest.json` records exact run/head/ref/status and distinct raw/selected log
digests. Original logs are under ignored
`artifacts/issues-oldest-20261101/runtime-credential/`. The first execution's
23 inputs and four source-tree identities are in `source-initial-sha256.json`.
The later `source-sha256.json` records 24 inputs, including the repaired seed,
at `392514a12acb106f5c625611983184974626691e`. Its lib/test/agent_core trees
match the first candidate exactly; only config/changelog differ. These are
not exhaustive build dependency manifests. Selected suites are explicit;
separate executions' counts are never added.

## Review and remaining scope

Independent adversarial and response source reviews pass with no P0–P2 at
`392514a12acb106f5c625611983184974626691e`, canonical full diff
`70da0b0ab48bc880a2a09e080ad158ff6674ec1d2056f85ba9e1d2dd891163b5`.
Both first reviewed the complete credential source at `0aba348`; their later
review verifies the six-entry seed/changelog delta. The response review's P3
wording concern is corrected to shared-set completeness, with the copied-account
limitation stated above. This source review does not certify a future evidence
head or establish an execution result.

The dashboard reachability probe still selects credentials from provider
declarations; this dispatch repair does not certify that consumer. Other
construction-time catalog projections and official-client reasoning policy
remain outside this work unit. Whole-stack integration, installed runtime,
real provider traffic, deployment and full issue acceptance remain separate.
The issue stays open. Internal source review is not formal non-author GitHub
approval.
