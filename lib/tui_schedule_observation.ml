type undetermined =
  | Receipt_not_seen
  | Stimulus_absent
  | Receipt_unsupported of string
  | Status_unsupported of string
  | Reaction_unreadable
  | Queue_unreadable
  | Consumption_conflict
  | Terminal_disagreement
  | Queue_still_holds
  | Reaction_stage_unexpected

type stage =
  | No_occurrence
  | Dispatching
  | Dispatch_failed of string option
  | Queued
  | Queued_at of string
  | Missing
  | Turn_started
  | Turn_ended of Keeper_reaction_ledger.Turn_disposition.t
  | Consumed
  | Completed
  | Receipt_is_the_record
  | Cancelled of string option
  | Settling of string
  | Transferring of { owner : string; target : string }
  | Undetermined of undetermined

type t = { stage : stage; due_at_iso : string option }

type reaction =
  | Unobserved
  | Observed of stage
  | Terminal_conflict

let reaction_stage = function
  | Unobserved -> Undetermined Receipt_not_seen
  | Observed stage -> stage
  | Terminal_conflict -> Undetermined Consumption_conflict

open Result.Syntax

let object_fields = function
  | `Assoc fields ->
      let names = List.map fst fields in
      if List.length names = List.length (List.sort_uniq String.compare names)
      then Ok fields else Error "duplicate schedule observation field"
  | _ -> Error "schedule observation must be an object"

let field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("schedule observation is missing " ^ name)

let text name fields =
  let* value = field name fields in
  match value with
  | `String value when String.trim value <> "" -> Ok value
  | _ -> Error ("schedule observation " ^ name ^ " must be a nonempty string")

