# Event Queue v8 to v12 migration

This is the pre-deploy runbook for the current-only Event Queue contract.
Run it before deploying a binary that accepts only
`keeper.event_queue.state.v12`.

The migration preserves `revision` and every pending stimulus. It refuses a v8
snapshot with an unprojected transition because silently dropping or
reinterpreting that receipt would violate exact replay.

## 1. Dry run

Use the same base path as the production process:

```sh
scripts/migrate-event-queue-v8-to-v12.sh --base-path /Users/dancer/me
```

The command must report every snapshot as v8 or v12 and print the total pending
stimulus count. Do not continue on an unsupported schema, malformed snapshot,
or non-empty v8 transition outbox.

## 2. Stop the service

Use the existing script-based stop/status workflow. Confirm that the production
PID is gone and port 8945 has no listener. Do not run the migration while any
process can write Event Queue state.

## 3. Apply and deploy

```sh
scripts/migrate-event-queue-v8-to-v12.sh \
  --base-path /Users/dancer/me \
  --apply \
  --confirm-stopped
```

The command validates every input before writing, stores the original bytes
under `.masc/migrations/event-queue-v8-to-v12/`, renders and validates all v12
snapshots, then replaces each file atomically. Keep the printed backup path.

Start the v12-capable binary immediately after the migration. Do not restart
the old v8 binary against migrated state.

## 4. Verify

Check the health endpoint and Keeper registration after startup. Also confirm
that every snapshot is v12 and the aggregate pending count matches the dry-run
count:

```sh
for f in /Users/dancer/me/.masc/keepers/*/event-queue.json; do
  jq -c '{schema,pending:.pending.length,pending_items:(.pending.items|length),transition_outbox:(.transition_outbox|length)}' "$f"
done
```

## Rollback

Stop the failed v12 process first. Restore the backup path printed by the apply
command:

```sh
scripts/migrate-event-queue-v8-to-v12.sh \
  --base-path /Users/dancer/me \
  --restore /Users/dancer/me/.masc/migrations/event-queue-v8-to-v12/BACKUP \
  --confirm-stopped
```

Only after the original v8 bytes are restored may the old binary be restarted.
The restore command checks that the backup manifest belongs to the requested
base path and atomically replaces only the snapshots recorded by that
migration.
