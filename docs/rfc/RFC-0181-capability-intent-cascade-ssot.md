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

## 6. Architect decisions (2026-05-26 session)

Resolved in this session. Implementation deferred (see §9).

**Q1 — Capability profile naming axis → (B) Capability-driven (model-attribute names).**
Rejects role+modifier hybrid in favour of *capability sets the model satisfies*. Pattern is K8s-style labels & selectors:
- Caller declares required capabilities (e.g., `governance_judge` requires `[fast-response, json-output, no-tool]`)
- Model declares satisfied capabilities (e.g., `glm-flashx` satisfies `[fast-response, json-output, tool-flex, no-streaming]`)
- Resolver = set intersection
- No cross product naming explosion. Composable.

**Q2 — RFC-0177 interaction → (c) Supersede.**
RFC-0177's 1:1 vendor substitution direction (`Zai_glm → Provider_k`, etc.) is judged as encryption-not-abstraction per memory `feedback_vendor_brand_substitution_is_encryption_not_abstraction` (2026-05-24). This RFC's capability/intent names replace both vendor brands AND the substituted placeholders. RFC-0177 status → Superseded. In-flight RFC-0177 PRs to be either redirected to capability names or closed.

**Q3 — Phonebook handling → (b) Delete + new `cascade_capability_*` module.**
Phonebook modules (`cascade_phonebook_types`, `cascade_phonebook_parser`, `cascade_routing_policy`) are deleted. New module set is designed against the capability/intent model rather than re-fitted. Phase 1-4 (PRs #18199, #18218) code is removed; the design lessons are preserved in this RFC.

**Q4 — Endpoint/auth resolution → (c) Reuse `Llm_provider.Provider_config.t`.**
Capability catalog stays purely logical: it carries `model_id` only. Endpoint/protocol/auth_env resolution remains the responsibility of `agent_sdk`'s `Llm_provider.Provider_config.t`, already partially wired in `lib/cascade/cascade_phonebook_resolve.ml:36`. Layered separation: cascade = capability matching; provider_config = physical config.

**Q5 — Migration sequencing → Stacked PRs.**
The §5 5-PR sequence is implemented as a stacked PR chain (each PR base = parent PR branch, not main). Reviewer can read commit-by-commit linearly. Each stack tip is independently buildable and CI-gateable. *Deferred per §9.*

## 7. Alternatives considered

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

## 9. Implementation status (2026-05-26)

**Decisions recorded. Implementation deferred.**

Architect concluded that cascade is the SSOT for every keeper turn, judge, and verifier — a replacement (not additive) refactor with revert blast radius comparable to a cluster-wide outage. The risk profile differs from RFC-0179's `keeper_*` additive expansion that landed as a single big-bang PR (#18710). Same big-bang pattern applied here would put every keeper turn / judge / verifier at risk simultaneously.

Therefore:

- Immediate symptom (governance_judge 45s timeout): already mitigated by PR #18695 (4-line route fix to `tier-group.governance`).
- Dual-SSOT structural issue (legacy `[routes.*]` + empty phonebook + dangling `cross-verify`): documented here, not yet remediated.
- Q1–Q5 decisions stand as the *design contract* when implementation resumes.

Resumption checklist:
- [ ] Confirm Q1–Q5 still hold given any newer evidence.
- [ ] Open RFC-0177 status update (Superseded marker + redirect notice on in-flight PRs).
- [ ] Begin §5 stack at PR-1 (new module, NOT wired). Validate buildable + no behavioral change. Pause for review.
- [ ] Only after PR-1 confidence: proceed to PR-2 (switch resolver, legacy fallback flagged).
