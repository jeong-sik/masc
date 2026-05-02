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

(** Tool handler context *)
type context = {
  config: Coord.config;
}

(** Tool result type *)
type tool_result = bool * string

open Tool_args

(** {1 Individual Handlers} *)

let handle_plan_init ctx args : tool_result =
  let task_id = get_string args "task_id" "" in
  let result = Planning_eio.init ctx.config ~task_id in
  match result with
  | Ok _ctx ->
      let response = `Assoc [
        ("status", `String "initialized");
        ("task_id", `String task_id);
        ("message", `String (Printf.sprintf "Planning context created for %s" task_id));
      ] in
      (true, Yojson.Safe.to_string response)
  | Error e ->
      (false, Printf.sprintf "❌ Failed to init planning: %s" e)

let handle_plan_update ctx args : tool_result =
  let task_id = get_string args "task_id" "" in
  let content = get_string args "content" "" in
  let result = Planning_eio.update_plan ctx.config ~task_id ~content in
  match result with
  | Ok plan_ctx ->
      let response = `Assoc [
        ("status", `String "updated");
        ("task_id", `String task_id);
        ("updated_at", `String plan_ctx.Planning_eio.updated_at);
      ] in
      (true, Yojson.Safe.to_string response)
  | Error e ->
      (false, Printf.sprintf "❌ Failed to update plan: %s" e)

let handle_note_add ctx args : tool_result =
  let task_id = get_string args "task_id" "" in
  let note = get_string args "note" "" in
  let result = Planning_eio.add_note ctx.config ~task_id ~note in
  match result with
  | Ok plan_ctx ->
      let response = `Assoc [
        ("status", `String "added");
        ("task_id", `String task_id);
        ("note_count", `Int (List.length plan_ctx.Planning_eio.notes));
      ] in
      (true, Yojson.Safe.to_string response)
  | Error e ->
      (false, Printf.sprintf "❌ Failed to add note: %s" e)

let handle_deliver ctx args : tool_result =
  let task_id_input = get_string args "task_id" "" in
  match Planning_eio.resolve_task_id ctx.config ~task_id:task_id_input with
  | Error e -> (false, Printf.sprintf "❌ %s" e)
  | Ok task_id ->
  let content = get_string args "content" "" in
  if String.equal (String.trim content) "" then
    (false, "❌ content is required for masc_deliver")
  else
  let result = Planning_eio.set_deliverable ctx.config ~task_id ~content in
  match result with
  | Ok plan_ctx ->
      let response = `Assoc [
        ("status", `String "delivered");
        ("task_id", `String task_id);
        ("updated_at", `String plan_ctx.Planning_eio.updated_at);
      ] in
      (true, Yojson.Safe.to_string response)
  | Error e ->
      (false, Printf.sprintf "❌ Failed to set deliverable: %s" e)

let handle_plan_get ctx args : tool_result =
  let task_id_input = get_string args "task_id" "" in
  match Planning_eio.resolve_task_id ctx.config ~task_id:task_id_input with
  | Error e -> (false, Printf.sprintf "❌ %s" e)
  | Ok task_id ->
      let result = Planning_eio.load ctx.config ~task_id in
      match result with
      | Ok plan_ctx ->
          let markdown = Planning_eio.get_context_markdown plan_ctx in
          let response = `Assoc [
            ("task_id", `String task_id);
            ("context", Planning_eio.planning_context_to_yojson plan_ctx);
            ("markdown", `String markdown);
          ] in
          (true, Yojson.Safe.to_string response)
      | Error e ->
          (false, Printf.sprintf "❌ Planning context not found: %s" e)

let handle_plan_set_task ctx args : tool_result =
  let task_id = get_string args "task_id" "" in
  if String.equal task_id "" then
    (false, "❌ task_id is required")
  else begin
    Planning_eio.set_current_task ctx.config ~task_id;
    let response = `Assoc [
      ("status", `String "set");
      ("current_task", `String task_id);
    ] in
    (true, Yojson.Safe.to_string response)
  end

let handle_plan_get_task ctx _args : tool_result =
  match Planning_eio.get_current_task ctx.config with
  | Some task_id ->
      let response = `Assoc [
        ("current_task", `String task_id);
      ] in
      (true, Yojson.Safe.to_string response)
  | None ->
      let response = `Assoc [
        ("current_task", `Null);
        ("message", `String "No current task set. Use masc_plan_set_task first.");
      ] in
      (true, Yojson.Safe.to_string response)

let handle_plan_clear_task ctx _args : tool_result =
  Planning_eio.clear_current_task ctx.config;
  let response = `Assoc [
    ("status", `String "cleared");
    ("message", `String "Current task cleared");
  ] in
  (true, Yojson.Safe.to_string response)

(** {1 Dispatcher} *)

let dispatch ctx ~name ~args : tool_result option =
  match name with
  | "masc_plan_init" -> Some (handle_plan_init ctx args)
  | "masc_plan_update" -> Some (handle_plan_update ctx args)
  | "masc_note_add" -> Some (handle_note_add ctx args)
  | "masc_deliver" -> Some (handle_deliver ctx args)
  | "masc_plan_get" -> Some (handle_plan_get ctx args)
  | "masc_plan_set_task" -> Some (handle_plan_set_task ctx args)
  | "masc_plan_get_task" -> Some (handle_plan_get_task ctx args)
  | "masc_plan_clear_task" -> Some (handle_plan_clear_task ctx args)
  | _ -> None

let schemas = Tool_schemas_plan.schemas

(* ================================================================ *)
(* Tool_spec registration                                           *)
(* ================================================================ *)

let _tool_spec_read_only = [ "masc_plan_get" ]
let _tool_spec_requires_join = [ "masc_plan_set_task"; "masc_plan_clear_task" ]

let tool_required_permission = function
  | "masc_plan_get" | "masc_plan_get_task" ->
      Some Types.CanReadState
  | _ -> None

let () =
  List.iter
    (fun (s : Types.tool_schema) ->
      Tool_spec.register
        (Tool_spec.create
           ~name:s.name
           ~description:s.description
           ~module_tag:Tool_dispatch.Mod_plan
           ~input_schema:s.input_schema
           ~handler_binding:Tag_dispatch
           ~is_read_only:(List.mem s.name _tool_spec_read_only)
           ~is_idempotent:(List.mem s.name _tool_spec_read_only)
           ~requires_join:(List.mem s.name _tool_spec_requires_join)
           ?required_permission:(tool_required_permission s.name)
           ()))
    schemas
