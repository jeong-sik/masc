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

(** Plan Tool Handlers

    Extracted from mcp_server_eio.ml for testability.
    11 tools: plan_init, plan_update, note_add, deliver, plan_get,
              error_add, error_resolve, plan_set_task, plan_get_task, plan_clear_task
*)

module Planning_eio = Task.Planning_eio

(** Plan action outcome — closed sum for the [status] field.
    Previously a separate module; inlined because tool_plan.ml is the
    sole consumer. *)
module Plan_action_outcome = struct
  type t =
    | Initialized
    | Updated
    | Added
    | Delivered
    | Set
    | Cleared

  let to_label = function
    | Initialized -> "initialized"
    | Updated -> "updated"
    | Added -> "added"
    | Delivered -> "delivered"
    | Set -> "set"
    | Cleared -> "cleared"
  ;;

  let status_field outcome : string * Yojson.Safe.t =
    ("status", `String (to_label outcome))
  ;;
end

(** Tool handler context *)
type context = {
  config: Workspace.config;
}

open Tool_args

(* RFC-0189 PR-1b.5 — handlers in this module return typed
   [Tool_result.result]. Dispatch returns [Tool_result.result option].

   Failure class assignments:
   - Planning_eio internal "Failed to ..." errors → Runtime_failure
     (Planning_eio is the persistence boundary; the error is opaque
      to the caller and not retryable with different args).
   - "task_id is required" / "content is required" / resolve_task_id
     parse errors / set_current_task validation
     → Workflow_rejection (caller-input violations; same args won't
      succeed on retry). *)

(** {1 Individual Handlers} *)

let handle_plan_init ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  let result = Planning_eio.init ctx.config ~task_id in
  match result with
  | Ok _ctx ->
      let response = `Assoc [
        Plan_action_outcome.(status_field Initialized);
        ("task_id", `String task_id);
        ("message", `String (Printf.sprintf "Planning context created for %s" task_id));
      ] in
      Tool_result.make_ok ~tool_name ~start_time ~data:response ()
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf "Failed to init planning: %s" e)

let handle_plan_update ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  let content = get_string args "content" "" in
  let result = Planning_eio.update_plan ctx.config ~task_id ~content in
  match result with
  | Ok plan_ctx ->
      let response = `Assoc [
        Plan_action_outcome.(status_field Updated);
        ("task_id", `String task_id);
        ("updated_at", `String plan_ctx.Planning_eio.updated_at);
      ] in
      Tool_result.make_ok ~tool_name ~start_time ~data:response ()
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf "Failed to update plan: %s" e)

let handle_note_add ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  let note = get_string args "note" "" in
  let result = Planning_eio.add_note ctx.config ~task_id ~note in
  match result with
  | Ok plan_ctx ->
      let response = `Assoc [
        Plan_action_outcome.(status_field Added);
        ("task_id", `String task_id);
        ("note_count", `Int (List.length plan_ctx.Planning_eio.notes));
      ] in
      Tool_result.make_ok ~tool_name ~start_time ~data:response ()
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf "Failed to add note: %s" e)

