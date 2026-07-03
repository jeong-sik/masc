(** Keeper_approval_queue_rules_types — types, conversions, and JSON
    serialization extracted from [Keeper_approval_queue_rules] (510 LoC).
    State management (SMap, atomic_update, CRUD) remains in the parent.
    @since Keeper 500-line decomposition *)

(* tla-lint: file-scope: approval queue types and conversions. *)

type risk_level =
  | Low
  | Medium
  | High
  | Critical

type suggested_option =
  { label : string
  ; rationale : string
  ; estimated_risk_delta : risk_level option
  }

type hitl_context_summary =
  { summary_version : int
  ; generated_at : float
  ; model_run_id : string
  ; context_summary : string
  ; key_questions : string list
  ; suggested_options : suggested_option list
  ; risk_rationale : string option
  ; uncertainty : float
  }

and summary_status =
  | Summary_not_requested
  | Summary_pending
  | Summary_available of hitl_context_summary
  | Summary_failed of { reason : string; retryable : bool }

type pending_phase =
  | Awaiting_operator
  | Escalated

type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; action_key : string
  ; input_hash : string
  ; sandbox_target : string
  ; sandbox_profile : string option
  ; backend : string option
  ; input : Yojson.Safe.t
  ; risk_level : risk_level
  ; requested_at : float
  ; turn_id : int option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; runtime_contract : Yojson.Safe.t option
  ; selected_model : string option
  ; disposition : string option
  ; disposition_reason : string option
  ; phase : pending_phase
  ; audit_base_path : string
  ; resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option
  ; on_resolution : (Agent_sdk.Hooks.approval_decision -> unit) option
  ; context_summary : hitl_context_summary option
  ; summary_status : summary_status
  }

type decision = Agent_sdk.Hooks.approval_decision

type approval_audit_decision =
  | Approval_resolved of decision
  | Approval_expired of string

type approval_audit_disposition =
  | Approval_escalated of string

type approval_rule =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; sandbox_profile : string option
  ; backend : string option
  ; request_fingerprint : string
  ; request_fingerprint_preview : string
  ; max_risk : risk_level
  ; created_at : float
  ; created_by : string option
  ; last_matched_at : float option
  ; match_count : int
  ; source_approval_id : string option
  }

type rule_match =
  { rule_id : string
  ; matched_by : string
  }

type resolution_result = { remembered_rule : approval_rule option }

let risk_level_to_string = function
  | Low -> "low"
  | Medium -> "medium"
  | High -> "high"
  | Critical -> "critical"
;;

let allowed_risk_levels = [ Low; Medium; High; Critical ]

let allowed_risk_level_values = List.map risk_level_to_string allowed_risk_levels

let allowed_risk_level_values_label = String.concat "/" allowed_risk_level_values

let risk_level_to_int = function
  | Low -> 1
  | Medium -> 2
  | High -> 3
  | Critical -> 4
;;

let risk_level_of_string = function
  | "low" -> Some Low
  | "medium" -> Some Medium
  | "high" -> Some High
  | "critical" -> Some Critical
  | _ -> None
;;

let pending_phase_to_string = function
  | Awaiting_operator -> "awaiting_operator"
  | Escalated -> "escalated"
;;

let pending_phase_of_string = function
  | "awaiting_operator" -> Some Awaiting_operator
  | "escalated" -> Some Escalated
  | _ -> None
;;

let approval_decision_to_string = function
  | Agent_sdk.Hooks.Approve -> "approve"
  | Agent_sdk.Hooks.Reject reason -> "reject:" ^ reason
  | Agent_sdk.Hooks.Edit _ -> "edit"
;;

let approval_audit_decision_to_string = function
  | Approval_resolved decision -> approval_decision_to_string decision
  | Approval_expired reason -> "reject:" ^ reason
;;

let fingerprint_preview_length = 12
;;

