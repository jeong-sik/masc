(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Masc_domain
module Persona_contract = Keeper_persona_authoring_contract

(** Issue #8430: canonical [tool_preset] strings. Mirrors
    [Keeper_types.valid_tool_preset_strings]. Direct dependency would
    create a cycle (Keeper_schema -> Keeper_types -> Keeper_types_profile
    -> Keeper_schema), so the test in [test_types.ml :: tool_preset_ssot]
    asserts these two lists stay in sync. *)
let tool_preset_enum_strings =
  [ "minimal"; "social"; "messaging"; "dispatch"; "coding"; "research"; "delivery"; "full" ]

(** Issue #8467: canonical strings for [Keeper_types_profile.sandbox_profile],
    [network_mode], . Same cycle constraint as
    [tool_preset_enum_strings] above — Keeper_schema cannot depend on
    Keeper_types_profile directly because the latter [include]s
    Keeper_config and is otherwise downstream. The test
    [test_types.ml :: keeper_profile_enum_ssot] asserts these mirrors
    stay in sync with [valid_*_strings] so adding a constructor in
    Keeper_types_profile fails the test instead of silently dropping
    from the JSON Schema. *)
let sandbox_profile_enum_strings =
  [ "local"; "docker" ]
let network_mode_enum_strings =
  [ "none"; "inherit" ]
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

let persona_axis_schema (axis : Persona_contract.archetype_axis) =
  `Assoc
    [ "type", `String "string"
    ; "enum", Persona_contract.string_list_to_json axis.choices
    ; "description", `String axis.schema_description
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
            `List (List.map (fun s -> `String s) tool_preset_enum_strings));
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
    name = "masc_persona_schema";
    description = "Explain persona profile.json fields, allowed values, and how each field affects persona-backed keeper creation.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("include_examples", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "If true, include a minimal profile.json example.");
        ]);
      ]);
    ];
  };
  {
    name = "masc_persona_generate";
    description = "Draft a persona profile.json from a natural-language concept. This does not write files; use masc_persona_schema for field and archetype choice effects, then masc_persona_save to persist it.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("concept", `Assoc [
          ("type", `String "string");
          ("description", `String "Freeform character/operator concept, e.g. 'good evil chaos research keeper'.");
        ]);
        ("handle", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional stable persona handle. Must match [A-Za-z0-9._-]+.");
        ]);
        ("display_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional display label for the persona.");
        ]);
        ("language", `Assoc [
          ("type", `String "string");
          ("default", `String Persona_contract.default_generation_language);
          ("description", `String "Preferred language for generated text.");
        ]);
        ("alignment", persona_axis_schema Persona_contract.alignment_axis);
        ("risk_posture", persona_axis_schema Persona_contract.risk_posture_axis);
        ("proactive_enabled", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool Persona_contract.default_proactive_enabled);
          ("description", `String "Default keeper.proactive_enabled for the draft.");
        ]);
        ("cascade_name", `Assoc [
          ("type", `String "string");
          ("default", `String Persona_contract.default_generation_cascade_name);
          ("description", `String "Named cascade used to draft the persona.");
        ]);
        ("temperature", `Assoc [
          ("type", `String "number");
          ("default", `Float Persona_contract.default_temperature);
        ]);
        ("max_tokens", `Assoc [
          ("type", `String "integer");
          ("default", `Int Persona_contract.default_max_tokens);
        ]);
      ]);
      ("required", `List [`String "concept"]);
    ];
  };
  {
    name = "masc_persona_save";
    description = "Validate and atomically write a generated persona profile.json under the resolved personas root.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("handle", `Assoc [
          ("type", `String "string");
          ("description", `String "Persona handle and directory name. Must match [A-Za-z0-9._-]+.");
        ]);
        ("profile", `Assoc [
          ("type", `String "object");
          ("description", `String "Persona profile.json object to validate and save.");
        ]);
        ("overwrite", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "If false, reject when the persona already exists.");
        ]);
        ("dry_run", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "If true, validate and return the target path without writing.");
        ]);
      ]);
      ("required", `List [`String "handle"; `String "profile"]);
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
        ("active_goal_ids", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Goal IDs this keeper is allowed to claim work for. Empty clears goal scoping.");
        ]);
        ("autoboot_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If false, persist the keeper but skip auto-start on future server boots.");
        ]);
        ("proactive_enabled", `Assoc [("type", `String "boolean")]);
        ("auto_handoff", `Assoc [("type", `String "boolean")]);
        ("handoff_threshold", `Assoc [("type", `String "number")]);
        ("handoff_cooldown_sec", `Assoc [("type", `String "integer")]);
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("tool_access",
          tool_access_schema
            "Canonical tool policy. Example preset: {kind: 'preset', preset: 'research', also_allow: ['masc_status']}. Example custom: {kind: 'custom', tools: ['masc_status']}.");
        ("tool_denylist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
      ]);
      ("required", `List [`String "persona_name"]);
    ];
  };

  {
    name = "masc_keeper_persona_audit";
    description = "Audit persona-backed keeper materialization across the active config root, durable keeper TOML, live runtime metadata, registry presence, autoboot, and keepalive state.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional keeper handle to audit. When omitted, all known keepers in the current base path/config root are audited.");
        ]);
        ("names", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Optional keeper handles to audit. Combined with name when both are provided.");
        ]);
        ("limit", `Assoc [
          ("type", `String "integer");
          ("default", `Int 100);
          ("description", `String "Maximum number of keepers to audit when name/names are omitted. Clamped to 500.");
        ]);
        ("include_ok", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool true);
          ("description", `String "If false, return only keepers with audit issues while keeping summary counts over all audited keepers.");
        ]);
        ("repair", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "If true, run Keeper_goal_repair.run after audit: create goals from keeper purpose statements and assign to keepers with empty active_goal_ids.");
        ]);
        ("dry_run_repair", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "If true, run Keeper_goal_repair.dry_run after audit: preview what repair would do without making changes.");
        ]);
      ]);
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
        ("active_goal_ids", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Goal IDs this keeper is allowed to claim work for. Empty clears goal scoping.");
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
        ("sandbox_profile", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) sandbox_profile_enum_strings));
          ("description", `String "Filesystem/process sandbox profile. 'local' runs on the host process with filesystem scoped to the keeper playground. 'docker' runs keeper_bash in an ephemeral hardened Docker container; the internal git/gh dispatcher upgrades network+credential mounts per-command.");
        ]);
        ("network_mode", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) network_mode_enum_strings));
          ("description", `String "Network policy associated with the sandbox profile. 'none' is valid only with sandbox_profile='docker'.");
        ]);
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Restrict file writes to these path prefixes. Empty list means playground-only (.masc/playground/<name>/).");
        ]);
        ("tool_access",
          tool_access_schema
            "Canonical tool policy. Example preset: {kind: 'preset', preset: 'research', also_allow: ['masc_status']}. Example custom: {kind: 'custom', tools: ['masc_status']}.");
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
    name = "masc_keeper_sandbox_status";
    description = "Inspect Docker sandbox state for one keeper or all keepers. Reports Docker preflight, visible containers, why no container is present, and identity drift warnings.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle. When omitted, return sandbox status for all registered keepers.");
        ]);
        ("verbose", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include full Docker preflight details in each result.");
        ]);
        ("include_preflight", `Assoc [
          ("type", `String "boolean");
          ("description", `String "When true, include Docker preflight status for docker keepers.");
        ]);
        ("timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Docker command timeout in seconds (default: 5).");
        ]);
      ]);
    ];
  };

  {
    name = "masc_keeper_sandbox_start";
    description = "Start a visible managed Docker sandbox container for a keeper. Only applies to sandbox_profile=docker keepers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle.");
        ]);
        ("network_mode", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) network_mode_enum_strings));
          ("description", `String "Managed container network policy. Defaults to the keeper's configured network_mode.");
        ]);
        ("ttl_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Managed container TTL in seconds before stale cleanup removes it (default: 1800).");
        ]);
        ("timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Docker command timeout in seconds (default: 10).");
        ]);
      ]);
      ("required", `List [`String "name"]);
    ];
  };

  {
    name = "masc_keeper_sandbox_stop";
    description = "Stop keeper sandbox containers scoped to this base path. Defaults to managed containers; pass container_kind=turn or container_kind=all to clean abandoned turn containers.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional keeper handle. When omitted, stop matching keeper sandbox containers for this base path.");
        ]);
        ("container_kind", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "managed"; `String "turn"; `String "all"]);
          ("description", `String "Container kind to stop. Defaults to managed; use turn for turn-scoped containers such as masc-keeper-turn-*.");
        ]);
        ("prune_stale", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Also run stale keeper sandbox cleanup after stopping matching containers.");
        ]);
        ("timeout_sec", `Assoc [
          ("type", `String "number");
          ("description", `String "Docker command timeout in seconds (default: 10).");
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
