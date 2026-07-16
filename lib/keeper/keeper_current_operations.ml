type source =
  | Event_queue_pending of
      { revision : int64
      ; stimulus : Keeper_event_queue.stimulus
      }
  | Event_queue_lease of
      { revision : int64
      ; lease : Keeper_event_queue_state.lease
      }
  | Event_queue_outbox of
      { revision : int64
      ; entry : Keeper_event_queue_state.outbox_entry
      }
  | Async_request of Keeper_msg_async.entry

type t =
  { keeper_name : string
  ; source : source
  }

type source_name =
  | Event_queue_source
  | Async_request_source

type read_error =
  | Durable_read_failed of string
  | Access_rejected of Keeper_msg_async.access_rejection
  | Async_keeper_mismatch of
      { request_id : string
      ; expected_keeper : string
      ; actual_keeper : string
      }
  | Async_terminal_entry of
      { request_id : string
      ; status : Keeper_msg_async.request_status
      }
  | Async_active_entry_has_completion_time of
      { request_id : string
      ; completed_at : float
      }

type unavailable =
  { source : source_name
  ; keeper_name : string
  ; error : read_error
  }

type 'a availability =
  | Available of 'a
  | Unavailable of unavailable

type snapshot =
  { keeper_name : string
  ; event_queue : t list availability
  ; async_requests : t list availability
  }

let project_event_queue_state ~keeper_name state =
  let revision = Keeper_event_queue_state.revision state in
  let pending =
    Keeper_event_queue_state.pending state
    |> Keeper_event_queue.to_list
    |> List.map (fun stimulus ->
      { keeper_name
      ; source = Event_queue_pending { revision; stimulus }
      })
  in
  let leases =
    Keeper_event_queue_state.leases state
    |> List.map (fun (lease : Keeper_event_queue_state.lease) ->
      { keeper_name
      ; source = Event_queue_lease { revision; lease }
      })
  in
  let outbox =
    Keeper_event_queue_state.transition_outbox state
    |> List.map (fun (entry : Keeper_event_queue_state.outbox_entry) ->
      { keeper_name
      ; source = Event_queue_outbox { revision; entry }
      })
  in
  leases @ pending @ outbox
;;

let project_async_entries ~keeper_name entries =
  let rec loop projected_rev = function
    | [] -> Ok (List.rev projected_rev)
    | (entry : Keeper_msg_async.entry) :: rest ->
      if not (String.equal entry.keeper_name keeper_name)
      then
        Error
          (Async_keeper_mismatch
             { request_id = entry.request_id
             ; expected_keeper = keeper_name
             ; actual_keeper = entry.keeper_name
             })
      else
        (match entry.status with
         | Lost _ | Cancelled _ | Persistence_failed _ | Done _ ->
           Error
             (Async_terminal_entry
                { request_id = entry.request_id; status = entry.status })
         | Queued | Running | Cancelling _ ->
           (match entry.completed_at with
            | Some completed_at ->
              Error
                (Async_active_entry_has_completion_time
                   { request_id = entry.request_id; completed_at })
            | None ->
              loop
                ({ keeper_name; source = Async_request entry } :: projected_rev)
                rest))
  in
  loop [] entries
;;

let availability ~source ~keeper_name = function
  | Ok value -> Available value
  | Error error -> Unavailable { source; keeper_name; error }
;;

let project_snapshot ~keeper_name ~event_queue ~async_requests =
  { keeper_name
  ; event_queue =
      availability ~source:Event_queue_source ~keeper_name
        (Result.map (project_event_queue_state ~keeper_name) event_queue)
  ; async_requests =
      availability ~source:Async_request_source ~keeper_name
        (Result.bind async_requests (project_async_entries ~keeper_name))
  }
;;

