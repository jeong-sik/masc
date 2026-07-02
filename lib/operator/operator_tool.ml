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

open Masc_domain
open Tool_args

type tool_result = Tool_result.result

type 'a context = 'a Tool_operator.context


(* RFC-0189 PR-1b.11 — typed result.

   [result_of_json] projects [Operator_control.*_json :
   ... -> (Yojson.Safe.t, string) result] into the typed surface.

   Success: [json] is the operator response envelope as
   [Yojson.Safe.t]; passing it as [~data:json] keeps the structured
   payload first-class.

   Failure: wrapped through [Tool_args.error_response] (the legacy
   JSON envelope shape). Class is [Workflow_rejection] — the
   operator control plane rejects caller-side input (unknown
   action, target not found, schema violation). When
   [Operator_control] later distinguishes runtime / transient
   failures via a typed Error variant, the construction site here
   gets the appropriate class at that time. *)

let envelope_data envelope : Yojson.Safe.t =
  match Tool_result.structured_payload_of_message envelope with
  | Some json -> json
  | None -> `String envelope

let result_of_json ~tool_name ~start_time = function
  | Ok json ->
      Tool_result.make_ok ~tool_name ~start_time ~data:json ()
  | Error message ->
      let envelope = Tool_args.error_response message in
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        ~data:(envelope_data envelope)
        envelope

let json_ok ~tool_name ~start_time (json : Yojson.Safe.t) : Tool_result.result =
  Tool_result.make_ok ~tool_name ~start_time ~data:json ()

let schema_properties entries = `Assoc entries

let strict_action_enums =
  [
    `String "broadcast";
    `String "namespace_pause";
    `String "namespace_resume";
    `String "social_sweep";
    `String "task_inject";
    `String "keeper_message";
    `String "keeper_probe";
    `String "keeper_recover";
  ]

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

let digest_target_type_enums = [ `String "root" ]
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
                      ("enum", `List strict_action_enums);
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

let dispatch (ctx : 'a context) ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  Log.Misc.debug "operator_dispatch: tool=%s agent=%s" name ctx.agent_name;
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
        (json_ok ~tool_name:name ~start_time:start
           (Operator_control.snapshot_json ?actor ?view ~include_messages
              ~include_keepers control_ctx))
  | "masc_operator_digest" ->
      let actor = get_string_opt args "actor" in
      let target_type = get_string_opt args "target_type" in
      let target_id = get_string_opt args "target_id" in
      let include_workers = get_bool args "include_workers" true in
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.digest_json ?actor ?target_type ?target_id
              ~include_workers control_ctx))
  | "masc_operator_action" ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.action_json control_ctx args))
  | "masc_operator_confirm" ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.confirm_json control_ctx args))
  | "masc_surface_audit" ->
      let surface_id = get_string_opt args "surface_id" in
      Some
        (json_ok
           ~tool_name:name
           ~start_time:start
           (Dashboard_surface_readiness.json ?surface_id ()))
  | "masc_operator_judgment_write" ->
      Some
        (result_of_json ~tool_name:name ~start_time:start
           (Operator_control.judgment_write_json control_ctx args))
  | _ ->
      Log.Misc.warn "operator_dispatch_unknown: tool=%s agent=%s" name ctx.agent_name;
      None

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

module Operator_remote_name = Tool_name.Operator_remote_name
module Operator_name = Tool_name.Operator_name

let remote_tool_names : string list = Operator_remote_name.all_strings
let operator_remote_tool_name name = Operator_remote_name.to_string name
let operator_tool_name name = operator_remote_tool_name (Operator_remote_name.Operator_tool name)
let surface_audit_tool_name = operator_remote_tool_name Operator_remote_name.Surface_audit

(* ================================================================ *)
(* Catalog metadata registration                                    *)
(* ================================================================ *)

let tool_spec_read_only =
  [
    operator_tool_name Operator_name.Operator_snapshot;
    operator_tool_name Operator_name.Operator_digest;
    surface_audit_tool_name;
  ]

(* Tools with explicit catalog metadata that must be preserved. *)
let tool_spec_hidden = [ "masc_operator_judgment_write"; surface_audit_tool_name ]
let tool_spec_hidden_destructive = [ operator_tool_name Operator_name.Operator_action ]

let register_catalog_metadata_only (s : tool_schema) =
  let is_read_only = List.mem s.name tool_spec_read_only in
  let is_destructive = List.mem s.name tool_spec_hidden_destructive in
  let is_hidden = List.mem s.name tool_spec_hidden || is_destructive in
  let existing = Tool_catalog.metadata s.name in
  Tool_catalog.register_metadata s.name
    { Tool_catalog.visibility = (if is_hidden then Tool_catalog.Hidden else Tool_catalog.Default)
    ; lifecycle = Tool_catalog.Active
    ; implementation_status = Tool_catalog.Real
    ; canonical_name = None
    ; replacement = None
    ; reason = existing.reason
    ; allow_direct_call_when_hidden = is_hidden
    ; readonly = Some is_read_only
    ; mcp_context_required = Some false
    ; destructive = Some is_destructive
    ; idempotent = Some is_read_only
    ; effect_domain = None
    ; requires_actor_binding = existing.requires_actor_binding
    }
;;

let () =
  List.iter register_catalog_metadata_only schemas

let () =
  Tool_operator.register_operator_tools ~dispatch ~schemas ~remote_schemas;
  Dashboard_briefing_sections.register_operator_snapshot_json { Dashboard_projection_cache.snapshot = Operator_control.snapshot_json };
  Dashboard_projection_cache.register_operator_snapshot_json { Dashboard_projection_cache.snapshot = Operator_control.snapshot_json };
  Dashboard_projection_cache.register_operator_digest_json { Dashboard_projection_cache.digest = Operator_control.digest_json };
  Dashboard_operator_judge.register_record_operator_judgment
    (fun config ~surface ~target_type_str ~target_id ~summary ~confidence
         ?model_name ?recommended_action ~evidence_refs ~disagreement_with_truth
         ~generated_at ~generated_at_unix ~fresh_until ~fresh_until_unix ~keeper_name () ->
      let target_type =
        match String.lowercase_ascii target_type_str with
        | "workspace" | "namespace" -> Operator_judgment.Workspace
        | other -> invalid_arg ("invalid target_type in judgment record: " ^ other)
      in
      ignore (
        Operator_judgment.record config ~surface ~target_type ~target_id ~summary
          ~confidence ?model_name ?recommended_action ~evidence_refs
          ~disagreement_with_truth ~generated_at ~generated_at_unix ~fresh_until
          ~fresh_until_unix ~keeper_name ()
      ));
  Atomic.set
    Workspace_hooks.operator_pending_confirm_trace_id_fn
    Operator_pending_confirm.trace_id;
  Atomic.set
    Workspace_hooks.operator_pending_confirm_upsert_fn
    (fun config (entry : Workspace_hooks.operator_pending_confirm_request) ->
      Operator_pending_confirm.upsert_pending_confirm
        config
        { token = entry.token
        ; trace_id = entry.trace_id
        ; actor = entry.actor
        ; action_type = entry.action_type
        ; target_type = entry.target_type
        ; target_id = entry.target_id
        ; payload = entry.payload
        ; delegated_tool = entry.delegated_tool
        ; created_at = entry.created_at
        ; expires_at = entry.expires_at
        });
  Atomic.set
    Workspace_hooks.operator_pending_confirm_remove_fn
    Operator_pending_confirm.remove_pending_confirm;
  Keeper_turn_lifecycle.register_remove_pending_confirms_by_target
    Operator_pending_confirm.remove_pending_confirms_by_target
;;

let force_link = ()
