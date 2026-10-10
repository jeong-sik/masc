open Masc_tui_types

let ( let* ) = Result.bind

(* The kind beside the name is a word, not the wire token: the row read
   "Operator Proof (human_operator)" and "keeper-701 (automated_actor)". The
   token is parsed through the schedule contract, so a kind this build does
   not know fails the read the way every other unknown wire value here does
   rather than reaching the screen as spelled. *)
let schedule_actor_kind_word = function
  | Schedule_contract_values.Human_operator -> "human"
  | Schedule_contract_values.Automated_actor -> "automated"
  | Schedule_contract_values.System -> "system"

let decode_schedule_actor json field =
  match Yojson.Safe.Util.member field json with
  | `Assoc _ as actor ->
      let* id = Masc.Tui_decode_fields.required_string_field actor "id" in
      let* kind = Masc.Tui_decode_fields.required_string_field actor "kind" in
      let* kind =
        Schedule_contract_values.actor_kind_of_string kind
        |> Result.map_error Schedule_contract_values.decode_error_to_string
      in
      let* display_name = Masc.Tui_decode_fields.optional_string_field actor "display_name" in
      let name = Option.value ~default:id display_name in
      Ok (Printf.sprintf "%s (%s)" name (schedule_actor_kind_word kind))
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object: %s" field
           (Yojson.Safe.to_string value))

let optional_nested_string_field json object_field field =
  match Yojson.Safe.Util.member object_field json with
  | `Null -> Ok None
  | `Assoc _ as nested -> Masc.Tui_decode_fields.optional_string_field nested field
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object or null: %s"
           object_field (Yojson.Safe.to_string value))

(* Whether a step of the wake actually happened, as the reaction ledger
   recorded it. Absent reads as [None] and not as [false]: "the ledger did not
   say" and "the ledger said no" are different answers, and only one of them
   means something went wrong. *)
let optional_nested_bool_field json object_field field =
  match Yojson.Safe.Util.member object_field json with
  | `Null -> Ok None
  | `Assoc _ as nested -> (
      match Yojson.Safe.Util.member field nested with
      | `Null -> Ok None
      | `Bool value -> Ok (Some value)
      | value ->
          Error
            (Printf.sprintf "schedule %s.%s must be a boolean or null: %s"
               object_field field (Yojson.Safe.to_string value)))
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object or null: %s"
           object_field (Yojson.Safe.to_string value))

let optional_nested_int_field json object_field field =
  match Yojson.Safe.Util.member object_field json with
  | `Null -> Ok None
  | `Assoc _ as nested ->
      (match Yojson.Safe.Util.member field nested with
       | `Null -> Ok None
       | `Int value -> Ok (Some value)
       | value ->
           Error
             (Printf.sprintf "schedule %s.%s must be an integer or null: %s"
                object_field field (Yojson.Safe.to_string value)))
  | value ->
      Error
        (Printf.sprintf "schedule %s must be an object or null: %s"
           object_field (Yojson.Safe.to_string value))

let required_schedule_json_field json field =
  match Yojson.Safe.Util.member field json with
  | `Null -> Error (Printf.sprintf "schedule %s is required" field)
  | value -> Ok value

