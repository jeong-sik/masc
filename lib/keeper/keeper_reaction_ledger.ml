type cursor =
  { cursor_ts : float
  ; post_id : string option
  }

type stimulus_kind = Keeper_reaction_store.stimulus_kind =
  | Board_signal
  | Bootstrap
  | Fusion_completed
  | Bg_completed
  | Schedule_due
  | Connector_attention
  | Hitl_resolved
  | Failure_judgment
  | Manual_compaction
  | Goal_assigned

type reaction_kind = Keeper_reaction_store.reaction_kind =
  | Turn_started
  | Event_queue_ack
  | Event_queue_requeued
  | Event_queue_escalated
  | Cursor_ack

type reaction_decode_error = Unknown_reaction_kind of string

type write_outcome = Keeper_reaction_store.write_outcome =
  | Inserted
  | Already_recorded

type board_scan_integrity_error =
  | Initial_scan_contains_stimuli
  | Scan_target_precedes_expected of
      { expected : cursor
      ; target : cursor
      }
  | Scan_cursor_authority_disappeared of { expected : cursor }
  | Scan_cursor_regressed of
      { expected : cursor
      ; current : cursor
      }
  | Scan_stimulus_not_board_signal of { post_id : string }
  | Scan_stimulus_cursor_mismatch of
      { scanned : cursor
      ; stimulus : cursor
      }
  | Scan_stimulus_not_after_expected of
      { expected : cursor
      ; stimulus : cursor
      }
  | Scan_stimulus_after_target of
      { target : cursor
      ; stimulus : cursor
      }
  | Scan_stimuli_not_strictly_ordered of
      { previous : cursor
      ; current : cursor
      }

type ledger_error =
  | Store_error of Keeper_reaction_store.error
  | Invalid_turn_lease_sequence of int64
  | Board_scan_integrity_error of board_scan_integrity_error
  | Event_queue_coordination_lock_error of string
  | Event_queue_stimulus_admission_error of string
  | Event_queue_outbox_read_error of string
  | Event_queue_outbox_invariant of { observed_count : int }
  | Event_queue_outbox_retire_error of string

let ( let* ) = Result.bind

let stimulus_kind_to_string = Keeper_reaction_store.stimulus_kind_to_string
let stimulus_kind_of_string = Keeper_reaction_store.stimulus_kind_of_string
let reaction_kind_to_string = Keeper_reaction_store.reaction_kind_to_string

let reaction_kind_of_string value =
  match Keeper_reaction_store.reaction_kind_of_string value with
  | Some kind -> Ok kind
  | None -> Error (Unknown_reaction_kind value)
;;

let cursor_to_string (cursor : cursor) =
  let post_id =
    match cursor.post_id with
    | None -> "<none>"
    | Some post_id -> post_id
  in
  Printf.sprintf
    "(%0.6f, %s)"
    cursor.cursor_ts
    post_id
;;

let board_scan_integrity_error_to_string = function
  | Initial_scan_contains_stimuli ->
    "an uninitialized Board scan cannot contain replay stimuli"
  | Scan_target_precedes_expected { expected; target } ->
    Printf.sprintf
      "Board scan target %s precedes expected cursor %s"
      (cursor_to_string target)
      (cursor_to_string expected)
  | Scan_cursor_authority_disappeared { expected } ->
    Printf.sprintf
      "Board cursor authority disappeared after scan expected=%s"
      (cursor_to_string expected)
  | Scan_cursor_regressed { expected; current } ->
    Printf.sprintf
      "Board cursor regressed during scan expected=%s current=%s"
      (cursor_to_string expected)
      (cursor_to_string current)
  | Scan_stimulus_not_board_signal { post_id } ->
    Printf.sprintf "Board scan carried a non-Board_signal stimulus post_id=%s" post_id
  | Scan_stimulus_cursor_mismatch { scanned; stimulus } ->
    Printf.sprintf
      "Board scan stimulus cursor mismatch scanned=%s stimulus=%s"
      (cursor_to_string scanned)
      (cursor_to_string stimulus)
  | Scan_stimulus_not_after_expected { expected; stimulus } ->
    Printf.sprintf
      "Board scan stimulus %s is not after expected cursor %s"
      (cursor_to_string stimulus)
      (cursor_to_string expected)
  | Scan_stimulus_after_target { target; stimulus } ->
    Printf.sprintf
      "Board scan stimulus %s is after target cursor %s"
      (cursor_to_string stimulus)
      (cursor_to_string target)
  | Scan_stimuli_not_strictly_ordered { previous; current } ->
    Printf.sprintf
      "Board scan stimuli are not strictly ordered previous=%s current=%s"
      (cursor_to_string previous)
      (cursor_to_string current)
;;

let ledger_error_to_string = function
  | Store_error error -> Keeper_reaction_store.error_to_string error
  | Invalid_turn_lease_sequence sequence ->
    Printf.sprintf "turn-start lease sequence must be positive: %Ld" sequence
  | Board_scan_integrity_error error -> board_scan_integrity_error_to_string error
  | Event_queue_coordination_lock_error detail ->
    "event queue reaction coordination failed: " ^ detail
  | Event_queue_stimulus_admission_error detail ->
    "event queue Board stimulus admission failed: " ^ detail
  | Event_queue_outbox_read_error detail ->
    "event queue transition outbox read failed: " ^ detail
  | Event_queue_outbox_invariant { observed_count } ->
    Printf.sprintf
      "event queue has %d unprojected transitions; expected at most one"
      observed_count
  | Event_queue_outbox_retire_error detail ->
    "event queue transition outbox retire failed: " ^ detail
