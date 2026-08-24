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
  Keeper_schema_toml.audit;

  Keeper_schema_toml.up;

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

  Keeper_schema_toml.delegate
; Keeper_schema_toml.delegate_status
; Keeper_schema_toml.delegate_cancel
; Keeper_schema_toml.delegate_list;


  Keeper_schema_toml.down;

  Keeper_schema_toml.list;

  Keeper_schema_toml.reset;

  Keeper_schema_toml.compact;

  Keeper_schema_toml.msg;

  Keeper_schema_toml.clear;

]
