open Types

let schemas : tool_schema list = [
  {
    name = "masc_petition_submit";
    description = "Submit a Governance V2 petition. Creates or merges a case, records requested action metadata, and files the item into the petition inbox.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("title", `Assoc [
          ("type", `String "string");
          ("description", `String "Petition title or agenda item");
        ]);
        ("origin", `Assoc [
          ("type", `String "string");
          ("description", `String "Origin tag such as human, automation, test, or harness");
        ]);
        ("subject_type", `Assoc [
          ("type", `String "string");
          ("description", `String "Subject classification such as task, operation, policy, or dispute");
        ]);
        ("risk_class", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "low"; `String "high"]);
          ("description", `String "Explicit risk classification. If omitted, the runtime derives it from the requested action.");
        ]);
        ("requested_action", `Assoc [
          ("type", `String "object");
          ("description", `String "Action metadata to execute when the case is adopted");
          ("properties", `Assoc [
            ("action_type", `Assoc [("type", `String "string")]);
            ("target_type", `Assoc [("type", `String "string")]);
            ("target_id", `Assoc [("type", `String "string")]);
            ("payload", `Assoc [("type", `String "object")]);
          ]);
        ]);
        ("source_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence or source references attached to the petition");
        ]);
      ]);
      ("required", `List [`String "title"]);
    ];
  };
  {
    name = "masc_case_brief_submit";
    description = "Add a support/oppose/neutral brief to a Governance V2 case. Brief submission can trigger a ruling and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("stance", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "support"; `String "oppose"; `String "neutral"]);
          ("description", `String "Brief stance for the case");
        ]);
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Short brief text");
        ]);
        ("evidence_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Evidence references supporting the brief");
        ]);
      ]);
      ("required", `List [`String "case_id"; `String "summary"]);
    ];
  };
  {
    name = "masc_cases";
    description = "List Governance V2 cases. Use this instead of the legacy debate/session listing tools.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("status", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional case status filter");
        ]);
        ("include_test", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include test/harness cases that are hidden by default");
        ]);
      ]);
    ];
  };
  {
    name = "masc_case_status";
    description = "Read a single Governance V2 case bundle including petitions, briefs, ruling, and execution order.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_ruling_status";
    description = "Read the latest Governance V2 ruling for a case.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
      ]);
      ("required", `List [`String "case_id"]);
    ];
  };
  {
    name = "masc_execution_orders";
    description = "List Governance V2 execution orders, inspect one case order, or confirm/deny a human gate.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("case_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Governance V2 case ID");
        ]);
        ("decision", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "confirm"; `String "deny"]);
          ("description", `String "Optional human-gate decision for a high-risk execution order");
        ]);
      ]);
    ];
  };
  {
    name = "masc_governance_status";
    description = "Get Governance V2 status (pending rulings, auto-executable cases, human-gated orders, executed cases).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_interrupt";
    description = "Pause workflow and wait for user approval (LangGraph interrupt pattern). Use before dangerous operations like database deletion, production changes, or external API calls. The workflow will be suspended until approved or rejected.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID being interrupted");
        ]);
        ("step", `Assoc [
          ("type", `String "integer");
          ("description", `String "Step number (1-based)");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "Action description (what you're about to do)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Approval request message to show user");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "step"; `String "action"; `String "message"]);
    ];
  };
  {
    name = "masc_approve";
    description = "Approve an interrupted workflow checkpoint. Use when user confirms the dangerous action should proceed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to approve");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_reject";
    description = "Reject an interrupted workflow checkpoint. Use when user declines the dangerous action.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to reject");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Rejection reason");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };
  {
    name = "masc_pending_interrupts";
    description = "List all pending interrupted workflows waiting for approval.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_branch";
    description = "Create a new execution branch from an existing checkpoint. Use for exploring alternative paths (e.g., 'try approach A here, try approach B there'). The source checkpoint is marked as 'branched' and a new checkpoint is created with the same state but a new branch name.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID containing the checkpoint");
        ]);
        ("source_step", `Assoc [
          ("type", `String "integer");
          ("description", `String "Step number of the checkpoint to branch from");
        ]);
        ("branch_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Name for the new branch (e.g., 'approach-a', 'safe-mode')");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "task_id"; `String "source_step"; `String "branch_name"]);
    ];
  };
  {
    name = "masc_cost_log";
    description = "Log token usage and cost for tracking multi-agent expenses. Call after significant API calls to track spending per agent and task.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name (claude, gemini, codex)");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model name (e.g., opus, sonnet, pro, flash)");
        ]);
        ("input_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of input tokens");
        ]);
        ("output_tokens", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of output tokens");
        ]);
        ("cost_usd", `Assoc [
          ("type", `String "number");
          ("description", `String "Estimated cost in USD");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional task ID for attribution");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "cost_usd"]);
    ];
  };
  {
    name = "masc_cost_report";
    description = "Get cost report showing token usage and spending by agent. Use to monitor multi-agent collaboration expenses.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("period", `Assoc [
          ("type", `String "string");
          ("description", `String "Time period: hourly, daily, weekly, monthly, all");
          ("default", `String "daily");
        ]);
        ("agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by agent name (optional)");
        ]);
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by task ID (optional)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_rate_limit_status";
    description = "Get your current rate limit status. Shows remaining requests per category (general, broadcast, task ops, file locks) and burst tokens.";
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
    name = "masc_rate_limit_config";
    description = "Get or update rate limit configuration (admin only). Shows limits per category and role multipliers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("per_minute", `Assoc [
          ("type", `String "integer");
          ("description", `String "Base requests per minute (default: 10)");
        ]);
        ("burst_allowed", `Assoc [
          ("type", `String "integer");
          ("description", `String "Burst tokens available (default: 5)");
        ]);
        ("broadcast_per_minute", `Assoc [
          ("type", `String "integer");
          ("description", `String "Broadcast operations per minute (default: 15)");
        ]);
        ("task_ops_per_minute", `Assoc [
          ("type", `String "integer");
          ("description", `String "Task operations per minute (default: 30)");
        ]);
      ]);
    ];
  };
  {
    name = "masc_encryption_status";
    description = "Get encryption status for this MASC room. Shows if encryption is enabled, key status, and RNG state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_encryption_enable";
    description = "Enable encryption for sensitive data in this MASC room. Requires setting MASC_ENCRYPTION_KEY environment variable (32-byte key) or providing a key file path.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("key_source", `Assoc [
          ("type", `String "string");
          ("description", `String "Key source: 'env' (from MASC_ENCRYPTION_KEY), 'file:<path>' (from file), or 'generate' (create new key)");
          ("default", `String "env");
        ]);
      ]);
    ];
  };
  {
    name = "masc_encryption_disable";
    description = "Disable encryption for this MASC room. Existing encrypted data will remain encrypted but new data will be stored in plain text.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_relay_status";
    description = "Check current context usage and relay readiness. Shows estimated token count, usage ratio, and whether relay is recommended. Call periodically to monitor context health.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of messages in conversation");
        ]);
        ("tool_calls", `Assoc [
          ("type", `String "integer");
          ("description", `String "Number of tool calls made");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Model name (claude, gemini, codex) for max context lookup");
          ("default", `String "claude");
        ]);
      ]);
    ];
  };
  {
    name = "masc_mitosis_status";
    description = "Get current agent cell status and stem pool state. Shows generation, task count, tool calls, and available reserve cells. Use to monitor lifecycle state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_handover_claim";
    description = "Claim a pending handover to continue the work. You become the successor agent. The handover DNA will be loaded into your context.";
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
    name = "masc_handover_claim_and_spawn";
    description = "Claim a handover AND automatically spawn the successor agent with the DNA. The successor agent will receive the handover context as its initial prompt and begin work immediately.";
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
  {
    name = "masc_walph_status";
    description = "Get detailed status for the current agent's Walph loop, including iterations, claimed/done counts, error counters, backoff settings, and last stop reason.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent requesting the status");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_hat_status";
    description = "Show current hat status for all agents. Displays which role each agent is currently using.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent requesting status");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };
  {
    name = "masc_gardener_status";
    description = "Get truth-only gardener loop runtime status. Returns liveness, last tick timestamps, last decision source, last action, last error, cooldown/circuit state, and the last observed health summary.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_gardener_reset_circuit";
    description = "Manually reset the circuit breaker if it's stuck open due to consecutive failures. Use with caution — only when you've addressed the root cause of the failures.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };
  {
    name = "masc_verify_status";
    description = "Check verification status by request ID.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("verification_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Verification request ID");
        ]);
      ]);
      ("required", `List [`String "verification_id"]);
    ];
  };
]
