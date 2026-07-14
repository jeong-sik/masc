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

type pending_approval =
  { id : string
  ; keeper_name : string
  ; tool_name : string
  ; input_hash : string
  ; input : Yojson.Safe.t
  ; requested_at : float
  ; turn_id : int option
  ; request_context : Yojson.Safe.t option
  ; task_id : string option
  ; goal_id : string option
  ; goal_ids : string list
  ; continuation_channel : Keeper_continuation_channel.t
  ; audit_base_path : string
  ; summary_status : summary_status
  }

type decision =
  | Approve
  | Reject of string
  | Edit of Yojson.Safe.t

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
  }

type rule_match = { rule_id : string }

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

let approval_decision_to_string (decision : decision) =
  match decision with
  | Approve -> "approve"
  | Reject reason -> "reject:" ^ reason
  | Edit _ -> "edit"
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

let approval_rule_to_yojson (rule : approval_rule) =
  `Assoc
    [ "id", `String rule.id
    ; "keeper_name", `String rule.keeper_name
    ; "tool_name", `String rule.tool_name
    ; "request_fingerprint", `String rule.request_fingerprint
    ; "created_at", `Float rule.created_at
    ; "created_by", Json_util.string_opt_to_json rule.created_by
    ; "source_approval_id", Json_util.string_opt_to_json rule.source_approval_id
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
    Ok
      { id
      ; keeper_name
      ; tool_name
      ; request_fingerprint
      ; created_at
      ; created_by
      ; source_approval_id
      }
  | _ -> Error "approval rule must be a JSON object"
;;

let approval_rule_of_yojson json =
  match approval_rule_of_yojson_with_error json with
  | Ok rule -> Some rule
  | Error _ -> None
;;
