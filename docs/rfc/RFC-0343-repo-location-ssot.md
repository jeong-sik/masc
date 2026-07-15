# RFC-0343 — Repo location SSOT (collapse dual-authority, attribute by git-remote)

- Status: Draft
- Updated: 2026-07-15
- Author: vincent
- Related: RFC-0128 (§4.5 write partition), RFC-0324 (filesystem-repo-truth), RFC-0000 §3.15 (Keeper-Config SSOT) / D9
- Supersedes: none (extends RFC-0128 §4.5 attribution mechanism)

## 0. Summary

MASC defines "where repository X lives for a keeper" in **two independent authorities** joined by a reverse-parse of a filesystem path. This RFC removes the reverse-parse and makes write-attribution read the checkout's own `origin` URL (`git remote get-url`), an operation the codebase already performs for the same purpose in `discover_repositories`. Repo **identity** (id/name/url/aliases) is already SSOT in `repositories.toml` and is unchanged.

Scope: attribution mechanism + the `clone_sandbox_repo` record fabrication + a field rename. Not in scope: the D8 decision to delete the playground bundle entirely (this RFC is a prerequisite that makes D8 (b3) trivial, not D8 itself).

## 1. Problem (evidence)

Two location authorities, no linking invariant:

1. **Registered path** — `repositories.toml local_path` (default `.masc/repos/<id>`), resolved by `Repo_store.local_path`. Consumed only by `repo_sync.ml:62`, `server_ide_http.ml:45`, `server_routes_http_routes_repositories.ml:45,73`, `server_routes_http_routes_workspace.ml:104`. This is the **operator working tree**.
2. **Per-keeper clone path** — `<base>/.masc/playground/<keeper>/repos/<repo_name>`, built by `playground_repo_readiness.clone_path` (`:139`) as `host_root_abs_of_meta ~config meta` + `"repos"` + `repo_name`. Built by `clone_sandbox_repo` (`:346`) which consults the catalog for **URL only** and never reads `local_path`.
3. **The join** — `Playground_paths.parse_playground_repo_path` (`playground_paths.ml:104`) structurally reverse-parses a keeper host write-path back to `(repo_id, rel)`, then `find_url_by_id` (`keeper_tool_filesystem_runtime.ml:317`) re-attaches the canonical URL. The *existence* of this reverse-parse is the evidence that identity and per-keeper location share no invariant.

Concrete failures:

- **`path_not_found` 379/24h (2026-07-08 audit).** A prior prompt invariant ("every catalog id resolves under `repos/<name>/`") was removed (RFC-0324 B-1) because it was false; keepers trusted a path that was never cloned.
- **default_branch/aliases dropped.** `clone_sandbox_repo` hardcodes `default_branch="main"`, `aliases=[]`, `id=repo_name` (`playground_repo_readiness.ml:354-357`). A catalog repo whose `default_branch` is `master`/`develop` is cloned and reasoned about as `main`. The **same hardcode** is duplicated in `discover_repositories` (`repo_store.ml:439-`).
- **id ≠ dir-name attribution break.** `make_repo_record` sets `id := repo_name` (sandbox dir basename); when it differs from the catalog id, `parse_playground_repo_path` mis-attributes → `sandbox_unregistered_repo` orphan, defeating collision detection against the operator working tree.

## 2. Non-goals

- Deleting the playground `mind/repos` bundle (D8; this RFC makes D8 (b3) — the `docker/` segment — deletable, but does not decide D8).
- Changing repo **identity** storage (`repositories.toml` stays the identity SSOT).
- Per-keeper credential/GitHub identity (RFC-gated, separate).
- The keeper identity-handle unification (RFC-0000 §3.15 SEVERE row; separate RFC — but see §6, this RFC removes one downstream symptom).

## 3. Design

### 3.1 Attribution by git-remote (replaces the reverse-parse)

**Deterministic boundary:** attribution is a pure read of git state, no heuristic.

- Delete `parse_playground_repo_path`'s use as a semantic channel. Its **only** production caller is `resolve_partition_for_write` (`keeper_tool_filesystem_runtime.ml:314`), which receives a host path (translated from the container-visible path at `keeper_run_tools_hooks.ml:108-117`) and produces `(By_url slug, rel)`.
- Replace with:
  - **bucket (URL):** `Repo_git.get_origin_url ~local_path:<checkout root>` (`repo_git.mli:41`) — `git remote get-url origin`, bounded, read-only. Already used identically at `repo_store.ml:439`.
  - **rel (repo-relative path):** `Repo_git.worktree_root ~local_path` (`repo_git.mli:45`, `git rev-parse --show-toplevel`), then the write path relative to that root.
- Both git ops already exist and are bounded. **No new infrastructure.**

Fail-closed: if `get_origin_url`/`worktree_root` returns `Error` (not a git repo, no origin), the write is attributed to a typed `Unattributed { reason }` and the caller handles it explicitly — never silently bucketed. (Matches the existing `sandbox_unregistered_repo` failure surface, but typed rather than path-derived.)

### 3.2 `clone_sandbox_repo` reads the full catalog record

