type actor_kind =
  | Human_operator
  | Automated_actor
  | System

type actor =
  { id : string
  ; kind : actor_kind
  ; display_name : string option
  }

type risk_class =
  | Reminder_only
  | Read_only
  | Workspace_write
  | External_write
  | Destructive
  | Cost_bearing

type schedule_status =
  | Pending_approval
  | Scheduled
  | Due
  | Running
  | Succeeded
  | Failed
  | Rejected
  | Cancelled
  | Expired

type schedule_source =
  | Operator_request
  | Automated_request
  | System_request

type schedule_request =
  { schedule_id : string
  ; requested_by : actor
  ; scheduled_by : actor
  ; requested_at : float
  ; due_at : float
  ; expires_at : float option
  ; payload : Yojson.Safe.t
  ; risk_class : risk_class
  ; approval_required : bool
  ; status : schedule_status
  ; source : schedule_source
  }

type execution_decision =
  | Approve
  | Reject of string

type execution_evidence =
  { schedule_id : string
  ; payload_digest : string
  ; due_at : float
  ; risk_class : risk_class
  }

type execution_grant =
  { grant_id : string
  ; schedule_id : string
  ; approved_by : actor
  ; approved_at : float
  ; decision : execution_decision
  ; evidence : execution_evidence
  }

type grant_error =
  | Grant_schedule_id_mismatch
  | Approver_not_human
  | Approver_is_requester
  | Approver_is_scheduler
  | Schedule_terminal
  | Schedule_not_pending_approval
  | Evidence_schedule_id_mismatch
  | Evidence_payload_digest_mismatch
  | Evidence_due_at_mismatch
  | Evidence_risk_class_mismatch

let ( let* ) = Result.bind

let nonempty field value =
  if String.trim value = "" then Error (field ^ " must be non-empty") else Ok value
;;

let actor_kind_to_string = function
  | Human_operator -> "human_operator"
  | Automated_actor -> "automated_actor"
  | System -> "system"
;;

let actor_kind_of_string = function
  | "human_operator" -> Ok Human_operator
  | "automated_actor" -> Ok Automated_actor
  | "system" -> Ok System
  | other -> Error ("unknown actor_kind: " ^ other)
;;

let risk_class_to_string = function
  | Reminder_only -> "reminder_only"
  | Read_only -> "read_only"
  | Workspace_write -> "workspace_write"
  | External_write -> "external_write"
  | Destructive -> "destructive"
  | Cost_bearing -> "cost_bearing"
;;

let risk_class_of_string = function
  | "reminder_only" -> Ok Reminder_only
  | "read_only" -> Ok Read_only
  | "workspace_write" -> Ok Workspace_write
  | "external_write" -> Ok External_write
  | "destructive" -> Ok Destructive
  | "cost_bearing" -> Ok Cost_bearing
  | other -> Error ("unknown risk_class: " ^ other)
;;

let schedule_status_to_string = function
  | Pending_approval -> "pending_approval"
  | Scheduled -> "scheduled"
  | Due -> "due"
  | Running -> "running"
  | Succeeded -> "succeeded"
  | Failed -> "failed"
  | Rejected -> "rejected"
  | Cancelled -> "cancelled"
  | Expired -> "expired"
;;

let schedule_status_of_string = function
  | "pending_approval" -> Ok Pending_approval
  | "scheduled" -> Ok Scheduled
  | "due" -> Ok Due
  | "running" -> Ok Running
  | "succeeded" -> Ok Succeeded
  | "failed" -> Ok Failed
  | "rejected" -> Ok Rejected
  | "cancelled" -> Ok Cancelled
  | "expired" -> Ok Expired
  | other -> Error ("unknown schedule_status: " ^ other)
;;

let schedule_source_to_string = function
  | Operator_request -> "operator_request"
  | Automated_request -> "automated_request"
  | System_request -> "system_request"
;;

let schedule_source_of_string = function
  | "operator_request" -> Ok Operator_request
  | "automated_request" -> Ok Automated_request
  | "system_request" -> Ok System_request
  | other -> Error ("unknown schedule_source: " ^ other)
;;

let grant_error_to_string = function
  | Grant_schedule_id_mismatch -> "grant schedule_id does not match request"
  | Approver_not_human -> "approver must be a human operator"
  | Approver_is_requester -> "requester cannot approve execution"
  | Approver_is_scheduler -> "scheduler cannot approve execution"
  | Schedule_terminal -> "schedule is already terminal"
  | Schedule_not_pending_approval -> "schedule is not pending approval"
  | Evidence_schedule_id_mismatch -> "grant evidence schedule_id mismatch"
  | Evidence_payload_digest_mismatch -> "grant evidence payload_digest mismatch"
  | Evidence_due_at_mismatch -> "grant evidence due_at mismatch"
  | Evidence_risk_class_mismatch -> "grant evidence risk_class mismatch"
;;

let is_terminal = function
  | Succeeded | Failed | Rejected | Cancelled | Expired -> true
  | Pending_approval | Scheduled | Due | Running -> false
;;

