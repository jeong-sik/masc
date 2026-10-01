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
| `Log.legacy_stderr` / `Log.legacy_traceln` | RFC-0079 raw bridge | `Log.<Module>.{…}` unless the message embeds its own `[LEVEL]` prefix (see the legacy bridge row below) |
| bare `Log.emit` / `Log.emit_event` | top-level, requires a `~module_name:` string | `Log.<Module>.emit` |

`Log.emit_routine` is **not** forbidden — `Log.<Module>.routine` is the same
routine API and either is acceptable, but prefer the per-module form.

`Logs.*` is forbidden in `lib/`: it is the `logs` opam library, not
`lib/masc_log`. It bypasses the structured ring buffer entirely.

## Where non-canonical output is intended

These sites print outside the canonical surface on purpose. A site that can
route through the canonical surface does: fix its call site instead of
printing around the logging surface. A new site that cannot route through it
is added here with its reason.

| Site | Why it cannot route through `Log` |
|---|---|
| `lib/masc_log/` | The Log system cannot log through itself. Its `eprintf` are the terminal sink, the warnings for an invalid level env var, and the file-sink rotate and write failures. |
| `lib/runtime_log_sink.ml` | Forwards each `Agent_core.Log` record to the top-level `Log.emit`. The module name is built per record (`"agent_core:" ^ record.module_name`), so no static `Log.<Module>` preserves it. |
| `lib/fs_compat/` | Runs below the logging stack: `masc_log` depends on `fs_compat`, so `fs_compat` cannot call `Log`. Its `eprintf` report a malformed JSONL line, a cut incomplete JSONL tail, and failed fsync or close calls. |
| `lib/fd_accountant/` | Reports file-descriptor resource errors. When descriptors run out the file sink cannot open files, so these go to stderr. |
| `lib/server/server_base_path_guard.ml` | Refuses to start without a workspace, or with a base path that cannot be canonicalized, before `Log` is initialised. |
| `bin/main_eio.ml` | A base path that cannot be canonicalized, the `Out_of_memory` and `Stack_overflow` FATAL handlers (which must not allocate through the logging stack), build-provenance argument errors, and the `login`, `token` and `mcp-config` subcommands, whose output is the command's answer. Its "already running" lines use `Log.legacy_stderr` (see the legacy bridge row). |
| `bin/main_stdio_eio.ml` | Reports a base path that cannot be canonicalized before the server starts. On the stdio transport stdout is the protocol, so diagnostics go to stderr. |
| `bin/masc_tui.ml` | Start-up messages before the screen is drawn: a failed stderr redirect (it cannot say so through the sink it is still redirecting), and refusals to start (no interactive terminal, no embedded build commit, an unusable workspace). |
| `lib/exec_shim/exec_shim.ml` | `masc-exec-shim` is a static binary that runs on the remote endpoint, built from `unix` and a few small libraries without the masc logging stack. Its one stderr line is the usage message. |
| `lib/keeper/keeper_github_identity.ml` | `print_observation` and the `run_cli_*` functions print what `masc keeper github ...` was asked for. The rest of the module runs inside the server, so the exemption is wider than the functions that need it. Splitting the subcommands into their own module removes it. |
| `lib/config_dir_resolver/config_dir_resolver.ml` | `Log.warn ~ctx:context` and `Log.info ~ctx:context` use a runtime-computed component string. No static module preserves the per-call value. |
| `bin/masc_trace.ml`, `bin/masc_cost.ml`, `bin/masc_librarian_replay.ml`, `bin/masc_http_probe.ml`, `bin/masc_lane_cli_probe.ml`, `bin/keeper_capability_probe_cli.ml`, `bin/stagehand_model_probe.ml`, `bin/fusion_run.ml`, `bin/masc_checkpoint_purge.ml`, `bin/deployment_preflight_helper.ml` | Operator commands run at a terminal. Their stdout and stderr are the answer to the command (measurements, JSON receipts, usage and argument errors), not a server record. Routing them to the log would move them away from the person who asked. |
| `bin/masc_cli_setup.ml`, `bin/masc_cli_docker_session.ml`, `bin/masc_cli_onboarding.ml`, `bin/masc_cli_antigravity.ml`, `bin/masc_cli_account_login.ml`, `bin/masc_cli_codex_models.ml`, `bin/masc_cli_muse_models.ml`, `bin/masc_cli_model_resume.ml`, `bin/masc_cli_owner_upgrade.ml`, `bin/masc_cli_prerequisites.ml` | One-shot setup and onboarding commands. They report account, login and setup failures to the operator's terminal and print machine-readable receipts on stdout before any server or log sink exists. |
| `bin/gen_board_tool_registry.ml` | A Dune-time generator. Its `eprintf` reports a malformed Board TOML declaration to the build operator. |
| `lib/server/server_startup_takeover.ml`, `lib/backend/backend.ml`, `lib/workspace/workspace_query.ml`, `lib/mcp_server_eio_resource.ml` | The RFC-0079 legacy bridge. `Log.legacy_stderr` and `Log.legacy_traceln` emit a raw, unprefixed stderr line and mirror it into the ring with a `Legacy_*` source tag (read back by `dashboard/src/api/schemas/logs.ts`). Every call site embeds its own `[FATAL]`, `[WARN]` or `[DEBUG]` marker in the message, so migrating would double-prefix it and drop the `Legacy_*` source. |

A static component such as `"agent_core:event"` does route through `Log`: a
module's `name` string may contain a colon even though the OCaml identifier
cannot, and that site is the `Agent_core_event` module.