- `clone_sandbox_repo` (`playground_repo_readiness.ml:346`) looks up the **catalog record** by id (not just URL) and reuses `default_branch` and `aliases`. Delete the hardcoded `"main"`/`[]`.
- The per-keeper clone location becomes a pure function keyed by **catalog id**, not an operator-chosen `repo_name` dir basename: `clone_path(keeper, catalog_id)`. This makes `id ≠ dir-name` unrepresentable.
- Apply the same fix at `repo_store.ml:439` (`discover_repositories`), which carries the identical `default_branch="main"` hardcode — codemod both sites in one change, do not patch one and leave the other (N-of-M bar).

### 3.3 Split the overloaded `local_path` field → `operator_checkout_path`

- `Repo_manager_types.repository.local_path` is read by **both** roles: `repo_sync`/routes read the REGISTERED operator tree; `clone_sandbox_repo:352` overloads it to carry the CLONE path into `Repo_git.clone`.
- Rename the registered field to `operator_checkout_path` (identity/registry role). The clone path stops masquerading as the same field — `clone_sandbox_repo` passes the clone path explicitly to `Repo_git.clone` without reusing the registry field name.
- Touch surface (REGISTERED consumers, ~11 sites): `repo_store.ml:101,210-211,260-261,278-281,387-398,448`, `repo_store_lookup.ml:80`, `repo_sync.ml:62`, `server_ide_http.ml:45`, `server_routes_http_routes_repositories.ml:45,73,100`, `server_routes_http_routes_workspace.ml:104`. The dashboard JSON key `"local_path"` (`server_routes_http_routes_repositories.ml:100`) is an **API-visible rename** — version or alias it.

### 3.4 `docker/` segment becomes deletable

The `docker/<keeper>` host-path segment exists only because the Docker bind-mount (`keeper_sandbox_docker.ml:316`) makes the host storage path carry the backend name; the parser accepts a `docker/` branch (`playground_paths.ml:132`) purely to reverse it. Once attribution moves to git-remote (§3.1), `parse_playground_repo_path` is deleted and the `docker/` branch question disappears with it. (This is exactly RFC-0000 D8 (b3) "실행 백엔드가 저장 경로에 새는 것".) This RFC does not require unifying the two byte-identical Docker host-root constructors; it makes that a follow-up cleanup rather than a blocker.

## 4. Acceptance

- `parse_playground_repo_path` deleted; `git grep parse_playground_repo_path lib/` = 0 (mli + impl + caller gone).
- `resolve_partition_for_write` attributes via `get_origin_url` + `worktree_root`; a write in a keeper clone whose origin ≠ its dir-name attributes to the **origin URL** bucket (regression test with a clone dir renamed off its id).
- `clone_sandbox_repo` and `discover_repositories` both read catalog `default_branch`/`aliases`; a catalog repo with `default_branch=master` is cloned on `master` (test). `git grep 'default_branch = "main"' lib/` = 0 in these two sites.
- `repository.local_path` renamed to `operator_checkout_path`; `clone_sandbox_repo` no longer writes a clone path into the registry field. `git grep '\.local_path' lib/` returns only the renamed registry field's consumers.
- Fail-closed: a write outside any git checkout returns typed `Unattributed`, never a silent bucket (test).
- Full keeper filesystem-write suite green; `test/` regression for the renamed off-id clone.

## 5. Blast radius

| change | sites | risk | rollback |
|---|---|---|---|
| Attribution → git-remote | `keeper_tool_filesystem_runtime.ml:314` (1 prod caller) | **중** — core write path; but get_origin_url already proven at repo_store.ml:439 | keep parse_playground_repo_path behind a flag one release |
| clone_sandbox_repo full-record + discover_repositories | `playground_repo_readiness.ml:346`, `repo_store.ml:439` | 중 — clone behavior change (branch name) | revert to URL-only lookup |
| local_path → operator_checkout_path | ~11 REGISTERED sites + 1 dashboard JSON key | **중~높음** — API-visible field rename; touches server routes | alias old key one release |
| docker/ segment | deleted with parser (§3.1) or deferred | 낮음 — follows attribution move | n/a (deletion is downstream) |

The reverse-parse is narrower than it looks: **one** production call site. The heavier cost is orthogonal (the field rename). No new infrastructure — `get_origin_url` and `worktree_root` both exist and are bounded.

## 6. Interaction with identity unification

`get_origin_url` attribution does not depend on the keeper identity-handle mess (RFC-0000 §3.15 SEVERE). But note: the `id := repo_name` fabrication in `make_repo_record` is a *repo*-identity instance of the same "untyped string used as identity" pattern that produces the keeper `#10440` credential-alias workaround. Keying the clone by catalog id (§3.2) removes the repo-side instance; the keeper-side (`Keeper_id` unification) remains a separate RFC.

## 7. Workaround-rejection self-check (CLAUDE.md)

- Not telemetry-as-fix: removes the reverse-parse, does not count its failures.
- Not a string classifier: replaces path-string parsing with a typed git-state read.
- Not N-of-M: the `default_branch="main"` hardcode is fixed at **both** sites (clone + discover) in one codemod, not one-at-a-time.
- Root fix, not symptom suppression: the `sandbox_unregistered_repo` orphan and `path_not_found` classes are removed at the source (no shared invariant → one attribution source), not capped/retried.
