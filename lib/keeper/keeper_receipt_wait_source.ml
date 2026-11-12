open Result.Syntax

type schedule_row =
  | Row_waiting
  | Row_ended
  | Row_delivers_to_queue
  | No_row

let row_of_request ~keeper_name (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.wake_keeper_name request with
  | Some target when String.equal target keeper_name ->
    let* delivery =
      Schedule_payload_projection.delivery_of_payload
        (Schedule_domain.payload_to_yojson request.payload)
    in
    (match delivery with
     | Schedule_supported_kinds.Keeper_wake_to_queue -> Ok Row_delivers_to_queue
     | Schedule_supported_kinds.Keeper_wake_to_receipt ->
       (match request.status with
        | Schedule_domain.Scheduled | Schedule_domain.Due | Schedule_domain.Running ->
          Ok Row_waiting
        | Schedule_domain.Succeeded
        | Schedule_domain.Failed
        | Schedule_domain.Cancelled
        | Schedule_domain.Expired -> Ok Row_ended))
  | Some _ | None -> Ok No_row
;;

let find_schedule ~base_path ~keeper_name schedule_id =
  match Schedule_store.read_state_result (Workspace.default_config base_path) with
  | Error failure ->
    Error
      ("the schedule store cannot be read: " ^ Schedule_store.read_error_to_string failure)
  | Ok state ->
    (match Schedule_store.find_schedule state ~schedule_id with
     | None -> Ok No_row
     | Some request -> row_of_request ~keeper_name request)
;;
