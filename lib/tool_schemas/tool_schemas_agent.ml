open Types

let schemas : tool_schema list = [
  {
    name = "masc_heartbeat";
    description = "Update your heartbeat timestamp to prove you are still active. Agents silent 5+ min become zombie candidates.";
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
    name = "masc_heartbeat_start";
    description = "Start automatic background heartbeat pings at a given interval. Smart mode skips beats when busy.";
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
    description = "Stop a periodic heartbeat started by masc_heartbeat_start.";
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
    description = "List all active heartbeat timers in the room with interval and last beat time.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_agents";
    description = "Get detailed status of all agents: zombie detection, current tasks, capabilities, last seen time.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_agent_update";
    description = "Update your own agent metadata (status or capabilities) with transition guards.";
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
    description = "Get or regenerate the A2A-compatible Agent Card for this MASC instance.";
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
    description = "Get fitness scores for agents based on completion rate, reliability, and speed metrics.";
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
    description = "Select the best agent for a task using weighted fitness scoring (completion, reliability, speed).";
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
  {
    name = "masc_register_capabilities";
    description = "Register your skill tags so other agents can discover you by capability.";
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

  {
    name = "masc_find_by_capability";
    description = "Search for active (non-zombie) agents that have a specific capability tag.";
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

  {
    name = "masc_collaboration_graph";
    description = "View the Hebbian collaboration graph showing learned agent-to-agent relationship strengths.";
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

  {
    name = "masc_consolidate_learning";
    description = "Apply decay to old collaboration patterns and prune weak Hebbian connections.";
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

  {
    name = "masc_get_metrics";
    description = "Fetch raw performance metrics for an agent: task completion, timing, error rates, collaboration history.";
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

  {
    name = "masc_agent_relations";
    description = "Query an agent's collaboration network and trust relationships from Neo4j via GraphQL.";
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

  {
    name = "masc_meta_cognition_snapshot";
    description = "Read a room-level meta-cognition snapshot derived from board, task, agent, and governance artifacts. Use this to inspect shared beliefs, tensions, desires, and discourse edges.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum items to return per section (default: 5, max: 20)");
          ("default", `Int 5);
        ]);
        ("hearth", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional hearth/topic filter (e.g. ops, research, code-review)");
        ]);
      ]);
    ];
  };

]
