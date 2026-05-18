# IDE Store Migration Runbook (RFC-0128)

Operator runbook for the IDE store partitioning rollout introduced by
[RFC-0128](rfc/RFC-0128-ide-canonical-url-partitioning.md). Covers
the diagnosis path for the user-facing symptom *"IDE shows no keeper
activity / no live information"* and the steps for the Phase 3
migration.

## TL;DR

If your IDE looks empty after pulling the RFC-0128 PRs:

1. Verify `<base-path>/.masc/config/repositories.toml` has an entry whose
   `local_path` points at the working tree you opened in the IDE.
2. Restart `main_eio` so the new entry is read.
3. Open the IDE with `?repo_id=<that-id>`.

If you have pre-RFC-0128 records (records written before the cut-over
landed), run `masc-ide-migrate --base-path <project-root> --dry-run`
to preview the partition split, then `--commit` (optionally with
`--delete-legacy`) to fold them into the new layout.

## Background

Before RFC-0128 the IDE store lived at a single flat directory:
`<base>/.masc-ide/{annotations,regions}.jsonl`. After RFC-0128 the
store is partitioned by *canonical git URL*:

```
<base>/.masc-ide/
  by-url/
    github.com_jeong-sik_masc-mcp/
      annotations.jsonl
      regions.jsonl
    github.com_jeong-sik_oas/
      ...
  _orphan/
    annotations.jsonl
    regions.jsonl
```

The canonical URL is derived from each registered repository's
`url` field (see `Ide_paths.canonical_url_of_remote`). Two clones of
the same upstream — for example the user's working tree and a
keeper's sandbox clone — both resolve to the same slug, so a write
by one is visible to the other.

Records whose `file_path` cannot be matched to a registered
repository land in `_orphan/`. The
`masc_ide_orphan_writes_total` Prometheus counter exposes the rate
so operators can spot misconfigured repositories.

## Diagnosis path

When the IDE looks empty, walk the layers in order. Each section
includes the exact command and the expected output.

### Layer 1 — Server is running where you think it is

```sh
ps aux | grep main_eio | grep -v grep
```

Confirm `--base-path` points at the project root that owns the
`.masc/` and `.masc-ide/` you expect. Mixing two base paths on the
same machine is the most common cause of "empty IDE" reports.

### Layer 2 — Disk state of `.masc-ide/`

```sh
ls -la <base>/.masc-ide/
find <base>/.masc-ide -type f
```

Expected layouts:

| Files present | Interpretation |
|---|---|
| `regions.jsonl` / `annotations.jsonl` at top level | Pre-RFC-0128 legacy store. Run `masc-ide-migrate` to fold into `by-url/`. |
| `by-url/<slug>/<file>` | Post-RFC-0128 cut-over. Healthy. |
| `_orphan/<file>` | Records that could not be assigned to a repository. See Layer 3. |
| Nothing | Server has not written yet (idle keeper) or is writing to a different base path (Layer 1). |

### Layer 3 — `repositories.toml` mapping

```sh
grep -A6 '^\[repository\.' <base>/.masc/config/repositories.toml
```

For every clone you want the IDE to see, expect an entry whose
`local_path` is the *absolute path of that clone*. The entry for the
operator's working tree typically looks like:

```toml
[repository.masc-mcp]
  name = "masc-mcp"
  url = "git@github.com:jeong-sik/masc-mcp.git"
  local_path = "/Users/<you>/workspace/.../masc-mcp"
  status = "Active"
  auto_sync = false
```

If the `url` is empty or unparseable, writes land in `_orphan` with
counter label `blank_url` / `url_unparseable`. If the entry is
missing entirely, writes land in `_orphan` with
`unregistered_repo`. Keeper sandbox writes fall back to a second
lookup chain (`Playground_paths.parse_playground_repo_path`) — see
the RFC §4.5 for the contract.

### Layer 4 — What is the keeper writing right now

```sh
tail -3 <base>/.masc-ide/regions.jsonl 2>/dev/null
# or for the partitioned layout:
tail -3 <base>/.masc-ide/by-url/<slug>/regions.jsonl
```

