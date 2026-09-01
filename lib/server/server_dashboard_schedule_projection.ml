(** Schedule projection owner.

    Sole producer of the [masc.dashboard.scheduled_automation.v1] JSON. Reads
    {!Schedule_store} directly; no other module renders this projection.

    Extracted from [server_dashboard_http_runtime_info.ml], where it sat
    alongside the tool inventory and was published as a nested field of
    [/api/v1/dashboard/tools]. The dedicated route
    [/api/v1/dashboard/scheduled-automation] now serves it, so a surface that
    needs schedule state no longer fetches the whole tool inventory to get it.

    Callers run on an Eio fiber, so route handlers wrap the entry point in
    [Domain_pool_ref.submit_io_or_inline]: the schedule ledger read is disk I/O
    and belongs on a worker domain, not the request fiber.

    A schedule-store read failure is reported as a typed fact
    ([status = "unknown"], null counts, [schedule_store_read_error]); it is
    never flattened to zero, which would read as "no schedules" rather than
    "the ledger could not be read". *)

(* TEL-OK: every function here is a pure [record -> Yojson.Safe.t] renderer over
   state the caller already read. This projection dispatches nothing and mutates
   no durable state. Queue evidence uses the non-locking, non-compacting
   request-local snapshot, while reaction evidence is one request-local batch
   per Keeper. Read failures remain typed projection facts. Telemetry for the
   described actions lives with Schedule_runner for dispatch and
   Keeper_event_queue for wake intake.

   The telemetry ratchet flags these as new handlers because this module is a
   new file; the code moved here verbatim from
   server_dashboard_http_runtime_info.ml, where it was equally untelemetered. *)

let take = Server_dashboard_http_runtime_info_json.take

let schedule_projection_request_limit = 20

let unix_iso_json ts = `String (Masc_domain.iso8601_of_unix_seconds ts)

let unix_iso_option_json = function
  | None -> `Null
  | Some ts -> unix_iso_json ts
;;

let schedule_status_count schedules status =
  List.fold_left
    (fun count (request : Schedule_domain.schedule_request) ->
      if request.status = status then count + 1 else count)
    0 schedules
;;

let schedule_counts_json schedules =
  `Assoc
    (List.map
       (fun status ->
         ( Schedule_domain.schedule_status_to_string status
         , `Int (schedule_status_count schedules status) ))
       Schedule_domain.all_schedule_statuses)
;;

type schedule_payload_support =
  | Supported
  | Unsupported
  | Unknown

let schedule_payload_support (request : Schedule_domain.schedule_request) =
  match Schedule_payload_projection.support_status request with
  | Schedule_payload_projection.Supported -> Supported
  | Schedule_payload_projection.Unsupported -> Unsupported
  | Schedule_payload_projection.Unknown -> Unknown
;;

let schedule_payload_support_to_string = function
  | Supported -> "supported"
  | Unsupported -> "unsupported"
  | Unknown -> "unknown"
;;

let schedule_payload_support_status request =
  schedule_payload_support request |> schedule_payload_support_to_string
;;

let schedule_payload_support_json schedules =
  Schedule_payload_projection.support_summary_to_yojson schedules
;;

let schedule_request_active (request : Schedule_domain.schedule_request) =
  not (Schedule_domain.is_terminal request.status)
;;

let schedule_due_candidate (request : Schedule_domain.schedule_request) =
  match request.status with
  | Schedule_domain.Scheduled | Schedule_domain.Due ->
    true
  | Schedule_domain.Running
  | Schedule_domain.Succeeded
  | Schedule_domain.Failed
  | Schedule_domain.Cancelled
  | Schedule_domain.Expired ->
    false
;;

let schedule_next_due_at schedules =
  schedules
  |> List.filter schedule_due_candidate
  |> List.fold_left
       (fun acc (request : Schedule_domain.schedule_request) ->
         match acc with
         | None -> Some request.due_at
         | Some ts -> Some (min ts request.due_at))
       None
;;

let schedule_fsm_state schedules =
  let count status = schedule_status_count schedules status in
  if count Schedule_domain.Running > 0
  then "running"
  else if count Schedule_domain.Due > 0
  then "due"
  else if count Schedule_domain.Scheduled > 0
  then "scheduled"
  else "idle"
;;

let wake_record_dashboard_json (wake : Schedule_domain.wake_record) =
  match Schedule_domain.wake_record_to_yojson wake with
  | `Assoc fields ->
    `Assoc
      (fields
       @ [ "started_at_iso", unix_iso_json wake.started_at
         ; "finished_at_iso", unix_iso_option_json wake.finished_at
         ])
  | other -> other
;;

