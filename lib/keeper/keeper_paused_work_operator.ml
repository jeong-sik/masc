module Queue = Keeper_event_queue
module Queue_state = Keeper_event_queue_state
module Disposition = Keeper_paused_work_disposition_receipt
module Resume = Keeper_paused_work_resume_transaction
module Cancellation = Keeper_paused_work_cancellation_transaction
module Transfer = Keeper_paused_work_transfer_transaction
module Source_terminal = Keeper_paused_work_source_terminal_transaction
module Request = Keeper_paused_work_operator_request

type request = Request.t =
  | Resume_owner of Resume.request
  | Cancel_pending of Cancellation.pending_request
  | Transfer_owner of
      { to_keeper : string
      ; request : Transfer.request
      }
  | Ack_source_terminal of Source_terminal.request

type outcome =
  | Resumed of Resume.success
  | Cancelled of Cancellation.success
  | Transferred of Transfer.success
  | Source_terminal_acked of Source_terminal.success

type error =
  | Invalid_request of string
  | Resume_rejected of Resume.error
  | Cancellation_rejected of Cancellation.error
  | Transfer_rejected of Transfer.error
  | Source_terminal_rejected of Source_terminal.error

type error_class =
  [ `Bad_request
  | `Not_found
  | `Conflict
  | `Unavailable
  ]

type inventory_error =
  | Inventory_meta_read_failed of string
  | Inventory_meta_missing
  | Inventory_queue_read_failed of string

let ( let* ) = Result.bind
let request_of_yojson = Request.of_yojson

let execute config ~keeper_name = function
  | Resume_owner request ->
    Resume.resume config ~keeper_name request
    |> Result.map (fun success -> Resumed success)
    |> Result.map_error (fun error -> Resume_rejected error)
  | Cancel_pending request ->
    Cancellation.cancel_pending config ~keeper_name request
    |> Result.map (fun success -> Cancelled success)
    |> Result.map_error (fun error -> Cancellation_rejected error)
  | Transfer_owner { to_keeper; request } ->
    Transfer.transfer_pending config ~from_keeper:keeper_name ~to_keeper request
    |> Result.map (fun success -> Transferred success)
    |> Result.map_error (fun error -> Transfer_rejected error)
  | Ack_source_terminal request ->
    Source_terminal.ack_pending config ~keeper_name request
    |> Result.map (fun success -> Source_terminal_acked success)
    |> Result.map_error (fun error -> Source_terminal_rejected error)
;;

let commit_status = function
  | `Committed -> "committed"
  | `Already_committed -> "already_committed"
;;

let cancellation_result_json (success : Cancellation.success) =
  let commit_status, ok, projection, receipt, error =
    match success.transition with
    | Keeper_registry_event_queue.Transition_applied receipt ->
      "committed", true, "applied", receipt, None
    | Keeper_registry_event_queue.Transition_already_applied receipt ->
      "already_committed", true, "applied", receipt, None
    | Keeper_registry_event_queue.Transition_committed_followup_failed
        { receipt; stage; detail } ->
      let stage =
        match stage with
        | `Checkpoint -> "checkpoint"
        | `Wal_compaction -> "wal_compaction"
        | `Projection -> "projection"
      in
      ( "committed"
      , false
      , "committed_followup_failed"
      , receipt
      , Some (Printf.sprintf "%s: %s" stage detail) )
  in
  `Assoc
    ([ "ok", `Bool ok
     ; "committed", `Bool true
     ; "operation", `String "cancel_accepted"
     ; "commit_status", `String commit_status
     ; "projection", `String projection
     ; "receipt", Queue_state.transition_receipt_to_yojson receipt
     ]
     @ match error with None -> [] | Some detail -> [ "error", `String detail ])
;;

