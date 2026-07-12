(** Keeper tool schemas — MCP tool definitions for keeper agents. *)

open Masc_domain

type sandbox_lifecycle_operation =
  | Sandbox_stop

type sandbox_lifecycle_policy =
  { required_permission : permission
  ; destructive : bool
  }

type sandbox_stop_target =
  | Stop_keeper of string
  | Stop_fleet

type sandbox_stop_request =
  { target : sandbox_stop_target
  ; scope : Keeper_types_profile_sandbox.sandbox_stop_scope
  ; timeout_sec : float
  }

type sandbox_status_request =
  { keeper_name : string option
  ; verbose : bool
  ; include_preflight : bool
  ; timeout_sec : float
  }

let all_sandbox_lifecycle_operations = [ Sandbox_stop ]

let sandbox_lifecycle_tool_name = function
  | Sandbox_stop -> "masc_keeper_sandbox_stop"
;;

let sandbox_lifecycle_operation_of_tool_name name =
  List.find_opt
    (fun operation ->
      String.equal name (sandbox_lifecycle_tool_name operation))
    all_sandbox_lifecycle_operations
;;

let sandbox_lifecycle_policy = function
  | Sandbox_stop -> { required_permission = CanAdmin; destructive = true }
;;

let sandbox_control_default_timeout_sec () =
  Env_config_sandbox.Shell_timeout.timeout_sec
    ~bucket:Env_config_sandbox.Shell_timeout.Cleanup_rm
    ()

let sandbox_status_default_timeout_sec () =
  Env_config_sandbox.Shell_timeout.timeout_sec
    ~bucket:Env_config_sandbox.Shell_timeout.Read
    ()

let duplicate_field fields =
  let rec first_duplicate = function
    | left :: (right :: _ as rest) ->
      if String.equal left right then Some left else first_duplicate rest
    | [] | [ _ ] -> None
  in
  fields |> List.map fst |> List.sort String.compare |> first_duplicate
;;

let sandbox_object_fields ~allowed = function
  | `Assoc fields ->
    (match duplicate_field fields with
     | Some name -> Error (Printf.sprintf "duplicate sandbox argument %S" name)
     | None ->
       let unsupported =
         fields
         |> List.filter_map (fun (name, _) ->
           if List.mem name allowed then None else Some name)
         |> List.sort_uniq String.compare
       in
       (match unsupported with
        | [] -> Ok fields
        | names ->
          Error
            (Printf.sprintf
               "unsupported sandbox argument(s): %s"
               (String.concat ", " names))))
  | _ -> Error "sandbox lifecycle arguments must be a JSON object"
;;

let optional_nonempty_string fields name =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`String value) ->
    let value = String.trim value in
    if String.equal value ""
    then Error (Printf.sprintf "%s must not be empty" name)
    else Ok (Some value)
  | Some _ -> Error (Printf.sprintf "%s must be a string" name)
;;

let optional_bool fields name =
  match List.assoc_opt name fields with
  | None -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some _ -> Error (Printf.sprintf "%s must be a boolean" name)
;;

let optional_bool_with_default fields name ~default =
  match List.assoc_opt name fields with
  | None -> Ok default
  | Some (`Bool value) -> Ok value
  | Some _ -> Error (Printf.sprintf "%s must be a boolean" name)
;;
let positive_number_with_default fields name ~default =
  let parsed =
    match List.assoc_opt name fields with
    | None -> Ok default
    | Some (`Int value) -> Ok (float_of_int value)
    | Some (`Intlit value) ->
      (match float_of_string_opt value with
       | Some parsed -> Ok parsed
       | None -> Error (Printf.sprintf "%s must be a number" name))
    | Some (`Float value) -> Ok value
    | Some _ -> Error (Printf.sprintf "%s must be a number" name)
  in
  match parsed with
  | Error _ as error -> error
  | Ok value when not (Float.is_finite value) ->
    Error (Printf.sprintf "%s must be finite" name)
  | Ok value when value <= 0.0 ->
    Error (Printf.sprintf "%s must be greater than zero" name)
  | Ok value -> Ok value
;;

