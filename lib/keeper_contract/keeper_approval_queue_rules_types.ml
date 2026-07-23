(** Non-hierarchical HITL queue types and JSON serialization. *)

(* tla-lint: file-scope: approval queue types and conversions. *)

type advisory_judgment =
  | Approve
  | Deny
  | Require_human

type hitl_context_summary =
  { summary_version : int
  ; generated_at : float
  ; model_run_id : string
  ; context_summary : string
  ; key_questions : string list
  ; judgment : advisory_judgment
  ; rationale : string
  }

and summary_status =
  | Summary_not_requested
  | Summary_pending
  | Summary_available of hitl_context_summary
  | Summary_failed of { reason : string; retryable : bool }

type exact_attempt_quarantine_cause =
  | Exact_flow_execution_failed
  | Exact_cancellation
  | Exact_attempt_replay
  | Exact_domain_invalid_output
  | Exact_terminal_persistence_failure
  | Exact_restart_uncertainty

type exact_attempt_status =
  | Exact_dispatch_uncertain
  | Exact_released_before_dispatch
  | Exact_quarantined of exact_attempt_quarantine_cause
  | Exact_completed

type exact_attempt_binding =
  { approval_id : string
  ; input_hash : string
  ; sequence : int
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; status : exact_attempt_status
  }

let make_exact_attempt_binding
      ~approval_id
      ~input_hash
      ~sequence
      ~slot_id
      ~call_id
      ~plan_fingerprint
      ~request_body_sha256
      ()
  =
  { approval_id
  ; input_hash
  ; sequence
  ; slot_id
  ; call_id
  ; plan_fingerprint
  ; request_body_sha256
  ; status = Exact_dispatch_uncertain
  }
;;

let exact_attempt_binding_with_status binding status = { binding with status }

type exact_attempt_state =
  | Exact_unbound
  | Exact_bound of exact_attempt_binding

type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; input_hash : string
  ; input : Yojson.Safe.t
  ; sequence : int
  ; requested_at : float
  ; turn_id : int option
  ; request_context : Yojson.Safe.t option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; continuation_channel : Keeper_continuation_channel.t
  ; audit_base_path : string
  ; summary_status : summary_status
  ; exact_attempt : exact_attempt_state
  }

module Decision = struct
  type t =
    | Approve
    | Reject of string
    | Edit of Yojson.Safe.t
end

type decision = Decision.t

type decision_source =
  | Always_allowed
  | Auto_judge
  | Human_operator

type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; request_fingerprint : string
  ; created_at : float
  ; created_by : string option
  ; source_approval_id : string option
  ; expires_at : float option
  }

type rule_match = { rule_id : string }

(** Exact rule lookup outcome. An expired rule never authorizes; it stays
    stored and observable until an operator deletes it. *)
type rule_lookup =
  | Rule_match_active of rule_match
  | Rule_match_expired of rule_match
  | Rule_match_absent

type rule_store_error =
  { path : string
  ; reason : string
  }

type resolution_result = { remembered_rule : approval_rule option }

let advisory_judgment_to_string = function
  | Approve -> "approve"
  | Deny -> "deny"
  | Require_human -> "require_human"
;;

let advisory_judgment_values =
  List.map advisory_judgment_to_string [ Approve; Deny; Require_human ]
;;

let advisory_judgment_of_string = function
  | "approve" -> Some Approve
  | "deny" -> Some Deny
  | "require_human" -> Some Require_human
  | _ -> None
;;

let approval_decision_to_string = function
  | Decision.Approve -> "approve"
  | Decision.Reject reason -> "reject:" ^ reason
  | Decision.Edit _ -> "edit"
;;

let decision_source_to_string = function
  | Always_allowed -> "always_allowed"
  | Auto_judge -> "auto_judge"
  | Human_operator -> "human_operator"
;;

let decision_source_of_string = function
  | "always_allowed" -> Some Always_allowed
  | "auto_judge" -> Some Auto_judge
  | "human_operator" -> Some Human_operator
  | _ -> None
;;

let string_opt_of_json = function
  | `String value ->
    let trimmed = String.trim value in
    if String.equal trimmed "" then None else Some trimmed
  | _ -> None
;;

let bool_member key json ~default =
  match Json_util.assoc_member_opt key json with
  | Some (`Bool value) -> value
  | _ -> default
;;

let rule_match_to_yojson (matched : rule_match) =
  `Assoc [ "rule_id", `String matched.rule_id ]
