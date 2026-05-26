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


(** Tool_inline_dispatch — thin dispatch router for inline tool handlers.

    Delegates to sub-modules:
    - Tool_inline_dispatch_coord: masc_start, masc_join, masc_leave
    - Tool_inline_dispatch_comm: masc_broadcast, masc_messages, masc_who
    - Tool_inline_dispatch_extra: remaining tools (board, etc.)

    Keeps inline: mcp_session, approval, spawn, discover_tools.

    RFC-0062 Phase 4c-2: handlers now return [Tool_result.t] directly;
    [wrap_result] adapter removed. *)

(** Re-export shared types so callers can use
    [Tool_inline_dispatch.context] and [Tool_inline_dispatch.tool_result]
    without knowing about the types sub-module. *)
type tool_result = Tool_inline_dispatch_types.tool_result
type context = Tool_inline_dispatch_types.context = {
  config : Coord.config;
  agent_name : string;
  registry : Session.registry;
  state : Mcp_server.server_state;
  sw : Eio.Switch.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  arguments : Yojson.Safe.t;
  mcp_session_id : string option;
  record_mcp_session_agent : string -> unit;
  wait_for_message :
    Session.registry ->
    agent_name:string ->
    timeout:float ->
    Yojson.Safe.t option;
  governance_defaults : string -> Mcp_server_eio_governance.governance_config;
  save_governance :
    Coord.config -> Mcp_server_eio_governance.governance_config -> unit;
  load_mcp_sessions : Coord.config -> Mcp_server_eio_governance.mcp_session_record list;
  save_mcp_sessions :
    Coord.config -> Mcp_server_eio_governance.mcp_session_record list -> unit;
}

let tool_index_entry_of_schema (schema : Masc_domain.tool_schema)
  : Agent_sdk.Tool_index.entry =
  let group =
    Tool_catalog.tool_group schema.name
    |> Option.map Tool_catalog.tool_group_to_string
  in
  Agent_sdk.Tool_index.
    { name = schema.name; description = schema.description; group; aliases = [] }

let discover_tool_matches ~(query : string) ~(limit : int)
    (schemas : Masc_domain.tool_schema list) =
  let query = String.lowercase_ascii (String.trim query) in
  let limit = max 0 limit in
  if String.equal query "" || limit = 0 then []
  else
    let schema_by_name = Hashtbl.create (List.length schemas) in
    List.iter
      (fun (schema : Masc_domain.tool_schema) ->
         Hashtbl.replace schema_by_name schema.name schema)
      schemas;
    let index_config = { Agent_sdk.Tool_index.default_config with top_k = limit } in
    let index =
      schemas
      |> List.map tool_index_entry_of_schema
      |> Agent_sdk.Tool_index.build ~config:index_config
    in
    Agent_sdk.Tool_index.retrieve index query
    |> List.filter_map (fun (name, score) ->
      match Hashtbl.find_opt schema_by_name name with
      | Some schema -> Some (schema, score)
      | None -> None)

let discover_tools_json ~(query : string) ~(limit : int)
    (schemas : Masc_domain.tool_schema list) : Yojson.Safe.t =
  let query = String.lowercase_ascii (String.trim query) in
  let matches = discover_tool_matches ~query ~limit schemas in
  let results =
    List.map
      (fun ((schema : Masc_domain.tool_schema), score) ->
         `Assoc
           [
             ("name", `String schema.name);
             ("description", `String schema.description);
             ("score", `Float score);
           ])
      matches
  in
  `Assoc
    [
      ("query", `String query);
      ("count", `Int (List.length results));
      ("tools", `List results);
      ("scoring", `String "bm25");
      ( "hint",
        `String
          "These tools are callable via tools/call even if not in the default tools/list."
      );
    ]

module For_testing = struct
  let discover_tools_json = discover_tools_json
end

