(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Types

let string_array_schema =
  `Assoc [
    ("type", `String "array");
    ("items", `Assoc [ ("type", `String "string") ]);
  ]

let tool_access_schema description =
  let preset_shape =
    `Assoc [
      ("type", `String "object");
      ("description", `String "Preset-based tool policy.");
      ("properties", `Assoc [
        ("kind", `Assoc [ ("const", `String "preset") ]);
        ("preset", `Assoc [
          ("type", `String "string");
          ("enum",
            `List
              [ `String "minimal"; `String "social"; `String "messaging"; `String "coding";
                `String "research"; `String "delivery"; `String "full" ]);
        ]);
        ("also_allow", string_array_schema);
      ]);
      ("required", `List [ `String "kind"; `String "preset" ]);
      ("additionalProperties", `Bool false);
    ]
  in
  let custom_shape =
    `Assoc [
      ("type", `String "object");
      ("description", `String "Custom tool allowlist policy.");
      ("properties", `Assoc [
        ("kind", `Assoc [ ("const", `String "custom") ]);
        ("tools", string_array_schema);
      ]);
      ("required", `List [ `String "kind"; `String "tools" ]);
      ("additionalProperties", `Bool false);
    ]
  in
  `Assoc [
    ("type", `String "object");
    ("description", `String description);
    ("oneOf", `List [ preset_shape; custom_shape ]);
  ]

let keeper_schemas : tool_schema list = [
  {
    name = "masc_persona_list";
    description = "List available persona profiles that can be used to create keepers via masc_keeper_create_from_persona.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("detailed", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool true);
          ("description", `String "If true, return full persona summaries. If false, return names only.");
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
          ("description", `String "Persona handle resolved from MASC_PERSONAS_DIR or the resolved config root personas/<persona_name>/profile.json");
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
        ("will", `Assoc [("type", `String "string")]);
        ("needs", `Assoc [("type", `String "string")]);
        ("desires", `Assoc [("type", `String "string")]);
        ("room_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "current"]);
          ("description", `String "Single-room compatibility field. Keepers always attach to the current/default namespace.");
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
        ("tool_access",
          tool_access_schema
            "Canonical tool policy. Prefer this over tool_preset/tool_also_allow. Example preset: {kind: 'preset', preset: 'research', also_allow: ['masc_status']}. Example custom: {kind: 'custom', tools: ['masc_status']}.");
        ("tool_preset", `Assoc [
          ("type", `String "string");
          ("description", `String "Compatibility field. Use tool_access.kind='preset' for new callers.");
          ("enum", `List [`String "minimal"; `String "messaging"; `String "coding"; `String "research"; `String "full"]);
        ]);
        ("tool_custom_allowlist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Compatibility field for custom allowlists. Use tool_access.kind='custom' for new callers.");
        ]);
        ("tool_also_allow", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Compatibility field. Adds tools on top of tool_preset.");
        ]);
        ("tool_denylist", `Assoc [
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
          ("description", `String "Keeper message/board visibility scope inside the single default namespace.");
        ]);
        ("room_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "current"]);
          ("description", `String "Single-room compatibility field. Keepers always maintain presence in the current/default namespace.");
        ]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Exact direct-mention tokens that can wake the keeper in room traffic (for example ['sangsu']).");
        ]);
        ("max_context_override", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional: absolute context token limit override for this keeper. Use to bypass global or discovered limits.");
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
        ("tool_access",
          tool_access_schema
            "Canonical tool policy. Prefer this over tool_preset/tool_also_allow. Example preset: {kind: 'preset', preset: 'research', also_allow: ['masc_status']}. Example custom: {kind: 'custom', tools: ['masc_status']}.");
        ("tool_preset", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "minimal"; `String "messaging"; `String "coding"; `String "research"; `String "full"]);
          ("description", `String "Compatibility field. Use tool_access.kind='preset' for new callers.");
        ]);
        ("tool_custom_allowlist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Compatibility field for custom allowlists. Use tool_access.kind='custom' for new callers.");
        ]);
        ("tool_also_allow", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Compatibility field. Adds tools on top of tool_preset.");
        ]);
        ("tool_denylist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Tool names to remove after preset resolution.");
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
          ("description", `String "Keeper handle. Optional; defaults to the caller when omitted.");
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
    ];
  };

  {
    name = "masc_keeper_msg";
    description = "Send a message to a keeper (async). Returns immediately with a request_id. Poll masc_keeper_msg_result for the response.";
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
    name = "masc_keeper_msg_result";
    description = "Poll the result of an async keeper_msg request. Returns status (queued/running/done/error) and the result when complete.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("request_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Request ID returned by masc_keeper_msg");
        ]);
      ]);
      ("required", `List [`String "request_id"]);
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
    name = "masc_keeper_reconcile";
    description = "Inspect or clear a keeper manual-reconcile blocker. Use inspect to review the persisted blocker record, then clear with operator evidence once the committed side effects have been reconciled.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("action", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "inspect"; `String "clear"]);
          ("description", `String "inspect returns the persisted blocker record. clear marks it cleared and re-enables keepalive turns.");
        ]);
        ("resolution", `Assoc [
          ("type", `String "string");
          ("description", `String "Required for clear. Operator summary of how the ambiguous side effects were reconciled.");
        ]);
        ("evidence_refs", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional evidence references (task ids, board posts, logs, notes) that justify the clear.");
        ]);
        ("actor", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional operator identity. Defaults to the calling agent_name.");
        ]);
        ("idempotency_key", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional idempotency key for repeated clear requests.");
        ]);
      ]);
      ("required", `List [`String "name"; `String "action"]);
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
    name = "masc_keeper_reset";
    description = "Reset a keeper's runtime state (usage counters, last_model_used, token stats). \
Clears stale data from previous sessions. Does not affect configuration, goals, or persona.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle to reset");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

]

let schemas : tool_schema list =
  keeper_schemas
