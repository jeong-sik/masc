# dashboard_api_types

Typed JSON wire contracts shared between the OCaml dashboard HTTP handlers and
the Bonsai client island (`dashboard_bonsai/`).

## Purpose

This library is the **single source of truth for the encoder** of the routes
listed under [Modules](#modules): the server serializes those responses from
records defined here. It is not a shared-compile SSOT, and it does not cover
every Bonsai route — the client does not link this library, so nothing here
constrains how the client reads the bytes, and routes not listed below have
their types elsewhere. Two consumers:

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

Server uses `ppx_deriving_yojson` and derives the encoder only. There is no
decoder here: #26992 removed the generated `*_of_yojson` API, and the client
reads each field with `Yojson.Safe.Util.member` in `dashboard_bonsai/src/`
rather than calling into this library at all — `dashboard_bonsai/src/dune`
does not depend on it.

This section used to describe that split as "Phase 1" with full ppx sharing
as "Phase 2". Sharing the ppx is not planned: it would require the client to
link this library, which is what the module boundary above exists to prevent.
The hand-written mirror is the arrangement, not a step toward another one.

## Guarantees we do **not** make

- Field order in generated JSON — the client reads each field by name with
  `Yojson.Safe.Util.member`, so order is free and a field the mirror does not
  know about is ignored rather than fatal.
- Variant tags — `ppx_deriving_yojson` emits a one-element array
  (`["Live"]` / `["Warn"]` / `["Dead"]`), not a bare string. Renaming a
  constructor requires a paired server+client deploy.
- Backward compatibility for removed fields — remove at end of a Bonsai
  migration phase only, never mid-release.
