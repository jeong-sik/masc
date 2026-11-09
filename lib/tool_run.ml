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
   [Tool_result.result]. Missing run initialization is a workflow precondition;
   damaged records and storage errors remain Runtime_failure. The
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
      let class_, effect_disposition, message =
        match e with
        | Run_eio.Missing_run _ ->
          Tool_result.Workflow_rejection, Tool_result.Proven_pre_effect,
          Run_eio.error_to_string e
          ^ " Call masc_run_init for this task before setting its plan."
        | Run_eio.Invalid_run _ ->
          Tool_result.Runtime_failure, Tool_result.Proven_pre_effect,
          Run_eio.error_to_string e
        | Run_eio.Storage_failure _ ->
          Tool_result.Runtime_failure, Tool_result.Effect_outcome_unknown,
          Run_eio.error_to_string e
      in
      Tool_result.make_err
        ~tool_name
        ~class_
        ~effect_disposition
        ~start_time
        (Printf.sprintf "Failed to update run plan: %s" message)

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

(* The newest 100 of the 787 runs in one workspace (2026-11-09) are 14,372 bytes
   as rows and the newest 50 are 7,255 bytes; a row is 140 bytes on average and
   161 at most. Common.max_tool_result_wire_bytes is 16,384, and above it a
   result is stored as a blob and read in pages. config/tools/masc_run_list.toml
   declares the same three numbers; test_run_tool_workflow reads that schema
   and checks the handler against it. *)
let default_list_limit = 50
let max_list_limit = 100

let handle_run_list ~tool_name ~start_time ctx args : Tool_result.result =
  match
    validate_int_range args "limit" ~min_v:1 ~max_v:max_list_limit ~default:default_list_limit
  with
  | Error error -> validation_error_result ~tool_name ~start_time [ error ]
  | Ok limit ->
    let json = Run_eio.run_listing_to_json (Run_eio.list ctx.config ~limit) in
    Tool_result.make_ok ~tool_name ~start_time ~data:json ()

(** {1 Dispatcher} *)

(* RFC-0189 PR-1b.6 — boundary projection lives here. Handlers above are
   typed; external callers (mcp_server_eio_execute, tools.ml,
   keeper_tag_dispatch) still consume Tool_result.result option. PR-1c will
   move the Tool_dispatch.handler ABI itself to result, removing this
   bridge. *)
(* The wire name is parsed once and the operations are matched, so an operation
   added to [Tool_schemas_run] is a compile error here. *)
let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Tool_timing.start () in
  let lift r = Some r in
  match Tool_schemas_run.operation_of_tool_name name with
  | None -> None
  | Some Tool_schemas_run.Run_init ->
    lift (handle_run_init ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_run.Run_plan ->
    lift (handle_run_plan ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_run.Run_get ->
    lift (handle_run_get ~tool_name:name ~start_time:start ctx args)
  | Some Tool_schemas_run.Run_list ->
    lift (handle_run_list ~tool_name:name ~start_time:start ctx args)

let schemas : Masc_domain.tool_schema list = Tool_schemas_run.schemas

let () =
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      match
        Tool_catalog.execution_policy_of_metadata
          ~tool_name:s.name
          (Tool_catalog.metadata s.name)
      with
      | Error error ->
        invalid_arg (Tool_catalog.execution_policy_error_to_string error)
      | Ok policy ->
        Tool_spec.register
          (Tool_spec.create
             ~name:s.name
             ~description:s.description
             ~module_tag:Tool_dispatch.Mod_run
             ~input_schema:s.input_schema
             ~handler_binding:Tag_dispatch
             ~is_read_only:policy.is_read_only
             ~is_idempotent:policy.is_idempotent
             ~mcp_context_required:policy.mcp_context_required
             ()))
    schemas
