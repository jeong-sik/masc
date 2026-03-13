(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_run_get";
    description = "Get full execution history for a task as markdown. \
Returns: plan, logs (timestamped), and deliverable if completed. \
Use when: resuming work, reviewing progress, preparing handoff. \
Example: masc_run_get({task_id: 'task-001'}) → '## Plan\\n...\\n## Logs\\n- 10:00 Started...'";
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
    description = "List all task runs with status (active/completed). \
Shows: task_id, has_plan, log_count, has_deliverable. \
Use to find: abandoned work, completed runs for review, active executions. \
Example response: [{task_id: 'task-001', status: 'active', logs: 5}]";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ===== Cache Tools (Phase 11) ===== *)
  {
    name = "masc_cache_set";
    description = "Set a cache entry for sharing context between agents. Useful for caching file contents, API responses, or expensive computations.";
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
    description = "Get a cached entry by key. Returns null if not found or expired.";
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
    description = "Delete a specific cache entry. \
Use when: invalidating stale data, clearing specific key, freeing memory. \
No error if key doesn't exist. Use masc_cache_list to find keys.";
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
    description = "List cache entries with keys, TTL remaining, and tags. \
Filter by tag to find related entries. Shows creation time and expiry. \
Use before: cache cleanup, debugging stale data, finding specific entries. \
Example: masc_cache_list({tag: 'api'}) → [{key: 'user_123', ttl: 3600, tags: ['api']}]";
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
    description = "Delete ALL cache entries. DESTRUCTIVE - cannot be undone. \
Use only when: resetting room state, debugging cache issues, fresh start. \
Consider masc_cache_delete for targeted cleanup instead.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_cache_stats";
    description = "Get cache usage statistics. \
Shows: total entries, memory size, oldest/newest entry age, hit/miss ratio. \
Use to: monitor cache health, decide when to clear, debug performance.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ===== Tempo Tools (Phase 12) ===== *)

  {
    name = "masc_tempo_get";
    description = "Get current orchestrator tempo (check interval). Shows adaptive tempo status.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_tempo_set";
    description = "Set orchestrator tempo manually. Interval is clamped between 60s (fast) and 600s (slow).";
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
    description = "Automatically adjust tempo based on pending task urgency. Fast for urgent tasks, slow when idle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_tempo_reset";
    description = "Reset room tempo to default 300s (5 minutes). \
Tempo controls SSE heartbeat interval and agent timeout detection. \
Use after: intensive work phase complete, debugging tempo issues. \
Lower tempo = faster detection but more overhead. Default balances both. \
Example: masc_tempo_reset() → {tempo: 300, message: 'Reset to default'}";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ===== Dashboard Tools (Phase 13) ===== *)
  {
    name = "masc_dashboard";
    description = "Show the MASC dashboard. By default it summarizes all rooms, and you can filter to the current room with scope='current'. Use with 'watch -n 1' for real-time updates.";
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

  (* Hebbian Learning *)
  {
    name = "masc_collaboration_graph";
    description = "View the Hebbian collaboration graph showing learned agent relationships. Stronger connections indicate successful collaboration patterns.";
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
    description = "Trigger Hebbian consolidation - apply decay to old collaboration patterns and prune weak connections. Mimics memory consolidation during sleep.";
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
    description = "Verify handoff context integrity. Compares original and received context to detect semantic drift, information loss, or distortion. Threshold: 0.85 similarity.";
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
    description = "Get raw performance metrics for an agent. Returns task completion data, timing, error rates, and collaboration history.";
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
    description = "List all available MASC rooms. Returns rooms with agent/task counts and current active room. Use to see available coordination spaces before entering one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_room_create";
    description = "Create a new MASC room for coordination. Room ID is auto-generated from name (slugified). Use to create separate spaces for different projects or teams.";
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
    description = "Enter a specific MASC room. Switches context to the selected room and auto-joins with a unique nickname. Use after masc_rooms_list to switch between coordination spaces.";
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
    description = "Read the current room-level search and speculation defaults. Use this before changing routing behavior so you know whether best_first_v1 or speculation is already enabled for the room.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_room_strategy_set";
    description = "Update room-level search and speculation defaults. Use this to set the default command-plane search strategy and to enable or disable speculative routing for the current room.";
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
    description = "Query audit logs to inspect agent actions and security events. Returns recent security events: auth success/failure, anomalies, violations. Use for trust verification and debugging collaboration issues.";
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
    description = "Get security statistics and trust metrics for agents. Shows auth success rate, anomaly count, task completion rate per agent. Use to evaluate agent reliability before delegation.";
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
