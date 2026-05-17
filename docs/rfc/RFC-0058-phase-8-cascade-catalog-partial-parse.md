---
rfc: "0058"
title: "Cascade Catalog Partial Parse Resilience"
status: Active
created: 2026-05-17
updated: 2026-05-17
author: vincent
extends: "0058"
supersedes: []
superseded_by: null
related: ["0042", "0027", "0066"]
implementation_prs: [15733, 15737]
---

# RFC-0058 Phase 8: Cascade Catalog Partial Parse Resilience

| | |
|---|---|
| Status | Active — Phase 8.1 / 8.2 머지 (#15733 / #15737, 2026-05-17 04:23 UTC). Phase 8.1.5 / 8.3 / 8.4 미완 |
| Depends-on | RFC-0058 §2.4 (Cross-reference validation at load time), Phase 5 (closed variant erase) |
| Scope | `Cascade_declarative_hotpath.try_load_declarative` return shape; downstream `keeper_cascade_profile` validation; logging substrate; boot-gate tolerance; dispatch resolver partial invariants |
| Breaking | No — public API is widened (additive); existing `Ok snapshot` shape preserved |
| Self-review | Post-merge audit (this amend) surfaced 6 gaps; RFC scope expanded from 3 → 5 sub-phases. See §11. |

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

`lib/keeper/keeper_config.ml:35-43` defines `phase_routing_cascade_names = [local_only_cascade_name; local_recovery_cascade_name]` and `tool_use_strict_cascade_name`. `keeper_types_profile.ml:47-50` unions them as `reserved_cascade_names`. These are used as a *safe minimal fallback* when the catalog `Error`-s, and as a fast-path skip in normal validation (line 803-805).

Treating the reserved list as the root would lead to a workaround-class fix: *expand the reserved list to include all production tier-groups*. That is N-of-M (CLAUDE.md §workaround rejection bar): every new tier-group requires an OCaml edit, the SSOT moves *back* into code, and RFC-0058 §2.1 is violated more, not less.

**Correction (2026-05-17 amend)**: an earlier draft of this section claimed reserved is *"legitimate as a phase-routing internal only"*. That is **incorrect**. Server log evidence (`masc-mcp-8935.log:562` shows `reserved: tier-group.glm-coding-with-spark, tier-group.strict_tool_candidates`) proves the reserved list includes the *current resolved value* of `cascade_name_for_use`, which **reads cascade.toml at runtime**. Hence:

- `local_only` / `local_recovery` from `phase_routing_cascade_names` are *literal* internal names.
- `glm-coding-with-spark` (and similar) appear in reserved because `Cascade_routes.cascade_name_for_use Tool_required` resolves to whatever the toml currently maps `Tool_required` to (here, `tier-group.strict_tool_candidates`).

So reserved is **partially catalog-dependent**, not a pure compile-time enum. The dependency direction is *catalog → reserved*, not the other way. Expanding reserved manually still violates SSOT, but the diagnosis is sharper: reserved is *already SSOT-derived for its phase-routing slot*, and the gap is purely the *adapter binary surface* (Bug B). Phase 8.1 + 8.2 close that gap; reserved retains its legitimate role unchanged.

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

Phase 8 splits into **5 sub-phases**. Phase 8.1 + 8.2 shipped 2026-05-17 (#15733 / #15737). 8.1.5 / 8.3 / 8.4 are post-merge follow-ups identified in §11 (self-review).

### Phase 8.1 — Adapter partial surface — **MERGED #15733**

**Scope (smallest viable):** Add `try_load_partial` + `partial_load_result` to `cascade_declarative_hotpath.{ml,mli}`. Keep `try_load_declarative` as a thin wrapper that returns `Ok snapshot` when `errors = []` and `Error errors` otherwise.

**Files:**
- `lib/cascade/cascade_declarative_hotpath.ml` — new type, new function, refactor `try_load_declarative` to wrap it.
- `lib/cascade/cascade_declarative_hotpath.mli` — expose `partial_load_result`, `try_load_partial`.

**Tests:** `test/test_cascade_declarative_hotpath.ml` — `phase8_partial_parse` group, 3 cases; fixture with 1 stale `[ghost.ghost-model]` binding + 1 valid `[tier-group.local-group]`; assert `snapshot.profile_names` contains the tier-group; `errors` list non-empty.

**Status:** Merged at `423ad519` on 2026-05-17 04:23:28 UTC. No downstream caller switched; pure surface widening.

### Phase 8.2 — Keeper validation consumes partial — **MERGED #15737**

**Scope:** Switch `declarative_public_catalog_names` + `declarative_catalog_lookup_names` to call `try_load_partial` and treat non-empty `errors` as *log + degrade*, not *fail*.

**Files (as shipped):**
- `lib/keeper/keeper_cascade_profile.ml` — both helpers switched; `log_partial_catalog_errors` emits via `Log.Keeper.warn` (interim — see 8.1.5 below).
- `test/test_keeper_cascade_profile_partial.ml` — 3 integration cases against `catalog_names_for_validation`, `catalog_names`, `catalog_names_result`.

**Status:** Merged at `4cd26c33` on 2026-05-17 04:23:42 UTC. Operates on live reload path; keeper toml validation now accepts partial subsets.

**Known shortcomings (closed by 8.1.5 below):**
- Logging routed through `Log.Keeper` because `Log.Cascade` namespace does not exist yet — alerting that filters on cascade-domain warnings misroutes.
- No `(path, mtime)`-keyed dedup; helper is called by every keeper toml load, producing N×2 warns per reload.

### Phase 8.1.5 — Logging substrate cleanup — **PENDING (PR-B)**

**Scope:** Add `Log.Cascade` log namespace + structured `(path, mtime)` dedup for partial-catalog errors. Migrate `log_partial_catalog_errors` from `Log.Keeper.warn` to `Log.Cascade.warn`.

**Why:** The post-merge audit (§11) flagged log spam (N×2 warns per reload across N keeper toml files) and a misrouted namespace (cascade-domain issue logged under keeper-domain channel). Phase 8.2 deferred dedup with the rationale *"only if log volume becomes an issue"*, but the audit reclassified this as **must-have alongside 8.2**, not optional, to match CLAUDE.md §workaround §4 (avoid log spam as accepted operational state).

**Files:**
- New `Log.Cascade` namespace module (mirroring existing `Log.Keeper`).
- `lib/keeper/keeper_cascade_profile.ml` — rewrite `log_partial_catalog_errors` to:
  - dedup via `Hashtbl.t` keyed on `(path, mtime, sorted_error_signatures)` with `Atomic.t`-backed mutex
  - emit via `Log.Cascade.warn`
- Test: assert the same `(path, mtime)` triggers the warn *exactly once* across 9 sequential calls.

**Acceptance:** Server reload after a mid-edit cascade.toml triggers 1 WARN, not 32.

### Phase 8.3 — Boot-gate partial tolerance — **PENDING (PR-C)**

**Scope:** Make `Cascade_catalog_runtime.validate_path_result` explicit about its strict mode. Document that boot remains all-or-nothing by default while live reload is partial. Add a `--cascade-allow-partial-boot` operator flag (off by default) and a corresponding env var (`MASC_CASCADE_PARTIAL_BOOT=1`) for emergency boot with degraded config.

**Why this is reclassified from "skipped if 8.2 covers live reload" to "must-have"**: the post-merge audit (§11) corrected the assumption that 8.2 covers the original incident. **It does not.** 8.2 only helps if the server is already running when the operator edits cascade.toml. The 2026-05-17 incident reproduces equally on **cold boot** with a stale binding, and in that case the boot gate's binary `try_load_declarative` aborts startup before the keeper validators run. 8.3 is the only sub-phase that addresses cold-boot recovery.

**Files:**
- `lib/cascade/cascade_catalog_runtime.ml` — `validate_path_result` accepts `?allow_partial:bool` parameter; default `false` preserves current strict semantics.
- `lib/server/server_runtime_bootstrap.ml` — read flag from CLI / env, pass through.
- `dashboard/src/components/cascade-status` — visible banner when partial-boot mode is active.
- `docs/operator/cascade-degraded-mode.md` — runbook.

**Acceptance:** With `MASC_CASCADE_PARTIAL_BOOT=1` set, server boots with a mid-edit cascade.toml; dashboard banner reflects degraded mode; affected keepers boot or wait depending on cascade_name resolvability.

**Risk:** Operator footgun if the flag is left on. Mitigations: off-by-default; dashboard banner; structured log on every reload while flag is active.

### Phase 8.4 — Dispatch resolver partial invariants — **PENDING (PR-D)**

**Scope:** Verify (via tests, not code change) that the cascade dispatch path operates correctly when the snapshot reaching it carries `errors`. The catalog runtime's `known_profile_names` and downstream resolvers must:

- Return the **valid subset** when consulted with a partial snapshot
- Never expose a profile whose tier resolves to zero members
- Fail-loud (not silently fall back) when a `cascade_name` that *was* in the catalog drops out of the resolvable subset between two reloads

**Why test-only:** §3.3 already asserts the adapter-level invariant (a tier-group surfacing in the snapshot has ≥1 resolvable member). The risk surfaced in §11 is that no test currently exercises *runtime dispatch* against a partial snapshot. We add the tests; if they pass without code change, the invariant is preserved through dispatch. If they fail, that finding triggers Phase 8.4.1 (separate RFC scope).

**Files:**
- `test/test_cascade_dispatch_partial.ml` — new file. Cases:
  - dispatch on partial snapshot with valid tier resolves correctly
  - dispatch on partial snapshot referencing a now-missing tier returns a structured error (not silent fallback to reserved)
  - reload that drops a previously-resolvable tier triggers `WARN` and removes that tier from dispatch eligibility

**Acceptance:** All 3 cases pass against current main. If any fails, escalate to Phase 8.4.1 code fix.

## 5. Non-goals

- Not changing `provider_kind` variant elimination (that is RFC-0058 Phase 5).
- Not making *invalid binding repair* automatic (no fuzzy matching, no "did you mean"). The adapter reports the error; the operator fixes the toml.
- Not expanding `reserved_cascade_names` to cover production tier-groups — explicitly rejected per CLAUDE.md §workaround rejection bar §3 (N-of-M abstraction absence).
- Not changing dispatch-time behavior. Cascade at runtime still operates on the resolved snapshot; this RFC only changes which snapshot reaches the runtime when the source toml has partial errors.

## 6. Verification

### 6.1 What 8.1 + 8.2 actually verify — and what they don't

**Corrected scope (2026-05-17 amend).** An earlier draft of §6 claimed 8.1 + 8.2 *"unblock"* the 9 keeper skip incident. That is overstated. The accurate framing:

- **8.1 + 8.2 prevent recurrence** of the load-time skip *when the server is already running*. If an operator edits cascade.toml mid-session and introduces a stale binding, the live reload now degrades gracefully instead of dropping 9 keepers.
- **8.1 + 8.2 do NOT recover cold boot.** A server restart with a stale cascade.toml still aborts at `validate_path_result` (boot gate), before keeper validators run. **Cold-boot recovery is Phase 8.3's responsibility**, not 8.2's.
- **At time of merge, the 9 keepers were already booting.** The operator hand-edited cascade.toml to remove the stale `[claude.claude-api-sonnet]` binding before the PR landed, which is what actually restored the keepers. 8.1 + 8.2 prevent the *next* occurrence; they did not cause the *current* recovery.

Honest framing: **8.1 + 8.2 are a regression guard, not an active fix**. The active fix was the cascade.toml hand-edit. Phase 8.3 is the active fix for the *same incident shape on cold boot*.

### 6.2 What `reserved_cascade_names` still does

Once Phase 8.2 lands:

- Keeper toml validation reaches `catalog_names_for_validation` → `Ok names` containing the resolvable tier-groups.
- Reserved fallback branch (`keeper_types_profile.ml:838-844`) is reachable **only** when the catalog has zero resolvable entries (corrupt file, missing file, or all bindings broken). It remains correct as a defensive last resort.
- Reserved fast-path (`keeper_types_profile.ml:803-805`) is unchanged. As §1.3 (corrected) clarifies, this list is *catalog-derived for its phase-routing slot*, not a static hardcode. No edit to it is required by 8.x.

This is **one structural fix at the adapter surface**, not a deletion of reserved logic.

### 6.3 Property — partial snapshot invariant (Phase 8.1)

`test/test_cascade_declarative_hotpath.ml` `phase8_partial_parse` group asserts (currently as fixed example-based cases, not yet generative):

```
For the fixture (1 stale [ghost.ghost-model] + 1 valid [tier-group.local-group]):
  let { snapshot; errors } = try_load_partial fixture in
  snapshot.profile_names ⊇ { tier-group.local-group }
  errors ⊇ { Provider_not_found "ghost", Model_not_found "ghost-model" }
  errors ∩ snapshot.profile_names = ∅
```

A future Phase 8.1.1 may upgrade this to generative property-based testing.

### 6.4 Dispatch invariant (Phase 8.4, pending)

The above only covers the *catalog load* surface. The *runtime dispatch* path is **not yet covered by tests**. Phase 8.4 adds that coverage; if it surfaces a violation, Phase 8.4.1 fixes it.

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

- 2026-05-17 04:23:28 UTC — Phase 8.1 merged. PR #15733 (`feat/rfc-0058-phase-8-cascade-toml-ssot` → main, commit `423ad519`). Adapter partial surface (`try_load_partial`, `partial_load_result`) + 3 property tests.
- 2026-05-17 04:23:42 UTC — Phase 8.2 merged. PR #15737 (`feat/rfc-0058-phase-8-keeper-consume` → main, commit `4cd26c33`). Keeper validation helpers switched to `try_load_partial` + 3 integration tests.
- 2026-05-17 (this amend) — Post-merge self-review surfaced 6 gaps (§11). RFC scope expanded from 3 → 5 sub-phases. Phase 8.1.5, 8.3, 8.4 reclassified from optional to required.
- (pending) Phase 8.1.5 — `Log.Cascade` namespace + `(path, mtime)` dedup. PR-B.
- (pending) Phase 8.3 — boot-gate partial tolerance flag. PR-C.
- (pending) Phase 8.4 — dispatch resolver partial invariant tests. PR-D.

## 11. Post-merge self-review (2026-05-17)

After 8.1 + 8.2 merged, an adversarial review against the original RFC body identified 6 gaps. They are categorized below by whether they invalidate the merged work (none do) or extend scope (all 6 do).

### 11.1 Gaps that *extend scope*, do not invalidate merged work

| # | Gap | Severity | Closed by |
|---|---|---|---|
| 1 | Boot gate stays binary — cold boot with stale cascade.toml still aborts at `validate_path_result`. | **HIGH** | Phase 8.3 |
| 2 | Dispatch resolver has no test coverage against partial snapshots. | **MEDIUM** | Phase 8.4 |
| 3 | `log_partial_catalog_errors` emits via `Log.Keeper.warn` because `Log.Cascade` namespace does not exist. Alerting routes misclassify. | **LOW** | Phase 8.1.5 |
| 4 | No `(path, mtime)`-keyed dedup; helper emits per keeper toml load. | **LOW** | Phase 8.1.5 |
| 5 | §1.3 of the original RFC body claimed `reserved_cascade_names` is *"phase-routing internal only"*. Evidence shows it is *catalog-derived for the phase-routing slot*. Diagnosis was sharper than original draft. | **LOW** | This amend (§1.3 correction) |
| 6 | §6 framed 8.1 + 8.2 as *"unblock 9 keepers"*. Accurate framing is *regression guard*; the operator's cascade.toml hand-edit was the active recovery. | **LOW** | This amend (§6.1 correction) |

### 11.2 Why merged 8.1 + 8.2 are still correct

None of the 6 gaps reverse 8.1 or 8.2. Both:

- Preserve the existing binary `try_load_declarative` semantics (boot gate unchanged).
- Add purely additive APIs (`try_load_partial`, `partial_load_result`) — no caller is forced.
- Switch two helpers (`declarative_public_catalog_names`, `declarative_catalog_lookup_names`) to a *strict superset* of their previous return values: cases that previously returned `Error` may now return `Ok subset`; cases that previously returned `Ok` still return `Ok` with identical content.

Gaps 1, 2 widen coverage; gaps 3, 4 improve observability; gaps 5, 6 correct documentation. None require revert.

### 11.3 Why this was missed during the original PR review

The original RFC §4 framed Phase 8.3 as *"opt-in extension"* contingent on whether 8.2 covered the operational need. The error was failing to distinguish *live reload* (covered by 8.2) from *cold boot* (uncovered). Both produce the same error signature in the server log; the original draft conflated them. The amend (§6.1) makes the distinction explicit.

The framing failure is the kind CLAUDE.md §워크어라운드 §1 ("telemetry-as-fix") warns about indirectly: the test fixture (a *running* server with mid-edit toml) and the production scenario (a *restarted* server with mid-edit toml) had the same surface (WARN line in log) but different causal paths. The fixture was treated as canonical without checking which boot phase the original incident hit.

### 11.4 Operating principle adopted by this amend

- Every "Phase N done" claim must distinguish *load path covered* from *boot path covered* from *dispatch path covered*. Three separate axes.
- Every operational claim ("X is unblocked") must specify *active vs regression-prevention*. Hand-edits to config files are not the RFC's work.
- RFC body updates after merge are first-class. A merged RFC whose §6 overstates effects is itself a workaround (documentation drift). Amend in the open.