let schedule_dispatch_receipt_dashboard_json
  (wake : Schedule_domain.wake_record option)
  =
  match wake with
  | None -> `Null
  | Some wake ->
    (match wake.Schedule_domain.detail with
     | None -> `Null
     | Some detail ->
    (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
     | Ok receipt ->
       (match Server_schedule_consumers.dispatch_receipt_to_yojson receipt with
        | `Assoc fields -> `Assoc (("projection_status", `String "recognized") :: fields)
        | other -> other)
     | Error reason ->
       `Assoc
         [ "projection_status", `String "unrecognized_detail"
         ; "reason", `String reason
         ]))
;;

module String_set = Set.Make (String)

type keeper_reaction_evidence_batch =
  ( (string * Keeper_reaction_ledger.event_queue_reaction_evidence_outcome) list
  , Keeper_reaction_ledger.event_queue_reaction_evidence_error )
  result

type schedule_evidence_snapshot =
  { queue_by_keeper :
      (string, Keeper_event_queue_persistence.snapshot_with_errors) Hashtbl.t
  ; reaction_by_keeper : (string, keeper_reaction_evidence_batch) Hashtbl.t
  }

let schedule_keeper_receipt_identity (wake : Schedule_domain.wake_record option) =
  match wake with
  | None -> None
  | Some wake ->
    (match wake.Schedule_domain.detail with
     | None -> None
     | Some detail ->
       (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
        | Error _ -> None
        | Ok
            (Server_schedule_consumers.Keeper_wake_enqueued
              { keeper_name; stimulus_id; _ }) ->
          Some (keeper_name, stimulus_id)))
;;

let schedule_evidence_snapshot ~config wakes =
  let requested_stimulus_ids = Hashtbl.create (List.length wakes) in
  List.iter
    (fun wake ->
       match schedule_keeper_receipt_identity wake with
       | None -> ()
       | Some (keeper_name, stimulus_id) ->
         let existing =
           match Hashtbl.find_opt requested_stimulus_ids keeper_name with
           | Some existing -> existing
           | None -> String_set.empty
         in
         let requested =
           match stimulus_id with
           | None -> existing
           | Some stimulus_id -> String_set.add stimulus_id existing
         in
         Hashtbl.replace requested_stimulus_ids keeper_name requested)
    wakes;
  let queue_by_keeper = Hashtbl.create (Hashtbl.length requested_stimulus_ids) in
  let reaction_by_keeper = Hashtbl.create (Hashtbl.length requested_stimulus_ids) in
  Hashtbl.iter
    (fun keeper_name stimulus_ids ->
       Hashtbl.add
         queue_by_keeper
         keeper_name
         (Keeper_event_queue_persistence.observe_snapshot_with_errors
            ~base_path:config.Workspace_utils.base_path
            ~keeper_name);
       Hashtbl.add
         reaction_by_keeper
         keeper_name
         (Keeper_reaction_ledger.event_queue_reaction_evidence_batch_result
            ~base_path:config.Workspace_utils.base_path
            ~keeper_name
            ~stimulus_ids:(String_set.elements stimulus_ids)))
    requested_stimulus_ids;
  { queue_by_keeper; reaction_by_keeper }
;;

type schedule_reaction_evidence_lookup =
  | Reaction_evidence_observed of
      Keeper_reaction_ledger.event_queue_reaction_evidence_outcome
  | Reaction_evidence_failed of
      Keeper_reaction_ledger.event_queue_reaction_evidence_error
  | Reaction_evidence_not_captured

let schedule_reaction_evidence_lookup snapshot ~keeper_name ~stimulus_id =
  match Hashtbl.find_opt snapshot.reaction_by_keeper keeper_name with
  | None -> Reaction_evidence_not_captured
  | Some (Error error) -> Reaction_evidence_failed error
  | Some (Ok evidence_by_id) ->
    (match List.assoc_opt stimulus_id evidence_by_id with
     | Some evidence -> Reaction_evidence_observed evidence
     | None -> Reaction_evidence_not_captured)
;;

let schedule_queue_read_error_dashboard_json
  (error : Keeper_event_queue_persistence.snapshot_read_error)
  =
  `Assoc
    [ "kind", `String (Keeper_event_queue_persistence.snapshot_read_error_kind_to_string error.kind)
    ; ( "path"
      , match error.path with
        | None -> `Null
        | Some path -> `String path )
    ; "message", `String error.message
    ]
;;

let schedule_queue_match
  ~(schedule_instance_id : string)
  ~(schedule_id : string)
  ~(due_at : float)
  ~(payload_digest : string)
  ~(post_id : string)
  ~(stimulus_label : string)
  (queue : Keeper_event_queue.t)
  =
  queue
  |> Keeper_event_queue.to_list
  |> List.find_opt (fun (stimulus : Keeper_event_queue.stimulus) ->
    String.equal stimulus.post_id post_id
    && String.equal (Keeper_event_queue.payload_kind_label stimulus.payload) stimulus_label
    &&
    match stimulus.payload with
    | Keeper_event_queue.Schedule_due wake ->
      String.equal wake.schedule_instance_id schedule_instance_id
      && String.equal wake.schedule_id schedule_id
      && Float.equal wake.due_at due_at
      && String.equal wake.payload_digest payload_digest
    | _ -> false)
;;

let schedule_queue_match_fields ~now bucket (stimulus : Keeper_event_queue.stimulus) =
  let scheduled_wake =
    match stimulus.payload with
    | Keeper_event_queue.Schedule_due wake -> Some wake
    | _ -> None
  in
  [ "matched_bucket", `String bucket
  ; "matched_post_id", `String stimulus.post_id
  ; "matched_payload_kind", `String (Keeper_event_queue.payload_kind_label stimulus.payload)
  ; "matched_arrived_at", `Float stimulus.arrived_at
  ; "matched_arrived_at_iso", unix_iso_json stimulus.arrived_at
  ; ( "matched_schedule_id"
    , match scheduled_wake with
      | Some wake -> `String wake.schedule_id
      | None -> `Null )
  ; ( "matched_schedule_instance_id"
    , match scheduled_wake with
      | Some wake -> `String wake.schedule_instance_id
      | None -> `Null )
  ; ( "matched_due_at"
    , match scheduled_wake with
      | Some wake -> `Float wake.due_at
      | None -> `Null )
  ; ( "matched_due_at_iso"
    , match scheduled_wake with
      | Some wake -> unix_iso_json wake.due_at
      | None -> `Null )
  ; ( "matched_payload_digest"
    , match scheduled_wake with
      | Some wake -> `String wake.payload_digest
      | None -> `Null )
  ; "matched_age_seconds", `Float (Float.max 0.0 (now -. stimulus.arrived_at))
  ]
;;

let schedule_keeper_queue_evidence_dashboard_json
  ~now
  ~evidence_snapshot
  ~(schedule_status : Schedule_domain.schedule_status)
  (wake : Schedule_domain.wake_record option)
  =
  (* A cancelled schedule is an explicit operator withdrawal: no future
     occurrence will ever consume an already-enqueued wake, and the keeper it
     was aimed at is often gone or unknown (task-370 live evidence: 17
     cancelled rows stuck in awaiting_ack up to 22.8 days, across four
     restarts and three builds). Matching such a wake against the pending
     queue as [matched_pending] presents a withdrawn leftover as live
     in-flight work — the dashboard-side face of the infinite retain. Only
     Cancelled is reclassified: a Succeeded one-shot's awaiting-ack wake is
     a legitimately delivered stimulus the keeper may still consume, and
     Failed/Expired retain their current meaning. The wake stays visible
     with its identity fields, but as a retained remainder, not pending
     work. *)
  let schedule_cancelled =
    match schedule_status with
    | Schedule_domain.Cancelled -> true
    | _ -> false
  in
  match wake with
  | None -> `Null
  | Some wake ->
    (match wake.Schedule_domain.detail with
     | None -> `Null
     | Some detail ->
       (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
        | Error reason ->
          `Assoc
            [ "projection_status", `String "unrecognized_receipt"
            ; "reason", `String reason
            ]
        | Ok
            (Server_schedule_consumers.Keeper_wake_enqueued
              { keeper_name
              ; schedule_instance_id = _
              ; schedule_id
              ; urgency = _
              ; post_id
              ; queue
              ; stimulus
              ; stimulus_id = _
              ; reaction_ledger_status = _
              ; result_delivery_policy = _
              ; occurrence_status = _
              ; activation_outcome = _
              }) ->
          let due_at = wake.Schedule_domain.due_at in
          let payload_digest = wake.Schedule_domain.payload_digest in
          let snapshot =
            match Hashtbl.find_opt evidence_snapshot.queue_by_keeper keeper_name with
            | Some snapshot -> snapshot
            | None ->
              { Keeper_event_queue_persistence.pending = Keeper_event_queue.empty
              ; read_errors =
                  [ { kind = Keeper_event_queue_persistence.Read_failed
                    ; path = None
                    ; message =
                        "queue evidence was not captured in the request snapshot"
                    }
                  ]
              }
          in
          let pending_match =
            schedule_queue_match
              ~schedule_instance_id:wake.schedule_instance_id
              ~schedule_id
              ~due_at
              ~payload_digest
              ~post_id
              ~stimulus_label:stimulus snapshot.pending
          in
          let read_errors =
            List.map schedule_queue_read_error_dashboard_json snapshot.read_errors
          in
          let base_fields =
            [ "source", `String "durable_event_queue_snapshot"
            ; "queue", `String queue
            ; "stimulus", `String stimulus
            ; "keeper_name", `String keeper_name
            ; "schedule_instance_id", `String wake.schedule_instance_id
            ; "schedule_id", `String schedule_id
            ; "post_id", `String post_id
            ; "wake_due_at", `Float due_at
            ; "wake_due_at_iso", unix_iso_json due_at
            ; "wake_payload_digest", `String payload_digest
            ; "schedule_status", `String (Schedule_domain.schedule_status_to_string schedule_status)
            ; "pending_count", `Int (Keeper_event_queue.length snapshot.pending)
            ; "read_errors", `List read_errors
            ]
          in
          (match pending_match, snapshot.read_errors with
           | Some match_, _ when schedule_cancelled ->
             `Assoc
               (( "projection_status"
                , `String "retained_terminal_wake" )
                :: base_fields
                @ schedule_queue_match_fields ~now "retained" match_)
           | Some match_, _ ->
             `Assoc
               (("projection_status", `String "matched_pending")
                :: base_fields
                @ schedule_queue_match_fields ~now "pending" match_)
           | None, _ :: _ ->
             `Assoc (("projection_status", `String "read_error") :: base_fields)
           | None, [] when schedule_cancelled ->
             (* Cancel propagation (task-370): the cancel boundary withdraws a
                cancelled schedule's enqueued utterance from the durable queue,
                so an absent pending match is the healthy outcome here, not a
                lost wake. Rows written before that propagation may still show
                a legacy [retained_terminal_wake] match above. *)
             `Assoc
               (( "projection_status"
                , `String "withdrawn_at_cancel" )
                :: base_fields)
           | None, [] ->
             `Assoc (("projection_status", `String "not_found") :: base_fields))))
