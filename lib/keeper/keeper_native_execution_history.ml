module Agent = Agent_core.Agent
module Projection = Agent.Execution_projection
module Operation_id = Keeper_chat_operation.Operation_id
module Store = Keeper_chat_operation_store
open Result.Syntax

type error =
  | Invalid_keeper_name of string
  | Missing_operation_store
  | Operation_store of Store.error
  | Invalid_limit of int
  | Unknown_call of string
  | Unknown_after_call of string
  | Runtime_unavailable
  | Filesystem_unavailable
  | Projection_failed of Projection.error

let error_to_string = function
  | Invalid_keeper_name detail -> detail
  | Missing_operation_store -> "native history operation store is absent"
  | Operation_store error -> Store.error_to_string error
  | Invalid_limit limit -> Printf.sprintf "invalid native history page limit: %d" limit
  | Unknown_call call_id -> "native call is not associated with this operation: " ^ call_id
  | Unknown_after_call call_id -> "native history cursor is not associated with this operation: " ^ call_id
  | Runtime_unavailable -> "native execution runtime is unavailable"
  | Filesystem_unavailable -> "native execution filesystem is unavailable"
  | Projection_failed error -> Projection.error_to_string error

(* Bounds the association response, independently of execution progress or
   retention. Journal event pages use Core's own transport boundary. *)
let max_calls_per_page = 200

let history ~base_path ~keeper_name ~operation_id =
  let* keeper = Keeper_id.Keeper_name.of_string keeper_name
    |> Result.map_error (fun detail -> Invalid_keeper_name detail) in
  let path = Store.path_for_keeper
      ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path)
      ~keeper_name:(Keeper_id.Keeper_name.to_string keeper) in
  let* stored = Store.inspect_native_history ~path ~operation_id
    |> Result.map_error (fun error -> Operation_store error) in
  match stored with
  | None -> Error Missing_operation_store
  | Some stored -> Ok stored

type call_page =
  { execution_operation_id : Operation_id.t
  ; calls : Keeper_native_call.history_ref list
  ; next_after_call_id : string option
  }

let list_calls ~base_path ~keeper_name ~operation_id ~after_call_id ~limit =
  let* () = if limit > 0 && limit <= max_calls_per_page then Ok () else Error (Invalid_limit limit) in
  let* stored = history ~base_path ~keeper_name ~operation_id in
  let rec after call_id = function
    | [] -> Error (Unknown_after_call call_id)
    | (reference : Keeper_native_call.history_ref) :: rest ->
      if reference.call_id = call_id then Ok rest else after call_id rest in
  let* remaining = match after_call_id with
    | None -> Ok stored.calls
    | Some call_id -> after call_id stored.calls in
  let calls = List.take limit remaining in
  let next_after_call_id =
    if List.length remaining > limit then
      match List.rev calls with
      | latest :: _ -> Some latest.Keeper_native_call.call_id
      | [] -> None
    else None in
  Ok {execution_operation_id=stored.execution_operation_id; calls; next_after_call_id}

type event_page =
  { execution_operation_id : Operation_id.t
  ; call : Keeper_native_call.history_ref
  ; page : Projection.page
  }

let read_page ~base_path ~keeper_name ~operation_id ~call_id ~after ~through ~limit =
  let* stored = history ~base_path ~keeper_name ~operation_id in
  let* call = match List.find_opt (fun (reference : Keeper_native_call.history_ref) ->
      reference.call_id = call_id) stored.calls with
    | None -> Error (Unknown_call call_id)
    | Some call -> Ok call in
  let* runtime = match Runtime_agent_execution_runtime.get () with
    | None -> Error Runtime_unavailable
    | Some runtime -> Ok runtime in
  let* fs = match Fs_compat.get_fs_opt () with
    | None -> Error Filesystem_unavailable
    | Some fs -> Ok fs in
  let session_dir = Filename.concat (Keeper_fs.session_store_path_for_base_path base_path)
      (Keeper_id.Trace_id.to_string call.trace_id) in
  let dir = Eio.Path.(fs / session_dir / "native-executions" / call.call_id) in
  let* projection = Agent.open_execution_projection ~runtime ~dir call.locator
    |> Result.map_error (fun error -> Projection_failed error) in
  let after = match after with None -> Projection.beginning_cursor projection | Some cursor -> cursor in
  let* page = Projection.read_page projection ~after ?through ~limit ()
    |> Result.map_error (fun error -> Projection_failed error) in
  Ok {execution_operation_id=stored.execution_operation_id; call; page}