`file_path` falls into one of three shapes:

| Shape | Meaning |
|---|---|
| `<base>/workspace/<owner>/<repo>/<rel>` | Operator working tree |
| `<base>/.masc/playground/<keeper>/repos/<repo>/<rel>` | Local sandbox |
| `<base>/.masc/playground/docker/<keeper>/repos/<repo>/<rel>` | Docker sandbox |

The post-RFC-0128 write path strips this down to the repo-relative
`<rel>` before persisting. If you see absolute paths in the JSONL
after the cut-over, that PR is not yet on `main`.

### Layer 5 — `/metrics` for the orphan counter

```sh
curl -s http://localhost:<port>/metrics | grep masc_ide_orphan_writes_total
```

Label values map directly to a fix:

| `reason` | Fix |
|---|---|
| `unregistered_repo` | Add the working-tree repository to `repositories.toml` |
| `blank_url` | Fill in the `url` field for the matching entry |
| `url_unparseable` | Correct the `url` (must be parseable by `canonical_url_of_remote`) |
| `sandbox_unregistered_repo` | Register the *upstream* in `repositories.toml` — the sandbox path resolves by `repo_id`, so the playground does not need its own entry |
| `sandbox_blank_url` / `sandbox_url_unparseable` | Same as the non-sandbox variants, just observed via the sandbox lookup chain |

## Phase 3 migration: `masc-ide-migrate`

Once the partitioned layout is in production, run the migration to
fold pre-cut-over records out of the flat store.

### Step 1 — Dry run

```sh
masc-ide-migrate --base-path <project-root>
```

Output:

```
RFC-0128 §5 Phase 3 — flat-file purge migration
  base path: /Users/<you>/...
  mode:      DRY RUN (no files written)

  annotations:
    total       142
    -> by-url   137
    -> _orphan  5
  regions:
    total       89
    -> by-url   85
    -> _orphan  4

Note: 9 record(s) routed to _orphan. Register the missing
      repositories in .masc/config/repositories.toml ...
```

Inspect the orphan count. If it is non-zero, add the missing
`repositories.toml` entries and re-run the dry run until the orphan
column is what you expect.

### Step 2 — Commit

```sh
masc-ide-migrate --base-path <project-root> --commit
```

Records are written to `by-url/<slug>/` and `_orphan/`. The Legacy
flat files are *kept* so a read with `?merge_legacy=true` (the
default for the HTTP route) still surfaces them — useful while
verifying the migration.

### Step 3 — Delete legacy

```sh
masc-ide-migrate --base-path <project-root> --commit --delete-legacy
```

Removes the flat `annotations.jsonl` / `regions.jsonl` after a
successful migration. After this step, `merge_legacy` becomes a
no-op.

The migration is idempotent: re-running on an already-migrated store
returns a zero-count report.

## What is *not* in scope

- Auto-migration on server boot. The data movement is irreversible
  without a backup; explicit operator opt-in via this CLI is the only
  way to commit it.
- Removing the `merge_legacy` read flag. That happens in a later cycle
  after Phase 3 has been verified in production.
- Multi-base-path consolidation. Each `main_eio` instance owns its own
  `.masc-ide/` tree; there is no cross-instance merge.

## References

- RFC-0128 spec: [`rfc/RFC-0128-ide-canonical-url-partitioning.md`](rfc/RFC-0128-ide-canonical-url-partitioning.md)
- Library entry points: `lib/ide/ide_paths.ml`, `lib/ide/ide_annotations.ml`,
  `lib/ide/ide_region_tracker.ml`, `lib/ide/ide_migration.ml`
- CLI: `bin/masc_ide_migrate.ml`
- Implementation PR stack: #16028 (helpers + signatures, MERGED),
  #16036 (cut-over), #16040 (`excluded_dirs`), #16044
  (single-write), #16049 (read merge), #16053 (migration),
  #16055 (dead-code purge), #16058 (CLI), #16061 (sandbox path
  lookup), #16062 (HTTP base alignment)
