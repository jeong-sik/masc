open Result.Syntax

type receipt_state =
  | Waiting
  | Ended

type schedule_row =
  | Row_receipt of
      { receipt_key : Schedule_supported_kinds.receipt_key
      ; state : receipt_state
      }
  | Row_delivers_to_queue
  | No_row

let state_of_status = function
  | Schedule_domain.Scheduled | Schedule_domain.Due | Schedule_domain.Running -> Waiting
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired -> Ended
;;

let row_of_request ~keeper_name (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.wake_keeper_name request with
  | Some target when String.equal target keeper_name ->
    let* route =
      Schedule_payload_projection.route_of_payload
        (Schedule_domain.payload_to_yojson request.payload)
    in
    (match route with
     | Schedule_payload_projection.Queue_route -> Ok Row_delivers_to_queue
     | Schedule_payload_projection.Receipt_route receipt_key ->
       Ok (Row_receipt { receipt_key; state = state_of_status request.status }))
  | Some _ | None -> Ok No_row
;;

let read_state ~base_path =
  match Schedule_store.read_state_result (Workspace.default_config base_path) with
  | Error failure ->
    Error
      ("the schedule store cannot be read: " ^ Schedule_store.read_error_to_string failure)
  | Ok state -> Ok state
;;

let find_schedule ~base_path ~keeper_name schedule_id =
  let* state = read_state ~base_path in
  match Schedule_store.find_schedule state ~schedule_id with
  | None -> Ok No_row
  | Some request -> row_of_request ~keeper_name request
;;

let find_receipt_state ~base_path ~keeper_name receipt_key =
  let* state = read_state ~base_path in
  let holds_key (request : Schedule_domain.schedule_request) =
    match row_of_request ~keeper_name request with
    | Ok (Row_receipt { receipt_key = held; state = progress }) ->
      if String.equal
           (Schedule_supported_kinds.receipt_key_to_string held)
           (Schedule_supported_kinds.receipt_key_to_string receipt_key)
      then Some (Ok progress)
      else None
    | Ok (Row_delivers_to_queue | No_row) -> None
    | Error detail ->
      (* A row this server cannot read may be the one that holds the key. *)
      Some (Error detail)
  in
  let judged = List.filter_map holds_key state.Schedule_store.schedules in
  match List.find_map (function Ok state -> Some state | Error _ -> None) judged with
  | Some state -> Ok (Some state)
  | None ->
    (match List.find_map (function Error detail -> Some detail | Ok _ -> None) judged with
     | Some detail -> Error detail
     | None -> Ok None)
;;