let optional_text name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`String value) -> Ok (Some value)
  | Some _ -> Error ("schedule observation " ^ name ^ " must be a string or null")

(* The finished turn's disposition, read with the ledger's own closed decoder:
   [null] is "no turn this stimulus started has finished", an unknown token is
   a decode failure rather than a guess. *)
let turn_finished_disposition fields =
  let* token = optional_text "turn_finished_disposition" fields in
  match token with
  | None -> Ok None
  | Some token ->
    (match Keeper_reaction_ledger.Turn_disposition.of_string token with
     | Some disposition -> Ok (Some disposition)
     | None -> Error ("schedule observation turn_finished_disposition is unknown: " ^ token))

let optional_bool name fields =
  match List.assoc_opt name fields with
  | None | Some `Null -> Ok None
  | Some (`Bool value) -> Ok (Some value)
  | Some _ -> Error ("schedule observation " ^ name ^ " must be a boolean or null")

let number name fields =
  let* value = field name fields in
  match value with
  | `Int value -> Ok (float_of_int value)
  | `Float value when Float.is_finite value -> Ok value
  | _ -> Error ("schedule observation " ^ name ^ " must be a finite number")

let same name expected fields =
  let* actual = text name fields in
  if String.equal actual expected then Ok ()
  else Error ("schedule observation identity mismatch: " ^ name)

(* The two [projection_status] axes are read through the schedule contract's
   closed tables: a token this build does not know fails the decode instead of
   falling to a default reading (#36009). *)
module Contract = Schedule_contract_values

let queue_status fields =
  let* token = text "projection_status" fields in
  Contract.queue_projection_status_of_string token
  |> Result.map_error Contract.decode_error_to_string

let reaction_status fields =
  let* token = text "projection_status" fields in
  Contract.reaction_projection_status_of_string token
  |> Result.map_error Contract.decode_error_to_string

let evidence_fields row name =
  match List.assoc_opt name row with
  | None | Some `Null -> Ok None
  | Some json -> object_fields json |> Result.map Option.some

let missing_stimulus_stage ~check_identity queue reaction =
  let* queue = match queue with
    | Some fields -> Ok fields
    | None -> Error "missing stimulus requires unavailable queue evidence" in
  let* reaction = match reaction with
    | Some fields -> Ok fields
    | None -> Error "missing stimulus requires unavailable reaction evidence" in
  let* () = check_identity queue in
  let* () = check_identity reaction in
  let mismatch = Error "schedule observation identity mismatch: projection_status" in
  let* queue_projection = queue_status queue in
  let* () = match queue_projection with
    | Contract.Queue_unrecognized_receipt -> Ok ()
    | Contract.Queue_matched_pending | Contract.Queue_retained_terminal_wake
    | Contract.Queue_withdrawn_at_cancel | Contract.Queue_not_found
    | Contract.Queue_matched_terminal_completed | Contract.Queue_matched_terminal_cancelled
    | Contract.Queue_terminal_projection_pending | Contract.Queue_transfer_projection_pending
    | Contract.Queue_evidence_invalid | Contract.Queue_read_error -> mismatch in
  let* reaction_projection = reaction_status reaction in
  let* () = match reaction_projection with
    | Contract.Reaction_missing_stimulus_id -> Ok ()
    | Contract.Reaction_conflicting_terminal_evidence | Contract.Reaction_matched_terminal_cancelled
    | Contract.Reaction_matched_consumed_ack | Contract.Reaction_matched_turn_finished
    | Contract.Reaction_matched_turn_started | Contract.Reaction_matched_stimulus
    | Contract.Reaction_not_found | Contract.Reaction_quarantined | Contract.Reaction_read_error
    | Contract.Reaction_invalid_stimulus_id | Contract.Reaction_unrecognized_receipt -> mismatch in
  let* bound_stimulus = optional_text "stimulus_id" reaction in
  let* () = match bound_stimulus with
    | None -> Ok ()
    | Some _ -> Error "missing stimulus conflicts with bound reaction evidence" in
  let rec no_progress = function
    | [] -> Ok (Undetermined Stimulus_absent)
    | field :: rest ->
        let* observed = optional_bool field reaction in
        (match observed with
         | None | Some false -> no_progress rest
         | Some true -> Error "missing stimulus conflicts with reaction progress") in
  let* () =
    let* finished = optional_text "turn_finished_disposition" reaction in
    match finished with
    | None -> Ok ()
    | Some _ -> Error "missing stimulus conflicts with reaction progress" in
  no_progress [ "stimulus_seen"; "turn_started_seen"
              ; "event_queue_ack_seen"; "event_queue_cancelled_seen" ]

let decode row_json =
  let* row = object_fields row_json in
  let* wake = evidence_fields row "last_wake" in
  match wake with
  | None -> Ok { stage = No_occurrence; due_at_iso = None }
  | Some wake ->
      let* due_at_iso = optional_text "due_at_iso" wake in
      (* Rows currently expose the wake due number but not its ISO spelling. *)
      let* queue = evidence_fields row "keeper_queue_evidence" in
      let* due_at_iso = match queue with
        | None -> Ok due_at_iso
        | Some queue -> optional_text "wake_due_at_iso" queue in
      let* instance = text "schedule_instance_id" row in
      let* schedule = text "schedule_id" row in
      let* () = same "schedule_instance_id" instance wake in
      let* () = same "schedule_id" schedule wake in
      let* status = text "status" wake in
      let* stage = match status with
        | "running" -> Ok Dispatching
        | "failed" -> optional_text "error" wake |> Result.map (fun reason -> Dispatch_failed reason)
        | "succeeded" ->
            let* detail_json = field "detail" wake in
            (* Refuses a detail that names one field twice, as every other
               evidence object here is refused; the fields themselves are the
               decoder's to read. *)
            let* _unique_fields = object_fields detail_json in
            (* The server's own decoder, so a receipt kind it writes cannot be
               one this reader calls unsupported. A receipt it cannot read --
               a kind a newer server added -- keeps its row as unknown, as the
               server's own [Unrecognized_receipt] does, and the page around
               it still reads. Identity checks below stay errors: a mismatch
               means another row's evidence was mixed in. *)
            (match Schedule_dispatch_receipt.dispatch_receipt_of_detail detail_json with
             | Error reason -> Ok (Undetermined (Receipt_unsupported reason))
             | Ok receipt ->
            let same_id name expected actual =
              if String.equal expected actual then Ok ()
              else Error ("schedule observation identity mismatch: " ^ name) in
            let occurrence_identity ~schedule_instance_id ~schedule_id =
              let* () = same_id "schedule_instance_id" instance schedule_instance_id in
              same_id "schedule_id" schedule schedule_id in
            let keeper_target keeper =
              let* named_target = optional_text "payload_keeper_name" row in
              let* encoded_target = optional_text "payload_target" row in
              match named_target, encoded_target with
              | None, None -> Error "schedule observation is missing its Keeper target"
              | (Some _ | None), (Some _ | None) ->
                  if (match named_target with None -> true | Some name -> String.equal name keeper)
                     && (match encoded_target with None -> true | Some target -> String.equal target ("keeper:" ^ keeper))
                  then Ok () else Error "schedule observation identity mismatch: Keeper target" in
            (match receipt with
             | Schedule_dispatch_receipt.Lane_act_handed_over { schedule_instance_id; schedule_id; _ } ->
                 let* () = occurrence_identity ~schedule_instance_id ~schedule_id in
                 Ok Receipt_is_the_record
             | Schedule_dispatch_receipt.Keeper_receipt_delivered
                 { keeper_name; schedule_instance_id; schedule_id } ->
                 let* () = occurrence_identity ~schedule_instance_id ~schedule_id in
                 let* () = keeper_target keeper_name in
                 Ok Receipt_is_the_record
             | Schedule_dispatch_receipt.Keeper_wake_enqueued
                 { keeper_name = keeper; schedule_instance_id; schedule_id; post_id = post
                 ; stimulus_id = stimulus; _ } ->
              let* () = occurrence_identity ~schedule_instance_id ~schedule_id in
              let* () = keeper_target keeper in
              let check_identity fields =
                let* () = same "schedule_instance_id" instance fields in
                let* () = same "schedule_id" schedule fields in
                let* () = same "keeper_name" keeper fields in
                same "post_id" post fields in
              let* reaction = evidence_fields row "keeper_reaction_evidence" in
              (match stimulus with
               | None -> missing_stimulus_stage ~check_identity queue reaction
               | Some stimulus ->
                  let* () = same_id "post_id" stimulus post in
                  let* reaction_observation = match reaction with
                    | None -> Ok Unobserved
                    | Some reaction ->
                        let* projection = reaction_status reaction in
                        (match projection with
                         | Contract.Reaction_conflicting_terminal_evidence -> Ok Terminal_conflict
                         | Contract.Reaction_read_error | Contract.Reaction_quarantined
                         | Contract.Reaction_invalid_stimulus_id | Contract.Reaction_missing_stimulus_id
                         | Contract.Reaction_unrecognized_receipt ->
                             Ok (Observed (Undetermined Reaction_unreadable))
                         | Contract.Reaction_matched_stimulus | Contract.Reaction_matched_turn_started
                         | Contract.Reaction_matched_turn_finished | Contract.Reaction_matched_consumed_ack
                         | Contract.Reaction_matched_terminal_cancelled | Contract.Reaction_not_found ->
                             let* () = check_identity reaction in
                             let* () = same "stimulus_id" stimulus reaction in
                             let* seen = optional_bool "stimulus_seen" reaction in
                             let* started = optional_bool "turn_started_seen" reaction in
                             let* ended = turn_finished_disposition reaction in
                             let* acked = optional_bool "event_queue_ack_seen" reaction in
                             let* cancelled = optional_bool "event_queue_cancelled_seen" reaction in
                             if acked = Some true && cancelled = Some true then
                               Ok Terminal_conflict
                             else if cancelled = Some true then Ok (Observed (Cancelled None))
                             else if acked = Some true then Ok (Observed Consumed)
                             else (match ended with
                               | Some disposition -> Ok (Observed (Turn_ended disposition))
                               | None ->
                                 if started = Some true then Ok (Observed Turn_started)
                                 else if seen = Some true then Ok (Observed Queued)
                                 else Ok Unobserved)) in
                  (match queue with
                   | None -> Ok (reaction_stage reaction_observation)
                   | Some queue ->
                       let* projection = queue_status queue in
                       let matched expected =
                         let* () = check_identity queue in
                         let* payload = text "payload_digest" wake in
                         let* () = same "wake_payload_digest" payload queue in
                         let* due = number "due_at" wake in
                         let* actual_due = number "wake_due_at" queue in
                         if not (Float.equal due actual_due) then Error "schedule observation identity mismatch: due_at"
                         else Ok expected in
                       let terminal outcome make =
                         let* reason = optional_text "terminal_reason" queue in
                         let* () = same "terminal_outcome" outcome queue in
                         let result = make reason in
                         let* owner = text "resolved_owner" queue in
                         (* The reaction ledger belongs to the original owner. Its
                            transfer ACK is not the recipient's completion/cancel. *)
                         let disagrees = if not (String.equal owner keeper) then false
                           else match reaction_observation with
                           | Terminal_conflict -> true
                           | Unobserved -> false
                           | Observed (Cancelled _) ->
                               (match result with
                                | Completed -> true
                                | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
                                | Turn_started | Turn_ended _ | Consumed | Receipt_is_the_record | Cancelled _ | Settling _
                                | Transferring _ | Undetermined _ -> false)
                           | Observed Consumed ->
                               (match result with
                                | Cancelled _ -> true
                                | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
                                | Turn_started | Turn_ended _ | Consumed | Completed | Receipt_is_the_record
                                | Settling _ | Transferring _ | Undetermined _ -> false)
                           | Observed (No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
                                      | Turn_started | Turn_ended _ | Completed | Receipt_is_the_record | Settling _
                                      | Transferring _ | Undetermined _) -> false in
                         matched (if disagrees then Undetermined Terminal_disagreement else result) in
                       match reaction_observation with
                       | Terminal_conflict -> Ok (Undetermined Consumption_conflict)
                       | Unobserved | Observed _ ->
                         (match projection with
                          | Contract.Queue_matched_pending | Contract.Queue_retained_terminal_wake ->
                              let* owner = text "resolved_owner" queue in
                              if not (String.equal owner keeper) then matched (Queued_at owner)
                              else (match reaction_observation with
                               | Observed (Consumed | Cancelled _) -> matched (Undetermined Queue_still_holds)
                               | Observed (Undetermined _ | Queued | Turn_started | Turn_ended _ as stage) -> matched stage
                               | Unobserved -> matched Queued
                               | Terminal_conflict -> matched (Undetermined Consumption_conflict)
                               | Observed (No_occurrence | Dispatching | Dispatch_failed _ | Completed | Receipt_is_the_record
                                          | Missing | Queued_at _ | Settling _ | Transferring _) ->
                                   matched (Undetermined Reaction_stage_unexpected))
                          | Contract.Queue_matched_terminal_completed ->
                              terminal "completed" (fun _ -> Completed)
                          | Contract.Queue_matched_terminal_cancelled ->
                              terminal "cancelled" (fun reason -> Cancelled reason)
                          | Contract.Queue_terminal_projection_pending ->
                              let* owner = text "resolved_owner" queue in
                              matched (Settling owner)
                          | Contract.Queue_transfer_projection_pending ->
                              let* owner = text "resolved_owner" queue in
                              let* target = text "transfer_target" queue in
                              matched (Transferring { owner; target })
                          | Contract.Queue_not_found ->
                              (match reaction_observation with
                               | Unobserved | Observed Queued -> matched Missing
                               | Observed ((No_occurrence | Dispatching | Dispatch_failed _ | Completed | Receipt_is_the_record
                                          | Queued_at _ | Missing | Turn_started | Turn_ended _ | Consumed | Cancelled _
                                          | Settling _ | Transferring _ | Undetermined _) as stage) -> matched stage
                               | Terminal_conflict -> matched (Undetermined Consumption_conflict))
                          | Contract.Queue_withdrawn_at_cancel -> matched (Cancelled None)
                          | Contract.Queue_read_error | Contract.Queue_evidence_invalid
                          | Contract.Queue_unrecognized_receipt ->
                              Ok (Undetermined Queue_unreadable))))))
        | other -> Ok (Undetermined (Status_unsupported other)) in
      Ok { stage; due_at_iso }

let needs_attention = function
  | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing | Turn_started | Turn_ended _
  | Consumed | Settling _ | Transferring _ | Undetermined _ -> true
  | No_occurrence | Completed | Receipt_is_the_record | Cancelled _ -> false
