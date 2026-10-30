type stage =
  | No_occurrence
  | Dispatching
  | Dispatch_failed of string option
  | Queued
  | Queued_at of string
  | Missing
  | Turn_started
  | Turn_ended
  | Consumed
  | Completed
  | Failed of string option
  | Cancelled of string option
  | Settling
  | Transferring
  | Unknown of string

type t = { stage : stage; due_at_iso : string option }

type reaction =
  | Unobserved
  | Observed of stage
  | Terminal_conflict

let reaction_stage = function
  | Unobserved -> Unknown "예약 수신 미확인"
  | Observed stage -> stage
  | Terminal_conflict -> Unknown "예약 소비 증거 충돌"

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
  let* () = same "projection_status" "unrecognized_receipt" queue in
  let* () = same "projection_status" "missing_stimulus_id" reaction in
  let* bound_stimulus = optional_text "stimulus_id" reaction in
  let* () = match bound_stimulus with
    | None -> Ok ()
    | Some _ -> Error "missing stimulus conflicts with bound reaction evidence" in
  let rec no_progress = function
    | [] -> Ok (Unknown "예약 발생 식별자 미확인")
    | field :: rest ->
        let* observed = optional_bool field reaction in
        (match observed with
         | None | Some false -> no_progress rest
         | Some true -> Error "missing stimulus conflicts with reaction progress") in
  no_progress [ "stimulus_seen"; "turn_started_seen"; "turn_finished_seen"
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
            let* detail = object_fields detail_json in
            let* kind = text "kind" detail in
            if not (String.equal kind "masc.keeper_wake.enqueued")
            then Ok (Unknown "예약 실행 증거 미지원")
            else
              let* () = same "schedule_instance_id" instance detail in
              let* () = same "schedule_id" schedule detail in
              let* keeper = text "keeper_name" detail in
              let* named_target = optional_text "payload_keeper_name" row in
              let* encoded_target = optional_text "payload_target" row in
              let* () = match named_target, encoded_target with
                | None, None -> Error "schedule observation is missing its Keeper target"
                | (Some _ | None), (Some _ | None) ->
                    if (match named_target with None -> true | Some name -> String.equal name keeper)
                       && (match encoded_target with None -> true | Some target -> String.equal target ("keeper:" ^ keeper))
                    then Ok () else Error "schedule observation identity mismatch: Keeper target" in
              let* post = text "post_id" detail in
              let check_identity fields =
                let* () = same "schedule_instance_id" instance fields in
                let* () = same "schedule_id" schedule fields in
                let* () = same "keeper_name" keeper fields in
                same "post_id" post fields in
              let* reaction = evidence_fields row "keeper_reaction_evidence" in
              let* stimulus = optional_text "stimulus_id" detail in
              (match stimulus with
               | None -> missing_stimulus_stage ~check_identity queue reaction
               | Some stimulus ->
                  let* () = same "post_id" stimulus detail in
                  let* reaction_observation = match reaction with
                    | None -> Ok Unobserved
                    | Some reaction ->
                        let* projection = text "projection_status" reaction in
                        (match projection with
                         | "conflicting_terminal_evidence" -> Ok Terminal_conflict
                         | "read_error" | "quarantined"
                         | "invalid_stimulus_id" | "missing_stimulus_id" | "unrecognized_receipt" ->
                             Ok (Observed (Unknown "예약 반응 조회 불가"))
                         | "matched_stimulus" | "matched_turn_started" | "matched_turn_finished"
                         | "matched_consumed_ack" | "matched_terminal_cancelled" | "not_found" ->
                             let* () = check_identity reaction in
                             let* () = same "stimulus_id" stimulus reaction in
                             let* seen = optional_bool "stimulus_seen" reaction in
                             let* started = optional_bool "turn_started_seen" reaction in
                             let* ended = optional_bool "turn_finished_seen" reaction in
                             let* acked = optional_bool "event_queue_ack_seen" reaction in
                             let* cancelled = optional_bool "event_queue_cancelled_seen" reaction in
                             if acked = Some true && cancelled = Some true then
                               Ok Terminal_conflict
                             else if cancelled = Some true then Ok (Observed (Cancelled None))
                             else if acked = Some true then Ok (Observed Consumed)
                             else if ended = Some true then Ok (Observed Turn_ended)
                             else if started = Some true then Ok (Observed Turn_started)
                             else if seen = Some true then Ok (Observed Queued)
                             else Ok Unobserved
                         | _ -> Ok (Observed (Unknown "예약 반응 상태 미지원"))) in
                  (match queue with
                   | None -> Ok (reaction_stage reaction_observation)
                   | Some queue ->
                       let* projection = text "projection_status" queue in
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
                                | Completed | Failed _ -> true
                                | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
                                | Turn_started | Turn_ended | Consumed | Cancelled _ | Settling
                                | Transferring | Unknown _ -> false)
                           | Observed Consumed ->
                               (match result with
                                | Cancelled _ -> true
                                | No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
                                | Turn_started | Turn_ended | Consumed | Completed | Failed _
                                | Settling | Transferring | Unknown _ -> false)
                           | Observed (No_occurrence | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing
                                      | Turn_started | Turn_ended | Completed | Failed _ | Settling
                                      | Transferring | Unknown _) -> false in
                         matched (if disagrees then Unknown "예약 종결 증거 충돌" else result) in
                       match reaction_observation with
                       | Terminal_conflict -> Ok (Unknown "예약 소비 증거 충돌")
                       | Unobserved | Observed _ ->
                         (match projection with
                          | "matched_pending" | "retained_terminal_wake" ->
                              let* owner = text "resolved_owner" queue in
                              if not (String.equal owner keeper) then matched (Queued_at owner)
                              else (match reaction_observation with
                               | Observed (Consumed | Cancelled _) -> matched (Unknown "예약 큐와 소비 증거 재확인 필요")
                               | Observed (Unknown _ | Queued | Turn_started | Turn_ended as stage) -> matched stage
                               | Unobserved -> matched Queued
                               | Terminal_conflict -> matched (Unknown "예약 소비 증거 충돌")
                               | Observed (No_occurrence | Dispatching | Dispatch_failed _ | Completed | Failed _
                                          | Missing | Queued_at _ | Settling | Transferring) -> matched (Unknown "예약 반응 재확인 필요"))
                          | "matched_terminal_completed" -> terminal "completed" (fun _ -> Completed)
                          | "matched_terminal_failed" -> terminal "failed" (fun reason -> Failed reason)
                          | "matched_terminal_cancelled" -> terminal "cancelled" (fun reason -> Cancelled reason)
                          | "terminal_projection_pending" -> matched Settling
                          | "transfer_projection_pending" -> matched Transferring
                          | "not_found" ->
                              (match reaction_observation with
                               | Unobserved | Observed Queued -> matched Missing
                               | Observed ((No_occurrence | Dispatching | Dispatch_failed _ | Completed | Failed _
                                          | Queued_at _ | Missing | Turn_started | Turn_ended | Consumed | Cancelled _
                                          | Settling | Transferring | Unknown _) as stage) -> matched stage
                               | Terminal_conflict -> matched (Unknown "예약 소비 증거 충돌"))
                          | "withdrawn_at_cancel" -> matched (Cancelled None)
                          | "read_error" | "evidence_invalid" | "unrecognized_receipt" ->
                              Ok (Unknown "예약 큐 조회 불가")
                          | _ -> Ok (Unknown "예약 큐 상태 미지원"))))
        | _ -> Ok (Unknown "예약 전달 상태 미지원") in
      Ok { stage; due_at_iso }

let needs_attention = function
  | Dispatching | Dispatch_failed _ | Queued | Queued_at _ | Missing | Turn_started | Turn_ended
  | Consumed | Failed _ | Settling | Transferring | Unknown _ -> true
  | No_occurrence | Completed | Cancelled _ -> false
