# RFC-0165 MCP server is client-agnostic

| | |
|---|---|
| Status | Draft |
| Related | RFC-0042 closed-sum noted, RFC-0058 Phase 5.7 (different shape — Generalize vs Remove), RFC-0088 Counter-as-Fix umbrella, RFC-0149 Telemetry-as-fix sunset |
| Scope | `lib/auth_login.ml{,.mli}`, `lib/auth_doctor.ml{,.mli}`, `bin/main_eio.ml` (login CLI), tests, runbook |
| Repos | masc-mcp |

## 1. Problem

`lib/auth_login.ml` and `lib/auth_doctor.ml` carried hardcoded knowledge of two MCP clients (Agent-LLM-A and Provider-F) in two SSOTs:

1. **`auth_login.ml:23-30`** — `mcp_token_env_var_for_agent` dispatched on agent_name string to pick a per-client env var name (`MASC_AGENT-LLM-A_MCP_TOKEN`, `MASC_PROVIDER-F_MCP_TOKEN`); `is_local_mcp_client_agent` matched on the same names to switch to a no-expiry credential.
2. **`auth_doctor.ml:78-90`** — `mcp_client_specs` list embedded the same two clients as a static spec, producing a per-client diagnostic in the JSON / text doctor output.

MASC is an MCP **server**. A server has no reason to know which clients connect to it. The coupling matches workaround-rejection signature §2 ("string-classifier addition", `software-development.md`): a closed-sum domain (the set of MCP clients) was encoded as string-match arms, so adding a new client would require touching server code in two places.

Live measurement (2026-05-24) of the env var reads showed the runtime cost is *zero* — `MASC_AGENT-LLM-A_MCP_TOKEN` and `MASC_PROVIDER-F_MCP_TOKEN` are read **only by the external MCP clients** (CLI-Tool-A, CLI-Tool-C). The server itself emits these names but never looks them up. The "table" was pure surface convention disguised as policy.

## 2. Decision

The server holds no list of "known" MCP clients. The caller (CLI or API consumer) supplies:

- The env var name (`--client-env <VAR>`, required, no default).
- The token-lifetime policy (`--no-expiry` flag, default `With_expiry`).

The per-client doctor diagnostic is removed. Operators who need per-client readiness checks compose them externally over the raw `doctor auth --json` output and their own client roster.

## 3. Why "Remove" rather than "Generalize via TOML"

RFC-0058 Phase 5.7 (Draft) proposed generalizing similar single-product knowledge in `auth_doctor.ml` by reading client specs from `[providers.<id>.mcp_client_config]` TOML stanzas. That is a valid alternative shape.

We chose **Remove** instead of **Generalize** because:

1. The server emits — but does not read — these env names. There is no protocol invariant or auth boundary that justifies the server enforcing the client roster.
2. The diagnostic's value is observable from the raw doctor output (`watched_agents`, `admin_bearer_sources`); a downstream wrapper script can synthesize the per-client view without server cooperation.
3. Adding a TOML loader to read client specs keeps the coupling: any new client still requires *something* in the masc-mcp codebase (a stanza, a default file). Removing the diagnostic moves the boundary cleanly to the operator's wrapper.

## 4. Non-Goals

- Generalizing dispatch in other doctor modules (`codex_mcp_config_doctor.ml`, `server_runtime_bootstrap.ml`). RFC-0058 Phase 5.7 still governs those.
- Adding a new TOML-driven client roster.
- Sunset of `Auth.create_token_without_expiry`: it remains the implementation of the `Long_lived` lifetime, called from `Auth_login.mint` when `--no-expiry` is set.

## 5. Changes

### `lib/auth_login.ml{,.mli}`
- Delete `default_mcp_token_env_var`, `mcp_token_env_var_for_agent`, `is_local_mcp_client_agent`.
- Add closed-sum type `token_lifetime = With_expiry | Long_lived`.
- `mint` gains required named args `~token_env_var:string` and `~token_lifetime:token_lifetime`.
- `mcp_token_env_var` record field now stores the caller-supplied string verbatim.

