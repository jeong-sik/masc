# Official-client optional schema deferral, 2026-10-24

Fourteen optional publishing, surface, memory, image and plan-inspection tools
previously loaded upfront. Their declarations now use `defer_loading = true`.
No tool schema, handler, permission or result changes. The four discovery/Skill
bootstrap tools and all five deliberately resident Candle tools remain unchanged.
Task-required composition tools retain the existing eager promotion.

## Evidence

`codex-probe.json` records a three-arm official Codex app-server probe using
ChatGPT subscription authentication, model `gpt-6.1-sol`, and the fourteen real
schemas from a retained provider-input snapshot. Dynamic handlers were local
fixtures; no product effect was executed. Both idle arms used the same goal and
developer instructions. The third arm requested a deferred surface reader.

| Arm | First request input tokens | Result |
|---|---:|---|
| All fourteen upfront | 30,023 | `PROBE_OK`, no dynamic call |
| All fourteen deferred | 26,052 | `PROBE_OK`, no dynamic call |
| Deferred discovery and invocation | 26,493 | `keeper_surface_read` discovered and called; `PROBE_READ_OK` |

The paired idle difference is **3,971 input tokens**. These are provider-reported
`thread/tokenUsage/updated.tokenUsage.last.inputTokens`, inclusive of cached
input, not a sum of cumulative totals. The invocation arm has a different goal
and multiple requests; its first request is not an additional idle comparison.
This is one pair, not a production estimate or a multi-model benchmark.
The fourteen captured schema bodies total 19,078 bytes; bytes are not tokens.

The manual probe follows `scripts/probe-codex-app-server-schema.py`'s
`initialize` / `account/read` / `thread/start` / `turn/start` protocol, supplies
the same `name`, `description`, `inputSchema`, and `namespace=masc` in each arm,
and changes only `deferLoading` for the paired arms. The first two goals say
`Reply with only PROBE_OK. Do not call tools.` A fixture `item/tool/call`
response returns `PROBE_READ_OK` for the third arm. Observe each request's `last`
usage rather than the thread's cumulative `total`. The subprocess environment matches `Runtime_codex_environment_projection`'s
whitelist; CLI overrides disable shell/unified exec and vendor subagents,
matching MASC's Native_read posture. This is still not a paired installed
Keeper run. An earlier inherited-environment probe observed 32,230 versus
28,660 input tokens; it was replaced because that launch also inherited the
coding session's environment.

## Client boundaries

- Codex maps these declarations to `deferLoading=true`.
- Claude Code leaves these tools behind its existing `ToolSearch` rather than
  marking them `anthropic/alwaysLoad`. No Claude token comparison was run.
- Antigravity ignores the declaration and currently registers every tool eagerly:
  its deferred schema-file read is blocked by the native-read policy. No Argon
  saving is claimed. Removing the eager flag alone would break discovery.
- Whole schema transport size is not evidence that every schema reaches a model:
  the official clients own deferred loading and provider history.
- Large starts after a runtime switch carry canonical history. This change does
  not delete history or claim those necessary starts are redundant replay.

Anthropic documents the distinction in
[its MCP tool-search contract](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search).
MASC's consumer paths are `Keeper_tools_agent_core_bundle`,
`Keeper_official_client_host.loading_of_plan`,
`Runtime_codex_app_server.dynamic_tool_spec`, and
`Runtime_claude_code.dynamic_tool_meta`.

## Validation and delivery

All 524 repository TOMLs parsed with `scripts/check-toml-syntax.sh`.
Parsed before/after declarations differ only in `defer_loading` for the fourteen
files. `git diff --check` passed. Independent source review found the earlier
Candle proposal contradicted its deliberate discovery decision; those changes
were removed and the corrected fourteen-file diff passed re-review.
No Dune build or full regression was run for this declaration-only change.

PR #45714 was created through `gh stack submit`. Its earlier generic warning
`Stacked PRs are not enabled for this repository` was a misleading client error:
the actual Stacks API request returned HTTP 401 Bad credentials, while `gh api`
using the active CLI credential returned the stack list successfully. Passing
that active credential to the extension for one invocation allowed submission;
no repository feature setting or persistent authentication configuration changed.
The change is not merged or installed. Installed-runtime verification remains pending.

## Follow-up audit of the remaining client settings

The 37 live Keeper declarations were inspected: 22 explicitly select `small`
and 15 omit the field. `Keeper_input_policy.default = Small`, so the omissions
are not a wide-history configuration defect. No redundant per-Keeper override
was added.

The Antigravity eager exception cannot safely be removed by granting its schema
directory beside `read_file(*)` in the deny list. Google's
[CLI permission contract](https://www.antigravity.google/docs/permissions?tab=cli)
gives deny precedence over allow; it also auto-allows unconfigured workspace
reads. Removing the blanket deny would therefore require a separate boundary
change and validation, not just a token optimization. The existing permissions
were retained.

The existing `keeper_tool_search` is not a substitute schema reader for this
client: `Keeper_identity_tool_search.load` requires a running Agent Core cell
and extends that agent's tool set. An official client owns its own set instead.
The capability search returns discovery candidates; its canonical input-schema
material participates in a digest but is not returned as a schema-loading
response. A future Argon lazy path must first deliver the exact frozen schema
through an actual client-supported boundary and prove discovery/callability;
merely registering fewer eager tools is insufficient.

Antigravity currently has no observed compaction/reset witness, and its runtime
therefore resends current carried context with an empty held set. A lower byte
count obtained by assuming the vendor still holds an earlier block would not
prove a correct improvement. The large start after a runtime switch and that
resume policy were left distinct from the fourteen corrected declarations.