let decode_schedule_row json =
  let* sch_schedule_instance_id =
    Masc.Tui_decode_fields.required_string_field json "schedule_instance_id"
  in
  let* sch_schedule_id = Masc.Tui_decode_fields.required_string_field json "schedule_id" in
  let* sch_status = Masc.Tui_decode_fields.required_string_field json "status" in
  let* sch_source = Masc.Tui_decode_fields.required_string_field json "source" in
  let* sch_requested_by = decode_schedule_actor json "requested_by" in
  let* sch_scheduled_by = decode_schedule_actor json "scheduled_by" in
  let* sch_requested_at_iso = Masc.Tui_decode_fields.required_string_field json "requested_at_iso" in
  let* sch_due_at_iso = Masc.Tui_decode_fields.optional_string_field json "due_at_iso" in
  let* sch_next_due_at_iso = Masc.Tui_decode_fields.optional_string_field json "next_due_at_iso" in
  let* sch_expires_at_iso = Masc.Tui_decode_fields.optional_string_field json "expires_at_iso" in
  let* sch_recurrence_summary =
    Masc.Tui_decode_fields.required_string_field json "recurrence_summary"
  in
  let* sch_recurrence = required_schedule_json_field json "recurrence" in
  let* sch_payload_digest = Masc.Tui_decode_fields.required_string_field json "payload_digest" in
  let* sch_payload = required_schedule_json_field json "payload" in
  let* sch_payload_kind = Masc.Tui_decode_fields.optional_string_field json "payload_kind" in
  let* sch_payload_support = Masc.Tui_decode_fields.required_string_field json "payload_support" in
  let* sch_payload_dispatch_tool =
    Masc.Tui_decode_fields.optional_string_field json "payload_dispatch_tool"
  in
  let* sch_payload_target = Masc.Tui_decode_fields.optional_string_field json "payload_target" in
  let* sch_payload_keeper_name =
    Masc.Tui_decode_fields.optional_string_field json "payload_keeper_name"
  in
  let* sch_payload_summary = Masc.Tui_decode_fields.optional_string_field json "payload_summary" in
  let* sch_last_wake_status =
    (* The server writes this from [wake_status_to_string], so a word the
       contract does not list is a wire error, not a fourth status. *)
    let* word = optional_nested_string_field json "last_wake" "status" in
    match word with
    | None -> Ok None
    | Some word ->
        Schedule_contract_values.wake_status_of_string word
        |> Result.map_error Schedule_contract_values.decode_error_to_string
        |> Result.map Option.some
  in
  let* sch_last_wake_started_at_iso =
    optional_nested_string_field json "last_wake" "started_at_iso"
  in
  let* sch_last_wake_error =
    optional_nested_string_field json "last_wake" "error"
  in
  let* sch_queue_projection_status =
    optional_nested_string_field json "keeper_queue_evidence" "projection_status"
  in
  let* sch_queue_pending_count =
    optional_nested_int_field json "keeper_queue_evidence" "pending_count"
  in
  let* sch_reaction_projection_status =
    optional_nested_string_field json "keeper_reaction_evidence"
      "projection_status"
  in
  let* sch_reaction_latest_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "latest_recorded_at_iso"
  in
  (* What became of the wake, step by step, as the reaction ledger recorded
     it. [projection_status] above is the verdict on all four at once; these
     are the four, and they are what tells a stalled wake from a delivered
     one that nobody acted on. *)
  let* sch_reaction_kind =
    optional_nested_string_field json "keeper_reaction_evidence" "reaction_kind"
  in
  let* sch_reaction_keeper_name =
    optional_nested_string_field json "keeper_reaction_evidence" "keeper_name"
  in
  let* sch_reaction_stimulus_id =
    optional_nested_string_field json "keeper_reaction_evidence" "stimulus_id"
  in
  let* sch_reaction_post_id =
    optional_nested_string_field json "keeper_reaction_evidence" "post_id"
  in
  let* sch_reaction_reason =
    optional_nested_string_field json "keeper_reaction_evidence" "reason"
  in
  let* sch_wake_seen =
    optional_nested_bool_field json "keeper_reaction_evidence" "stimulus_seen"
  in
  let* sch_turn_started =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "turn_started_seen"
  in
  let* sch_queue_ack_seen =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "event_queue_ack_seen"
  in
  let* sch_wake_cancelled =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "event_queue_cancelled_seen"
  in
  let* sch_stimulus_recorded_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "stimulus_recorded_at_iso"
  in
  let* sch_turn_finished =
    optional_nested_bool_field json "keeper_reaction_evidence"
      "turn_finished_seen"
  in
  let* sch_turn_finished_recorded_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "turn_finished_recorded_at_iso"
  in
  let* sch_turn_started_recorded_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "turn_started_recorded_at_iso"
  in
  let* sch_queue_ack_recorded_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "event_queue_ack_recorded_at_iso"
  in
  let* sch_wake_cancelled_recorded_at_iso =
    optional_nested_string_field json "keeper_reaction_evidence"
      "event_queue_cancelled_recorded_at_iso"
  in
  let* sch_reaction_quarantined =
    optional_nested_int_field json "keeper_reaction_evidence"
      "quarantined_record_count"
  in
  let* sch_runner_hold = Tui_decode.decode_schedule_runner_hold json in
  Ok
    { sch_schedule_instance_id
    ; sch_schedule_id
    ; sch_status
    ; sch_source
    ; sch_requested_by
    ; sch_scheduled_by
    ; sch_requested_at_iso
    ; sch_due_at_iso
    ; sch_next_due_at_iso
    ; sch_expires_at_iso
    ; sch_recurrence_summary
    ; sch_recurrence
    ; sch_payload_digest
    ; sch_payload
    ; sch_payload_kind
    ; sch_payload_support
    ; sch_payload_dispatch_tool
    ; sch_payload_target
    ; sch_payload_keeper_name
    ; sch_payload_summary
    ; sch_last_wake_status
    ; sch_last_wake_started_at_iso
    ; sch_last_wake_error
    ; sch_queue_projection_status
    ; sch_queue_pending_count
    ; sch_reaction_projection_status
    ; sch_reaction_kind
    ; sch_reaction_keeper_name
    ; sch_reaction_stimulus_id
    ; sch_reaction_post_id
    ; sch_reaction_reason
    ; sch_wake_seen
    ; sch_turn_started
    ; sch_turn_finished
    ; sch_queue_ack_seen
    ; sch_wake_cancelled
    ; sch_stimulus_recorded_at_iso
    ; sch_turn_started_recorded_at_iso
    ; sch_turn_finished_recorded_at_iso
    ; sch_queue_ack_recorded_at_iso
    ; sch_wake_cancelled_recorded_at_iso
    ; sch_reaction_quarantined
    ; sch_reaction_latest_at_iso
    ; sch_runner_hold
    }

