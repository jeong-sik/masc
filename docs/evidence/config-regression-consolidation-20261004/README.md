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

`python3 check-config-tests.py CHECKOUT CACHE_CHECKOUT provider|boot` runs isolated native
suites without Dune. It creates and prints its own temporary directory. Provider
mode compiles the candidate Runtime_toml implementation against the unchanged
cached public signature (the candidate interface differs only in documentation),
then uses cached lower dependencies, including the source-identical Runtime loader.
Boot mode rejects mismatched source/interface copies for all eight configuration
owners and direct consumers (16 files), then compiles their candidate implementations
and the complete test suite. Other dependencies remain cached. Both modes are parsed
with explicit choices; an unknown mode is refused before compilation. The account suite uses
the same MASC_TEST_RUNTIME_SEED setting as its committed Dune stanza.

The two modes need coherent caches for their respective source versions. Initial
attempts found an incompatible Runtime_schema cache, missing native link packages
and test stubs, and an omitted seed environment variable. These harness failures
are not product failures. Full product, provider activation, CI, runtime deployment
and independent source approval are not claimed. Prior review agents exhausted
their session quota; this change has self-review only pending independent review.

## Runner review response

The corrected runner passed all 80 cases again. Boot mode checked all 16
owner/consumer source and interface files and compiled the eight candidate
implementations before running 53 tests. Provider mode checked the cached Runtime
loader source/interface and passed the 14 + 13 suites. `runner-refusals.json` records
the rejected unknown mode and deliberate source mismatch; neither reached linking.

## Current parent integration

The original cache-runner manifests/results above are historical evidence for
their recorded source states. This integration uses parent #41048
`fe81b2ef68d62c47ff37828274ff692b719c5537`. Its production source, interfaces,
configuration and provider `request-path` repair remain unchanged. The adjacent
namespace conflict keeps both the parent's valid-path/typo regression and this
child's model-set/table-form/file-loader checks.

The inherited zero-retention test is now explicitly named legacy JSONL rotation;
it exercises `append_jsonl_line`, while the separate dated-store test exercises
`append_keeper_metrics` and the shared public reader. Assertions are unchanged.

Local focused OCaml 5.5.1 repository-wrapper build passed. Namespace 15/15
(0.005s) and boot TOML overrides 55/55 (0.025s) tests passed on the integrated
sources: 70 newly executed native tests. Parent account declaration 13/13 and
runtime validity 144/144 evidence may be reused only because their source and
production dependencies are unchanged; those suites were not rerun here. The
historical cache harness was not rerun. No full build/suite, provider activation,
installed runtime, deployment or release proof is claimed.
