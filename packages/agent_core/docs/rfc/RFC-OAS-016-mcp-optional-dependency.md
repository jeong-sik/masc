# RFC-OAS-016: Make `mcp_protocol` an Optional Dependency

| | |
|---|---|
| Status | Draft |
| Author | jeong-sik (with Claude analysis) |
| Created | 2026-05-12 |
| Target | `agent_sdk` (oas) |
| Supersedes | None |
| Related | `sub-library-decomposition-rfc.md` (overall sub-library structure — adjacent but separate concern) |

## 0. Summary

`agent_sdk.opam` lists `mcp_protocol >= 1.3.0` as an **unconditional** dependency. The `mcp_protocol` package is a fork (`jeong-sik/mcp-protocol-sdk`) not present on the opam registry, so every consumer of `agent_sdk` must pin the fork in their switch — even when they never instantiate an MCP server.

This RFC proposes splitting MCP integration into an optional sub-library `agent_sdk.mcp` so the core `agent_sdk` library has no `mcp_protocol` dep. Audit shows the coupling is **not structural**: `Mcp_protocol.Mcp_types` only leaks into one OAS implementation file (`lib/protocol/mcp_schema.ml`) and its interface (`lib/protocol/mcp_schema.mli`) — see §2.1 for the full list. What is load-bearing is OAS's **own** `Mcp.managed` / `Mcp_session.info` types being embedded in core agent state (`agent_types.ml`, `builder.ml`, `checkpoint*.ml`, `contract.ml`, `tool_middleware.ml`). Migration requires relocating those touchpoints behind an abstract type or callback, not rewriting MCP itself.

## 1. Problem

### 1.1 Surface

| Site | Verified |
|---|---|
| `agent_sdk.opam` (currently line 25 on `origin/main`; `agent_sdk.opam` is generated from `dune-project`, so the exact line drifts) | `"mcp_protocol" {>= "1.3.0"}` — no `with-test` / `with-doc` filter |
| `dune-project` `(package agent_sdk)` `depends` stanza | `(mcp_protocol (>= 1.3.0))` — bare, this is the source of truth |
| `lib/dune:6-22` | flat `agent_sdk` library lists `mcp_protocol`, `mcp_protocol.eio`, `mcp_protocol.http` in `(libraries ...)` |
| `lib/base/dune` (`agent_sdk_base`) | does **not** reference `mcp_protocol` |
| `lib/llm_provider/dune` (`llm_provider`) | does **not** reference `mcp_protocol` |

### 1.2 Consumer friction

Any consumer who wants to use `agent_sdk` for a non-MCP agent app must still pin `jeong-sik/mcp-protocol-sdk` (not on opam) in their switch. The fork-pin propagates to anyone who depends on their library, etc. Inverse: removing OAS from a project does not remove the fork pin from their `.opam` / switch state — it has to be cleaned by hand.

### 1.3 Why this PR didn't already happen during #557 / sub-library RFC

`sub-library-decomposition-rfc.md` (2026-05-04, Draft) targets compile-time isolation and build performance — its Phase 1 lifts `lib/protocol/`, `lib/pipeline/`, `lib/agent/` into sub-libraries that still depend on the parent `agent_sdk` (no consumer-facing dependency change). Whether `mcp_protocol` should be **optional for consumers** is a separate decision from "should `lib/protocol/` be its own dune library."

## 2. Coupling depth (verified)

### 2.1 Direct `Mcp_protocol*` references (the fork's modules) — confined to `lib/protocol/`

```
lib/protocol/mcp.ml:9          Mcp_protocol_eio.Client
lib/protocol/mcp_http.ml:2     Mcp_protocol_http.Http_client
lib/protocol/mcp_http.mli:1    Mcp_protocol_http.Http_client  (doc-comment reference)
lib/protocol/mcp_schema.ml:2   Mcp_protocol.Mcp_types  (as aliased Sdk_types)
lib/protocol/mcp_schema.mli:6  Mcp_protocol.Mcp_types
```

