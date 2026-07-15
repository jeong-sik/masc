(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Masc_domain

(** Network mode strings exposed only by explicit sandbox-management tools.
    Keeper creation/update no longer accepts sandbox posture knobs. *)
let network_mode_enum_strings =
  Keeper_types_profile_sandbox.valid_network_mode_strings
;;

module Sandbox_contract = Keeper_sandbox_control_contract

let sandbox_stop_scope_enum_strings = Sandbox_contract.stop_scope_strings

let positive_number_schema description =
  `Assoc
    [ "type", `String "number"
    ; "exclusiveMinimum", `Float 0.0
    ; "description", `String description
    ]
;;

let nonnegative_number_schema description =
  `Assoc
    [ "type", `String "number"
    ; "minimum", `Float 0.0
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

let closed_object_schema ~required properties =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc properties
    ; "required", `List (List.map (fun name -> `String name) required)
    ; "additionalProperties", `Bool false
    ]
;;

let keeper_invocation_target_schema =
  closed_object_schema
    ~required:[ "kind"; "name" ]
    [ "kind", `Assoc [ "type", `String "string"; "enum", `List [ `String "keeper" ] ]
    ; "name", `Assoc [ "type", `String "string" ]
    ]
;;

let keeper_invocation_run_ref_schema =
  closed_object_schema
    ~required:[ "run_id"; "target"; "capability" ]
    [ "run_id", `Assoc [ "type", `String "string" ]
    ; "target", keeper_invocation_target_schema
    ; ( "capability"
      , `Assoc
          [ "type", `String "string"; "enum", `List [ `String "invoke_turn" ] ] )
    ]
;;

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
          nonnegative_number_schema
            "Managed sandbox lifetime in seconds; omit or use 0 for no automatic expiry." );
        ( "timeout_sec",
          positive_number_schema "Explicit sandbox start timeout in seconds." );
      ]);
      ("required", `List [`String "name"; `String "timeout_sec"]);
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
          positive_number_schema "Explicit sandbox stop timeout in seconds." );
        ("prune_stale", `Assoc [
          ("type", `String "boolean");
          ("default", `Bool false);
          ("description", `String "Also remove stale managed sandbox containers after the targeted stop.");
        ]);
      ]);
      ("required", `List [ `String "timeout_sec" ]);
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
          ("description", `String "If true, return the resolved keeper args without creating the keeper.");
        ]);
        ("instructions", `Assoc [("type", `String "string")]);
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
        ("allowed_paths", `Assoc [
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
        ("instructions", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: additional system instructions (kept across compaction/handoff).");
        ]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Exact direct-mention tokens that can wake the keeper in workspace traffic (for example ['sangsu']).");
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
          ("description", `String "If true, scheduled keeper cycles may produce proactive responses.");
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

  { name = "masc_keeper_delegate"
  ; description = "Submit one typed, non-blocking Keeper invocation and return its durable run_ref."
  ; input_schema =
      closed_object_schema
        ~required:[ "target"; "capability"; "prompt" ]
        [ "target", keeper_invocation_target_schema
        ; ( "capability"
          , `Assoc
              [ "type", `String "string"; "enum", `List [ `String "invoke_turn" ] ] )
        ; "prompt", `Assoc [ "type", `String "string" ]
        ]
  }
; { name = "masc_keeper_delegate_status"
  ; description = "Read one Keeper invocation using the exact typed run_ref returned at submission."
  ; input_schema =
      closed_object_schema
        ~required:[ "run_ref" ]
        [ "run_ref", keeper_invocation_run_ref_schema ]
  }
; { name = "masc_keeper_delegate_cancel"
  ; description = "Request cancellation of one Keeper invocation identified by its exact typed run_ref."
  ; input_schema =
      closed_object_schema
        ~required:[ "run_ref" ]
        [ "run_ref", keeper_invocation_run_ref_schema ]
  }
; { name = "masc_keeper_delegate_list"
  ; description = "List non-terminal Keeper invocations, optionally filtered by a typed Keeper target."
  ; input_schema =
      closed_object_schema ~required:[] [ "target", keeper_invocation_target_schema ]
  };

  (* masc_keeper_reconcile removed with manual_reconcile blocker system. *)

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
Clears stale data from previous sessions. Does not affect configuration, instructions, or persona.";
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
    description = "Trigger explicit context compaction for a non-terminal keeper checkpoint.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle");
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
FSM, which resets context_overflow. \
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
(goal, instructions, mention_targets, proactive_enabled) become the defaults a \
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
        ("instructions", `Assoc [("type", `String "string")]);
        ("mention_targets", `Assoc [
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
        ("instructions", `Assoc [("type", `String "string")]);
        ("mention_targets", `Assoc [
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
