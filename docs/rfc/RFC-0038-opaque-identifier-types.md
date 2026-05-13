# RFC-0038 — Opaque Identifier Types for Provider, Cascade, Model

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7)
- **Created**: 2026-05-07
- **Related**: RFC-0024 (ollama cascade integration), RFC-0027 (capability-typed cascade), RFC-0032 (env knob unification), RFC-0037 (local-first enablement boundary)
- **Files referenced**:
  `lib/provider_adapter.ml:152-167` (cn_* SSOT constants),
  `lib/cascade/cascade_config.ml:277` (provider name match),
  `lib/keeper/keeper_status_detail.ml:199` (provider name match),
  `lib/keeper/keeper_cascade_profile.ml:14-22` (cascade variant SSOT),
  `lib/cascade/cascade_routes.ml:65-94` (route_specs literal list)

## 1. Problem

Provider names, cascade names, and model identifiers appear in source
code as **bare string literals** scattered across modules:

| Identifier kind | SSOT location | Example drift sites | Drift count (`rg "<name>"` lib) |
|-----------------|---------------|---------------------|---------------------------------|
| Provider name (e.g. "ollama") | `Provider_adapter.cn_ollama` | `keeper_status_detail.ml:199`, `cascade_config.ml:277`, `server_routes_http_routes_cascade.ml:16` | 20+ across 14 files |
| Cascade name (e.g. "primary") | `Keeper_cascade_profile.t` variant | `cascade_routes.ml:65-94`, `cascade_config_loader.ml`, `cascade_routes.mli` | 5 files |
| Model id (e.g. "qwen3-coder:30b") | `cascade.toml` (data) | scattered string equality checks across cascade resolvers, telemetry tags |  highly variable |

These identifiers are **external to the codebase** — they come from
provider catalogs, cascade configurations, and external model registries
that change independently of the source code. Embedding them as string
literals creates three problems:

1. **Drift risk**: SSOT exists (`cn_ollama`) but is bypassed by 14
   files that re-write `"ollama"` directly. A rename of the canonical
   name (e.g. `"ollama"` → `"ollama-local"`) breaks the unmigrated
   sites silently — unit tests pass, runtime fails.
2. **No type-safety**: nothing prevents `String.equal cascade_name
   provider_name` — comparing across kinds. The compiler treats both
   as `string` and the bug surfaces only in production.
3. **No audit trail**: `rg '"ollama"' lib` produces 20+ hits and you
   cannot tell from source which are *the canonical name* vs *a
   telemetry tag that happens to share the spelling* vs *a TOML key
   referenced for parsing*.

The user-visible consequence: harder to add a new provider (must
hunt for every site that hardcodes `"ollama"` semantics), harder to
rename, harder to reason about boundaries.

## 2. Goal

Make the **kind of an identifier explicit in the type system**, and
move the canonical string to a single place per kind. After this RFC,
the compiler should reject a comparison between `Provider_id.t` and
`Cascade_id.t`, and there should be exactly one place in the codebase
that says `"ollama"` (the registry).

## 3. Non-Goals

- **Not** loading the full provider catalog from external config at
  startup — `direct_adapters` list stays in source code.  RFC-0024
  established that registration is a compile-time event; this RFC
  doesn't change that. What we do is enforce *use sites* to go
  through the registry rather than re-spelling.
- **Not** touching `cascade.toml` — operators still see provider
  names as strings in their config files.
- **Not** an SDK boundary refactor — the agent_sdk layer keeps its
  current types.

## 4. Design

### 4.1 Three opaque types

Three new modules, each defining a `private` string alias:

```ocaml
(* lib/identifiers/provider_id.mli *)
type t = private string
val of_canonical_name : string -> t option
  (** Returns [Some] only if the string matches a registered
      [Provider_adapter.adapter.canonical_name]. *)
val of_canonical_name_exn : string -> t
val to_string : t -> string
val equal : t -> t -> bool

(* Stable accessors for the names the codebase already uses. *)
val ollama : t
val llama : t
val claude : t
val claude_api : t
val codex : t
val gemini : t
val kimi : t
val glm : t
val custom : t
(* ... one per Provider_adapter.cn_* constant *)
```

Identical pattern for `Cascade_id` (canonical names from
`Keeper_cascade_profile`) and `Model_id` (free-form, but tagged so
it cannot accidentally substitute for `Provider_id`).

### 4.2 Migration strategy

The repository has many places that compare strings. We migrate **call
sites only**, not data structures, in three phases:

**Phase A — Provider_id (this RFC, surgical PR)**:
- Replace `String.equal x "ollama"` with `String.equal x Provider_adapter.cn_ollama` (or eventually `Provider_id.equal x Provider_id.ollama`).
- This is the minimum drift fix — even without the full opaque type, just routing through SSOT eliminates the literal duplication. **Companion PR #14111 ships exactly this.**

