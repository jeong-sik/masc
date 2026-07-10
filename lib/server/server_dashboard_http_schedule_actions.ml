type schedule_decision =
  | Approve
  | Reject
  | Cancel
  | Update

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

let required_number key json =
  match Server_dashboard_http_json_utils.json_number key json with
  | None -> Error (key ^ " is required")
  | Some value -> Ok value
;;

let number_opt key json = Server_dashboard_http_json_utils.json_number key json

let required_payload key json =
  match Server_dashboard_http_json_utils.json_assoc key json with
  | None -> Error (key ^ " is required")
  | Some payload -> Ok payload
;;

let decision_of_json json =
  let* raw = required_string "decision" json in
  match String.lowercase_ascii raw with
  | "approve" -> Ok Approve
  | "reject" -> Ok Reject
  | "cancel" -> Ok Cancel
  | "update" -> Ok Update
  | _ -> Error "decision must be 'approve', 'reject', 'cancel', or 'update'"
;;

let decision_to_string = function
  | Approve -> "approve"
  | Reject -> "reject"
  | Cancel -> "cancel"
  | Update -> "update"
;;

(* Absent means the narrow historical semantics (this occurrence only);
   an unknown value is a request error, never a silent default. *)
let grant_scope_of_json json =
  match string_opt "scope" json with
  | None -> Ok Schedule_domain.Grant_occurrence
  | Some raw ->
    (match Schedule_domain.grant_scope_of_string (String.lowercase_ascii raw) with
     | Ok scope -> Ok scope
     | Error _ -> Error "scope must be 'occurrence' or 'standing'")
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
      let map_service_error result =
        Result.map_error Schedule_service.service_error_to_string result
      in
      match decision with
      | Approve ->
        let* scope = grant_scope_of_json args in
        Schedule_service.approve config ~schedule_id ~approved_by ~scope ()
        |> map_service_error
      | Reject ->
        let reason =
          match string_opt "reason" args with
          | Some reason -> reason
          | None ->
            (* DET-OK: the dashboard fallback is derived only from the authenticated
               operator bound by token auth, not from caller-supplied body identity. *)
            default_rejection_reason ~operator_name
        in
        Schedule_service.reject config ~schedule_id ~approved_by ~reason ()
        |> map_service_error
      | Cancel ->
        Schedule_service.cancel config ~schedule_id |> map_service_error
      | Update ->
        let* due_at = required_number "due_at" args in
        let expires_at = number_opt "expires_at" args in
        let* payload_json = required_payload "payload" args in
        let* payload = Schedule_domain.payload_of_yojson payload_json in
        Schedule_service.update config ~schedule_id ~due_at ~expires_at ~payload
        |> map_service_error
    in
    service_result
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

let prune_http_json ~config ~operator_name
  : (Yojson.Safe.t, string) result
  =
  let operator_name = String.trim operator_name in
  let result =
    let* () =
      if String.equal operator_name ""
      then Error "authenticated operator is required"
      else Ok ()
    in
    match Schedule_service.prune config with
    | Error err -> Error (Schedule_service.service_error_to_string err)
    | Ok (_, count) ->
      Ok (`Assoc
            [ "ok", `Bool true
            ; "pruned_count", `Int count
            ])
  in
  result
;;
