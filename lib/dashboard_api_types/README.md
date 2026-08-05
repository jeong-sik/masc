# dashboard_api_types

Typed JSON wire contracts shared between the OCaml dashboard HTTP handlers and
the Bonsai client island (`dashboard_bonsai/`).

## Purpose

This library is the **single source of truth** for the shape of every JSON
response the Bonsai island consumes. Two consumers:

- **Server** — `lib/dashboard/dashboard_http_*.ml` serialize via
  `<Module>.response_to_yojson` instead of hand-rolling
  `Yojson.Safe.t` trees.
- **Client** — `dashboard_bonsai/src/*_types.ml` restate the record by hand
  and read it with `Yojson.Safe.Util`. The client does not link this
  library, so it never calls a generated decoder.

Only the encoder is derived (`to_yojson`). A schema change is therefore two
edits — this library, then the client mirror — and no compiler checks that
the second one happened.

## Modules

| Module | Route | Consumers |
|---|---|---|
| `Keepers` | `GET /dashboard/b/api/keepers/summary` | focus card · roster · swimlane · ctx pressure chart |

More modules will land as Bonsai islands expand (logs already uses a separate
`Logs_types` module inside `dashboard_bonsai/src/` and will be lifted here
once it stabilizes).

## Why a dedicated library (not `lib/dashboard/`)

- **Client-shareable**: Bonsai compiles via `bonsai-dashboard` opam switch
  (OxCaml 5.2). Importing `masc.dashboard` would drag in Eio, Unix,
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

- Field order in generated JSON — the client reads each field by name with
  `Yojson.Safe.Util.member`, so order is free and a field the mirror does not
  know about is ignored rather than fatal.
- Variant tags — `ppx_deriving_yojson` emits a one-element array
  (`["Live"]` / `["Warn"]` / `["Dead"]`), not a bare string. Renaming a
  constructor requires a paired server+client deploy.
- Backward compatibility for removed fields — remove at end of a Bonsai
  migration phase only, never mid-release.
