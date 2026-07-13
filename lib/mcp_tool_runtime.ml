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


(** Mcp_tool_runtime — MCP server-local tool runtime.

    Delegates to sub-modules:
    - Mcp_tool_runtime_workspace: masc_start
    - Mcp_tool_runtime_comm: masc_broadcast, masc_messages
    - Mcp_tool_runtime_board: remaining tools (board, etc.)

    Keeps MCP-only server helpers that need per-request server state.

    RFC-0062 Phase 4c-2: handlers now return [Tool_result.result] directly;
    [wrap_result] adapter removed. *)

(** Re-export shared types so callers can use
    [Mcp_tool_runtime.context] and [Mcp_tool_runtime.tool_result]
    without knowing about the types sub-module. *)
type tool_result = Mcp_tool_runtime_types.tool_result
type context = Mcp_tool_runtime_types.context = {
  config : Workspace.config;
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
  load_mcp_sessions : Workspace.config -> Mcp_session_store.mcp_session_record list;
  save_mcp_sessions :
    Workspace.config -> Mcp_session_store.mcp_session_record list -> unit;
}

(* RFC-0189 PR-2: MCP runtime helpers return [Tool_result.result] directly.
   Two patterns:

   - [runtime_ok] handles both plain-text and JSON-string success bodies.
     [structured_payload_of_message] lifts JSON envelopes into [data];
     plain strings fall through as [`String body].
   - [runtime_err_workflow] commits caller-input rejections to
     [Workflow_rejection]: every error path in this dispatch
     ("id is required", unknown enum action, not-found lookups) is
     caller-side. *)
let runtime_ok ~tool_name ~start_time body : Tool_result.result =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.make_ok ~tool_name ~start_time ~data ()
;;

let runtime_err_workflow ~tool_name ~start_time msg : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    msg
;;

(** Dispatch a tool call.
    Returns [Some (Tool_result.result)] if the tool name is handled,
    [None] if the tool name is not recognized by this module. *)
let dispatch (ctx : context) ~(name : string) : Tool_result.result option =
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
  (* ── Workspace lifecycle (delegated) ─────────────────────────────── *)
  | "masc_start" ->
      Mcp_tool_runtime_workspace.handle_start ~tool_name:name ~start_time:start ctx

  (* ── Communication (delegated) ──────────────────────────────── *)
  | "masc_broadcast" ->
      Mcp_tool_runtime_comm.handle_broadcast ~tool_name:name ~start_time:start ctx
  | "masc_messages" ->
      Mcp_tool_runtime_comm.handle_messages ~tool_name:name ~start_time:start ctx

  (* Verification tools removed: pruned *)

  (* ── MCP Session ────────────────────────────────────────────── *)
  | "masc_session" ->
      (* Issue #8520: parse via Mcp_session.action_of_string_opt;
         dispatch via exhaustive match on the Variant — adding a 6th
         action will fail compilation here, not silently break. *)
      let raw = arg_get_string "action" "" in
      (match Mcp_session.action_of_string_opt raw with
       | None ->
         Some (runtime_err_workflow ~tool_name:name ~start_time:start
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
            let record : Mcp_session_store.mcp_session_record =
              { id; agent_name; created_at = now; last_seen = now } in
            save (record :: sessions);
            Ok (`Assoc [
              ("status", `String "created");
              ("session", Mcp_session_store.mcp_session_to_json record);
            ])
        | Mcp_session.Get ->
            let session_id = arg_get_string "session_id" "" in
            (match List.find_opt (fun (s : Mcp_session_store.mcp_session_record) -> String.equal s.id session_id) sessions with
             | None -> Error (Printf.sprintf "MCP session '%s' not found" session_id)
             | Some s ->
                 let updated = { s with last_seen = now } in
                 let others = List.filter (fun (x : Mcp_session_store.mcp_session_record) -> not (String.equal x.id session_id)) sessions in
                 save (updated :: others);
                 Ok (Tool_args.ok_assoc [
                   ("session", Mcp_session_store.mcp_session_to_json updated);
                 ]))
        | Mcp_session.List ->
            Ok (`Assoc [
              ("count", `Int (List.length sessions));
              ("sessions", `List (List.map Mcp_session_store.mcp_session_to_json sessions));
            ])
        | Mcp_session.Cleanup ->
            let cutoff = now -. Masc_time_constants.days_to_seconds 7 in
            let remaining = List.filter (fun (s : Mcp_session_store.mcp_session_record) -> Stdlib.Float.compare s.last_seen cutoff >= 0) sessions in
            let removed = List.length sessions - List.length remaining in
            save remaining;
            Ok (`Assoc [
              ("status", `String "cleaned");
              ("removed", `Int removed);
              ("remaining", `Int (List.length remaining));
            ])
        | Mcp_session.Remove ->
            let session_id = arg_get_string "session_id" "" in
            let remaining = List.filter (fun (s : Mcp_session_store.mcp_session_record) -> not (String.equal s.id session_id)) sessions in
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
       | Ok json -> Some (runtime_ok ~tool_name:name ~start_time:start (Yojson.Safe.to_string json))
       | Error e -> Some (runtime_err_workflow ~tool_name:name ~start_time:start e)))

  (* ── Fallthrough to extra dispatch ──────────────────────────── *)
  | _ ->
      Mcp_tool_runtime_board.dispatch ~config ~agent_name ~arguments ~state ~sw ~clock ~name ~start_time:start

(* ================================================================ *)
(* Tool_spec registration (RFC-0182 §3.2)                           *)
(* ================================================================ *)

(* Migrates MCP server-local workspace tools from the legacy
   register_module_tag bootstrap (mcp_server_eio.ml) to the Tool_spec
   single-call SSOT.

   Excluded (deferred, semantic-widening would be required):
   - [masc_set_param], [channel_gate] —
     no Masc_domain.tool_schema record exists. They are dispatched via
     HTTP routes / MCP runtime arms but never advertised to MCP. Promoting
     them to Tool_spec.register requires authoring new input schemas
     and deciding visibility semantics for MCP exposure. Tracked as
     RFC-0182 follow-up scope.
   The retired [masc_tool_*] shard-management tools are intentionally absent
   from this list and from the MCP ToolSpec surface. *)

let runtime_register_targets =
  [ "masc_broadcast"; "masc_messages" ]

let runtime_tool_read_only =
  [ "masc_messages" ]

let runtime_tool_mcp_context_required =
  [ "masc_broadcast"; "masc_messages" ]

let () =
  runtime_register_targets
  |> List.iter (fun name ->
    match
      List.find_opt
        (fun (s : Masc_domain.tool_schema) -> String.equal s.name name)
        Tool_schemas_inline.schemas
    with
    | None -> ()
    | Some (schema : Masc_domain.tool_schema) ->
      let is_read_only = List.mem name runtime_tool_read_only in
      Tool_spec.register
        (Tool_spec.create
           ~name:schema.name
           ~description:schema.description
           ~module_tag:Tool_dispatch.Mod_inline
           ~input_schema:schema.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only
           ~is_idempotent:is_read_only
           ~mcp_context_required:(List.mem name runtime_tool_mcp_context_required)
           ()))
