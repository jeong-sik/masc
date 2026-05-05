# RFC-0030 — `masc create` CLI / API for Keeper, Cascade, Persona

- **Status**: Draft
- **Author**: yousleepwhen (vincent)
- **Created**: 2026-05-05
- **Audit reference**: `docs/audit-responses/2026-05-05-integrated-improvement-design.md` §2-1, §2-2
- **Related**: RFC-0027 (typed cascade), RFC-0019 (keeper credential unification),
  RFC-0008 (credential provider), `lib/keeper/keeper_persona_authoring.ml`,
  `lib/cascade/cascade_config.ml`

## 1. Problem

Three persistence shapes today require **manual file editing + server
restart**:

| Asset | File | Restart required? | Validator |
|-------|------|-------------------|-----------|
| Keeper persona | `config/keepers/<name>.toml` | Yes (autoboot rescan) | TOML parse + `keeper_meta_json_parse.ml` |
| Cascade profile | `config/cascade.toml` | Yes (cascade reload) | `cascade_toml_materializer.ml` |
| Credential | `config/keepers/<name>.toml` + post-boot issuance | Partial | `credential_provider.ml` |

Operator pain points:

1. **Schema drift.** Operator must know the valid TOML keys by reading
   tests or scanning errors. There is no "what fields are valid?" query.
2. **No dry-run.** A typo materialises only at server boot, sometimes
   only when a specific code path triggers parse.
3. **No auto-registration.** Adding a keeper means: edit TOML, restart,
   wait for autoboot, watch credential issuance, watch first turn,
   verify dashboard shows the new keeper, verify cascade routing picks
   it up. Each step has its own failure mode.
4. **No deletion.** "Removing" a keeper is "edit TOML, archive the
   file". Credentials don't auto-revoke; the dashboard keeps a stale
   tile until projection rebuild.