let status_to_yojson = function
  | Keeper_msg_async.Queued -> `Assoc [ "kind", `String "queued"; "terminal", `Bool false ]
  | Running -> `Assoc [ "kind", `String "running"; "terminal", `Bool false ]
  | Cancelling { reason; cancelled_by } ->
    `Assoc [ "kind", `String "cancelling"; "terminal", `Bool false
           ; "reason", `String reason; "cancelled_by", `String cancelled_by ]
  | Lost { reason } ->
    `Assoc [ "kind", `String "lost"; "terminal", `Bool true; "reason", `String reason ]
  | Cancelled { reason; cancelled_by } ->
    `Assoc [ "kind", `String "cancelled"; "terminal", `Bool true
           ; "reason", `String reason; "cancelled_by", `String cancelled_by ]
  | Persistence_failed { attempted_status; reason } ->
    `Assoc [ "kind", `String "persistence_failed"; "terminal", `Bool true
           ; "attempted_status", `String attempted_status; "reason", `String reason ]
  | Done { ok; body; data } ->
    `Assoc [ "kind", `String "done"; "terminal", `Bool true; "ok", `Bool ok
           ; "body", `String body
           ; "data", (match data with None -> `Null | Some value -> value) ]
;;

let async_entry_to_yojson (entry : Keeper_msg_async.entry) =
  `Assoc
    [ "request_id", `String entry.request_id
    ; "keeper_name", `String entry.keeper_name
    ; "base_path", `String entry.base_path
    ; "submitted_by", `String entry.submitted_by
    ; "submitted_at", `Float entry.submitted_at
    ; "completed_at", Option.fold ~none:`Null ~some:(fun value -> `Float value) entry.completed_at
    ; "status", status_to_yojson entry.status
    ]
;;

let outbox_to_yojson (entry : Keeper_event_queue_state.outbox_entry) =
  `Assoc
    [ "receipt", Keeper_event_queue_state.transition_receipt_to_yojson entry.receipt
    ; "stimulus", Keeper_event_queue.stimulus_to_yojson entry.stimulus
    ]
;;

let source_to_yojson = function
  | Event_queue_pending { revision; stimulus } ->
    `Assoc [ "kind", `String "event_queue_pending"
           ; "revision", `String (Int64.to_string revision)
           ; "value", Keeper_event_queue.stimulus_to_yojson stimulus ]
  | Event_queue_lease { revision; lease } ->
    `Assoc [ "kind", `String "event_queue_lease"
           ; "revision", `String (Int64.to_string revision)
           ; "value", Keeper_event_queue_state.lease_to_yojson lease ]
  | Event_queue_outbox { revision; entry } ->
    `Assoc [ "kind", `String "event_queue_outbox"
           ; "revision", `String (Int64.to_string revision)
           ; "value", outbox_to_yojson entry ]
  | Async_request entry ->
    `Assoc [ "kind", `String "async_request"; "value", async_entry_to_yojson entry ]
;;

let to_yojson (operation : t) =
  `Assoc
    [ "keeper_name", `String operation.keeper_name
    ; "source", source_to_yojson operation.source
    ]
;;

let unavailable_to_yojson unavailable =
  let source =
    match unavailable.source with
    | Event_queue_source -> "event_queue"
    | Async_request_source -> "async_requests"
  in
  let error =
    match unavailable.error with
    | Durable_read_failed detail ->
      `Assoc [ "kind", `String "durable_read_failed"; "detail", `String detail ]
    | Access_rejected rejection ->
      `Assoc [ "kind", `String "access_rejected"
             ; "detail", Keeper_msg_async.access_rejection_to_json rejection ]
    | Async_keeper_mismatch { request_id; expected_keeper; actual_keeper } ->
      `Assoc
        [ "kind", `String "async_keeper_mismatch"
        ; "request_id", `String request_id
        ; "expected_keeper", `String expected_keeper
        ; "actual_keeper", `String actual_keeper
        ]
    | Async_terminal_entry { request_id; status } ->
      `Assoc
        [ "kind", `String "async_terminal_entry"
        ; "request_id", `String request_id
        ; "status", status_to_yojson status
        ]
    | Async_active_entry_has_completion_time { request_id; completed_at } ->
      `Assoc
        [ "kind", `String "async_active_entry_has_completion_time"
        ; "request_id", `String request_id
        ; "completed_at", `Float completed_at
        ]
  in
  `Assoc [ "source", `String source; "keeper_name", `String unavailable.keeper_name
         ; "error", error ]
;;

let availability_to_yojson = function
  | Available operations ->
    `Assoc [ "available", `Bool true; "operations", `List (List.map to_yojson operations) ]
  | Unavailable error ->
    `Assoc [ "available", `Bool false; "unavailable", unavailable_to_yojson error ]
;;

let snapshot_to_yojson snapshot =
  `Assoc
    [ "schema", `String "keeper.current_operations.v1"
    ; "keeper_name", `String snapshot.keeper_name
    ; "event_queue", availability_to_yojson snapshot.event_queue
    ; "async_requests", availability_to_yojson snapshot.async_requests
    ]
;;

let render operation = to_yojson operation |> Yojson.Safe.to_string
