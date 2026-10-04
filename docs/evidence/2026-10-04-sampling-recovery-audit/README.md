# Sampling cold recovery (audit L3)

Source reviewed: `4b640af170e5ef180064302a4840e57d80498b76`.
Parent: `ec0275ed4b8e6450ded83eb60d9728d38400d1b1` (#40991).

Production startup runs `Lane_addon_runtime.recover_sampling` before the
configuration service; its existing maintenance pulse retries recovery. Recovery
streams each producer's journals with a per-record bound derived from its reply
limit (request metadata plus worst-case JSON string escaping), verifies exact
identity and durable bytes, repairs missing/corrupt outcomes, and compacts only
after successful durable publication. Query aggregate accounting is unchanged.
A bad request does not prevent other requests from recovering in either index
directory. Intact canonical/fallback files are verified without replacement;
corrupt regular canonical bytes are repaired before compaction so they cannot
consume the query allowance before the good fallback. Nonregular canonical
paths remain compatible with fallback reads.

Independent adversarial source review found no remaining P0/P1/P2 at the source
head above; previous FAIL findings and their corrections are retained in
`source-review.json`. This is not a GitHub approval or cross-model claim.

Nine changed OCaml files passed parsing. This only checks syntax; native
compilation and execution have not run. No local Dune build or CI was invoked.

The authored runtime regression has 22 scenarios: both request/outcome hash
orders, primary/terminal index placement, absent/canonical/fallback/corrupt
canonical/nonregular canonical blob placement, an escaped journal larger than
the query allowance, and corrupt terminal siblings next to a healthy primary.
It calls the public recovery function after a manager reset, then the actual
bounded receipt reader and historical Slice/Evidence/export paths. It checks
exact bytes, preserved intact inode, a repeat cold read and unchanged fake
observer invocation count. Additional source/worker regressions cover digest
rejection, bounds and sync failure. These are authored test cases, not test
passes. The fixture observer count does not establish a real provider trace.

Actual server bootstrap/pulse execution, power-loss behavior, and automatic
reattachment of old producer output to a new live downstream installation are
not verified. This change enables historical reads; it does not implement that
separate automatic downstream continuity behavior. Root-parent durability work
in #40862 overlaps this stack and must be reconciled before integration.

## Current parent integration

The review/parser receipts above describe the historical source heads, not this
integration. Current parent #40991 is
`3b783a3328a1690cd98f9cfde6dca06f1ef8fd2e`; its typed request-ID/full-frame
sampling boundary remains intact.

The initial recovery attempt now completes before `publish_server_state` and
owner readiness in the actual bootstrap caller. The maintenance pulse retries
incomplete records. Existing inline outcomes are verified with the strict owned
file/digest/fsync/root-identity guards without charging their already-read bytes
twice. Valid-file verification errors propagate; directory publication blockers
may use an owned fallback, while unsafe links remain errors.

Local focused OCaml 5.5.1 build passed. Worker 28/28, runtime 22/22, source
provenance 15/15, server sampling 17/17 and MCP integration 27/27 tests passed
(109 total). The worker regression covers an uncompacted 3 MiB inline journal
with an existing outcome under the unchanged 4 MiB allowance, intact inode,
and cold-reader root-sync failure/retry. The runtime/source tests exercise public
recovery and historical consumers; they do not execute the complete server
bootstrap process or prove power-loss/deployment behavior.

An initial integration worker run exposed fixture state interaction: cold read
compaction removed the interrupted inline state before the parent's strict
iterator checks. The fixture now recreates that state before those checks; all
original sync/link/root assertions remain and the final complete suite passed.

Independent integration review identified an oversized owned canonical outcome
that maintenance still refused before applying its repair policy. The appended
byte regression failed before repair (1 focused case, 1.118s). Startup recovery
now durably rewrites that proven-corrupt owned regular file; cold queries still
refuse it and preserve its bytes. Unsafe links and valid-file fsync/identity
failures are unchanged. The recovery fixture now covers 26 scenarios, including
both hash orders/index locations for the oversized canonical plus valid fallback.
The corrected tree's focused build and all 109 tests passed again: worker 28
(7.382s), runtime 22 (7.162s), sources 15 (0.176s), server sampling 17 (0.430s),
MCP integration 27 (0.176s). These remain fixture/native evidence with the
bootstrap/deployment limits above.
