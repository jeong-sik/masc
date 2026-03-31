(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Types

let keeper_schemas : tool_schema list = [
  {
    name = "masc_persona_list";
    description = "List available personas that have structured profile.json data. Use this before creating a keeper from a persona.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("detailed", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, return persona summaries with profile path and keeper availability. If false, return persona names only.");
        ]);
      ]);
    ];
  };

  {
    name = "masc_keeper_create_from_persona";
    description = "Create or dry-run a keeper configuration from a persona profile.json. Keepers are durable and auto-start on server boot.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("persona_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Persona handle under ME_ROOT/personas/<persona_name>/profile.json");
        ]);
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional keeper handle. Defaults to persona_name.");
        ]);
        ("dry_run", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, return the resolved keeper args and validation errors without creating the keeper.");
        ]);
        ("goal", `Assoc [("type", `String "string")]);
        ("short_goal", `Assoc [("type", `String "string")]);
        ("mid_goal", `Assoc [("type", `String "string")]);
        ("long_goal", `Assoc [("type", `String "string")]);
        ("instructions", `Assoc [("type", `String "string")]);
        ("soul_profile", `Assoc [("type", `String "string")]);
        ("will", `Assoc [("type", `String "string")]);
        ("needs", `Assoc [("type", `String "string")]);
        ("desires", `Assoc [("type", `String "string")]);
        ("room_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "current"; `String "all"]);
        ]);
        ("scope_kind", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "local"; `String "global"]);
        ]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("proactive_enabled", `Assoc [("type", `String "boolean")]);
        ("auto_handoff", `Assoc [("type", `String "boolean")]);
        ("handoff_threshold", `Assoc [("type", `String "number")]);
        ("handoff_cooldown_sec", `Assoc [("type", `String "integer")]);
        ("execution_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "observe_only"; `String "workspace"; `String "local"]);
        ]);
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
      ]);
      ("required", `List [`String "persona_name"]);
    ];
  };

  {
    name = "masc_keeper_up";
    description = "Create or update a durable keeper. Keepers auto-start on server boot and are reconciled back into live presence.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle (stable). Example: 'keeper-helper'");
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
        ("scope_kind", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "local"; `String "global"]);
          ("description", `String "Keeper presence scope. 'global' enables room-aware roaming state.");
        ]);
        ("room_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "current"; `String "all"]);
          ("description", `String "Which rooms the keeper should maintain presence in.");
        ]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Exact direct-mention tokens that can wake the keeper in room traffic (for example ['sangsu']).");
        ]);
        ("proactive_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, keeper can send proactive check-ins after idle periods. Defaults to false unless explicitly enabled.");
        ]);
        ("proactive_idle_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Idle seconds before proactive check-in is allowed (default: 900).");
        ]);
        ("proactive_cooldown_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum seconds between proactive check-ins (default: 1800).");
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
        ("execution_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "observe_only"; `String "workspace"; `String "local"]);
          ("description", `String "Execution scope: observe_only (read-only), workspace (write to allowed paths), local (full access). Default: workspace.");
        ]);
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Restrict file writes to these path prefixes. Empty list uses computed defaults based on execution_scope. Use [\"*\"] for explicit full access.");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_status";
    description = "Get keeper status (keepalive/live/reconcile state plus current context and monitoring tails).";
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
    description = "Send a message to an existing keeper and get a reply. Use masc_keeper_up for keeper creation or persisted updates.";
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
        ("timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Optional: overall cascade timeout (sec) for this keeper message call");
        ]);
        ("no_skill_route", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: do not emit SKILL/SKILL_REASON headers in reply");
        ]);
        ("no_state_block", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: do not emit [STATE]...[/STATE] block in reply");
        ]);
      ]);
      ("required", `List [`String "name"; `String "message"]);
    ];
  };

  {
    name = "masc_keeper_repair";
    description = "Run a keeper-facing detachable repair loop for OCaml code and return the terminal state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("task_spec", `Assoc [
          ("type", `String "string");
          ("description", `String "Exact OCaml task specification or signature requirement.");
        ]);
        ("source_text", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional initial OCaml code to validate and repair.");
        ]);
        ("target_mode", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "snippet"; `String "repo"]);
        ]);
        ("working_dir", `Assoc [ ("type", `String "string") ]);
        ("target_file", `Assoc [ ("type", `String "string") ]);
        ("plugin_id", `Assoc [ ("type", `String "string") ]);
        ("validator_profile", `Assoc [ ("type", `String "string") ]);
        ("model_label", `Assoc [ ("type", `String "string") ]);
        ("max_attempts", `Assoc [ ("type", `String "integer") ]);
      ]);
      ("required", `List [`String "name"; `String "task_spec"]);
    ];
  };

  {
    name = "masc_keeper_down";
    description = "Stop a keeper. Optionally remove underlying files.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("remove_meta", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Delete .masc/keepers/<name>.json (default: false). Set true only for permanent removal.");
        ]);
        ("remove_session", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Delete .masc/traces/<trace_id>/ directory (default: false).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_list";
    description = "List known keepers from persisted keeper metadata.";
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

  {
    name = "masc_keeper_add_loop";
    description = "Register a recurring broadcast task on a keeper. The keeper dispatches it automatically on each heartbeat cycle when the interval has elapsed.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("keeper_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Target keeper handle");
        ]);
        ("label", `Assoc [
          ("type", `String "string");
          ("description", `String "Short label for this recurring task");
        ]);
        ("interval_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Seconds between dispatches (minimum 10)");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Broadcast message content");
        ]);
        ("max_failures", `Assoc [
          ("type", `String "integer");
          ("description", `String "Auto-disable after this many consecutive failures (default 5)");
        ]);
      ]);
      ("required", `List [
        `String "keeper_name"; `String "label";
        `String "interval_sec"; `String "message"
      ]);
    ];
  };

  {
    name = "masc_keeper_list_loops";
    description = "List recurring tasks registered on a keeper.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("keeper_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle (omit for all keepers)");
        ]);
      ]);
    ];
  };

  {
    name = "masc_keeper_remove_loop";
    description = "Remove a recurring task by its ID.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("id", `Assoc [
          ("type", `String "string");
          ("description", `String "Recurring task ID (from add_loop or list_loops)");
        ]);
      ]);
      ("required", `List [`String "id"]);
    ];
  };
]

