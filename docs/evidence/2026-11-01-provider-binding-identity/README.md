# Selected provider identity survives catalog changes

This records the bounded repair in [#47015](https://github.com/jeong-sik/masc/pull/47015)
for [#27898](https://github.com/jeong-sik/masc/issues/27898). The broader immutable
catalog, manifest and caller hard cut remains open.

## Observed failure and repair

`Binding_identity.of_provider_config` used the config's id to look up the
current global provider declaration. Replacing or removing that declaration
could change an already selected call's authentication, credential scope and
failure ownership. Provider labels could also acquire a later alias mapping.

The admitted runtime binding now attaches typed authentication and scope to
the config's existing opaque request-policy snapshot. Binding identity reads
that selection, actual endpoint and opaque credential without a catalog
lookup. Provider labels project the carried id. A fresh selection observes new
declarations; changing provider id or wire invalidates the old attribution.
Endpoint changes preserve provider ownership. No secret is copied into the
selection metadata. The unused reverse-lookup API is removed.

## Executed evidence

Every run below is the **Test** workflow, with ref
`fix/provider-binding-identity-20261101`. Checkout, requested suite, assertion
and suite-summary lines were read from the actual job logs.

| Run | Executed head | Actual result |
| --- | --- | --- |
| [41259248934](https://github.com/jeong-sik/masc/actions/runs/41259248934) | `98b63fc277c8e129415acb50e6a33e4a9efcb230` | FAILURE: attribution 15 PASS / 3 FAIL, 18 executed cases |
| [41259487017](https://github.com/jeong-sik/masc/actions/runs/41259487017) | `2db89555a45998a0b6ed08a0098a7b62b5c55a02` | SUCCESS: attribution 18 + runtime binding 34 = 52 PASS |
| [41259789315](https://github.com/jeong-sik/masc/actions/runs/41259789315) | `818c01e5f6dce6c2806d7cdcb9cb71f04076718e` | SUCCESS: attribution 18 + runtime binding 34 = 52 PASS |

The baseline requests only `packages/agent_core/test/test_provider_failure_attribution`.
Both corrected runs request that suite plus
`packages/agent_core/test/test_provider_runtime_binding`, with `minimal=true`.
The two 52-case runs are separate executions, not 104 distinct tests.

The three baseline failures are catalog replacement changing identity,
replacement before config construction changing the selected authentication,
and an unselected config acquiring later declaration ownership. Assertions
after each baseline failure did not execute. The corrected logs explicitly
reach scope retention, removal, fresh selection, provider/wire invalidation,
endpoint override, request-policy refresh and raw provider-label assertions.

The only `2db89555` to `818c01e5` source delta is a blank line disambiguating
the new interface docstring. An explicit local strict warning-50 parse reported
that ambiguity even though its parsing-only process exited zero; the earlier
Test run still succeeded. This is a strict-parser diagnostic correction,
not an observed CI compilation failure. All three changed interfaces passed
the explicit strict check with no diagnostic after the correction.

## Captures and provenance

[manifest.json](manifest.json) contains eight implementation/interface/fixture
SHA256 values for each source head, the requested suites and actual run
results, and capture digests. The three retained `*-selected.txt` files are
bounded derivatives: ANSI color was removed and checkout, selection,
assertion/failure and summary lines were selected. These are not full raw job
logs. The separately hashed decoded job-log captures remain in the campaign's
local `artifacts/` directory; those hashes describe captured UTF-8 text, not
the original HTTP response bytes.

The source/fixture changes compiled as dependencies of the selected executables
and their assertions ran in CI. No local Dune build, full regression, live
provider request, installed binary, runtime deployment or UI observation is
claimed. Independent source review and formal non-author approval are separate;
the latter remains required before the native stack can merge.
