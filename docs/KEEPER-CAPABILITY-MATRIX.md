# Keeper Capability Matrix

Tool availability for keepers is determined by two axes:
**policy_mode** (who decides what tools) and **policy_shell_mode** (shell access level).

Research profile (`soul_profile = "research"`) adds autoresearch/research tools regardless of other settings.

## Tool Shards (keeper_model_tools: 28 tools total)

| Shard | Tools | Count | Removable |
|-------|-------|-------|-----------|
| **base** | `keeper_time_now`, `keeper_context_status`, `keeper_memory_search` | 3 | No |
| **board** | `keeper_board_{get,post,list,comment,vote}` | 5 | Yes |
| **filesystem** | `keeper_fs_{read,edit}` | 2 | Yes |
| **shell** | `keeper_shell_readonly`, `keeper_bash`, `keeper_github` | 3 | Yes |
| **voice** | `keeper_voice_{speak,agent,sessions,session_start,session_end}` | 5 | Yes |
| **weather** | `keeper_weather_note` | 1 | Yes |
| **library** | `keeper_library_{search,read}` | 2 | Yes |
| **taskboard** | `keeper_tasks_{list,audit}`, `keeper_task_{force_release,force_done,claim,done}`, `keeper_broadcast` | 7 | Yes |

## Policy Mode × Shell Mode Matrix

| | `disabled` | `readonly` | `sandboxed` / default | `coding` |
|---|---|---|---|---|
| **Heuristic** (default) | base + board + fs + shell + voice + weather + library + taskboard (28 tools) | same | same | same + code_write |
| **Learned_offline_v1** | read + board (12 tools) | read + board + shell_readonly (13) | read + board (12) | read + board + code_write |
| **Explicit_event_v1** | same as Heuristic | same | same | same |
| **Model_deliberation** | same as Heuristic | same | same | same |

Notes:
- "read" = `keeper_read_tool_names` (7 tools: `keeper_read`, `keeper_fs_read`, `keeper_memory_search`, `keeper_library_search`, `keeper_library_read`, `keeper_time_now`, `keeper_context_status`)
- Voice tools added when `policy_voice_enabled = true` (any mode)
- `write_done = true` returns empty tool list (session terminated)

## Research Profile Additions

When `soul_profile = "research"`, these tools are added (any policy mode):

| Source | Tools | Note |
|--------|-------|------|
| `Tool_research.schemas` | `masc_research_start`, `masc_research_status` | Research loop control |
| `Tool_shard.autoresearch_keeper_tools` | `masc_autoresearch_{start,status,stop,inject,cycle,record_finding,search_findings}` | Autoresearch suite |

These overlap with `Tool_permissions.admin_tools` for `masc_autoresearch_start` and `masc_autoresearch_stop`. Keepers access them via shard allocation, not through the dispatch permission hook.

## Safety Gates (applied to all keepers)

| Gate | Description | Config |
|------|-------------|--------|
| Cost budget | Per-session limit | `max_cost_usd` (default: $0.50) |
| Turn limit | Max tool calls per turn | `max_tool_calls_per_turn` (default: 10) |
| Entropy | Consecutive same-tool detection | `entropy_threshold` (default: 3) |
| Destructive | Pattern-match on bash/edit commands | 19 patterns, substring match |
| Allowlist/Denylist | Explicit tool filtering | `allowed_tools`, `denied_tools` |

Source: `lib/eval_gate.ml`, `lib/keeper/keeper_exec_tools.ml`, `lib/tool_shard.ml`
