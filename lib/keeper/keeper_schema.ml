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

let tail_order_enum_strings =
  Keeper_status_options_defaults.valid_tail_order_strings

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

let schemas : tool_schema list = [
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
    name = "masc_keeper_audit";
    description = "Audit keeper config, prompt, live runtime metadata, registry presence, autoboot, and keepalive state.";
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
      ("additionalProperties", `Bool false);
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
          ("description", `String "Complete Keeper instructions written to keepers/<name>/AGENT.md (kept across compaction/handoff).");
        ]);
        ("mention_targets", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Exact direct-mention tokens that can wake the keeper in workspace traffic (for example ['example-keeper']).");
        ]);
        ("active_goal_ids", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Goal IDs this keeper is allowed to claim work for. Empty clears goal scoping.");
        ]);
        ("sandbox_profile", `Assoc [
          ("type", `String "string");
          ("enum", `List [`String "local"; `String "docker"]);
          ("default", `String "local");
          ("description", `String "Sandbox isolation profile. New keepers default to local with playground-only writes when omitted; select docker explicitly when required.");
        ]);
        ("autoboot_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If false, persist the keeper but skip auto-start on future server boots.");
        ]);
        ("max_context_override", `Assoc [
          ("type", `String "integer");
          ("description", `String "Optional: absolute context token limit override for this keeper. Use 0 to clear the override.");
        ]);
        ("autonomous_wake_prompt", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional: user message this keeper's autonomous turns are woken with, overriding the fleet autonomous.wake_prompt. Non-blank, at most 2048 bytes; it is appended to the durable checkpoint every autonomous turn. Use null to clear.");
        ]);
        ("proactive_enabled", `Assoc [
          ("type", `String "boolean");
          ("description", `String "If true, scheduled keeper cycles may produce proactive responses.");
        ]);
        ("runtime_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Optional opaque runtime id. Writes the keeper assignment to runtime.toml.");
        ]);
        ("allowed_paths", `Assoc [
          ("type", `String "array");
          ("items", `Assoc [("type", `String "string")]);
          ("description", `String "Restrict file writes to these path prefixes. Empty list means playground-only (.masc/playground/<name>/).");
        ]);
      ]);
      ("required", `List [`String "name"]);
      (* [network_mode] is deliberately absent from the MCP contract. *)
      ("additionalProperties", `Bool false);
    ];
  };

  {
    name = "masc_keeper_status";
    description = "Get keeper status (keepalive/live/reconcile state plus current context and monitoring tails).";
    input_schema = closed_object_schema ~required:[] [
        (Keeper_status_options_defaults.Argument.name, `Assoc [
          ("type", `String "string");
          ("minLength", `Int 1);
          ("pattern", `String "\\S");
          ("description", `String "Non-blank Keeper handle. Optional; defaults to the caller only when omitted.");
        ]);
        (Keeper_status_options_defaults.Argument.tail_turns, `Assoc [
          ("type", `String "integer");
          ("minimum", `Int Keeper_status_options_defaults.min_tail_turns);
          ("maximum", `Int Keeper_status_options_defaults.max_tail_turns);
          ("description", `String (Printf.sprintf "How many recent turns to include from keeper metrics (default: %d; maximum: %d)." Keeper_status_options_defaults.tail_turns Keeper_status_options_defaults.max_tail_turns));
        ]);
        (Keeper_status_options_defaults.Argument.tail_messages, `Assoc [
          ("type", `String "integer");
          ("minimum", `Int Keeper_status_options_defaults.min_tail_messages);
          ("maximum", `Int Keeper_status_options_defaults.max_tail_messages);
          ("description", `String (Printf.sprintf "How many recent history messages to include (default: %d; maximum: %d)." Keeper_status_options_defaults.tail_messages Keeper_status_options_defaults.max_tail_messages));
        ]);
        (Keeper_status_options_defaults.Argument.tail_bytes, `Assoc [
          ("type", `String "integer");
          ("minimum", `Int Keeper_status_options_defaults.min_tail_bytes);
          ("maximum", `Int Keeper_status_options_defaults.max_tail_bytes);
          ("description", `String (Printf.sprintf "How many bytes from the end of files to scan for tails (default: %d; range: %d..%d)." Keeper_status_options_defaults.tail_bytes Keeper_status_options_defaults.min_tail_bytes Keeper_status_options_defaults.max_tail_bytes));
        ]);
        (Keeper_status_options_defaults.Argument.tail_order, `Assoc [
          ("type", `String "string");
          ("enum", `List (List.map (fun s -> `String s) tail_order_enum_strings));
          ("description", `String "Ordering for metrics/history tails and recent memory notes. Default: oldest_first.");
        ]);
        (Keeper_status_options_defaults.Argument.fast, `Assoc [
          ("type", `String "boolean");
          ("description", `String "Enable fast mode (skip heavy sections unless explicitly enabled).");
        ]);
        (Keeper_status_options_defaults.Argument.include_context, `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include checkpoint-derived context stats (default: !fast).");
        ]);
        (Keeper_status_options_defaults.Argument.include_metrics_overview, `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include metrics overview + skill route scan (default: !fast).");
        ]);
        (Keeper_status_options_defaults.Argument.include_history_tail, `Assoc [
          ("type", `String "boolean");
          ("description", `String "Include recent history tail + fragment counters (default: !fast).");
        ]);
    ];
  };

  { name = "masc_keeper_delegate"
  ; description = "Submit one typed Keeper chat operation and return its durable operation_id without waiting for the turn."
  ; input_schema =
      closed_object_schema
        (* [capability] is not advertised. Its enum has one member, so a
           submitter cannot choose it -- it can only restate it or get it wrong
           -- and every delegate rejection in the week before #27434 was this
           field: 22 said "task_assignment", 7 said "claim_and_execute", both
           descriptions of the prompt rather than capabilities the contract
           offers. A field named [capability] reads as a menu.

           #27434 made it optional, which was not enough. Measured across that
           week, all 64 calls sent the field explicitly and none omitted it: a
           field the model can see is a field it fills in. The decoder still
           accepts it, so the dashboard and operator paths that send it are
           unaffected; it stops being offered.

           A second capability puts it back here, as a real choice. *)
        ~required:[ "target"; "prompt" ]
        [ "target", keeper_invocation_target_schema
        ; "prompt", `Assoc [ "type", `String "string" ]
        ]
  }
