module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

open Types
open Tool_args

type 'a context = {
  config : Coord.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  mcp_session_id : string option;
}

type tool_result = bool * string

let schema_properties entries = `Assoc entries

let strict_action_enums =
  [
    `String "broadcast";
    `String "namespace_pause";
    `String "namespace_resume";
    `String "social_sweep";
    (* Issue #8417: [task_inject] has a real handler in
       [Operator_control.dispatch] (line 119) and is advertised by
       [Operator_pending_confirm.available_actions] (line 253).  It
       was previously grouped with the legacy aliases, so the remote
       operator MCP surface and the LLM judge never saw it and
       couldn't discover the capability. The remaining entries in
       [legacy_action_alias_enums] are genuine aliases
       ([keeper_msg]→[keeper_message], [room_pause]→[namespace_pause],
       [room_resume]→[namespace_resume], [autonomy_tick]→[social_sweep]). *)
    `String "task_inject";
    `String "github_identity_login_prepare";
    `String "github_identity_status";
    `String "keeper_message";
    `String "keeper_probe";
    `String "keeper_recover";
    `String "keeper_github_identity_login_prepare";
    `String "keeper_github_identity_status";
  ]

let legacy_action_alias_enums =
  [ `String "keeper_msg"; `String "room_pause"; `String "room_resume";
    `String "autonomy_tick" ]

let target_type_enums =
  [
    `String "root";
    `String "namespace";
    `String "keeper";
  ]

let snapshot_schema ~remote =
  {
    name = "masc_operator_snapshot";
    description =
      if remote then
        "Read the unified operator control-plane state. Use this when you need current namespace, keeper, message, and pending-confirm data before taking action."
      else
        "Read unified operator state for the default namespace, keepers, recent messages, and pending confirmations. Use this before issuing control-plane actions.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                (* Issue #8471: derive enum from Variant SSOT
                   ([Operator_control_snapshot.valid_snapshot_view_strings]).
                   Sessions was missing from the hand-written list before
                   this fix; the parser accepted "sessions" but the
                   schema rejected it. *)
                ("view", `Assoc [ ("type", `String "string"); ("enum", `List (List.map (fun s -> `String s) Operator_control_snapshot.valid_snapshot_view_strings)) ]);
                ("include_messages", `Assoc [ ("type", `String "boolean") ]);
                ("include_keepers", `Assoc [ ("type", `String "boolean") ]);
              ] );
        ];
  }

let digest_target_type_enums = [ `String "root"; `String "namespace" ]
let judgment_surface_enums =
  [
    `String "command.namespace";
    `String "intervene";
  ]

let digest_schema ~remote =
  {
    name = "masc_operator_digest";
    description =
      if remote then
        "Read an intervention-oriented operator digest. Use this when you need namespace health, attention items, command-plane search or microarch signals, worker summaries, and recommended next actions before deciding how to intervene."
      else
        "Read a high-signal operator digest with intervention recommendations for the default namespace. Use this when raw snapshot data is too low-level for fast supervision and you want translated command-plane search or microarch signals.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ( "target_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List digest_target_type_enums);
                    ] );
                ("target_id", `Assoc [ ("type", `String "string") ]);
                ("include_workers", `Assoc [ ("type", `String "boolean") ]);
              ] );
        ];
  }

let surface_audit_schema ~remote =
  {
    name = "masc_surface_audit";
    description =
      if remote then
        "Read dashboard surface readiness, exposure policy, and evidence references. Use this before pointing operators to an experimental surface."
      else
        "Read dashboard surface readiness, exposure policy, and evidence references. Use this to decide whether a surface belongs in main navigation, Lab, or should stay hidden.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [ ("surface_id", `Assoc [ ("type", `String "string") ]) ] );
        ];
  }

let action_schema ~remote =
  let enum_values =
    if remote then strict_action_enums else strict_action_enums @ legacy_action_alias_enums
  in
  {
    name = "masc_operator_action";
    description =
      if remote then
        "Preview or run a structured operator action. Use this when you need to broadcast, pause a namespace, or message a keeper through the remote operator surface. Use social_sweep for immediate public-square social processing."
      else
        "Run a structured operator action against the namespace or a keeper. Use this when you need guided control with preview-confirm safety for disruptive actions. Use social_sweep for immediate public-square social processing.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ( "action_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List enum_values);
                    ] );
                ( "target_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List target_type_enums);
                    ] );
                ("target_id", `Assoc [ ("type", `String "string") ]);
                ("payload", `Assoc [ ("type", `String "object") ]);
              ] );
            ("required", `List [ `String "action_type"; `String "payload" ]);
        ];
  }

let confirm_schema =
  {
    name = "masc_operator_confirm";
    description =
      "Confirm and execute a previously previewed operator action. Use this only after masc_operator_action returns confirm_required=true.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ("actor", `Assoc [ ("type", `String "string") ]);
                ("confirm_token", `Assoc [ ("type", `String "string") ]);
                ( "decision",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List [ `String "confirm"; `String "deny" ]);
                    ] );
              ] );
          ("required", `List [ `String "confirm_token" ]);
        ];
  }

let judgment_write_schema =
  {
    name = "masc_operator_judgment_write";
    description =
      "Internal operator-judge write path. Use this to store a durable operator judgment for namespace supervision. Hidden from the default catalog and intended for keeper/automation experiments.";
    input_schema =
      `Assoc
        [
          ("type", `String "object");
          ( "properties",
            schema_properties
              [
                ( "surface",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List judgment_surface_enums);
                    ] );
                ( "target_type",
                  `Assoc
                    [
                      ("type", `String "string");
                      ("enum", `List digest_target_type_enums);
                    ] );
                ("target_id", `Assoc [ ("type", `String "string") ]);
                ("summary", `Assoc [ ("type", `String "string") ]);
                ("confidence", `Assoc [ ("type", `String "number") ]);
                ("fresh_ttl_sec", `Assoc [ ("type", `String "integer") ]);
                ("keeper_name", `Assoc [ ("type", `String "string") ]);
                ("model_name", `Assoc [ ("type", `String "string") ]);
                ("runtime_name", `Assoc [ ("type", `String "string") ]);
                ( "evidence_refs",
                  `Assoc
                    [
                      ("type", `String "array");
                      ("items", `Assoc [ ("type", `String "string") ]);
                    ] );
                ("recommended_action", `Assoc [ ("type", `String "object") ]);
                ("fallback_used", `Assoc [ ("type", `String "boolean") ]);
                ("disagreement_with_truth", `Assoc [ ("type", `String "boolean") ]);
              ] );
          ("required", `List [ `String "surface"; `String "target_type"; `String "summary" ]);
        ];
  }

