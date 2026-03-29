# I3: Filesystem Storage Migration Framework Design

> Status: Draft
> Date: 2026-03-29
> Ref: RFC #3646, Gap I3

## Problem

`.masc/` directory structure changes (e.g., `perpetual` → `keeper` renaming in #3627)
have no automated migration path. Changes are applied via manual rename scripts
or one-time fixup commits that are not reproducible.

## Current State

- Storage: `.masc/` filesystem tree under `base_path`
- Migrations: ad-hoc shell scripts or manual renames
- Versioning: no schema version marker in `.masc/`
- Rollback: none (manual backup recommended)

## Proposed Design

### Schema Version File

```
.masc/schema_version
```

Contains a single integer (e.g., `1`). Read at startup by `Room.default_config`.
If absent, assumed to be version 0 (legacy).

### Migration Registry

```ocaml
(** fs_migration.ml *)

type migration = {
  from_version : int;
  to_version : int;
  description : string;
  apply : base_path:string -> unit;
}

let migrations : migration list = [
  { from_version = 0; to_version = 1;
    description = "Rename perpetual-keepers to keepers";
    apply = fun ~base_path ->
      let src = Filename.concat base_path ".masc/perpetual-keepers" in
      let dst = Filename.concat base_path ".masc/keepers" in
      if Sys.file_exists src && not (Sys.file_exists dst) then
        Unix.rename src dst };
]

(** Apply all pending migrations from current version to latest. *)
let migrate ~base_path =
  let current = read_schema_version ~base_path in
  let pending = List.filter (fun m -> m.from_version >= current) migrations in
  List.iter (fun m -> m.apply ~base_path) (List.sort compare pending);
  write_schema_version ~base_path (latest_version ())
```

### Startup Integration

Called once in `Room.default_config` after resolving `base_path`:

```ocaml
let default_config base_path =
  let resolved = resolve_masc_base_path base_path in
  Fs_migration.migrate ~base_path:resolved;  (* NEW *)
  ...
```

### Safety

- Each migration is idempotent (check before rename)
- Backup: `cp -r .masc .masc.backup-$(date +%s)` before first migration
- Rollback: restore from backup (no automated rollback)
- CI: test migrations on fixture directories

## Implementation Plan

| Phase | Scope | Effort |
|-------|-------|--------|
| P0 | schema_version file + read/write | 0.5 day |
| P1 | Migration registry + apply loop | 1 day |
| P2 | Startup integration | 0.5 day |
| P3 | First real migration (perpetual→keeper) | 0.5 day |
| P4 | CI fixture tests | 1 day |

Total: 3-4 days.

## Trade-offs

| Decision | Alternative | Why This |
|----------|-------------|----------|
| Integer version | SemVer | Single linear sequence, simpler |
| File-based marker | Env var | Persists with data, not with process |
| Eager at startup | Lazy on first access | Fail fast, predictable state |
| No rollback automation | Reversible migrations | Complexity not justified for single-dev project |