### `bin/main_eio.ml` (login subcommand)
- New `--client-env VAR` flag, **required, no default**. Omitting it fails with a Cmdliner usage error.
- New `--no-expiry` flag, default false.
- `Auth_login.mint` call threads both values through.

### `lib/auth_doctor.ml{,.mli}`
- Delete `mcp_client_spec`, `mcp_client_specs`, `mcp_client_report`, `mcp_client_warning`, `mcp_client_next_action`, `mcp_client_to_yojson`, the public `mcp_client` type, and the `t.mcp_clients` field.
- Remove the `mcp_clients:` text section and the JSON `mcp_clients` key.

### Tests
- `test/test_auth_login.ml`: renamed both cases. Case 1 verifies caller-supplied env var passthrough for `With_expiry`. Case 2 verifies passthrough + `expires_at = None` for `Long_lived` using an arbitrary `CUSTOM_MCP_TOKEN` name and a non-agent-llm-a/provider-f agent.
- `test/test_auth_doctor.ml`: removed `test_reports_claude_and_provider-f_mcp_client_identities` and the `find_mcp_client` helper. Added a regression test that the JSON output omits `"mcp_clients"` and the text output omits `mcp_clients:`.

### Docs
- `docs/LOCAL-DASHBOARD-AUTH-RUNBOOK.md` §5 rewritten: examples include `--client-env` and `--no-expiry`; conventions are explicitly framed as operator-side recommendations, not server policy. The factually wrong "Local startup also self-heals private non-expiring token files for `agent-llm-a` and `provider-f`" sentence is removed (no such code path exists; the unrelated keeper credential self-heal in `auth.ml:881` does not seed MCP-client tokens).

## 6. Breaking changes

**CLI**: `masc-mcp login --agent agent-llm-a --role worker --shell` (without `--client-env`) now exits non-zero with a usage error. Callers must add `--client-env <VAR>`. Long-running local MCP daemons should also add `--no-expiry` to preserve prior behavior.

**JSON API**: `doctor auth --json` no longer emits a `mcp_clients` field. Dashboard does not consume this field (verified by `rg 'mcp_clients' dashboard/` — 0 hits); `keeper_oas_checkpoint.ml:60`'s `mcp_clients` is an unrelated `Agent_sdk.Agent.options` field.

**Text output**: `doctor auth` text rendering loses the `mcp_clients:` section.

## 7. Workaround-rejection self-check (`software-development.md` §워크어라운드 거부 기준)

This PR *removes* a string-classifier; it does not add one. Self-check against the 7 rejection items:

1. "makes X visible" without fixing — NO (deletes a diagnostic, no telemetry added).
2. String/substring/prefix classifier added — NO (deletes two of them).
3. "PR #N fixed K of M sites" — NO (single PR closes both SSOTs).
4. catch-all `_ ->` added — NO (closed-sum `token_lifetime` replaces the implicit fall-through).
5. cap / cooldown / dedup / repair without alternate RFC — NO.
6. test backdoor — NO.
7. typo / off-by-one repeated across N sites — NO.

## 8. Migration

`~/me/scripts/mcp-sync.sh` should be updated (separate PR) to pass `--client-env MASC_AGENT-LLM-A_MCP_TOKEN --no-expiry` for Agent-LLM-A and `--client-env MASC_PROVIDER-F_MCP_TOKEN --no-expiry` for Provider-F. Until that PR lands, operators run those flags manually.

## 9. Verification

- `rg -i 'agent-llm-a|provider-f' lib/auth_login.ml lib/auth_doctor.ml` returns 0 hits.
- `dune build` clean.
- `dune exec test/test_auth_login.exe` PASS for both cases.
- `dune exec test/test_auth_doctor.exe` PASS for all three cases (including new "json omits mcp_clients" regression test).
- CLI smoke: `login --agent X --role worker --client-env CUSTOM_VAR --shell` emits `export CUSTOM_VAR=...`; without `--client-env` the CLI fails fast with a usage error.