;;

let stimulus_kind_of_event_queue (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal _ | Keeper_event_queue.Board_attention _ ->
    Board_signal
  | Keeper_event_queue.Bootstrap -> Bootstrap
  | Keeper_event_queue.Fusion_completed _ -> Fusion_completed
  | Keeper_event_queue.Bg_completed _ -> Bg_completed
  | Keeper_event_queue.Schedule_due _ -> Schedule_due
  | Keeper_event_queue.Connector_attention _ -> Connector_attention
  | Keeper_event_queue.Hitl_resolved _ -> Hitl_resolved
  | Keeper_event_queue.Failure_judgment _ -> Failure_judgment
  | Keeper_event_queue.Manual_compaction_requested -> Manual_compaction
  | Keeper_event_queue.Goal_assigned _ -> Goal_assigned
;;

let stimulus_id_of_event_queue = Keeper_event_queue.stimulus_identity_id

let store_urgency = function
  | Keeper_event_queue.Immediate -> Keeper_reaction_store.Immediate
  | Normal -> Keeper_reaction_store.Normal
  | Low -> Keeper_reaction_store.Low
;;

let board_updated_at (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Board_signal board
  | Keeper_event_queue.Board_attention { signal = board; _ } -> Some board.updated_at
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Failure_judgment _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _ -> None
;;

let store_source (stimulus : Keeper_event_queue.stimulus) =
  Keeper_reaction_store.
    { stimulus_kind = stimulus_kind_of_event_queue stimulus
    ; post_id = stimulus.post_id
    }
;;

let stimulus_event ~recorded_at stimulus =
  let stimulus_id = stimulus_id_of_event_queue stimulus in
  Keeper_reaction_store.
    { event_id = stimulus_id ^ ":stimulus"
    ; stimulus_id
    ; recorded_at
    ; payload =
        Stimulus_event
          { kind = stimulus_kind_of_event_queue stimulus
          ; post_id = stimulus.post_id
          ; urgency = store_urgency stimulus.urgency
          ; arrived_at = stimulus.arrived_at
          ; board_updated_at = board_updated_at stimulus
          }
    }
;;

let record_event_queue_stimulus_result ~base_path ~keeper_name stimulus =
  let event = stimulus_event ~recorded_at:(Time_compat.now ()) stimulus in
  Keeper_reaction_store.append_event ~base_path ~keeper_name event
  |> Result.map_error (fun error -> Store_error error)
;;

let turn_started_event ~recorded_at ~lease_sequence stimulus =
  if Int64.compare lease_sequence 0L <= 0
  then Error (Invalid_turn_lease_sequence lease_sequence)
  else
    let stimulus_id = stimulus_id_of_event_queue stimulus in
    let event_identity =
      `Assoc
        [ "schema", `String "masc.keeper_reaction.turn_started.v1"
        ; "stimulus_id", `String stimulus_id
        ; "lease_sequence", `Intlit (Int64.to_string lease_sequence)
        ]
      |> Yojson.Safe.to_string
      |> Digestif.SHA256.digest_string
      |> Digestif.SHA256.to_hex
    in
    let event =
      Keeper_reaction_store.
        { event_id = "keeper-reaction:sha256:" ^ event_identity
        ; stimulus_id
        ; recorded_at
        ; payload = Turn_started_event (store_source stimulus)
        }
    in
    Ok event
;;

let record_event_queue_turn_started_result
      ~base_path
      ~keeper_name
      ~lease_sequence
      stimulus
  =
  let* event =
    turn_started_event ~recorded_at:(Time_compat.now ()) ~lease_sequence stimulus
  in
  Keeper_reaction_store.append_event ~base_path ~keeper_name event
  |> Result.map_error (fun error -> Store_error error)
;;

let record_event_queue_turn_admission_result
      ~base_path
      ~keeper_name
      ~lease_sequence
      stimuli
  =
  let recorded_at = Time_compat.now () in
  let rec build reversed = function
    | [] -> Ok (List.rev reversed)
    | stimulus :: rest ->
      let* turn = turn_started_event ~recorded_at ~lease_sequence stimulus in
      build (turn :: stimulus_event ~recorded_at stimulus :: reversed) rest
  in
  let* events = build [] stimuli in
  Keeper_reaction_store.append_events ~base_path ~keeper_name events
  |> Result.map (fun _ -> ())
  |> Result.map_error (fun error -> Store_error error)
;;

let transition_source receipt source_index stimulus =
  Keeper_reaction_store.
    { event_id = Printf.sprintf "%s:source:%d" receipt.Keeper_event_queue_state.event_id source_index
    ; stimulus_id = stimulus_id_of_event_queue stimulus
    ; stimulus_kind = stimulus_kind_of_event_queue stimulus
    ; post_id = stimulus.Keeper_event_queue.post_id
    }
;;

let store_settlement (settlement : Keeper_event_queue_state.settlement) =
  match settlement with
  | Keeper_event_queue_state.Ack -> Keeper_reaction_store.Ack, false
  | Keeper_event_queue_state.Requeue _ -> Keeper_reaction_store.Requeue, false
  | Keeper_event_queue_state.Escalate { reason; _ } ->
    ( Keeper_reaction_store.Escalate
    , Keeper_event_queue_state.escalation_reason_requests_external_input reason )
;;

let store_transition (entry : Keeper_event_queue_state.outbox_entry) =
  let receipt = entry.receipt in
  let settlement_kind, external_input_requested = store_settlement receipt.settlement in
  Keeper_reaction_store.
    { transition_id = receipt.transition_id
    ; transition_event_id = receipt.event_id
    ; lease_id = receipt.lease_id
    ; lease_sequence = receipt.lease_sequence
    ; settled_at = receipt.settled_at
    ; settlement_kind
    ; settlement_identity =
        Yojson.Safe.to_string
          (Keeper_event_queue_state.settlement_to_yojson receipt.settlement)
    ; external_input_requested
    ; sources = List.mapi (transition_source receipt) entry.stimuli
    }
;;

let project_event_queue_transition_outbox_locked_result ~base_path ~keeper_name =
  match Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name with
  | Error detail -> Error (Event_queue_outbox_read_error detail)
  | Ok [] -> Ok ()
  | Ok [ entry ] ->
    let transition = store_transition entry in
    let recorded_at = Time_compat.now () in
    let root_events = List.map (stimulus_event ~recorded_at) entry.stimuli in
    let* _ =
      Keeper_reaction_store.append_events_and_transition
        ~base_path
        ~keeper_name
        ~events:root_events
        transition
      |> Result.map_error (fun error -> Store_error error)
    in
    Keeper_registry_event_queue.mark_transition_projected_result
      ~base_path
      keeper_name
      ~transition_id:entry.receipt.transition_id
    |> Result.map_error (fun detail -> Event_queue_outbox_retire_error detail)
  | Ok entries ->
    Error (Event_queue_outbox_invariant { observed_count = List.length entries })
;;

let project_event_queue_transition_outbox_result ~base_path ~keeper_name =
  match Keeper_registry_event_queue.transition_outbox_result ~base_path keeper_name with
  | Error detail -> Error (Event_queue_outbox_read_error detail)
  (* An exact empty outbox has no cross-store work.  If settlement commits
     after this read, its queue transaction leaves the stimulus represented by
     the new outbox until a later projection, so no resurrection gap opens. *)
  | Ok [] -> Ok ()
  | Ok (_ :: _) ->
    (match
       Keeper_registry_event_queue.with_reaction_coordination_lock_result
         ~base_path
         ~keeper_name
         (fun () ->
            project_event_queue_transition_outbox_locked_result ~base_path ~keeper_name)
     with
     | Ok result -> result
     | Error detail -> Error (Event_queue_coordination_lock_error detail))
;;

let record_board_cursor_ack_uncoordinated_result
      ~base_path
      ~keeper_name
      ~cursor_ts
      ~post_id
      ()
  =
  let cursor = Keeper_reaction_store.{ cursor_ts; post_id } in
  let* stimulus_id =
    Keeper_reaction_store.cursor_identity_id cursor
    |> Result.map_error (fun error -> Store_error error)
  in
  let event =
    Keeper_reaction_store.
      { event_id = stimulus_id ^ ":cursor_ack"
      ; stimulus_id
      ; recorded_at = Time_compat.now ()
      ; payload = Cursor_ack_event cursor
      }
  in
  Keeper_reaction_store.append_event ~base_path ~keeper_name event
  |> Result.map_error (fun error -> Store_error error)
;;

let current_board_cursor_result ~base_path ~keeper_name =
  Keeper_reaction_store.current_cursor ~base_path ~keeper_name
  |> Result.map
       (Option.map (fun (cursor : Keeper_reaction_store.cursor) ->
          { cursor_ts = cursor.cursor_ts; post_id = cursor.post_id }))
  |> Result.map_error (fun error -> Store_error error)
;;

let after_board_stimuli_admitted_before_cursor_ack = Atomic.make (fun () -> ())

type board_scan_entry =
  { scan_cursor : cursor
  ; scan_stimulus : Keeper_event_queue.stimulus
  }

type board_scan_reconcile_outcome =
  | Board_scan_cursor_advanced of
      { suffix_stimulus_count : int
      ; skipped_prefix_stimulus_count : int
      }
  | Board_scan_already_reconciled

let store_cursor (cursor : cursor) : Keeper_reaction_store.cursor =
  { cursor_ts = cursor.cursor_ts; post_id = cursor.post_id }
;;

let normalize_ledger_cursor (cursor : cursor) =
  Keeper_reaction_store.normalize_cursor (store_cursor cursor)
  |> Result.map (fun (cursor : Keeper_reaction_store.cursor) ->
    { cursor_ts = cursor.cursor_ts; post_id = cursor.post_id })
  |> Result.map_error (fun error -> Store_error error)
;;

let compare_cursor left right =
  Keeper_reaction_store.compare_normalized_cursor
    (store_cursor left)
    (store_cursor right)
;;

let make_board_scan_entry ~(cursor : cursor) stimulus =
  let* scan_cursor = normalize_ledger_cursor cursor in
  match stimulus.Keeper_event_queue.payload with
  | Keeper_event_queue.Board_signal board_signal ->
    let* stimulus_cursor =
      normalize_ledger_cursor
        { cursor_ts = board_signal.updated_at; post_id = Some stimulus.post_id }
    in
    if compare_cursor scan_cursor stimulus_cursor = 0
    then Ok { scan_cursor; scan_stimulus = stimulus }
    else
      Error
        (Board_scan_integrity_error
           (Scan_stimulus_cursor_mismatch
              { scanned = scan_cursor; stimulus = stimulus_cursor }))
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Failure_judgment _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _ ->
    Error
      (Board_scan_integrity_error
         (Scan_stimulus_not_board_signal { post_id = stimulus.post_id }))
;;

let validate_board_scan_plan ~expected_cursor ~target_cursor entries =
  let* expected_cursor =
    match expected_cursor with
    | None -> Ok None
    | Some cursor -> Result.map Option.some (normalize_ledger_cursor cursor)
  in
  let* target_cursor = normalize_ledger_cursor target_cursor in
  match expected_cursor with
  | None ->
    if entries = []
    then Ok (None, target_cursor, entries)
    else Error (Board_scan_integrity_error Initial_scan_contains_stimuli)
  | Some expected ->
    if compare_cursor target_cursor expected < 0
    then
      Error
        (Board_scan_integrity_error
           (Scan_target_precedes_expected { expected; target = target_cursor }))
    else
      let rec validate previous = function
        | [] -> Ok (Some expected, target_cursor, entries)
        | entry :: rest ->
          if compare_cursor entry.scan_cursor expected <= 0
          then
            Error
              (Board_scan_integrity_error
                 (Scan_stimulus_not_after_expected
                    { expected; stimulus = entry.scan_cursor }))
          else if compare_cursor entry.scan_cursor target_cursor > 0
          then
            Error
              (Board_scan_integrity_error
                 (Scan_stimulus_after_target
                    { target = target_cursor; stimulus = entry.scan_cursor }))
          else
            (match previous with
             | Some previous when compare_cursor entry.scan_cursor previous <= 0 ->
               Error
                 (Board_scan_integrity_error
                    (Scan_stimuli_not_strictly_ordered
                       { previous; current = entry.scan_cursor }))
             | None | Some _ -> validate (Some entry.scan_cursor) rest)
      in
      validate None entries
;;

let admit_board_stimuli_and_record_cursor_ack_uncoordinated_result
      ~base_path
      ~keeper_name
      ~stimuli
      ~(cursor : cursor)
  =
  let* _committed =
    Keeper_registry_event_queue.enqueue_stimuli_durable_result
      ~base_path
      ~keeper_name
      stimuli
    |> Result.map_error (fun detail -> Event_queue_stimulus_admission_error detail)
  in
  (Atomic.get after_board_stimuli_admitted_before_cursor_ack) ();
  record_board_cursor_ack_uncoordinated_result
    ~base_path
    ~keeper_name
    ~cursor_ts:cursor.cursor_ts
    ~post_id:cursor.post_id
    ()
  |> Result.map (Fun.const ())
;;

let reconcile_board_scan_locked_result
      ~base_path
      ~keeper_name
      ~expected_cursor
      ~target_cursor
      entries
  =
  let* current_cursor = current_board_cursor_result ~base_path ~keeper_name in
  match expected_cursor, current_cursor with
  | None, Some _ -> Ok Board_scan_already_reconciled
  | None, None ->
    let* () =
      admit_board_stimuli_and_record_cursor_ack_uncoordinated_result
        ~base_path
        ~keeper_name
        ~stimuli:[]
        ~cursor:target_cursor
    in
    Ok
      (Board_scan_cursor_advanced
         { suffix_stimulus_count = 0; skipped_prefix_stimulus_count = 0 })
  | Some expected, None ->
    Error
      (Board_scan_integrity_error
         (Scan_cursor_authority_disappeared { expected }))
  | Some expected, Some current ->
    if compare_cursor current expected < 0
    then
      Error
        (Board_scan_integrity_error
           (Scan_cursor_regressed { expected; current }))
    else if compare_cursor current target_cursor >= 0
    then Ok Board_scan_already_reconciled
    else
      let rec after_current skipped = function
        | entry :: rest when compare_cursor entry.scan_cursor current <= 0 ->
          after_current (skipped + 1) rest
        | suffix -> skipped, suffix
      in
      let skipped_prefix_stimulus_count, suffix = after_current 0 entries in
      let stimuli = List.map (fun entry -> entry.scan_stimulus) suffix in
      let* () =
        admit_board_stimuli_and_record_cursor_ack_uncoordinated_result
          ~base_path
          ~keeper_name
          ~stimuli
          ~cursor:target_cursor
      in
      Ok
        (Board_scan_cursor_advanced
           { suffix_stimulus_count = List.length stimuli
           ; skipped_prefix_stimulus_count
           })
;;

let reconcile_board_scan_result
      ~base_path
      ~keeper_name
      ~expected_cursor
      ~target_cursor
      entries
  =
  let* expected_cursor, target_cursor, entries =
    validate_board_scan_plan ~expected_cursor ~target_cursor entries
  in
  match
    Keeper_registry_event_queue.with_reaction_coordination_lock_result
      ~base_path
      ~keeper_name
      (fun () ->
         reconcile_board_scan_locked_result
           ~base_path
           ~keeper_name
           ~expected_cursor
           ~target_cursor
           entries)
  with
  | Ok result -> result
  | Error detail -> Error (Event_queue_coordination_lock_error detail)
;;

module For_testing = struct
  let with_after_board_stimuli_admitted_before_cursor_ack_hook hook f =
    let prior = Atomic.exchange after_board_stimuli_admitted_before_cursor_ack hook in
    Fun.protect ~finally:(fun () -> Atomic.set after_board_stimuli_admitted_before_cursor_ack prior) f
  ;;
end

type event_queue_latest_reaction =
  | Latest_turn_started of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      }
  | Latest_event_queue_ack of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      }
  | Latest_event_queue_requeued of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      }
  | Latest_event_queue_escalated of
      { sequence : int64
      ; event_id : string
      ; recorded_at : float
      ; transition_id : string
      ; source_index : int
      ; source_count : int
      ; external_input_requested : bool
      }

