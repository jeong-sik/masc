# Recover an acknowledged Memory admission frontier

`admission receipt recovery required` means accepted pending writes are preserved,
but the queue cannot prove which earlier writes already committed. Do not reset the
queue, manufacture a receipt, replay the acknowledged prefix, or infer Memory from
the pending tail. A missing snapshot cannot be reconstructed from the journal: the
journal does not contain the complete snapshot.

This is a supported **offline exact-backup recovery**, not automatic reconstruction.
It requires a coherent, product-validated backup of the same Keeper's current
snapshot, committed range receipts, admission queue and journal. The operator must
establish that this is the last committed snapshot before damage, using the stopped
writer interval and an independently retained snapshot SHA-256/backup inventory.
A hash recomputed only from the candidate backup is not that independent evidence.
If newer commits may have occurred without preserved evidence, stop: this tool
cannot prove absence of lost writes and must not be used to authorize rollback.

The tool supports only `masc.memory-admission-recovery.range-v1`, the contiguous
explicit-write range schema. Sparse candidate receipts or another queue schema are
rejected. A later runtime needs a separately reviewed recovery contract; do not
rename fields or translate receipts to make this tool accept them.

1. Resolve the affected workspace and effective configuration keepers directory.
   Stop every server, Keeper, Librarian and other writer sharing these stores.
   Preserve an immutable incident backup of the entire base/config/runtime tree,
   including damaged files, permissions and a hash inventory. Work on another
   offline copy. Neither input below is a live directory.
2. Locate the independently attested coherent backup. Its queue generation and
   acknowledged frontier must equal the incident queue's. Any saved pending prefix
   must remain identical; additional accepted tail rows are allowed and preserved.
   Its committed explicit-write receipt must name that exact frontier and bind
   the exact backup snapshot revision **and raw-byte SHA-256**. Prepared receipts
   are not authority. The journal must be present and byte-identical in both
   copies, with latest committed revision equal to the snapshot's. This deliberately
   refuses even benign changed journals rather than guessing a recovery cut.
3. Prepare a new copy with Python 3 (standard library only):

   ```sh
   python3 scripts/maintenance/recover-memory-admission.py \
     --format masc.memory-admission-recovery.range-v1 \
     --current-copy /path/to/offline-incident-keepers \
     --backup /path/to/attested-backup-keepers \
     --output /path/to/new-recovery-bundle \
     --keeper keeper-name \
     --expected-snapshot-sha256 HASH_FROM_INDEPENDENT_BACKUP_RECORD
   ```

   This writes only the previously nonexistent output. `repaired/` preserves all
   incident files and pending queue bytes, replacing only the snapshot and receipt
   from the attested backup. `original/` retains replaced bytes that existed.
   `manifest.json` records before/after hashes and the two replacement paths.
   Missing receipts and missing/non-JSON snapshots are supported. A different
   surviving receipt or any different JSON snapshot is refused: it may contain
   newer Memory. Symlinks, shared hardlinks and changed inputs are refused.
4. Check the manifest against both frozen inputs. Only its two replacement paths
   may differ; the queue and every other file must be byte-identical. Place those
   replacements into a separate copy of the full base/config layout and run the
   **matching runtime's** production decoder preflight there:

   ```sh
   masc-deployment-preflight-helper validate-stores --base-path /path/to/full-offline-base
   ```

   Use the effective config layout for that copy; do not accidentally point its
   configuration at the live base. The Python tool verifies recovery binding and
   preserves opaque payload bytes; it does not replace all native fact/snapshot
   semantic validation. A decoder refusal ends the recovery attempt. Never start
   a Keeper or model merely to validate a speculative snapshot.
5. With all live writers still stopped, compare live file hashes to the incident
   manifest. Abort on drift. Install only the two verified replacement files using
   same-directory private temporary files, file fsync, rename and directory fsync.
   **Do not install the copied admission queue**, even if it looks identical.
   Verify hashes and run the matching production decoder preflight before resuming.
   If interrupted or validation fails, keep writers stopped and restore original
   bytes (or original absence) for both files. Preserve the incident backup.
6. Resume the normal worker. Its existing committed-range check confirms the
   acknowledged prefix without judging it again; only the unchanged pending tail
   may be dispatched. Observe the unavailable state clearing and the next durable
   receipt/queue acknowledgement. These are required deployment observations, not
   results already established by source review or this runbook.

If no coherent, latest attested backup exists, report the affected Keeper and
frontier as unrecoverable from available evidence. Keep accepted input and all
remaining records. This procedure never turns that uncertainty into permission to
lose facts, reset sequence/generation, or duplicate previously consumed writes.

## Reproducible verification boundaries

`python3 test/test_memory_admission_recovery_tool.py` executes synthetic offline
cases: exact byte restoration, pending-tail retention, and refusal of changed
frontier/generation/journal, different snapshots/receipts, unsupported schema and
unsafe filesystem entries. It makes no native-worker execution claim.

`test_keeper_memory_admission_queue.ml` additionally creates a backup through the
real Current/Queue APIs, loses the snapshot/receipt, invokes this Python tool, and
feeds its repaired copy to the real decoder and worker. It asserts that only the
pending tail reaches judgment. That native regression is source evidence until
its matching-head test is actually executed under the repository workflow.
