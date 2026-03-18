(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_auth_refresh";
    description = "Refresh an expired or soon-to-expire authentication token. \
Use when your token is about to expire during a long session. \
Pair with masc_auth_status to check expiry, or masc_auth_create_token for a fresh one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Your agent name");
        ]);
        ("token", `Assoc [
          ("type", `String "string");
          ("description", `String "Your current token");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "token"]);
    ];
  };

  {
    name = "masc_auth_revoke";
    description = "Revoke an agent's authentication token (admin). \
Use when revoking access for a misbehaving or departed agent. \
The agent must call masc_auth_create_token to regain access. Pair with masc_auth_list to find targets.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent name whose token to revoke");
        ]);
      ]);
      ("required", `List [`String "agent_name"]);
    ];
  };

  {
    name = "masc_auth_list";
    description = "List all agent credentials with roles and token expiry (admin only). \
Use when auditing who has access or checking for expired tokens. \
Pair with masc_auth_revoke to clean up stale credentials.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* Rate limit tools *)
  {
    name = "masc_rate_limit_status";
    description = "Get your current rate limit status: remaining requests per category and burst tokens. \
Use when you are hitting rate limits or want to check budget before a batch operation. \
Pair with masc_rate_limit_config to adjust limits (admin).";
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
    description = "Get or update rate limit configuration (admin only). \
Use when adjusting per-minute limits, burst tokens, or role multipliers. \
Pair with masc_rate_limit_status to verify the effect of changes.";
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

  (* ============================================ *)
  (* Encryption (Data Protection)                *)
  (* ============================================ *)

  {
    name = "masc_encryption_status";
    description = "Get encryption status for this MASC room: enabled flag, key status, and RNG state. \
Use when verifying data protection is active before handling sensitive information. \
Pair with masc_encryption_enable to turn on, or masc_generate_key for a new key.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_encryption_enable";
    description = "Enable encryption for sensitive data in this MASC room. \
Use when the room will handle credentials, tokens, or private data. \
Requires MASC_ENCRYPTION_KEY env var or key_source='generate'. Pair with masc_encryption_status to verify.";
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
    description = "Disable encryption for this MASC room. Existing encrypted data stays encrypted; new data is plain text. \
Use when encryption overhead is not needed or for debugging. \
Pair with masc_encryption_status to confirm the change.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_generate_key";
    description = "Generate a random 256-bit encryption key in hex or base64 format. \
Use when setting up encryption for the first time or rotating keys. \
Store the key securely. Pair with masc_encryption_enable to apply.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("output", `Assoc [
          ("type", `String "string");
          ("description", `String "Output format: 'hex' (64 chars), 'base64' (44 chars)");
          ("default", `String "hex");
        ]);
      ]);
    ];
  };

  (* ============================================ *)
  (* Mode Management (Serena-style)              *)
  (* ============================================ *)

  {
    name = "masc_switch_mode";
    description = "Switch MASC mode to control which tool categories are visible. \
Use when you want to reduce token overhead (minimal/solo) or enable more features (parallel/full). \
Modes: minimal (~20), standard, parallel, full (~322), solo (~23), agent (~20), custom. \
Pair with masc_get_config to see current mode, masc_tool_enable for individual tools.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "minimal"; `String "standard"; `String "parallel"; `String "full"; `String "solo"; `String "custom"]);
          ("description", `String "Mode preset: minimal, standard, parallel, full, solo, or custom");
        ]);
        ("categories", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "For 'custom' mode: list of categories to enable (core, comm, portal, worktree, health, discovery, voting, interrupt, cost, auth, ratelimit, encryption)");
        ]);
      ]);
      ("required", `List [`String "mode"]);
    ];
  };

  {
    name = "masc_get_config";
    description = "Get current MASC mode configuration: enabled/disabled categories and available presets. \
Use when checking which tools are visible before requesting a mode switch. \
Pair with masc_switch_mode to change modes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* ============================================ *)
  (* Spawn - Auto-dispatch agents                 *)
  (* ============================================ *)

  {
    name = "masc_spawn";
    description = "Spawn an agent process (claude, gemini, codex, or llama) to execute a task. \
Use when you need another agent to work in parallel on a subtask. \
For llama, provide model explicitly. Pair with masc_add_task to create the task first.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to spawn: 'claude', 'gemini', 'codex', or custom command");
        ]);
        ("model", `Assoc [
          ("type", `String "string");
          ("description", `String "Explicit model id. Required when agent_name='llama'.");
        ]);
        ("prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "The task/prompt to send to the agent");
        ]);
        ("timeout_seconds", `Assoc [
          ("type", `String "integer");
          ("default", `Int 300);
          ("description", `String "Max execution time in seconds (default: 300)");
        ]);
        ("working_dir", `Assoc [
          ("type", `String "string");
          ("description", `String "Working directory for the agent (optional)");
        ]);
      ]);
      ("required", `List [`String "agent_name"; `String "prompt"]);
    ];
  };

  (* ============================================ *)
  (* Relay Tools (Infinite Context via Handoff)  *)
  (* ============================================ *)

  {
    name = "masc_relay_status";
    description = "Check current context usage and relay readiness: token count, usage ratio, and recommendation. \
Use when monitoring context health during long sessions. Call periodically. \
Pair with masc_relay_now when relay is recommended, or masc_relay_checkpoint to save state.";
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
    name = "masc_relay_checkpoint";
    description = "Save a checkpoint of current work state (summary, TODOs, relevant files) for smooth handoff. \
Use when completing a subtask or before starting a complex operation. \
Pair with masc_relay_now to trigger handoff, or masc_relay_status to check if relay is needed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Brief summary of work done so far");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Current task being worked on (optional)");
        ]);
        ("todos", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of remaining TODO items");
        ]);
        ("pdca_state", `Assoc [
          ("type", `String "string");
          ("description", `String "Current PDCA cycle state (optional)");
        ]);
        ("relevant_files", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "List of files being worked on");
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };

  {
    name = "masc_relay_now";
    description = "Trigger immediate relay to a new agent with compressed context. \
Use when context is getting full (>70%) or before a task that will overflow. \
Call masc_relay_checkpoint first to save state. The successor continues where you left off.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Summary of work for handoff");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "Task to continue (optional)");
        ]);
        ("target_agent", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent to relay to (default: claude)");
          ("default", `String "claude");
        ]);
        ("generation", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current relay generation (default: 0)");
          ("default", `Int 0);
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };

  {
    name = "masc_relay_smart_check";
    description = "Proactive relay check with task complexity hint. Predicts if the next task will overflow context. \
Use when about to start a large_file, multi_file, or long_running task. \
Returns relay recommendation before you commit. Pair with masc_relay_now if relay is advised.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current message count");
        ]);
        ("tool_calls", `Assoc [
          ("type", `String "integer");
          ("description", `String "Current tool call count");
        ]);
        ("task_hint", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "large_file"; `String "multi_file"; `String "long_running"; `String "exploration"; `String "simple"]);
          ("description", `String "Hint about upcoming task complexity");
        ]);
        ("file_count", `Assoc [
          ("type", `String "integer");
          ("description", `String "For multi_file hint: number of files");
        ]);
      ]);
      ("required", `List [`String "task_hint"]);
    ];
  };

  (* ============================================ *)
  (* Mitosis Tools (Cell Division Pattern)       *)
  (* ============================================ *)

  {
    name = "masc_mitosis_status";
    description = "Get current agent cell status: generation, task count, tool calls, and stem pool reserve. \
Use when monitoring your lifecycle state or deciding if mitosis is approaching. \
Pair with masc_mitosis_check for threshold-based recommendations.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_mitosis_all";
    description = "Get mitosis status of ALL agents in the cluster (cross-machine). \
Use when checking if any agent is under context pressure and needs handoff help. \
Pair with masc_mitosis_divide to assist an agent approaching threshold.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_mitosis_pool";
    description = "View the stem cell pool: reserve agents ready for instant handoff. \
Use when checking if warm cells are available before triggering mitosis. \
Pair with masc_mitosis_divide for manual division, or masc_memento_mori for auto-lifecycle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_mitosis_divide";
    description = "Manually trigger cell division (mitosis): parent cell dies, child inherits compressed context DNA. \
Use when you decide to hand off proactively rather than waiting for auto-threshold. \
Pair with masc_mitosis_prepare to extract DNA first, or use masc_memento_mori for auto mode.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("summary", `Assoc [
          ("type", `String "string");
          ("description", `String "Current context summary to compress into DNA");
        ]);
        ("current_task", `Assoc [
          ("type", `String "string");
          ("description", `String "The task to continue after division");
        ]);
      ]);
      ("required", `List [`String "summary"]);
    ];
  };

  {
    name = "masc_mitosis_check";
    description = "2-phase mitosis check: Phase 1 (50%) should_prepare, Phase 2 (80%) should_handoff. \
Use when periodically checking context health. Returns current phase and thresholds. \
After should_prepare: call masc_mitosis_prepare. After should_handoff: call masc_mitosis_divide.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("context_ratio", `Assoc [
          ("type", `String "number");
          ("description", `String "Current context usage ratio (0.0-1.0)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_mitosis_record";
    description = "Record an activity event (task completion or tool call) to update mitosis trigger counters. \
Use when completing a task or making a significant tool call to keep lifecycle tracking accurate. \
Pair with masc_mitosis_check to see if the counters have triggered a threshold.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_done", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Whether a task was completed");
        ]);
        ("tool_called", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Whether a tool was called");
        ]);
      ]);
    ];
  };

  {
    name = "masc_mitosis_prepare";
    description = "Phase 1: Extract DNA from current context and mark cell as ready for division. Does NOT hand off yet. \
Use when masc_mitosis_check returns should_prepare=true (context ~50%). \
Actual handoff happens at 80% via masc_mitosis_divide or masc_memento_mori.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("full_context", `Assoc [
          ("type", `String "string");
          ("description", `String "Full context to extract DNA from (will be compressed)");
        ]);
      ]);
      ("required", `List [`String "full_context"]);
    ];
  };

  (* ============================================ *)
  (* Progressive Tool Disclosure                  *)
  (* ============================================ *)

  {
    name = "masc_tool_enable";
    description = "Enable specific tools or entire categories without switching to Full mode. \
Use when you need a tool not in the current mode preset (e.g., masc_perpetual_start in Standard mode). \
Pass tool= for individual, tools= for multiple, or category= for bulk (ecosystem, discovery, code, board, etc.). \
Pair with masc_tool_disable to revert, or masc_switch_mode for wholesale changes.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tool", `Assoc [
          ("type", `String "string");
          ("description", `String "Single tool name to enable (e.g. masc_perpetual_start)");
        ]);
        ("tools", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Multiple tool names to enable at once");
        ]);
        ("category", `Assoc [
          ("type", `String "string");
          ("description", `String "Enable all tools in a category (e.g. ecosystem, discovery, code, board)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_tool_disable";
    description = "Disable previously extra-enabled tools, or clear all extra-enabled tools with clear=true. \
Use when cleaning up tools you no longer need, or resetting to the mode preset baseline. \
Pair with masc_tool_enable to re-add tools later.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("tool", `Assoc [
          ("type", `String "string");
          ("description", `String "Single tool name to disable");
        ]);
        ("tools", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Multiple tool names to disable");
        ]);
        ("clear", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Clear all extra-enabled tools");
        ]);
      ]);
    ];
  };
]