type event_queue_reaction_evidence =
  { keeper_name : string
  ; stimulus_id : string
  ; stimulus_seen : bool
  ; turn_started_seen : bool
  ; event_queue_ack_seen : bool
  ; stimulus_recorded_at : float option
  ; turn_started_recorded_at : float option
  ; event_queue_ack_recorded_at : float option
  ; latest_reaction : event_queue_latest_reaction option
  ; latest_recorded_at : float option
  ; matched_record_count : int
  }

type event_queue_reaction_evidence_error =
  | Evidence_invalid_stimulus_id
  | Evidence_store_error of Keeper_reaction_store.error

let event_queue_reaction_evidence_error_to_string = function
  | Evidence_invalid_stimulus_id ->
    "reaction ledger evidence stimulus_id must be non-empty"
  | Evidence_store_error error -> Keeper_reaction_store.error_to_string error
;;

let latest_reaction_of_event (event : Keeper_reaction_store.stored_event) =
  let integrity_failure detail =
    Error (Evidence_store_error (Keeper_reaction_store.Integrity_failure detail))
  in
  match event.payload with
  | Keeper_reaction_store.Stored_turn_started _ ->
    Ok
      (Latest_turn_started
         { sequence = event.sequence
         ; event_id = event.event_id
         ; recorded_at = event.recorded_at
         })
  | Stored_transition_settlement
      { reaction_kind = Event_queue_ack
      ; transition_id
      ; source_index
      ; source_count
      ; external_input_requested = false
      ; _
      } ->
    Ok
      (Latest_event_queue_ack
         { sequence = event.sequence
         ; event_id = event.event_id
         ; recorded_at = event.recorded_at
         ; transition_id
         ; source_index
         ; source_count
         })
  | Stored_transition_settlement
      { reaction_kind = Event_queue_requeued
      ; transition_id
      ; source_index
      ; source_count
      ; external_input_requested = false
      ; _
      } ->
    Ok
      (Latest_event_queue_requeued
         { sequence = event.sequence
         ; event_id = event.event_id
         ; recorded_at = event.recorded_at
         ; transition_id
         ; source_index
         ; source_count
         })
  | Stored_transition_settlement
      { reaction_kind = Event_queue_escalated
      ; transition_id
      ; source_index
      ; source_count
      ; external_input_requested
      ; _
      } ->
    Ok
      (Latest_event_queue_escalated
         { sequence = event.sequence
         ; event_id = event.event_id
         ; recorded_at = event.recorded_at
         ; transition_id
         ; source_index
         ; source_count
         ; external_input_requested
         })
  | Stored_transition_settlement
      { reaction_kind = (Event_queue_ack | Event_queue_requeued)
      ; external_input_requested = true
      ; _
      } ->
    integrity_failure "non-escalated transition settlement requested external input"
  | Stored_transition_settlement
      { reaction_kind = (Turn_started | Cursor_ack); _ } ->
    integrity_failure "transition settlement carried a non-settlement reaction kind"
  | Stored_stimulus _ | Stored_cursor_ack _ ->
    integrity_failure "latest reaction query returned a non-reaction event"
