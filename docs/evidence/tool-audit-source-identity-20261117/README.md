# Bind the latest tool audit to the retained files

The previous audit cache reused its result when the store's total physical row
count stayed equal. The official metrics writer can rotate and prune
`[old, mid]` into `[mid, new]` while retaining two rows. The cache then returned
`mid`, even though a strict read returned `new`. It could also bypass a storage
error in an older file outside the operator's recent 120-row read.

The source at `65fb3632077d87be2009fb5fcf9a510051cec25f`, based on
`bf7d4b468b7a6f8cb9b7a450d74c8e08ab2b7957`, replaces that integer identity with
a Dated_jsonl-owned strict latest view. [Source hashes](source-inputs.json)
bind the actual production files and maintained tests. Later changelog-only
commits do not rerun these observations.

## Source behavior

Each read lists the strict month/day order and opens verified regular handles
before reusing a file's result. The view keeps device/inode, size, modification
and change times, whether the previous extent ended in a newline, and the
selected value or `None`. Changed identity, shrinkage, same-size metadata edits
and incomplete-tail appends rescan that file. A valid append after a complete
extent reads only its suffix and falls back only to that same file's previous
selection. Removed paths supply no result. A successful read retains only the
files it visited; the consumer retains its existing 256-store cap.

No complete retained-row count precedes a latest lookup. Repeated sparse or
no-match reads reuse file-local `None` results instead of decoding all older
rows. This establishes the intended work path, not a measured CPU speedup.
Metadata/open costs remain, and no before/after timing or memory benchmark is
included. Metadata is not a content digest: prefix edits combined with growth
are outside the documented append-only contract.

## Executed evidence

- **Baseline defect:** R6 used the real public config/backend and
  `Keeper_metrics_storage` writer with explicit owned paths and pre-write
  path assertions. Rotation/pruning kept count 2; the baseline audit stayed
  `mid`, while the strict latest result was `new`.
  [Selected output](baseline-result.json) omits host paths and retains the
  original stdout digest. R6 reused the exact complete baseline
  Keeper_status_metrics ML/MLI objects compiled in R1.
- **Core typing:** R3 compiled the full actual baseline/candidate Dated_jsonl
  ML and MLI under fresh basenames, using real existing prebuilt dependencies
  and generated wrapper aliases. Fatal warnings 4, 8, 32 and 69 remained on.
- **Core behavior:** R5 executed two complete existing maintained cases against
  baseline, and those same two plus three complete new cases against candidate.
  Helpers and case bodies were copied verbatim with leading module aliases.
  The cases cover reverse chunk joins/order, sparse `None` reuse, short and
  multi-chunk append suffixes, valid unterminated rows, incomplete-tail
  completion, replacement/truncation, cached-`None` replacement and a cached
  older-file symlink error.

R5 has five successful operations: corrected maintained-test compile, runner
compile, link and two separate fresh processes. It reuses unchanged full Core
objects from R3; it is not a fresh full rebuild. The retained outputs are
[baseline stdout](run-base.stdout), [candidate stdout](run-test.stdout),
[baseline stderr](run-base.stderr) and [candidate stderr](run-test.stderr).
The two and 24 stderr lines are normal Alcotest ASSERT traces; line count is
not case count. [Receipts](native-receipts.json) retain every attempt's terminal
result and command/output digests. The argv digest uses compact UTF-8 JSON;
full argv and local captures remain private artifacts.

This is **seven calls of five distinct Core cases**, not the whole declared
Dune target. The fixed Keeper consumer and its maintained rotation/prune case
have not been executed. Broad real prebuilt dependencies do not prove a clean
dependency/ABI rebuild. No CI, installed candidate, runtime recovery, CPU share,
RSS benefit, cancellation stress or concurrent-publish stress is claimed.

## Corrections retained

[Failed attempts](failed-attempts.json) preserve the fatal test warning in R2,
the same-process temporary fixture collision in R3, and the fixture callback
error in R4. The final test fixes retain their assertions and do not suppress
warnings. Independent source review also caught a candidate channel acquired
on a cancellable worker before caller cleanup was installed. Acquisition now
stays in the caller's existing strict-reader scope, before the first yielding
use; this correction was source-reviewed, not cancellation-stress-tested.

R1 also had an execution-scope mistake: ambient base discovery redirected its
requested artifact fixture to the operator runtime root. It created a new
`owned-cache-probe` metrics directory. The exact generated row hashes and
directory birthtime were checked, no Keeper config or open files were found,
and that newly created directory was atomically moved to private artifacts.
Its two retained rows total 392 bytes. R1 must not be described as isolated.
R6 replaced ambient discovery with actual explicit config/backend construction
and verified both config and store paths before writes. Original R1 captures
were preserved rather than relabeled as the corrected execution.

The [source review](source-review-r1.json) and
[response review](response-review-r1.json) bind their listed snapshots and
limits. [Review provenance](review-provenance.json) records the original
private report digests and any selected derivative changes. These are
independent session reports, not current-head GitHub account approvals.
