(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Types

(** Issue #8430: canonical [tool_preset] strings. Mirrors
    [Keeper_types.valid_tool_preset_strings]. Direct dependency would
    create a cycle (Keeper_schema -> Keeper_types -> Keeper_types_profile
    -> Keeper_schema), so the test in [test_types.ml :: tool_preset_ssot]
    asserts these two lists stay in sync. *)
let tool_preset_enum_strings =
  [ "minimal"; "social"; "messaging"; "coding"; "research"; "delivery"; "full" ]

(** Issue #8467: canonical strings for [Keeper_types_profile.sandbox_profile],
    [network_mode], and [shared_memory_scope]. Same cycle constraint as
    [tool_preset_enum_strings] above — Keeper_schema cannot depend on
    Keeper_types_profile directly because the latter [include]s
    Keeper_config and is otherwise downstream. The test
    [test_types.ml :: keeper_profile_enum_ssot] asserts these mirrors
    stay in sync with [valid_*_strings] so adding a constructor in
    Keeper_types_profile fails the test instead of silently dropping
    from the JSON Schema. *)
let sandbox_profile_enum_strings =
  [ "legacy_local"; "docker_hardened"; "docker_with_git" ]
let network_mode_enum_strings =
  [ "none"; "inherit" ]
let shared_memory_scope_enum_strings =
  [ "disabled"; "room" ]

(** Issue #8486: hand-mirrored from
    [Keeper_status_detail.valid_tail_order_strings].  Same cycle
    constraint — Keeper_schema is upstream of Keeper_status_detail.
    The test [test_types.ml :: tail_order_ssot] asserts this mirror
    stays in sync with the SSOT so adding a 3rd ordering constructor
    fails compilation in [tail_order_to_string] AND fails the test
    here, instead of silently dropping from the JSON Schema. *)
let tail_order_enum_strings =
  [ "oldest_first"; "newest_first" ]

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
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("autoboot_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If false, persist the keeper but skip auto-start on future server boots.");
        ]);
        ("proactive_enabled", `Assoc [("type", `String "boolean")]);
        ("auto_handoff", `Assoc [("type", `String "boolean")]);
        ("handoff_threshold", `Assoc [("type", `String "number")]);
        ("handoff_cooldown_sec", `Assoc [("type", `String "integer")]);
        ("execution_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List (Keeper_execution_scope.all |> List.map (fun s -> `String (Keeper_execution_scope.to_string s))));
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
          (* Issue #8430: mirrors [Keeper_types.valid_tool_preset_strings].
             Direct dependency would create a cycle
             (Keeper_schema -> Keeper_types -> Keeper_types_profile ->
             Keeper_schema). Test [test_types.ml :: tool_preset_ssot]
             asserts the two stay in sync — if either side adds a value
             the other diverges. Used to drop Social and Delivery. *)
          ("enum", `List (List.map (fun s -> `String s) tool_preset_enum_strings));
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
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Exact direct-mention tokens that can wake the keeper in room traffic (for example ['sangsu']).");
        ]);
        ("autoboot_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If false, persist the keeper but skip auto-start on future server boots.");
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
          ("enum", `List (Keeper_execution_scope.all |> List.map (fun s -> `String (Keeper_execution_scope.to_string s))));
          ("description", `String "Execution scope. 'observe_only' blocks all writes. 'workspace'/'local' enable writes within playground (.masc/playground/<name>/). Extra paths must be listed explicitly in allowed_paths. Default: workspace.");
        ]);
        ("sandbox_profile", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) sandbox_profile_enum_strings));
          ("description", `String "Filesystem/process sandbox profile. 'legacy_local' keeps the current local execution model. 'docker_hardened' runs keeper_bash in an ephemeral hardened Docker container rooted at the keeper playground.");
        ]);
        ("network_mode", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) network_mode_enum_strings));
          ("description", `String "Network policy associated with the sandbox profile. 'none' is valid only with sandbox_profile='docker_hardened'.");
        ]);
        ("shared_memory_scope", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) shared_memory_scope_enum_strings));
          ("description", `String "Typed shared-memory lane policy. 'room' enables keeper-authorized masc_team_memory_* access on the flattened default namespace.");
        ]);
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Restrict file writes to these path prefixes. Empty list means playground-only (.masc/playground/<name>/). Use [\"*\"] for explicit full access.");
        ]);
        ("tool_access",
          tool_access_schema
            "Canonical tool policy. Prefer this over tool_preset/tool_also_allow. Example preset: {kind: 'preset', preset: 'research', also_allow: ['masc_status']}. Example custom: {kind: 'custom', tools: ['masc_status']}.");
        ("tool_preset", `Assoc [
          ("type", `String "string");
          (* Issue #8430: mirrors [Keeper_types.valid_tool_preset_strings].
             Direct dependency would create a cycle
             (Keeper_schema -> Keeper_types -> Keeper_types_profile ->
             Keeper_schema). Test [test_types.ml :: tool_preset_ssot]
             asserts the two stay in sync — if either side adds a value
             the other diverges. Used to drop Social and Delivery. *)
          ("enum", `List (List.map (fun s -> `String s) tool_preset_enum_strings));
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
        ("tail_order", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) tail_order_enum_strings));
          ("description", `String "Ordering for metrics/history/compaction tails and recent memory notes. Default: oldest_first (compat).");
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

  (* masc_keeper_reconcile removed with manual_reconcile blocker system. *)

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

  {
    name = "masc_keeper_compact";
    description = "Trigger operator-initiated context compaction for a keeper. \
Compacts the keeper's checkpoint to reduce context size. \
Default precondition: keeper phase is Overflowed, Paused, or Compacting. \
Pass force=true to allow compaction on Running or Failing keepers. \
Terminal/transient phases (Offline, Stopped, Dead, Crashed, Restarting, \
HandingOff, Draining) are always rejected.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("force", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Bypass default precondition to allow compaction on Running or Failing keepers. Has no effect on terminal/transient phases.");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_clear";
    description = "Last-resort context clear for a keeper. \
Wipes user/assistant/tool messages from the checkpoint; keeps the system prompt \
by default (preserve_system_prompt=true). Set preserve_system_prompt=false to \
drop the system prompt too. Dispatches Operator_clear_requested to the keeper \
FSM, which resets context_overflow and compact_retry_exhausted. \
Use only when compaction is insufficient and the keeper cannot recover otherwise. \
Requires a reason for the audit trail.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
        ]);
        ("preserve_system_prompt", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Keep the system prompt in the cleared context. Defaults to true.");
        ]);
        ("reason", `Assoc [
          ("type", `String "string");
          ("description", `String "Required. Operator explanation for why the context is being cleared (audit trail).");
        ]);
      ]);
      ("required", `List [`String "name"; `String "reason"]);
    ];
  };

]

let schemas : tool_schema list =
  keeper_schemas
