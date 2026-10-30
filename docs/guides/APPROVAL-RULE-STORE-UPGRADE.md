# Approval rule store format cut

The approval-origin contract changes the approval queue to pending format
**13** (following format 12 in PR #43361). Remembered rules retain the canonical
`{schema_version: 1, rules, applications}` object.
Pending formats 12 and earlier and bare rule lists are refused. Format 13
requires explicit origin provenance on every pending or retained delivery entry;
old source attribution is never guessed. The new server preserves
unsupported files and reports a storage error; it does not migrate or reset them.
Existing workspaces cannot load their old pending approvals or apply, remember,
or renew their old standing rules until the operator chooses a reset. Postpone
deployment and keep the previous binary if that loss is unacceptable.

## Affected state

Use the affected runtime's `paths.effective_masc_root` from `/health?full=1`.
It is normally `<base-path>/.masc`, independent of the source checkout.

| Authority | Exact runtime path | State removed from active use by a reset |
|---|---|---|
| Approval queue | `<base-path>/.masc/gate/pending.json` | Pending approval requests, retained approved/rejected deliveries, unconsumed one-shot grants and their replay state |
| Queue append log | `<base-path>/.masc/gate/pending.log.jsonl` | Decisions and requests committed after the queue snapshot |
| Remembered rules and application receipts | `<base-path>/.masc/gate/always-allowed.json` | All remembered standing rules, their requested expiry and application/tombstone receipts |

The two format-bearing files are `pending.json` and `always-allowed.json`.
Treat the pending snapshot **and its append log** as one authority and reset
them together with the rules file. Do not retain new application receipts while
restarting the queue sequence from an empty store. `replay-results.json` is a
derived projection, not a replacement for the queue; archive it with the gate
state so old readback is not mistaken for a new decision.

The deployment `validate-stores` check decodes the snapshot and replays its
append log with the runtime's generation and final sequence checks. A valid
snapshot does not make a malformed or future-generation WAL acceptable.
Preflight refuses an incomplete WAL tail and leaves its bytes untouched for
owner recovery; it does not invoke startup recovery, install the queue or
create a reset. With no snapshot, it follows the runtime's reset semantics
and ignores an orphan WAL without deleting it.

This is deployment validation. Gate remains `Preflight_only` in the shared
store inventory, so its lane-local startup failure does not become a new
whole-server boot refusal.

## Operator-selected upgrade

1. Identify every runtime/base path to upgrade and stop all processes writing
   that workspace before changing files. Preserve the deployed binary version.
2. Back up the whole `<base-path>/.masc/gate/` directory outside the live gate
   directory with its private access permissions. Keep the archive for review
   of old pending requests, permissions and any external effects already taken.
3. After accepting the state loss above, move `pending.json`,
   `pending.log.jsonl`, `always-allowed.json` and the derived
   `replay-results.json` out of the live gate directory into that archive if
   they exist. Keep other gate mode/configuration files in place. Do not edit
   format numbers or synthesize application receipts in old files.
4. Start the new server on that same verified base path. Missing stores start
   empty and new writes use the canonical formats. Verify that pending-store
   installation succeeds and that rule readback reports an empty list without
   storage errors before resuming work.
5. Reissue still-needed requests through the normal Keeper/tool workflow and
   explicitly approve them again. Recreate each wanted remembered rule through
   approval with its deliberate expiry, or permanent approval when requested.
   An archived approval ID is not usable as a grant in the new empty queue.
   Review completed external effects before retrying an old request; a reset
   neither reverses an effect nor proves that retrying it is safe.

This PR performs none of these runtime operations. A merge is not an upgrade
or authorization to discard a live workspace's approvals.

## Recovery and rollback

If the new binary refuses the old format before a reset, stop it and continue
with the previous binary and the untouched original state. If a reset was
chosen and no new decisions or effects have occurred, stop all writers and
restore the complete matching archive together with the previous binary.
After new writes or effects, preserve both generations and reconcile their
requests/effects before choosing rollback; restoring an old snapshot over new
work can lose approvals or repeat an external action. Never feed old-format
files back to the new binary expecting migration.

## Receipt retention

Application receipts intentionally survive rule deletion and are currently
retained without compaction. A retained or delayed delivery may still return;
deleting its receipt could let an older decision overwrite or recreate a
permission. The store does not have an authoritative proof that every delivery
and restart replay using a receipt has retired. Receipt retirement and the
growth of the whole-file store remain follow-up work under #25483. Do not
remove individual receipts or truncate the file as a maintenance shortcut.