The audit framed this as a 36-keeper scaling problem ("36개의 config
파일을 직접 편집하면 1달이 걸린다"). Even at today's 5-persona scale
the pain is real — every persona addition burns 30+ minutes of
ceremony.

## 2. Goal

Three operator-facing surfaces, in increasing complexity:

- **2.1** `masc create persona`: TOML stub + schema validation + post-create
  registration (no credential / cascade impact).
- **2.2** `masc create cascade`: profile add/activate/list/delete with
  runtime reload, no server restart.
- **2.3** `masc create keeper`: persona + credential issuance + cascade
  routing entry + dashboard register, single command, atomic.

Each surface is independently shippable. Order matters — 2.3 depends on
2.1 + 2.2.

## 3. Non-goals

- GUI / web dashboard authoring. The audit mentioned TUI; this RFC keeps
  the surface CLI + MCP-tool only. TUI is a follow-up if the CLI proves
  awkward.
- Mass migration of existing TOML to a new schema. The CLI writes the
  same TOML that today's autoboot already parses. Schema evolution is
  RFC-0027's lane.
- Replacing TOML with a different format. JSON / YAML proposals are
  out of scope; switching costs are higher than the gain.
- Multi-tenant / per-team scoping. The CLI assumes a single operator
  trust boundary, matching today's deployment model.

## 4. Design

### 4.1 Persona create surface

```
masc create persona \
  --name <string> \
  --tier <big_three|tier_fast|tier_small|...> \
  --tools <preset|comma-list> \
  [--work-source <unclaimed_tasks|...>] \
  [--git-identity-mode <github_identity|keeper_alias>] \
  [--dry-run]
```

Implementation:

- New module `lib/keeper/keeper_persona_create.ml` that owns the
  TOML-write side. `keeper_persona_authoring.ml` already parses /
  validates; this RFC adds the *generative* counterpart.
- `--dry-run` writes nothing, prints the rendered TOML + the validation
  result to stdout. No filesystem effect.
- Validation runs the same pipeline as autoboot (`keeper_meta_json_parse`
  + `keeper_types_profile.ml` enum guards). On failure, prints the
  field-level error from the existing parser — no separate error
  catalogue.
- On success, writes `config/keepers/<name>.toml` with the standard
  `base = "base.toml"` + override block layout. Keeps the file
  hand-editable.

API counterpart (MCP tool): `masc_persona_create` with the same params
as named record fields. Returns `{ name; toml_path; validated: true }`
or the validation error.

### 4.2 Cascade create surface

```
masc create cascade \
  --name <string> \
  --models <comma-list> \
  --strategy <latency_first|cheap_first|...> \
  [--fallback <profile-name>] \
  [--max-tokens <int>] \
  [--temperature <float>] \
  [--dry-run]

masc cascade activate <name>      # runtime reload
masc cascade list
masc cascade delete <name>
```

Implementation:

- `lib/cascade/cascade_authoring.ml` — wraps `cascade_toml_materializer`
  in a generative API.
- `cascade activate` calls into the existing reload path (RFC-0027
  PR-9b dual-track resolver, #13097). The dual-track is the
  preconditions for runtime reload — without it, this command does
  nothing safe.
- `cascade delete` refuses if any keeper TOML references the profile.
  The check uses `keeper_persona_authoring`'s reverse index (added in
  the same PR).

This surface has the largest risk: cascade routing is hot-path.
Mitigation:

- `--dry-run` prints the rendered profile + the diff against current
  `cascade.toml`.
- `activate` is gated on a `--confirm` flag for non-`--dry-run`
  invocations; the operator must read the diff before applying.
- Memory cross-ref: `feedback_keeper_starvation_capacity_vs_turn_duration_mismatch`
  warns that capacity tuning has hidden coupling. The CLI must reject
  profiles that lower capacity below the current keeper count without
  explicit `--allow-capacity-shrink`.

### 4.3 Keeper create surface

```
masc create keeper \
  --name <string> \
  --persona <persona-name | --inline persona-flags...> \
  --tier <...> \
  [--no-credential]   # for testing / staging
  [--cascade-route]   # opt-in; default off — most keepers route via tier
  [--dry-run]
```

Atomic sequence (in this order, each step idempotent):

1. Persona create (if `--inline`) or lookup (if `--persona <name>`).
2. Credential issue via `credential_provider.materialise` — RFC-0019
   pathway. New keeper gets a fresh credential. Failure aborts.
3. Cascade route entry (if `--cascade-route` set; default off — most
   keepers route via tier).
4. Autoboot rescan trigger via internal MCP tool `masc_autoboot_rescan`
   (added in this RFC).
5. Wait up to `MASC_KEEPER_CREATE_BOOT_TIMEOUT_SEC` (default 30s) for
   the keeper's first heartbeat. Print the heartbeat or a timeout
   diagnostic.

Rollback: each step records what it created. On step-N failure, undo
all `1..N-1` in reverse. No partial state on disk.

### 4.4 Validation pipeline (shared)

All three surfaces call into a common `Authoring_validate` module that
runs:

- TOML parse (delegate to existing `keeper_meta_json_parse` /
  `cascade_toml_materializer`).
- Cross-reference checks (persona's tool preset exists; cascade's
  fallback profile exists; keeper's persona exists).
- Capability checks (persona's `git_identity_mode` is one of the two
  enum variants; tier exists in cascade).
- Conflict checks (no two keepers with same name; no two cascade
  profiles with same name).

The validation result is a `Result.t` with field-level errors. CLI
prints them grouped by field; MCP tool returns the structured form.

## 5. Tests

### 5.1 PR-2.1 (persona create)

- `test_persona_create_writes_valid_toml`: round-trip create →
  parse → assert equal to expected.
- `test_persona_create_rejects_invalid_tier`: assert error mentions
  `tier`.
- `test_persona_create_dry_run_writes_nothing`: assert filesystem
  unchanged.
- `test_persona_create_idempotent_on_retry`: same name twice with same
  fields → no error, no duplicate file.

### 5.2 PR-2.2 (cascade create + activate)

- `test_cascade_create_dry_run_diff`: compare rendered TOML against
  fixture.
- `test_cascade_activate_triggers_reload`: stub the reload path;
  assert the resolver picks up the new profile.
- `test_cascade_delete_refuses_when_referenced`: keeper TOML references
  profile → delete fails with referenced-by list.
- `test_cascade_capacity_shrink_rejected_without_flag`: lowering
  capacity below current keeper count without
  `--allow-capacity-shrink` errors.

### 5.3 PR-2.3 (keeper create)

- `test_keeper_create_atomic_rollback`: stub credential failure →
  assert persona TOML deleted.
- `test_keeper_create_first_heartbeat_within_timeout`: integration
  test against a fixture cascade.
- `test_keeper_create_idempotent_on_existing_name`: same name twice →
  reports already-exists, no overwrite.

## 6. Performance

- Persona create: file write, no hot path. Sub-millisecond.
- Cascade activate: triggers RFC-0027's dual-track reload. Per-cascade
  resolver swap is atomic; observed latency in PR-9b's tests is sub-
  10ms.
- Keeper create: dominated by step 5 (heartbeat wait). 30s timeout is
  the floor; typical observed time is ~3s under healthy autoboot.

No micro-benchmark gate is needed at this RFC level — these are
operator commands, not request-path code.

## 7. Migration

The three surfaces ship as separate PRs:

- **PR-2.1** (persona create CLI + MCP tool) — ships first, no
  cross-cutting changes.
- **PR-2.2** (cascade create / activate / list / delete) — depends on
  RFC-0027 PR-9b (dual-track resolver, #13097) being merged. Block on
  that merge.
- **PR-2.3** (keeper create end-to-end) — depends on PR-2.1 + PR-2.2.

No data migration. Existing hand-edited TOML files keep working — the
CLI writes the same shape.

Deprecation: hand-editing remains supported indefinitely. The CLI is
*additive*. We don't lock anyone out of vim.

## 8. Open questions

- **Should `masc create persona` also offer `--from-template
  <preset>`?** Tempting (e.g. `--from-template coding-agent` writes the
  full sangsu-style block). Held off because the templates would
  duplicate `base.toml` defaults — the override block is already small
  enough.
- **Should `cascade activate` be gated by a TLA+ liveness check?**
  RFC-0022 (cascade attempt liveness) defines the model; runtime
  enforcement could refuse activation if the new profile would violate
  the spec. Held off — TLA+ checks are CI gates, not runtime checks.
- **Should the MCP tool surface be exposed to keepers themselves?**
  i.e. can a keeper provision its own peers? Strict no. The audit
  framed CLI as operator-only and that boundary is correct —
  RFC-0008's credential trust model assumes operator-issued
  credentials.

## 9. Decision log

- Three separate surfaces (not one mega-CLI) — chosen so PR-2.1 can
  ship before RFC-0027 PR-9b, and operator value lands incrementally.
- Atomic rollback on `keeper create` — chosen over "best-effort with
  manual cleanup". Operators will hit failures during the early days
  of the CLI; partial state is the single biggest source of
  trust-erosion in operator tooling.
- TUI deferred — the audit mentioned it but CLI + MCP tool covers all
  current operator workflows. Reopen when there's a concrete TUI ask.
