---
rfc: "0058"
title: "Cascade Catalog Partial Parse Resilience"
status: Draft
created: 2026-05-17
updated: 2026-05-17
author: vincent
extends: "0058"
supersedes: []
superseded_by: null
related: ["0042", "0027", "0066"]
implementation_prs: []
---

# RFC-0058 Phase 8: Cascade Catalog Partial Parse Resilience

| | |
|---|---|
| Status | Draft |
| Depends-on | RFC-0058 §2.4 (Cross-reference validation at load time), Phase 5 (closed variant erase) |
| Scope | `Cascade_declarative_hotpath.try_load_declarative` return shape; downstream `keeper_cascade_profile` validation; reserved-name fallback obsolescence |
| Breaking | No — public API is widened (additive); existing `Ok snapshot` shape preserved |

## 1. Problem

cascade.toml has 4 well-formed `[tier-group.*]` entries (`runpod_mtp`, `local_mtp`, `ollama_cloud_stable`, `strict_tool_candidates`). 9 keeper .toml files reference them via `cascade_name = "tier-group.runpod_mtp"` etc.

Server log (2026-05-17 12:29:43, masc-mcp-8935.log:562-686) — all 9 rejected at load time:

```
[WARN] [Keeper] toml_loader: skipping analyst.toml: ...
  invalid cascade_name 'tier-group.ollama_cloud_stable' (
    reserved: tier-group.glm-coding-with-spark, tier-group.strict_tool_candidates;
    declarative cascade catalog invalid:
      (Cascade_declarative_adapter.Provider_not_found "claude");
      (Cascade_declarative_adapter.Binding_resolution_failed "claude.claude-api-sonnet");
      ...
  )
```

cascade.toml in mid-edit state held a stale `[claude.claude-api-sonnet]` binding pointing at a removed `[providers.claude]`. **One stale binding** invalidates the **entire catalog**. Once the catalog is `Error`, keeper toml validation drops to the `reserved_cascade_names` fallback list (2 entries), which excludes 3 of 4 production tier-groups in active use. 9 keepers fail to load even though every tier-group they reference is well-formed.

### 1.1 Live trace — the cliff

`lib/cascade/cascade_declarative_hotpath.ml` exposes:

```ocaml
val try_load_declarative :
  string -> (decl_snapshot, adapter_error list) result option
```

— a binary `Ok snapshot | Error errors`. `lib/keeper/keeper_cascade_profile.ml:105-122` (`declarative_catalog_lookup_names`) forwards binary:

```ocaml
match Cascade_declarative_hotpath.try_load_declarative path with
| Some (Ok snapshot) -> Ok (qualified_names_of_declarative_snapshot snapshot ...)
| Some (Error errors) -> Error ("declarative cascade catalog invalid: " ^ rendered)
```

`lib/keeper/keeper_types_profile.ml:807-844` consumes that `Error` and drops to `reserved_cascade_names`. Three layers, each fail-closed, compose into total catastrophe for a single bad binding.

### 1.2 Why this violates RFC-0058 §2.4

RFC-0058 §2.4 states *"Cross-reference validation happens at load time."* The intent is *cross-reference invariants are detected at load, not at dispatch*. The current implementation interprets it as *the whole catalog is either invariant-clean or unusable*. A 1-binding error nullifies 11 valid bindings, 4 valid tier-groups, and 19 valid routes. That is not validation — that is fail-stop.

### 1.3 Why `reserved_cascade_names` is also a smell, but not the root

`lib/keeper/keeper_config.ml:35-43` hardcodes `phase_routing_cascade_names = [local_only_cascade_name; local_recovery_cascade_name]` and `tool_use_strict_cascade_name`. `keeper_types_profile.ml:47-50` unions them as `reserved_cascade_names`. These are used as a *safe minimal fallback* when the catalog `Error`-s, and as a fast-path skip in normal validation (line 803-805).

Treating the reserved list as the root would lead to a workaround-class fix: *expand the reserved list to include all production tier-groups*. That is N-of-M (CLAUDE.md §workaround rejection bar): every new tier-group requires an OCaml edit, the SSOT moves *back* into code, and RFC-0058 §2.1 is violated more, not less.