let is_side_effecting = function
  | Reminder_only | Read_only -> false
  | Workspace_write | External_write | Destructive | Cost_bearing -> true
;;

let requires_separate_human_grant request =
  request.approval_required || is_side_effecting request.risk_class
;;

let rec canonical_json = function
  | `Assoc fields ->
    fields
    |> List.map (fun (key, value) -> key, canonical_json value)
    |> List.sort (fun (left, _) (right, _) -> String.compare left right)
    |> fun fields -> `Assoc fields
  | `List items -> `List (List.map canonical_json items)
  | other -> other
;;

let sha256_json json =
  json |> canonical_json |> Yojson.Safe.to_string
  |> Digestif.SHA256.(fun stable -> digest_string stable |> to_hex)
;;

let option_to_yojson f = function
  | None -> `Null
  | Some value -> f value
;;

let string_option_of_yojson = function
  | `Null -> Ok None
  | `String value -> Ok (Some value)
  | _ -> Error "expected string option"
;;

let float_to_yojson value = `Float value

let float_of_yojson = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error "expected float"
;;

let bool_of_yojson = function
  | `Bool value -> Ok value
  | _ -> Error "expected bool"
;;

let assoc_field name fields =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing field: " ^ name)
;;

let string_field name fields =
  let* value = assoc_field name fields in
  match value with
  | `String value -> Ok value
  | _ -> Error ("expected string field: " ^ name)
;;

let float_field name fields =
  let* value = assoc_field name fields in
  match float_of_yojson value with
  | Ok value -> Ok value
  | Error err -> Error (name ^ ": " ^ err)
;;

let bool_field name fields =
  let* value = assoc_field name fields in
  match bool_of_yojson value with
  | Ok value -> Ok value
  | Error err -> Error (name ^ ": " ^ err)
;;

let actor_to_yojson (actor : actor) =
  `Assoc
    [ "id", `String actor.id
    ; "kind", `String (actor_kind_to_string actor.kind)
    ; "display_name", option_to_yojson (fun value -> `String value) actor.display_name
    ]
;;

