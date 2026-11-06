(** Tool_control - Flow control operations

    Handles: pause_status
*)

type context = {
  config: Workspace.config;
  agent_name: string;
}

(* Handlers *)

(* What [masc_pause_status] answers, before it becomes JSON. Both cases fill
   the same fields and [pause_status_reply_json] writes them as one object, so
   the cases can differ only in values, never in keys. *)
type pause_status_reply =
  { initializing : bool
  ; status : string
  ; message : string
  }

let pause_status_reply_json ~keeper_pause reply =
  `Assoc
    [ ("ok", `Bool true)
    ; ("initializing", `Bool reply.initializing)
    ; ("status", `String reply.status)
    ; ("keeper_pause", keeper_pause)
    ; ("message", `String reply.message)
    ]

let handle_pause_status ~tool_name ~start_time ctx _args : Tool_result.result =
  match Pause_status_backend.keeper_pause_status ctx.config with
  | Error detail ->
    Tool_result.error ~failure_class:Tool_result.Runtime_failure
      ~tool_name ~start_time detail
  | Ok keeper_pause_status ->
  let reply =
    match keeper_pause_status with
    | Pause_status_backend.Workspace_not_initialized ->
      { initializing = true
      ; status = "initializing"
      ; message = "Server is initializing; pause state is not available yet"
      }
    | Pause_status_backend.Census { paused_names; _ } ->
      { initializing = false
      ; status = "running"
      ; message =
          (if paused_names <> []
           then "Server is running, but one or more keepers are paused"
           else "Server is running; no keeper is paused")
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
