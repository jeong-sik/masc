open Result.Syntax
module Outbox = Keeper_client_tool_outbox
module Background = Keeper_execute_background
module Resolution = Keeper_receipt_wait_resolution

(* What the request record says about a run. The arguments of an ended run
   are what its Unfinished receipt echoes. A record that is absent, or that is
   not a background Execute run's, has none, and no value stands in for them. *)
type ended =
  | With_arguments of Yojson.Safe.t
  | Without_arguments of string

type record =
  | Worker_may_exist
  | Ended of ended

let read_record ~base_path ~keeper_name request_id =
  match Keeper_msg_async.load_canonical_request ~base_path ~caller:keeper_name request_id with
  | Keeper_msg_async.Found entry ->
    if Resolution.request_may_have_worker entry
    then Ok Worker_may_exist
    else
      (match Background.request_arguments entry with
       | Some arguments -> Ok (Ended (With_arguments arguments))
       | None ->
         Ok
           (Ended
              (Without_arguments
                 (Printf.sprintf
                    "request %s is not a background Execute run, so its arguments are \
                     not recorded"
                    request_id))))
  | Keeper_msg_async.Absent ->
    Ok
      (Ended
         (Without_arguments
            (Printf.sprintf
               "request %s has no record, so the arguments of its run are not known"
               request_id)))
  | Keeper_msg_async.Unreadable reason ->
    Error (Printf.sprintf "request %s is unreadable: %s" request_id reason)
  | Keeper_msg_async.Rejected rejection ->
    Error
      (Printf.sprintf
         "request %s is not readable by this Keeper: %s"
         request_id
         (Yojson.Safe.to_string (Keeper_msg_async.access_rejection_to_json rejection)))
;;

(* The request record is read before the outbox. A worker writes its receipt
   before it settles the request, so a request that has ended and has no
   receipt in an outbox read taken afterwards never had its receipt delivered.
   The other order lets a worker finish between the two reads. [Ok None] is a
   wait with nothing to settle. An [Error] leaves the wait pending, and the
   next sweep reads it again. *)
let lost_arguments ~base_path ~keeper_name request_id =
  let* record = read_record ~base_path ~keeper_name request_id in
  match record with
  | Worker_may_exist -> Ok None
  | Ended ended ->
    let* snapshot =
      Outbox.load ~base_path ~keeper_name ~viewer:Outbox.Every_receipt
    in
    if Outbox.contains_call snapshot ~call_id:request_id
    then Ok None
    else
      (match ended with
       | With_arguments arguments -> Ok (Some arguments)
       | Without_arguments reason -> Error reason)
;;

let settle_one ~base_path ~keeper_name request_id arguments =
  let* () =
    Background.retain_source_lost_receipt ~base_path ~keeper_name ~request_id ~arguments
  in
  match
    Keeper_owner_registry.receipt_arrived
      ~base_path
      ~keeper_name
      ~request_id
      ~resolution:Keeper_semantic_execution.Source_lost
  with
  | Ok
      ( Keeper_chat_operation_store.Receipt_resolved
      | Keeper_chat_operation_store.Receipt_already_arrived
      | Keeper_chat_operation_store.Receipt_without_owner ) -> Ok ()
  | Error error ->
    Error
      (Printf.sprintf
         "lost source of %s could not be reported to the Owner: %s"
         request_id
         (Keeper_owner_registry.command_error_to_string error))
;;

let settle_lost ~base_path ~keeper_name =
  let* pending = Resolution.pending_requests ~base_path ~keeper_name in
  let failures =
    List.filter_map
      (fun request_id ->
         match
           let* lost = lost_arguments ~base_path ~keeper_name request_id in
           match lost with
           | None -> Ok ()
           | Some arguments -> settle_one ~base_path ~keeper_name request_id arguments
         with
         | Ok () -> None
         | Error detail -> Some detail)
      pending
  in
  match failures with
  | [] -> Ok ()
  | _ :: _ -> Error (String.concat "; " failures)
;;

let after_wait ~base_path ~keeper_name =
  let arrived = Resolution.arrived ~base_path ~keeper_name in
  let settled = settle_lost ~base_path ~keeper_name in
  match arrived, settled with
  | Ok (), Ok () -> Ok ()
  | Error detail, Ok () | Ok (), Error detail -> Error detail
  | Error first, Error second -> Error (first ^ "; " ^ second)
;;
