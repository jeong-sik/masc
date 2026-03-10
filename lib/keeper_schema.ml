(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Types

let schemas : tool_schema list = [
  {
    name = "masc_keeper_up";
    description = "Create or update a persistent keeper agent (event-driven). \
Stores context on disk and keeps presence alive. Auto-handoff is enabled by default.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle (stable). Example: 'lodge-helper'");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper goal/system purpose (required when creating)");
        ]);
        ("short_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: short-term goal horizon (default: goal).");
        ]);
        ("mid_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: mid-term goal horizon (default: goal).");
        ]);
        ("long_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: long-term goal horizon (default: goal).");
        ]);
        ("instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: additional system instructions (kept across compaction/handoff).");
        ]);
        ("soul_profile", `Assoc [
          ("type", `String "string");
          ("description", `String "Memory priority preset. One of: balanced, safety, delivery, research, relationship, minimal.");
        ]);
        ("will", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: keeper's long-term will (의지).");
        ]);
        ("needs", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: keeper's operational needs (니즈).");
        ]);
        ("desires", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: keeper's desire/drive statement (욕구).");
        ]);
        ("models", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Model cascade (provider:model). Examples: 'claude:opus', 'gemini:gemini-3.1-pro-preview', 'glm:glm-4.7', 'openrouter:openai/gpt-4o-mini'.");
        ]);
        ("verify", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable verifier model feedback (default: false for keeper).");
        ]);
        ("presence_keepalive", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, periodically refresh Room.heartbeat for the keeper agent (default: true).");
        ]);
        ("presence_keepalive_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Presence keepalive interval seconds (default: 30).");
        ]);
        ("proactive_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, keeper can send proactive check-ins after idle periods (default: true).");
        ]);
        ("proactive_idle_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Idle seconds before proactive check-in is allowed (default: 900).");
        ]);
        ("proactive_cooldown_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum seconds between proactive check-ins (default: 1800).");
        ]);
        ("drift_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, keeper self-model (will/needs/desires) can drift from conversation signals (default: true).");
        ]);
        ("drift_min_turn_gap", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum keeper turns between automatic drift updates (default: 6).");
        ]);
        ("compaction_profile", `Assoc [
          ("type", `String "string");
          ("description", `String "Compaction preset. One of: aggressive, balanced, conservative, custom.");
        ]);
        ("compaction_ratio_gate", `Assoc [
          ("type", `String "number");
          ("description", `String "Context ratio gate for compaction (0.1-0.98). Overrides preset when set.");
        ]);
        ("compaction_message_gate", `Assoc [
          ("type", `String "integer");
          ("description", `String "Message count gate for compaction (0 disables this gate). Overrides preset when set.");
        ]);
        ("compaction_token_gate", `Assoc [
          ("type", `String "integer");
          ("description", `String "Token count gate for compaction (0 disables this gate). Overrides preset when set.");
        ]);
        ("continuity_compaction_cooldown_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum seconds to wait after a [STATE] continuity update before compaction. 0 disables the reflection hold.");
        ]);
        ("auto_handoff", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, automatically rotate trace_id when context gets large (default: true).");
        ]);
        ("handoff_threshold", `Assoc [
          ("type", `String "number");
          ("description", `String "Context ratio threshold for auto-handoff (default: 0.85).");
        ]);
        ("handoff_cooldown_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum seconds between handoffs (default: 300).");
        ]);
        ("context_budget", `Assoc [
          ("type", `String "number");
          ("description", `String "How much compressed context to transfer to successor (0.0-1.0, default: 0.6).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_status";
    description = "Get keeper status (meta + current context stats + monitoring tails).";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("tail_turns", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many recent turns to include from keeper metrics (default: 3).");
        ]);
        ("tail_messages", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many recent history messages to include (default: 5).");
        ]);
        ("tail_compactions", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many recent compaction events to include (default: 10).");
        ]);
        ("tail_bytes", `Assoc [
          ("type", `String "integer");
          ("description", `String "How many bytes from the end of files to scan for tails (default: 60000).");
        ]);
        ("fast", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable fast mode (skip heavy sections unless explicitly enabled).");
        ]);
        ("include_context", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include checkpoint-derived context stats (default: !fast).");
        ]);
        ("include_metrics_overview", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include metrics overview + skill route scan (default: !fast).");
        ]);
        ("include_memory_bank", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include memory bank summary (default: !fast).");
        ]);
        ("include_history_tail", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include recent history tail + fragment counters (default: !fast).");
        ]);
        ("include_compaction_history", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include recent compaction history tail (default: !fast).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_msg";
    description = "Send a message to a keeper and get a reply. \
Persists context + checkpoints. Auto-handoff is applied when needed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "User message");
        ]);
        ("goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set goal when creating keeper inline");
        ]);
        ("short_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set short-term goal horizon when creating keeper inline");
        ]);
        ("mid_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set mid-term goal horizon when creating keeper inline");
        ]);
        ("long_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set long-term goal horizon when creating keeper inline");
        ]);
        ("instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set instructions when creating keeper inline");
        ]);
        ("soul_profile", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set memory priority preset when creating keeper inline");
        ]);
        ("will", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set keeper will (의지) when creating keeper inline");
        ]);
        ("needs", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set keeper needs (니즈) when creating keeper inline");
        ]);
        ("desires", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: set keeper desires (욕구) when creating keeper inline");
        ]);
        ("drift_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: enable/disable self-model drift when creating keeper inline");
        ]);
        ("drift_min_turn_gap", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional: min turn gap for drift updates when creating keeper inline");
        ]);
        ("models", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional: set models when creating keeper inline. If keeper already exists, this acts as a runtime-only cascade override for this message call.");
        ]);
        ("timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Optional: overall cascade timeout (sec) for this keeper message call");
        ]);
        ("ollama_timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Optional: override Ollama timeout (sec) for this keeper message call");
        ]);
        ("no_skill_route", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: do not emit SKILL/SKILL_REASON headers in reply");
        ]);
        ("no_state_block", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: do not emit [STATE]...[/STATE] block in reply");
        ]);
        ("require_existing", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: fail if keeper does not already exist");
        ]);
        ("new_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper goal (persisted)");
        ]);
        ("new_short_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper short-term goal horizon (persisted)");
        ]);
        ("new_mid_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper mid-term goal horizon (persisted)");
        ]);
        ("new_long_goal", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper long-term goal horizon (persisted)");
        ]);
        ("new_instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper instructions (persisted)");
        ]);
        ("new_soul_profile", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper memory priority preset (persisted)");
        ]);
        ("new_will", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper will (persisted)");
        ]);
        ("new_needs", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper needs (persisted)");
        ]);
        ("new_desires", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: replace keeper desires (persisted)");
        ]);
        ("new_drift_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: replace drift enabled flag (persisted)");
        ]);
        ("new_drift_min_turn_gap", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional: replace drift min turn gap (persisted)");
        ]);
      ]);
      ("required", `List [`String "name"; `String "message"]);
    ];
  };

  {
    name = "masc_keeper_down";
    description = "Stop keeper presence keepalive and optionally remove keeper files.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("remove_meta", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Delete .masc/perpetual-keepers/<name>.json (default: false). Set true only for permanent removal.");
        ]);
        ("remove_session", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Delete .masc/perpetual/<trace_id>/ directory (default: false).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_list";
    description = "List keepers from .masc/perpetual-keepers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max keepers to return (default: 50).");
        ]);
        ("detailed", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Return keeper summaries (model/context/handoff/compaction) instead of names only.");
        ]);
      ]);
    ];
  };

  (* --- Phase 4: Keeper Autonomy MCP Tools --- *)

  {
    name = "masc_keeper_autonomy";
    description = "Query or change a keeper's autonomy level (L1_Reactive..L5_Independent). Without 'level', returns current autonomy info.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("level", `Assoc [
          ("type", `String "string");
          ("description", `String "New autonomy level: L1_Reactive, L2_Suggestive, L3_Guided, L4_Autonomous, L5_Independent");
          ("enum", `List [
            `String "L1_Reactive"; `String "L2_Suggestive"; `String "L3_Guided";
            `String "L4_Autonomous"; `String "L5_Independent";
          ]);
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_goals";
    description = "Link, unlink, or list goals for a keeper. Without action, lists the keeper's active goals.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("description", `String "link | unlink (omit to list)");
          ("enum", `List [`String "link"; `String "unlink"]);
        ]);
        ("goal_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Goal ID to link or unlink");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_trajectory";
    description = "View recent trajectory entries (tool calls) for a keeper session.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description", `String "Max entries to return (default: 20, most recent first).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_eval";
    description = "Run eval harness against a keeper's trajectory. Returns quality scores.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("scenario_file", `Assoc [
          ("type", `String "string");
          ("description", `String "Path to scenario JSONL file (optional, uses keeper trajectory if omitted).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };
]
