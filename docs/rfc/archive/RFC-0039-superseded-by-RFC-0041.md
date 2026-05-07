# RFC-0039 — Capability Dispatch Over Name

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7)
- **Created**: 2026-05-07
- **Supersedes scope of**: RFC-0038 §5 Phase B.3 (typed-wrapper direction abandoned)
- **Related**: RFC-0024 (ollama integration), RFC-0027 (capability-typed cascade), RFC-0037 (local-first enablement boundary), RFC-0038 §5 Phase A (SSOT routing — kept)
- **Files referenced**:
  `lib/provider_adapter.ml:152-167` (cn_* constants),
  `lib/provider_adapter.mli:221` (is_local_provider),
  `lib/keeper/keeper_status_detail.ml:202` (PR-A target),
  `lib/cascade/cascade_config.ml:276,281,291` (PR-B target),
  `lib/dashboard_provider_runs.ml:169,178` (PR-D target),
  `lib/keeper/keeper_mcp_provider_audit.ml:85` (PR-C target)

## 1. Position

Provider names like `"ollama"`, `"llama"`, `"claude"` should appear in
masc-mcp source code in **exactly one place**: the
`Provider_adapter.direct_adapters` registry list. Every other site
that currently dispatches behavior on a provider name is wrong — the
name is acting as a proxy for some structural property the code
actually cares about, and that property should be expressed as a
typed field on the `adapter` record.

This RFC supersedes the typed-wrapper direction proposed in RFC-0038
§5 Phase B (`Provider_id.t = private string`). The wrapper would have
made name-based dispatch type-safe but did not address the deeper
issue: **name-based dispatch is itself the anti-pattern**. PR #14125
is closed in favor of this RFC.

## 2. Diagnosis

### 2.1 Current name-comparison sites in lib/

