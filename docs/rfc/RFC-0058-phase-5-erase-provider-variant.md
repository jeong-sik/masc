# RFC-0058 Phase 5: Erase Provider/Model Variants from OCaml Code

| | |
|---|---|
| Status | Draft |
| Depends-on | RFC-0058 §2.4, Phase 4 (PR #14550) |
| Scope | OCaml dispatch sites — remove vendor/model literals from code |

## 1. Problem

RFC-0058 §2.4 states *"Code dispatches by `api_format`, never by provider
name"*. Phase 4 delivered the TOML SSOT but the dispatch sites still
type-discriminate on closed variants and string literals tied to specific
vendors. Audit (2026-05-11) found at least the following sources of leakage
on `feat/rfc-0058-phase4`:

| File | Symptom |
|------|---------|
| `lib/provider_adapter.ml` | `cascade_prefix = "claude_code" / "codex_cli" / "kimi_cli" / "gemini_cli" / "glm-coding"` and per-provider `aliases = [...]` lists hardcode every vendor name and its synonyms |
| `lib/provider_tool_support.ml` | Closed variant `Claude_code | Gemini_cli | Kimi_cli | Codex_cli` with per-variant capability lookup |
| `lib/cascade/cascade_attempt_liveness_config.ml:54-56` | Liveness tunables keyed by literal `"codex_cli"` / `"claude_code"` / `"glm-coding"` etc. |
| `lib/cascade/cascade_catalog_validator.ml:162-168` | Warn message and detection logic enumerate provider names |
| `lib/cascade/cascade_config.mli:152-154` | `auto` expansion logic referencing `"gemini_cli:auto"` etc. |
| `lib/cascade/cascade_error_classify.mli:147-168` | `codex_cli_prompt_preflight` type and helpers — preflight is provider-specific by design |
| `lib/prometheus.ml:530` | Metric name `masc_codex_cli_mcp_tool_omission_total` baked into code |
| `lib/dashboard_cascade.mli` | Documentation literals (`cli:claude_code`, `kimi_cli`, …) — driven by runtime data but the contract surface still spells them out |

The provider name leaks into call sites in three forms:

1. **Closed variant** (`type provider_id = Claude_code | …`) — exhaustive
   match enforces that any new vendor needs a code change in every dispatch
   site.
2. **Cascade prefix literal** (`"claude_code"`, `"codex_cli"`, …) —
   string compared against runtime config; adding a vendor means hunting
   for every match site.
3. **Per-vendor configuration tables** baked into OCaml (`auto_register_for_candidates`,
   liveness tunables, capability defaults) — duplicates the TOML SSOT.

## 2. Goals

- Remove closed `provider_id` variant types from public dispatch surfaces.
- Eliminate every literal vendor cascade prefix from OCaml under `lib/`.
- Move per-vendor capability/liveness/pricing/concurrency knobs out of
  OCaml into `config/cascade.toml` (the Phase 4 SSOT).
- After Phase 5, adding a vendor that uses an existing `api_format` is
  TOML-only.

## 3. Non-Goals

- Removing per-vendor *adapter modules* (`Kimi_cli_adapter`, `Messages_api_adapter`,
  …) — those legitimately encode wire-format quirks and remain dispatched
  by `api_format`.
- Backward-compatible env-var fallback for legacy `MASC_PROVIDER=*` reads —
  that lives in a separate runtime-pin RFC.

## 4. Approach

Phased to keep `main` green at every step. Each step is one PR.

### Phase 5.1 — Erase `provider_id` variant from `provider_tool_support`

- Replace `type provider_id = Claude_code | …` with `Provider_id of string`
  (id is the TOML `[providers.<id>]` key).
- Move per-provider capability defaults from
  `Llm_provider.Capabilities.{claude_code,gemini_cli,kimi_cli,codex_cli}_capabilities`
  into a `[providers.<p>.capabilities]` TOML sub-table. New section parses
  to `provider_capabilities` record and the dispatch reads from it.
- Caller-site grep: `provider_tool_support`, `runtime_mcp_policy_requires_http_headers`,
  `codex_cli_identity_runtime_mcp_header`. Each becomes a TOML lookup.

### Phase 5.2 — Remove static liveness classes

The provider-level liveness schema was superseded before productization.
Do not add a provider liveness sub-table or provider liveness class field
back to declarative cascade config.

Runtime liveness now uses:

- an explicit bootstrap budget for candidates with no successful history,
- recent successful attempt samples keyed by concrete provider/model candidate,
- no training from failed, killed, rejected, or cancelled attempts.

This keeps provider ids and model-size labels out of liveness policy.
Follow-up hardening should focus on receipts/debug surfaces that expose
the candidate key, budget source (`bootstrap` or `observed_success`), and
resolved budget used for the attempt.

**Former Phase 5.2b caller migration — obsolete**
- Do not replace the old match with a provider-id keyed budget lookup;
  that still makes provider identity the budget taxonomy. Keeper dispatch
  should use a concrete provider/model candidate key.
- The hardcoded `match cascade_prefix with "codex_cli" | "claude_code" |
  …` block is deleted without replacing it with static provider classes.
- If validator rules are added, they should ensure no shipped provider
  declares a liveness class so future entries cannot silently regress.

### Phase 5.3 — Erase `cascade_prefix` literals from `provider_adapter`

- `provider_adapter.ml` becomes a thin lookup over the TOML
  `[providers.<id>]` table — `aliases` synonyms move into TOML
  `aliases = [...]` field on each provider.
- Removes the giant per-provider record list at the bottom of the file.

### Phase 5.4 — Generalize Prometheus metric names

- `metric_codex_cli_mcp_tool_omission` becomes a labelled metric:
  `masc_provider_mcp_tool_omission_total{provider="<id>"}`. Dashboards
  follow.

### Phase 5.5 — Validator hardens R11 globally

- Promote `validate_strict` (introduced in Phase 5.2a alongside R11)
  to be the default validator used by every cascade.toml load site.
  Legacy `validate` removed once test fixtures all carry
  `max-concurrent`.

### Phase 5.6 — Erase residual `provider_cfg.kind` sites from keeper

Closed by an 8-PR sweep (2026-05-11):

| PR | Site | Boundary helper / structural change |
|----|------|-------------------------------------|
| #14691 | `keeper_turn_liveness.ml` (8 ollama tokens) | `Cascade_capacity_probe.can_probe` registry replaces the inline `is_ollama_cfg` variant match |
| #14710 | `cascade_http_probe.ml` (3 internal `is_ollama_url` calls) | Explicit URL registry — `Http_probe.register_url` retires the `:11434` substring scan |
| #14717 | `keeper_agent_context.ml:83` (`OpenAI_compat + Local` rewrap) | `Provider_adapter.apply_wire_overlay` — keeper layer no longer inspects either `Provider_config` or `Agent_sdk.Provider` variants |
| #14721 | `cascade_client_capacity.auto_register_for_candidates` (substring auto-register) | `Provider_adapter.is_http_probe_capable_kind` predicate; caller registers explicitly |
| #14729 | `keeper_turn_fsm.guard_transition` violation warn | dead-after-raise log line moved above `wrap_unit` — diagnostics reach operators |
| #14736 | `keeper_turn_driver_helpers.ml:41` (per-provider attempt timeout bounds) | `Provider_adapter.timeout_bounds_of_kind` — last keeper-layer `match provider_cfg.kind` site closed |
| #14745 | `keeper_bootstrap_stats.enabled` (producer-only field) | Removed; `should_start_supervisor_sweep` had already ignored it after the 2026-04-24 incident |
| #14753 | `handle_keeper_down` swallowed `pending_confirms_removed` count | Log + JSON response now expose the count; aligned with `server_dashboard_http_delete_actions.purge_agent_filesystem_artifacts` |

End-state invariant verified against `origin/main` HEAD `d3dd1086b`:

```bash
rg "match provider_cfg\.kind with" lib/keeper/ | grep -v provider_adapter
# (no matches — keeper layer is variant-agnostic)
```

The `with` anchor is intentional: it matches OCaml `match … with`
expressions only, so the two `[match provider_cfg.kind]` references that
remain inside `keeper_turn_driver_helpers.{ml,mli}` docstrings (Phase 5.6
history notes) do not trip the invariant.

The only `provider_cfg.kind` reads left in `lib/` outside
`provider_adapter` are out of scope:

- `cascade_transport.ml:1706` uses `provider_cfg.kind` as a `Hashtbl`
  registry key (lookup, not variant dispatch) — legitimate runtime
  registry, passes the workaround rejection bar.
- `cascade_catalog_runtime.ml:511` matches `strategy_cfg.kind`, not a
  provider kind — strategy-side dispatch over a separate
  `Cascade_strategy_config` type, unrelated to Phase 5.

## 5. Acceptance Gates

For each Phase 5.N PR:

- G1: `rg "Claude_code|Codex_cli|Kimi_cli|Gemini_cli" lib/ -t ocaml` shrinks
  monotonically. Phase 5.1 must zero out the variant occurrences in
  `provider_tool_support`.
- G2: `rg '"claude_code"|"codex_cli"|"kimi_cli"|"gemini_cli"|"glm-coding"' lib/ -t ocaml`
  shrinks monotonically. Phase 5.3 must zero them out under `lib/` (test
  fixtures and migration tools excluded).
- G3: `dune build --root .` and `dune test` pass. Test fixtures may be
  amended in the same PR but production cascade.toml schema does not change.
- G4: New TOML fields (`[providers.<p>.capabilities]`, provider `aliases`)
  ship with parser + R-rule validator coverage. Provider liveness classes
  remain absent.

## 6. Risks

- **Build cascade**: 30+ files touch `provider_id` variant. Sequence the
  PRs so the variant survives in one place at a time. Use compiler
  exhaustiveness to enumerate the call sites instead of grep.
- **TOML bloat**: per-provider capability sub-tables grow the file. Mitigation:
  the bloat is structured and replaces unstructured OCaml records — net
  reduction in maintenance surface.
- **Phase 4 PR rebase**: each Phase 5.N branches from Phase 4. Keep Phase 4
  merged before Phase 5.1 opens.

## 7. Open Questions

1. Should provider `aliases` (synonym strings like `"claude"`/`"claude-code"`/`"claude_code"`)
   be moved to TOML or eliminated entirely by canonicalizing all callers
   to the TOML id? Eliminating is cleaner but touches more call sites.
2. Per-provider preflight (`codex_cli_prompt_preflight`) — is the argv/prompt
   length check truly Codex-specific, or a general constraint that should
   live as a TOML `[providers.<p>.preflight]` policy?
3. Dashboard contract literals (`dashboard_cascade.mli` docstrings, JSON
   shape examples) — leave them as documentation, or drive examples from
   the live config snapshot at doc-generation time?