let decode_schedule_rows json_list =
  Masc.Tui_decode_fields.decode_list "requests" decode_schedule_row json_list

(* The snapshot keeps the server's ok/unknown split: on a store read failure
   the route reports [status = "unknown"] with a null [request_count] and an
   empty row list, and the pane must not draw that as "no schedules". *)
let snapshot_of_json json =
  let* scs_status = Masc.Tui_decode_fields.required_string_field json "status" in
  let* scs_read_error =
    Masc.Tui_decode_fields.optional_string_field json "schedule_store_read_error"
  in
  let* scs_request_count =
    match Yojson.Safe.Util.member "request_count" json with
    | `Int value -> Ok (Some value)
    | `Null -> Ok None
    | other ->
        Error
          (Printf.sprintf "schedules request_count must be an integer: %s"
             (Yojson.Safe.to_string other))
  in
  let* scs_truncated =
    match Yojson.Safe.Util.member "truncated" json with
    | `Bool value -> Ok value
    | other ->
        Error
          (Printf.sprintf "schedules truncated must be a boolean: %s"
             (Yojson.Safe.to_string other))
  in
  (* The summary spells it [next_due_at] (Server_dashboard_schedule_projection,
     the [fsm] object), unlike a row's [next_due_at_iso]. The server always
     writes the member, null when nothing is due, so an absent member is a
     wire change and not "nothing due". *)
  let* scs_next_due_iso =
    match Yojson.Safe.Util.member "fsm" json with
    | `Assoc fields ->
        (match List.assoc_opt "next_due_at" fields with
         | Some (`String value) -> Ok (Some value)
         | Some `Null -> Ok None
         | None -> Error "schedules fsm is missing next_due_at"
         | Some other ->
             Error
               (Printf.sprintf
                  "schedules fsm next_due_at must be a string or null: %s"
                  (Yojson.Safe.to_string other)))
    | other ->
        Error
          (Printf.sprintf "schedules fsm must be an object: %s"
             (Yojson.Safe.to_string other))
  in
  (* Walked from [Schedule_domain.all_schedule_statuses], the same list the
     server builds this object from, so a status added to the shared contract
     is asked for here without a second spelling of the vocabulary. The server
     sends [null] exactly when the store read failed, which is the reading
     [request_count] already carries. *)
  let* scs_counts =
    match Yojson.Safe.Util.member "counts" json with
    | `Null -> Ok None
    | `Assoc fields ->
        let rec read acc = function
          | [] -> Ok (Some (List.rev acc))
          | status :: rest -> (
              let name = Schedule_domain.schedule_status_to_string status in
              match List.assoc_opt name fields with
              | Some (`Int count) -> read ((status, count) :: acc) rest
              | Some other ->
                  Error
                    (Printf.sprintf "schedules counts %s must be an integer: %s"
                       name
                       (Yojson.Safe.to_string other))
              | None ->
                  Error (Printf.sprintf "schedules counts is missing %s" name))
        in
        read [] Schedule_domain.all_schedule_statuses
    | other ->
        Error
          (Printf.sprintf "schedules counts must be an object or null: %s"
             (Yojson.Safe.to_string other))
  in
  let* rows = Masc.Tui_decode_fields.required_list_field json "requests" in
  let* scs_rows = decode_schedule_rows rows in
  let* scs_runner_status = Tui_decode.decode_schedule_runner_status json in
  Ok
    { scs_status
    ; scs_read_error
    ; scs_request_count
    ; scs_truncated
    ; scs_next_due_iso
    ; scs_counts
    ; scs_rows
    ; scs_runner_status
    }

let decode_schedule_wake json =
  let* swk_status =
    let* word = Masc.Tui_decode_fields.required_string_field json "status" in
    Schedule_contract_values.wake_status_of_string word
    |> Result.map_error Schedule_contract_values.decode_error_to_string
  in
  let* swk_started_at_iso = Masc.Tui_decode_fields.optional_string_field json "started_at_iso" in
  let* swk_finished_at_iso = Masc.Tui_decode_fields.optional_string_field json "finished_at_iso" in
  let* swk_error = Masc.Tui_decode_fields.optional_string_field json "error" in
  Ok { swk_status; swk_started_at_iso; swk_finished_at_iso; swk_error }

(* The lookup answers four ways and only one of them carries a schedule. The
   other three are reported as their own error text rather than as an empty
   history, because "this schedule has never woken" and "the store could not
   be read" are the two readings this pane exists to keep apart. *)
let wake_history_of_json json =
  let* status = Masc.Tui_decode_fields.required_string_field json "status" in
  let* swh_schedule_id = Masc.Tui_decode_fields.required_string_field json "schedule_id" in
  match status with
  | "found" ->
      let* wake_jsons = Masc.Tui_decode_fields.required_list_field json "wakes" in
      let* swh_wakes = Masc.Tui_decode_fields.decode_list "wakes" decode_schedule_wake wake_jsons in
      (* [wake_count] rides the wire for a JSON reader; the pane counts the
         list it is about to draw, so the two cannot drift apart on screen. *)
      let* swh_retention_per_schedule =
        Masc.Tui_decode_fields.required_int_field json "wake_retention_per_schedule"
      in
      Ok { swh_schedule_id; swh_wakes; swh_retention_per_schedule }
  | "not_found" ->
      Error (Printf.sprintf "schedule %s is no longer in the store" swh_schedule_id)
  | "invalid_id" -> Error "the schedule lookup was asked for an empty id"
  | "unavailable" ->
      let reason =
        match Masc.Tui_decode_fields.optional_string_field json "reason" with
        | Ok (Some reason) -> reason
        | Ok None | Error _ -> "no reason given"
      in
      Error ("schedule lookup unavailable: " ^ reason)
  | other -> Error ("unknown schedule lookup status: " ^ other)
