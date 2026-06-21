type schedule_decision =
  | Approve
  | Reject

let ( let* ) = Result.bind

let trim_nonempty value =
  let trimmed = String.trim value in
  if String.equal trimmed "" then None else Some trimmed
;;

let string_opt key json =
  Safe_ops.json_string_opt key json |> Option.bind trim_nonempty
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
  | _ -> Error "decision must be 'approve' or 'reject'"
;;

let decision_to_string = function
  | Approve -> "approve"
  | Reject -> "reject"
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
    let approved_by = actor_of_operator_name operator_name in
    let service_result =
      match decision with
      | Approve ->
        Schedule_service.approve config ~schedule_id ~approved_by ()
      | Reject ->
        let reason =
          string_opt "reason" args
          |> Option.value ~default:(default_rejection_reason ~operator_name)
        in
        Schedule_service.reject config ~schedule_id ~approved_by ~reason ()
    in
    service_result
    |> Result.map_error Schedule_service.service_error_to_string
    |> Result.map (fun schedule ->
      `Assoc
        [ "ok", `Bool true
        ; "schedule_id", `String schedule_id
        ; "decision", `String (decision_to_string decision)
        ; "approved_by", Schedule_domain.actor_to_yojson approved_by
        ; "schedule", Schedule_domain.schedule_request_to_yojson schedule
        ])
  in
  result
;;
