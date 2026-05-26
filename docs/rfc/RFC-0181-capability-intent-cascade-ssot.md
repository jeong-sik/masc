---
rfc-id: RFC-0181
title: Capability/intent-based cascade SSOT
status: Draft
authors: Vincent (architect), Claude
created: 2026-05-26
related: RFC-0058 (declarative cascade config v2), RFC-0177 (phonebook internal vendor purge), RFC-0041 (cascade routing group/item hierarchy)
---

# RFC-0181 Capability/intent-based cascade SSOT

> Status: **Draft skeleton.** Open questions left for architect to decide before flesh-out.

## 1. Problem

cascade routing has two coexisting paths, and *neither alone is the SSOT*:

1. **Legacy `[routes.*]` in `config/cascade.toml`** — read by `Cascade_routes.cascade_name_for_use`. Every concrete caller today (governance_judge, operator_judge, cross_verifier, verifier, anti_rationalization, verifier_oas, keeper_turn, etc.) resolves through this path. This is what actually decides routing at runtime.
2. **Phonebook (`cascade_phonebook_*.ml`, `Cascade_routing_policy.default_routing_policies`)** — wired in by RFC Cascade Phonebook Phase 1-4 (#18199, #18218). It receives a `task_use` and resolves to a tier-group of typed `Provider_config.t`. The infrastructure exists, but `config/cascade.toml` does **not** carry the phonebook schema sections (`[providers.*]`, `[models.*]`, `[tier-groups.*]` — plural form). Only the test fixture `test/fixtures/cascade-phonebook.toml` is populated.

As a result:

- `cascade_models_for_use_via_phonebook` and `cascade_provider_configs_for_use_via_phonebook` return `None` in production today.
- The intent expressed in `task_use_of_logical_use` (4 judge routes → `Code_review`) is contradicted by `cascade.toml` (each judge route had its own `target = "tier-group.primary"` — fixed in PR #18695 to `tier-group.governance`, but the dual-path structure remains).
- `default_routing_policies` declares `Code_review → primary_tier_group = "cross-verify"`, but no `tier-group.cross-verify` exists in any TOML file. Silent dangling reference.

### Why current state is fragile

Symptom: `Dashboard_governance_judge.refresh_once` timed out at 45s every cycle (the immediate observation that motivated this RFC, mitigated by PR #18695). The user's instinctive question — "why does the cascade not fall back to a different model?" — exposed:

- legacy `routes.*` uses `tier-group.primary` with `tiers = ["primary"]` (single tier, no cross-tier fallback path)
- phonebook would have offered a proper fallback chain (`primary → __safe_lane`) but is empty
- a fully populated phonebook plus removal of legacy `[routes.*]` would be a one-SSOT system, but cannot be done while RFC-0177 is mid-flight

### Coupling with RFC-0177

RFC-0177 (`phonebook-internal-vendor-purge`) is purging vendor brand names from masc-mcp internal enums via 1:1 substitution (`Zai_glm → Provider_k`, `Anthropic_http → Provider_a`, etc.). User feedback memory (`feedback_vendor_brand_substitution_is_encryption_not_abstraction`, 2026-05-24) records that this approach was judged as *encryption, not abstraction*: the coupling is preserved, only the label changes.

If we migrate the phonebook to be the SSOT *while RFC-0177 substitutes labels in flight*, every consumer of phonebook is rewritten twice. This RFC therefore proposes ending the 1:1 substitution direction and replacing it with capability/intent-driven names.

## 2. Goals

- One declarative SSOT for cascade routing (not "legacy routes + phonebook + dangling references").
- Caller speaks **intent** (`judge`, `code-generation`, `tool-execution`), not provider names.
- Tier-groups describe **capability profiles** the routing matcher uses to pick concrete models.
- No vendor brand names in any masc-mcp internal type. No `provider_d`-style substituted labels either; either capability classes or stable model IDs.
- Fall-back chain is part of the declarative spec, not an emergent property of `tiers = ["X", "Y"]` tuples.

## 3. Non-goals

- Replacing `agent_sdk` provider taxonomy (RFC-0176 territory).
- Changing wire protocol detection (`cascade_server_flavor`) — that is a separate axis.
- Implementing the full RFC in one PR.

## 4. Proposed design — TBD (open questions in §6)

The current sketch (to be refined):

```toml
# Single section — no [routes.*] + [tier-group.*] + [tier.*] split

[capability.judge-fast]
description = "Advisory dashboard judge: ≤30s p50, JSON output, no tools required"
constraints = { max_output_tokens = 2048, requires_thinking = false }
fallback = "judge-medium"

[capability.judge-medium]
description = "Background judges with structural reasoning"
constraints = { max_output_tokens = 4096 }
fallback = "safe-lane"

[capability.code-generation-large]
description = "Keeper turn, complex reasoning, tool use"
constraints = { runtime_mcp_tools = true, tool_strict = true }
fallback = "code-generation-medium"

# ... etc.

[model.glm-flashx]
provider = "glm-coding"  # endpoint/auth resolved elsewhere
satisfies = ["judge-fast", "judge-medium", "code-generation-medium"]

[model.deepseek-v4-flash]
provider = "openai-compat-deepseek"
satisfies = ["judge-fast", "judge-medium"]

# Intent table: what each caller needs
[intent]
governance_judge = "judge-fast"
operator_judge = "judge-fast"
cross_verifier = "judge-medium"
verifier = "judge-medium"
keeper_turn = "code-generation-large"
# ...
```

Resolution: `intent[name] → capability → models satisfying it → pick first available, fall back along capability chain`.

The runtime is then *pure data lookup* — no `[tier.X] members = [...]` strings, no parallel legacy table.

## 5. Migration plan (sketch — needs sequencing decision)

The realistic plan is multi-PR. A first cut:

1. **PR-1**: New `[capability.*]` + `[model.*]` + `[intent.*]` sections added to `cascade.toml`. Old `[tier.*]` / `[tier-group.*]` / `[routes.*]` remain. New `Cascade_capability_resolver` module added but not yet wired. Lint/test only.
2. **PR-2**: Switch `Cascade_routes.cascade_name_for_use` to query capability resolver. Legacy fallback retained, gated by env var.
3. **PR-3**: Migrate the 5+ direct call sites (`Cascade_routes.cascade_name_for_use` → typed capability/intent API). Existing callers stop holding strings.
4. **PR-4**: Drop `[routes.*]` section + legacy resolver code + `Cascade_routing_policy.default_routing_policies "cross-verify"` dangling.
5. **PR-5**: Drop `[tier.*]` / `[tier-group.*]` once capability resolution is the only consumer.

Each PR is reversible and CI-gateable.

## 6. Open questions (architect decision required)

**Q1 — Capability profile granularity.** Sample names above (`judge-fast`, `judge-medium`, `code-generation-large`) are placeholders. Should the axis be latency budget? Tool strictness? Reasoning depth? Some hybrid? Naming convention here is the most opinion-loaded decision; it locks in mental model for every future caller.

**Q2 — RFC-0177 interaction.** Three options:
- (a) Halt RFC-0177 mid-flight, accept current branded enums as-is until this RFC absorbs them.
- (b) Continue RFC-0177 to completion, then start this RFC on top of post-purge baseline.
- (c) Supersede RFC-0177 with this RFC, treat in-flight substitution PRs as work-in-progress that should be redirected to capability names directly.

User memory (2026-05-24) suggests (c). Confirming.

**Q3 — Phonebook deprecation.** If capability resolution becomes SSOT, what happens to `cascade_phonebook_types.ml`, `cascade_phonebook_parser.ml`, `cascade_routing_policy.ml`? Two paths:
- Repurpose them: rename internally so they *are* the capability resolver.
- Delete: write a parallel `cascade_capability_*` module and remove phonebook entirely.

The choice affects how much of Phase 4's recent work is preserved.

**Q4 — Endpoint/auth resolution.** `[model.X]` table above defers endpoint/protocol/auth_env to "elsewhere". Where? Reusing phonebook's `[providers.*]` is natural, but only if Q3 keeps phonebook.

**Q5 — Big-bang vs incremental.** The migration plan in §5 is 5 PRs. User memory (`feedback_radical_improvement_over_diff_size`, `feedback_big_bang_refactor_preference`) prefers fewer, larger PRs in this codebase. Should §5 collapse to 2 PRs (data introduction + cutover) at the cost of larger review surface?

## 7. Alternatives considered

- **Keep legacy `[routes.*]` indefinitely, give up on phonebook**: smallest diff, but cements two-SSOT structure and leaves dangling `cross-verify` reference.
- **Finish phonebook migration (data + cutover) without capability rename**: closes one SSOT but inherits RFC-0177's 1:1 substitution path.
- **Externalize routing to OAS bridge**: pushes the decision out of masc-mcp entirely. Larger blast radius, deferred.

## 8. Evidence

- PR #18695 (fix(cascade): route judge calls to tier-group.governance) — immediate symptom mitigation that exposed dual-SSOT structure.
- `config/cascade.toml` lines 859-911 (`[routes.*]` section) — legacy resolver input.
- `lib/cascade/cascade_routes.ml:313` (`cascade_name_for_use`) — legacy resolver code path.
- `lib/cascade/cascade_routing_policy.ml:67-70` — dangling `cross-verify` reference.
- `test/fixtures/cascade-phonebook.toml` — what a populated phonebook actually looks like.
- Memory `feedback_vendor_brand_substitution_is_encryption_not_abstraction` (2026-05-24) — user judgment on RFC-0177's substitution direction.
- Memory `project_rfc_cascade_phonebook_phase_4_merged_2026_05_24` — phonebook Phase 1-4 merged, Phase 5 pending.
