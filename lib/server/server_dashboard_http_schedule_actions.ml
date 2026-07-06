type schedule_decision =
  | Approve
  | Reject
  | Cancel

let ( let* ) = Result.bind

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let string_opt key json =
  match Safe_ops.json_string_opt key json with
  | None -> None
  | Some value -> trim_nonempty value
;;

let required_string key json =
  match string_opt key json with
  | Some value -> Ok value
  | None -> Error (key ^ " is required")
;;

let decision_of_json json =
  let* raw = required_string "decision" json in
  match String.lowercase_ascii raw with
  | "approve" -> Ok Approve
  | "reject" -> Ok Reject
  | "cancel" -> Ok Cancel
  | _ -> Error "decision must be 'approve', 'reject', or 'cancel'"
;;

let decision_to_string = function
  | Approve -> "approve"
  | Reject -> "reject"
  | Cancel -> "cancel"
;;

let default_rejection_reason ~operator_name =
  "rejected from dashboard by " ^ operator_name
;;

let actor_of_operator_name operator_name : Schedule_domain.actor =
  { id = operator_name
  ; kind = Schedule_domain.Human_operator
  ; display_name = Some operator_name
  }
;;

let resolve_http_json ~config ~operator_name ~(args : Yojson.Safe.t)
  : (Yojson.Safe.t, string) result
  =
  let operator_name = String.trim operator_name in
  let result =
    let* () =
      if String.equal operator_name ""
      then Error "authenticated operator is required"
      else Ok ()
    in
    let* schedule_id = required_string "schedule_id" args in
    let* decision = decision_of_json args in
    let operator_actor = actor_of_operator_name operator_name in
    let* decision_reason =
      match decision with
      | Approve -> Ok None
      | Reject ->
        let reason =
          match string_opt "reason" args with
          | Some reason -> reason
          | None ->
            (* DET-OK: the dashboard fallback is derived only from the authenticated
               operator bound by token auth, not from caller-supplied body identity. *)
            default_rejection_reason ~operator_name
        in
        Ok (Some reason)
      | Cancel -> required_string "reason" args |> Result.map Option.some
    in
    let service_result =
      match decision with
      | Approve ->
        Schedule_service.approve config ~schedule_id ~approved_by:operator_actor ()
      | Reject ->
        (match decision_reason with
         | Some reason ->
           Schedule_service.reject config ~schedule_id ~approved_by:operator_actor ~reason ()
         | None -> Error (Schedule_service.Invalid_request "reject reason missing"))
      | Cancel ->
        (match decision_reason with
         | Some reason ->
           Schedule_service.cancel config ~schedule_id
             ~cancelled_by:operator_actor
             ~reason
         | None -> Error (Schedule_service.Invalid_request "cancel reason missing"))
    in
    service_result
    |> Result.map_error Schedule_service.service_error_to_string
    |> Result.map (fun schedule ->
      let actor_field =
        match decision with
        | Approve | Reject -> "approved_by"
        | Cancel -> "cancelled_by"
      in
      `Assoc
        [ "ok", `Bool true
        ; "schedule_id", `String schedule_id
        ; "decision", `String (decision_to_string decision)
        ; actor_field, Schedule_domain.actor_to_yojson operator_actor
        ; ( "reason"
          , match decision_reason with
            | Some reason -> `String reason
            | None -> `Null )
        ; "schedule", Schedule_domain.schedule_request_to_yojson schedule
        ])
  in
  result
;;
