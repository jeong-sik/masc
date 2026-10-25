# Explicit provider identity — issue #27898

Parent source: e9ae207275e0e3d2b1f1d25385158ce39048472f, PR #45872.

The model catalog still exposed two URL/host/request-path reverse lookup APIs.
Only the provider-config fixture called them, including an assertion that
preserved a declaration-order winner for an ambiguous base URL. Delete both
APIs and their implementation. Provider identity comes from an explicit ID or
typed anonymous wire, as current runtime bindings already require.

The host-inference declaration is removed from provider records, the strict
parser's allowed fields, packaged TOML and one runtime fixture. The catalog
evidence projection no longer fingerprints this removed field. Catalog and
selected-target generation hashes change with this source; no persisted-artifact
compatibility or old/new evidence equivalence is claimed.

The base-URL getter returned only entry.base_url and ignored its getenv argument.
Its three consumers now read that typed field directly. Actual endpoint bytes,
auth declarations, codec kinds, wire permission lists and all model payloads
are unchanged. identity_kinds remains authoritative for explicit wire selection.

Existing runtime binding cases cover endpoint-only configs without a binding,
explicit IDs sharing an endpoint, endpoint override without identity changes,
and unknown IDs refusing to switch by URL. Obsolete reverse-lookup assertions
are deleted; provider declaration/registry assertions remain.

Changed OCaml files parse and full-diff whitespace passes. Independent TOML
comparison confirms every model and every non-host provider field unchanged.
No local Dune, successful candidate suite, full executable build, provider HTTP,
merge, installation or deployment is claimed. Focused consumer checks are
requested separately. Issue #27898 stays open for immutable catalog/manifest
consolidation, remaining provider-independent API/high-level binding cleanup
and integration.

Parent catalog execution is now observed separately: run40149897587 at the
exact parent e9ae207275e0e3d2b1f1d25385158ce39048472f succeeded with catalog27,
capabilities124, modality7 and provider coverage115 cases (273 total). This
proves the corrected parent fixtures, not this deletion layer. Earlier six
suites262 passed at23e6 in an overall failed run. No combined current-head
execution or full-regression result is inferred from those separate runs.

## Observed compiler failure and resolver input hard cut

Initial run40150288619 checked out8b1230612ebe447d1d61ac48825508f647d60b6b
and FAILED before suite execution: deleting the getter left an unused local
getenv helper, fatal warning26. The earlier source PASS at8b is invalidated by
this actual compile failure; it never proved compilation.

The repair removes resolver_io and its load_resolver_snapshot argument, the
empty environment-observation fold, and the now-unproducible snapshot
Environment_read_failed variant. Public interfaces change first. Production
runtime/CLI and direct test callers migrate together; no ignored-argument or
compatibility adapter is introduced. Endpoints and credential facts already
arrive through typed target bindings. Credential_resolved/unresolved outcomes
and real runtime credential selection remain intact. Fixture-only getenv
stubs had no observation consumer and are deleted with the parameter; their
removal is not new proof of credential fault scenarios.

A focused follow-up is requested after this correction. No successful repair
execution or full executable build is claimed from source parsing.