`mcp_schema.{ml,mli}` defines `mcp_resource` / `mcp_prompt` / `mcp_prompt_result` as **aliases** of `Mcp_protocol.Mcp_types.{resource,prompt,...}`. Anyone consuming those aliases inherits the fork dep transitively.

Grep `rg -l 'Mcp_protocol' lib/` returns nothing outside `lib/protocol/`. The fork barely leaks.

### 2.2 OAS-local `Mcp` / `Mcp_session` types embedded in core (the real coupling)

| Site | Reference |
|---|---|
| `lib/agent/agent_types.ml:32` | `mcp_clients : Mcp.managed list` (a field of `options`) |
| `lib/agent/agent_types.ml:308, :359` | `Mcp.close_all` calls |
| `lib/agent/agent.mli:41` | `Mcp.managed` in the public Agent signature |
| `lib/agent/builder.ml:51`, `builder.mli:60` | `Mcp.managed` in Builder API |
| `lib/agent/agent_config.ml:366-370, :455` (file removed 2026-07-21, test-only surface cut) | `Mcp.connect_and_load`, `Mcp_http.connect_and_load_managed` — gated by `when cfg.mcp_servers <> []` (dormant by default) |
| `lib/checkpoint.ml:34, :79` | `Mcp_session.info` in checkpoint record + `Replace_mcp_sessions` codec op |
| `lib/checkpoint_codec.ml:182, :309, :408, :496` | `Mcp_session.info` round-trip in checkpoint serialization |
| `lib/checkpoint_types.ml:29, :74` | `Mcp_session.info` in checkpoint record types |
| `lib/contract.ml:293`, `contract.mli:96` | `filter_mcp_clients : ... -> Mcp.managed list -> Mcp.managed list` |
| `lib/tool_middleware.ml:32` | `Mcp_schema.json_schema_to_params` |
| `lib/agent_sdk.ml:66-68`, `.mli:39-41` | Public re-export of `Mcp`, `Mcp_http`, `Mcp_session` from the SDK facade |

### 2.3 Runtime dormancy

`mcp_clients` defaults to `[]` (`agent_types.ml:156`, `builder.ml:123`). `agent_config.ml` only invoked `Mcp.connect_and_load*` when `cfg.mcp_servers <> []` (file removed 2026-07-21, test-only surface cut — the gated invocation path no longer exists; `git grep mcp_servers -- lib` is now 0). So the actual **MCP network/spawn code path is dormant by default** — but the embedded MCP types are always linked, and that is enough to require the fork.

## 3. Options

### Option A — status quo (rejected)

Keep `mcp_protocol` as an unconditional dep. Document the fork pin in `README` as a known friction point. Trade-off: zero refactoring cost; persistent consumer friction; "use OAS for other OCaml dev" stays compromised.

### Option B — `with-test` filter only (rejected)

`"mcp_protocol" {with-test & >= "1.3.0"}` so only test/example builds need it. Doesn't work: `mcp_protocol` is referenced in `lib/`'s production modules (per §2.1), not just tests. Filter would cause link failure on any production consumer.

### Option C — extract `lib/protocol/mcp*` into `agent_sdk.mcp` sub-library (recommended)

New dune library `agent_sdk.mcp` in `lib/protocol/` (or `lib/mcp/`):

```
lib/protocol/mcp/
├── dune          # (library (name agent_sdk_mcp) (public_name agent_sdk.mcp) (libraries agent_sdk_base mcp_protocol))
├── mcp.ml        # moved from lib/protocol/mcp.ml
├── mcp_http.ml   # moved from lib/protocol/mcp_http.ml
├── mcp_schema.ml # moved from lib/protocol/mcp_schema.ml
└── mcp_session.ml # moved from lib/protocol/mcp_session.ml
```

Then `agent_sdk.opam` drops `mcp_protocol` to a peer package (`agent_sdk_mcp.opam`, or part of a multi-package opam). Consumers who want MCP install both; consumers who don't, install only `agent_sdk`.

This is structurally simple IF nothing outside `lib/protocol/` references the moved modules. Today many things do (§2.2). So Option C must be staged behind a refactor that removes the cross-library leaks.

