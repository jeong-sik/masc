# Consolidated configuration regressions

Canonical implementation: merged K1 #41047 (`4b87f3d73ca7212ad0d883a20467bf7b56cef962`)
and open K2 #41048 (`d465e05bdce78cce11fcebc5993d61835a8b2625`). This change is a child
of K2 and changes tests only, preserving the useful additional coverage from
#41060 and #41062 before retiring those duplicate PRs.

## Source comparison

`comparison.json` records both duplicate heads, their own-change parents and
complete own-diff digests. #41060's current GitHub base moved after it was authored;
its own two commits are isolated from inherited Board/Cron/IDE/Goal changes.
Those inherited changes retain their original PRs and are not discarded here.

- #41060's seven lazy settings and consumer wiring are covered by merged #41047.
  The canonical implementation additionally handles supervisor interval bounds
  and strict environment validation at boot, the two remaining #41060 findings.
  The removed debug alias stays removed; tests use the canonical debug reader.
- #41062 and #41048 validate the same provider field set before decoding.
  Both preserve protocol-specific field validation and structured non-table
  refusals. The canonical parser and account-copy rejection remain unchanged.
- Preserved K1 checks exercise reading before boot, actual append/rotation data,
  a later file edit remaining pending restart, and environment priority in both
  the heartbeat consumer and settings projection.
- Preserved K2 checks cover canonical/misspelled model-set names with and without
  explicit bindings, inline/dotted/nested unknown fields, account_home, scalar
  providers, and the file loader's file-path plus field-path diagnostic.
  The file diagnostic test explicitly depends on `masc.string_util`.

No retention behavior is changed. The zero/reduced-backup retention repair remains
in #41096, and dated-store retention remains in #41111/#41125.

## Results

- Provider namespace: 14/14 passed, including the additional table forms and
  actual file-loader diagnostic.
- Account declaration: 13/13 passed, including all shipped seed clients.
- Boot TOML overrides: 53/53 passed. The combined environment-priority scenario
  resets the test boot snapshot before simulating its separate startup; an initial
  attempt correctly reported zero newly installed overrides for a repeat load.
- All ten source comparisons in `cached-source-identity.json` match. Full native
  output and per-mode manifests are retained alongside this document.

## Validation method

`check-config-tests.py CHECKOUT CACHE_CHECKOUT provider|boot` runs isolated native
suites without Dune. It creates and prints its own temporary directory. Provider
mode compiles the candidate Runtime_toml implementation against the unchanged
cached public signature (the candidate interface differs only in documentation),
then uses cached lower dependencies, including the source-identical Runtime loader.
Boot mode compiles the complete candidate test suite against cached product objects;
source copies for the configuration owners and direct consumers are checked against
the candidate. It does not rebuild those product modules. The account suite uses
the same MASC_TEST_RUNTIME_SEED setting as its committed Dune stanza.

The two modes need coherent caches for their respective source versions. Initial
attempts found an incompatible Runtime_schema cache, missing native link packages
and test stubs, and an omitted seed environment variable. These harness failures
are not product failures. Full product, provider activation, CI, runtime deployment
and independent source approval are not claimed. Prior review agents exhausted
their session quota; this change has self-review only pending independent review.
