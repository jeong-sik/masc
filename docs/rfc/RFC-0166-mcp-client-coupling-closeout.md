# RFC-0166 MCP-client coupling closeout (big-bang)

| | |
|---|---|
| Status | Draft |
| Supersedes | RFC-0058 Phase 5.7 (now marked Superseded) |
| Related | RFC-0165 (auth modules — the first half), RFC-0042 closed-sum |
| Scope | All remaining MCP-client name literals in OCaml dispatch/text surfaces |
| Repos | masc-mcp |

## 1. Problem

After RFC-0165 (#18203, merged 2026-05-24) removed the `claude`/`gemini` dispatch from `lib/auth_login.ml` and `lib/auth_doctor.ml`, an audit of the rest of the codebase found that MCP-client name literals still leaked into a handful of operator-facing tool descriptions in `bin/gen_tool_descriptors.ml`. The descriptions enumerated specific client names (`'claude', 'gemini', 'codex', or 'llama'`) as if the server held a closed roster of supported clients, when in fact `agent_name` is a free-form string resolved against an operator-configured roster.

This RFC closes the residue and records the domain boundary that distinguishes legitimate from illegitimate retention of client/provider names.

## 2. Decision

**Sweep**: Replace the enumerated client lists in tool descriptions with descriptions that frame `agent_name` as free-form, naming the operator's local roster as the source of truth.

**Retain (Non-Goals)**: Upstream LLM provider classification (`apply_provider_filter`, `inference_model_bucket`) is a *different domain* — it classifies the LLM API endpoint (Anthropic, OpenAI, Gemini, etc.) that MASC *calls*, not the MCP client that *calls MASC*. These belong to the cascade/provider layer and stay in this PR's Non-Goals.

**Wire-format adapters (Non-Goals)**: `cascade_transport_codex_omission_dedup.ml` and similar `*_adapter.ml` files encode protocol-level quirks of specific provider wire formats. RFC-0058 §3 lists these as non-goals; this RFC preserves that carve-out.

## 3. Why "closeout" rather than further dispatch sweep

The big-bang inventory (2026-05-24) measured:

| Area | Hits | Disposition |
|------|------|-------------|
| `lib/auth_login.ml`, `lib/auth_doctor.ml` | 0 | Cleared by RFC-0165 |
| `lib/codex_mcp_config_doctor.ml` | n/a | File already removed |
| `lib/server/server_runtime_bootstrap.ml` codex hits | 0 | Already clean |
| `bin/gen_tool_descriptors.ml` MCP-client examples | 5 | **In scope** |
| `lib/cascade/cascade_config_provider_filter.ml` comment | 1 | Non-Goal (upstream provider) |
| `lib/cascade/cascade_event_bridge_inference.ml` | 6 | Non-Goal (upstream provider bucket) |
| `lib/cascade/cascade_config.mli`, `cascade_config_loader.ml` JSON examples | 2 | Non-Goal (upstream provider) |
| `cascade_transport_codex_omission_dedup.ml` | (module) | Non-Goal (wire adapter) |

The only remaining *MCP-client* coupling on `main` was the tool description text.

## 4. Changes

### `bin/gen_tool_descriptors.ml`
- `masc_spawn_spec` description: replace `(claude, gemini, codex, or llama)` with a generic frame; replace the `agent_name` parameter description's `'claude', 'gemini', 'codex', or custom command` enumeration with a description of how the operator's local roster resolves the name.
- `masc_join_spec` `agent_name` description: replace `'claude', 'gemini', or 'codex'` with a free-form-string description.
- `masc_leave_spec` description: replace the `masc_leave({agent_name: 'claude-xyz'})` example with `masc_leave({agent_name: 'worker-1'})`.

### `docs/rfc/RFC-0058-phase-5-7-doctor-modules.md`
- Status `Draft` → `Superseded by RFC-0165 + RFC-0166 (2026-05-24)`.
- Closeout note explains that the three Phase-5.7 target files reached the goal by independent paths: `codex_mcp_config_doctor.ml` was removed wholesale, `auth_doctor.ml` was cleared by RFC-0165, `server_runtime_bootstrap.ml` was already clean at supersession time. The "Generalize via TOML stanza" mechanism was deliberately not adopted.

## 5. Domain boundary (the rule that drives Non-Goals)

| Domain | Examples | Treat as |
|--------|----------|----------|
| **MCP client** (calls MASC) | Claude Code CLI, Gemini CLI, Codex CLI as MCP clients | Server must NOT enumerate. Use free-form `agent_name`; operator-side rosters resolve. |
| **Upstream LLM provider** (MASC calls) | Anthropic API, Gemini API, OpenAI/Codex API endpoints | Server domain knowledge. Closed-sum `provider_kind` is legitimate; classifier helpers (`inference_model_bucket`) are legitimate. |
| **Wire-format adapter** | `cascade_transport_codex_omission_dedup` | Legitimate. Encodes protocol quirks; carve-out per RFC-0058 §3. |

Adding a new MCP client must not require any masc-mcp source change. Adding a new upstream LLM provider naturally requires a provider-config entry and (potentially) an adapter.

## 6. Workaround-rejection self-check (`software-development.md` §워크어라운드 거부 기준)

This RFC removes; it does not add.

1. "makes X visible" without fixing — NO
2. String/substring/prefix classifier added — NO (removes the residue of the one RFC-0165 closed)
3. "PR #N fixed K of M sites" — NO (the unfinished N-of-M is *this* RFC's reason to exist; closing it now)
4. catch-all `_ ->` added — NO
5. cap / cooldown / dedup / repair — NO
6. test backdoor — NO
7. typo / off-by-one repeated — NO

All 7 rejection signatures: NO.

## 7. Verification

- `rg -i 'claude|gemini' bin/gen_tool_descriptors.ml` returns only the `Claude Code BashTool/prompt.ts` provenance comment (legitimate code-attribution, not client coupling).
- `dune build lib/ bin/` clean (`bin/gen_tool_descriptors.ml` changes are description text only — no type/dispatch change).
- `dune build test/` clean for previously passing modules.
- `gen_tool_descriptors` rerun produces JSON tool-spec output that frames `agent_name` as free-form.

## 8. Migration

None. Description text changes are operator-facing prose; no external API or CLI contract changes. `masc_spawn` / `masc_join` / `masc_leave` continue to accept any `agent_name` string exactly as before.