The reserved list is **legitimate as a phase-routing internal**, but **illegitimate as a fallback for missing catalog data**. The right fix is to make the catalog *not need* a hardcoded fallback. That requires Bug B's resolution: partial-parse.

## 2. Root cause

`try_load_declarative` returns a binary result. There is no representation of *partial success*. Every consumer downstream is forced to choose: trust everything, or trust nothing.

The adapter (`lib/cascade/cascade_declarative_adapter.ml:255, 270, 392`) already *accumulates* `errors` in a `ref`, then converts to `Error errors` only at the boundary. Internally it is *already partial* — it builds whatever bindings/tiers/groups it can resolve, and records the rest as errors. The surface throws away the partial result if any error exists.

Quote (`cascade_declarative_adapter.ml:268-273`):
```ocaml
| None ->
    errors :=
      Binding_resolution_failed (Printf.sprintf "%s.%s" ...) :: !errors;
    None
```

— the `Some config` and `None` paths are already handled per-binding. The catalog **could** expose `{ valid_bindings; errors }` honestly. Today it collapses both into `Result`.

## 3. Design

### 3.1 Widen `try_load_declarative` return shape

Add a new structured snapshot result alongside the existing binary one:

```ocaml
(* lib/cascade/cascade_declarative_hotpath.mli — NEW *)

type partial_load_result = {
  snapshot : decl_snapshot;
  (** Always present. Contains whatever bindings/tiers/groups/routes
      could be resolved. May be empty if every entry failed. *)
  errors : Cascade_declarative_adapter.adapter_error list;
  (** Per-entry errors. Empty list = clean parse. Non-empty = partial. *)
}

val try_load_partial : string -> partial_load_result option
(** Replacement for [try_load_declarative]. Returns [None] only when the
    file is not a declarative cascade catalog at all (e.g. legacy profile
    format). When the file is a declarative catalog, returns
    [Some { snapshot; errors }] — partial parses surface valid entries
    in [snapshot] and report failed entries in [errors].

    The [snapshot] obeys the invariant that every binding, tier, and
    tier-group it contains is internally consistent (all cross-references
    resolve). Entries with unresolved references are omitted, not
    half-stitched.

    [try_load_declarative] is retained for backward compatibility:
    [Some (Ok _) | Some (Error _)] for callers that need binary semantics
    (notably the boot-time gate at
    [Cascade_catalog_runtime.validate_path_result], where a fully clean
    parse is a deliberate hard requirement). *)
```

Internally `try_load_partial` walks the adapter's per-binding pipeline and stops *only* when there is no resolvable binding to seed the snapshot from. `Ok` is a degenerate case of `try_load_partial` with `errors = []`.

### 3.2 Adapter-level partial invariant

The adapter (`cascade_declarative_adapter.ml`) must preserve the invariant: **a tier-group surfaced in the snapshot has at least one resolvable member**. Tiers that resolve zero members are omitted from the snapshot and emitted as `Tier_group_empty` errors. This avoids the *half-stitched* failure mode (a tier-group with a dangling member reference that crashes at dispatch).

Concretely:

| Adapter unit | Resolves | Surfaces |
|---|---|---|
| Binding (`[<p>.<m>]`) | provider + model | self if both present; else `Provider_not_found` / `Model_not_found` |
| Tier (`[tier.X]`) | member bindings | self if ≥1 member resolved; else `Tier_group_empty "tier.X"` |
| Tier-group (`[tier-group.G]`) | tier references | self if ≥1 tier resolved; else `Tier_group_empty "tier-group.G"` |
| Route (`[routes.R]`) | tier-group | self if tier-group resolved; else `Binding_resolution_failed "routes.R"` |

The snapshot already has this shape internally; we change *exposure*, not *resolution semantics*.

### 3.3 Downstream consumers

| Consumer | Today | After |
|---|---|---|
| `declarative_public_catalog_names` (kcp.ml:81) | `Error` on any adapter error | `Ok names` from `partial_load_result.snapshot`; log errors to server log once per reload mtime |
| `declarative_catalog_lookup_names` (kcp.ml:105) | same | same |
| `catalog_names_for_validation` (kcp.ml:175) | `Error` on any adapter error | `Ok names` from valid subset; keeper toml validation now sees actual tier-groups |
| `Cascade_catalog_runtime.validate_path_result` (boot gate) | hard fail on any error | **unchanged** — boot still requires clean catalog; partial only applies to live reload |
| `keeper_types_profile.ml:807-844` fallback path | reached on every adapter error | reached *only* when catalog has zero resolvable entries; reserved list narrows back to *internal phase-routing only* |

