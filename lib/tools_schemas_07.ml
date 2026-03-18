(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_heartbeat_result";
    description = "Submit heartbeat completion evidence after running an assigned heartbeat_task MCP tool loop. \
Call when a worker agent finishes its heartbeat action cycle with status (acted/skipped/failed). \
Reports tool usage and decision metadata. Pair with masc_heartbeat_start to initiate the cycle.";
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

  (* ============================================ *)
  (* Tempo Control (Pace Management)             *)
  (* ============================================ *)

  {
    name = "masc_tempo";
    description = "Read or change cluster-wide tempo (pace) in one call: get current or set normal/slow/fast/paused. \
Use when switching between careful review (slow) and batch processing (fast). \
For finer control, use masc_tempo_set (exact interval) or masc_tempo_adjust (auto-tune).";
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

  (* ============================================ *)
  (* MCP 2025-11-25 Spec Compliance Tools        *)
  (* ============================================ *)

  {
    name = "masc_mcp_session";
    description = "Create, get, list, or remove MCP sessions that track client context across requests. \
Use when managing multi-request workflows that need session continuity (Mcp-Session-Id header). \
Pair with masc_subscription to receive session-scoped event notifications.";
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
    description = "Create, cancel, or check cancellation tokens for long-running operations. \
Use when starting a long task (create token), aborting work (cancel), or polling abort status (check). \
Pair with masc_progress to track operation progress alongside cancellation state.";
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
    description = "Watch for changes on tasks, agents, messages, or votes via polling or SSE notifications. \
Use when coordinating with other agents and you need to react to state changes. \
After subscribing, poll with action=poll. Clean up with action=unsubscribe before leaving.";
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
    description = "Broadcast progress updates (start/update/step/complete/stop) for long-running tasks via SSE. \
Call when executing multi-step work so other agents and the dashboard can track progress. \
Pair with masc_cancellation to support cooperative abort during tracked operations.";
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

  (* Cellular Agent - Handover Tools *)
  {
    name = "masc_handover_create";
    description = "Write a structured handover record (goal, progress, decisions, warnings) before context limit or session end. \\nCall when approaching context capacity, hitting a timeout, or completing a task phase. \\nSuccessor claims it via masc_handover_claim or masc_handover_claim_and_spawn.";
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
    description = "List handover records, optionally filtered to pending (unclaimed) only. \
Use when starting a session to find abandoned work waiting to be continued. \
After finding a handover, call masc_handover_get for details, then masc_handover_claim to take it.";
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
    name = "masc_handover_claim";
    description = "Claim a pending handover as the successor agent, loading its DNA into your context. \
Use when you found unclaimed work via masc_handover_list and want to continue it. \
After claiming, the handover context guides your next steps. Or use masc_handover_claim_and_spawn to auto-launch.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name (the successor)");
        ]);
        ("handover_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the handover to claim");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "handover_id"]);
    ];
  };

  {
    name = "masc_handover_get";
    description = "Retrieve a handover record as formatted markdown showing goal, progress, decisions, and warnings. \
Use when reviewing a handover before deciding to claim it via masc_handover_claim. \
Pair with masc_handover_list to browse available handovers first.";
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

  (* Auto-spawn on claim *)
  {
    name = "masc_handover_claim_and_spawn";
    description = "Claim a handover and auto-spawn a successor agent that receives the DNA as its initial prompt. \
Use when you want a hands-off continuation: the new agent starts working immediately. \
Combines masc_handover_claim + masc_spawn in one step. Review with masc_handover_get first.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("handover_id", `Assoc [
          ("type", `String "string");
          ("description", `String "ID of the handover to claim");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn (claude, gemini, codex, llama). Bare 'ollama' is unsupported; use 'default' in model fields for adapter-managed selection.");
        ]);
        ("additional_instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional extra instructions for the successor agent");
        ]);
        ("timeout_seconds", `Assoc [
          ("type", `String "integer");
          ("description", `String "Timeout for the spawned agent (default: 300)");
        ]);
      ]);
      ("required", `List [`String "handover_id"; `String "agent_name"]);
    ];
  };

  (* ===== Execution Memory Tools ===== *)

  {
    name = "masc_run_init";
    description = "Create an execution memory directory (.masc/runs/{task_id}/) to track plan, logs, and deliverables. \
Call when starting work on a claimed task to enable structured progress tracking. \
After init, use masc_run_plan to set approach, masc_run_log for notes, masc_run_deliverable to close.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to track");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent working on the task");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "agent_name"]);
    ];
  };

  {
    name = "masc_run_plan";
    description = "Set or update the execution plan (markdown) for a task run; each update creates a new revision. \\nCall after masc_run_init to document your approach before starting implementation. \\nOther agents can view plans via masc_run_get for coordination and handoff context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("plan", `Assoc [
          ("type", `String "string");
          ("description", `String "The plan (markdown supported)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "plan"]);
    ];
  };

  {
    name = "masc_run_log";
    description = "Append a timestamped note (ISO8601) to a task's execution log for audit and handoff continuity. \\nCall when reaching milestones, finding blockers, or making key decisions during task execution. \\nPair with masc_run_plan for the approach and masc_run_get to review the full log.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("note", `Assoc [
          ("type", `String "string");
          ("description", `String "Note to add (will be timestamped)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "note"]);
    ];
  };

  {
    name = "masc_run_deliverable";
    description = "Record the final deliverable (markdown) and mark the task run as completed. \
Call when task implementation is finished and verified to close out the execution record. \
After recording, the run shows as completed in masc_run_list and masc_run_get.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("deliverable", `Assoc [
          ("type", `String "string");
          ("description", `String "The deliverable (markdown supported)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "deliverable"]);
    ];
  };
]
