# Agent Join Rules and Classification

How agents enter a MASC room and how the system distinguishes agent types.

## Join Paths

| Path | Name Format | Lifecycle | Trigger |
|------|------------|-----------|---------|
| Keeper auto-start | `keeper-{persona}-agent` | Long-lived | `masc_keeper_up` or resident bootstrap |
| MCP auto-join | `agent-{session_hash}` | Ephemeral | First tool call with `Mcp-Session-Id` header |
| Explicit join | User-specified or nickname | Ephemeral | `masc_join` tool call |
| Swarm worker | Session-prefix based | Ephemeral | Team session / operator dispatch |

### Keeper Path

Keepers are long-lived agents backed by a persona profile and persistent state.

- Name: `keeper-{persona}-agent` (e.g. `keeper-sangsu-agent`)
- Created by `Keeper_types_profile.keeper_agent_name` (`lib/keeper/keeper_types_profile.ml`)
- Registered in `Keeper_registry` (in-memory) and persisted to `.masc/perpetual-keepers/{name}.json`
- Session checkpoint stored under `.masc/perpetual/{trace_id}/`
- Keepalive fiber maintains heartbeat and metrics

### MCP Auto-Join Path

External MCP clients (Claude Code, other agents) get auto-joined on first tool call.

- Name: `agent-{session_key_prefix}` (e.g. `agent-ab3f9e`)
- Generated in `mcp_server_eio_execute.ml` from the `Mcp-Session-Id` header
- Auto-join only fires when:
  - The tool requires room membership (`is_join_required`)
  - A stable session ID is present (no session = no auto-join, prevents orphan agents)
  - Auth allows it (token-based auth requires stable nickname)
- Nickname may be reassigned by `Room.join` based on the agent registry

### Explicit Join

Agents call `masc_join` with an optional `agent_name` parameter.

- If omitted, server assigns a nickname
- Capabilities can be declared at join time

### Swarm Workers

Team session workers receive names derived from the session prefix.

- Dispatched by `Team_session_engine_eio` or the operator
- Lifetime bound to the team session

## Agent Classification

### Keeper Detection

The system identifies keepers by name pattern **and** `agent_type` field.

```
is_keeper(name, agent_type) =
  name matches "keeper-*-agent" (case-insensitive)
  OR agent_type = "keeper"
```

Code: `Resilience.Zombie.is_keeper` (`lib/room/resilience.ml`)

Name-only matching is intentionally insufficient: any agent named `keeper-*-agent` would get the extended zombie threshold without the type check.

### Persona Extraction

Dashboard and status views extract the persona name from the agent name:

```
"keeper-sangsu-agent" -> "sangsu"
```

Code: `Dashboard_execution_helpers.extract_persona_name` (`lib/dashboard/dashboard_execution_helpers.ml`)

### Zombie Thresholds

| Agent Type | Zombie Threshold |
|-----------|-----------------|
| Keeper | 7 days |
| Regular agent | Default (configurable) |

Keepers get an extended threshold because they are designed to be long-lived and may be idle between interactions.

## Adding a New Agent Type

When adding a new agent type:

1. Define the name format in a dedicated module
2. Add classification logic to `Resilience.Zombie.is_keeper` or create a parallel check
3. Set appropriate zombie threshold
4. Document the join path in this file
