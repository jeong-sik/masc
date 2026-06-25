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
  ; audit_base_path : string
  ; resolver : Agent_sdk.Hooks.approval_decision Eio.Promise.u option
  ; on_resolution : (Agent_sdk.Hooks.approval_decision -> unit) option
  }

type decision = Agent_sdk.Hooks.approval_decision

type approval_audit_decision =
  | Approval_resolved of decision
  | Approval_expired of string

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

let approval_decision_to_string = function
  | Agent_sdk.Hooks.Approve -> "approve"
  | Agent_sdk.Hooks.Reject reason -> "reject:" ^ reason
  | Agent_sdk.Hooks.Edit _ -> "edit"
;;

let approval_audit_decision_to_string = function
  | Approval_resolved decision -> approval_decision_to_string decision
  | Approval_expired reason -> "reject:" ^ reason
;;

let string_opt_of_json = function
  | `String value ->
    let trimmed = String.trim value in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

(* RFC-0145 — narrow the wildcard catch-all to the only exception
   [Yojson.Safe.Util.member] can raise on non-object inputs.  An
   unrelated runtime exception (e.g. [Out_of_memory], async failure,
   unexpected internal contract break) will now propagate to the
   caller instead of being silently coerced to [None]. *)
let string_opt_member key json =
  match Json_util.assoc_member_opt key json with
  | Some value -> string_opt_of_json value
  | None -> None
;;

let bool_member key json ~default =
  match Json_util.assoc_member_opt key json with
  | Some (`Bool value) -> value
  | _ -> default
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

let approval_rule_of_yojson json =
  let ( let* ) = Option.bind in
  let required_string field =
    match Json_util.assoc_member_opt field json with
    | Some (`String value) ->
      let value = String.trim value in
      if String.equal value "" then None else Some value
    | _ -> None
  in
  let* id = required_string "id" in
  let* keeper_name = required_string "keeper_name" in
  let* tool_name = required_string "tool_name" in
  let sandbox_profile = Json_util.get_string json "sandbox_profile" in
  let backend = Json_util.get_string json "backend" in
  let* request_fingerprint = required_string "request_fingerprint" in
  let request_fingerprint_preview =
    Json_util.get_string json "request_fingerprint_preview"
    |> Option.value
         ~default:
           (String.sub
              request_fingerprint
              0
              (min 12 (String.length request_fingerprint)))
  in
  let* max_risk =
    match Json_util.assoc_member_opt "max_risk" json with
    | Some (`String value) -> risk_level_of_string value
    | _ -> None
  in
  let* created_at = Json_util.get_float json "created_at" in
  let created_by = Json_util.get_string json "created_by" in
  let last_matched_at = Json_util.get_float json "last_matched_at" in
  let* match_count = Json_util.get_int json "match_count" in
  let source_approval_id = Json_util.get_string json "source_approval_id" in
  Some
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
;;
