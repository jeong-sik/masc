(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_run_get";
    description = "Retrieve full execution history (plan, timestamped logs, deliverable) for a task as markdown. \\nUse when resuming work on a task, reviewing progress, or preparing a handoff. \\nPair with masc_run_list to find task IDs, masc_run_log to add entries.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to retrieve");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };

  {
    name = "masc_run_list";
    description = "List all task runs with their status (active/completed), plan presence, and log count. \\nUse when starting a session to find abandoned work or review completed runs. \\nAfter finding a run, call masc_run_get for full details or masc_run_init to start a new one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ===== Cache Tools (Phase 11) ===== *)
  {
    name = "masc_cache_set";
    description = "Store a key-value pair in shared cache with optional TTL and tags for cross-agent data sharing. \
Use when caching file contents, API responses, or expensive computations for reuse by other agents. \
Retrieve with masc_cache_get. Browse entries with masc_cache_list.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key (e.g., 'file:src/main.ts', 'jira:PK-123')");
        ]);
        ("value", `Assoc [
          ("type", `String "string");
          ("description", `String "Value to cache");
        ]);
        ("ttl_seconds", `Assoc [
          ("type", `String "integer");
          ("description", `String "Time-to-live in seconds. Omit for no expiry.");
        ]);
        ("tags", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Tags for filtering (e.g., ['file', 'typescript'])");
        ]);
      ]);
      ("required", `List [`String "key"; `String "value"]);
    ];
  };

  {
    name = "masc_cache_get";
    description = "Retrieve a cached entry by key; returns null if not found or expired. \
Use when you need data previously stored by yourself or another agent via masc_cache_set. \
If miss, check masc_cache_list to verify the key exists or re-populate with masc_cache_set.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to retrieve");
        ]);
      ]);
      ("required", `List [`String "key"]);
    ];
  };

  {
    name = "masc_cache_delete";
    description = "Remove a specific cache entry by key; no error if key does not exist. \\nUse when invalidating stale data, clearing a specific key, or freeing memory. \\nFind keys first with masc_cache_list. For bulk cleanup, use masc_cache_clear instead.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key", `Assoc [
          ("type", `String "string");
          ("description", `String "Cache key to delete");
        ]);
      ]);
      ("required", `List [`String "key"]);
    ];
  };

  {
    name = "masc_cache_list";
    description = "List cache entries with keys, TTL remaining, and tags; optionally filter by tag. \\nUse when browsing cached data before cleanup or looking for specific entries across agents. \\nPair with masc_cache_delete for targeted removal or masc_cache_stats for aggregate health.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tag", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by tag (optional)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_cache_clear";
    description = "Delete ALL cache entries (destructive, cannot undo). \\nUse only when resetting room state, debugging persistent cache issues, or starting fresh. \\nPrefer masc_cache_delete for targeted cleanup. Check masc_cache_stats before clearing.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_cache_stats";
    description = "Get aggregate cache statistics: total entries, memory size, oldest/newest entry age, hit/miss ratio. \\nUse when monitoring cache health, deciding whether to clear, or debugging performance issues. \\nPair with masc_cache_list for per-entry details, masc_cache_clear for full reset.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ===== Tempo Tools (Phase 12) ===== *)

  {
    name = "masc_tempo_get";
    description = "Read the current orchestrator check interval and adaptive tempo status. \
Use when checking how frequently the orchestrator polls before adjusting tempo. \
Pair with masc_tempo_set to change interval or masc_tempo_adjust for auto-tuning.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_tempo_set";
    description = "Set the orchestrator check interval manually (clamped 60s-600s). \
Use when you need a specific polling frequency for intensive or idle work phases. \
Check current value with masc_tempo_get first. Use masc_tempo_reset to return to default 300s.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("interval_seconds", `Assoc [
          ("type", `String "number");
          ("description", `String "Check interval in seconds (60-600)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Reason for tempo change");
        ]);
      ]);
      ("required", `List [`String "interval_seconds"]);
    ];
  };

  {
    name = "masc_tempo_adjust";
    description = "Auto-tune orchestrator tempo based on pending task urgency: fast for urgent, slow when idle. \
Call when you want the system to pick the right interval without manual calculation. \
Pair with masc_tempo_get to see the resulting interval after adjustment.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_tempo_reset";
    description = "Reset room tempo to the default 300s (5 minutes) interval. \\nUse after an intensive work phase or when debugging tempo-related issues. \\nTempo controls SSE heartbeat interval and agent timeout detection. Pair with masc_tempo_get to verify.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ===== Dashboard Tools (Phase 13) ===== *)
  {
    name = "masc_dashboard";
    description = "Render the MASC dashboard summarizing rooms, agents, and tasks in one view. \\nUse when you need a quick overview of cluster state; set scope='current' for this room only. \\nPair with masc_agents for agent details, masc_run_list for task details.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("compact", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, show compact single-line summary instead of full dashboard");
        ]);
        ("scope", `Assoc [
          ("type", `String "string");
          ("description", `String "Dashboard scope: 'all' (default) or 'current'");
          ("default", `String "all");
        ]);
      ]);
    ];
  };

  (* ===== Level 2: Organization Tools (Phase 13) ===== *)

  (* Fitness Selection *)
  {
    name = "masc_agent_fitness";
    description = "Get fitness scores for agents based on completion rate, reliability, and speed metrics. \
Use when evaluating agent capabilities before assigning tasks or reviewing team performance. \
Pair with masc_select_agent to pick the best agent, masc_get_metrics for raw data.";
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
    description = "Pick the best agent for a task using weighted fitness scoring (completion, reliability, speed, handoff, collaboration). \
Use when dispatching work and multiple agents are available. \
Pair with masc_agent_fitness to review scores, masc_spawn to launch the selected agent.";
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

  (* Hebbian Learning *)
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

  (* Drift Guard *)
  {
    name = "masc_verify_handoff";
    description = "Compare original and received context to detect semantic drift, information loss, or distortion after handoff. \
Call after claiming a handoff to verify context integrity (default threshold: 0.85 similarity). \
Pair with masc_handover_get for the original context, masc_handover_claim for the received.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("original", `Assoc [
          ("type", `String "string");
          ("description", `String "Original context before handoff");
        ]);
        ("received", `Assoc [
          ("type", `String "string");
          ("description", `String "Received context after handoff");
        ]);
        ("threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Similarity threshold (default: 0.85)");
          ("default", `Float 0.85);
        ]);
      ]);
      ("required", `List [`String "original"; `String "received"]);
    ];
  };

  (* Metrics *)
  {
    name = "masc_get_metrics";
    description = "Fetch raw performance metrics for an agent: task completion data, timing, error rates, and collaboration history. \
Use when investigating agent performance issues or preparing data for masc_metrics_compare. \
Pair with masc_agent_fitness for computed scores, masc_audit_stats for security-focused metrics.";
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

  (* ============================================ *)
  (* Multi-Room Management Tools                  *)
  (* ============================================ *)

  {
    name = "masc_rooms_list";
    description = "List all MASC rooms with agent/task counts and identify the current active room. \
Use when starting a session to find the right coordination space or checking cross-room state. \
After finding a room, call masc_room_enter to switch into it.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_room_create";
    description = "Create a new MASC room for coordination; room ID is auto-generated from name (slugified). \
Use when you need a separate coordination space for a different project or team. \
After creation, call masc_room_enter to switch into the new room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Room display name (e.g., 'My Project Dev', 'Personal Projects')");
        ]);
        ("description", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional room description");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_room_enter";
    description = "Switch context to a specific MASC room and auto-join with a unique nickname. \
Use after masc_rooms_list to move between coordination spaces for different projects. \
All subsequent tool calls operate in this room until you enter a different one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("room_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Room ID to enter (e.g., 'my-project-dev', 'default')");
        ]);
        ("agent_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent type: 'claude', 'gemini', or 'codex'");
          ("default", `String "claude");
        ]);
      ]);
      ("required", `List [`String "room_id"]);
    ];
  };

  {
    name = "masc_room_strategy_get";
    description = "Read current room-level defaults for search strategy and speculative routing. \
Use before changing routing behavior to see what is already configured for this room. \
Pair with masc_room_strategy_set to update search_strategy_default or speculation settings.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_room_strategy_set";
    description = "Update room-level defaults for command-plane search strategy and speculative routing. \
Use when optimizing task dispatch behavior for this room (e.g., enabling best_first_v1 or speculation). \
Check current settings with masc_room_strategy_get before making changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("search_strategy_default", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "legacy"; `String "best_first_v1"]);
          ("description", `String "Optional room default for command-plane search strategy.");
        ]);
        ("speculation_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable or disable room-level speculative routing.");
        ]);
        ("speculation_budget", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional max number of candidates to speculate over when speculation is enabled.");
        ]);
      ]);
    ];
  };

  (* ============================================ *)
  (* Audit & Governance Tools (Trust Building)   *)
  (* ============================================ *)

  {
    name = "masc_audit_query";
    description = "Search audit logs for security events: auth success/failure, anomalies, violations, tool calls. \
Use when investigating suspicious activity, verifying trust, or debugging collaboration issues. \
Pair with masc_audit_stats for aggregate trust metrics, masc_auth_list for credential status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("event_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "auth_success";
            `String "auth_failure";
            `String "anomaly_detected";
            `String "security_violation";
            `String "tool_call";
            `String "all"
          ]);
          ("description", `String "Filter by event type (default: all)");
          ("default", `String "all");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Maximum events to return (default: 50)");
          ("default", `Int 50);
        ]);
        ("since_hours", `Assoc [
          ("type", `String "number");
          ("description", `String "Only show events from last N hours (default: 24)");
          ("default", `Float 24.0);
        ]);
      ]);
    ];
  };

  {
    name = "masc_audit_stats";
    description = "Get aggregate security and trust metrics per agent: auth success rate, anomaly count, task completion rate. \
Use when evaluating agent reliability before delegating sensitive tasks. \
Pair with masc_audit_query for detailed event logs, masc_agent_fitness for performance scores.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Specific agent to analyze (optional, shows all if omitted)");
        ]);
      ]);
    ];
  };
]
