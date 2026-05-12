# RFC-0037 — Local-first Keeper Enablement: Harness/User Boundary

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7)
- **Created**: 2026-05-07
- **Related**: RFC-0024 (Ollama Cascade Integration — registration done, 2026-05-03), RFC-0027 (capability-typed cascade), RFC-0032 (env knob unification)
- **Files referenced**:
  `lib/cascade/cascade_runtime.ml:65-85`,
  `lib/config/masc_network_defaults.ml:is_ollama_url`,
  `lib/cascade/cascade_health_tracker.ml`,
  `lib/keeper/keeper_cascade_profile.ml:14-22`,
  `lib/keeper/keeper_unified_turn.ml:319-394`,
  `config/cascade.toml:[tier_small]`,
  `lib/runtime_catalog.ml:296`

## 1. Problem

A keeper cannot be enabled to use Ollama with a single configuration switch.
RFC-0024 completed the *registration* layer (runtime_catalog has the Ollama
entry at `lib/runtime_catalog.ml:296`; cascade.toml has a commented `[tier_small]`
slot). What is still missing is the **boundary** between two layers:

1. **Harness layer** (deterministic, automatic) — should make Ollama work
   *without* user effort once it is running locally on `:11434`.
2. **User declaration layer** (declarative, explicit) — should let an
   operator say *"this keeper uses Ollama"* in a single line.

These two layers are entangled in main:

| Layer | What should be there | What is actually there |
|-------|----------------------|------------------------|
| Harness — auto-discovery | Ping `:11434` → register Provider_registry | Only triggers when `Eio_context` has *both* sw and net (`cascade_runtime.ml:65-85`); silent skip otherwise |
| Harness — URL classification | Explicit provider declaration first, port heuristic last | Pure substring `:11434` scan in `masc_network_defaults.is_ollama_url` |
| Harness — cooldown policy | Local providers tolerated more than remote | Uniform `cooldown_threshold=3 / cooldown_sec=30` for all providers (no `is_local_provider` use in `cascade_health_tracker.ml`) |
| Harness — saturation skip cap | Bounded retry | PR #14100 (in flight) — bounds at 5 consecutive skips |
| User — declaration toggle | One line in `config/keepers/<name>.toml` | None. Operator must edit `cascade.toml`, uncomment models, find the right cascade name, set keeper's `cascade` field, hope phases align |

The result: an operator who runs Ollama locally still gets a 4-step manual
alignment that must succeed exactly to enable a keeper. The harness layer
silently fails on three of those steps, and the user-facing layer has no
single place to express intent.

## 2. Goals

1. **G1 — Single-line user declaration.** A keeper config carrying
   `providers = ["ollama"]` (or equivalent) routes through Ollama without
   the operator touching `cascade.toml`.
2. **G2 — Robust harness auto-discovery.** Ollama on `:11434` becomes
   reachable from the cascade runtime even when `Eio_context` is partially
   unset, with explicit fallback registration and warning logs.
3. **G3 — Layer separation that holds under code review.** Each new addition
   must be classifiable as *harness* or *user-declaration* with no
   straddling. The classification lives in this RFC and is referenced by
   subsequent PR descriptions.

## 3. Non-Goals

- Replacing RFC-0024's registration layer — already done.
- Removing the existing cascade catalog mechanism — `cascade.toml` remains
  the SSOT for cascade definitions.
- Adding a "model selection AI" — this is plumbing, not policy.
- Cross-host Ollama deployments — out of scope; the default URL is local.

## 4. Design

### 4.1 Layer matrix (binding)

Every implementation phase below is tagged H (harness) or U (user-declaration).
PRs implementing items in this RFC MUST cite the tag in the PR body.

| Tag | Layer | Owner | Visibility | Change discipline |
|-----|-------|-------|------------|-------------------|
| H | Harness | runtime | invisible to operator on success | surgical, single-file PRs preferred |
| U | User | config schema | operator types it explicitly | versioned config field, deprecation policy required |
| K | Knob | env var | operator escape hatch only | follows RFC-0032 catalog |

### 4.2 User declaration: `providers` field on keeper config (U)

Add a field to keeper config TOML (single source of truth in
`lib/keeper/keeper_config.ml`):