let actor_of_yojson = function
  | `Assoc fields ->
    let* id = string_field "id" fields in
    let* kind_name = string_field "kind" fields in
    let* kind = actor_kind_of_string kind_name in
    let* display_name =
      match List.assoc_opt "display_name" fields with
      | None -> Ok None
      | Some value -> string_option_of_yojson value
    in
    Ok { id; kind; display_name }
  | _ -> Error "expected actor object"
;;

let payload_digest payload = sha256_json payload

let evidence_of_request (request : schedule_request) =
  { schedule_id = request.schedule_id
  ; payload_digest = payload_digest request.payload
  ; due_at = request.due_at
  ; risk_class = request.risk_class
  }
;;

let execution_decision_to_yojson = function
  | Approve -> `Assoc [ "kind", `String "approve" ]
  | Reject reason -> `Assoc [ "kind", `String "reject"; "reason", `String reason ]
;;

let execution_decision_of_yojson = function
  | `Assoc fields ->
    let* kind = string_field "kind" fields in
    (match kind with
     | "approve" -> Ok Approve
     | "reject" ->
       let* reason = string_field "reason" fields in
       Ok (Reject reason)
     | other -> Error ("unknown execution_decision: " ^ other))
  | _ -> Error "expected execution_decision object"
;;

let execution_evidence_to_yojson (evidence : execution_evidence) =
  `Assoc
    [ "schedule_id", `String evidence.schedule_id
    ; "payload_digest", `String evidence.payload_digest
    ; "due_at", float_to_yojson evidence.due_at
    ; "risk_class", `String (risk_class_to_string evidence.risk_class)
    ]
;;

let execution_evidence_of_yojson = function
  | `Assoc fields ->
    let* schedule_id = string_field "schedule_id" fields in
    let* payload_digest = string_field "payload_digest" fields in
    let* due_at = float_field "due_at" fields in
    let* risk_name = string_field "risk_class" fields in
    let* risk_class = risk_class_of_string risk_name in
    Ok { schedule_id; payload_digest; due_at; risk_class }
  | _ -> Error "expected execution_evidence object"
;;

let execution_grant_to_yojson (grant : execution_grant) =
  `Assoc
    [ "grant_id", `String grant.grant_id
    ; "schedule_id", `String grant.schedule_id
    ; "approved_by", actor_to_yojson grant.approved_by
    ; "approved_at", float_to_yojson grant.approved_at
    ; "decision", execution_decision_to_yojson grant.decision
    ; "evidence", execution_evidence_to_yojson grant.evidence
    ]
;;

let execution_grant_of_yojson = function
  | `Assoc fields ->
    let* grant_id = string_field "grant_id" fields in
    let* schedule_id = string_field "schedule_id" fields in
    let* approved_by_json = assoc_field "approved_by" fields in
    let* approved_by = actor_of_yojson approved_by_json in
    let* approved_at = float_field "approved_at" fields in
    let* decision_json = assoc_field "decision" fields in
    let* decision = execution_decision_of_yojson decision_json in
    let* evidence_json = assoc_field "evidence" fields in
    let* evidence = execution_evidence_of_yojson evidence_json in
    Ok { grant_id; schedule_id; approved_by; approved_at; decision; evidence }
  | _ -> Error "expected execution_grant object"
;;

let schedule_request_to_yojson (request : schedule_request) =
  `Assoc
    [ "schedule_id", `String request.schedule_id
    ; "requested_by", actor_to_yojson request.requested_by
    ; "scheduled_by", actor_to_yojson request.scheduled_by
    ; "requested_at", float_to_yojson request.requested_at
    ; "due_at", float_to_yojson request.due_at
    ; "expires_at", option_to_yojson float_to_yojson request.expires_at
    ; "payload", request.payload
    ; "risk_class", `String (risk_class_to_string request.risk_class)
    ; "approval_required", `Bool request.approval_required
    ; "status", `String (schedule_status_to_string request.status)
    ; "source", `String (schedule_source_to_string request.source)
    ]
;;

let schedule_request_of_yojson = function
  | `Assoc fields ->
    let* schedule_id = string_field "schedule_id" fields in
    let* requested_by_json = assoc_field "requested_by" fields in
    let* requested_by = actor_of_yojson requested_by_json in
    let* scheduled_by_json = assoc_field "scheduled_by" fields in
    let* scheduled_by = actor_of_yojson scheduled_by_json in
    let* requested_at = float_field "requested_at" fields in
    let* due_at = float_field "due_at" fields in
    let* expires_at =
      match List.assoc_opt "expires_at" fields with
      | None | Some `Null -> Ok None
      | Some value ->
        let* value = float_of_yojson value in
        Ok (Some value)
    in
    let* payload = assoc_field "payload" fields in
    let* risk_name = string_field "risk_class" fields in
    let* risk_class = risk_class_of_string risk_name in
    let* approval_required = bool_field "approval_required" fields in
    let* status_name = string_field "status" fields in
    let* status = schedule_status_of_string status_name in
    let* source_name = string_field "source" fields in
    let* source = schedule_source_of_string source_name in
    Ok
      { schedule_id
      ; requested_by
      ; scheduled_by
      ; requested_at
      ; due_at
      ; expires_at
      ; payload
      ; risk_class
      ; approval_required
      ; status
      ; source
      }
  | _ -> Error "expected schedule_request object"
;;

let create_request
  ~schedule_id
  ~requested_by
  ~scheduled_by
  ~requested_at
  ~due_at
  ?expires_at
  ~payload
  ~risk_class
  ~approval_required
  ~source
  ()
  =
  let* schedule_id = nonempty "schedule_id" schedule_id in
  let* _ = nonempty "requested_by.id" requested_by.id in
  let* _ = nonempty "scheduled_by.id" scheduled_by.id in
  let approval_required = approval_required || is_side_effecting risk_class in
  let status = if approval_required then Pending_approval else Scheduled in
  Ok
    { schedule_id
    ; requested_by
    ; scheduled_by
    ; requested_at
    ; due_at
    ; expires_at
    ; payload
    ; risk_class
    ; approval_required
    ; status
    ; source
    }
;;

let create_execution_grant
  ~grant_id
  ~approved_by
  ~approved_at
  ~decision
  (request : schedule_request)
  =
  { grant_id
  ; schedule_id = request.schedule_id
  ; approved_by
  ; approved_at
  ; decision
  ; evidence = evidence_of_request request
  }
;;

let validate_execution_grant (request : schedule_request) (grant : execution_grant) =
  if grant.schedule_id <> request.schedule_id then Error Grant_schedule_id_mismatch
  else if is_terminal request.status then Error Schedule_terminal
  else if request.status <> Pending_approval then Error Schedule_not_pending_approval
  else if requires_separate_human_grant request && grant.approved_by.kind <> Human_operator
  then Error Approver_not_human
  else if requires_separate_human_grant request
          && String.equal grant.approved_by.id request.requested_by.id
  then Error Approver_is_requester
  else if requires_separate_human_grant request
          && String.equal grant.approved_by.id request.scheduled_by.id
  then Error Approver_is_scheduler
  else (
    let expected = evidence_of_request request in
    if grant.evidence.schedule_id <> expected.schedule_id then
      Error Evidence_schedule_id_mismatch
    else if grant.evidence.payload_digest <> expected.payload_digest then
      Error Evidence_payload_digest_mismatch
    else if grant.evidence.due_at <> expected.due_at then Error Evidence_due_at_mismatch
    else if grant.evidence.risk_class <> expected.risk_class then
      Error Evidence_risk_class_mismatch
    else
      Ok ())
;;

let apply_execution_grant (request : schedule_request) (grant : execution_grant) =
  let* () = validate_execution_grant request grant in
  match grant.decision with
  | Approve -> Ok { request with status = Scheduled }
  | Reject _ -> Ok { request with status = Rejected }
;;

let mark_due ~now (request : schedule_request) =
  match request.status with
  | Scheduled when request.due_at <= now -> { request with status = Due }
  | _ -> request
;;
