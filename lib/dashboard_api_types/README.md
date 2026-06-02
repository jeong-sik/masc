# dashboard_api_types

Typed JSON wire contracts shared between the OCaml dashboard HTTP handlers and
the Bonsai client island (`dashboard_bonsai/`).

## Purpose

This library is the **single source of truth** for the shape of every JSON
response the Bonsai island consumes. Two consumers:

- **Server** — `lib/dashboard/dashboard_http_*.ml` serialize via
  `<Module>.response_to_yojson` instead of hand-rolling
  `Yojson.Safe.t` trees.
- **Client** — `dashboard_bonsai/src/*_types.ml` deserialize via
  `<Module>.response_of_yojson`.

A schema change is a single `.ml` edit; both sides re-compile against the
new type.

## Modules

| Module | Route | Consumers |
|---|---|---|
| `Keepers` | `GET /dashboard/b/api/keepers/summary` | focus card · roster · swimlane · ctx pressure chart |

More modules will land as Bonsai islands expand (logs already uses a separate
`Logs_types` module inside `dashboard_bonsai/src/` and will be lifted here
once it stabilizes).

## Why a dedicated library (not `lib/dashboard/`)

- **Client-shareable**: Bonsai compiles via `bonsai-dashboard` opam switch
  (OxCaml 5.2). Importing `masc_mcp.dashboard` would drag in Eio, Unix,
  filesystem helpers the client cannot compile.
- **Zero side effects**: pure record definitions + ppx-generated JSON
  converters. No Eio, no Unix, no logging. Safe to link anywhere.
- **Versioned wire contract**: a breaking JSON change requires editing this
  library, making review scope obvious.

## ppx strategy

Server uses `ppx_deriving_yojson` (the same ppx already in `lib/types/`).
For the client, Bonsai's `ppx_yojson_conv` can re-parse the same record by
copying the module file or by generating a mirror with compatible field
attributes. Phase 1 uses the simplest path: server emits the JSON, client
parses with a small hand-written `of_yojson` in `dashboard_bonsai/src/`.
Full ppx sharing is Phase 2.

## Guarantees we do **not** make

- Field order in generated JSON — use `strict = false` so clients tolerate
  extra fields and server can add without breaking the contract.
- Variant tags — encoded as JSON strings (`"Live"` / `"Warn"` / `"Dead"`).
  Renaming requires a paired server+client deploy.
- Backward compatibility for removed fields — remove at end of a Bonsai
  migration phase only, never mid-release.