;;

let evidence_of_store ~keeper_name ~stimulus_id (store : Keeper_reaction_store.stimulus_evidence) =
  let* latest_reaction =
    match store.latest_reaction_event with
    | None -> Ok None
    | Some event when String.equal event.stimulus_id stimulus_id ->
      Result.map Option.some (latest_reaction_of_event event)
    | Some _ ->
      Error
        (Evidence_store_error
           (Keeper_reaction_store.Integrity_failure
              "latest reaction query returned a foreign stimulus identity"))
  in
  Ok
    { keeper_name
    ; stimulus_id
    ; stimulus_seen = Option.is_some store.stimulus_recorded_at
    ; turn_started_seen = Option.is_some store.turn_started_recorded_at
    ; event_queue_ack_seen = Option.is_some store.event_queue_ack_recorded_at
    ; stimulus_recorded_at = store.stimulus_recorded_at
    ; turn_started_recorded_at = store.turn_started_recorded_at
    ; event_queue_ack_recorded_at = store.event_queue_ack_recorded_at
    ; latest_reaction
    ; latest_recorded_at = store.latest_recorded_at
    ; matched_record_count = store.matched_record_count
    }
;;

let event_queue_reaction_evidence_batch_result
      ~base_path
      ~keeper_name
      ~stimulus_ids
  =
  if List.exists (String.equal "") stimulus_ids
  then Error Evidence_invalid_stimulus_id
  else
    let* rows =
      Keeper_reaction_store.evidence_for_stimuli
        ~base_path
        ~keeper_name
        ~stimulus_ids
      |> Result.map_error (fun error -> Evidence_store_error error)
    in
    let rec map_rows reversed = function
      | [] -> Ok (List.rev reversed)
      | (stimulus_id, store) :: rest ->
        let* evidence = evidence_of_store ~keeper_name ~stimulus_id store in
        map_rows ((stimulus_id, evidence) :: reversed) rest
    in
    map_rows [] rows
