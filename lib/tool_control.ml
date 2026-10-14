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

(* What [masc_pause_status] answers, before it becomes JSON. Every case fills
   the same fields and [pause_status_reply_json] writes them as one object, so
   the cases can differ only in values, never in keys. *)
type pause_status_reply =
  { initializing : bool
  ; status : string
  ; paused : bool option
  ; paused_by : string option
  ; pause_reason : string option
  ; paused_at : string option
  ; any_pause_active : bool option
  ; message : string
  }

let pause_status_reply_json ~keeper_pause reply =
  `Assoc
    [ ("ok", `Bool true)
    ; ("initializing", `Bool reply.initializing)
    ; ("status", `String reply.status)
    ; ("paused", Json_util.bool_opt_to_json reply.paused)
    ; ("paused_by", Json_util.string_opt_to_json reply.paused_by)
    ; ("pause_reason", Json_util.string_opt_to_json reply.pause_reason)
    ; ("paused_at", Json_util.string_opt_to_json reply.paused_at)
    ; ("any_pause_active", Json_util.bool_opt_to_json reply.any_pause_active)
    ; ("keeper_pause", keeper_pause)
    ; ("message", `String reply.message)
    ]

let handle_pause_status ~tool_name ~start_time ctx _args : Tool_result.result =
  match Pause_status_backend.keeper_pause_status ctx.config with
  | Error detail ->
    Tool_result.error ~failure_class:Tool_result.Runtime_failure
      ~tool_name ~start_time detail
  | Ok keeper_pause_status ->
  (* The census already says whether the workspace is initialised; asking
     [Workspace] again could answer differently within one call. *)
  let reply =
    match keeper_pause_status with
    | Pause_status_backend.Workspace_not_initialized ->
      { initializing = true
      ; status = "initializing"
      ; paused = None
      ; paused_by = None
      ; pause_reason = None
      ; paused_at = None
      ; any_pause_active = None
      ; message = "Server is initializing; pause state is not available yet"
      }
    | Pause_status_backend.Census { paused_names; _ } ->
      let state = Workspace.read_state ctx.config in
      if state.paused then
        { initializing = false
        ; status = "paused"
        ; paused = Some true
        ; paused_by = state.paused_by
        ; pause_reason = state.pause_reason
        ; paused_at = state.paused_at
        ; any_pause_active = Some true
        ; message = "Server is paused"
        }
      else
        let keeper_paused = paused_names <> [] in
        { initializing = false
        ; status = "running"
        ; paused = Some false
        ; paused_by = None
        ; pause_reason = None
        ; paused_at = None
        ; any_pause_active = Some keeper_paused
        ; message =
            (if keeper_paused
             then "Server is running, but one or more keepers are paused"
             else "Server is running (not paused)")
        }
  in
  let keeper_pause = Pause_status_backend.keeper_pause_status_to_json keeper_pause_status in
  Tool_result.make_ok ~tool_name ~start_time
    ~data:(pause_status_reply_json ~keeper_pause reply) ()
;;

(* Schemas are generated from the RFC-0057 specs and projected through
   [Tool_schemas_misc.control_schemas]. *)

(* Dispatch function *)
(* Resolved against the same control schemas registration walks, so an
   operation added to [Tool_schemas_misc.control_operation] is a compile error
   here rather than an advertised name with no route. *)
let find_operation name =
  List.find_opt
    (fun operation ->
      String.equal (Tool_schemas_misc.control_schema operation).name name)
    Tool_schemas_misc.control_operations

let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Tool_timing.start () in
  match find_operation name with
  | None -> None
  | Some Tool_schemas_misc.Pause ->
    Some (handle_pause ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_misc.Resume ->
    Some (handle_resume ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_misc.Pause_status ->
    Some (handle_pause_status ~tool_name:name ~start_time:start ctx args)
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