let string_opt_of_json = function
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let bool_member key json ~default =
  match Json_util.assoc_member_opt key json with
  | Some (`Bool value) -> value
  | _ -> default
;;

let non_negative_int_member key json =
  match Json_util.get_int json key with
  | Some value when value >= 0 -> Some value
  | _ -> None
;;

let rule_match_to_yojson (matched : rule_match) =
  `Assoc [ "rule_id", `String matched.rule_id; "matched_by", `String matched.matched_by ]
;;

let approval_rule_to_yojson (rule : approval_rule) =
  `Assoc
    [ "id", `String rule.id
    ; "keeper_name", `String rule.keeper_name
    ; "tool_name", `String rule.tool_name
    ; "sandbox_profile", Json_util.string_opt_to_json rule.sandbox_profile
    ; "backend", Json_util.string_opt_to_json rule.backend
    ; "request_fingerprint", `String rule.request_fingerprint
    ; "request_fingerprint_preview", `String rule.request_fingerprint_preview
    ; "max_risk", `String (risk_level_to_string rule.max_risk)
    ; "created_at", `Float rule.created_at
    ; "created_at_iso", `String (Masc_domain.iso8601_of_unix_seconds rule.created_at)
    ; "created_by", Json_util.string_opt_to_json rule.created_by
    ; "last_matched_at", Json_util.float_opt_to_json rule.last_matched_at
    ; ( "last_matched_at_iso"
      , match rule.last_matched_at with
        | Some ts -> `String (Masc_domain.iso8601_of_unix_seconds ts)
        | None -> `Null )
    ; "match_count", `Int rule.match_count
    ; "source_approval_id", Json_util.string_opt_to_json rule.source_approval_id
    ]
;;

let rec suggested_option_to_yojson (option : suggested_option) =
  `Assoc
    [ "label", `String option.label
    ; "rationale", `String option.rationale
    ; ( "estimated_risk_delta"
      , Json_util.option_to_yojson
          (fun risk -> `String (risk_level_to_string risk))
          option.estimated_risk_delta )
    ]

and hitl_context_summary_to_yojson (summary : hitl_context_summary) =
  `Assoc
    [ "summary_version", `Int summary.summary_version
    ; "generated_at", `Float summary.generated_at
    ; ( "generated_at_iso"
      , `String (Masc_domain.iso8601_of_unix_seconds summary.generated_at) )
    ; "model_run_id", `String summary.model_run_id
    ; "context_summary", `String summary.context_summary
    ; "key_questions", Json_util.json_string_list summary.key_questions
    ; ( "suggested_options"
      , `List (List.map suggested_option_to_yojson summary.suggested_options) )
    ; "risk_rationale", Json_util.string_opt_to_json summary.risk_rationale
    ; "uncertainty", `Float summary.uncertainty
    ]

and summary_status_to_yojson = function
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

let approval_rule_of_yojson_with_error json =
  match json with
  | `Assoc _ ->
    let ( let* ) = Result.bind in
    let require field json =
      match Json_util.get_string_nonempty json field with
      | Some value -> Ok value
      | None -> Error (Printf.sprintf "%s must be a non-blank string" field)
    in
    let* id = require "id" json in
    let* keeper_name = require "keeper_name" json in
    let* tool_name = require "tool_name" json in
    let sandbox_profile = Json_util.get_string json "sandbox_profile" in
    let backend = Json_util.get_string json "backend" in
    let* request_fingerprint = require "request_fingerprint" json in
    let request_fingerprint_preview =
      Json_util.get_string_nonempty json "request_fingerprint_preview"
      |> Option.value
           ~default:
             (String.sub
                request_fingerprint
                0
                (min fingerprint_preview_length (String.length request_fingerprint)))
    in
    let* max_risk_raw = require "max_risk" json in
    let* max_risk =
      match risk_level_of_string max_risk_raw with
      | Some level -> Ok level
      | None ->
        Error
          (Printf.sprintf
             "max_risk %S is not %s"
             max_risk_raw
             allowed_risk_level_values_label)
    in
    let* created_at =
      match Json_util.get_float json "created_at" with
      | Some value -> Ok value
      | None -> Error "created_at must be a number"
    in
    let created_by = Json_util.get_string json "created_by" in
    let last_matched_at = Json_util.get_float json "last_matched_at" in
    let* match_count =
      match non_negative_int_member "match_count" json with
      | Some value -> Ok value
      | None -> Error "match_count must be a non-negative integer"
    in
    let source_approval_id = Json_util.get_string json "source_approval_id" in
    Ok
      { id
      ; keeper_name
      ; tool_name
      ; sandbox_profile
      ; backend
      ; request_fingerprint
      ; request_fingerprint_preview
      ; max_risk
      ; created_at
      ; created_by
      ; last_matched_at
      ; match_count
      ; source_approval_id
      }
  | _ -> Error "approval rule must be a JSON object"
;;

let approval_rule_of_yojson json =
  match approval_rule_of_yojson_with_error json with
  | Ok rule -> Some rule
  | Error _ -> None
;;