(* RFC-0189 PR-1b: typed [Tool_result.result] constructors lifted to
   [Tool_result.t] at the dispatch boundary so [dispatch]'s
   [Tool_result.t option] return type stays compatible with the sole
   external caller [Mcp_server_eio_execute].  Two patterns:

   - [inline_ok] handles both plain-text and JSON-string success bodies.
     [structured_payload_of_message] lifts JSON envelopes into [data];
     plain strings fall through as [`String body].  Matches the canonical
     pattern from #18767 so callers that round-trip through
     [result.message] still see the original body.
   - [inline_err_workflow] commits caller-input rejections to
     [Workflow_rejection]: every error path in this dispatch
     ("id is required", unknown enum action, "query is required",
     not-found lookups, approval-resolve errors) is caller-side. *)
let inline_ok ~tool_name ~start_time body : Tool_result.t =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.to_legacy
    (Tool_result.make_ok ~tool_name ~start_time ~data ())
;;

let inline_err_workflow ~tool_name ~start_time msg : Tool_result.t =
  Tool_result.to_legacy
    (Tool_result.make_err
       ~tool_name
       ~class_:Tool_result.Workflow_rejection
       ~start_time
       msg)
;;

(** Dispatch a tool call.
    Returns [Some (Tool_result.t)] if the tool name is handled,
    [None] if the tool name is not recognized by this module. *)
let dispatch (ctx : context) ~(name : string) : Tool_result.t option =
  let start = Time_compat.now () in
  let config = ctx.config in
  let agent_name = ctx.agent_name in
  let state = ctx.state in
  let sw = ctx.sw in
  let clock = ctx.clock in
  let arguments = ctx.arguments in

  (* Argument extraction helpers — delegate to Safe_ops *)
  let arg_get_string key default =
    Safe_ops.json_string ~default key arguments
  in
  let arg_get_int key default =
    Safe_ops.json_int ~default key arguments
  in
  let _arg_get_bool key default =
    Safe_ops.json_bool ~default key arguments
  in
  let _arg_get_string_list key =
    Safe_ops.json_string_list key arguments
  in
  let arg_get_string_opt key =
    match Safe_ops.json_string_opt key arguments with
    | Some "" -> None
    | other -> other
  in
  let _arg_get_string_required key =
    Tool_args.get_string_required arguments key
  in
  let _arg_get_int_opt _key = () in  (* unused but kept for symmetry *)
  let _arg_get_float_opt key =
    Safe_ops.json_float_opt key arguments
  in

  match name with
  (* ── Coord lifecycle (delegated) ─────────────────────────────── *)
  (* RFC-0189 PR-1b.15: Tool_inline_dispatch_coord handlers return
     Tool_result.result option; lift to legacy at this boundary so
     dispatch's Tool_result.t option signature is preserved for the
     external caller (Mcp_server_eio_execute). *)
  | "masc_start" ->
      Tool_inline_dispatch_coord.handle_start ~tool_name:name ~start_time:start ctx
      |> Option.map Tool_result.to_legacy
  | "masc_join" ->
      Tool_inline_dispatch_coord.handle_join ~tool_name:name ~start_time:start ctx
      |> Option.map Tool_result.to_legacy
  | "masc_leave" ->
      Tool_inline_dispatch_coord.handle_leave ~tool_name:name ~start_time:start ctx
      |> Option.map Tool_result.to_legacy

  (* ── Communication (delegated) ──────────────────────────────── *)
  | "masc_broadcast" ->
      Tool_inline_dispatch_comm.handle_broadcast ~tool_name:name ~start_time:start ctx
  | "masc_messages" ->
      Tool_inline_dispatch_comm.handle_messages ~tool_name:name ~start_time:start ctx
  | "masc_who" ->
      Tool_inline_dispatch_comm.handle_who ~tool_name:name ~start_time:start ctx

  (* ── Approval queue (#5907) ─────────────────────────────────── *)
  | "masc_approval_pending" ->
      let json = Keeper_approval_queue.list_pending_json () in
      Some (inline_ok ~tool_name:name ~start_time:start (Yojson.Safe.to_string json))
  | "masc_approval_get" ->
      let id = arg_get_string "id" "" in
      if String.equal id "" then Some (inline_err_workflow ~tool_name:name ~start_time:start "id is required")
      else
        (match Keeper_approval_queue.get_pending_json ~id with
         | Some json -> Some (inline_ok ~tool_name:name ~start_time:start (Yojson.Safe.to_string json))
         | None ->
           Some (inline_err_workflow ~tool_name:name ~start_time:start
             (Printf.sprintf
               "approval %s is no longer pending or was not found. Refresh with masc_approval_pending before approving/rejecting."
               id)))
  | "masc_approval_resolve" ->
      let id = arg_get_string "id" "" in
      let decision_str = arg_get_string "decision" "approve" in
      if String.equal id "" then Some (inline_err_workflow ~tool_name:name ~start_time:start "id is required")
      else
        let decision = match String.lowercase_ascii decision_str with
          | "approve" -> Agent_sdk.Hooks.Approve
          | "reject" ->
            let reason = arg_get_string "reason" "operator rejected" in
            Agent_sdk.Hooks.Reject reason
          | _ -> Agent_sdk.Hooks.Reject (Printf.sprintf "unknown decision: %s" decision_str)
        in
        (match Keeper_approval_queue.resolve ~id ~decision with
         | Ok () ->
           Some (inline_ok ~tool_name:name ~start_time:start
             (Printf.sprintf "{\"resolved\":\"%s\",\"decision\":\"%s\"}" id decision_str))
         | Error err ->
           Some (inline_err_workflow ~tool_name:name ~start_time:start
             (Keeper_approval_queue.resolve_error_to_string err)))

  (* Verification tools removed: pruned *)

  (* ── MCP Session ────────────────────────────────────────────── *)
  | "masc_mcp_session" ->
      (* Issue #8520: parse via Mcp_session.action_of_string_opt;
         dispatch via exhaustive match on the Variant — adding a 6th
         action will fail compilation here, not silently break. *)
      let raw = arg_get_string "action" "" in
      (match Mcp_session.action_of_string_opt raw with
       | None ->
         Some (inline_err_workflow ~tool_name:name ~start_time:start
           (Printf.sprintf
             "action must be one of [%s]; got %S"
             (String.concat "|" Mcp_session.valid_action_strings) raw))
       | Some action ->
      let now = Time_compat.now () in
      let sessions = ctx.load_mcp_sessions config in
      let save sessions = ctx.save_mcp_sessions config sessions in
      let response =
        match action with
        | Mcp_session.Create ->
            let agent_name = arg_get_string_opt "agent_name" in
            let id = Mcp_session.generate () in
            let record : Mcp_server_eio_governance.mcp_session_record =
              { id; agent_name; created_at = now; last_seen = now } in
            save (record :: sessions);
            Ok (`Assoc [
              ("status", `String "created");
              ("session", Mcp_server_eio_governance.mcp_session_to_json record);
            ])
        | Mcp_session.Get ->
            let session_id = arg_get_string "session_id" "" in
            (match List.find_opt (fun (s : Mcp_server_eio_governance.mcp_session_record) -> String.equal s.id session_id) sessions with
             | None -> Error (Printf.sprintf "MCP session '%s' not found" session_id)
             | Some s ->
                 let updated = { s with last_seen = now } in
                 let others = List.filter (fun (x : Mcp_server_eio_governance.mcp_session_record) -> not (String.equal x.id session_id)) sessions in
                 save (updated :: others);
                 Ok (Tool_args.ok_assoc [
                   ("session", Mcp_server_eio_governance.mcp_session_to_json updated);
                 ]))
        | Mcp_session.List ->
            Ok (`Assoc [
              ("count", `Int (List.length sessions));
              ("sessions", `List (List.map Mcp_server_eio_governance.mcp_session_to_json sessions));
            ])
        | Mcp_session.Cleanup ->
            let cutoff = now -. Masc_time_constants.days_to_seconds 7 in
            let remaining = List.filter (fun (s : Mcp_server_eio_governance.mcp_session_record) -> Stdlib.Float.compare s.last_seen cutoff >= 0) sessions in
            let removed = List.length sessions - List.length remaining in
            save remaining;
            Ok (`Assoc [
              ("status", `String "cleaned");
              ("removed", `Int removed);
              ("remaining", `Int (List.length remaining));
            ])
        | Mcp_session.Remove ->
            let session_id = arg_get_string "session_id" "" in
            let remaining = List.filter (fun (s : Mcp_server_eio_governance.mcp_session_record) -> not (String.equal s.id session_id)) sessions in
            if List.length remaining = List.length sessions then
              Error (Printf.sprintf "MCP session '%s' not found" session_id)
            else begin
              save remaining;
              Ok (`Assoc [
                ("status", `String "removed");
                ("session_id", `String session_id);
              ])
            end
      in
      (match response with
       | Ok json -> Some (inline_ok ~tool_name:name ~start_time:start (Yojson.Safe.to_string json))
       | Error e -> Some (inline_err_workflow ~tool_name:name ~start_time:start e)))

  (* Infrastructure tools: cancellation, subscription, progress,
     governance_set, masc_spawn removed — pruned from surfaces *)

  (* ── Tool discovery ─────────────────────────────────────────── *)
  | "masc_discover_tools" ->
      let query = arg_get_string "query" "" in
      let limit = arg_get_int "limit" 20 in
      if String.equal (String.trim query) "" then
        Some (inline_err_workflow ~tool_name:name ~start_time:start "query is required")
      else
        let all_schemas = Config.visible_tool_schemas ~include_hidden:true () in
        let payload = discover_tools_json ~query ~limit all_schemas in
        Some (inline_ok ~tool_name:name ~start_time:start (Yojson.Safe.to_string payload))

  (* ── Fallthrough to extra dispatch ──────────────────────────── *)
  | _ ->
      Tool_inline_dispatch_extra.dispatch ~config ~agent_name ~arguments ~state ~sw ~clock ~name ~start_time:start

(* ================================================================ *)
(* Tool_spec registration (RFC-0182 §3.2)                           *)
(* ================================================================ *)

(* Migrates the inline-dispatched coord + approval tools from the legacy
   register_module_tag bootstrap (mcp_server_eio.ml) to the Tool_spec
   single-call SSOT. Scope: 6 of 10 §3.2 live tools.

   Excluded (deferred, semantic-widening would be required):
   - [masc_approval_resolve], [masc_set_param], [channel_gate] —
     no Masc_domain.tool_schema record exists. They are dispatched via
     HTTP routes / inline arms but never advertised to MCP. Promoting
     them to Tool_spec.register requires authoring new input schemas
     (and for [masc_set_param] / [channel_gate], deciding visibility
     semantics for MCP exposure). Tracked as RFC-0182 follow-up scope.
   - [masc_tool_revoke] — already registered via Tool_shard schemas
     (lib/tool_shard.ml:348). Audit row was a false positive. *)

let inline_register_targets =
  [ "masc_join"; "masc_leave"; "masc_broadcast"; "masc_messages"
  ; "masc_approval_get"; "masc_approval_pending" ]

let inline_tool_required_permission name : Masc_domain.permission option =
  match name with
  | "masc_join" -> Some Masc_domain.CanJoin
  | "masc_leave" -> Some Masc_domain.CanLeave
  | "masc_broadcast" -> Some Masc_domain.CanBroadcast
  | "masc_messages" -> Some Masc_domain.CanReadState
  | "masc_approval_get" -> Some Masc_domain.CanAdmin
  | "masc_approval_pending" -> Some Masc_domain.CanReadState
  | _ -> None

let inline_tool_read_only =
  [ "masc_messages"; "masc_approval_get"; "masc_approval_pending" ]

let inline_tool_requires_join = [ "masc_leave"; "masc_broadcast" ]

let inline_tool_requires_actor_binding = [ "masc_join"; "masc_leave" ]

let inline_tool_mcp_context_required =
  [ "masc_join"; "masc_leave"; "masc_broadcast"; "masc_messages"; "masc_approval_get" ]

let inline_tool_effect_domain name : Tool_catalog.effect_domain =
  if List.mem name inline_tool_read_only then Tool_catalog.Read_only
  else Tool_catalog.Masc_coordination

let () =
  inline_register_targets
  |> List.iter (fun name ->
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
        Tool_schemas_inline.schemas
    with
    | None -> ()
    | Some (schema : Masc_domain.tool_schema) ->
      let is_read_only = List.mem name inline_tool_read_only in
      Tool_spec.register
        (Tool_spec.create
           ~name:schema.name
           ~description:schema.description
           ~module_tag:Tool_dispatch.Mod_inline
           ~input_schema:schema.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only
           ~is_idempotent:is_read_only
           ~requires_join:(List.mem name inline_tool_requires_join)
           ~mcp_context_required:(List.mem name inline_tool_mcp_context_required)
           ~requires_actor_binding:(List.mem name inline_tool_requires_actor_binding)
           ~effect_domain:(inline_tool_effect_domain name)
           ?required_permission:(inline_tool_required_permission name)
           ()))