let outcome_to_yojson = function
  | Cancelled success -> cancellation_result_json success
  | Resumed (success : Resume.success) ->
    let commit_status =
      match success.commit_status with
      | Resume.Committed -> commit_status `Committed
      | Resume.Already_committed -> commit_status `Already_committed
    in
    let ok, projection, error =
      match success.projection with
      | Resume.Applied phase ->
        true, Keeper_state_machine.phase_to_string phase, None
      | Resume.Committed_followup_failed failure ->
        ( false
        , "committed_followup_failed"
        , Some
            (Resume.error_to_string
               { cause = failure; reservation_release = None }) )
    in
    `Assoc
      ([ "ok", `Bool ok
       ; "committed", `Bool true
       ; "operation", `String "resume_owner"
       ; "commit_status", `String commit_status
       ; "projection", `String projection
       ; "receipt", Disposition.to_yojson success.receipt
       ]
       @ match error with None -> [] | Some detail -> [ "error", `String detail ])
  | Transferred (success : Transfer.success) ->
    let commit_status =
      match success.commit_status with
      | Transfer.Committed -> commit_status `Committed
      | Transfer.Already_committed -> commit_status `Already_committed
    in
    let ok, projection, error =
      match success.projection with
      | Transfer.Applied target_projection ->
        let projection =
          match target_projection with
          | Transfer.Enqueued -> "enqueued"
          | Transfer.Already_present -> "already_present"
        in
        true, projection, None
      | Transfer.Committed_followup_failed failure ->
        ( false
        , "committed_followup_failed"
        , Some
            (Transfer.error_to_string
               { cause = failure; reservation_release = None }) )
    in
    `Assoc
      ([ "ok", `Bool ok
       ; "committed", `Bool true
       ; "operation", `String "transfer_owner"
       ; "commit_status", `String commit_status
       ; "projection", `String projection
       ; "receipt", Disposition.to_yojson success.receipt
       ]
       @ match error with None -> [] | Some detail -> [ "error", `String detail ])
  | Source_terminal_acked (success : Source_terminal.success) ->
    let commit_status =
      match success.commit_status with
      | Source_terminal.Committed -> commit_status `Committed
      | Source_terminal.Already_committed -> commit_status `Already_committed
    in
    let ok, projection, error =
      match success.projection with
      | Source_terminal.Applied _ -> true, "applied", None
      | Source_terminal.Committed_followup_failed failure ->
        ( false
        , "committed_followup_failed"
        , Some
            (Source_terminal.error_to_string
               { cause = failure; reservation_release = None }) )
    in
    `Assoc
      ([ "ok", `Bool ok
       ; "committed", `Bool true
       ; "operation", `String "ack_source_terminal"
       ; "commit_status", `String commit_status
       ; "projection", `String projection
       ; "receipt", Disposition.to_yojson success.receipt
       ]
       @ match error with None -> [] | Some detail -> [ "error", `String detail ])
;;

let outcome_projection_complete = function
  | Resumed { projection = Resume.Applied _; _ }
  | Cancelled
      { transition =
          ( Keeper_registry_event_queue.Transition_applied _
          | Keeper_registry_event_queue.Transition_already_applied _ )
      ; _
      }
  | Transferred { projection = Transfer.Applied _; _ }
  | Source_terminal_acked { projection = Source_terminal.Applied _; _ } ->
    true
  | Resumed { projection = Resume.Committed_followup_failed _; _ }
  | Cancelled
      { transition = Keeper_registry_event_queue.Transition_committed_followup_failed _; _ }
  | Transferred { projection = Transfer.Committed_followup_failed _; _ }
  | Source_terminal_acked
      { projection = Source_terminal.Committed_followup_failed _; _ } ->
    false
;;

let error_to_string = function
  | Invalid_request detail -> detail
  | Resume_rejected error -> Resume.error_to_string error
  | Cancellation_rejected error -> Cancellation.error_to_string error
  | Transfer_rejected error -> Transfer.error_to_string error
  | Source_terminal_rejected error -> Source_terminal.error_to_string error
;;

let admission_busy = function
  | Cancellation_rejected (Cancellation.Admission_busy block) -> Some block
  | Transfer_rejected { cause = Transfer.Admission_busy block; _ } -> Some block
  | Source_terminal_rejected
      { cause = Source_terminal.Admission_busy block; _ } ->
    Some block
  | Invalid_request _
  | Resume_rejected _
  | Cancellation_rejected _
  | Transfer_rejected _
  | Source_terminal_rejected _ ->
    None
;;

let error_to_yojson error =
  let fields =
    [ "ok", `Bool false; "error", `String (error_to_string error) ]
  in
  match admission_busy error with
  | None -> `Assoc fields
  | Some block ->
    `Assoc
      (fields
       @ [ "error_code", `String "keeper_owner_busy"
         ; "admission", Keeper_owner.autonomous_block_to_yojson block
         ])
