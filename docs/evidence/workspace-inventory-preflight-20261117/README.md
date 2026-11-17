# Workspace inventory preflight consumer

The HTTP workspace-memory-inventory route previously called the complete
`Ledger.observe` before every cache lookup, but used only its unavailable state.
It now calls `Ledger.check_readable` through the existing
`Domain_pool_ref.submit_cpu_or_inline` helper. Parsing and strict validation use
CPU weight; read/background lane selection and existing worker/non-Eio/absent
pool fallbacks remain centralized in that helper. It executes once and preserves
exception propagation and cancellation settlement.

The fresh regular-file/read/decode check still precedes the cache. Ledger
corruption returns the same 503/error JSON. Missing ledgers in existing
workspaces proceed. Cache key, TTL, invalidation, inventory producer and ETag
handling are unchanged. A corrupt briefing does not make the ledger unreadable,
as in the previous availability decision. No availability snapshot is cached.

The [core bundle](../workspace-ledger-readable-20261117/README.md) retains the
46-assertion old/new fixture, complete maintained 19-test suite and isolated
CPU/allocation experiment. Those reductions apply to the gate, not this HTTP
route or the whole server.

[native-verification.json](native-verification.json) binds the exact consumer
ML/MLI and Core hashes. The complete unchanged original MLI and complete changed
ML compile natively against compatible prebuilt dependencies and the fresh Core
module. Only `open Masc` and a named Ledger alias are added. This repeated check
uses the curated recipe without previous experiment include directories; it is
not a product rebuild.

[source-review.json](source-review.json) records the independent no-P0/P1/P2
source review of the original source-only commit and validates the terminal
19-test receipt. It does not approve subsequent packaging commits. The retained
review is a derivative with only its host worktree path replaced; its original
digest is included. Source hashes remain the binding across packaging/rebase.

The Core `replay.py --consumer` additionally compiles the complete consumer from
the supplied checkout and records its actual source hashes; compare them with
this receipt. It does not execute HTTP/cache-hit/304 handling or real pool
dispatch. No product build, full regression, install, restart, provider or live
CPU/RSS recovery is claimed. Those remain separate runtime verification work.