```toml
# config/keepers/local_only_keeper.toml
name = "local_only_keeper"
providers = ["ollama"]              # NEW — explicit, declarative
# (instead of) cascade = "tier_small"  + uncommenting models in cascade.toml
```

Resolution rule:
- If `providers = [...]` is set: synthesize an in-memory cascade from the listed providers, bypassing `cascade.toml` lookup.
- If `providers` is absent: fall through to existing `cascade = "..."` lookup.

This deliberately avoids adding a `Local_only` variant to
`Keeper_cascade_profile.t`, which the SSOT comment explicitly forbids
without a compile-time event:

```ocaml
(* lib/keeper/keeper_cascade_profile.ml:14-22 SSOT comment *)
(* Adding a new profile is a compile-time event: add a variant here, then
   exhaustive [match] sites flag every consumer that needs to handle it. *)
```

The `providers` field is data, not a new variant — it parameterizes the
existing `Big_three` execution path with a different provider set.

### 4.3 Harness — partial-Eio-context diagnostic (H) — IMPLEMENTED

**Scope revision (2026-05-07)**: Original proposal was register-fallback,
but `Llm_provider.Provider_registry`'s public API on masc-mcp's downstream
requires both `~sw` and `~net` to probe — there is no register-without-probe
entry point exposed. Realistic surgical change is **visibility**: turn
silent skip into a one-shot WARN that tells the operator which half of
the context is missing and where to fix it.

```ocaml
match sw, net with
| Some sw, Some net ->
    (* existing path: full discovery *)
| _ ->
    warn_partial_eio_context_once
      ~sw_some:(Option.is_some sw) ~net_some:(Option.is_some net);
    false
```

`Atomic.exchange` flag prevents heartbeat-loop log spam.

Implemented in PR #14110.

For the larger fallback-registration goal (register endpoint without
probe), a follow-up RFC against the agent_sdk Provider_registry surface
is required — out of scope for this RFC.

### 4.4 Harness — URL classification with explicit-set priority (H)

`Masc_network_defaults.is_ollama_url` is a `:11434` substring scan. Refine
to layered classification:

```ocaml
let is_ollama_url ?explicit_provider url =
  match explicit_provider with
  | Some "ollama" | Some "ollama-local" -> true
  | _ -> is_default_port_substring url   (* existing :11434 scan *)
```

Callers that already know the provider name (cascade resolver, keeper config
parser) pass `?explicit_provider` and bypass the heuristic. Pure-URL
callers fall through to the substring scan, behavior unchanged.

### 4.5 Harness — local provider cooldown policy (H)

`Cascade_health_tracker` currently has no `Runtime_catalog.is_local_provider`
awareness. Add a per-class cooldown profile:

```ocaml
let cooldown_config_for ~provider_key =
  if Runtime_catalog.is_local_provider provider_key then
    { threshold = 5; cooldown_sec = 10.0 }       (* generous: local probe is flaky by nature *)
  else
    { threshold = cooldown_threshold; cooldown_sec = cooldown_sec }   (* existing 3 / 30s *)
```

`Runtime_catalog.is_local_provider` exists today
(`lib/runtime_catalog.mli:221`). This change does not introduce a new
primitive; it wires an existing one.

### 4.6 Harness — saturation skip cap (H, in flight)

Implemented in PR #14100. Per-keeper consecutive skip counter capped at
`MASC_MAX_CONSECUTIVE_SATURATION_SKIPS` (default 5). No further design
change here; documented in this RFC for the boundary classification.

### 4.7 Knob catalog (K)

Per RFC-0032, every new env knob must enter the catalog. This RFC adds:

| Knob | Default | Range | Purpose |
|------|---------|-------|---------|
| `MASC_LOCAL_COOLDOWN_THRESHOLD` | 5 | 1..50 | §4.5 local fail count |
| `MASC_LOCAL_COOLDOWN_SEC` | 10.0 | 1.0..300.0 | §4.5 local cooldown |
| `MASC_DEFAULT_OLLAMA_URL` | `http://127.0.0.1:11434` | URL | §4.3 fallback target |
| `MASC_MAX_CONSECUTIVE_SATURATION_SKIPS` | 5 | 1..100 | §4.6, PR #14100 |

## 5. Implementation Phases

### Phase 1 — Harness fixes (no SSOT change, no RFC gate beyond this one)

