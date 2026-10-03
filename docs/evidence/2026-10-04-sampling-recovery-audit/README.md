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
