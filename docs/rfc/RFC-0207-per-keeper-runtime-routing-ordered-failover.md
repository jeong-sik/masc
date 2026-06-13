---
rfc: "0207"
title: "Per-keeper LLM runtime routing"
status: Draft
created: 2026-06-01
updated: 2026-06-01
author: jeong-sik
supersedes: []
superseded_by: null
superseded_sections:
  - section: "§2"
    by: "0211"
    note: "Surface choice (persona model field as the single surface) is superseded by RFC-0211 (runtime.toml keeper-assignment SSOT). Part A routing mechanism stands."
related: ["0001", "0206", "0211"]
implementation_prs: []
---

# RFC-0207 — Per-keeper LLM runtime routing

- Status: Part A implemented (per-keeper primary selection). Part B (ordered failover) deferred.
- Date: 2026-06-01
- Builds on: RFC-0206 (single-binding `Runtime`), RFC-0001 (silent-substitution anti-pattern).

## 0. Summary

A keeper can already declare which provider-model it runs on, via its persona
TOML `model = "provider.model"` field (e.g. `keepers/echo.toml` →
`model = "ollama_cloud.deepseek-v4-pro"`). That declaration reached the
reconcile/status layer but **never reached the wire**: the turn dispatcher
returned the global `[runtime].default` for every keeper. This RFC fixes the
dispatcher to honour the existing persona selection. No new configuration
surface is introduced.

## 1. Problem

Under RFC-0206, all keepers route through one `[runtime].default`. Eight keepers
were assigned `model = "ollama_cloud.deepseek-v4-pro"` (provider spread off a
single RunPod dependency), but every turn still ran on the RunPod default — zero
`deepseek` calls in fleet logs.

The per-keeper intent died at two points:

1. `keeper_meta_contract.runtime_id_of_meta` discarded its `keeper_meta`
   argument (`_m`) and returned `Runtime.get_default_runtime_id ()`
   unconditionally.
2. `keeper_turn_driver` (the dispatch site) ignored the `runtime_id` it was
   passed and used `Runtime.get_default_runtime ()` (the default) directly.

Fixing only ① still dispatches the default at ②; both are fixed.

## 2. There is only one surface: the persona `model` field

The keeper persona TOML already carries the per-keeper runtime selection:

- `keepers/<name>.toml` `[keeper] model = "provider.model"` (the key is parsed
  as `runtime_id`/`model`, both populating `keeper_profile_defaults.model`).
- Parsed and cached by `Keeper_types_profile.load_keeper_profile_defaults`
  (config files are static at runtime; the cache key includes `MASC_CONFIG_DIR`).
- Resolved by `Keeper_runtime.effective_declarative_runtime_id` for the reconcile
  change-detector and the dashboard status override view.

An earlier draft of this RFC added a *second* surface (`[llm_runtime.<keeper>]`
in the shared `runtime.toml`). That was rejected: it duplicated the
existing persona field, split per-keeper data across two files, and — because
the dispatcher read one surface while the reconcile/status layer read the other
with the opposite precedence — created a split-brain that would flag `runtime`
drift on every ~30 s reconcile sweep (a re-sync write storm, cf. #10061).

The dispatcher is allowed to read the persona field directly: the dependency
direction is `keeper_types_profile` (low) ← `keeper_meta_contract` (mid)
← `keeper_runtime` (high), and `keeper_meta_contract` already depends on
`Keeper_types_profile`. There was never a dependency wall forcing a new surface.

## 3. Design

`runtime_id_of_meta` resolves a keeper's runtime from the SAME `defaults.model`
source as `effective_declarative_runtime_id`:

- persona `model = Some "provider.model"` → that id (after `String.trim`);
- otherwise → the documented `[runtime].default`
  (`Runtime.get_default_runtime_id ()`), NOT a silent substitution.

Because both the dispatcher and the declare/status layer read `defaults.model`,
they cannot disagree — one surface, no storm. The reconcile change-detector
(`runtime_changed = runtime_id_of_meta meta <> effective_declarative_runtime_id
defaults meta`) is now always false unless the persona file actually changed.

### Validation (fail-fast at dispatch, RFC-0206 §2.1)

The persona `model` is a raw string. It is validated at *dispatch*: the driver
calls `Runtime.get_runtime_by_id id`, and an id that does not resolve to a
materialized runtime returns `None`, so the driver returns an
`Agent_sdk.Error.Internal` instead of silently substituting the default. There
is no startup-time validation pass (the persona selection is per-keeper and
config-static; a typo surfaces as a loud dispatch error on that keeper's first
turn).

## 4. As-built surface

- `Runtime.get_runtime_by_id : string -> t option` (new) — resolve a runtime by
  its binding-key id `"provider.model"`; reads `runtimes_ref` (no module-level
  eager binding — NB(R2)).
- `Keeper_meta_contract.runtime_id_of_meta` — reads
  `(Keeper_types_profile.load_keeper_profile_defaults m.name).model`, else the
  default.
- `keeper_turn_driver` — dispatches via `get_runtime_by_id runtime_id`;
  unresolved id → fail-fast `Internal` error.
- `Keeper_runtime.effective_declarative_runtime_id` and the
  `keeper_status_bridge` copy — unchanged behaviour; comments now record that
  they share the `defaults.model` source with the dispatcher (do not re-fork).

No schema, TOML parser, or config-file changes. The cascade concept is not
reintroduced.

## 5. Migration

Zero config migration for Part A. The eight keepers already declare
`model = "ollama_cloud.deepseek-v4-pro"`; once the new binary is deployed, the
dispatcher honours it and routes those keepers to `ollama_cloud` immediately.
The `ollama_cloud.deepseek-v4-pro` binding already materializes in
`runtime.toml` (`[providers.ollama_cloud]` + `[models.deepseek-v4-pro]` +
`[ollama_cloud.deepseek-v4-pro]`).

## 6. Part B — ordered failover (deferred)

Static per-keeper selection is Part A ("1번"). Ordered failover ("3") is Part B:
extend the persona with an optional ordered list (e.g.
`runtime_failover = ["..."]`) consumed by the reactive failover lane in
`keeper_error_classify.ml`. That file is a contended, broken-main-history shared
surface (#19679 landed a `degraded_rotation_*` lane there), so Part B ships as a
separate PR with a broadcast + cross-review. Part A does not touch it; on a
recoverable failure the existing `degraded_rotation` fallback still applies.

## 7. Tests

`test/test_runtime_per_keeper_routing.ml` (5 cases, self-initialising):

1. persona `model` drives `runtime_id_of_meta` (declared keeper → its selection,
   not the default);
2. undeclared keeper falls to `[runtime].default`;
3. `get_runtime_by_id` resolves a known id and returns `None` for an unknown id
   (driver fail-fast);
4. direct budget resolution uses the selected runtime's `max-context`;
5. the production `resolve_max_context_resolution_of_meta` path budgets against
   the persona runtime rather than the global default.

Whole-program `dune build @check` and `dune build .` are green; the existing
`runtime_id_of_meta` consumers (`test_keeper_identity_parse`,
`test_mcp_server_eio_call_tool`) show identical pre-existing direct-exec
behaviour at HEAD and with this change (they rely on the `dune runtest` harness
to initialise `Runtime`).