;;

let rule_store_error_to_string error =
  Printf.sprintf "%s: %s" error.path error.reason
;;

let rule_expired ~now (rule : approval_rule) =
  match rule.expires_at with
  | None -> false
  | Some expires_at -> expires_at <= now
;;

let approval_rule_to_yojson (rule : approval_rule) =
  `Assoc
    [ "id", `String rule.id
    ; "keeper_name", `String rule.keeper_name
    ; "tool_name", `String rule.tool_name
    ; "request_fingerprint", `String rule.request_fingerprint
    ; "created_at", `Float rule.created_at
    ; "created_by", Json_util.string_opt_to_json rule.created_by
    ; "source_approval_id", Json_util.string_opt_to_json rule.source_approval_id
    ; "expires_at", Json_util.float_opt_to_json rule.expires_at
    ]
;;

let hitl_context_summary_to_yojson (summary : hitl_context_summary) =
  `Assoc
    [ "summary_version", `Int summary.summary_version
    ; "generated_at", `Float summary.generated_at
    ; "model_run_id", `String summary.model_run_id
    ; "context_summary", `String summary.context_summary
    ; "key_questions", Json_util.json_string_list summary.key_questions
    ; "judgment", `String (advisory_judgment_to_string summary.judgment)
    ; "rationale", `String summary.rationale
    ]
;;

let summary_status_to_yojson = function
  | Summary_not_requested -> `String "not_requested"
  | Summary_pending -> `String "pending"
  | Summary_available summary ->
    `Assoc
      [ "status", `String "available"
      ; "summary", hitl_context_summary_to_yojson summary
      ]
  | Summary_failed { reason; retryable } ->
    `Assoc
      [ "status", `String "failed"
      ; "reason", `String reason
      ; "retryable", `Bool retryable
      ]
;;

let exact_attempt_status_to_string = function
  | Exact_dispatch_uncertain -> "dispatch_uncertain"
  | Exact_released_before_dispatch -> "released_before_dispatch"
  | Exact_quarantined _ -> "quarantined"
  | Exact_completed -> "completed"
;;

let exact_attempt_quarantine_cause_to_string = function
  | Exact_flow_execution_failed -> "flow_execution_failed"
  | Exact_cancellation -> "cancellation"
  | Exact_attempt_replay -> "attempt_replay"
  | Exact_domain_invalid_output -> "domain_invalid_output"
  | Exact_terminal_persistence_failure -> "terminal_persistence_failure"
  | Exact_restart_uncertainty -> "restart_uncertainty"
;;

let exact_attempt_state_to_yojson = function
  | Exact_unbound -> `Assoc [ "state", `String "unbound" ]
  | Exact_bound binding ->
    let quarantine_cause =
      match binding.status with
      | Exact_quarantined cause ->
        `String (exact_attempt_quarantine_cause_to_string cause)
      | Exact_dispatch_uncertain
      | Exact_released_before_dispatch
      | Exact_completed ->
        `Null
    in
    `Assoc
      [ "state", `String "bound"
      ; "approval_id", `String binding.approval_id
      ; "input_hash", `String binding.input_hash
      ; "sequence", `Int binding.sequence
      ; "slot_id", `String binding.slot_id
      ; "call_id", `String binding.call_id
      ; "plan_fingerprint", `String binding.plan_fingerprint
      ; "request_body_sha256", `String binding.request_body_sha256
      ; "status", `String (exact_attempt_status_to_string binding.status)
      ; "quarantine_cause", quarantine_cause
      ]
;;

let reject_unknown_fields ~surface ~allowed fields =
  let rec duplicate seen = function
    | [] -> None
    | (key, _) :: rest ->
      if List.mem key seen then Some key else duplicate (key :: seen) rest
  in
  match duplicate [] fields with
  | Some field -> Error (Printf.sprintf "%s contains duplicate field %s" surface field)
  | None ->
    (match List.find_opt (fun (key, _) -> not (List.mem key allowed)) fields with
     | None -> Ok ()
     | Some (field, _) ->
       Error (Printf.sprintf "%s contains unsupported field %s" surface field))
;;

let required_string ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`String value) when String.trim value <> "" -> Ok value
  | Some (`String _) ->
    Error (Printf.sprintf "%s.%s must be non-blank" surface field)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a string" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_float ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (Float.of_int value)
  | Some _ -> Error (Printf.sprintf "%s.%s must be a number" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_positive_int ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`Int value) when value > 0 -> Ok value
  | Some _ -> Error (Printf.sprintf "%s.%s must be a positive integer" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let required_string_list ~surface field fields =
  match List.assoc_opt field fields with
  | Some (`List values) ->
    let rec parse index acc = function
      | [] -> Ok (List.rev acc)
      | `String value :: rest -> parse (index + 1) (value :: acc) rest
      | _ :: _ ->
        Error
          (Printf.sprintf "%s.%s[%d] must be a string" surface field index)
    in
    parse 0 [] values
  | Some _ -> Error (Printf.sprintf "%s.%s must be an array" surface field)
  | None -> Error (Printf.sprintf "%s.%s is required" surface field)
;;

let exact_attempt_quarantine_cause_of_string = function
  | "flow_execution_failed" -> Ok Exact_flow_execution_failed
  | "cancellation" -> Ok Exact_cancellation
  | "attempt_replay" -> Ok Exact_attempt_replay
  | "domain_invalid_output" -> Ok Exact_domain_invalid_output
  | "terminal_persistence_failure" -> Ok Exact_terminal_persistence_failure
  | "restart_uncertainty" -> Ok Exact_restart_uncertainty
  | cause ->
    Error
      (Printf.sprintf
         "exact_attempt.quarantine_cause %S is unknown"
         cause)
;;

let is_lowercase_sha256 value =
  let rec loop index =
    if index = String.length value
    then true
    else
      match value.[index] with
      | '0' .. '9'
      | 'a' .. 'f' ->
        loop (index + 1)
      | _ -> false
  in
  String.length value = 64 && loop 0
;;

let exact_attempt_state_of_yojson_with_error json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "exact_attempt" in
    let* state = required_string ~surface "state" fields in
    (match state with
     | "unbound" ->
       let* () = reject_unknown_fields ~surface ~allowed:[ "state" ] fields in
       Ok Exact_unbound
     | "bound" ->
       let* () =
         reject_unknown_fields
           ~surface
           ~allowed:
             [ "state"
             ; "approval_id"
             ; "input_hash"
             ; "sequence"
             ; "slot_id"
             ; "call_id"
             ; "plan_fingerprint"
             ; "request_body_sha256"
             ; "status"
             ; "quarantine_cause"
             ]
           fields
       in
       let* approval_id = required_string ~surface "approval_id" fields in
       let* input_hash = required_string ~surface "input_hash" fields in
       let* sequence = required_positive_int ~surface "sequence" fields in
       let* slot_id = required_string ~surface "slot_id" fields in
       let* call_id = required_string ~surface "call_id" fields in
       let* plan_fingerprint = required_string ~surface "plan_fingerprint" fields in
       let* request_body_sha256 =
         required_string ~surface "request_body_sha256" fields
       in
       let* () =
         if is_lowercase_sha256 request_body_sha256
         then Ok ()
         else
           Error
             "exact_attempt.request_body_sha256 must be exactly 64 lowercase hexadecimal characters"
       in
       let* status_raw = required_string ~surface "status" fields in
       let* quarantine_cause =
         match List.assoc_opt "quarantine_cause" fields with
         | Some value -> Ok value
         | None -> Error "exact_attempt.quarantine_cause is required"
       in
       let* status =
         match status_raw, quarantine_cause with
         | "dispatch_uncertain", `Null -> Ok Exact_dispatch_uncertain
         | "released_before_dispatch", `Null ->
           Ok Exact_released_before_dispatch
         | "completed", `Null -> Ok Exact_completed
         | "quarantined", `String cause ->
           let* cause = exact_attempt_quarantine_cause_of_string cause in
           Ok (Exact_quarantined cause)
         | "quarantined", _ ->
           Error
             "exact_attempt.quarantined requires a typed quarantine_cause"
         | ( "dispatch_uncertain"
           | "released_before_dispatch"
           | "completed" ),
           _ ->
           Error
             "non-quarantined exact_attempt status requires null quarantine_cause"
         | status, _ ->
           Error (Printf.sprintf "exact_attempt.status %S is unknown" status)
       in
       Ok
         (Exact_bound
            { approval_id
            ; input_hash
            ; sequence
            ; slot_id
            ; call_id
            ; plan_fingerprint
            ; request_body_sha256
            ; status
            })
     | state ->
       Error (Printf.sprintf "%s.state %S is unknown" surface state))
  | _ -> Error "exact_attempt must be a JSON object"
;;

let hitl_context_summary_of_yojson_with_error json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let surface = "hitl_context_summary" in
    let* () =
      reject_unknown_fields
        ~surface
        ~allowed:
          [ "summary_version"
          ; "generated_at"
          ; "model_run_id"
          ; "context_summary"
          ; "key_questions"
          ; "judgment"
          ; "rationale"
          ]
        fields
    in
    let* summary_version = required_positive_int ~surface "summary_version" fields in
    let* generated_at = required_float ~surface "generated_at" fields in
    let* model_run_id = required_string ~surface "model_run_id" fields in
    let* context_summary = required_string ~surface "context_summary" fields in
    let* key_questions = required_string_list ~surface "key_questions" fields in
    let* judgment_raw = required_string ~surface "judgment" fields in
    let* judgment =
      match advisory_judgment_of_string judgment_raw with
      | Some judgment -> Ok judgment
      | None ->
        Error
          (Printf.sprintf
             "%s.judgment %S is not %s"
             surface
             judgment_raw
             (String.concat "/" advisory_judgment_values))
    in
    let* rationale = required_string ~surface "rationale" fields in
    Ok
      { summary_version
      ; generated_at
      ; model_run_id
      ; context_summary
      ; key_questions
      ; judgment
      ; rationale
      }
  | _ -> Error "hitl_context_summary must be a JSON object"
;;

let summary_status_of_yojson_with_error json =
  let ( let* ) = Result.bind in
  match json with
  | `String "not_requested" -> Ok Summary_not_requested
  | `String "pending" -> Ok Summary_pending
  | `Assoc fields ->
    let* status = required_string ~surface:"summary_status" "status" fields in
    (match status with
     | "available" ->
       let* () =
         reject_unknown_fields
           ~surface:"summary_status"
           ~allowed:[ "status"; "summary" ]
           fields
       in
       (match List.assoc_opt "summary" fields with
        | None -> Error "summary_status.summary is required"
        | Some json ->
          let* summary = hitl_context_summary_of_yojson_with_error json in
          Ok (Summary_available summary))
     | "failed" ->
       let* () =
         reject_unknown_fields
           ~surface:"summary_status"
           ~allowed:[ "status"; "reason"; "retryable" ]
           fields
       in
       let* reason = required_string ~surface:"summary_status" "reason" fields in
       (match List.assoc_opt "retryable" fields with
        | Some (`Bool retryable) -> Ok (Summary_failed { reason; retryable })
        | Some _ -> Error "summary_status.retryable must be a boolean"
        | None -> Error "summary_status.retryable is required")
     | other -> Error (Printf.sprintf "summary_status.status %S is unknown" other))
  | _ -> Error "summary_status must be a known string or JSON object"
;;

let approval_rule_of_yojson_with_error json =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* () =
      match
        reject_unknown_fields
          ~surface:"approval rule"
          ~allowed:
            [ "id"
            ; "keeper_name"
            ; "tool_name"
            ; "request_fingerprint"
            ; "created_at"
            ; "created_by"
            ; "source_approval_id"
            ; "expires_at"
            ]
          fields
      with
      | Ok () -> Ok ()
      | Error reason -> Error (reason ^ "; explicit re-approval is required")
    in
    let require field =
      match Json_util.get_string_nonempty json field with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "%s must be a non-blank string" field)
    in
    let* id = require "id" in
    let* keeper_name = require "keeper_name" in
    let* tool_name = require "tool_name" in
    let* request_fingerprint = require "request_fingerprint" in
    let* created_at =
      match Json_util.get_float json "created_at" with
      | Some value -> Ok value
      | None -> Error "created_at must be a number"
    in
    let created_by = Json_util.get_string json "created_by" in
    let source_approval_id = Json_util.get_string json "source_approval_id" in
    let* expires_at =
      match List.assoc_opt "expires_at" fields with
      | None | Some `Null -> Ok None
      | Some (`Float value) -> Ok (Some value)
      | Some (`Int value) -> Ok (Some (Float.of_int value))
      | Some _ -> Error "expires_at must be a number or null"
    in
    Ok
      { id
      ; keeper_name
      ; tool_name
      ; request_fingerprint
      ; created_at
      ; created_by
      ; source_approval_id
      ; expires_at
      }
  | _ -> Error "approval rule must be a JSON object"
;;

let approval_rule_of_yojson json =
  match approval_rule_of_yojson_with_error json with
  | Ok rule -> Some rule
  | Error _ -> None
;;
