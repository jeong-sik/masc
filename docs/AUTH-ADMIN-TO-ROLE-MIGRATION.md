# Credential `admin` → `role` migration

This runbook prepares durable credentials for the current-only decoder in
#26220 without rotating tokens.

## Order

1. Merge this migration tooling.
2. Stop MASC and confirm port 8945 has no listener.
3. Run the read-only inventory:

   ```sh
   scripts/migrate-auth-admin-to-role.sh --base-path /absolute/base/path
   ```

4. Apply while stopped:

   ```sh
   scripts/migrate-auth-admin-to-role.sh \
     --base-path /absolute/base/path \
     --apply \
     --confirm-stopped
   ```

5. Keep the reported backup path. Start the old runtime and verify credential
   authentication. The old decoder accepts the role-only files.
6. Only then deploy #26220.

The script never prints credential values. It rejects malformed fields,
duplicate JSON keys, `role`/`admin` disagreement, and a mixed legacy/current
fleet. Redirect stubs are validated and left unchanged.

## Rollback

Stop MASC, then use the exact backup path reported by the apply:

```sh
scripts/migrate-auth-admin-to-role.sh \
  --base-path /absolute/base/path \
  --restore /absolute/base/path/.masc/migrations/auth-admin-to-role/<backup> \
  --confirm-stopped
```

Restore verifies the manifest, checksums, and the complete filename inventory
before replacing any credential.
