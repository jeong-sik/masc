open Types

let schemas : tool_schema list = [
  {
    name = "masc_a2a_discover";
    description = "Discover available A2A agents. Returns agent cards with capabilities, skills, and protocol bindings. Use for local room discovery or remote endpoint fetching.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("endpoint", `Assoc [
          ("type", `String "string");
          ("description", `String "Remote endpoint URL (optional, defaults to local room)");
        ]);
        ("capability", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by capability (e.g., 'typescript', 'code-review')");
        ]);
      ]);
    ];
  };
  {
    name = "masc_a2a_query_skill";
    description = "Query detailed information about an agent's skill, including input/output modes and examples. Use to understand what a skill can do before delegating.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Target agent name");
        ]);
        ("skill_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Skill ID to query (e.g., 'task-management', 'git-worktree')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "skill_id"]);
    ];
  };
  {
    name = "masc_a2a_delegate";
    description = "Delegate a task to another A2A agent. Opens portal, sends task, returns task ID. Use sync for waiting, async for fire-and-forget, stream for real-time updates.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to delegate to");
        ]);
        ("task_type", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "sync"; `String "async"; `String "stream"]);
          ("default", `String "async");
          ("description", `String "Type: 'sync' (wait), 'async' (fire-and-forget), 'stream' (real-time)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Task description or prompt to send");
        ]);
        ("artifacts", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "object");
            ("properties", `Assoc [
              ("name", `Assoc [("type", `String "string")]);
              ("mime_type", `Assoc [("type", `String "string")]);
              ("data", `Assoc [("type", `String "string")]);
            ]);
          ]);
          ("description", `String "Optional input artifacts (files, data)");
        ]);
        ("timeout", `Assoc [
          ("type", `String "integer");
          ("default", `Int 300);
          ("description", `String "Timeout in seconds (default: 300)");
        ]);
      ]);
      ("required", `List [`String "target_agent"; `String "message"]);
    ];
  };
  {
    name = "masc_a2a_subscribe";
    description = "Subscribe to events from agents (task updates, broadcasts, completions). Connect to SSE endpoint to receive events.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to subscribe to (or '*' for all agents)");
        ]);
        ("events", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [
            ("type", `String "string");
            ("enum", `List [`String "task_update"; `String "broadcast"; `String "completion"; `String "error"]);
          ]);
          ("description", `String "Event types to subscribe to");
        ]);
      ]);
      ("required", `List [`String "events"]);
    ];
  };
  {
    name = "masc_a2a_unsubscribe";
    description = "Stop receiving events from a background subscription. \
Call when: (1) done monitoring, (2) switching to different events, (3) cleanup before leave. \
Frees server resources - always unsubscribe when done. \
Get subscription_id from masc_a2a_subscribe response. \
Example: masc_a2a_unsubscribe({subscription_id: 'sub-abc123'})";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to remove");
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
  };
  {
    name = "masc_poll_events";
    description = "Poll buffered events for a subscription. Use this for background subscription workflow: subscribe → do work → poll_events periodically. Returns and clears buffered events.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID to poll events from");
        ]);
        ("clear", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Clear buffer after reading (default: true)");
          ("default", `Bool true);
        ]);
      ]);
      ("required", `List [`String "subscription_id"]);
    ];
  };
  {
    name = "masc_tempo";
    description = "Get or set cluster tempo (pace control). Use to slow down for careful work or speed up for simple tasks.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "set"]);
          ("description", `String "Get current tempo or set new tempo");
        ]);
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "normal"; `String "slow"; `String "fast"; `String "paused"]);
          ("description", `String "Tempo mode (only for set action)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why changing tempo");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_mcp_session";
    description = "Manage MCP sessions (Mcp-Session-Id; legacy X-MCP-Session-ID also accepted). Sessions track client context across requests.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "get"; `String "create"; `String "list"; `String "cleanup"; `String "remove"]);
          ("description", `String "Session action");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Session ID (for get/remove)");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (for create)");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_cancellation";
    description = "Manage cancellation tokens for long-running operations. Check tokens to abort work gracefully.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "create"; `String "cancel"; `String "check"; `String "list"; `String "cleanup"]);
          ("description", `String "Cancellation action");
        ]);
        ("token_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Token ID (for cancel/check)");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Cancellation reason");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_subscription";
    description = "Subscribe to resource changes (tasks, agents, messages, votes). Receive notifications via polling or SSE.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "subscribe"; `String "unsubscribe"; `String "list"; `String "poll"]);
          ("description", `String "Subscription action");
        ]);
        ("subscriber", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscriber ID (agent_name or session_id)");
        ]);
        ("resource", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "tasks"; `String "agents"; `String "messages"; `String "votes"]);
          ("description", `String "Resource type");
        ]);
        ("filter", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional filter (specific ID or '*')");
        ]);
        ("subscription_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Subscription ID (for unsubscribe/poll)");
        ]);
      ]);
      ("required", `List [`String "action"]);
    ];
  };
  {
    name = "masc_progress";
    description = "Send progress notifications for long-running tasks. Broadcasts via SSE using MCP notifications/progress format.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "start"; `String "update"; `String "step"; `String "complete"; `String "stop"]);
          ("description", `String "Progress action: start tracking, update progress, step forward, complete, or stop tracking");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task identifier for progress tracking");
        ]);
        ("progress", `Assoc [
          ("type", `String "number");
          ("description", `String "Progress value (0.0 to 1.0, for 'update' action)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional progress message");
        ]);
        ("total_steps", `Assoc [
          ("type", `String "integer");
          ("description", `String "Total steps (for 'start' action, default: 100)");
        ]);
      ]);
      ("required", `List [`String "action"; `String "task_id"]);
    ];
  };
  {
    name = "masc_handover_create";
    description = "Create a handover record (agent's 'last will') before context limit or session end. Contains goal, progress, decisions, warnings for the next agent. Inspired by Stanford Generative Agents memory stream + Erlang 'let it crash' supervisor pattern.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (the dying agent)");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task being worked on");
        ]);
        ("session_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Current session identifier");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "context_limit"; `String "timeout"; `String "explicit"; `String "error"; `String "complete"]);
          ("description", `String "Why handover is triggered");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Current goal being pursued");
        ]);
        ("progress", `Assoc [
          ("type", `String "string");
          ("description", `String "Summary of progress made");
        ]);
        ("completed_steps", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Steps already completed");
        ]);
        ("pending_steps", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Steps remaining to do");
        ]);
        ("decisions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Key decisions made and why (implicit knowledge transfer)");
        ]);
        ("assumptions", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "What we're assuming is true");
        ]);
        ("warnings", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Gotchas and things to watch out for");
        ]);
        ("errors", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Unresolved errors from PDCA loop");
        ]);
        ("files", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Files modified during this session");
        ]);
        ("context_pct", `Assoc [
          ("type", `String "integer");
          ("description", `String "Context usage percentage when handover triggered");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "reason"; `String "goal"]);
    ];
  };
  {
    name = "masc_handover_list";
    description = "List all handover records, optionally filtering by pending (unclaimed) ones. Use to see what work is waiting to be picked up.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("pending_only", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, only show unclaimed handovers");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
  {
    name = "masc_handover_get";
    description = "Get full details of a handover record as formatted markdown. Use to understand context before claiming.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("handover_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the handover to retrieve");
        ]);
      ]);
      ("required", `List [`String "handover_id"]);
    ];
  };
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
  {
    name = "masc_governance_report";
    description = "Generate a governance summary report from the audit trail. Aggregates per-agent action counts, cost estimates, token usage, and failure rates over a time period. Use for periodic governance review and cost tracking.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("since", `Assoc [
          ("type", `String "string");
          ("description", `String "Start of period as Unix timestamp string (optional, defaults to all time)");
        ]);
        ("until", `Assoc [
          ("type", `String "string");
          ("description", `String "End of period as Unix timestamp string (optional, defaults to now)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_set";
    description = "Configure governance policies for the room. Enables audit logging, anomaly detection, and agent isolation. Enterprise security for production use.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("level", `Assoc [
          ("type", `String "string");
          ("enum", `List [
            `String "development";
            `String "production";
            `String "enterprise";
            `String "paranoid"
          ]);
          ("description", `String "Security level: development (permissive), production (basic), enterprise (audit+encryption), paranoid (max isolation)");
          ("default", `String "production");
        ]);
        ("audit_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable audit logging (default: true for production+)");
          ("default", `Bool true);
        ]);
        ("anomaly_detection", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable anomaly detection (auth spikes, low success rate)");
          ("default", `Bool false);
        ]);
      ]);
    ];
  };
]
