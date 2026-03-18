open Types

let schemas : tool_schema list = [
  {
    name = "masc_a2a_discover";
    description = "Discover available A2A (Agent-to-Agent) agents and return their cards with capabilities, skills, and protocol bindings. \
Use when you need to find collaborators in the local room or at a remote endpoint before delegating work. \
Pair with masc_a2a_query_skill for detail on a specific skill, then masc_a2a_delegate to dispatch tasks.";
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
    description = "Query detailed information about an agent's specific skill, including input/output modes and usage examples. \
Use when you found an agent via masc_a2a_discover and need to understand a skill's interface before delegating. \
After reviewing the skill details, call masc_a2a_delegate to send the actual task.";
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
    description = "Delegate a task to another A2A agent by opening a portal and sending a message. Returns a task ID for tracking. \
Use when you have identified a target agent (via masc_a2a_discover or masc_route) and want to dispatch work. \
Modes: sync (wait for result), async (fire-and-forget), stream (real-time updates). Pair with masc_a2a_subscribe for async monitoring.";
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
    description = "Subscribe to SSE events from agents: task_update, broadcast, completion, or error. Returns a subscription_id for polling. \
Use when monitoring delegated tasks or observing room activity in the background. \
After subscribing, call masc_poll_events to read buffered events. Call masc_a2a_unsubscribe when done to free resources.";
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
    description = "Stop receiving events from a background A2A subscription and free server resources. \
Call when done monitoring delegated tasks, switching event types, or cleaning up before masc_leave. \
Use the subscription_id returned by masc_a2a_subscribe. Always unsubscribe when monitoring is complete.";
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
    description = "Poll and retrieve buffered events for a background subscription. Returns accumulated events and clears the buffer by default. \
Use when you have an active masc_a2a_subscribe subscription and want to check for updates between work steps. \
Workflow: masc_a2a_subscribe -> do work -> masc_poll_events -> repeat -> masc_a2a_unsubscribe.";
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
    description = "Get or set the cluster-wide tempo (pace control) for coordinated work speed. \
Use when you need to slow down for careful review work or speed up for batch processing. \
Pair with masc_tempo_get/masc_tempo_set/masc_tempo_adjust for granular orchestrator-level tempo control.";
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
    description = "Manage MCP sessions that track client context across requests. Actions: get, create, list, cleanup, remove. \
Use when debugging session state, cleaning up stale sessions, or creating a new session for a client. \
Accepts both Mcp-Session-Id and legacy X-MCP-Session-ID headers. Pair with masc_init for room-level setup.";
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
    description = "Create, cancel, check, list, or cleanup cancellation tokens for long-running operations. \
Use when you need cooperative cancellation: create a token before starting work, check it periodically, cancel it to signal abort. \
Pair with masc_progress to track and cancel long tasks. Enables graceful shutdown of spawned or delegated work.";
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
    description = "Subscribe to resource change notifications for tasks, agents, messages, or votes. Receive updates via polling or SSE. \
Use when you want to react to room state changes without repeatedly calling status tools. \
Actions: subscribe, unsubscribe, list, poll. Pair with masc_a2a_subscribe for agent-level events.";
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
    description = "Send progress notifications for long-running tasks, broadcast via SSE in MCP notifications/progress format. \
Use when executing a multi-step task and other agents or the dashboard need to see real-time progress (0.0-1.0). \
Actions: start, update, step, complete, stop. Pair with masc_cancellation to allow aborting tracked tasks.";
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
    description = "Create a structured handover record (goal, progress, decisions, warnings, pending steps) before context exhaustion or session end. \
Use when approaching context limits, timing out, or completing a session and another agent will continue. \
Pair with masc_handover_list to find pending handovers and masc_handover_get to read one before claiming work.";
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
    description = "List all handover records with optional filtering for pending (unclaimed) ones. \
Use when joining a room to see what work previous agents left behind, or to monitor incomplete handoffs. \
After finding a pending handover, call masc_handover_get for full details, then masc_claim_next to take over.";
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
    description = "Get the full details of a handover record as formatted markdown, including goal, progress, decisions, and warnings. \
Use when you found a handover via masc_handover_list and need to understand the full context before claiming the work. \
After reviewing, use masc_transition to claim the associated task and continue where the previous agent left off.";
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
    description = "Set a key-value cache entry shared across all agents in the room. Supports optional TTL and tags for filtering. \
Use when you want to share file contents, API responses, or expensive computation results with other agents. \
Pair with masc_cache_get to retrieve entries. Use masc_cache_list to browse, masc_cache_delete to invalidate.";
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
    description = "Retrieve a cached entry by key. Returns null if the key does not exist or the TTL has expired. \
Use when you need data that another agent may have cached (file contents, API responses, computation results). \
Pair with masc_cache_set to write entries and masc_cache_list to discover available keys.";
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
    description = "Delete a specific cache entry by key. No error if the key does not exist. \
Use when invalidating stale data, clearing a specific key after use, or freeing memory. \
Pair with masc_cache_list to find keys before deleting. For bulk cleanup, use masc_cache_clear instead.";
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
    description = "List all cache entries showing keys, TTL remaining, tags, and creation time. Supports filtering by tag. \
Use when browsing available cached data, debugging stale entries, or planning cleanup. \
Pair with masc_cache_get to read a specific entry, masc_cache_delete to remove one, or masc_cache_clear for full reset.";
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
    description = "Delete ALL cache entries at once. DESTRUCTIVE and cannot be undone. \
Use only when resetting room state, debugging persistent cache corruption, or starting fresh. \
Prefer masc_cache_delete for targeted removal. Check masc_cache_stats before clearing to understand impact.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_cache_stats";
    description = "Get cache usage statistics: total entries, memory size, oldest/newest entry age, and hit/miss ratio. \
Use when monitoring cache health, deciding whether to run masc_cache_clear, or debugging cache performance. \
Pair with masc_cache_list for entry-level detail or masc_cache_clear if stats indicate bloat.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_tempo_get";
    description = "Get the current orchestrator tempo (check interval in seconds) and adaptive tempo status. \
Use when you want to see how frequently the orchestrator is polling without changing it. \
Pair with masc_tempo_set to manually adjust or masc_tempo_adjust for automatic urgency-based tuning.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_tempo_set";
    description = "Manually set the orchestrator check interval in seconds (clamped to 60s-600s range). \
Use when you need a specific polling frequency for the current workload, overriding adaptive tempo. \
Pair with masc_tempo_get to check the current interval or masc_tempo_adjust for automatic tuning.";
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
    description = "Automatically adjust the orchestrator tempo based on pending task urgency. Speeds up for urgent tasks, slows down when idle. \
Call when workload has changed and you want the orchestrator to adapt without manually setting an interval. \
Pair with masc_tempo_get to verify the result, or masc_tempo_set to override with a specific value.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_dashboard";
    description = "Show the MASC dashboard with agents, tasks, and room status. Defaults to all rooms; use scope='current' for the active room only. \
Use when you need a quick overview of the cluster state, agent activity, or task progress. \
Pair with masc_observe_swarm for deeper operational metrics. Supports compact mode for single-line summary. Core_Ops category.";
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
    description = "View the Hebbian collaboration graph that tracks learned agent-to-agent relationships weighted by collaboration success. \
Use when deciding which agent to delegate to, or reviewing collaboration patterns for optimization. \
Pair with masc_consolidate_learning to decay old connections and prune weak links. Discovery category.";
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
    description = "Apply decay to old Hebbian collaboration patterns and prune weak connections, similar to memory consolidation during sleep. \
Call when the collaboration graph has accumulated stale connections (default: decay after 7 days). \
Pair with masc_collaboration_graph to view the graph before and after consolidation. Discovery category.";
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
    description = "Verify handoff context integrity by comparing original and received context for semantic drift, information loss, or distortion. \
Use when a successor agent receives context from a predecessor and wants to confirm nothing critical was lost (threshold: 0.85). \
Call after masc_relay_now or masc_mitosis_handoff completes. Pair with masc_handover_get for the original context.";
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
    description = "Get raw performance metrics for a specific agent: task completion data, timing, error rates, and collaboration history over N days. \
Use when evaluating agent reliability before delegation or reviewing an agent's track record. \
Pair with masc_audit_stats for security-focused metrics, or masc_metrics_compare for cross-generation analysis. Discovery category.";
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
    description = "Query audit logs for security events: auth success/failure, anomaly detection, violations, and tool calls. Filterable by agent and event type. \
Use when investigating suspicious agent behavior, verifying trust, or debugging collaboration issues. \
Pair with masc_audit_stats for aggregated trust metrics, or masc_governance_report for periodic governance reviews.";
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
    description = "Get aggregated security statistics and trust metrics per agent: auth success rate, anomaly count, and task completion rate. \
Use when evaluating an agent's reliability before delegating sensitive work, or during periodic trust reviews. \
Pair with masc_audit_query for raw event detail, or masc_get_metrics for performance-focused (non-security) metrics.";
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
    description = "Generate a governance summary report aggregating per-agent action counts, cost estimates, token usage, and failure rates over a time period. \
Use when conducting periodic governance reviews, tracking costs, or preparing operational reports. \
Pair with masc_audit_query for drill-down into specific events, or masc_governance_set to adjust security policies.";
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
    description = "Configure room governance policies: security level (development/production/enterprise/paranoid), audit logging, and anomaly detection. \
Use when setting up a room for production or high-security work, or when changing security posture mid-session. \
Pair with masc_governance_report to review the effect of policy changes, and masc_audit_query to inspect events.";
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