let handle_deliver ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id_input = get_string args "task_id" "" in
  match Planning_eio.resolve_task_id ctx.config ~task_id:task_id_input with
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        e
  | Ok task_id ->
  let content = get_string args "content" "" in
  if String.equal (String.trim content) "" then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "content is required for masc_deliver"
  else
  let result = Planning_eio.set_deliverable ctx.config ~task_id ~content in
  match result with
  | Ok plan_ctx ->
      let response = `Assoc [
        Plan_action_outcome.(status_field Delivered);
        ("task_id", `String task_id);
        ("updated_at", `String plan_ctx.Planning_eio.updated_at);
      ] in
      Tool_result.make_ok ~tool_name ~start_time ~data:response ()
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf "Failed to set deliverable: %s" e)

let handle_plan_get ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id_input = get_string args "task_id" "" in
  match Planning_eio.resolve_task_id ctx.config ~task_id:task_id_input with
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        e
  | Ok task_id ->
      let result = Planning_eio.load_or_init ctx.config ~task_id in
      match result with
      | Ok plan_ctx ->
          let markdown = Planning_eio.get_context_markdown plan_ctx in
          let response = `Assoc [
            ("task_id", `String task_id);
            ("context", Planning_eio.planning_context_to_yojson plan_ctx);
            ("markdown", `String markdown);
          ] in
          Tool_result.make_ok ~tool_name ~start_time ~data:response ()
      | Error e ->
          Tool_result.make_err
            ~tool_name
            ~class_:Tool_result.Runtime_failure
            ~start_time
            (Printf.sprintf "Failed to load planning context: %s" e)

let handle_plan_set_task ~tool_name ~start_time ctx args : Tool_result.result =
  let task_id = get_string args "task_id" "" in
  if String.equal task_id "" then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "task_id is required"
  else match Planning_eio.set_current_task ctx.config ~task_id with
  | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        e
  | Ok () ->
    let response = `Assoc [
      Plan_action_outcome.(status_field Set);
      ("current_task", `String task_id);
    ] in
    Tool_result.make_ok ~tool_name ~start_time ~data:response ()

let handle_plan_get_task ~tool_name ~start_time ctx _args : Tool_result.result =
  match Planning_eio.get_current_task ctx.config with
  | Some task_id ->
      let response = `Assoc [
        ("current_task", `String task_id);
      ] in
      Tool_result.make_ok ~tool_name ~start_time ~data:response ()
  | None ->
      let response = `Assoc [
        ("current_task", `Null);
        ("message", `String "No current task set. Use masc_plan_set_task first.");
      ] in
      Tool_result.make_ok ~tool_name ~start_time ~data:response ()

let handle_plan_clear_task ~tool_name ~start_time ctx _args : Tool_result.result =
  Planning_eio.clear_current_task ctx.config;
  let response = `Assoc [
    Plan_action_outcome.(status_field Cleared);
    ("message", `String "Current task cleared");
  ] in
  Tool_result.make_ok ~tool_name ~start_time ~data:response ()

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : Tool_result.result option =
  let start = Time_compat.now () in
  let lift r = Some r in
  match name with
  | "masc_plan_init" -> lift (handle_plan_init ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_update" -> lift (handle_plan_update ~tool_name:name ~start_time:start ctx args)
  | "masc_note_add" -> lift (handle_note_add ~tool_name:name ~start_time:start ctx args)
  | "masc_deliver" -> lift (handle_deliver ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_get" -> lift (handle_plan_get ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_set_task" -> lift (handle_plan_set_task ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_get_task" -> lift (handle_plan_get_task ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_clear_task" -> lift (handle_plan_clear_task ~tool_name:name ~start_time:start ctx args)
  | _ -> None

(* RFC-0057 PR-2: schemas binding removed; plan tools now emitted via
   Tool_descriptors_gen (Tool_schemas_misc.schemas chain). *)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only = [ "masc_plan_get_task" ]

let () =
  let is_plan = function
    | "masc_plan_init"
    | "masc_plan_update"
    | "masc_plan_get"
    | "masc_plan_set_task"
    | "masc_plan_get_task"
    | "masc_plan_clear_task"
    | "masc_note_add"
    | "masc_deliver" -> true
    | _ -> false
  in
  List.iter
    (fun (s : Masc_domain.tool_schema) ->
      if is_plan s.name then
        Tool_spec.register
          (Tool_spec.create
             ~name:s.name
             ~description:s.description
             ~module_tag:Tool_dispatch.Mod_plan
             ~input_schema:s.input_schema
             ~handler_binding:Tag_dispatch
             ~is_read_only:(List.mem s.name tool_spec_read_only)
             ()))
    Tool_schemas_misc.schemas