;;

let event_queue_reaction_evidence_result ~base_path ~keeper_name ~stimulus_id =
  let* evidence =
    event_queue_reaction_evidence_batch_result
      ~base_path
      ~keeper_name
      ~stimulus_ids:[ stimulus_id ]
  in
  match evidence with
  | [ _, evidence ] -> Ok evidence
  | [] | _ :: _ :: _ ->
    Error
      (Evidence_store_error
         (Keeper_reaction_store.Integrity_failure
            "single evidence query returned a non-singleton result"))
;;

let summary_schema = "keeper.reaction_ledger.summary.v3"
let fleet_summary_schema = "keeper.reaction_ledger.fleet_summary.v3"

type keeper_summary =
  { keeper_name : string
  ; pending_id_display_limit : int
  ; row_count : int
  ; stimulus_count : int
  ; reaction_count : int
  ; turn_started_count : int
  ; event_queue_ack_count : int
  ; event_queue_requeue_count : int
  ; event_queue_escalation_count : int
  ; event_queue_external_input_count : int
  ; cursor_ack_count : int
  ; cursor_swept_stimulus_count : int
  ; orphan_reaction_stimulus_count : int
  ; in_progress_stimulus_count : int
  ; acked_stimulus_count : int
  ; escalated_stimulus_count : int
  ; external_input_requested_stimulus_count : int
  ; pending_stimulus_count : int
  ; pending_stimulus_ids : string list
  ; pending_ids_truncated : bool
  ; latest_recorded_at : float option
  ; latest_stimulus_id : string option
  }

