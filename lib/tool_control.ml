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

(** Tool_control - Flow control operations

    Handles: pause, pause_status, resume
*)

open Tool_args

type context = {
  config: Workspace.config;
  agent_name: string;
}

(* Handlers *)

(* Plain-text success remains opaque. Typed producers pass [~data] directly. *)
let text_ok ~tool_name ~start_time body : Tool_result.result =
  Tool_result.ok ~tool_name ~start_time body
;;

let handle_pause ~tool_name ~start_time ctx args : Tool_result.result =
  let reason = get_string args "reason" "Manual pause" in
  Workspace.pause ctx.config ~by:ctx.agent_name ~reason;
  text_ok ~tool_name ~start_time
    (Printf.sprintf "Paused by %s: %s" ctx.agent_name reason)
;;

let handle_resume ~tool_name ~start_time ctx _args : Tool_result.result =
  match Workspace.resume ctx.config ~by:ctx.agent_name with
  | `Resumed ->
    text_ok ~tool_name ~start_time
      (Printf.sprintf "Resumed by %s" ctx.agent_name)
  | `Already_running ->
    text_ok ~tool_name ~start_time "Default project scope is not paused"
;;

let handle_pause_status ~tool_name ~start_time ctx _args : Tool_result.result =
  let keeper_pause =
    if not (Workspace.is_initialized ctx.config)
    then
      `Assoc
        [
          ("paused", `Null);
          ("paused_count", `Null);
          ("paused_names", `List []);
          ("meta_paused_count", `Null);
          ("phase_paused_count", `Null);
          ("read_errors", `List []);
        ]
    else Pause_status_backend.keeper_pause_status_json ctx.config
  in
  let keeper_paused =
    match keeper_pause with
    | `Assoc fields -> (
      match List.assoc_opt "paused" fields with
      | Some (`Bool value) -> value
      | _ -> false)
    | _ -> false
  in
  let pause_state =
    if not (Workspace.is_initialized ctx.config) then `Initializing
    else
      let state = Workspace.read_state ctx.config in
      if state.paused then
        `Paused (state.paused_by, state.pause_reason, state.paused_at)
      else `Running
  in
  let payload =
    match pause_state with
    | `Paused (by, reason, at) ->
        `Assoc
          [
            ("ok", `Bool true);
            ("initializing", `Bool false);
            ("status", `String "paused");
            ("paused", `Bool true);
            ("paused_by", Json_util.string_opt_to_json by);
            ("pause_reason", Json_util.string_opt_to_json reason);
            ("paused_at", Json_util.string_opt_to_json at);
            ("pause_scope", `String "workspace");
            ("any_pause_active", `Bool true);
            ("keeper_pause", keeper_pause);
            ("message", `String "Server is paused");
          ]
    | `Running ->
        `Assoc
          [
            ("ok", `Bool true);
            ("initializing", `Bool false);
            ("status", `String "running");
            ("paused", `Bool false);
            ("paused_by", `Null);
            ("pause_reason", `Null);
            ("paused_at", `Null);
            ("pause_scope", `String "workspace");
            ("any_pause_active", `Bool keeper_paused);
            ("keeper_pause", keeper_pause);
            ( "message",
              `String
                (if keeper_paused
                 then "Server is running, but one or more keepers are paused"
                 else "Server is running (not paused)") );
          ]
    | `Initializing ->
        `Assoc
          [
            ("ok", `Bool true);
            ("initializing", `Bool true);
            ("status", `String "initializing");
            ("paused", `Null);
            ("paused_by", `Null);
            ("pause_reason", `Null);
            ("paused_at", `Null);
            ("pause_scope", `String "workspace");
            ("any_pause_active", `Null);
            ("keeper_pause", keeper_pause);
            ( "message",
              `String
                "Server is initializing; pause state is not available yet" );
          ]
  in
  Tool_result.make_ok ~tool_name ~start_time ~data:payload ()
;;

(* Schemas are generated from the RFC-0057 specs and projected through
   [Tool_schemas_misc.control_schemas]. *)

(* Dispatch function *)
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  match name with
  | "masc_pause" ->
    Some (handle_pause ~tool_name:name ~start_time:start ctx args)
  | "masc_resume" ->
    Some (handle_resume ~tool_name:name ~start_time:start ctx args)
  | "masc_pause_status" ->
    Some (handle_pause_status ~tool_name:name ~start_time:start ctx args)
  | _ -> None
;;

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

(* Control schemas have a dedicated typed projection because they must remain
   registered with [Mod_control] while staying outside Config's public/front-door
   inventory. *)
let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_control
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ()))
    Tool_schemas_misc.control_schemas
