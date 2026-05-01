# Repository Migration Guide

This guide helps existing masc-mcp users migrate from the legacy single-repository
model to the new multi-repository system introduced in Week 8.

## What Changed

| Before | After |
|--------|-------|
| Single implicit repository at `base_path` | Multiple explicit repositories in `.masc/config/repositories.toml` |
| All keepers see all branches | Keeper-repo mapping controls access |
| No URL tracking | Each repository has a remote URL and local checkout path |

## Migration Steps

### Phase 1: Discover Existing Repositories

The runtime can automatically detect git repositories under your `base_path`:

**Via OCaml API:**
```ocaml
(* Returns candidate repositories inferred from origin remotes *)
let* candidates = Repo_store.discover_repositories ~base_path in
```

**Via HTTP API:**
```bash
curl -X POST http://localhost:8935/api/v1/repositories/discover \
  -H "Authorization: Bearer $TOKEN"
```

**Via automatic registration (Week 8 helper):**
```ocaml
(* Discovers and registers all found repositories, skipping duplicates *)
let* registered = Repo_store.register_discovered ~base_path in
```

Directories scanned:
- All paths containing `.git/` up to depth 3 under `base_path`
- Excludes `.masc/` internals
- Excludes already-registered repositories

### Phase 2: Verify and Adjust

After discovery, review `.masc/config/repositories.toml`:

```toml
[repository.project-a]
name = "project-a"
url = "https://github.com/myuser/project-a"
local_path = ".masc/repos/project-a"
default_branch = "main"
credential_id = "default"
keepers = []
status = "Active"
auto_sync = false
sync_interval = 300
```

Fields to review:
- `credential_id`: Assign the correct credential for this remote
- `keepers`: List keeper IDs that should access this repository
- `local_path`: Change if you want to keep the existing worktree location

### Phase 3: Backward Compatibility

If no `repositories.toml` exists, the system still returns a default repository
pointing at `base_path`. This means:

- Existing deployments continue to work without any file changes
- The default repository has `id = "default"`
- Once you add any explicit repository, the default is no longer injected

### Phase 4: Keeper-Repository Mapping

After registration, restrict keeper access:

```ocaml
(* Check if a keeper may use a repository *)
let allowed = Keeper_repo_mapping.is_allowed
  ~keeper_id:"keeper-a"
  ~repository_id:"project-a"
  ~base_path
```

If no mapping exists for a keeper, access falls back to "allow all" for backward
compatibility. Once keeper-repository mappings are configured, access is
restricted to the repositories explicitly listed for that keeper; an explicit
empty mapping grants access to no repositories.

## Rollback

To revert to the legacy behavior, delete `.masc/config/repositories.toml`. The
system will immediately fall back to the single default repository.

## Verification Checklist

- [ ] `discover_repositories` finds your expected repositories
- [ ] `register_discovered` (or manual `add`) populates TOML
- [ ] `load_all` returns the registered repositories
- [ ] Keeper operations still work for allowed repositories
- [ ] Dashboard shows the repository list correctly
