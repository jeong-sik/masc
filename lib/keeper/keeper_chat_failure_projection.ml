module Operation = Keeper_chat_operation
module Journal = Keeper_chat_event_log

type error =
  | Invalid_identity of string
  | Transcript_unavailable of string
  | Journal_unavailable of string

type outcome = Not_failed | Projected of
  { transcript : (unit, error) result
  ; journal : (Journal.terminal_error_receipt, error) result }

let error_to_string = function
  | Invalid_identity detail -> "failed operation identity: " ^ detail
  | Transcript_unavailable detail -> "failed operation transcript: " ^ detail
  | Journal_unavailable detail -> "failed operation journal: " ^ detail

let summary = function
  | Operation.Interrupted_by_restart ->
    Keeper_request_failure.summary
      { Keeper_request_failure.cause = Keeper_request_failure.Server_restarted }
  | (Operation.Turn_cancelled | Turn_exception | Store_unavailable
    | No_queued_operation | Invalid_input | Turn_invariant | Delivery_failed) as kind ->
    Operation.public_failure_message kind

let persist ~base_path ~keeper_name (operation : Operation.t) =
  let ( let* ) = Result.bind in
  match operation.state with
  | Operation.Queued | Running _ | Succeeded _ | Cancelled _ -> Ok Not_failed
  | Failed { completed_at; failure } ->
    let operation_id = Operation.Operation_id.to_string operation.operation_id in
    let* request_id = Keeper_chat_delivery_identity.Request_id.of_string operation_id
      |> Result.map_error (fun detail -> Invalid_identity detail) in
    let source = lazy (Keeper_chat_operation_payload.source_of_json operation.source) in
    let route = lazy (match Lazy.force source with
      | Ok source -> { Keeper_chat_store.Row_route.surface=Some source.surface;
          conversation_id=source.conversation_id }
      | Error _ -> Keeper_chat_store.Row_route.none) in
    let content = "Keeper request failed: " ^ summary failure.kind in
    let appended = Keeper_chat_store.append_settled_failure_once
      ~base_dir:base_path ~keeper_name
      ~delivery_key:(Keeper_chat_delivery_identity.Operation request_id)
      ~route
      ~content ()
      |> Result.map_error (fun detail -> Transcript_unavailable detail) in
    let transcript = Result.map (fun appended -> match appended with
     | Keeper_chat_store.Already_present _ -> ()
     | Keeper_chat_store.Appended _ ->
       let surface = match Lazy.force source with
         | Ok source -> Surface_ref.lane_label source.surface
         | Error detail ->
           Log.Keeper.warn ~keeper_name
             "failed operation %s has an unreadable source; failure row has no route: %s"
             operation_id detail;
           "operation" in
       (try Keeper_chat_broadcast.chat_appended ~keeper_name ~source:surface ~content ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Log.Keeper.warn ~keeper_name "failure transcript broadcast failed: %s"
            (Printexc.to_string exn))) appended in
    let journal = Journal.open_journal ~base_dir:base_path ~keeper_name ~operation_id () in
    let settlement = { Journal.operation_id = operation.operation_id; completed_at } in
    let journal = Journal.record_terminal_error ~segment:(Journal.Operation_settlement settlement)
      journal ~ts:completed_at ~message:(summary failure.kind)
    |> Result.map_error (fun detail -> Journal_unavailable detail) in
    Ok (Projected {transcript; journal})
