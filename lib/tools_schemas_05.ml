(** Split chunk from tools.ml; private schema registry. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_auth_refresh";
    description = "Refresh an expired or soon-to-expire token. Returns a new token.";
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
    description = "Revoke an agent's token. The agent will need a new token to perform authenticated actions.";
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
    description = "List all agent credentials (admin only). Shows agent names, roles, and token expiry times.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  (* Rate limit tools *)
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

  (* ============================================ *)
  (* Encryption (Data Protection)                *)
  (* ============================================ *)

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
    name = "masc_generate_key";
    description = "Generate a new random 256-bit encryption key. Returns the key in hex format. Store this securely - losing the key means losing access to encrypted data.";
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
    description = "Switch MASC mode to reduce token usage. Available modes: 'minimal' (core+health), 'standard' (core+comm+worktree+health), 'parallel' (multi-agent heavy: comm+portal+discovery+voting+interrupt), 'full' (all features), 'solo' (single-agent: core+worktree). Use 'custom' with categories parameter for fine-grained control.";
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
    description = "Get current MASC mode configuration. Shows enabled categories, disabled categories, and available mode presets.";
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
    description = "Spawn an agent to execute a task. Use this to orchestrate multi-agent collaboration without manual terminal setup. When agent_name='llama', you must provide model explicitly.";
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
    name = "masc_relay_checkpoint";
    description = "Save a checkpoint of current state for smooth handoff. Call at key moments (after completing subtasks, before complex operations). Checkpoints enable proactive relay with minimal context loss.";
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
    description = "Trigger immediate relay to a new agent. Use when context is getting full or before a complex task. The new agent will receive compressed context and continue seamlessly.";
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
    description = "Proactive relay check with task hint. Predicts if upcoming task will overflow context and suggests relay BEFORE starting the task. Key for smooth transitions.";
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
    description = "Get current agent cell status and stem pool state. Shows generation, task count, tool calls, and available reserve cells. Use to monitor lifecycle state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_mitosis_all";
    description = "Get mitosis status of ALL agents in the cluster (cross-machine). Shows each agent's context pressure so you can see if another agent needs handoff help. Use for collaboration awareness.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_mitosis_pool";
    description = "View the stem cell pool - reserve agents ready for instant handoff. Shows warm cells, their generation, and readiness state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

  {
    name = "masc_mitosis_divide";
    description = "Manually trigger cell division (mitosis). Parent cell dies gracefully (apoptosis) while child cell inherits compressed DNA (context). Use for proactive handoff.";
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
    description = "2-Phase mitosis check. Phase 1 (50%): should_prepare=true → extract DNA. Phase 2 (80%): should_handoff=true → execute handoff. Returns current phase and thresholds.";
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
    description = "Record activity for mitosis trigger tracking. Call after completing tasks or tool calls to update counters.";
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
    description = "Phase 1: Prepare for division - extract DNA and mark cell as ready. Does NOT handoff yet. Call this at 50% context to prepare early, actual handoff happens at 80%.";
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
    description = "Enable specific tools or categories without switching to Full mode. Use when you need a tool not in the current mode. Categories: ecosystem (perpetual, gardener, keeper, mdal, handover, library), discovery (capabilities, agent_card, fitness), code (code_search, code_symbols, code_read), board (post, comment, vote), portal, worktree, consensus (debate, convo, walph), voting, encryption, auth, cost. Pass category= for bulk enable or tool= for individual.";
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
    description = "Disable previously extra-enabled tools, or clear all extra-enabled tools with clear=true.";
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
