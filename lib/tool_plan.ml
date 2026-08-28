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
      let response = `Assoc [ ("current_task", `Null) ] in
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
  | "masc_plan_set_task" -> lift (handle_plan_set_task ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_get_task" -> lift (handle_plan_get_task ~tool_name:name ~start_time:start ctx args)
  | "masc_plan_clear_task" -> lift (handle_plan_clear_task ~tool_name:name ~start_time:start ctx args)
  | _ -> None

(* RFC-0057 PR-2: schemas binding removed; plan tools now emitted via
   config/tools/masc_plan_*.toml (Tool_schemas_misc.schemas chain). *)

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let tool_spec_read_only = [ "masc_plan_get_task" ]

let () =
  let is_plan = function
    | "masc_plan_set_task"
    | "masc_plan_get_task"
    | "masc_plan_clear_task" -> true
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