type keeper_summary_observation =
  | Known_summary of keeper_summary
  | Summary_read_error of
      { keeper_name : string
      ; pending_id_display_limit : int
      ; error : Keeper_reaction_store.error
      }

let keeper_summary_of_exact ~keeper_name ~limit (exact : Keeper_reaction_store.exact_summary) =
  { keeper_name
  ; pending_id_display_limit = limit
  ; row_count = exact.row_count
  ; stimulus_count = exact.stimulus_count
  ; reaction_count = exact.reaction_count
  ; turn_started_count = exact.turn_started_count
  ; event_queue_ack_count = exact.event_queue_ack_count
  ; event_queue_requeue_count = exact.event_queue_requeue_count
  ; event_queue_escalation_count = exact.event_queue_escalation_count
  ; event_queue_external_input_count = exact.event_queue_external_input_count
  ; cursor_ack_count = exact.cursor_ack_count
  ; cursor_swept_stimulus_count = exact.cursor_swept_stimulus_count
  ; orphan_reaction_stimulus_count = exact.orphan_reaction_stimulus_count
  ; in_progress_stimulus_count = exact.in_progress_stimulus_count
  ; acked_stimulus_count = exact.acked_stimulus_count
  ; escalated_stimulus_count = exact.escalated_stimulus_count
  ; external_input_requested_stimulus_count =
      exact.external_input_requested_stimulus_count
  ; pending_stimulus_count = exact.pending_stimulus_count
  ; pending_stimulus_ids = exact.pending_stimulus_ids
  ; pending_ids_truncated = exact.pending_ids_truncated
  ; latest_recorded_at = exact.latest_recorded_at
  ; latest_stimulus_id = exact.latest_stimulus_id
  }
;;

let error_summary ~keeper_name ~limit error =
  Summary_read_error
    { keeper_name; pending_id_display_limit = limit; error }
;;

let keeper_summary_status summary =
  if summary.row_count = 0
  then "empty"
  else if
    summary.pending_stimulus_count = 0
    && summary.orphan_reaction_stimulus_count = 0
    && summary.escalated_stimulus_count = 0
    && summary.external_input_requested_stimulus_count = 0
  then "ok"
  else "degraded"
;;

