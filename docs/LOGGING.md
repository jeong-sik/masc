# Logging

One logging surface: the per-module loggers in `lib/masc_log/log.ml`.

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

## Absent fields

`Log.Kv.render` builds a `key=value` message and leaves out every field whose
value is `None`. A field the producer did not measure is not written as `-` or
`n/a`; its absence is the fact. `false` and `0` are values and are rendered.
Use it for any line that carries optional fields:

```ocaml
Log.Keeper.info ~keeper_name "%s"
  (Log.Kv.render
     [ Log.Kv.int "turn" turn
     ; Log.Kv.opt_map "cache_n" string_of_int cache_n  (* omitted when None *)
     ])
```

Only the message text is shaped; the ring entry's typed fields are untouched.

## Forbidden in `lib/` and `bin/`

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

## Where non-canonical output is intended

These sites print outside the canonical surface on purpose. Each states why it
cannot route through it:

- **`lib/masc_log/`** — the Log system cannot log through itself; its `eprintf`
  are the terminal sink and unparsable-env-var / rotation-failure warnings.
- **`lib/fs_compat/`** — runs below the logging stack (`masc_log` depends on
  `fs_compat`, not the reverse); last-resort pre-runtime diagnostics.
- **`bin/main_eio.ml`** — pre-`Log`-init base-path boot guards, FATAL handlers
  for `Out_of_memory` / `Stack_overflow` (must not allocate through the logging
  stack), and the `login` / `init` CLI subcommands whose stderr/stdout is
  user-facing CLI output.
- **Standalone CLI tools** (`bin/masc_trace.ml`,
  `bin/masc_tui_loader.ml`, `bin/masc_cost.ml`) — one-shot
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
- **Runtime-computed component** (`lib/runtime_log_sink.ml`) — `Log.emit`
  with `~module_name:("agent_core:" ^ record.module_name)`; the component is built per
  record at runtime, so no static module preserves it. (A *static* literal
  component such as `"agent_core:event"` is migrate-able — a module's `name` string may
  contain a colon even though the OCaml identifier cannot; that site became the
  `Oas_event` module.)

A site that can route through the canonical surface does. Fix its call site
instead of printing around the logging surface.