; { name = "masc_keeper_delegate_status"
  ; description = "Read one Keeper chat operation by exact target and operation_id."
  ; input_schema =
      closed_object_schema
        ~required:[ "target"; "operation_id" ]
        [ "target", keeper_invocation_target_schema
        ; "operation_id", `Assoc [ "type", `String "string" ]
        ]
  }
; { name = "masc_keeper_delegate_cancel"
  ; description = "Cancel one queued Keeper chat operation by exact target and operation_id."
  ; input_schema =
      closed_object_schema
        ~required:[ "target"; "operation_id" ]
        [ "target", keeper_invocation_target_schema
        ; "operation_id", `Assoc [ "type", `String "string" ]
        ]
  }
; { name = "masc_keeper_delegate_list"
  ; description = "List queued Keeper chat operations owned by the caller for one exact Keeper target."
  ; input_schema =
      closed_object_schema
        ~required:[ "target" ]
        [ "target", keeper_invocation_target_schema ]
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
      ("additionalProperties", `Bool false);
    ];
  };

  {
    name = "masc_keeper_list";
    description =
      "List known keepers from persisted keeper metadata. The response carries \
       total (keepers known before limit), limit (the value applied) and \
       truncated, so a short answer is distinguishable from a complete one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("limit", `Assoc [
          ("type", `String "integer");
          ("description",
           `String
             "Max keepers to return (default: 50). Names are sorted and cut \
              from the end, so a low limit hides whatever sorts last; check \
              truncated in the response.");
        ]);
        ("detailed", `Assoc [
          ("type", `String "boolean");
          ("description", `String "Return keeper summaries (model/context/handoff/compaction) instead of names only.");
        ]);
      ]);
      ("additionalProperties", `Bool false);
    ];
  };

  {
    name = "masc_keeper_reset";
    description = "Clear a keeper's lifecycle latch: drops the pause bit, the latched \
reason, and runtime.last_blocker in one durable write. This is the operator recovery path \
for a keeper the generic resume transform refuses to unpause — Keeper_meta_contract.mark_resumed \
deliberately leaves Transcript_corruption_reset_required unchanged, so resume alone cannot \
free it. Does not touch usage counters, token stats, configuration, \
goals, or Keeper instructions.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle to reset");
        ]);
      ]);
      ("required", `List [`String "name"]);
      ("additionalProperties", `Bool false);
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
      ("additionalProperties", `Bool false);
    ];
  };

  {
    name = "masc_keeper_msg";
    description = "Send a direct message to a keeper. Submits the message as an async chat operation and returns operation_id immediately; poll masc_keeper_delegate_status with target {kind: \"keeper\", name} and this operation_id to observe the turn settle.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("name", `Assoc [
          ("type", `String "string");
          ("description", `String "Keeper handle to message");
        ]);
        ("message", `Assoc [
          ("type", `String "string");
          ("description", `String "Message text to send to the keeper");
        ]);
      ]);
      ("required", `List [`String "name"; `String "message"]);
      ("additionalProperties", `Bool false);
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
      ("additionalProperties", `Bool false);
    ];
  };

]
