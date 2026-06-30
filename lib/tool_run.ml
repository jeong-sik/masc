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

(** Run Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    4 tools: run_init, run_plan, run_get, run_list
*)

(** Tool handler context *)
type context = {
  config: Workspace.config;
  agent_name: string option;
}

open Tool_args

(** {1 Individual Handlers} *)

(* RFC-0189 PR-1b.6 — handlers in this module return typed
   [Tool_result.result]. Run_eio is the persistence layer; its Error
   cases are opaque "Failed to ..." (Runtime_failure). The
   "task_id is required" caller-input rejections are Workflow_rejection.

   JSON responses flow as typed [~data:json] directly. *)

let task_id_required ~tool_name ~start_time : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    "task_id is required"

let handle_run_init ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  if String.equal task_id "" then
    task_id_required ~tool_name ~start_time
  else
    let agent = get_string_opt args "agent_name" in
    match Run_eio.init ctx.config ~task_id ~agent_name:agent with
  | Ok run ->
      Tool_result.make_ok ~tool_name ~start_time ~data:(Run_eio.run_record_to_json run) ()
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf "Failed to init run: %s" e)

let handle_run_plan ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  if String.equal task_id "" then
    task_id_required ~tool_name ~start_time
  else
    let plan = get_string args "plan" "" in
    match Run_eio.update_plan ctx.config ~task_id ~content:plan with
  | Ok run ->
      Tool_result.make_ok ~tool_name ~start_time ~data:(Run_eio.run_record_to_json run) ()
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf "Failed to update run plan: %s" e)

let handle_run_get ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  if String.equal task_id "" then
    task_id_required ~tool_name ~start_time
  else
    match Run_eio.get ?agent_name:ctx.agent_name ctx.config ~task_id with
    | Ok json -> Tool_result.make_ok ~tool_name ~start_time ~data:json ()
    | Error e ->
        Tool_result.make_err
          ~tool_name
          ~class_:Tool_result.Runtime_failure
          ~start_time
          (Printf.sprintf "Failed to get run: %s" e)

let handle_run_list ~tool_name ~start_time ctx _args : Tool_result.result =
  let json = Run_eio.list ctx.config in
  Tool_result.make_ok ~tool_name ~start_time ~data:json ()

(** {1 Dispatcher} *)

(* RFC-0189 PR-1b.6 — boundary projection lives here. Handlers above are
   typed; external callers (mcp_server_eio_execute, tools.ml,
   keeper_tag_dispatch) still consume Tool_result.result option. PR-1c will
   move the Tool_dispatch.handler ABI itself to result, removing this
   bridge. *)
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  let lift r = Some r in
  match name with
  | "masc_run_init" -> lift (handle_run_init ~tool_name:name ~start_time:start ctx args)
  | "masc_run_plan" -> lift (handle_run_plan ~tool_name:name ~start_time:start ctx args)
  | "masc_run_get" -> lift (handle_run_get ~tool_name:name ~start_time:start ctx args)
  | "masc_run_list" -> lift (handle_run_list ~tool_name:name ~start_time:start ctx args)
  | _ -> None

let schemas : Masc_domain.tool_schema list = Tool_schemas_run.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let read_only_tools = [ "masc_run_list" ]

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      let is_ro = List.mem s.name read_only_tools in
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_run
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:is_ro
           ~is_idempotent:is_ro
           ()))
    schemas