;;

let schedule_keeper_reaction_evidence_dashboard_json
  ~evidence_snapshot
  (wake : Schedule_domain.wake_record option)
  =
  match wake with
  | None -> `Null
  | Some wake ->
    (match wake.Schedule_domain.detail with
     | None -> `Null
     | Some detail ->
       (match Server_schedule_consumers.dispatch_receipt_of_detail detail with
        | Error reason ->
          `Assoc
            [ "projection_status", `String "unrecognized_receipt"
            ; "reason", `String reason
            ]
        | Ok
            (Server_schedule_consumers.Keeper_wake_enqueued
              { keeper_name
              ; schedule_instance_id
              ; schedule_id
              ; urgency = _
              ; post_id
              ; queue = _
              ; stimulus
              ; stimulus_id
              ; reaction_ledger_status = _
              ; result_delivery_policy = _
              ; occurrence_status = _
              ; activation_outcome = _
              }) ->
          let base_fields =
            [ "source", `String "keeper_reaction_ledger"
            ; "keeper_name", `String keeper_name
            ; "schedule_instance_id", `String schedule_instance_id
            ; "schedule_id", `String schedule_id
            ; "post_id", `String post_id
            ; "stimulus", `String stimulus
            ; ( "reaction_kind"
              , `String
                  (Keeper_reaction_ledger.reaction_kind_to_string
                     Keeper_reaction_ledger.Turn_started) )
            ; ( "stimulus_kind"
              , `String
                  (Keeper_reaction_ledger.stimulus_kind_to_string
                     Keeper_reaction_ledger.Schedule_due) )
            ]
          in
          (match stimulus_id with
           | None ->
             `Assoc
               (("projection_status", `String "missing_stimulus_id")
                :: ("reason", `String "dispatch receipt predates stimulus_id projection")
                :: base_fields)
           | Some stimulus_id ->
             let evidence_fields
                   (evidence : Keeper_reaction_ledger.event_queue_reaction_evidence)
               =
               [ "stimulus_id", `String stimulus_id
                  ; "stimulus_seen", `Bool evidence.stimulus_seen
                  ; "turn_started_seen", `Bool evidence.turn_started_seen
                  ; "turn_finished_seen", `Bool evidence.turn_finished_seen
                  ; "event_queue_ack_seen", `Bool evidence.event_queue_ack_seen
                  ; ( "event_queue_cancelled_seen"
                    , `Bool evidence.event_queue_cancelled_seen )
                  ; "matched_record_count", `Int evidence.matched_record_count
                  ; ( "quarantined_record_count"
                    , `Int evidence.quarantined_record_count )
                  ; ( "stimulus_recorded_at"
                    , match evidence.stimulus_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "stimulus_recorded_at_iso"
                    , unix_iso_option_json evidence.stimulus_recorded_at )
                  ; ( "turn_finished_recorded_at"
                    , match evidence.turn_finished_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "turn_finished_recorded_at_iso"
                    , unix_iso_option_json evidence.turn_finished_recorded_at )
                  ; ( "turn_started_recorded_at"
                    , match evidence.turn_started_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "turn_started_recorded_at_iso"
                    , unix_iso_option_json evidence.turn_started_recorded_at )
                  ; ( "event_queue_ack_recorded_at"
                    , match evidence.event_queue_ack_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "event_queue_ack_recorded_at_iso"
                    , unix_iso_option_json evidence.event_queue_ack_recorded_at )
                  ; ( "event_queue_cancelled_recorded_at"
                    , match evidence.event_queue_cancelled_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "event_queue_cancelled_recorded_at_iso"
                    , unix_iso_option_json
                        evidence.event_queue_cancelled_recorded_at )
                  ; ( "latest_recorded_at"
                    , match evidence.latest_recorded_at with
                      | None -> `Null
                      | Some ts -> `Float ts )
                  ; ( "latest_recorded_at_iso"
                    , unix_iso_option_json evidence.latest_recorded_at )
                  ]
             in
             let projection_json ?reason ?(extra_fields=[]) status evidence =
               let reason_fields =
                 match reason with
                 | Some value -> [ "reason", `String value ]
                 | None -> []
               in
               `Assoc
                 (("projection_status", `String status)
                  :: base_fields
                  @ evidence_fields evidence
                  @ reason_fields
                  @ extra_fields)
             in
             (match
                schedule_reaction_evidence_lookup
                  evidence_snapshot
                  ~keeper_name
                  ~stimulus_id
              with
              | Reaction_evidence_failed
                  Keeper_reaction_ledger.Evidence_invalid_stimulus_id ->
                let error =
                  Keeper_reaction_ledger.Evidence_invalid_stimulus_id
                in
                `Assoc
                  (("projection_status", `String "invalid_stimulus_id")
                   :: ( "reason"
                      , `String
                          (Keeper_reaction_ledger
                           .event_queue_reaction_evidence_error_to_string
                             error) )
                   :: base_fields
                   @ [ "stimulus_id", `String stimulus_id ])
              | Reaction_evidence_failed
                  (Keeper_reaction_ledger.Evidence_read_error _ as error) ->
                `Assoc
                  (("projection_status", `String "read_error")
                   :: ( "reason"
                      , `String
                          (Keeper_reaction_ledger
                           .event_queue_reaction_evidence_error_to_string
                             error) )
                   :: base_fields
                   @ [ "stimulus_id", `String stimulus_id ])
              | Reaction_evidence_not_captured ->
                `Assoc
                  (("projection_status", `String "read_error")
                   :: ( "reason"
                      , `String
                          "reaction evidence was not captured in the request snapshot" )
                   :: base_fields
                   @ [ "stimulus_id", `String stimulus_id ])
              | Reaction_evidence_observed
                  (Keeper_reaction_ledger.Evidence_complete evidence) ->
                let projection_status =
                  if
                    evidence.event_queue_ack_seen
                    && evidence.event_queue_cancelled_seen
                  then "conflicting_terminal_evidence"
                  else if evidence.event_queue_cancelled_seen
                  then "matched_terminal_cancelled"
                  else if evidence.event_queue_ack_seen
                  then "matched_consumed_ack"
                  (* Finished outranks started: both rows are written for the
                     same stimulus, and the later one is the more complete
                     reading of what happened. *)
                  else if evidence.turn_finished_seen
                  then "matched_turn_finished"
                  else if evidence.turn_started_seen
                  then "matched_turn_started"
                  else if evidence.stimulus_seen
                  then "matched_stimulus"
                  else "not_found"
                in
                projection_json projection_status evidence
              | Reaction_evidence_observed
                  (Keeper_reaction_ledger.Evidence_quarantined
                    { evidence; first_reason }) ->
                projection_json
                  ~reason:
                    (Keeper_reaction_ledger.row_quarantine_reason_to_string
                       first_reason)
                  "quarantined"
                  evidence))))
;;

let schedule_signal_projection_limit = 20

let schedule_signal_payload_kind_json (signal : Schedule_runner.wake_signal) =
  match signal.payload with
  | `Assoc fields ->
    (match List.assoc_opt "kind" fields with
     | Some (`String kind) -> `String kind
     | _ -> `Null)
  | _ -> `Null
;;

let schedule_signal_dashboard_json (signal : Schedule_runner.wake_signal) =
  let kind = Schedule_runner.signal_kind_to_string signal.kind in
  `Assoc
    [ ( "occurrence_id"
      , `String (Schedule_occurrence_id.to_string signal.occurrence_id) )
    ; "kind", `String kind
    ; "event_type", `String kind
    ; "schedule_instance_id", `String signal.schedule_instance_id
    ; "schedule_id", `String signal.schedule_id
    ; "emitted_at", `Float signal.emitted_at
    ; "emitted_at_iso", unix_iso_json signal.emitted_at
    ; "due_at", `Float signal.due_at
    ; "due_at_iso", unix_iso_json signal.due_at
    ; "payload_digest", `String signal.payload_digest
    ; "payload_kind", schedule_signal_payload_kind_json signal
    ]
;;

type schedule_signal_projection_entry =
  | Decoded_schedule_signal of Schedule_runner.wake_signal
  | Schedule_signal_decode_error of int * string

let schedule_signal_decode_error_dashboard_json ordinal error =
  `Assoc [ "ordinal", `Int ordinal; "error", `String error ]
;;

let schedule_signal_rows_and_errors config limit =
  let entries =
    Dated_jsonl.read_recent
      (Dated_jsonl.create ~base_dir:(Schedule_runner.signals_dir config) ())
      limit
    |> List.mapi (fun ordinal json ->
      match Schedule_runner.wake_signal_of_yojson json with
      | Ok signal -> Decoded_schedule_signal signal
      | Error error -> Schedule_signal_decode_error (ordinal, error))
  in
  List.fold_right
    (fun entry (signals, errors) ->
       match entry with
       | Decoded_schedule_signal signal -> signal :: signals, errors
       | Schedule_signal_decode_error (ordinal, error) ->
         signals, schedule_signal_decode_error_dashboard_json ordinal error :: errors)
    entries
    ([], [])
;;

let schedule_request_dashboard_json
  ~now
  ~evidence_snapshot
  ?last_wake
  (request : Schedule_domain.schedule_request)
  =
  let next_due_at =
    match request.status with
    | Schedule_domain.Scheduled | Schedule_domain.Due -> Some request.due_at
    | Schedule_domain.Running
    | Schedule_domain.Succeeded
    | Schedule_domain.Failed
    | Schedule_domain.Cancelled
    | Schedule_domain.Expired ->
      None
  in
  let payload_target, payload_summary =
    Schedule_payload_projection.target_summary request
  in
  let payload_keeper_name =
    Schedule_payload_projection.wake_keeper_name request
  in
  `Assoc
    [ "schedule_instance_id", `String request.schedule_instance_id
    ; "schedule_id", `String request.schedule_id
    ; "status", `String (Schedule_domain.schedule_status_to_string request.status)
    ; "source", `String (Schedule_domain.schedule_source_to_string request.source)
    ; "requested_by", Schedule_domain.actor_to_yojson request.requested_by
    ; "scheduled_by", Schedule_domain.actor_to_yojson request.scheduled_by
    ; "requested_at", `Float request.requested_at
    ; "requested_at_iso", unix_iso_json request.requested_at
    ; "due_at", `Float request.due_at
    ; "due_at_iso", unix_iso_json request.due_at
    ; ( "next_due_at"
      , match next_due_at with
        | None -> `Null
        | Some ts -> `Float ts )
    ; "next_due_at_iso", unix_iso_option_json next_due_at
    ; "expires_at", (match request.expires_at with None -> `Null | Some ts -> `Float ts)
    ; "expires_at_iso", unix_iso_option_json request.expires_at
    ; "recurrence", Schedule_domain.recurrence_to_yojson request.recurrence
    ; "recurrence_kind", `String (Schedule_domain.recurrence_kind_to_string request.recurrence)
    ; "recurrence_summary", `String (Schedule_domain.recurrence_summary request.recurrence)
    ; "payload_digest", `String (Schedule_domain.payload_digest request.payload)
    ; "payload", Schedule_domain.payload_to_yojson request.payload
    ; ( "payload_kind"
      , match Schedule_payload_projection.kind request with
        | None -> `Null
        | Some kind -> `String kind )
    ; "payload_support", `String (schedule_payload_support_status request)
    ; ( "payload_dispatch_tool"
        (* Display getter: use the non-logging result variant. The logging
           [dispatch_tool_for_request] emits a WARN per unsupported row on every
           dashboard poll (terminal accept-then-die rows → ~600 WARN/5000 log
           lines); the genuine dispatch failure is logged once by the scheduler
           runner, not here. *)
      , match Schedule_payload_projection.dispatch_tool_for_request_result request with
        | Ok tool_name -> `String tool_name
        | Error _ -> `Null )
    ; ( "payload_target"
      , match payload_target with
        | None -> `Null
        | Some target -> `String target )
    ; ( "payload_keeper_name"
      , match payload_keeper_name with
        | None -> `Null
        | Some keeper_name -> `String keeper_name )
    ; ( "payload_summary"
      , match payload_summary with
        | None -> `Null
        | Some summary -> `String summary )
    ; ( "last_wake"
      , match last_wake with
        | None -> `Null
        | Some wake -> wake_record_dashboard_json wake )
    ; "dispatch_receipt", schedule_dispatch_receipt_dashboard_json last_wake
    ; ( "keeper_queue_evidence"
      , schedule_keeper_queue_evidence_dashboard_json
          ~now
          ~evidence_snapshot
          ~schedule_status:request.status
          last_wake )
    ; ( "keeper_reaction_evidence"
      , schedule_keeper_reaction_evidence_dashboard_json
          ~evidence_snapshot
          last_wake )
    ]
;;

let live_supported_evidence_ids_limit = 8

let schedule_live_supported_non_terminal_evidence_json schedules =
  let
    ( supported_request_count
    , supported_non_terminal_count
    , supported_live_count
    , supported_terminal_or_expired_count
    , unsupported_request_count
    , unknown_request_count
    , terminal_or_expired_count
    , matched_ids )
    =
    List.fold_left
      (fun
        ( supported_count
        , supported_non_terminal
        , supported_live
        , supported_terminal_or_expired
        , unsupported_count
        , unknown_count
        , terminal_or_expired
        , ids )
        (request : Schedule_domain.schedule_request)
       ->
         let live_row = schedule_request_active request in
         let terminal_or_expired_row = not live_row in
         let terminal_or_expired =
           if terminal_or_expired_row then terminal_or_expired + 1 else terminal_or_expired
         in
         match schedule_payload_support request with
         | Supported ->
           let non_terminal = not (Schedule_domain.is_terminal request.status) in
           let supported_non_terminal =
             if non_terminal then supported_non_terminal + 1 else supported_non_terminal
           in
           if live_row
           then (
             let ids =
               if List.length ids < live_supported_evidence_ids_limit
               then request.schedule_id :: ids
               else ids
             in
             ( supported_count + 1
             , supported_non_terminal
             , supported_live + 1
             , supported_terminal_or_expired
             , unsupported_count
             , unknown_count
             , terminal_or_expired
             , ids ))
           else
             ( supported_count + 1
             , supported_non_terminal
             , supported_live
             , supported_terminal_or_expired + 1
             , unsupported_count
             , unknown_count
             , terminal_or_expired
             , ids )
         | Unsupported ->
           ( supported_count
           , supported_non_terminal
           , supported_live
           , supported_terminal_or_expired
           , unsupported_count + 1
           , unknown_count
           , terminal_or_expired
           , ids )
         | Unknown ->
           ( supported_count
           , supported_non_terminal
           , supported_live
           , supported_terminal_or_expired
           , unsupported_count
           , unknown_count + 1
           , terminal_or_expired
           , ids ))
      (0, 0, 0, 0, 0, 0, 0, [])
      schedules
  in
  let request_count = List.length schedules in
  let projection_status =
    if supported_live_count > 0
    then "matched_supported_non_terminal"
    else if supported_request_count = 0 && request_count > 0
    then "no_supported_payload_rows"
    else "no_supported_non_terminal"
  in
  let reason =
    if supported_live_count > 0
    then "live schedule_store contains supported non-terminal rows"
    else if supported_request_count = 0 && request_count > 0
    then "current live schedule_store has no rows with a supported payload kind"
    else "supported rows are currently terminal"
  in
  `Assoc
    [ "schema", `String "masc.dashboard.scheduled_automation.live_supported_non_terminal_evidence.v1"
    ; "source", `String "schedule_store"
    ; "projection_status", `String projection_status
    ; ( "criteria"
      , `String
          "payload_support=supported && status is non-terminal" )
    ; "reason", `String reason
    ; "request_count", `Int request_count
    ; "supported_request_count", `Int supported_request_count
    ; "supported_non_terminal_count", `Int supported_non_terminal_count
    ; "supported_live_count", `Int supported_live_count
    ; "supported_terminal_or_expired_count", `Int supported_terminal_or_expired_count
    ; "unsupported_request_count", `Int unsupported_request_count
    ; "unknown_request_count", `Int unknown_request_count
    ; "terminal_or_expired_count", `Int terminal_or_expired_count
    ; ( "matched_schedule_ids"
      , `List (List.map (fun schedule_id -> `String schedule_id) (List.rev matched_ids)) )
    ; "matched_schedule_id_limit", `Int live_supported_evidence_ids_limit
    ]
;;

let schedule_request_rows_dashboard_json ~config ~now state request_rows =
  let request_rows_with_wakes =
    List.map
      (fun (request : Schedule_domain.schedule_request) ->
         let last_wake =
           Schedule_store.last_wake_for_schedule_instance state
             ~schedule_instance_id:request.Schedule_domain.schedule_instance_id
             ~schedule_id:request.Schedule_domain.schedule_id
         in
         request, last_wake)
      request_rows
  in
  let evidence_snapshot =
    schedule_evidence_snapshot
      ~config
      (List.map snd request_rows_with_wakes)
  in
  List.map
    (fun (request, last_wake) ->
       schedule_request_dashboard_json
         ~now
         ~evidence_snapshot
         ?last_wake
         request)
    request_rows_with_wakes
;;

let scheduled_automation_dashboard_json (config : Workspace.config) : Yojson.Safe.t =
  (* Read-only projection; the schedule store remains the status SSOT. *)
  let now = Unix.gettimeofday () in
  let signal_rows, signal_errors =
    schedule_signal_rows_and_errors config schedule_signal_projection_limit
  in
  let base_fields =
    [ "schema", `String "masc.dashboard.scheduled_automation.v1"
    ; "source", `String "schedule_store"
    ; "generated_at", `String (Masc_domain.now_iso ())
    ; "signal_source", `String "schedule_runner_signals"
    ; "signal_count", `Int (List.length signal_rows)
    ; "signal_limit", `Int schedule_signal_projection_limit
    ; "signals", `List (List.map schedule_signal_dashboard_json signal_rows)
    ; "signal_errors", `List signal_errors
    ]
  in
  match Schedule_store.read_state_result config with
  | Error err ->
    let read_error =
      "schedule store read failed: " ^ Schedule_store.read_error_to_string err
    in
    `Assoc
      (base_fields
       @ [ "status", `String "unknown"
         ; "schedule_store_known", `Bool false
         ; "schedule_store_read_error", `String read_error
         ; "request_count", `Null
         ; "request_limit", `Int schedule_projection_request_limit
         ; "truncated", `Bool false
         ; "counts", `Null
         ; "payload_support", `Null
         ; "live_supported_non_terminal_evidence", `Null
         ; ( "fsm"
           , `Assoc
               [ "state", `String "unknown"
               ; "active_count", `Null
               ; "terminal_count", `Null
               ; "next_due_at", `Null
               ] )
         ; "requests", `List []
         ])
  | Ok state ->
    let schedules = state.schedules in
    let active_count =
      List.fold_left
        (fun count request ->
           if schedule_request_active request then count + 1 else count)
        0 schedules
    in
    let terminal_count = List.length schedules - active_count in
    let payload_support = schedule_payload_support_json schedules in
    let sorted =
      schedules
      |> List.sort (fun left right ->
        match
          ( schedule_request_active left
          , schedule_request_active right
          , compare left.due_at right.due_at )
        with
        | true, false, _ -> -1
        | false, true, _ -> 1
        | _, _, due_cmp when due_cmp <> 0 -> due_cmp
        | _ -> String.compare left.schedule_id right.schedule_id)
    in
    let request_rows = take schedule_projection_request_limit sorted in
    let request_jsons =
      schedule_request_rows_dashboard_json ~config ~now state request_rows
    in
    `Assoc
      (base_fields
       @ [ "status", `String "ok"
         ; "schedule_store_known", `Bool true
         ; "schedule_store_read_error", `Null
         ; "request_count", `Int (List.length schedules)
         ; "request_limit", `Int schedule_projection_request_limit
         ; "truncated", `Bool (List.length schedules > schedule_projection_request_limit)
         ; "counts", schedule_counts_json schedules
         ; "payload_support", payload_support
         ; ( "live_supported_non_terminal_evidence"
           , schedule_live_supported_non_terminal_evidence_json schedules )
         ; ( "fsm"
           , `Assoc
               [ "state", `String (schedule_fsm_state schedules)
               ; "active_count", `Int active_count
               ; "terminal_count", `Int terminal_count
               ; "next_due_at", unix_iso_option_json (schedule_next_due_at schedules)
               ] )
         ; "requests", `List request_jsons
         ])
;;

type exact_lookup_status =
  | Found
  | Not_found
  | Unavailable
  | Invalid_id

let exact_lookup_status_to_string = function
  | Found -> "found"
  | Not_found -> "not_found"
  | Unavailable -> "unavailable"
  | Invalid_id -> "invalid_id"
;;

let exact_lookup_json ~now ~schedule_id status fields =
  `Assoc
    ([ "schema", `String "masc.dashboard.scheduled_automation.lookup.v1"
     ; "source", `String "schedule_store"
     ; "generated_at", `String (Masc_domain.iso8601_of_unix_seconds now)
     ; "status", `String (exact_lookup_status_to_string status)
     ; "schedule_id", `String schedule_id
     ]
     @ fields)
;;

let scheduled_automation_exact_lookup_json config ~now ~schedule_id:raw_schedule_id =
  if String.trim raw_schedule_id = ""
  then
    exact_lookup_json
      ~now
      ~schedule_id:raw_schedule_id
      Invalid_id
      [ "reason", `String "schedule_id must be non-empty" ]
  else
    let schedule_id = raw_schedule_id in
    (match Schedule_store.read_state_result config with
     | Error err ->
       let reason =
         "schedule store read failed: " ^ Schedule_store.read_error_to_string err
       in
       exact_lookup_json
         ~now
         ~schedule_id
         Unavailable
         [ "reason", `String reason ]
     | Ok state ->
       (match
          List.find_opt
            (fun (request : Schedule_domain.schedule_request) ->
               String.equal request.schedule_id schedule_id)
            state.schedules
        with
        | None -> exact_lookup_json ~now ~schedule_id Not_found []
        | Some request ->
          let requests =
            schedule_request_rows_dashboard_json
              ~config
              ~now
              state
              [ request ]
          in
          (* The wake list rides the exact lookup and not the aggregate: the
             fleet page has one row per schedule and no room for each row's
             attempts, and until this endpoint carried them an operator could
             read exactly one of the up-to-32 the store keeps. The ceiling
             travels with the list so the count cannot be read as a complete
             history. *)
          let wakes =
            Schedule_store.wakes_for_schedule_instance
              state
              ~schedule_instance_id:request.schedule_instance_id
              ~schedule_id:request.schedule_id
          in
          (match requests with
           | [ request_json ] ->
             exact_lookup_json
               ~now
               ~schedule_id
               Found
               [ "request", request_json
               ; "wakes", `List (List.map wake_record_dashboard_json wakes)
               ; "wake_count", `Int (List.length wakes)
               ; ( "wake_retention_per_schedule"
                 , `Int Schedule_store.terminal_wakes_retained_per_schedule )
               ]
           | [] | _ :: _ :: _ ->
             exact_lookup_json
               ~now
               ~schedule_id
               Unavailable
               [ "reason", `String "exact schedule projection cardinality mismatch" ])))
;;
