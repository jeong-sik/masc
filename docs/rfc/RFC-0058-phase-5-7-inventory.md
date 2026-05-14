# RFC-0058 Phase 5.7 Inventory — Doctor Module Product Leaks

Audit baseline for [RFC-0058 Phase 5.7](RFC-0058-phase-5-7-doctor-modules.md). See companion CSV: `RFC-0058-phase-5-7-inventory.csv`.

## Method

`origin/main` `f1bcdad26e` (2026-05-14). For each of the three target files, every line matching `(codex|claude_code|gemini|kimi|glm-coding|llama)` (case-insensitive) is one entry. Lines matching multiple products yield a single entry with the product list `|`-joined.

215 entries total. First-pass classification by `leak_class` heuristic — auto-classified, not human-reviewed line-by-line. The 47 `needs_review` entries (22%) need human classification during Phase 5.7.2–5.7.5 implementation; they were not forced into a heuristic class to avoid false signals.

## Per-file totals

| File | Entries | Notes |
|------|---------|-------|
| `lib/codex_mcp_config_doctor.ml` | 81 | Entire module named after Codex CLI. Filename itself is a leak. |
| `lib/auth_doctor.ml` | 72 | Single-product branch density highest of the three. |
| `lib/server/server_runtime_bootstrap.ml` | 43 | Boot-time MCP config sync helpers. |
| `lib/auth_doctor.mli` | 12 | Public type/value names carry Codex. |
| `lib/codex_mcp_config_doctor.mli` | 7 | Module's public surface. |

## Leak class distribution

| leak_class | Count | Phase 5.7 target |
|------------|-------|------------------|
| `symbol_reference` | 75 | Symbol uses like `codex_mcp_*`, `Codex_mcp_*`. Most resolve when binding sites rename (cascade through type system). |
| `needs_review` | 47 | Heuristic could not classify. Hand-classify in 5.7.2/5.7.3 PRs as they touch each cluster. |
| `user_msg_string` | 34 | User-facing diagnostic text ("skipped because Codex config did not parse as TOML"). Survives in TOML `[providers.<id>.diagnostic_messages]` or doctor receives a `~display_name:string` argument. |
| `header_or_env_literal` | 19 | `X-MASC-Agent: codex-mcp-client`, `MASC_CODEX_CONFIG_PATH` env var. Survives in `[providers.<id>.mcp_client_config.header_values]` + `env_var_prefix`. |
| `binding_name` | 18 | `let codex_foo = ...` definitions. Rename in 5.7.2/5.7.3 (compiler enumerates callers). |
| `module_reference` | 9 | `Codex_mcp_config_doctor.t` etc. — references to module names. Resolve when 5.7.5 renames the module. |
| `string_literal` | 6 | Bare product strings outside diagnostic contexts. |
| `docstring` | 4 | OCamldoc comments. Update in 5.7.5 when filenames change. |
| `path_template` | 3 | `~/.codex/config.toml` — already TOML-owned in proposed schema (`config_path_template`). |

## What this baseline says

The `codex_mcp_config_doctor.ml` filename is **1 leak** but its impact is module-shaped: every `module_reference` (9), every `symbol_reference` to `Codex_mcp_*` (~30 of 75), and the entire public `.mli` (7) hang off it. Renaming the file is the single largest payoff per LoC changed.

`auth_doctor.ml` is the opposite shape: no filename leak, but the highest density of internal symbol leakage and the 34 `user_msg_string` entries cluster here. This file's cleanup is structural (extract `auth_doctor_core` per RFC §4 Phase 5.7.3), not cosmetic rename.

`server_runtime_bootstrap.ml` carries the boot-path Codex MCP config sync. Cleanup here depends on the TOML schema additions in 5.7.1.

## What this baseline does *not* say

- **Behavioural correctness**: the CSV is grep-shaped, not semantically verified. A line tagged `symbol_reference` may carry semantic content that does not survive a mechanical rename (e.g., a branch that genuinely depends on Codex-specific behaviour).
- **Test coverage**: which doctor outputs are covered by snapshot tests is unknown at this baseline. RFC §6 risk "user-facing behaviour change" needs test coverage measurement before 5.7.5 ships.
- **Out-of-scope modules**: this audit covers the three files named in RFC §1. Adjacent files (`lib/keeper/keeper_codex_*` if any, `lib/cascade/*_codex_*` if any) are not measured here. RFC §6 risk "hidden product knowledge" addresses this — new findings go to a follow-up RFC, not into 5.7 scope.

## How to use the CSV during phase work

1. Open a 5.7.N branch.
2. `awk -F, '$4 == "needs_review" && $1 == "<file>"' RFC-0058-phase-5-7-inventory.csv` for hand-classification at touch time.
3. After the PR lands, update the CSV (delete rows that no longer match `origin/main`, or commit a regeneration in the same PR).
4. RFC-0058 §G1 (monotonic decrease) is verified against this CSV's line count, not against a fresh `rg` invocation that may have classifier drift.
