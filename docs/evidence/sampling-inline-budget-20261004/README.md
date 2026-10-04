# Sampling inline-journal query accounting

Parent #41033 at 0783e7d4f5fae24719b7c106225287b0188df847 fails 6 of the 11
new receipt recovery cases. Candidate: 11/11 pass, including both evidence hash
orders, missing/canonical/fallback blobs, failed optional disk compaction,
reopened reads, independent outcome inode preservation, aggregate over-limit
refusal, oversized journal refusal and charging a failed durability read.

Recovery now has an explicit per-file I/O envelope equal to the query's initial
limit (an existing outcome is further bounded by the verified inline size).
It verifies journal identity/durability and a durable outcome, then presents a
compact receipt even if optional disk compaction fails. Query accounting charges
that receipt and the one outcome payload through the existing shared blob cache.
Recovery does not reset or increase the remaining query allowance. Repair I/O is
separate bounded work; this is not a claim that total physical repair+query I/O
is at most the query reply envelope. Journals themselves larger than the initial
per-file envelope remain refused and require the existing maintenance recovery.

The complete current Lane_addon_store is natively compiled. Execution uses the
exact retained_receipts function extracted from current Lane_addon_sampling and
the complete registered test suite with module aliases, against real files and
cached lower dependencies. The complete candidate sampling .mli/.ml separately
passed typechecking with the candidate store and cached interfaces. No replacement
storage behavior is used. Runner: CHECKOUT CACHE_CHECKOUT [SOURCE_REF]; the optional
source ref reuses the candidate tests against parent product sources. The runner
creates a fresh directory under the system temporary root, prints its path, and
returns the test exit status; no pre-existing report directory is required.

This proves bounded local storage-to-receipt behavior, not a full server, actual
provider/Docker run, startup race, independent approval, merge or deployment.

## Current parent integration

The manifests and extracted-consumer runner results above are historical. This
integration uses parent #41033 at
`0c984e316874d6af6ffe22430bd6b11b3e61ba2c`. Conflict resolution retains its root
durability obligation and strict owned-file verification, including startup-only
oversized corruption repair. The child keeps its separate journal per-file bound,
compact-receipt accounting, and unchanged aggregate outcome allowance.

The repo-local focused native build passed for the four relevant executables.
Using the declared test environment, receipt recovery passed 11/11 (1.917s),
worker recovery 28/28 (7.922s), runtime 22/22 (7.656s), and source provenance
15/15 (0.196s): 76 tests total. These execute the integrated store and consumer,
including the parent's strict recovery regressions. No full suite, complete
server bootstrap, provider/Docker execution, deployment or release is claimed.