;;

let error_class = function
  | Invalid_request _ -> `Bad_request
  | Resume_rejected { cause = Resume.Invalid_request _; _ }
  | Transfer_rejected { cause = Transfer.Invalid_request _; _ }
  | Source_terminal_rejected { cause = Source_terminal.Invalid_request _; _ } ->
    `Bad_request
  | Resume_rejected { cause = Resume.Durable_meta_missing; _ }
  | Cancellation_rejected
      (Cancellation.Failed { cause = Cancellation.Durable_meta_missing; _ })
  | Transfer_rejected { cause = Transfer.Durable_meta_missing _; _ }
  | Source_terminal_rejected { cause = Source_terminal.Durable_meta_missing; _ } ->
    `Not_found
  | Resume_rejected
      { cause =
          ( Resume.Reservation_conflict _
          | Resume.Receipt_conflict _
          | Resume.Durable_owner_nonce_changed _
          | Resume.Durable_owner_identity_changed
          | Resume.Durable_owner_not_paused
          | Resume.Registry_owner_nonce_changed _
          | Resume.Registry_owner_identity_changed
          | Resume.Registry_owner_not_paused _ )
      ; _
      }
  | Cancellation_rejected (Cancellation.Reservation_conflict _)
  | Cancellation_rejected
      (Cancellation.Failed
        { cause =
            ( Cancellation.Durable_owner_not_paused
            | Cancellation.Durable_owner_nonce_changed _
            | Cancellation.Registry_owner_not_paused _
            | Cancellation.Registry_owner_nonce_changed _ )
        ; _
        })
  | Transfer_rejected
      { cause =
          ( Transfer.Reservation_conflict _
          | Transfer.Receipt_conflict _
          | Transfer.Source_owner_not_paused
          | Transfer.Source_owner_nonce_changed _
          | Transfer.Source_owner_identity_changed
          | Transfer.Target_owner_not_active
          | Transfer.Target_owner_nonce_changed _
          | Transfer.Target_owner_identity_changed
          | Transfer.Continuation_binding_mismatch
          | Transfer.Source_queue_validation_failed _ )
      ; _
      }
  | Source_terminal_rejected
      { cause =
          ( Source_terminal.Reservation_conflict _
          | Source_terminal.Receipt_conflict _
          | Source_terminal.Durable_owner_not_paused
          | Source_terminal.Durable_owner_nonce_changed _
          | Source_terminal.Durable_owner_identity_changed
          | Source_terminal.Source_queue_validation_failed _ )
      ; _
      } ->
    `Conflict
  | Resume_rejected
      { cause =
          ( Resume.Receipt_lock_failed _
          | Resume.Receipt_read_failed _
          | Resume.Receipt_write_failed _
          | Resume.Durable_meta_read_failed _
          | Resume.Registry_owner_missing
          | Resume.Projection_failed _ )
      ; _
      }
  | Cancellation_rejected (Cancellation.Admission_busy _)
  | Cancellation_rejected (Cancellation.Owner_unavailable _)
  | Transfer_rejected { cause = Transfer.Admission_busy _; _ }
  | Transfer_rejected { cause = Transfer.Owner_unavailable _; _ }
  | Source_terminal_rejected { cause = Source_terminal.Admission_busy _; _ }
  | Source_terminal_rejected { cause = Source_terminal.Owner_unavailable _; _ }
  | Cancellation_rejected
      (Cancellation.Failed
        { cause =
            ( Cancellation.Durable_meta_read_failed _
            | Cancellation.Queue_replay_failed _
            | Cancellation.Queue_commit_failed _ )
        ; _
        })
  | Transfer_rejected
      { cause =
          ( Transfer.Receipt_lock_failed _
          | Transfer.Receipt_read_failed _
          | Transfer.Receipt_write_failed _
          | Transfer.Durable_meta_read_failed _
          | Transfer.Source_transfer_shutdown_reserved _
          | Transfer.Target_transfer_shutdown_reserved _
          | Transfer.Committed_projection_failed _ )
      ; _
      }
  | Source_terminal_rejected
      { cause =
          ( Source_terminal.Receipt_lock_failed _
          | Source_terminal.Receipt_read_failed _
          | Source_terminal.Receipt_write_failed _
          | Source_terminal.Durable_meta_read_failed _
          | Source_terminal.Committed_ack_failed _ )
      ; _
      } ->
    `Unavailable
;;

let pending_item_to_yojson
      (selection : Queue_state.pending_selection)
  =
  let source = selection.source in
  let source_terminal_receipt_kind =
    match Queue_state.source_terminal_receipt_of_stimulus source with
    | Ok receipt -> `String (Disposition.source_terminal_receipt_kind receipt)
    | Error _ -> `Null
  in
  `Assoc
    [ "source", Queue.stimulus_to_yojson source
    ; "source_incarnation", `Intlit (Int64.to_string selection.admitted_revision)
    ; ( "continuation_binding"
      , Disposition.continuation_binding_of_source source
        |> Disposition.continuation_binding_to_yojson )
    ; "source_terminal_receipt_kind", source_terminal_receipt_kind
    ]
;;

let inventory_json config ~keeper_name =
  let* meta =
    Keeper_meta_store.read_meta config keeper_name
    |> Result.map_error (fun detail -> Inventory_meta_read_failed detail)
  in
  let* meta =
    match meta with
    | Some meta -> Ok meta
    | None -> Error Inventory_meta_missing
  in
  let* state =
    Keeper_event_queue_persistence.load_state_result
      ~base_path:config.Workspace.base_path
      ~keeper_name
    |> Result.map_error (fun detail -> Inventory_queue_read_failed detail)
  in
  let pending = Queue_state.pending_selections state in
  let pause_kind = Keeper_activation_readiness.pause_kind meta in
  Ok
    (`Assoc
      [ "schema", `String "masc.keeper.paused-work.inventory.v2"
      ; "operator_request_schema", `String Request.schema
      ; "keeper_name", `String keeper_name
      ; ( "owner"
        , `Assoc
            [ "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
            ; "generation", `Int meta.runtime.nonce
            ; "paused", `Bool meta.paused
            ; ( "pause_kind"
              , `String (Keeper_activation_readiness.pause_kind_to_wire pause_kind) )
            ] )
      ; ( "queue"
        , `Assoc
            [ "revision", `Intlit (Int64.to_string (Queue_state.revision state))
            ; "pending_count", `Int (List.length pending)
            ; "pending", `List (List.map pending_item_to_yojson pending)
            ; ( "transition_outbox_count"
              , `Int (List.length (Queue_state.transition_outbox state)) )
            ; ( "accepted_transfer_projection_count"
              , `Int
                  (List.length (Queue_state.accepted_transfer_projections state)) )
            ] )
      ])
;;

let inventory_error_to_string = function
  | Inventory_meta_read_failed detail -> "keeper metadata read failed: " ^ detail
  | Inventory_meta_missing -> "keeper metadata is missing"
  | Inventory_queue_read_failed detail -> "keeper event queue read failed: " ^ detail
;;