let known_keeper_summary_to_json summary =
  let pending_count = summary.pending_stimulus_count in
  let external_input_count = summary.external_input_requested_stimulus_count in
  let orphan_count = summary.orphan_reaction_stimulus_count in
  `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String summary.keeper_name
    ; "status", `String (keeper_summary_status summary)
    ; ( "operator_action_required"
      , `Bool
          (pending_count > 0
           || orphan_count > 0
           || summary.escalated_stimulus_count > 0
           || external_input_count > 0) )
    ; "counts_complete", `Bool true
    ; "pending_id_display_limit", `Int summary.pending_id_display_limit
    ; "row_count", `Int summary.row_count
    ; "stimulus_count", `Int summary.stimulus_count
    ; "reaction_count", `Int summary.reaction_count
    ; "turn_started_count", `Int summary.turn_started_count
    ; "event_queue_ack_count", `Int summary.event_queue_ack_count
    ; "event_queue_requeue_count", `Int summary.event_queue_requeue_count
    ; "event_queue_escalation_count", `Int summary.event_queue_escalation_count
    ; "event_queue_external_input_count", `Int summary.event_queue_external_input_count
    ; "cursor_ack_count", `Int summary.cursor_ack_count
    ; "cursor_swept_stimulus_count", `Int summary.cursor_swept_stimulus_count
    ; "orphan_reaction_stimulus_count", `Int orphan_count
    ; "in_progress_stimulus_count", `Int summary.in_progress_stimulus_count
    ; "acked_stimulus_count", `Int summary.acked_stimulus_count
    ; "escalated_stimulus_count", `Int summary.escalated_stimulus_count
    ; ( "external_input_requested_stimulus_count"
      , `Int external_input_count )
    ; "pending_stimulus_count", `Int pending_count
    ; "pending_ids_truncated", `Bool summary.pending_ids_truncated
    ; ( "pending_stimulus_ids"
      , `List
          (List.map
             (fun value -> `String value)
             summary.pending_stimulus_ids) )
    ; "latest_recorded_at_unix", Json_util.float_opt_to_json summary.latest_recorded_at
    ; "latest_stimulus_id", Json_util.string_opt_to_json summary.latest_stimulus_id
    ; "read_error", `Null
    ]
;;

let error_keeper_summary_to_json ~keeper_name ~pending_id_display_limit error =
  `Assoc
    [ "schema", `String summary_schema
    ; "keeper_name", `String keeper_name
    ; "status", `String "unknown"
    ; "operator_action_required", `Bool true
    ; "counts_complete", `Bool false
    ; "pending_id_display_limit", `Int pending_id_display_limit
    ; "row_count", `Null
    ; "stimulus_count", `Null
    ; "reaction_count", `Null
    ; "turn_started_count", `Null
    ; "event_queue_ack_count", `Null
    ; "event_queue_requeue_count", `Null
    ; "event_queue_escalation_count", `Null
    ; "event_queue_external_input_count", `Null
    ; "cursor_ack_count", `Null
    ; "cursor_swept_stimulus_count", `Null
    ; "orphan_reaction_stimulus_count", `Null
    ; "in_progress_stimulus_count", `Null
    ; "acked_stimulus_count", `Null
    ; "escalated_stimulus_count", `Null
    ; "external_input_requested_stimulus_count", `Null
    ; "pending_stimulus_count", `Null
    ; "pending_ids_truncated", `Null
    ; "pending_stimulus_ids", `List []
    ; "latest_recorded_at_unix", `Null
    ; "latest_stimulus_id", `Null
    ; "read_error", `String (Keeper_reaction_store.error_to_string error)
    ]
;;

let keeper_summary_to_json = function
  | Known_summary summary -> known_keeper_summary_to_json summary
  | Summary_read_error { keeper_name; pending_id_display_limit; error } ->
    error_keeper_summary_to_json ~keeper_name ~pending_id_display_limit error
;;

let summary_record_for_keeper ~base_path ~keeper_name ~pending_id_display_limit =
  match
    Keeper_reaction_store.exact_summary
      ~base_path
      ~keeper_name
      ~pending_id_display_limit
  with
  | Ok exact ->
    Known_summary
      (keeper_summary_of_exact ~keeper_name ~limit:pending_id_display_limit exact)
  | Error error -> error_summary ~keeper_name ~limit:pending_id_display_limit error
;;

let summary_for_keeper ~base_path ~keeper_name ~pending_id_display_limit =
  summary_record_for_keeper ~base_path ~keeper_name ~pending_id_display_limit
  |> keeper_summary_to_json
;;

let unavailable_fleet_summary_json () =
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String "unavailable"
    ; "status_reasons", `List [ `String "server_state_unavailable" ]
    ; "operator_action_required", `Bool true
    ; "keeper_count", `Null
    ; "keeper_names", `List []
    ; "keeper_name_discovery_error_count", `Int 0
    ; "keeper_name_discovery_errors", `List []
    ; "counts_complete", `Bool false
    ; "pending_id_display_limit_per_keeper", `Int 0
    ; "row_count", `Null
    ; "stimulus_count", `Null
    ; "reaction_count", `Null
    ; "turn_started_count", `Null
    ; "event_queue_ack_count", `Null
    ; "event_queue_requeue_count", `Null
    ; "event_queue_escalation_count", `Null
    ; "event_queue_external_input_count", `Null
    ; "cursor_ack_count", `Null
    ; "cursor_swept_stimulus_count", `Null
    ; "orphan_reaction_stimulus_count", `Null
    ; "in_progress_stimulus_count", `Null
    ; "acked_stimulus_count", `Null
    ; "escalated_stimulus_count", `Null
    ; "external_input_requested_stimulus_count", `Null
    ; "pending_stimulus_count", `Null
    ; "reaction_store_discovered_keeper_count", `Null
    ; "reaction_store_discovered_keeper_names", `List []
    ; "reaction_store_discovery_error_count", `Int 0
    ; "reaction_store_discovery_errors", `List []
    ; "pending_by_keeper", `List []
    ; "read_error_count", `Null
    ; "keepers", `List []
    ]
;;

type keeper_name_discovery =
  | Keeper_names_discovered of string list
  | Keeper_name_discovery_failed of string

let fleet_summary_json
      ~base_path
      ~keeper_name_discovery
      ~pending_id_display_limit_per_keeper
  =
  let configured_keeper_names, keeper_name_discovery_errors =
    match keeper_name_discovery with
    | Keeper_names_discovered names -> names, []
    | Keeper_name_discovery_failed detail -> [], [ detail ]
  in
  let reaction_discovery = Keeper_reaction_store.discover_keeper_names ~base_path in
  let keeper_names =
    List.sort_uniq
      String.compare
      (configured_keeper_names @ reaction_discovery.keeper_names)
  in
  let summaries =
    List.map
      (fun keeper_name ->
        summary_record_for_keeper
          ~base_path
          ~keeper_name
          ~pending_id_display_limit:pending_id_display_limit_per_keeper)
      keeper_names
  in
  let known_summaries =
    List.filter_map
      (function
        | Known_summary summary -> Some summary
        | Summary_read_error _ -> None)
      summaries
  in
  let sum field =
    List.fold_left (fun total summary -> total + field summary) 0 known_summaries
  in
  let pending_count = sum (fun summary -> summary.pending_stimulus_count) in
  let external_input_count =
    sum (fun summary -> summary.external_input_requested_stimulus_count)
  in
  let orphan_count = sum (fun summary -> summary.orphan_reaction_stimulus_count) in
  let escalated_count = sum (fun summary -> summary.escalated_stimulus_count) in
  let read_error_count =
    List.fold_left
      (fun total -> function
         | Known_summary _ -> total
         | Summary_read_error _ -> total + 1)
      0
      summaries
  in
  let reaction_discovery_error_count = List.length reaction_discovery.errors in
  let keeper_name_discovery_error_count =
    List.length keeper_name_discovery_errors
  in
  let counts_complete =
    keeper_name_discovery_error_count = 0
    && read_error_count = 0
    && reaction_discovery_error_count = 0
  in
  let keeper_discovery_complete =
    keeper_name_discovery_error_count = 0
    && reaction_discovery_error_count = 0
  in
  let exact_count_json value = if counts_complete then `Int value else `Null in
  let status_reasons =
    []
    |> (fun reasons ->
      if keeper_name_discovery_error_count > 0
      then "keeper_meta_discovery_error" :: reasons
      else reasons)
    |> (fun reasons -> if read_error_count > 0 then "read_error" :: reasons else reasons)
    |> (fun reasons ->
      if reaction_discovery_error_count > 0
      then "reaction_store_discovery_error" :: reasons
      else reasons)
    |> (fun reasons ->
      if pending_count > 0 then "reaction_ledger_pending_stimulus" :: reasons else reasons)
    |> (fun reasons ->
      if external_input_count > 0
      then "reaction_ledger_external_input_requested" :: reasons
      else reasons)
    |> (fun reasons ->
      if orphan_count > 0 then "reaction_ledger_orphan_reaction" :: reasons else reasons)
    |> (fun reasons ->
      if escalated_count > 0 then "reaction_ledger_escalated" :: reasons else reasons)
    |> List.rev
  in
  let row_count = sum (fun summary -> summary.row_count) in
  let status =
    if
      keeper_name_discovery_error_count > 0
      || read_error_count > 0
      || reaction_discovery_error_count > 0
    then "unknown"
    else if
      pending_count > 0
      || external_input_count > 0
      || orphan_count > 0
      || escalated_count > 0
    then "degraded"
    else "ok"
  in
  let pending_by_keeper =
    List.filter_map
      (fun summary ->
        if summary.pending_stimulus_count = 0
        then None
        else
          let ids = summary.pending_stimulus_ids in
          Some
            (`Assoc
               [ "keeper_name", `String summary.keeper_name
               ; "pending_stimulus_count", `Int summary.pending_stimulus_count
               ; "pending_ids_truncated", `Bool summary.pending_ids_truncated
               ; ( "pending_stimulus_ids"
                 , `List (List.map (fun id -> `String id) ids) )
               ]))
      known_summaries
  in
  `Assoc
    [ "schema", `String fleet_summary_schema
    ; "status", `String status
    ; "status_reasons", `List (List.map (fun reason -> `String reason) status_reasons)
    ; "operator_action_required", `Bool (status_reasons <> [])
    ; "empty", (if counts_complete then `Bool (row_count = 0) else `Null)
    ; ( "keeper_count"
      , if keeper_discovery_complete then `Int (List.length keeper_names) else `Null )
    ; "keeper_names", `List (List.map (fun name -> `String name) keeper_names)
    ; "keeper_name_discovery_error_count", `Int keeper_name_discovery_error_count
    ; ( "keeper_name_discovery_errors"
      , `List (List.map (fun detail -> `String detail) keeper_name_discovery_errors) )
    ; "counts_complete", `Bool counts_complete
    ; ( "pending_id_display_limit_per_keeper"
      , `Int pending_id_display_limit_per_keeper )
    ; "row_count", exact_count_json row_count
    ; "stimulus_count", exact_count_json (sum (fun summary -> summary.stimulus_count))
    ; "reaction_count", exact_count_json (sum (fun summary -> summary.reaction_count))
    ; ( "turn_started_count"
      , exact_count_json (sum (fun summary -> summary.turn_started_count)) )
    ; ( "event_queue_ack_count"
      , exact_count_json (sum (fun summary -> summary.event_queue_ack_count)) )
    ; ( "event_queue_requeue_count"
      , exact_count_json (sum (fun summary -> summary.event_queue_requeue_count)) )
    ; ( "event_queue_escalation_count"
      , exact_count_json (sum (fun summary -> summary.event_queue_escalation_count)) )
    ; ( "event_queue_external_input_count"
      , exact_count_json
          (sum (fun summary -> summary.event_queue_external_input_count)) )
    ; "cursor_ack_count", exact_count_json (sum (fun summary -> summary.cursor_ack_count))
    ; ( "cursor_swept_stimulus_count"
      , exact_count_json (sum (fun summary -> summary.cursor_swept_stimulus_count)) )
    ; "orphan_reaction_stimulus_count", exact_count_json orphan_count
    ; ( "in_progress_stimulus_count"
      , exact_count_json (sum (fun summary -> summary.in_progress_stimulus_count)) )
    ; "acked_stimulus_count", exact_count_json (sum (fun summary -> summary.acked_stimulus_count))
    ; "escalated_stimulus_count", exact_count_json escalated_count
    ; "external_input_requested_stimulus_count", exact_count_json external_input_count
    ; "pending_stimulus_count", exact_count_json pending_count
    ; ( "reaction_store_discovered_keeper_count"
      , if reaction_discovery_error_count = 0
        then `Int (List.length reaction_discovery.keeper_names)
        else `Null )
    ; ( "reaction_store_discovered_keeper_names"
      , `List
          (List.map
             (fun name -> `String name)
             reaction_discovery.keeper_names) )
    ; "reaction_store_discovery_error_count", `Int reaction_discovery_error_count
    ; ( "reaction_store_discovery_errors"
      , `List
          (List.map
             (fun error -> `String (Keeper_reaction_store.error_to_string error))
             reaction_discovery.errors) )
    ; "pending_by_keeper", `List pending_by_keeper
    ; ( "read_error_count"
      , if keeper_discovery_complete then `Int read_error_count else `Null )
    ; "keepers", `List (List.map keeper_summary_to_json summaries)
    ]
;;
