open Types

let schemas : tool_schema list = [
  {
    name = "masc_heartbeat";
    description = "Update your heartbeat timestamp to prove you are still active. \
Call every few minutes during long tasks; agents silent for 5+ min become zombie candidates. \
Prefer masc_heartbeat_start for automatic pings. Pair with masc_cleanup_zombies to reap stale agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_cleanup_zombies";
    description = "Remove zombie agents (no heartbeat for 5+ min) and release their file locks. \
Use when you see stale agents in masc_agents or suspect a crashed session left locks behind. \
Pair with masc_gc for full room maintenance including old tasks and messages.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_heartbeat_start";
    description = "Start automatic background heartbeat pings at a given interval. \
Call after masc_join to keep your presence alive during long-running work. \
Smart mode skips beats when busy. Stop with masc_heartbeat_stop before masc_leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("interval", `Assoc [
          ("type", `String "integer");
          ("description", `String "Interval in seconds between heartbeats (min: 5, max: 300)");
          ("default", `Int 30);
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Heartbeat message content");
          ("default", `String "🏓 heartbeat");
        ]);
        ("smart", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable smart mode: skip when busy, 3x interval when idle >5min");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
  {
    name = "masc_heartbeat_stop";
    description = "Stop a periodic heartbeat that was started by masc_heartbeat_start. \
Call when your long task is complete or you are about to masc_leave. \
Get heartbeat_id from masc_heartbeat_start response or masc_heartbeat_list.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("heartbeat_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of heartbeat to stop (from masc_heartbeat_start)");
        ]);
      ]);
      ("required", `List [`String "heartbeat_id"]);
    ];
  };
  {
    name = "masc_heartbeat_list";
    description = "List all active heartbeat timers in the room with their interval and last beat time. \
Use when debugging presence issues or looking for orphaned heartbeats before cleanup. \
Pair with masc_heartbeat_stop to cancel or masc_cleanup_zombies to reap dead agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gc";
    description = "Run garbage collection: remove zombie agents, archive stale tasks, delete old messages. \
Call periodically or when the room feels cluttered; defaults to 7-day age threshold. \
Pair with masc_archive_view to inspect what was archived or masc_cleanup_zombies for agents only.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("days", `Assoc [
          ("type", `String "integer");
          ("default", `Int 7);
          ("description", `String "Age threshold in days (default: 7)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_agents";
    description = "Get detailed status of all agents: zombie detection, current tasks, capabilities, and last seen time. \
Use when you need a full roster beyond what masc_who shows, including health indicators. \
Pair with masc_cleanup_zombies to remove stale agents or masc_find_by_capability to search.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_agent_update";
    description = "Update your own agent metadata (status or capabilities) with transition guards. \
Use when you need to change your status to busy/listening or update capabilities. \
Only modifies the calling agent's own record. Pair with masc_agents to verify the update.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional status: active | busy | listening | inactive");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional capability list (overwrites existing)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_agent_card";
    description = "Get or regenerate the A2A-compatible Agent Card for this MASC instance. \
Use when integrating with external A2A systems or verifying advertised capabilities. \
Action 'get' returns current card; 'refresh' rebuilds it from live bindings. Pair with masc_agents.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "refresh"]);
          ("description", `String "Action: 'get' returns current card, 'refresh' regenerates it");
        ]);
      ]);
    ];
  };
  {
    name = "masc_agent_fitness";
    description = "Get fitness scores for agents based on performance metrics (completion rate, reliability, speed). \
Use when choosing which agent to assign work to or reviewing agent performance over time. \
Pair with masc_select_agent for automated assignment or masc_agents for raw status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: Get fitness for specific agent. If omitted, returns all agents.");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of days to analyze (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
    ];
  };
  {
    name = "masc_select_agent";
    description = "Select the best agent for a task using weighted fitness scoring (completion, reliability, speed). \
Use when you have a task to assign and multiple agents are available. \
Pair with masc_agent_fitness to review scores or masc_transition(action='claim') to assign directly.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("available_agents", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of available agent names to choose from");
        ]);
        ("strategy", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "capability_first"; `String "elite_1"; `String "roulette_wheel"; `String "random"]);
          ("description", `String "Selection strategy (default: capability_first)");
          ("default", `String "capability_first");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Days of metrics to consider (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
      ("required", `List [`String "available_agents"]);
    ];
  };
  (* masc_register_capabilities *)
  {
    name = "masc_register_capabilities";
    description = "Register your skill tags so other agents can discover you by capability. \
Call after masc_join if you did not pass capabilities at join time, or to update them later. \
Pair with masc_find_by_capability to search others or masc_who to see the full roster.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("capabilities", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of your capabilities (e.g., ['typescript', 'testing'])");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "capabilities"]);
    ];
  };

  (* masc_find_by_capability *)
  {
    name = "masc_find_by_capability";
    description = "Search for active (non-zombie) agents that have a specific capability tag. \
Use when you need help with a particular skill (e.g., 'typescript') and want to find the right agent. \
Pair with masc_broadcast to @mention the found agent or masc_portal_open for direct delegation.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("capability", `Assoc [
          ("type", `String "string");
          ("description", `String "Capability to search for (e.g., 'typescript')");
        ]);
      ]);
      ("required", `List [`String "capability"]);
    ];
  };

  (* masc_collaboration_graph *)
  {
    name = "masc_collaboration_graph";
    description = "View the Hebbian collaboration graph showing learned agent-to-agent relationship strengths. \
Use when analyzing which agent pairs collaborate well or planning team composition. \
Pair with masc_consolidate_learning to prune weak connections, masc_select_agent for dispatch.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("format", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "text"; `String "json"]);
          ("description", `String "Output format (default: text)");
          ("default", `String "text");
        ]);
      ]);
    ];
  };

  (* masc_consolidate_learning *)
  {
    name = "masc_consolidate_learning";
    description = "Apply decay to old collaboration patterns and prune weak Hebbian connections. \
Trigger periodically (e.g., weekly) or after major team changes to keep the graph current. \
Pair with masc_collaboration_graph to review the graph before and after consolidation.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("decay_after_days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Apply decay to connections older than this (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
    ];
  };

  (* masc_get_metrics *)
  {
    name = "masc_get_metrics";
    description = "Fetch raw performance metrics for an agent: task completion data, timing, error rates, and collaboration history. \
Use when investigating agent performance issues or preparing data for masc_metrics_compare. \
Pair with masc_agent_fitness for computed scores and masc_status for current room context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to get metrics for");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of days of history (default: 7)");
          ("default", `Int 7);
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  (* masc_agent_relations — proxy to Neo4j/GraphQL for relationship data *)
  {
    name = "masc_agent_relations";
    description = "Query an agent's collaboration network and trust relationships from Neo4j via GraphQL. \
MASC proxies this data — Neo4j is the source of truth, not MASC. \
Returns collaborators (with count and last-seen), interests, and typed relations. \
If agent_name is omitted, defaults to the calling agent. \
Pair with masc_agents for room-level status or masc_collaboration_graph for Hebbian weights.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name to query. Defaults to calling agent if omitted.");
        ]);
      ]);
    ];
  };

]