After RFC-0038 Phase A (PR #14116), 5 production sites compare
provider names. Each is dispatching behavior — but the behavior is
structural, not nominal:

| File:Line | Compares against | Real intent (capability) |
|-----------|------------------|--------------------------|
| `keeper_status_detail.ml:202-203` | `cn_llama`, `cn_ollama` | "is this provider local?" → `is_local_provider` (already exists, line 1158) |
| `cascade_config.ml:276` | `cn_ollama` | "discover via /api/ps" → new field `discovery_method = Via_ps_url` |
| `cascade_config.ml:281,291` | `cn_llama` | "discover by listing models" → `discovery_method = Via_models_endpoint` |
| `dashboard_provider_runs.ml:169,178` | `cn_llama` | "no enumerated catalog (discover instead)" → `auto_models_source` already partially captures this |
| `keeper_mcp_provider_audit.ml:85` | `"glm"`, `"glm-coding"`, `"ollama"` | "MCP auto-construct path: not applicable" → new field `mcp_auto_construct = Not_applicable` |

### 2.2 Why name-based dispatch is wrong (three failure modes)

| Failure mode | Concrete example |
|--------------|------------------|
| (a) **Rename breaks code** | If we rename `cn_ollama = "ollama"` to `"ollama-local"`, every site that wrote `"ollama"` literal (or `cn_ollama` constant if it's hardcoded elsewhere) silently breaks. |
| (b) **New provider with same behavior is missed** | If we add `vllm` (also a local runtime), the `keeper_status_detail` check `name = cn_llama \|\| cn_ollama` does not fire — `vllm` requests are misclassified as `non_local`. |
| (c) **Name is a leaky proxy** | The code says `if name = cn_ollama then probe_ps`. Reader has to KNOW that ollama specifically uses /api/ps. The code does not document the property; it documents the provider's identity. |

All three failure modes vanish under capability dispatch.

## 3. Design

### 3.1 The "exactly once" rule

Provider names appear in source code only in:

1. `Provider_adapter.direct_adapters` registry — one entry per provider,
   `canonical_name = "ollama"` etc. This is the declaration of fact.
2. `aliases` field on adapter records — for parsing user input that
   matches non-canonical spellings.
3. Boundary parsers (TOML, JSON, env-var readers) at the moment they
   convert a string to an `adapter`.

That's it. Three places in source, all at boundaries. The internal
graph never sees the string after parsing.

### 3.2 Capability fields on `adapter`

Add structural fields to capture the properties currently dispatched
by name. The `adapter` record grows; each new field is exhaustively
matched (variant, not bool where possible) so the compiler catches
incomplete migration.

```ocaml
(* Existing fields, kept *)
type adapter = {
  canonical_name : string;
  runtime_kind : runtime_kind;          (* Local | Cli_agent | Direct_api *)
  auth_mode : auth_mode;
  aliases : string list;
  ...
  (* RFC-0039 additions *)
  discovery_method : discovery_method;
  mcp_auto_construct : mcp_auto_construct;
}

and discovery_method =
  | Via_ps_url               (* ollama: GET <base>/api/ps *)
  | Via_models_endpoint      (* llama-server: GET <base>/v1/models *)
  | No_discovery             (* claude, openai: model list is static *)

and mcp_auto_construct =
  | Active of {
      env_flag : string;
      default_when_unset : bool;
      module_name : string;
    }
  | Not_applicable
  | No_path
```

### 3.3 Migration sites and existing primitives

| Site | Capability used | Status |
|------|-----------------|--------|
| `keeper_status_detail.ml:202` | `Provider_adapter.is_local_provider` | EXISTS — just call it (PR-A, this PR) |
| `cascade_config.ml:276,281,291` | `Provider_adapter.discovery_method` | NEW field needed (PR-B) |
| `dashboard_provider_runs.ml:169,178` | Existing `auto_models_source` (line ~30 in provider_adapter.ml) | EXISTS — refactor caller |
| `keeper_mcp_provider_audit.ml:85` | `Provider_adapter.mcp_auto_construct` | NEW field needed (PR-C) |

### 3.4 Final state of `Provider_adapter.cn_*`

After all migrations, `cn_*` constants serve only the registry
definition itself (`canonical_name = cn_ollama;` in `direct_adapters`).
External callers use `find_by_*` / `is_local_provider` /
`discovery_method` / etc.

The `cn_*` constants can then be made `private` to the
`provider_adapter.ml` module (or removed in favor of inline literals
*inside* the registry definition, since the registry IS the SSOT).

## 4. Implementation Phases

| Phase | PR | Scope | Estimate |
|-------|----|-------|----------|
| A | this PR | RFC + `keeper_status_detail.ml` migration to `is_local_provider` | ~20 LOC |
| B | follow-up | Add `discovery_method` field + migrate `cascade_config.ml` 3 sites | ~50 LOC |
| C | follow-up | Add `mcp_auto_construct` field + migrate `keeper_mcp_provider_audit.ml` | ~50 LOC |
| D | follow-up | Migrate `dashboard_provider_runs.ml` to `auto_models_source` | ~20 LOC |
| E | gate | Make `Provider_adapter.cn_*` private; CI gate that `rg "Provider_adapter\.cn_" lib --no-filename` returns 0 outside `provider_adapter.ml` | ~10 LOC + CI |

Phases B, C, D can land in parallel. E is the seal.

## 5. Validation

| Check | Method | Pass criterion |
|-------|--------|----------------|
| C1 | `rg "Provider_adapter\.cn_" lib --no-filename` after Phase E | 0 outside `provider_adapter.ml` |
| C2 | `rg '"ollama"' lib --no-filename` after Phase E | ≤ 5 (registry + alias list + dashboard category label + comments). Specifically NOT in any conditional or match guard. |
| C3 | Adding a hypothetical `vllm` provider (Local runtime) requires only registry entry + capability field values | manual code review — no other site should need editing |
| C4 | Each name-comparison removed: behavior unchanged | unit test per migration site |

## 6. Risks and Tradeoffs

- **Risk**: `adapter` record grows by 2 fields. Future devs must remember
  to set them on new adapters. **Mitigation**: variant types force
  exhaustive set; missing field is a compile error.
- **Risk**: `discovery_method` and `mcp_auto_construct` are
  domain-specific — feels arbitrary. **Mitigation**: each field is
  introduced in a PR that *also* migrates a real caller; the field
  earns its keep on day one.
- **Tradeoff**: This RFC makes the `adapter` record the canonical
  decision table for provider behavior. A non-trivial behavioral
  difference between two providers always shows up as a structural
  field. This is the goal — but it means the record is no longer a
  thin descriptor.
- **Risk vs RFC-0027**: RFC-0027 proposed capability profiles at the
  cascade level. This RFC operates one layer below — at the provider
  level. The two compose: cascades have capability profiles; providers
  have capability fields; cascade-vs-provider matching is the next
  layer up.

## 7. Why not the typed wrapper (RFC-0038 §5 Phase B)

PR #14125 added `Provider_id.t = private string` with named accessors
(`Provider_id.ollama` etc.). User feedback closed it: the wrapper
made name-based dispatch type-safe but did not eliminate the
fundamentally wrong axis. The string `"ollama"` still appeared in
source — just under a typed name.

Capability dispatch is not type-safe in the same sense (the compiler
doesn't enforce `is_local_provider` is the right primitive — that's
a design choice). But it makes the intent explicit and prevents
failure modes (a) and (b) above. Type safety alone does not.

The drift-detection portion of PR #14125 (test `Provider_id.ollama
== Provider_adapter.cn_ollama`) is moot once `cn_*` is private to
its module — there is no second SSOT to drift against.

## 8. Open Questions

- **OQ1**: Should we keep `Provider_adapter.cn_*` private or remove
  them entirely (inlining literals inside `direct_adapters`)?
  Argument for keeping: `cn_*` exposed in `.mli` lets test fixtures
  reference canonical names without hardcoding strings. Argument for
  removing: any test that needs to refer to "ollama" specifically is
  itself doing name-based comparison and should use a capability or
  `find_by_*`.
- **OQ2**: `is_local_provider` is currently O(N) over `direct_adapters`
  with normalization. Hot-path dispatch in `keeper_status_detail` is
  per-keeper-tick — is the cost acceptable, or do we need a cached
  set?
- **OQ3**: `aliases` field (`["ollama"; "ollama-local"]`) currently
  lives in source. Is that boundary-acceptable or should aliases load
  from `provider.toml`? Defer to RFC-0024's "register at compile time"
  position.

## 9. Decision

This RFC retires the typed-wrapper direction. Approval unblocks
Phases B, C, D, E to merge independently. PR-A (this PR) ships the
RFC document plus the most trivial migration as proof of concept —
`keeper_status_detail.ml` switches from name comparison to
`is_local_provider` capability. No new fields added in this PR; the
primitive already exists.