let housekeep_schemas : tool_schema list = [
  {
    name = "masc_housekeep_scan";
    description = "Scan .masc/ directory and list all files with size, age, and category. Use to observe the state of your world before deciding what to clean.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("category", `Assoc [
          ("type", `String "string");
          ("description", `String "Filter by category: keeper_meta, keeper_metrics_single_file, keeper_memory, keeper_feedback, jsonl_data, dated_split, events, other. Omit for all.");
        ]);
        ("min_age_days", `Assoc [
          ("type", `String "number");
          ("description", `String "Only show files older than this many days. Default: 0 (all).");
        ]);
      ]);
    ];
  };
  {
    name = "masc_housekeep_delete";
    description = "Delete a specific file under .masc/. Logs the deletion with timestamp and reason. Only deletes files, not directories.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Absolute path to the file to delete. Must be under .masc/.");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Why this file is being deleted (logged for audit trail).");
        ]);
      ]);
      ("required", `List [`String "path"; `String "reason"]);
    ];
  };
  {
    name = "masc_housekeep_prune";
    description = "Prune old entries from a date-split JSONL store. Removes day-files older than the specified number of days.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("store", `Assoc [
          ("type", `String "string");
          ("description", `String "Store to prune: 'audit', 'telemetry', or 'keeper:<name>' (e.g. 'keeper:dm-keeper').");
        ]);
        ("days", `Assoc [
          ("type", `String "integer");
          ("description", `String "Delete entries older than this many days. Default: 30.");
        ]);
      ]);
      ("required", `List [`String "store"]);
    ];
  };
]

let schemas : tool_schema list =
  keeper_schemas @ housekeep_schemas
