(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Masc_domain

(** Network mode strings exposed only by explicit sandbox-management tools.
    Keeper creation/update no longer accepts sandbox posture knobs. *)
let network_mode_enum_strings =
  Keeper_types_profile_sandbox.valid_network_mode_strings
;;

module Sandbox_contract = Keeper_sandbox_control_contract

let sandbox_stop_scope_enum_strings = Sandbox_contract.stop_scope_strings

let bounded_number_schema (bounds : Sandbox_contract.bounded_float) description =
  `Assoc
    [ "type", `String "number"
    ; "minimum", `Float bounds.minimum
    ; "maximum", `Float bounds.maximum
    ; "default", `Float bounds.default
    ; "description", `String description
    ]
;;

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
  `Assoc [
    ("type", `String "array");
    ("description", `String description);
    ("items", `Assoc [ ("type", `String "string") ]);
  ]

let keeper_schemas : tool_schema list = [
  {
    name = "masc_keeper_sandbox_start";
    description = "Start the managed sandbox container for a keeper.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle whose managed sandbox should be started.");
        ]);
        ("network_mode", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun value -> `String value) network_mode_enum_strings));
          ("description", `String "Optional sandbox network mode. Defaults to the keeper's configured network mode.");
        ]);
        ( "ttl_sec",
          bounded_number_schema
            Sandbox_contract.managed_ttl_sec
            "Managed sandbox lifetime in seconds." );
        ( "timeout_sec",
          bounded_number_schema
            Sandbox_contract.operation_timeout_sec
            "Sandbox start timeout in seconds." );
      ]);
      ("required", `List [`String "name"]);
      ("additionalProperties", `Bool false);
    ];
  };
  {
    name = "masc_keeper_sandbox_stop";
    description = "Stop the managed sandbox container(s) for a keeper or fleet.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional keeper handle. When omitted, stop matching containers across the active fleet.");
        ]);
        ("container_kind", `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun value -> `String value) sandbox_stop_scope_enum_strings));
          ( "default",
            `String
              (Sandbox_contract.stop_scope_to_string
                 Sandbox_contract.default_stop_scope) );
          ("description", `String "Container scope to stop: managed, turn, or all (default: managed).");
        ]);
        ( "timeout_sec",
          bounded_number_schema
            Sandbox_contract.operation_timeout_sec
            "Sandbox stop timeout in seconds." );
        ("prune_stale", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "Also remove stale managed sandbox containers after the targeted stop.");
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };
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
        ("instructions", `Assoc [("type", `String "string")]);
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
            "Persisted tool candidate profiles for discovery. Does not alone grant execution; runtime applies descriptor availability, denylist, per-turn OAS policy, and eval gates.");
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
        ("instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: additional system instructions (kept across compaction/handoff).");
        ]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Exact direct-mention tokens that can wake the keeper in workspace traffic (for example ['sangsu']).");
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
          ("description", `String "Optional: absolute context token limit override for this keeper. Use 0 to clear the override.");
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
          ("description", `String "Compaction profile. One of: aggressive, balanced, conservative, custom.");
        ]);
        ("compaction_ratio_gate", `Assoc [
          ("type", `String "number");
          ("description", `String "Context ratio gate for compaction (0.1-0.98). Overrides compaction profile when set.");
        ]);
        ("compaction_message_gate", `Assoc [
          ("type", `String "integer");
          ("description", `String "Message count gate for compaction (0 disables this gate). Overrides compaction profile when set.");
        ]);
        ("compaction_token_gate", `Assoc [
          ("type", `String "integer");
          ("description", `String "Token count gate for compaction (0 disables this gate). Overrides compaction profile when set.");
        ]);
        ("compaction_cooldown_sec", `Assoc [
          ("type", `String "integer");
          ("description", `String "Minimum seconds between completed compactions. 0 disables the cooldown.");
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
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Restrict file writes to these path prefixes. Empty list means playground-only (.masc/playground/<name>/).");
        ]);
        ("tool_access",
          tool_access_schema
            "Persisted tool candidate profiles for discovery. Does not alone grant execution; runtime applies descriptor availability, denylist, per-turn OAS policy, and eval gates.");
        ("tool_denylist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Execution removal layer after candidate discovery. Excludes matching tools from runtime execution.");
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
          ("description", `String "Optional override: overall timeout (sec) for this async keeper message request and its runtime turn. Defaults to the runtime-resolved keeper turn timeout.");
        ]);
        ("direct_reply", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: run the turn synchronously and return the reply directly instead of queueing");
        ]);
        ("no_skill_route", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Optional: do not emit SKILL/SKILL_REASON headers in reply");
        ]);
        ("turn_instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: free-form instructions to prepend to the keeper prompt for this turn");
        ]);
        ("surface_context", `Assoc [
          ("type", `String "object");
          ("description", `String "Optional: co-view context from the dashboard ({ label, route, scene, fields }); formatted into turn instructions when turn_instructions is omitted");
        ]);
        ("channel", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: channel label (e.g. copilot) for the chat lane");
        ]);
        ("channel_user_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: external user id on the channel");
        ]);
        ("channel_user_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: external user name on the channel");
        ]);
        ("channel_workspace_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: operator session or workspace id for the channel");
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
    name = "masc_keeper_msg_cancel";
    description = "Cancel a running async keeper_msg request by request_id.";
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
    name = "masc_keeper_msg_queue";
    description = "List all pending/running async keeper_msg requests, optionally filtered by keeper_name.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("keeper_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: filter by keeper name");
        ]);
      ]);
    ];
  };

  (* masc_keeper_reconcile removed with manual_reconcile blocker system. *)

  {
    name = "masc_keeper_adversarial_review";
    description = "Run fresh-context structural adversarial review on a diff or changed file.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("diff", `Assoc [
          ("type", `String "string");
          ("description", `String "Unified diff or file content to review.");
        ]);
        ("path", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional file path; when provided the diff is treated as the changed file content.");
        ]);
      ]);
      ("required", `List [`String "diff"]);
    ];
  };

  {
    name = "masc_keeper_down";
    description = "Submit a durable, non-blocking Keeper shutdown. Returns an operation_id immediately after admission is fenced and the ownership snapshot is persisted. Repeating the call returns the existing operation state.";
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

  {
    name = "masc_persona_create";
    description = "Create a new persona profile at MASC_PERSONAS_DIR/<name>/profile.json. \
Persona profiles serve as templates for keeper creation via masc_keeper_create_from_persona. \
Identity fields (display_name, role, trait) describe the persona; keeper-template fields \
(goal, instructions, mention_targets, tool_denylist, proactive_enabled) become the defaults a \
keeper spawned from this persona inherits. Required fields: persona_name, display_name.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("persona_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Unique persona handle. Used as the directory name under MASC_PERSONAS_DIR.");
        ]);
        ("display_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Human-readable display name for the persona.");
        ]);
        ("role", `Assoc [("type", `String "string")]);
        ("trait", `Assoc [("type", `String "string")]);
        ("goal", `Assoc [("type", `String "string")]);
        ("instructions", `Assoc [("type", `String "string")]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("tool_denylist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("proactive_enabled", `Assoc [("type", `String "boolean")]);
      ]);
      ("required", `List [`String "persona_name"; `String "display_name"]);
    ];
  };

  {
    name = "masc_persona_update";
    description = "Update an existing persona profile. Uses partial merge semantics — \
only the fields present in the request are merged into the existing profile.json. \
persona_name is immutable (delete and recreate to rename). Returns error if the \
persona does not exist.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("persona_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Persona handle to update. Must already exist.");
        ]);
        ("display_name", `Assoc [("type", `String "string")]);
        ("role", `Assoc [("type", `String "string")]);
        ("trait", `Assoc [("type", `String "string")]);
        ("goal", `Assoc [("type", `String "string")]);
        ("instructions", `Assoc [("type", `String "string")]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("tool_denylist", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
        ]);
        ("proactive_enabled", `Assoc [("type", `String "boolean")]);
      ]);
      ("required", `List [`String "persona_name"]);
    ];
  };

  {
    name = "masc_persona_delete";
    description = "Delete an existing persona profile and its directory under \
MASC_PERSONAS_DIR/<name>/ (profile.json plus any sibling files such as AGENT.md). \
Returns an error if the persona does not exist. Keepers already spawned from the \
persona are unaffected (their keeper TOML is independent); this only prevents \
future spawns from the persona.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("persona_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Persona handle to delete. Must already exist.");
        ]);
      ]);
      ("required", `List [`String "persona_name"]);
    ];
  };

]

let schemas : tool_schema list =
  keeper_schemas