**Phase B — Phantom-typed wrappers**:
- Introduce `Provider_id.t = private string`.
- `Provider_adapter.cn_ollama : string` becomes `Provider_id.ollama : Provider_id.t`.
- All call sites that imported `cn_ollama` get an automatic compile error and must update — desirable, this is how we find the migration surface.
- Estimate: ~80-150 LOC of mechanical updates spread across ~15 files.

**Phase C — Cascade_id and Model_id**:
- Same phantom-type pattern applied to cascade and model identifiers.
- This is the larger refactor and requires its own RFC review.

### 4.3 What stays a string

Some `"ollama"` literals in the codebase are *not* provider names —
they are stable telemetry/dashboard category labels. Example:

```ocaml
(* lib/dashboard_cascade.ml:826 *)
if Masc_network_defaults.is_cli_sentinel_url url then "cli"
else if Masc_network_defaults.is_ollama_url url then "ollama"   (* ← category tag *)
else "other"
```

This `"ollama"` is a **dashboard category** that happens to spell
the same as the provider name. Coupling it to `Provider_id.ollama`
would tie the dashboard backward-compat API to provider catalog
renames — a coupling we do not want.

The Phase B migration explicitly allows these stable string labels
to remain as literals. The migration tool (or human reviewer) tags
them with a comment:

```ocaml
else if Masc_network_defaults.is_ollama_url url then "ollama"
  (* category label, intentionally decoupled from Provider_id.ollama *)
```

### 4.4 Why not just make them all variants?

```ocaml
(* tempting alternative *)
type provider_id = Ollama | Claude | Glm | ...
```

Variants are *closed*. RFC-0024 established that adding a provider
requires editing `direct_adapters`. A variant would force every
exhaustive `match` site to update — for some boundaries that's
desirable (cascade routing), for others it's noise (telemetry, log
formatting). The phantom-typed `private string` alias gives
type-safety without forcing exhaustiveness.

## 5. Implementation Phases

| Phase | Scope | LOC | Status |
|-------|-------|-----|--------|
| A | route through `Provider_adapter.cn_*` SSOT (no new module) | ~30 | DONE — companion PR #14111 |
| B | introduce `Provider_id.t = private string`, migrate call sites | ~150 | OPEN — needs separate sign-off |
| C | `Cascade_id.t`, `Model_id.t` + migration | ~300 | DEFERRED — needs review of Phase B outcome |

Phase A ships immediately to remove the most acute drift. Phase B is
the actual type-safety win and requires a separate review because it
introduces a new module convention and breaks every consumer of
`cn_*` (fixable by mechanical rename).

## 6. Validation

| Check | Method | Pass criterion |
|-------|--------|----------------|
| C1 (Phase A) | `rg '"ollama"' lib --no-filename \| wc -l` decreases | from 20+ to ≤4 (telemetry/dashboard category labels remaining, intentionally decoupled) |
| C2 (Phase B) | `Provider_id.t` opaque — `rg "Provider_id\.t = string"` returns 0 outside `provider_id.ml` | yes |
| C3 (Phase B) | `(p : Provider_id.t) = (c : Cascade_id.t)` is a compile error | yes |
| C4 (Phase A+B) | Adding a new provider requires touching only `direct_adapters` and `Provider_id.t` exposure list | manual code review |

## 7. Risks and Tradeoffs

- **Risk**: Phase B introduces a module convention. New code must
  remember to use `Provider_id.t` instead of `string`. **Mitigation**:
  one-shot grep gate in CI (`rg "provider_name : string" lib` returns 0
  after Phase B).
- **Risk**: `private string` aliases interact awkwardly with JSON
  serialization libraries that demand concrete types. **Mitigation**:
  `to_string` is exposed; serialization sites call it explicitly.
- **Tradeoff**: Phase A alone (`cn_*` routing) is a 30 LOC win that
  delivers most of the drift safety. Phase B is the type-safety win
  and is a much bigger refactor. We can ship A and stop, depending on
  Phase B review.

## 8. Open Questions

- **OQ1**: Should `Provider_id.of_canonical_name` consult the
  registry at runtime, or be enumerated at compile time? Trade-off:
  runtime lookup admits new providers from config; compile-time
  enumeration gives exhaustive `match` if we later choose variants.
- **OQ2**: Phase C scope — should `Model_id` be opaque or stay raw
  string? Models change faster than providers; opaque might just
  add ceremony.
- **OQ3**: Naming — `Provider_id` vs `Provider_name` vs `Provider_key`?
  Existing code uses `provider_key`, `pname`, `canonical_name`
  interchangeably.

## 9. Decision

This RFC defines the opaque-id direction. Phase A is shipping with
the companion PR. Phases B and C require explicit sign-off — they are
not auto-implied by this RFC's approval.
