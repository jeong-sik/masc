# OAS Bridge Clock Timeout Contract

Status: active as of 2026-06-26.

This contract is MASC-local. The OAS SDK still supports optional clocks for
compatibility, but MASC callers that go through `Masc_oas_bridge` must run with
a domain-local Eio environment that includes `sw`, `net`, and `clock`.

## Why Fail Closed

`Masc_oas_bridge` owns MASC's structural wall-clock timeout around trusted OAS
work. If the bridge runs without an Eio clock, it cannot enforce that budget.
The previous warning-and-run behavior silently converted configured timeouts
into unbounded execution.

Do not add a default-off opt-out flag that restores clockless bridge execution.
That would preserve the unsafe behavior this contract removes.

Callers registered in `Env_config_oas_bridge.known_callers` must have finite
checked-in defaults. The bridge rejects `Float.infinity` even when supplied
directly, and env parsing treats `infinity` as invalid so resolution falls
through to the next lookup step. Known callers keep their checked-in defaults;
unknown callers fall through to the global env/default fallback. Advisory
dashboard judges are still separately bounded, but they no longer bypass the
bridge timeout wrapper.

## Migration

Server boot:

- `Server_runtime_bootstrap.init_runtime_context` supplies `clock`, `net`, and
  `sw`.
- `Server_runtime_bootstrap.create_server_state` initializes `Masc_eio_env`
  once, before any server code path can invoke `Masc_oas_bridge.run_safe` or
  `run_with_caller`.

Standalone Eio binaries:

- After `Eio_main.run` and `Eio.Switch.run`, use `Eio.Stdenv.clock env` and
  `Eio.Stdenv.net env` to initialize `Masc_eio_env`.
- `bin/fusion_run.ml` and `bin/masc_completion_trust_eval.ml` are the current
  standalone entrypoint examples. `bin/main_stdio_eio.ml` goes through
  `create_server_state`.

Additional OCaml domains:

- `Masc_eio_env` is `Domain.DLS` only. A new domain must initialize its own Eio
  handles before using OAS bridge calls.
- Do not borrow another domain's switch, net, or clock through a process-wide
  fallback.

Tests and scripts:

- Tests that intentionally exercise missing environment behavior should assert
  that the bridge returns an error without invoking the body.
- Tests that expect OAS work to run must use `Eio_main.run`, `Eio.Switch.run`,
  and `Masc_eio_env.init ~sw ~net ~clock ()`.

Fusion failure reporting:

- `Fusion_types.Timeout` is reserved for actual bridge timeout errors.
- Bridge/bootstrap failures are reported as `Fusion_types.Bridge_error` so
  operators do not confuse environment bugs with model timeouts.