| PR | Scope | Tag | Status |
|----|-------|-----|--------|
| §4.6 | saturation skip cap | H | DONE — PR #14100 |
| §4.3 | partial Eio_context diagnostic | H | DONE — PR #14110 (scope revised, see §4.3) |
| §4.5 | local cooldown policy | H | DONE — PR #14109 |
| §4.4 | URL classification with `?explicit_provider` | H | OPEN — narrow gap (non-default port deployments only) |

Phase 1 PRs reference this RFC in their body and may merge independently.

### Phase 2 — User declaration (depends on Phase 1)

| PR | Scope | Tag | Estimate |
|----|-------|-----|----------|
| §4.2a | `providers` field schema in keeper config | U | ~40 LOC schema |
| §4.2b | cascade synthesis from `providers` | U | ~60 LOC resolver |
| §4.2c | docs + sample config | U | docs |

Phase 2 starts only after Phase 1 PRs land — synthesis depends on robust
harness layer.

### Phase 3 — Bootstrap tooling (optional)

| PR | Scope | Tag | Estimate |
|----|-------|-----|----------|
| §6 | `masc init --local-only` command | U | ~80 LOC, depends on RFC-0030 |

Defer until Phase 2 stabilizes.

## 6. Migration

- No existing config breaks. `providers` field is opt-in; absence means
  current `cascade = "..."` lookup runs unchanged.
- `cascade.toml [tier_small]` stays as fallback path for operators who
  prefer the catalog.
- Knob defaults match prior behavior: `MASC_LOCAL_COOLDOWN_THRESHOLD=5`
  is more generous than today's `3`, but the change applies only to
  endpoints that pass `Runtime_catalog.is_local_provider`.

## 7. Validation

| Check | Method | Pass criterion |
|-------|--------|----------------|
| C1 | Phase 1 PRs each cite RFC-0037 §X.Y in body | manual review |
| C2 | After Phase 1: keeper with `cascade = "tier_small"` and uncommented model in cascade.toml routes through Ollama with **no** Eio_context special-casing required | integration test |
| C3 | After Phase 2: keeper with only `providers = ["ollama"]` (no cascade.toml edit) routes through Ollama | integration test |
| C4 | Local provider cooldown: simulated 4 consecutive Ollama failures keep the endpoint usable; 4 consecutive Claude failures cool it down | unit test |
| C5 | URL classification: `http://my-server:8080` with `~explicit_provider:"ollama"` returns true; `http://example.com:9000` returns false | unit test |

## 8. Risks and Tradeoffs

- **Risk**: `providers` field bypasses `cascade.toml`, causing two ways to
  configure the same thing. **Mitigation**: documentation calls out
  `providers` as the *recommended* path; `cascade` field remains for legacy
  catalog-driven setups.
- **Risk**: Generous local cooldown (5/10s vs 3/30s) lets a flaky local
  endpoint absorb more requests than today. **Mitigation**: still has a
  cap; the saturation skip layer (§4.6) provides upstream defense.
- **Risk**: `register_default_local_endpoint` in §4.3 fallback path may
  register an endpoint that isn't actually live. **Mitigation**:
  registration is cheap; the probe layer rejects unreachable endpoints
  via `try_probe` returning `None` → cascade strategy moves on.
- **Tradeoff**: this RFC does NOT add a `Local_only` variant to
  `Keeper_cascade_profile.t`, deferring to the SSOT comment. Operators
  who want compile-time exhaustiveness for local routes can layer a
  capability profile (RFC-0027) on top.

## 9. Open Questions

- **OQ1**: Should `providers = ["ollama", "claude"]` mean *failover order*
  or *load-balance pool*? Current proposal: failover order matching
  cascade semantics.
- **OQ2**: Should the §4.3 fallback warn-once or warn-each-tick? Probably
  warn-once via `Atomic.exchange` flag (matches `cascade_ollama_probe`
  pattern in PR #14060).
- **OQ3**: Phase 3 tooling — should `masc init` create a file or print to
  stdout? Defer to RFC-0030.

## 10. Decision

This RFC defines the boundary. Approval of this RFC unblocks Phase 1 PRs
to merge independently. Phase 2 requires a separate sign-off because it
introduces a new user-facing config field.
