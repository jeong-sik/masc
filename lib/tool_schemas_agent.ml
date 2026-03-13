open Types

let schemas : tool_schema list = [
  {
    name = "masc_heartbeat";
    description = "Update your heartbeat timestamp. Call periodically (every few minutes) to indicate you're still active. Agents without heartbeat for 5+ minutes are considered 'zombies' and can be cleaned up.";
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
    description = "Clean up zombie agents (no heartbeat for 5+ minutes). Removes stale agents and releases their file locks. Run this periodically or when you suspect agent crashes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_heartbeat_start";
    description = "Start periodic heartbeat broadcasts. Runs in background, sending pings at specified interval. Smart mode skips heartbeats when agent is busy (60-80% token savings).";
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
    description = "Stop a periodic heartbeat started by masc_heartbeat_start. \
Use when: long task complete, no longer need keep-alive, cleaning up. \
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
    description = "List all active heartbeats in the room. \
Shows: heartbeat_id, agent, interval, last_beat time. \
Use to: find orphaned heartbeats, debug presence issues, cleanup before leave.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gc";
    description = "Garbage collection - cleanup zombies, archive stale tasks, delete old messages. One command to clean everything older than N days.";
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
    description = "Get detailed status of all agents including zombie detection, current tasks, capabilities, and last seen time.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_agent_update";
    description = "Update agent metadata (status/capabilities). Use for external agents or manual corrections. Status guards prevent illegal transitions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name or nickname");
        ]);
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
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_agent_card";
    description = "Get or update the A2A-compatible Agent Card for this MASC instance. Agent Cards enable standardized agent discovery and capability advertisement. Use 'get' to retrieve current card, 'refresh' to regenerate with current bindings.";
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
    name = "masc_heartbeat_result";
    description = "A2A Worker submits heartbeat completion evidence. Worker receives heartbeat_task, runs an MCP tool loop directly, then reports status, tool usage, and decision metadata. MASC no longer proxies the board write.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("worker_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Worker agent name (e.g., 'llm-worker-local')");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Original Lodge agent name (e.g., 'dreamer')");
        ]);
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Completion status: acted | skipped | failed");
          ("enum", `List [`String "acted"; `String "skipped"; `String "failed"]);
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short completion summary");
        ]);
        ("tool_call_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of MCP tool calls executed by the worker");
        ]);
        ("tool_names", `Assoc [
          ("type", `String "array");
          ("description", `String "Executed MCP tool names");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("decision_reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why the worker chose this outcome");
        ]);
        ("decision_confidence", `Assoc [
          ("type", `String "number");
          ("description", `String "Confidence score between 0.0 and 1.0");
        ]);
        ("failure_reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional explicit failure reason");
        ]);
      ]);
      ("required",
        `List
          [
            `String "worker_name";
            `String "agent";
            `String "status";
            `String "summary";
            `String "tool_call_count";
            `String "tool_names";
            `String "decision_reason";
            `String "decision_confidence";
          ]);
    ];
  };
  {
    name = "masc_agent_fitness";
    description = "Get fitness scores for agents based on performance metrics. Higher scores indicate better performance (completion rate, reliability, speed). Use for understanding agent capabilities.";
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
    description = "Select the best agent for a task based on fitness scores. Uses weighted scoring: completion (35%), reliability (25%), speed (15%), handoff (15%), collaboration (10%).";
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
    name = "masc_gardener_retire_agent";
    description = "Evaluate whether an agent should be retired. Checks population minimums, idle thresholds, and recent contributions. Returns approval/deferral/rejection with reasons. Does NOT actually retire — use masc_gardener_execute_retire for that.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name of the agent to consider for retirement");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
]
