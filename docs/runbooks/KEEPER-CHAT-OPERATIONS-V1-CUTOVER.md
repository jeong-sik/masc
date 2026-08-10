# Keeper Chat Operations v1 Cutover

This is a one-way maintenance-window hard cut. It archives removed storage; it
does not import, replay, or translate any chat work.

## Preconditions

1. Record the deployed SHA, `GET /health?full=1`, and checksums of Keeper meta
   and chat storage.
2. On the old binary, stop intake and verify every old queue has zero `pending`,
   `inflight`, and `recovery_required` rows. Audit every direct-delivery marker;
   all marker directories must be empty.
3. Stop the old binary with the repository stop script. Verify that no process
   holds the BasePath lease.
4. Prepare the strict v1 Keeper meta snapshots separately. The new binary does
   not decode or rewrite an older meta contract.

## Archive and start

Build the typed helper, choose a new timestamped destination, then run the
archive while the canonical BasePath lease is held:

```sh
scripts/dune-local.sh build bin/deployment_preflight_helper.exe
archive_dir="/absolute/base/path/.masc/archive/keeper-chat-cutover-$(date -u +%Y%m%dT%H%M%SZ)"
_build/default/bin/deployment_preflight_helper.exe lease-run \
  --base-path /absolute/base/path \
  -- \
  scripts/archive-keeper-chat-cutover-v1.sh \
  --base-path /absolute/base/path \
  --archive-dir "$archive_dir"
scripts/check-runtime-deployment-preflight.sh --base-path /absolute/base/path
```

The archive command refuses active queue rows, nonempty direct marker
directories, symlinks, an existing destination, or execution without the exact
BasePath lease. It preserves paths below `.masc`, writes preflight/postflight
reports, and seals the archive with SHA-256 checksums.

Start the new binary only after the deployment preflight passes. The server also
performs the same read-only inventory before installing any Keeper Owner and
will not become ready while an archive artifact remains.

## Smoke and rollback boundary

Verify one Keeper through submit, Running, streamed tool/text progress, and
Succeeded. Then verify queued edit, move-to-end, cancel, and reconnect lookup by
operation ID. Confirm only `chat-operations.sqlite3` is open.

Rollback to the old binary is permitted only before the new binary accepts its
first operation. Restore the untouched archive before such a rollback. After
the first acceptance, repair forward.
