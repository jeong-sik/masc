(** Run Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    6 tools: run_init, run_plan, run_log, run_deliverable, run_get, run_list
*)

(** Tool handler context *)
type context = {
  config: Room.config;
}

(** Tool result type *)
type result = bool * string

open Tool_args

(** {1 Individual Handlers} *)

let handle_run_init ctx args : result =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
    let agent = get_string_opt args "agent_name" in
    match Run_eio.init ctx.config ~task_id ~agent_name:agent with
  | Ok run ->
      (true, Yojson.Safe.to_string (Run_eio.run_record_to_json run))
  | Error e ->
      (false, Printf.sprintf "❌ Failed to init run: %s" e)

let handle_run_plan ctx args : result =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
    let plan = get_string args "plan" "" in
    match Run_eio.update_plan ctx.config ~task_id ~content:plan with
  | Ok run ->
      (true, Yojson.Safe.to_string (Run_eio.run_record_to_json run))
  | Error e ->
      (false, Printf.sprintf "❌ Failed to update run plan: %s" e)

let handle_run_log ctx args : result =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
    let note = get_string args "note" "" in
    match Run_eio.append_log ctx.config ~task_id ~note with
  | Ok entry ->
      (true, Yojson.Safe.to_string (Run_eio.log_entry_to_json entry))
  | Error e ->
      (false, Printf.sprintf "❌ Failed to append run log: %s" e)

let handle_run_deliverable ctx args : result =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
    let deliverable = get_string args "deliverable" "" in
    match Run_eio.set_deliverable ctx.config ~task_id ~content:deliverable with
  | Ok run ->
      (true, Yojson.Safe.to_string (Run_eio.run_record_to_json run))
  | Error e ->
      (false, Printf.sprintf "❌ Failed to set run deliverable: %s" e)

let handle_run_get ctx args : result =
  let task_id = get_string args "task_id" "" in
  if task_id = "" then
    (false, "task_id is required")
  else
    match Run_eio.get ctx.config ~task_id with
    | Ok json -> (true, Yojson.Safe.to_string json)
    | Error e -> (false, Printf.sprintf "❌ Failed to get run: %s" e)

let handle_run_list ctx _args : result =
  let json = Run_eio.list ctx.config in
  (true, Yojson.Safe.to_string json)

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "masc_run_init" -> Some (handle_run_init ctx args)
  | "masc_run_plan" -> Some (handle_run_plan ctx args)
  | "masc_run_log" -> Some (handle_run_log ctx args)
  | "masc_run_deliverable" -> Some (handle_run_deliverable ctx args)
  | "masc_run_get" -> Some (handle_run_get ctx args)
  | "masc_run_list" -> Some (handle_run_list ctx args)
  | _ -> None

let schemas : Types.tool_schema list = [
  (* masc_run_init *)
  {
    name = "masc_run_init";
    description = "Create an execution memory directory (.masc/runs/{task_id}/) to track plan, logs, and deliverables. \
Call when starting work on a claimed task to enable structured progress tracking. \
After init, use masc_run_plan to set approach, masc_run_log for notes, masc_run_deliverable to close.";
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
    description = "Set or update the execution plan (markdown) for a task run; each update creates a new revision. \\nCall after masc_run_init to document your approach before starting implementation. \\nOther agents can view plans via masc_run_get for coordination and handoff context.";
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

  (* masc_run_log *)
  {
    name = "masc_run_log";
    description = "Append a timestamped note (ISO8601) to a task's execution log for audit and handoff continuity. \\nCall when reaching milestones, finding blockers, or making key decisions during task execution. \\nPair with masc_run_plan for the approach and masc_run_get to review the full log.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("note", `Assoc [
          ("type", `String "string");
          ("description", `String "Note to add (will be timestamped)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "note"]);
    ];
  };

  (* masc_run_deliverable *)
  {
    name = "masc_run_deliverable";
    description = "Record the final deliverable (markdown) and mark the task run as completed. \
Call when task implementation is finished and verified to close out the execution record. \
After recording, the run shows as completed in masc_run_list and masc_run_get.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc [
        ("task_id", `Assoc [
          ("type", `String "string");
          ("description", `String "Task ID");
        ]);
        ("deliverable", `Assoc [
          ("type", `String "string");
          ("description", `String "The deliverable (markdown supported)");
        ]);
      ]);
      ("required", `List [`String "task_id"; `String "deliverable"]);
    ];
  };

  (* masc_run_get *)
  {
    name = "masc_run_get";
    description = "Retrieve full execution history (plan, timestamped logs, deliverable) for a task as markdown. \\nUse when resuming work on a task, reviewing progress, or preparing a handoff. \\nPair with masc_run_list to find task IDs, masc_run_log to add entries.";
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
    description = "List all task runs with their status (active/completed), plan presence, and log count. \\nUse when starting a session to find abandoned work or review completed runs. \\nAfter finding a run, call masc_run_get for full details or masc_run_init to start a new one.";
    input_schema = `Assoc [
      ("type", `String "object");
      ("properties", `Assoc []);
    ];
  };

]

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let read_only_tools = [ "masc_run_get"; "masc_run_list" ]

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
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
