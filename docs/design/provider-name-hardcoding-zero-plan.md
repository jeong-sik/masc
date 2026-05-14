# Provider Name Hardcoding Zero Plan

Date: 2026-05-14

## Objective

Converge case-insensitive code-level occurrences of `codex`, `gemini`, `claude`, `kimi`, and `glm` toward zero outside explicit source-of-truth surfaces.

Zero does not mean provider names disappear from the product. It means runtime policy, auth wiring, metrics bucketing, dashboard defaults, and transport behavior do not carry scattered literals. Remaining literals must live in an intentional catalog, generated token artifact, schema/code generator, test fixture, or operator-facing text with a narrow reason.

## Current Baseline

Initial search command:

```bash
rg -n -i '\b(codex|gemini|claude|kimi|glm)\b' \
  lib bin test scripts dashboard/src dashboard_bonsai/src dashboard_bonsai/bin sidecars \
  --glob '!**/*.md' --glob '!**/*.json' --glob '!**/*.lock' \
  --glob '!**/node_modules/**' --glob '!**/_build/**'
```

Initial raw hits:

| Scope | claude | codex | gemini | glm | kimi |
| --- | ---: | ---: | ---: | ---: | ---: |
| all scanned code | 1151 | 626 | 549 | 501 | 376 |
| `lib` + `bin` runtime code | 154 | 170 | 126 | 154 | 93 |
| `test` fixtures | 902 | 365 | 374 | 260 | 214 |
| dashboard code/tokens | 74 | 63 | 36 | 77 | 68 |
| scripts/sidecars | 21 | 28 | 13 | 10 | 1 |

The high-signal runtime clusters are:

- `Provider_adapter`: provider/runtime catalog and aliases.
- `cascade_*`: model alias resolution, transport defaults, and telemetry bucketing.
- `auth_*` / `server_runtime_bootstrap`: first-party local MCP client identities.
- `exec/bin` / `spawn`: CLI executable registry.
- dashboard constants/tokens: UI defaults and visual labels.

## Zero Boundary

Allowed surfaces:

- `Provider_adapter` and OAS provider metadata for provider/runtime identity.
- `Local_mcp_clients` for first-party MCP client bearer identity.
- `Cascade_model_resolve` for model alias/default resolution until OAS owns the full model catalog.
- `Exec/bin` for audited shell executable names.
- Generated visual token files.
- Tests and fixtures that explicitly exercise provider names.
- Operator-facing text where the product must name a concrete client or command.

Disallowed surfaces:

- Substring provider inference in telemetry or routing.
- Repeated local MCP client arrays across auth, bootstrap, dashboard, or scripts.
- Dashboard defaults that pin a provider without going through config or API metadata.
- Transport defaults duplicated away from the provider catalog.
- New provider-name literals outside the allowlist without `provider-name-hardcoding-ok: <reason>`.

## Enforcement

Required detector:

```bash
scripts/lint/no-provider-name-hardcoding.sh --summary
scripts/lint/no-provider-name-hardcoding.sh --fail
```

The detector scans runtime code paths, skips tests and binary assets, strips OCaml block comments, skips comment-only lines in other scanned files, and subtracts `scripts/lint/no-provider-name-hardcoding.allowlist`. The `Provider/client name hardcoding` job in `.github/workflows/fundamental-check.yml` runs `--self-test` and `--fail`, so new off-catalog provider/client literals block the Fundamental Check workflow instead of relying on manual local invocation.

Current checkpoint after catalog migration and allowlist classification:

```bash
scripts/lint/no-provider-name-hardcoding.sh --fail
# provider-name-hardcoding: clean
```

Final pre-allowlist residual was 59 matches. Each remaining path is now in `scripts/lint/no-provider-name-hardcoding.allowlist` with a category-level reason:

- provider catalogs: `Provider_adapter`, `Local_mcp_clients`, `Cascade_model_resolve`, `Exec/bin`.
- schema/code generator sources: declarative cascade protocol parser, tool descriptors, shell IR walker generator.
- generated visual token files.
- public compatibility surfaces: `Env_config_runtime.Glm`.
- operator/fixture surfaces: client setup scripts, dashboard credit labels, harness workloads, and detector scripts.

Material runtime-policy migrations completed in this slice:

- local MCP client names now flow through `Local_mcp_clients`.
- Kimi CLI transport metadata flows through `Provider_adapter`.
- inference/metric provider bucketing flows through `Provider_adapter.inference_model_bucket`.
- cascade auth-header policy is owned by `Provider_adapter.headers_with_auth_for_provider_kind`.
- autoresearch dashboard no longer sends a provider-pinned client default; blank means the server default model path is used.

## Cleanup Phases

1. Measurement and centralization
   - Add the detector and allowlist.
   - Introduce `Local_mcp_clients` and route auth/login/bootstrap through it.
   - Success: duplicated local MCP client arrays are gone from runtime code.

2. Telemetry bucket cleanup
   - Replace `cascade_event_bridge` substring checks with catalog-derived provider family mapping.
   - Preserve current metric label values with tests.
   - Success: no provider-name substring classifier remains outside catalog.

3. Transport/default cleanup
   - Move Kimi CLI URL/model defaults behind provider metadata helpers.
   - Keep API-key env resolution catalog-owned.
   - Success: transport modules consume provider config instead of embedding names.

4. Dashboard default cleanup
   - Replace the provider-pinned frontend default with an empty client value so server defaults apply.
   - Keep visual token names generated/allowlisted only.
   - Success: dashboard behavior does not pin a provider in client constants.

5. Test/fixture cleanup
   - Keep provider-specific fixtures only where they assert provider-specific behavior.
   - Convert generic tests to generated catalog fixtures.
   - Success: remaining test hits are fixture intent, not copy-paste runtime policy.

## Done Criteria

- `scripts/lint/no-provider-name-hardcoding.sh --fail` exits 0.
- `.github/workflows/fundamental-check.yml` runs `scripts/lint/no-provider-name-hardcoding.sh --self-test` and `--fail`.
- `scripts/lint/no-provider-name-hardcoding.allowlist` contains only catalog, compatibility, generated, operator, or fixture paths with explicit category reasons.
- `rg -n -i '\b(codex|gemini|claude|kimi|glm)\b' lib bin dashboard/src scripts sidecars` has no unexplained runtime-policy hits outside the detector report.
- Focused OCaml/TS checks for touched modules pass.
