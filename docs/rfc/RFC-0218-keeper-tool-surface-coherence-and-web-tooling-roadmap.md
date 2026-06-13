---
rfc: "0218"
title: "Keeper tool-surface coherence + web-tooling roadmap — phases and per-phase gates"
status: Draft
created: 2026-06-04
updated: 2026-06-04
author: jeong-sik (with Claude Opus 4.8)
supersedes: []
superseded_by: null
related: ["0064", "0179", "0190", "0194", "0212"]
implementation_prs: []
---

# RFC-0218 — Keeper tool-surface coherence + web-tooling roadmap

> Follow-up to the 2026-06-04 read-only audit of the keeper tool-surface
> assembly path. That audit was triggered by a per-turn WARN
> (`AllowList pruned ... WebSearch, WebFetch`, ~3.5k/day) whose root cause
> ([#20060](https://github.com/jeong-sik/masc-mcp/pull/20060), merged) was a
> three-way split-brain between (1) the policy candidate list, (2) ungated
> core public-name injection, and (3) the schema inventory. The audit also
> removed dead per-keeper allowlist machinery
> ([#20087](https://github.com/jeong-sik/masc-mcp/pull/20087),
> [#20088](https://github.com/jeong-sik/masc-mcp/pull/20088), merged).
>
> This RFC **sequences the remaining improvements** the audit surfaced and
> defines what each phase must satisfy before merge. **No code moves under
> this RFC** — it is a roadmap + gate definition. Each phase ships as its own
> PR (Phase 2's security item may need its own sub-RFC).

## 1. Problem (measured state, origin/main `344bb3cf97`, 2026-06-04)

### 1.1 "Does this tool exist?" is asserted by many parallel sources of truth

There is no single registry that answers "is X a real keeper tool". At least
six lists assert membership independently and are **not derived from one
another**, so they can drift:

| # | Source | Site | Asserts |
|---|--------|------|---------|
| 1 | `raw_all_tool_schemas` | `lib/config.ml:16` | the substrate "all tools that exist" superset (feeds keeper universe AND public MCP) |
| 2 | `masc_schemas_state` (mutable global ref) | `lib/keeper/keeper_tool_registry.ml:270` (`set`:272 / `snapshot`:276) | the keeper-injected masc_* schema subset, set once at startup |
| 3 | `core_always_tools` / `core_discovery_tools` | `lib/keeper/keeper_tool_registry.ml:45` / `:71` | tools always offered to the LLM |
| 4 | `Keeper_tool_descriptor.public_names ()` | injected at `keeper_tool_registry.ml:96` (ungated) | LLM-facing public names (Execute/Read/WebSearch/…) |
| 5 | `public_mcp_surface_tools` | `lib/tool_catalog_surfaces/tool_catalog_surfaces.ml:48` | the external public MCP allowlist |
| 6 | `keeper_base_candidate_tool_names ()` | `lib/keeper/keeper_tool_policy.ml:232` | the per-keeper-independent execution candidate set |

The realized LLM surface is rebuilt a **seventh** time from the assembled
`Agent_sdk.Tool.t` bundle (`keeper_run_tools_setup.ml` `all_tool_names` /
`universe_set`). The per-turn `validate_allow_list` keeps a name only if it is
in `universe_set ∩ policy_allowed_tool_set`, else prunes + WARNs.

**Drift hazard, demonstrated.** When #19864 removed the web schemas from source
(1), sources (4) + (6) still advertised `WebSearch`/`WebFetch` but the realized
bundle (source 2/7) could not register them → every keeper turn pruned + WARNed,
AND `Config.is_raw_tool_name "masc_web_search"` returned `false` (the substrate
denied a tool it dispatches). #20060 fixed the instance; the **class** (any of
these six diverging) is still open. [#20061](https://github.com/jeong-sik/masc-mcp/issues/20061)
tracks the specific ungated-injection fragility (source 4).

### 1.2 Runtime gating reality (post-#20088)

Keeper execution gating is now `candidate(global) − denylist`. `filter_by_access`
(a byte-identical alias of `filter_by_universe`) and the policy-filtered schema
path (`keeper_allowed_model_tools` / `keeper_masc_tool_schemas`) were removed in
#20088. Per-keeper `tool_access`/allow does **not** gate execution; only the
denylist does. `allow_set` survives as a telemetry field only. This is the
intended model — there is no remaining "allowlist" debt — but it is undocumented
beyond code comments.

### 1.3 Web tooling is narrower than the field (source-verified 2026-06-04)

`lib/tool_misc_web_search.ml` / `lib/tool_misc_web_fetch.ml`: `masc_web_search`
has 7 search providers (Searxng/Brave/Tavily/Exa/Bing API/DDG/Bing RSS) with
TTL cache + rate limit + query validation. `masc_web_fetch` does a single GET,
**strips HTML to plain text** (`clean_search_text`, not markdown), and **hard-
truncates at 100KB** with no chunking/offset. Gaps vs the field (Anthropic
web_fetch, smolagents, Aider, Hermes): markdown extraction, citation
char-offsets, chunking/pagination, domain allow/block, URL-provenance
exfiltration mitigation. (Re-confirm these line-level facts at implementation
time; this RFC records the gap, not the patch.)

## 2. Goals / non-goals

**Goals.** (a) Make tool-existence drift impossible to ship silently. (b) Reduce
the number of independent "tool exists" sources of truth. (c) Close the
domain-neutral web-tooling gaps that block keepers doing web-heavy work.

**Non-goals.** No change to the `candidate − deny` gating model. No stateful
browser automation (see §6). No change to the public MCP allowlist contents.

## 3. Phases

### Phase 1a — Startup coherence invariant (fail-fast)

**Change.** After `inject_masc_schemas` runs at startup (`lib/mcp_server_eio.ml:90`),
assert that every name in `keeper_base_candidate_tool_names ()` — minus the
descriptor public aliases that Pass B registers by projection — has a backing
schema reachable by the bundle (`all_keeper_schemas` / `raw_all_tool_schemas`).
On violation: fail fast at boot with the offending names (not a per-turn WARN).

**Why.** Converts the entire §1.1 drift class (#19864, #20061, phantom tools)
from runtime symptom (per-turn WARN / silent prune / `is_raw_tool_name` lying)
into a boot-time failure that CI and startup catch. This is "make illegal
states unrepresentable" applied at the one place all sources must agree.

**Verification (gate).** TLA-style mutation test pattern (CLAUDE.md §TLA+ Bug
Model): a clean fixture (candidate ⊆ schemas) passes; a fixture that injects a
candidate with no schema MUST fail the assertion. Plus: `dune build .` clean;
boot a keeper locally and confirm no `AllowList pruned` WARN in the fleet log.

**Size.** Small. **RFC weight.** Light (this RFC). **Boundary.** No new
keeper→MCP-surface enumeration; the assertion reads existing lists.

### Phase 1b — Source-of-truth consolidation

**Change.** Derive sources (3)(4)(6) from a single substrate projection rather
than independent construction, so they cannot diverge by construction. Concrete
target: `effective_core_tools` public-name injection (source 4) becomes
universe-aware (closes #20061), and `keeper_base_candidate_tool_names` /
core lists are expressed as filters over one registered-schema set. The mutable
global `masc_schemas_state` (source 2) is evaluated for replacement by a pure
function of `raw_all_tool_schemas` (startup-race surface removal).

**Why.** 1a makes drift *detectable*; 1b makes it *impossible*. Removes the
"점프점프" indirection the audit flagged: fewer independent registries = fewer
places a future change can desync.

**Verification (gate).** All existing keeper tool tests green; the 1a invariant
still holds (now structurally, not just asserted); no change to the realized
per-turn tool surface for a default keeper (snapshot test: tool set before/after
identical). `dune build .` clean.

**Size.** Large. **RFC weight.** This RFC defines intent; a focused design note
may precede the PR if the consolidation touches the descriptor projection
contract (RFC-0064/0179/0190 surface).

**Dependency.** 1a MUST land first (safety net for 1b's refactor).

### Phase 2 — Web-tooling domain-neutral primitives

Each item is a result-shape or param change on the existing search/fetch tools,
not a domain-coupled feature (§6). Independent of 1a/1b; may run in parallel.

| Item | Change | RFC weight |
|------|--------|-----------|
| P1 markdown extraction | `format: "text" \| "markdown"` on `masc_web_fetch` | light |
| P2 citation char-offsets | `cited_text` / `start_char_index` / `end_char_index` in results | light |
| P3 chunking/pagination | `offset` + `max_bytes`/`max_tokens`; return `total_length` + `has_more` (replace the hard 100KB cut) | light |
| P4 domain allow/block | `allowed_domains` / `blocked_domains` params on both tools | light |
| P5 URL-provenance allowlist | `masc_web_fetch` accepts only URLs seen in prior results/task input (exfiltration mitigation) | **own security sub-RFC** |
| P6 recency surfacing | expose `published_at`/`page_age` + optional recency sort | light |

**Verification (gate).** Per item: unit test of the new shape; existing web
tool tests green; no provider/credential behavior change. P5 additionally:
threat-model note + does not reject legitimate operator-supplied URLs.

## 4. Sequence and dependencies

```
1a (boot invariant) ──► 1b (consolidation)
2 (web P1-P4,P6) ── independent, parallel
2-P5 (URL-provenance) ── after its own security sub-RFC
```

Recommended order: **1a first** (small, high-ROI, safety net), then 1b and the
Phase-2 light items in parallel, P5 last (security review).

## 5. Out of scope / explicitly declined

- **Stateful browser automation** (Playwright/Chromium): a browser session
  carries DOM/session state across calls, which is incompatible with the
  "a Tool is a pure stateless FunctionCall substrate" boundary
  ([Tool ⊥ Keeper](/boundary/tool-keeper-mcp-surface/)). If ever needed, the
  correct home is an MCP-bridged external browser server, not the in-process
  Tool layer.
- **Adversarial source verification** for web results: belongs at a
  coordinator/keeper layer, not as a web primitive.
- Changing the `candidate − deny` gating model or the public MCP allowlist.

## 6. Boundary considerations

All phases are data/schema/assertion changes. None add keeper-side enumeration
or translation of the MCP-client tool surface, so none worsen the open
`tool-keeper-mcp-surface` coupling debt. Phase 2 enhancements are domain-neutral
web primitives (params/result fields), not domain-coupled features. Phase 1b
must not "fix" coherence by hardcoding any tool name into a keeper-side list —
that would add coupling; it must derive from the substrate.

## 7. Risks and rollback

- **1a false-positive at boot** (a legitimate candidate without a schema):
  mitigated by the same exclusion logic Pass B already uses (public aliases);
  the mutation test covers the boundary. Rollback: revert the single assertion
  call site.
- **1b over-reach**: if consolidation changes the realized per-turn surface,
  the snapshot test fails the gate. Rollback: per-PR, since 1b ships in slices.
- **2-P3 cache correctness**: chunked fetch must key the TTL cache per range;
  gate includes a cache-key test.

## 8. Verification summary (per-phase gate, must all hold)

1. `dune build .` clean (default target, not just `@check`).
2. Phase-specific test green (mutation test for 1a; snapshot test for 1b; shape
   test for each Phase-2 item).
3. No new `AllowList pruned` WARN in a local keeper boot (1a/1b).
4. `pr-rfc-check.sh` PASS (this RFC referenced; not a workaround).
5. No new keeper→MCP-surface enumeration (boundary).