The boot-time gate stays strict deliberately: starting up with a broken config should still fail loudly. The change applies to **live reload** and **subsequent toml validation**, where the operator already has the system running and an edit drift should degrade gracefully.

### 3.4 Reserved-name obsolescence

Once `catalog_names_for_validation` returns the valid subset for partial catalogs:

- `reserved_cascade_names` in `keeper_types_profile.ml:47-50` is still used as a *fast-path skip* (line 803-805). That role is fine — it short-circuits for phase-routing internal names (`tier.local_only`, `tier.local_recovery`, `tier-group.strict_tool_candidates`). These are RFC-0058-aligned: they are *names defined by RFC-0066* (phase routing), not vendor names hardcoded.
- The *fallback* role at line 838-844 (`Error fallback_error` branch) becomes unreachable in practice, because `catalog_names_for_validation` now returns `Ok []` rather than `Error` when the catalog is degraded. Keeping the branch as defensive code is fine; treating it as the production load path is the bug.

No code deletion is mandatory in Phase 8. The fallback becomes correct-but-irrelevant.

## 4. Implementation phases

### Phase 8.1 — Adapter partial surface (this RFC, PR-1)

**Scope (smallest viable):** Add `try_load_partial` + `partial_load_result` to `cascade_declarative_hotpath.{ml,mli}`. Keep `try_load_declarative` as a thin wrapper that returns `Ok snapshot` when `errors = []` and `Error errors` otherwise.

**Files:**
- `lib/cascade/cascade_declarative_hotpath.ml` — new type, new function, refactor `try_load_declarative` to wrap it.
- `lib/cascade/cascade_declarative_hotpath.mli` — expose `partial_load_result`, `try_load_partial`.

**Tests:** `test/test_cascade_declarative_hotpath_partial.ml` — fixture with 1 stale binding + 4 valid tier-groups; assert `snapshot.profile_names` contains all 4 tier-group names; `errors` list contains exactly the 1 binding failure.

**No downstream changes in PR-1.** This is a pure surface widening.

### Phase 8.2 — Keeper validation consumes partial (PR-2)

**Scope:** Switch `declarative_public_catalog_names` + `declarative_catalog_lookup_names` to call `try_load_partial` and treat non-empty `errors` as *log + degrade*, not *fail*.

**Files:**
- `lib/keeper/keeper_cascade_profile.ml:81-130` — replace match arms; emit `Log.Cascade.warn` per unique error per mtime via a small `Hashtbl.t` keyed on `(path, mtime)` to avoid log spam.

**Tests:** `test/test_keeper_cascade_validation_partial.ml` — load cascade.toml with mid-edit drift; assert `catalog_names_for_validation` returns `Ok names` containing the production tier-groups; assert log entries record the dropped entries exactly once.

### Phase 8.3 — Boot gate semantics (PR-3)

**Scope:** Make `Cascade_catalog_runtime.validate_path_result` *explicit* about its strict mode. Document that boot remains all-or-nothing while live reload is partial. Add a `--cascade-allow-partial-boot` operator flag (off by default) for emergency boot with degraded config.

**Files:**
- `lib/cascade/cascade_catalog_runtime.ml` — flag gate.
- `bin/server/server_runtime_bootstrap.ml` — flag wiring.
- `docs/operator/cascade-degraded-mode.md` — operator runbook.

**Skipped if 8.2 covers the live-reload need** without operator-facing boot relaxation. Phase 8.3 is *opt-in extension*, not required for the original 9-keeper-skip incident.

## 5. Non-goals

- Not changing `provider_kind` variant elimination (that is RFC-0058 Phase 5).
- Not making *invalid binding repair* automatic (no fuzzy matching, no "did you mean"). The adapter reports the error; the operator fixes the toml.
- Not expanding `reserved_cascade_names` to cover production tier-groups — explicitly rejected per CLAUDE.md §workaround rejection bar §3 (N-of-M abstraction absence).
- Not changing dispatch-time behavior. Cascade at runtime still operates on the resolved snapshot; this RFC only changes which snapshot reaches the runtime when the source toml has partial errors.

