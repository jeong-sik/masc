# Catalog-owned exact binding

Source comparison base: `62e02218c2dcf761747caab21f9828d5f7ce65a1` (PR #45876).
Issue: #27898. This layer does not complete its consolidation/high-level API contract.

## Before and after

Before, `Model_catalog.of_model_entries` checked duplicate identities but accepted
raw model records without strict TOML field validation. Enumeration and exact
binding separately accepted `catalog` and caller-supplied `model_entries`. A
provider from one validated catalog could therefore be paired with a replacement
row list. This is direct source evidence, not an executed baseline exploit.

After, public nonempty catalog construction uses the strict TOML constructor.
The raw-record constructor is deleted. Enumeration and exact binding read only
the catalog's original rows. The redundant duplicate-model binding check and its
unproducible resolver outcome are removed; duplicate input is rejected by the
catalog parser. Runtime wizard enumeration, exact resolver, closed error
rendering and direct tests are migrated with the interfaces.

The 36 capability fixture rows retain their policies as strict TOML. Pricing
fixtures produce TOML too, preserving omitted fields and explicit zero. Review
caught invalid trailing-dot floats from `string_of_float`; the corrected fixture
formatter emits `%.17e`. No provider/model/catalog payload, endpoint, credential,
capability precedence or model alias is changed in the packaged declarations.

## Verification and limits

- All 13 changed OCaml files parse; current source hashes are in source-checks.json.
- Static Python TOML parsing accepts the 36-row fixture and nine existing pricing
  numeric values. This does not execute the OCaml decoder or inline tests.
- Existing duplicate tests now enter through the strict parser. The binding
  case interleaves two catalogs with identical IDs and different context values,
  checking original model/provider row identity, casefold and wire-byte retention.
- Independent adversarial review found the float-format issue; independent
  response review found no remaining P0-P2 after its correction.
- Selected production consumer execution will be requested after publication.
  At authoring, no corrected typecheck/test execution is observed. No local Dune,
  full regression, provider HTTP, CLI wizard behavior, installation or runtime
  deployment is claimed.

Local gh-stack init and remote link both refused because another live gh-stack
submit owns its global editing lock. Its process was not stopped or its lock
removed. This candidate can be published as a draft branch chain based on the
current #45876 branch; Native Stack membership must be confirmed separately.

## Initial execution failure and repair

Run 40153805828 actually checked out `20724a6803bdc6aa9b113a2791db98112c1f5133`
and FAILED before selected tests. A remaining inline negative case referenced
`test_catalog_entries` after that raw fixture list was removed. It now reads
`Model_catalog.model_entries test_catalog`, so it preserves the same declared
rows through the strict constructor. The initial runtime suite name was also
wrong; the actual direct runtime consumer suite is `test/test_runtime_per_keeper_routing`.
The retained compile-failure log records both, and the prior source verdict was
explicitly invalidated. No baseline or repaired execution success is inferred.