let parse_sandbox_stop_request args =
  match
    sandbox_object_fields
      ~allowed:[ "name"; "fleet"; "container_kind"; "timeout_sec" ]
      args
  with
  | Error _ as error -> error
  | Ok fields ->
    let scope =
      match List.assoc_opt "container_kind" fields with
      | None -> Error "container_kind is required"
      | Some (`String raw) ->
        (match Keeper_types_profile_sandbox.sandbox_stop_scope_of_string raw with
         | Some scope -> Ok scope
         | None ->
           Error
             (Printf.sprintf
                "container_kind must be one of: %s"
                (String.concat
                   ", "
                   Keeper_types_profile_sandbox.valid_sandbox_stop_scope_strings)))
      | Some _ -> Error "container_kind must be a string"
    in
    (match
       optional_nonempty_string fields "name",
       optional_bool fields "fleet",
       scope,
       positive_number_with_default
         fields
         "timeout_sec"
         ~default:(sandbox_control_default_timeout_sec ())
     with
     | Error error, _, _, _
     | _, Error error, _, _
     | _, _, Error error, _
     | _, _, _, Error error -> Error error
     | ( Ok keeper_name
       , Ok fleet
       , Ok scope
       , Ok timeout_sec ) ->
       let target =
         match keeper_name, fleet with
         | Some name, None when Safe_identifier.is_portable_name name ->
           Ok (Stop_keeper name)
         | Some _, None -> Error (Safe_identifier.portable_name_error ~field:"name")
         | None, Some true -> Ok Stop_fleet
         | Some _, Some _ | None, Some false | None, None ->
           Error "provide exactly one sandbox stop target: name or fleet=true"
       in
       (match target with
        | Error _ as error -> error
       | Ok target -> Ok { target; scope; timeout_sec }))
;;

let parse_sandbox_status_request args =
  match
    sandbox_object_fields
      ~allowed:[ "name"; "verbose"; "include_preflight"; "timeout_sec" ]
      args
  with
  | Error _ as error -> error
  | Ok fields ->
    (match
       optional_nonempty_string fields "name",
       optional_bool_with_default fields "verbose" ~default:false,
       optional_bool_with_default fields "include_preflight" ~default:true,
       positive_number_with_default
         fields
         "timeout_sec"
         ~default:(sandbox_status_default_timeout_sec ())
     with
     | Error error, _, _, _
     | _, Error error, _, _
     | _, _, Error error, _
     | _, _, _, Error error -> Error error
     | ( Ok keeper_name
       , Ok verbose
       , Ok include_preflight
       , Ok timeout_sec ) ->
       Ok
         { keeper_name
         ; verbose
         ; include_preflight
         ; timeout_sec
         })
;;

let number_property ~description ~default =
  `Assoc
    [ "type", `String "number"
    ; "exclusiveMinimum", `Float 0.0
    ; "default", `Float default
    ; "description", `String description
    ]
;;

let sandbox_stop_schema =
  { name = sandbox_lifecycle_tool_name Sandbox_stop
  ; description =
      "Stop active turn or one-shot sandbox containers for exactly one keeper or an explicitly selected fleet."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "name"
                , `Assoc
                    [ "type", `String "string"
                    ; "minLength", `Int 1
                    ; ( "description"
                      , `String
                          "Keeper handle for a single-keeper stop. Mutually exclusive with fleet=true." )
                    ] )
              ; ( "fleet"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "const", `Bool true
                    ; ( "description"
                      , `String
                          "Set true to target all matching keeper containers in this base path. Mutually exclusive with name." )
                    ] )
              ; ( "container_kind"
                , `Assoc
                    [ "type", `String "string"
                    ; ( "enum"
                      , `List
                          (List.map
                             (fun value -> `String value)
                             Keeper_types_profile_sandbox.valid_sandbox_stop_scope_strings) )
                    ; "description", `String "Required container scope: oneshot, turn, or all."
                    ] )
              ; ( "timeout_sec"
                , number_property
                    ~description:"Docker stop timeout in seconds."
                    ~default:(sandbox_control_default_timeout_sec ()) )
              ] )
        ; "required", `List [ `String "container_kind" ]
        ; ( "oneOf"
          , `List
              [ `Assoc
                  [ "required", `List [ `String "name" ]
                  ; "not", `Assoc [ "required", `List [ `String "fleet" ] ]
                  ]
              ; `Assoc
                  [ "required", `List [ `String "fleet" ]
                  ; ( "properties"
                    , `Assoc
                        [ "fleet", `Assoc [ "const", `Bool true ] ] )
                  ; "not", `Assoc [ "required", `List [ `String "name" ] ]
                  ]
              ] )
        ; "additionalProperties", `Bool false
        ]
  }
;;

let sandbox_lifecycle_schemas = [ sandbox_stop_schema ]
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

let sandbox_status_schema =
  { name = "masc_keeper_sandbox_status"
  ; description =
      "Inspect the effective Keeper sandbox boundary, Docker preflight, active on-demand containers, credential projection, and playground repository policy. Omit name for fleet status."
  ; input_schema =
      `Assoc
        [ "type", `String "object"
        ; ( "properties"
          , `Assoc
              [ ( "name"
                , `Assoc
                    [ "type", `String "string"
                    ; "minLength", `Int 1
                    ; "description", `String "Optional Keeper handle. Omit for fleet status."
                    ] )
              ; ( "verbose"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "default", `Bool false
                    ; "description", `String "Include verbose container diagnostics."
                    ] )
              ; ( "include_preflight"
                , `Assoc
                    [ "type", `String "boolean"
                    ; "default", `Bool true
                    ; "description", `String "Probe Docker readiness for Docker profiles."
                    ] )
              ; ( "timeout_sec"
                , number_property
                    ~description:"Caller-owned timeout for each sandbox status probe."
                    ~default:(sandbox_status_default_timeout_sec ()) )
              ] )
        ; "additionalProperties", `Bool false
        ]
  }
;;

let keeper_schemas : tool_schema list = [
  sandbox_status_schema;
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
Required fields: persona_name, display_name. Optional fields: role, trait, goal, instructions, \
mention_targets, tool_denylist, proactive_enabled, auto_handoff.";
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
        ("auto_handoff", `Assoc [("type", `String "boolean")]);
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
        ("auto_handoff", `Assoc [("type", `String "boolean")]);
      ]);
      ("required", `List [`String "persona_name"]);
    ];
  };

] @ sandbox_lifecycle_schemas

let schemas : tool_schema list =
  keeper_schemas
