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

(* RFC-0189 PR-1b: typed [Tool_result.result] success helper. Mirrors the
   round-trip-safe [text_ok] pattern introduced in #18767 — if [body] is
   itself a serialized JSON envelope, lift it back into the structured
   [data] field. Plain text falls through as [`String body]. *)
let text_ok ~tool_name ~start_time body : Tool_result.result =
  let data =
    match Tool_result.structured_payload_of_message body with
    | Some json -> json
    | None -> `String body
  in
  Tool_result.make_ok ~tool_name ~start_time ~data ()
;;

let handle_pause ~tool_name ~start_time ctx args : Tool_result.result =
  let reason = get_string args "reason" "Manual pause" in
  Workspace.pause ctx.config ~by:ctx.agent_name ~reason;
  text_ok ~tool_name ~start_time
    (Printf.sprintf "Paused by %s: %s" ctx.agent_name reason)
;;

let handle_resume ~tool_name ~start_time ctx _args : Tool_result.result =
  match Workspace.resume_result ctx.config ~by:ctx.agent_name with
  | Error msg ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time
      (Printf.sprintf "Resume failed: %s" msg)
  | Ok `Resumed ->
    text_ok ~tool_name ~start_time
      (Printf.sprintf "Resumed by %s" ctx.agent_name)
  | Ok `Already_running ->
    text_ok ~tool_name ~start_time "Default project scope is not paused"
;;

let handle_pause_status ~tool_name ~start_time ctx _args : Tool_result.result =
  let workspace_initialized = Workspace.is_initialized ctx.config in
  let keeper_pause =
    if not workspace_initialized
    then
      `Assoc
        [
          ("paused", `Null);
          ("keeper_names_known", `Null);
          ("paused_count", `Null);
          ("paused_names", `List []);
          ("meta_paused_count", `Null);
          ("phase_paused_count", `Null);
          ("keeper_name_discovery_read_error_count", `Int 0);
          ("keeper_name_discovery_read_errors", `List []);
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
  let pause_state_result =
    if not workspace_initialized then Ok `Initializing
    else
      match Workspace.read_state_result ctx.config with
      | Error error -> Error (Workspace.read_state_error_to_string error)
      | Ok state ->
        if state.paused then
          Ok (`Paused (state.paused_by, state.pause_reason, state.paused_at))
        else Ok `Running
  in
  match pause_state_result with
  | Error msg ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Runtime_failure
      ~start_time
      (Printf.sprintf "Pause status failed: %s" msg)
  | Ok pause_state ->
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
  text_ok ~tool_name ~start_time (Yojson.Safe.to_string payload)
;;

(* schemas removed in RFC-0057 PR-1 — masc_pause / masc_resume are emitted
   via Tool_descriptors_gen (Tool_schemas_misc.schemas chain). *)

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

(* RFC-0057 PR-1: control tool schemas now come from
   Tool_descriptors_gen via Tool_schemas_misc.schemas. Filter to the
   two control tools so they register with Mod_control. *)
let () =
  let is_control = function
    | "masc_pause" | "masc_resume" -> true
    | _ -> false
  in
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      if is_control s.name then
        Tool_spec.register
          (Tool_spec.create
             ~name:s.name
             ~description:s.description
             ~module_tag:Tool_dispatch.Mod_control
             ~input_schema:s.input_schema
             ~handler_binding:Tag_dispatch
             ()))
    Tool_schemas_misc.schemas