### Option D — invert the coupling via abstract types (the migration plan for C)

For each `Mcp.managed` / `Mcp_session.info` reference in core, introduce an **opaque handle**:

```ocaml
(* lib/base/mcp_handle.mli — new *)
type managed
(** Opaque MCP client handle; concrete representation lives in
    agent_sdk.mcp. Core sees only the handle. *)

val close_all : managed list -> unit Eio.Promise.or_exn list
```

The `agent_sdk.mcp` sub-library implements `managed` as `Mcp_protocol_eio.Client.t` (today's content) and provides the `close_all`, `connect_and_load`, etc. constructors. Core operates on `Mcp_handle.managed list` without knowing what's inside.

Same trick for:
- `Mcp_session.info` → `Mcp_handle.session_info` (a record of plain types: `name : string; tools : string list; ...`)
- `Mcp.json_schema_type_to_param_type` → moves to `lib/base/json_schema_to_param.ml` (it's a pure helper, no MCP runtime needed; the function lives in `Mcp` today only by historical accident)
- `Mcp_schema.json_schema_to_params` → similar

After inversion: `lib/protocol/mcp*` becomes a pure plug-in implementation behind `Mcp_handle`. `agent_config.ml` (removed 2026-07-21), `agent_types.ml`, `checkpoint*.ml`, `contract.ml`, `tool_middleware.ml`, `agent_sdk.ml` reference only `Mcp_handle.*` — no `mcp_protocol` dep.

### Option E — break-out the public re-export only (interim)

Drop `module Mcp = Mcp` etc. from `agent_sdk.ml` so the **public facade** doesn't expose MCP. Hosts still need `agent_sdk_mcp.{Mcp, Mcp_http, Mcp_session}` to use MCP, but the *core* `agent_sdk` no longer advertises those modules. Useful as a smaller staging step but doesn't drop the `mcp_protocol` dep on its own (the embedded `Mcp.managed` fields in `agent_types`/`checkpoint*` keep the linker bringing in the fork).

## 4. Recommendation

**Adopt Option C, staged by Option D over 2–3 PRs.** Phase plan:

**Phase 4.1** — move pure helpers out of `Mcp` (no behavior change, no API break):
- `Mcp.json_schema_type_to_param_type` → `lib/base/json_schema.ml` (or similar, in `agent_sdk_base`)
- `Mcp_schema.json_schema_to_params` → same target
- Update the remaining caller in `tool_middleware.ml`.
- Acceptance: `rg 'Mcp\.json_schema\|Mcp_schema\.json_schema' lib/` returns `lib/protocol/mcp*` and the new home only.

**Phase 4.2** — introduce `Mcp_handle.managed` / `session_info` abstract types in `agent_sdk_base`:
- New file `lib/base/mcp_handle.{ml,mli}` with opaque types and the operations used in core (`close_all`, accessors).
- Replace `Mcp.managed` with `Mcp_handle.managed` in: `agent_types.ml`, `agent.mli`, `builder.{ml,mli}`, `contract.{ml,mli}`, ~~`agent_config.ml` (gated paths)~~ (removed 2026-07-21 — do not restore for this phase; the surviving call sites are the complete list), `checkpoint_types.ml`, `checkpoint.ml`, `checkpoint_codec.ml`.
- `lib/protocol/mcp.ml` exposes a constructor `to_handle : Mcp.managed -> Mcp_handle.managed` (or makes `Mcp.managed` an alias of `Mcp_handle.managed`).
- Acceptance: `rg 'Mcp\.managed\|Mcp_session\.info' lib/` returns only `lib/protocol/`.

**Phase 4.3** — extract `lib/protocol/mcp*` into `agent_sdk.mcp` sub-library:
- New dune library `agent_sdk_mcp` (public name `agent_sdk.mcp`).
- Drop `mcp_protocol` from `lib/dune`'s top-level library.
- Either:
  - **C-1**: keep both packages in the same opam (`agent_sdk.opam`, `agent_sdk_mcp.opam` via dune `(package ...)` stanzas), so `opam install agent_sdk` doesn't pull MCP — consumer opts in with `opam install agent_sdk_mcp`; OR
  - **C-2**: keep one opam file but move `mcp_protocol` to a `depopts:` stanza — `depopts:` is opam's standard mechanism for optional package dependencies. Note that `optional` is *not* a filter variable (unlike `with-test`, `with-doc`, `build`, `dev`), so `{optional & ...}` inside `depends:` would not parse as opam intends. Combine `depopts:` with a dune `(optional)` library wrapper around `lib/protocol/mcp*` so the SDK still links when `mcp_protocol` is absent.
- Move public re-exports from `agent_sdk.ml` to `agent_sdk_mcp.ml` (or keep but gate behind a `(optional)` library include).
- Acceptance: `opam install agent_sdk` in a clean switch does **not** pull `jeong-sik/mcp-protocol-sdk`.

## 5. Non-goals

- Replacing `jeong-sik/mcp-protocol-sdk` with an opam-registered upstream package — out of scope (orthogonal concern, also requires upstream coordination).
- The broader sub-library decomposition (`agent_sdk.protocol`, `agent_sdk.pipeline`, `agent_sdk.agent`) covered by `sub-library-decomposition-rfc.md` — independent. Phase 4.3 of this RFC could land before or after that one; they touch different files.
- Removing `bisect_ppx` (the other fork dep). It's already `with-test`, so it doesn't bite production consumers the same way.

## 6. Acceptance criteria

- `opam install agent_sdk` in a fresh switch does not require `jeong-sik/mcp-protocol-sdk` to be pinned.
- An OCaml project that depends on `agent_sdk` (only) and never instantiates MCP builds without the fork.
- A project that wants MCP installs `agent_sdk_mcp` (or whatever the optional package is named) and gets identical functionality to today.
- `rg 'Mcp_protocol' lib/` returns matches only in the new `agent_sdk.mcp` sub-library; `rg 'Mcp_protocol' lib/base lib/agent lib/pipeline lib/llm_provider` returns nothing.
- Existing checkpoints (pre-refactor) deserialize correctly (the `Mcp_session.info` field becomes `Mcp_handle.session_info`; codec compatibility verified by replaying a saved checkpoint).
- `agent_sdk_mcp` exports identical user-facing API to today's `Mcp` / `Mcp_http` / `Mcp_session` so existing consumers migrate by `s/Agent_sdk.Mcp/Agent_sdk_mcp.Mcp/g`.

## 7. Risk register

| Risk | Mitigation |
|---|---|
| Phase 4.2 abstract type breaks downstream codecs that decode `Mcp_session.info` from external JSON | Keep the JSON schema of the embedded MCP session field byte-identical; only the OCaml type name changes. Run existing `test/test_checkpoint.ml` round-trip with a pre-refactor fixture. |
| `Mcp.json_schema_type_to_param_type` consumers outside OAS | Grep is internal-only at the moment, but the public facade exports `Mcp`, so external code may transitively call it. Provide a 1-version deprecation alias in `Mcp` that delegates to the new home. |
| dune `(optional)` library semantics surprise opam solvers | If C-2 chosen, validate with `opam install --dry-run agent_sdk` on a freshly bootstrapped switch. Fall back to C-1 (two-package split) if surprises emerge. |
| `Phase 4.3` collides with `sub-library-decomposition-rfc.md` Phase 1's `agent_sdk.protocol` extraction | Sequence: land 4.2 first (abstract types) — both decompositions become safe afterwards because the moved files no longer leak `Mcp_protocol` symbols. |

## 8. Out of scope (for this RFC, but listed so they aren't lost)

- `structured.ml`'s `add_retry_usage` helper silently treats `None` `cost_usd` as `0.0` — same antipattern shape as the closed #555 / the just-landed `max_cost_usd` fix, in yet another code path. Track separately.
- `lib/runtime.mli` exposing coordinator-shaped types (`participant_state`, `worker_id`) via the public facade — separate RFC.

---

*This RFC is implementation-ready for Phase 4.1; Phases 4.2 and 4.3 should be re-scoped after 4.1 lands and the actual surface of `Mcp_handle` is shaken out.*