let json_string_of_result = function
  | Ok json -> (true, Yojson.Safe.to_string json)
  | Error message -> (false, Yojson.Safe.to_string (`Assoc [ ("status", `String "error"); ("message", `String message) ]))

let dispatch (ctx : 'a context) ~name ~args : tool_result option =
  let control_ctx : 'a Operator_control.context =
    {
      config = ctx.config;
      agent_name = ctx.agent_name;
      sw = ctx.sw;
      clock = ctx.clock;
      proc_mgr = ctx.proc_mgr;
      net = ctx.net;
      mcp_session_id = ctx.mcp_session_id;
    }
  in
  match name with
  | "masc_operator_snapshot" ->
      let actor = get_string_opt args "actor" in
      let view = get_string_opt args "view" in
      let include_messages = get_bool args "include_messages" true in
      let include_keepers = get_bool args "include_keepers" true in
      Some
        ( true,
          Yojson.Safe.to_string
            (Operator_control.snapshot_json ?actor ?view ~include_messages
               ~include_keepers control_ctx) )
  | "masc_operator_digest" ->
      let actor = get_string_opt args "actor" in
      let target_type = get_string_opt args "target_type" in
      let target_id = get_string_opt args "target_id" in
      let include_workers = get_bool args "include_workers" true in
      Some
        (json_string_of_result
           (Operator_control.digest_json ?actor ?target_type ?target_id
              ~include_workers control_ctx))
  | "masc_operator_action" ->
      Some (json_string_of_result (Operator_control.action_json control_ctx args))
  | "masc_operator_confirm" ->
      Some (json_string_of_result (Operator_control.confirm_json control_ctx args))
  | "masc_surface_audit" ->
      let surface_id = get_string_opt args "surface_id" in
      Some (true, Yojson.Safe.to_string (Dashboard_surface_readiness.json ?surface_id ()))
  | "masc_operator_judgment_write" ->
      Some
        (json_string_of_result (Operator_control.judgment_write_json control_ctx args))
  | _ -> None

let schemas : tool_schema list =
  [
    snapshot_schema ~remote:false;
    digest_schema ~remote:false;
    action_schema ~remote:false;
    confirm_schema;
    surface_audit_schema ~remote:false;
    judgment_write_schema;
  ]

let remote_schemas : tool_schema list =
  [
    snapshot_schema ~remote:true;
    digest_schema ~remote:true;
    action_schema ~remote:true;
    confirm_schema;
    surface_audit_schema ~remote:true;
  ]

let remote_tool_names : string list =
  List.map (fun (schema : tool_schema) -> schema.name) remote_schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_operator_snapshot"; "masc_operator_digest"; "masc_surface_audit" ]
let _tool_spec_requires_join = [ "masc_operator_action"; "masc_operator_confirm" ]

(* Tools with explicit catalog metadata that must be preserved. *)
let _tool_spec_hidden = [ "masc_operator_judgment_write"; "masc_surface_audit" ]
let _tool_spec_hidden_destructive = [ "masc_operator_action" ]

let tool_required_permission = function
  | "masc_operator_snapshot" | "masc_operator_digest" | "masc_surface_audit" ->
      Some Types.CanReadState
  | "masc_operator_action" | "masc_operator_confirm"
  | "masc_operator_judgment_write" ->
      Some Types.CanBroadcast
  | _ -> None

let () =
  List.iter
    (fun (s : tool_schema) ->
      let is_destructive = List.mem s.name _tool_spec_hidden_destructive in
      let is_hidden = List.mem s.name _tool_spec_hidden || is_destructive in
      let existing = Tool_catalog.metadata s.name in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_operator
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ~visibility:(if is_hidden then Tool_catalog.Hidden else Tool_catalog.Default)
           ~is_destructive
           ~allow_direct_call_when_hidden:is_hidden
           ?reason:existing.reason
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
