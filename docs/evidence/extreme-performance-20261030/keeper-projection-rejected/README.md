# Rejected eager Keeper-list indexes

This candidate was **rejected and removed from product source**. Preparing an
immutable index for every entire side input on each list preparation makes dense
large-query work faster, but increases allocation and strongly regresses small
query sets. The full 100 us goal remains open. No native product build or TUI
run was requested for this rejected candidate.

## Candidate and component boundary

The [patch](rejected-product-candidate.diff) is against
`d0a4db845644cf946f419b47687223700c7e79ce`. It adds a pure roster reader and
replaces repeated scans in `keeper_list_rows` with local immutable maps for
turns, waiting, approvals, task ID, awaiting-verification assignees, question
counts and async groups. Nothing survives a preparation. There is no new mutable
product field or retained cache. Source review found no new functional P0–P2;
that did not establish acceptable performance.

The component compiles exact selected before/after product function fragments
against reduced typed fixture records. Activity/date projection and sorting are
identical no-op stubs. This excludes their real cost and cannot prove full-module
type correctness, native TUI speed, applied UI population or physical paint.
The model metadata is compared by original fixture identity, deliberately
ignoring UI row order. Each execution passes the same 1,920 metadata/decision
cases, including empty Keeper fixtures, roster completeness, errors, duplicates,
declared keepers and unavailable observations, plus direct liveness comparisons. This is not complete
product feature coverage. No rendered text, layout or row-order assertions were
created. All five extracted modules compiled with OCaml 5.5.1 and
`-w +4+32+69 -warn-error +a`. Product files passed parsing only before removal.

The initial generator invocation used an incorrect working directory and found
no source files; [decision-v1.json](decision-v1.json) records that preparation
failure. The corrected component compile and execution receipts are retained.
No product Dune build was attempted.

## Synthetic input and measurements

In dense cases, **S is the size of each** roster, turn, waiting, approval and task
list; question rows number `2*S+1` including one unrelated installation, and
async rows number `3*S`. This is a deliberately dense synthetic configuration,
not a count of all side rows together or a measured production distribution.
Sparse cases retain only the S-row roster and omit the other side collections.
K is the number of original queried Keeper metadata objects. Fixtures are built
outside the measured loops. Batches alternate before/after order across five
rounds; the table reports medians of **per-call batch averages**, not individual
latency quantiles. CPU, every raw batch and all negative cases remain in
[analysis-v3.json](analysis-v3.json) and the two sample streams.

| Case | K / S | Before / after wall us | Before / after allocated bytes per call |
| --- | ---: | ---: | ---: |
| Empty | 0 / 300 | 0.003 / 0.002 | 32 / 0 |
| Dense | 1 / 1 | 0.127 / 0.384 | 672 / 1,816 |
| Dense | 2 / 2 | 0.239 / 0.931 | 1,312 / 3,768 |
| Dense | 30 / 30 | 35.507 / 39.456 | 19,232 / 116,408 |
| Dense | 300 / 300 | 3,368.778 / 732.782 | 192,035 / 1,686,875 |
| Dense | 3,000 / 3,000 | 426,595.667 / 11,460.625 | 1,920,176 / 21,881,816 |
| Sparse | 300 / 300 | 196.871 / 97.194 | 132,033 / 224,409 |
| Small query, dense large sides | 2 / 3,000 | 132.917 / 10,263.196 | 1,326 / 20,874,358 |
| All declared, dense | 300 / 300 | 4,045.668 / 1,116.652 | 172,835 / 1,682,075 |
| Additional dense side check | 1 / 300 | 4.709 / 316.176 | 673 / 1,586,409 |
| Additional dense side check | 2 / 300 | 11.092 / 318.154 | 1,313 / 1,586,745 |

The last two cases are a separate second execution after the S=3,000 regression;
they check the issue with 300 rows per main side list. They do not replace v1 or
make either run controlled production evidence. Small-query names match the first one/two entries in each main
side list, making the negative result conditional on that early-hit fixture;
production query/hit-position distributions remain unmeasured. Shared host scheduling/load is
uncontrolled. The environment record is explicitly a later read. Wall uses
Mtime; CPU uses `Sys.time`; allocation uses `Gc.allocated_bytes`. Probe accounting
overhead is amortized across each batch and is not subtracted. Small-call figures
are especially sensitive to that overhead and clock resolution. The denser large
cases use fewer iterations, as recorded, and do not support stable tail claims.

At K=S=300, candidate CPU batch average falls from 2,845.0 to 600.2 us, while
allocation grows about 8.8 times. At K=2/S=300 the later CPU values are
11.1/315.9 us and allocation grows by over three orders of magnitude. The
candidate builds indexes for unrelated names, including cases where the original
first-match scans stop almost immediately. This measured component tradeoff
is enough to reject this implementation; it does not establish a native UI
regression multiplier or a chosen replacement architecture.

## Retention and reproduction

[provenance.json](provenance.json) binds 25 exact selected source/capture pairs
read after execution. Earlier subset manifests remain separately. The earlier
combined analysis-v2 and provenance-v2 incorrectly described their scope as one
execution; analysis-v3 and the current manifest correct that wording. V3 binds both executions' metadata checks without changing
the numeric results. V1/v2 raw samples and execution receipts are unchanged.
Original candidate full-source snapshots and native component binaries stay in
ignored `artifacts/`. The retained patch plus the historical base reconstruct the
candidate; [source-identity.json](source-identity.json) records full input hashes.
[Patch reconstruction](patch-reconstruction-v1.json) in an isolated temporary
Git index matched all three frozen candidate file hashes without changing the
working tree or compiling the product.
These later hashes do not invent independent capture-time provenance.

For a new component invocation, copy the retained `fixture_types.ml`, both
`control_*.ml`, both `projection_*.ml`, and the desired benchmark driver into a
new ignored directory. Compile those five modules in that order, then link the
driver with `ocamlfind ocamlopt -package unix,mtime.clock.os -linkpkg` and the five
`.cmx` files, using the same warning flags. Redirect the new binary's output to
a new sample file. Never overwrite the retained sample or execution receipts.
`prepare.py` is the capture-time extraction recipe: it unconditionally overwrites
the five generated fragment/fixture files and `source-identity.json` beside
itself. Never execute it inside this retained bundle. Re-extraction requires a
separate checkout at the recorded base with the candidate patch applied, plus a
copy of `prepare.py` in a new ignored output directory. It is not a regeneration
command for the restored product tree. No credentials, private conversations, native product binaries or
runtime state are selected in this component bundle.

Query-scoped indexing and immutable producer-owned prepared readings remain
proposals. Their next comparison must include preparation/fetch cost and memory,
failure/reset/workspace ownership, duplicate and partial-reading semantics, and
both small query sets and full fleets. Warm lookup wins alone cannot select one.
