# Released workspace upgrade boundary

An upgrade must preserve the workspace rather than initialize over rejected
state. `Released_workspace_upgrade` provides one offline, per-Keeper transaction.
The caller must pass the server's configured BasePath lease directory and an
existing canonical workspace path. It refuses a workspace already owned by a
server, including one in the calling process.

## Proven released mismatch

At tag `v0.34.0`, `lib/keeper/keeper_types_profile_toml_parser.ml` declared
`keeper.autoboot_enabled` and `keeper.proactive_enabled` as booleans.
`keeper_lifecycle_gate_env.ml` projected them to owner restoration and proactive
work respectively. At tag `v0.35.0` these were replaced by `activation_mode`;
`keeper_activation_mode.ml` defines the three representable combinations:

| Explicit old values: autoboot, proactive | Current mode |
| --- | --- |
| false, false | manual |
| true, false | on_demand |
| true, true | autonomous |

Both old values must be present. The combination false/true, missing values,
a mixture of old and new keys, and any otherwise unsupported configuration
require manual repair. No default is inferred from installed software or old
metadata. The current typed declaration parser must accept the transformed
content, and every unrelated parsed field must remain equal. The existing TOML
editor preserves prompt text and unrelated formatting.

## Backup and recovery

Assessment makes no changes. Apply rechecks the original file snapshot, writes
its exact bytes privately to `.masc/upgrades/<random-id>/original.toml`, and
publishes `manifest.json` containing original/result hashes and the known
transformation. Both files and directory entries are synced before the original
configuration is atomically replaced. The receipt distinguishes a confirmed
sync from an after-rename durability warning.

Interactive setup lists known Keeper upgrades when its workspace check finds
unsupported state. Select one or more Keepers to preserve their configuration
and apply the known mapping. Each selected file has its own backup receipt;
failure stops that selection and returns to assessment. Setup also offers
existing validated configuration backups for restoration. A later edit prevents
restoration from overwriting it.

Advanced operators can inspect the same catalog with
`masc workspace-upgrade --base-path WORKSPACE`. Apply uses `--apply KEEPER` and
the displayed `--source-sha256 SHA256`; restore uses `--restore BACKUP_ID`.
No path or digest entry is needed in the interactive selection flow.

This is one file at a time, not a transaction spanning the entire workspace.
Other files, including runtime and fallback assignments, Task, Board, Goal and
Keeper memory, are untouched. The server must be stopped, and independent file
editors must not write concurrently. Detected edits reject the operation.

After a process restart, `load_recovery` validates a backup identifier, reads
owned private regular files, recomputes the transformation, and compares the
manifest. Restore requires the current configuration to equal that exact
migration output; later user changes are never intentionally overwritten.
The backup remains after restore. Recovering an old schema does not make it
acceptable to the current runtime; it restores the operator's original state.

## Cases that must not be synthesized

Between `v0.34.0` and current main, Goal rows gained required
`criterion_revision`, and pending/proven verification records gained request,
criterion and authority identity. Existing `version` values are write counters,
not schema versions. An old proof cannot acquire those identities by inferring
them from its title, time or current Goal. Such stores remain explicit manual
repair cases in setup preflight; this module neither resets nor rewrites them.
