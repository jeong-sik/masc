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

let schemas : Masc_domain.tool_schema list = [
  (* masc_run_init *)
  {
    name = "masc_run_init";
    description = "Create an execution memory directory (.masc/runs/{task_id}/) to track the run plan. \
Call when starting work on a claimed task to enable structured progress tracking. \
After init, use masc_run_plan to set approach and masc_run_get to review.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to track");
        ]);
        ("agent_name", `Assoc [
          ("type", `String "string");
          ("description", `String "Agent working on the task");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "agent_name"]);
    ];
  };

  (* masc_run_plan *)
  {
    name = "masc_run_plan";
    description = "Set or update the execution plan (markdown) for a task run; each update creates a new revision. \\nCall after masc_run_init to document your approach before starting implementation. \\nOther agents can view plans via masc_run_get for workspace and handoff context.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("plan", `Assoc [
          ("type", `String "string");
          ("description", `String "The plan (markdown supported)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "plan"]);
    ];
  };

  (* masc_run_get *)
  {
    name = "masc_run_get";
    description = "Retrieve the run record and execution plan for a task. \\nIf the task has no run record yet, create an empty run scaffold and return it so resume flow can continue. \\nUse when resuming work on a task, reviewing progress, or preparing a handoff. \\nPair with masc_run_plan to set the plan.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID to retrieve");
        ]);
      ]);
      ("required", `List [`String "task_id"]);
    ];
  };

  (* masc_run_list *)
  {
    name = "masc_run_list";
    description = "List all task runs with their status (active/completed) and plan presence. \\nUse when starting a session to find abandoned work or review completed runs. \\nAfter finding a run, call masc_run_get for full details or masc_run_init to start a new one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

]

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
