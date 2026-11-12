open Result.Syntax
module Outbox = Keeper_client_tool_outbox

let store_path ~base_path ~keeper_name =
  Keeper_chat_operation_store.path_for_keeper
    ~keepers_runtime_dir:(Common.keepers_runtime_dir_of_base ~base_path)
    ~keeper_name
;;

let request_owner ~base_path ~keeper_name ~request_id =
  let path = store_path ~base_path ~keeper_name in
  match
    Eio_guard.run_in_systhread ~label:"receipt-wait-owner" (fun () ->
      Keeper_chat_operation_store.inspect_receipt_owners ~path)
  with
  | Ok owners -> Ok (Keeper_chat_operation_store.receipt_owner owners ~request_id)
  | Error error ->
    Error
      ("receipt owners are unreadable: "
       ^ Keeper_chat_operation_store.error_to_string error)
;;

let pending_requests ~base_path ~keeper_name =
  let path = store_path ~base_path ~keeper_name in
  match
    Eio_guard.run_in_systhread ~label:"receipt-wait-pending" (fun () ->
      Keeper_chat_operation_store.inspect_pending_receipt_requests ~path)
  with
  | Ok requests -> Ok requests
  | Error error ->
    Error
      ("pending receipt waits are unreadable: "
       ^ Keeper_chat_operation_store.error_to_string error)
;;

let request_may_have_worker (entry : Keeper_msg_async.entry) =
  match entry.status with
  | Keeper_msg_async.Queued
  | Keeper_msg_async.Running
  | Keeper_msg_async.Cancelling _
  | Keeper_msg_async.Waiting_for_dependencies _ -> true
  | Keeper_msg_async.Lost _
  | Keeper_msg_async.Cancelled _
  | Keeper_msg_async.Persistence_failed _
  | Keeper_msg_async.Done _ -> false
;;

let tell_owner ~base_path ~keeper_name ~request_id =
  match
    Keeper_owner_registry.receipt_arrived
      ~base_path
      ~keeper_name
      ~request_id
      ~resolution:Keeper_semantic_execution.Receipt_in_outbox
  with
  | Ok
      ( Keeper_chat_operation_store.Receipt_resolved
      | Keeper_chat_operation_store.Receipt_already_arrived
      | Keeper_chat_operation_store.Receipt_without_owner ) -> Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "receipt of %s could not be reported to the Owner: %s"
         request_id
         (Keeper_owner_registry.command_error_to_string error))
;;

let arrived ~base_path ~keeper_name =
  let* pending = pending_requests ~base_path ~keeper_name in
  match pending with
  | [] -> Ok ()
  | _ :: _ ->
    let* snapshot =
      Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt
    in
    let failures =
      List.filter_map
        (fun request_id ->
           if Outbox.contains_call snapshot ~call_id:request_id
           then (
             match tell_owner ~base_path ~keeper_name ~request_id with
             | Ok () -> None
             | Error detail -> Some detail)
           else None)
        pending
    in
    (match failures with
     | [] -> Ok ()
     | _ :: _ -> Error (String.concat "; " failures))
;;

let obligations_of_terminal_effect = function
  | Some (Keeper_tool_execution.Receipt_wait_requested { first; later }) ->
    List.fold_left
      (fun obligations request_id ->
         let* obligations = obligations in
         let* obligation =
           Keeper_semantic_execution.receipt_obligation
             ~request_id
             ~state:Keeper_semantic_execution.Pending
         in
         Ok (obligations @ [ obligation ]))
      (Ok [])
      (first :: later)
  | Some (Keeper_tool_execution.Surface_post_completed _) | None -> Ok []
;;
