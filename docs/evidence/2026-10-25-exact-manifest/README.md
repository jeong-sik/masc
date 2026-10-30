# Exact capability manifest identity — 2026-10-25

Issue #27898. Source base `c75ee3febdb834225ff905020add4cecd2e5264b`.
Duplicate normalized declarations were already repaired by merged #45780.
The remaining manifest lookup used the first declared matching prefix.

## Observed defect and corrected authority

The source-bound before run uses the actual production manifest, identifier,
vocabulary and effort modules/interfaces. It proves an undeclared suffixed ID
inherits a tool capability and reversing two distinct declarations changes the
capability chosen for an explicitly declared target. No provider call, Core
link or request resolver is involved in this standalone reproduction.

Schema version 2 uses `model_id : Model_identifiers.Model_id.t` and equality
from that same type for lookup and duplicate checks. ASCII case equality is
retained; no family, suffix, separator or provider-name reconstruction occurs.
The root requires an explicit models list. Empty is explicit; absent/null is
rejected. Older schema or prefix fields fail instead of being converted.
The manifest remains opaque and installed only through validated parsing.

Update the public interface, direct SDK fixtures and active guide/example
schema together. Existing field-behavior fixtures declare their full intended
targets rather than depending on inheritance. The catalog-precedence test now
still declares the exact same target in both sources, so it tests precedence
rather than accidental manifest absence. Core tests additionally cover exact
order independence, unknown variants, qualified exact IDs and strict schema.

## Source-hashed standalone execution

```
python3 docs/evidence/2026-10-25-exact-manifest/run_fixture.py --source-ref c75ee3febdb834225ff905020add4cecd2e5264b --before
python3 docs/evidence/2026-10-25-exact-manifest/run_fixture.py
```

`before.json`: both historical defect observations reproduced.
`result.json`: 14 corrected parser/lookup checks passed. Only inline-test
extensions are excluded for standalone compilation; production module bodies
and interfaces are compiled and their original/compiled hashes retained.
The runner uses temporary outputs, not a local Dune or project build.
This is not actual Core/request-policy consumer execution, full regression,
server build, provider HTTP, installation or UI proof. Selected SDK consumer
suites require a separate recorded result.

## Original scope remains open

This unit removes prefix authority from the capability manifest. Model catalog
family matching, catalog/manifest consolidation and remaining resolved-binding
cleanup are not completed here. No full #27898 closure is claimed; current
provider ownership and model-catalog precedence remain separate contracts.
