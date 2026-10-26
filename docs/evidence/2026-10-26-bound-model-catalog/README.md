# Selection-owned model policy — #27898

A selected provider declaration previously retained its endpoint/default while
`to_provider_config` looked up model policy from the current global catalog and
returned an unfrozen config. Catalog replacement before construction or before
later request preparation could therefore change the selected policy.

Baseline [40223999179](https://github.com/jeong-sik/masc/actions/runs/40223999179)
checked out exactly `13862dbd41ae7569bda8cfa2ae4dd7cf1be72753` and FAILED:
31 actual cases = 28 existing PASS + 3 new FAIL. Both replacement timings and
replacement-provider inheritance of the seed's bare-model authority failed.
These are executed failures, separate from source review and the inherited
MASC Librarian compilation failure in combined run 40222877344.

The immutable declaration selection now retains its model catalog and selected
provider declarations. A pure resolver uses that catalog, selected wire and
provider defaults with exact applicable model fields. Explicit wire-specific
bases retain precedence over model base presets. Overlay replacement clears
old aliases, wire bases and bare-model permissions. Explicit scoped model rows
remain applicable; undeclared model policy uses selected provider defaults.
Absent Anthropic thinking controls remain absent. No global model/manifest read
is performed by the selected-binding-to-config path.

Runtime bindings are private records carrying the owning selection. Config
construction installs the already-resolved request policy, including missing
controls, before later global mutations. Explicit endpoint changes retain that
identity-bound policy; changing provider/model/wire requires fresh resolution.
The root auth projection fixture now obtains real admitted bindings instead of
constructing public records.

Source reviewers found and corrected a no-model-row wire-base omission and a
stale storage-specific override assertion before final execution. Initial source
observations do not certify the corrected candidate. Changed sources/interfaces
parse and whitespace passes. No local Dune build or typecheck ran.

Focused mapping: captured declaration/model catalog → pure policy resolver →
Provider_runtime_binding.to_provider_config → public capability, forcing
admission, thinking control and actual schema serialization. Five new cases
cover pre/post construction replacement, overlay bare authority, absent
Anthropic control, and exact/missing-model wire bases. Existing declaration,
Pipeline and Cohere wire suites exercise direct policy/transport consumers.
Corrected execution remains unverified until its actual result is read. The
root auth fixture cannot be claimed executed while main's unrelated Librarian
consumer references a removed Core module (existing PR #46007).

This advances resolve-once selection, not complete model/manifest consolidation,
all high-level caller migration, live provider acceptance, installation,
deployment, full regression, formal approval, merge or issue completion.
