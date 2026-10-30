# Parent integration provenance

This normal merge integrates parent #40214 at `16218a85f5d0a006032e0f1ab26ab56a2519dcdd` into #40256 head `0141cba19952bee2ca1f31ad33df9564726c40cf`.

The README, composition and source-hash manifest are retained byte-for-byte from that child head as a coherent historical evidence bundle. Their references to current source describe the recorded historical composition, not this merge. Parent-side copies describe an earlier source composition and do not supersede the child's later evidence refresh. No historical hash or check result is promoted to evidence for this merge.

The integration retains the parent's current-owner APIs, canonical diagnostic filtering and exact Keeper identity check alongside the child's shared regular-file reader. All Auth regression registrations are retained. Current validation is recorded separately in the conflict-repair ledger; no native execution, Dune build or CI result is claimed here.
