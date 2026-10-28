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

(* A Failed operation's projection, decided before any effect. *)
type failed =
  { operation : Operation.Operation_id.t
  ; operation_id : string
  ; delivery_key : Keeper_chat_delivery_identity.delivery_key
  ; completed_at : float
  ; failure_kind : Operation.failure_kind
  ; source : (Keeper_chat_operation_payload.decoded_source, string) result Lazy.t
  ; route : Keeper_chat_store.Row_route.t Lazy.t
  ; content : string
  }

let prepare (operation : Operation.t) =
  match operation.state with
  | Operation.Queued | Running _ | Succeeded _ | Cancelled _ -> Ok None
  | Failed { completed_at; failure } ->
    let operation_id = Operation.Operation_id.to_string operation.operation_id in
    (match Keeper_chat_delivery_identity.Request_id.of_string operation_id with
     | Error detail -> Error (Invalid_identity detail)
     | Ok request_id ->
       let source = lazy (Keeper_chat_operation_payload.source_of_json operation.source) in
       let route = lazy (match Lazy.force source with
         | Ok source -> { Keeper_chat_store.Row_route.surface=Some source.surface;
             conversation_id=source.conversation_id }
         | Error _ -> Keeper_chat_store.Row_route.none) in
       Ok (Some { operation = operation.operation_id
                ; operation_id
                ; delivery_key = Keeper_chat_delivery_identity.Operation request_id
                ; completed_at
                ; failure_kind = failure.kind
                ; source
                ; route
                ; content = "Keeper request failed: " ^ summary failure.kind }))

(* The transcript answer is already in; the journal is attempted either way. *)
let finish ~base_path ~keeper_name (failed : failed) appended =
  let transcript = appended
    |> Result.map_error (fun detail -> Transcript_unavailable detail)
    |> Result.map (fun appended -> match appended with
     | Keeper_chat_store.Already_present _ -> ()
     | Keeper_chat_store.Appended _ ->
       let surface = match Lazy.force failed.source with
         | Ok source -> Surface_ref.lane_label source.surface
         | Error detail ->
           Log.Keeper.warn ~keeper_name
             "failed operation %s has an unreadable source; failure row has no route: %s"
             failed.operation_id detail;
           "operation" in
       (try Keeper_chat_broadcast.chat_appended ~keeper_name ~source:surface ~content:failed.content ()
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | exn -> Log.Keeper.warn ~keeper_name "failure transcript broadcast failed: %s"
            (Printexc.to_string exn))) in
  let journal = Journal.open_journal ~base_dir:base_path ~keeper_name
      ~operation_id:failed.operation_id () in
  let settlement = { Journal.operation_id = failed.operation; completed_at = failed.completed_at } in
  let journal = Journal.record_terminal_error ~segment:(Journal.Operation_settlement settlement)
    journal ~ts:failed.completed_at ~message:(summary failed.failure_kind)
  |> Result.map_error (fun detail -> Journal_unavailable detail) in
  Projected {transcript; journal}

let persist ~base_path ~keeper_name (operation : Operation.t) =
  match prepare operation with
  | Error _ as error -> error
  | Ok None -> Ok Not_failed
  | Ok (Some failed) ->
    let appended = Keeper_chat_store.append_settled_failure_once
      ~base_dir:base_path ~keeper_name ~delivery_key:failed.delivery_key
      ~route:failed.route ~content:failed.content () in
    Ok (finish ~base_path ~keeper_name failed appended)

let persist_all ~base_path ~keeper_name (operations : Operation.t list) =
  let prepared = List.map (fun (operation : Operation.t) -> operation, prepare operation) operations in
  let others = List.filter_map (fun (operation, prepared) -> match prepared with
    | Error error -> Some (operation, Error error)
    | Ok None -> Some (operation, Ok Not_failed)
    | Ok (Some _) -> None) prepared in
  let pending = List.filter_map (fun (operation, prepared) -> match prepared with
    | Ok (Some failed) ->
      Some ((operation, failed),
            { Keeper_chat_store.Settled_failure.delivery_key = failed.delivery_key
            ; content = failed.content
            ; route = failed.route })
    | Error _ | Ok None -> None) prepared in
  let answered = match Keeper_chat_store.append_settled_failures_once
      ~base_dir:base_path ~keeper_name pending with
    | Ok answers -> answers
    | Error detail -> List.map (fun (tag, _) -> tag, Error detail) pending in
  others @ List.map (fun ((operation, failed), appended) ->
    operation, Ok (finish ~base_path ~keeper_name failed appended)) answered
