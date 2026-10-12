# Unknown checkpoint recovery

A checkpoint from an earlier server epoch remains **unknown**. A different epoch
is not evidence that the old server or worker has stopped, that a save/restore
had no effect, or that a retry is safe. F5 inspects the exact receipt; it does not
replay the checkpoint. An available committed receipt remains the preferred
online recovery path.

When no terminal receipt can be obtained, the supported escape is an offline
operator acknowledgement of one unresolved local intent. This acknowledges
uncertainty; it does not manufacture a completed or no-effect receipt.

1. Stop every server, MSX writer and TUI client that can access this workspace,
   including older server processes and clients on other hosts. Disable their
   supervisors/restart policies and verify process termination on every such
   host. Block external access to the workspace until recovery is complete.
   **If this cannot be established, keep the intent and do not proceed.** The
   script cannot establish this distributed operational precondition for you.
2. Preserve a backup of the workspace's MSX files and receipt database while all
   writers are stopped. Do not edit/delete `checkpoint-operations.sqlite3` or
   replay the old request. Inspect the receipt and checkpoint files; if their
   effect remains uncertain, keep that fact in the operator incident record.
3. Diagnose the *captured* canonical base path, canonical MASC root, operation ID,
   action and slot from the pending record. Paths below are operator variables,
   not default workspace locations. All five fields must match exactly:

   ```sh
   python3 scripts/acknowledge-msx-checkpoint-offline.py \
     --base-path "$checkpoint_base" --masc-root "$checkpoint_root" \
     --operation-id "$checkpoint_id" --action "$checkpoint_action" \
     --slot "$checkpoint_slot"
   ```

4. Copy the diagnosed `intent_sha256` into `checkpoint_digest`. After independently
   verifying step 1, explicitly acknowledge this request's unknown outcome:

   ```sh
   python3 scripts/acknowledge-msx-checkpoint-offline.py \
     --base-path "$checkpoint_base" --masc-root "$checkpoint_root" \
     --operation-id "$checkpoint_id" --action "$checkpoint_action" \
     --slot "$checkpoint_slot" --intent-sha256 "$checkpoint_digest" --apply \
     --writers-stopped-ack 'all checkpoint writers and TUI clients are stopped and cannot restart' \
     --outcome-ack 'acknowledge unknown outcome without replay'
   ```

   The tool first durably saves the exact original intent and acknowledgement in
   `<masc-root>/tui/checkpoint-acknowledged/<operation-id>.json`, then removes only
   that exact pending file. Other intents and the server receipt remain intact.
   Symlinks, mismatched bindings, changed contents and pre-existing archives are
   refused. If interrupted after backup, it fails closed: inspect the retained
   archive and intent before any further manual action; do not blindly delete
   either file or rerun with another operation ID.
5. Restart one intended server and a fresh TUI, verify its advertised workspace
   identity, and read the current machine in Observe mode before explicitly
   rearming control. Do not automatically resend the old save/restore. A future
   intentional checkpoint is a new operation with a new ID; the old receipt
   stays unknown and retained. Only restore network access/supervision after
   this verification.
