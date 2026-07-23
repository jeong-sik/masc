# Logging

One logging surface, enforced by `scripts/ci/check-logging-consistency.sh`.

## Canonical surface

Use the per-module loggers defined in `lib/masc_log/log.ml`:

```ocaml
Log.<Module>.info  fmt …      (* normal informational log    *)
Log.<Module>.warn  fmt …      (* recoverable problem          *)
Log.<Module>.error fmt …      (* failure operators must see   *)
Log.<Module>.debug fmt …      (* verbose / development detail  *)
Log.<Module>.routine fmt …    (* repeatable housekeeping; level via MASC_LOG_ROUTINE_LEVEL *)

Log.<Module>.emit <level> ~details:<json> "msg"   (* structured payload with a fixed level *)
```

Each `<Module>` is built by `module X = Make(struct let name = "X" end)`. The
`name` string is the component operators see in the emitted line and in the
dashboard ring entry:

```
[2026-06-03 11:22:33] [WARN] [Keeper] message text
                              ^^^^^^^ = the module's name
```

`Log.<Module>.info` and the top-level `Log.info ~ctx:"<Module>"` produce the
**same** output shape (same component, level, message). The per-module form is
canonical because the component is fixed at the module definition (no per-call
string to drift) and the env-var override `MASC_LOG_<NAME>_LEVEL` works.

To add a component, add a `module X = Make(struct let name = "x" end)` line to
**both** `lib/masc_log/log.ml` and the `module X : LOGGER` list in
`lib/masc_log/log.mli`. The module identifier must be `Capitalized`; the `name`
string carries the exact component.

## Forbidden in `lib/` and `bin/` (the gate fails on these)

| Pattern | Why it is non-canonical | Migrate to |
|---|---|---|
| `Printf.eprintf` / `prerr_*` | raw stderr, never reaches the dashboard ring | `Log.<Module>.{info,warn,error,debug}` |
| `Log.info ~ctx:"X"` (top-level) | per-call component string, drifts; no per-module level override | `Log.X.info` |
| `Logs.{info,warn,err,debug,app}` | a **different** library (`logs`), routes through its own reporter, not the masc ring | `Log.<Module>.{…}` |
| `Log.legacy_stderr` / `Log.legacy_traceln` | RFC-0079 raw bridge | `Log.<Module>.{…}` unless the message embeds its own `[LEVEL]` prefix (see allowlist) |
| bare `Log.emit` / `Log.emit_event` | top-level, requires a `~module_name:` string | `Log.<Module>.emit` |

`Log.emit_routine` is **not** forbidden — `Log.<Module>.routine` is the same
routine API and either is acceptable, but prefer the per-module form.

`Logs.*` is forbidden in `lib/`: it is the `logs` opam library, not
`lib/masc_log`. It bypasses the structured ring buffer entirely.

## Allowlist (legit non-canonical)

Maintained in `ci/logging-consistency-allowlist.txt` as path prefixes. Each
entry states why the site cannot route through the canonical surface. Summary:

- **`lib/masc_log/`** — the Log system cannot log through itself; its `eprintf`
  are the terminal sink and unparsable-env-var / rotation-failure warnings.
- **`lib/fs_compat/`** — runs below the logging stack (`masc_log` depends on
  `fs_compat`, not the reverse); last-resort pre-runtime diagnostics.
- **`bin/main_eio.ml`** — pre-`Log`-init base-path boot guards, FATAL handlers
  for `Out_of_memory` / `Stack_overflow` (must not allocate through the logging
  stack), and the `login` / `init` CLI subcommands whose stderr/stdout is
  user-facing CLI output.
- **Standalone CLI tools** (`bin/masc_trace.ml`,
  `bin/masc_tui_loader.ml`, `bin/masc_cost.ml`, `bin/masc_compaction_audit.ml`,
  `bin/keeper_feature_proof_report.ml`, `bin/env_knob_catalog.ml`) — one-shot
  binaries; their I/O is the tool's user interface, not server logging.
- **RFC-0079 legacy bridge** (`lib/server/server_startup_takeover.ml`,
  `lib/backend/backend.ml`, `lib/workspace/workspace_query.ml`,
  `lib/mcp_server_eio_resource.ml`) — `legacy_stderr`/`legacy_traceln` emit a
  raw, unprefixed stderr line and mirror it into the ring with a `Legacy_*`
  source tag (read back by `dashboard/src/api/schemas/logs.ts`). Every call site
  embeds its own `[FATAL]`/`[WARN]`/`[DEBUG]` marker in the message body;
  migrating would double-prefix the message and drop the `Legacy_*` source.
- **Dynamic component** (`lib/config_dir_resolver/config_dir_resolver.ml`) —
  `~ctx:context` uses a runtime-computed component string; no static module
  preserves the per-call value.
- **Runtime-computed component** (`lib/agent_sdk_log_bridge.ml`) — `Log.emit`
  with `~module_name:("oas:" ^ record.module_name)`; the component is built per
  record at runtime, so no static module preserves it. (A *static* literal
  component such as `"oas:event"` is migrate-able — a module's `name` string may
  contain a colon even though the OCaml identifier cannot; that site became the
  `Oas_event` module.)

Four files (`server_startup_takeover.ml`, `backend.ml`, `workspace_query.ml`,
`mcp_server_eio_resource.ml`) are allowlisted **wholesale** even though they also
contain canonical logging — the suppression is intentional because their only
non-canonical sites are the embedded-`[LEVEL]` legacy-bridge lines. The trade-off
is that a future stray `Printf.eprintf` added to one of these files would not be
caught; reviewers of those four files must check logging by hand.

Do not add an allowlist entry to silence a migrate-able site. Fix the call
site. The gate is a ratchet: `ci/logging-consistency-baseline.txt` is `0` and
may only be lowered.

## Migration counts (this change)

Non-canonical sites in `lib/` + `bin/`, before → after:

| Category | Before | Migrated | Allowlisted | After (gated) |
|---|---:|---:|---:|---:|
| top-level `Log.{info,warn,error,debug}` (`~ctx` + no-ctx) | 63 | 61 | 2 (dynamic `~ctx:context`) | 0 |
| `Logs.*` library | 11 | 11 | 0 | 0 |
| `Log.legacy_stderr` / `legacy_traceln` (call sites) | 27 | 0 | 27 (embedded `[LEVEL]` prefix) | 0 |
| bare `Log.emit` / `emit_event` (non-comment) | 8 | 7 | 1 (`"oas:" ^ …` runtime component) | 0 |
| raw `Printf.eprintf` / `prerr_*` | 47 | 3 | 44 (log.ml, fs_compat, CLI tools, boot/FATAL) | 0 |

The migration added per-module loggers for the components that previously only
existed as `~ctx:"…"` strings (e.g. `Dashboard_runtime`, `Otel`,
`H2_gateway`), preserving the exact component string operators see, plus
domain-named modules (`Voice`, `ExecTap`, `ToolValidation`, `Discord`) for raw /
`Logs.*` sites that previously carried no component.