## 6. Verification

### 6.1 Reproduction of the 2026-05-17 incident

```bash
# Setup: cascade.toml with a stale [claude.claude-api-sonnet] binding
# but valid [tier-group.runpod_mtp] etc.

# Before this RFC:
$ sb masc keeper-list
# 9 keepers (analyst, imseonghan, jobsian_purist, masc-improver,
#  ramarama, sangsu, scholar, tech_glutton, velvet-hammer) skip on load.

# After this RFC (Phase 8.1 + 8.2):
$ sb masc keeper-list
# 16 keepers load. Server log records:
#   [WARN] [Cascade] catalog drift in cascade.toml mtime=...:
#     Binding_resolution_failed "claude.claude-api-sonnet"
#   (logged once per mtime)
```

### 6.2 Bug B is the only fix needed; Bug A is implicitly resolved

Once Phase 8.2 lands:

- Keeper toml validation reaches `catalog_names_for_validation` → `Ok [tier-group.runpod_mtp; tier-group.local_mtp; ...]`.
- Reserved fallback branch (kcp_types_profile.ml:838-844) becomes unreachable on the production codepath. It remains as defensive code for the catastrophic case (catalog has zero resolvable entries, e.g. corrupted file).
- No edit to `reserved_cascade_names` is required.

This is **one fix, not two**. The earlier diagnosis treating Bug A as a separate concern was wrong — it would have led to a workaround-class expansion of the reserved list.

### 6.3 Property — partial snapshot invariant

`test/test_cascade_declarative_hotpath_partial.ml` asserts via property-based generation:

```
∀ catalog c:
  let { snapshot; errors } = try_load_partial c in
  every tier-group g in snapshot has ≥1 resolvable member
  every tier t in snapshot has ≥1 resolvable binding
  errors ∩ snapshot.profile_names = ∅
```

## 7. Migration

No operator action required. cascade.toml schema unchanged. Existing keepers that were already loading continue to load. Keepers that were silently skipped due to upstream catalog errors begin loading on the next live reload after Phase 8.2.

`try_load_declarative` is preserved as a backward-compat wrapper for the duration of Phase 8. Removal candidate after Phase 8.3 ships and no internal caller uses the binary form.

## 8. Open questions

- **Q: Should `Tier_group_empty` for *expected-to-be-empty during edit* tier-groups be elevated to error or silenced?** Tentative: keep as `WARN`, dedup by `(path, mtime, tier-group-name)`. Operators editing cascade.toml often leave temporarily empty groups; spamming the log obstructs the actual edit.
- **Q: Boot gate — does `cascade-allow-partial-boot` introduce a footgun?** Tentative: yes, hence off-by-default. Operators using it must accept that some keepers will not auto-boot. The dashboard should reflect this via a banner. Phase 8.3 follow-up.
- **Q: Hot-reload of `try_load_partial` — does it interact with the existing additive merge?** No: `try_load_partial` is a pure function of the file at a given path+mtime. The merge layer at `Cascade_catalog_runtime` continues to compare snapshots and swap atomically.

## 9. References

- `lib/cascade/cascade_declarative_hotpath.ml:32` — `decl_snapshot`
- `lib/cascade/cascade_declarative_adapter.ml:17-24` — `adapter_error`
- `lib/keeper/keeper_cascade_profile.ml:81-130` — current binary consumers
- `lib/keeper/keeper_types_profile.ml:47-50, 803-844` — `reserved_cascade_names` site
- `lib/keeper/keeper_config.ml:35-43` — phase routing cascade names (legitimate internal use)
- `~/me/.masc/logs/masc-mcp-8935.log:562-686` — incident trace 2026-05-17 12:29:43
- RFC-0058 §2.1, §2.4 — *Code never knows provider names*, *Cross-reference validation at load time*
- CLAUDE.md §워크어라운드 거부 기준 §3 — N-of-M abstraction absence (basis for rejecting reserved-list expansion)

## 10. Implementation log

(Filled in as PRs land.)

- 2026-05-17 — RFC body draft on `feat/rfc-0058-phase-8-cascade-toml-ssot`. PR-1 (Phase 8.1 adapter partial surface) in progress.
