open Keeper_gate_types

let auto_judge_completion_rejection_to_string = function
  | Completion_not_found -> "not_found"
  | Completion_key_mismatch -> "key_mismatch"
  | Completion_invalid_identity -> "invalid_identity"
  | Completion_summary_not_pending -> "summary_not_pending"
  | Completion_unbound_state -> "unbound_state"
  | Completion_disposition_conflict -> "disposition_conflict"
  | Completion_identity_conflict -> "identity_conflict"
  | Completion_status_conflict -> "status_conflict"
  | Completion_provenance_mismatch -> "provenance_mismatch"
  | Completion_content_conflict -> "content_conflict"
;;

let auto_judge_resume_failure_code_to_string = function
  | Resume_worker_start_failed -> "worker_start_failed"
  | Resume_identity_unbound -> "identity_unbound"
  | Resume_completion_persistence_uncertain -> "completion_persistence_uncertain"
  | Resume_completion_rejected rejection ->
    "completion_rejected:"
    ^ auto_judge_completion_rejection_to_string rejection
  | Resume_judgment_resolution_failed -> "judgment_resolution_failed"
  | Resume_exact_state_not_completed -> "exact_state_not_completed"
;;

let completion_rejection_of_exact_attempt = function
  | Keeper_approval_queue_result.Exact_attempt_not_found _ ->
    Completion_not_found
  | Keeper_approval_queue_result.Exact_attempt_key_mismatch _ ->
    Completion_key_mismatch
  | Keeper_approval_queue_result.Exact_attempt_invalid_identity _ ->
    Completion_invalid_identity
  | Keeper_approval_queue_result.Exact_attempt_summary_not_pending _ ->
    Completion_summary_not_pending
  | Keeper_approval_queue_result.Exact_attempt_unbound_state _ ->
    Completion_unbound_state
  | Keeper_approval_queue_result.Exact_attempt_disposition_conflict _ ->
    Completion_disposition_conflict
  | Keeper_approval_queue_result.Exact_attempt_identity_conflict _ ->
    Completion_identity_conflict
  | Keeper_approval_queue_result.Exact_attempt_status_conflict _ ->
    Completion_status_conflict
  | Keeper_approval_queue_result.Exact_attempt_provenance_mismatch _ ->
    Completion_provenance_mismatch
  | Keeper_approval_queue_result.Exact_attempt_content_conflict _ ->
    Completion_content_conflict
;;

let completion_rejection_operator_detail = function
  | Completion_not_found ->
    "Exact completion was rejected because the approval no longer exists."
  | Completion_key_mismatch ->
    "Exact completion was rejected because the durable row identity changed."
  | Completion_invalid_identity ->
    "Exact completion was rejected because its identity is invalid."
  | Completion_summary_not_pending ->
    "Exact completion was rejected because the summary is not pending."
  | Completion_unbound_state ->
    "Exact completion was rejected because no attempt identity is bound."
  | Completion_disposition_conflict ->
    "Exact completion was rejected because the durable disposition changed."
  | Completion_identity_conflict ->
    "Exact completion was rejected because a different attempt is bound."
  | Completion_status_conflict ->
    "Exact completion was rejected by the durable attempt status."
  | Completion_provenance_mismatch ->
    "Exact completion was rejected because its provenance does not match."
  | Completion_content_conflict ->
    "Exact completion was rejected because different summary content is already durable."
;;

let status_label = function
  | Unix.WEXITED code -> Printf.sprintf "exit=%d" code
  | Unix.WSIGNALED signal -> Printf.sprintf "signal=%d" signal
  | Unix.WSTOPPED signal -> Printf.sprintf "stopped=%d" signal
;;

let authorization_source_to_string = function
  | One_shot_resolution _ -> "one_shot_resolution"
  | Exact_always_rule _ -> "exact_always_rule"
  | Keeper_always_allow -> "keeper_always_allow"
  | Workspace_always_allow -> "workspace_always_allow"
  | Readonly_sandbox -> "readonly_sandbox"
  | Local_output -> "local_output"
  | Observed_in_box _ -> "observed_in_box"
;;

let deferred_reason_to_string = function
  | Human_requested -> "human_requested"
  | Judge_requested -> "judge_requested"
  | Auto_judge_unavailable _ ->
    Keeper_approval_queue_rules_types.summary_attempt_pre_worker_unavailable_code_to_string
      Keeper_approval_queue_rules_types.Summary_pre_worker_auto_judge_unavailable
  | Mode_state_invalid _ ->
    Keeper_approval_queue_rules_types.summary_attempt_pre_worker_unavailable_code_to_string
      Keeper_approval_queue_rules_types.Summary_pre_worker_mode_state_invalid
;;

let unavailable_reason_to_string = function
  | Queue_storage_unavailable error ->
    Keeper_approval_queue_result.storage_error_to_string error
  | Approval_grant_unavailable error ->
    Keeper_approval_queue_result.grant_error_to_string error
  | Approval_grant_consumption_in_progress approval_id ->
    Printf.sprintf "approval %s is being consumed" approval_id
;;

let source_fields = function
  | One_shot_resolution approval_id ->
    [ "authorization_source", `String "one_shot_resolution"
    ; "approval_id", `String approval_id
    ]
  | Exact_always_rule rule_id ->
    [ "authorization_source", `String "exact_always_rule"
    ; "rule_id", `String rule_id
    ]
  | Keeper_always_allow ->
    [ "authorization_source", `String "keeper_always_allow" ]
  | Workspace_always_allow ->
    [ "authorization_source", `String "workspace_always_allow" ]
  | Readonly_sandbox ->
    [ "authorization_source", `String "readonly_sandbox" ]
  | Local_output ->
    [ "authorization_source", `String "local_output" ]
  | Observed_in_box { run; result = _ } ->
    [ "authorization_source", `String "observed_in_box"
    ; ( "observation_run"
      , `String (Keeper_types_profile_sandbox.observation_run_to_string run) )
    ]
;;

let audit_receipts_to_yojson receipts =
  `List (List.map Keeper_approval.Audit.receipt_to_yojson receipts)
;;

let authorization_subject_id = function
  | One_shot_resolution approval_id -> Some approval_id
  | Exact_always_rule rule_id -> Some rule_id
  | Keeper_always_allow
  | Workspace_always_allow
  | Readonly_sandbox
  | Local_output
  | Observed_in_box _ ->
    None
;;

let decision_to_yojson = function
  | Allow authorization ->
    `Assoc
      ([ "decision", `String "allow"
       ; "audit_receipts", audit_receipts_to_yojson authorization.audit_receipts
       ]
       @ source_fields authorization.source)
  | Deferred { operation; approval_id; reason; audit_receipts } ->
    let detail =
      match reason with
      | Mode_state_invalid detail -> [ "mode_read_error", `String detail ]
      | Auto_judge_unavailable detail ->
        [ "auto_judge_error", `String detail ]
      | Human_requested | Judge_requested -> []
    in
    (* RFC-0356 host replay, stated where the model reads it: without
       this line the payload reads as a plain block and the model
       resubmits the same call while the approval is in flight —
       measured as three duplicate approvals in #28866. The promise is
       made only for operations [replayable_operation] recognizes: over
       an unrecognized one it starves the approved effect silently
       (#32668), so those are told the truth — the one-shot
       authorization arrives on the next turn and the exact call spends
       it. *)
    let on_approve =
      match replayable_operation operation with
      | Some _ ->
        "The host replays this exact call and delivers its output to you \
         automatically. Do not resubmit it; a resubmission folds onto this \
         same approval."
      | None ->
        "The resolution reaches your next turn. If approved, a one-shot \
         authorization for this exact operation and input is delivered \
         there; re-issue the exact call to spend it. A different call while \
         this one is pending opens a new request."
    in
    `Assoc
      ([ "decision", `String "deferred"
       ; "approval_id", `String approval_id
       ; "reason", `String (deferred_reason_to_string reason)
       ; "on_approve", `String on_approve
       ; "audit_receipts", audit_receipts_to_yojson audit_receipts
       ]
       @ detail)
  | Unavailable reason ->
    `Assoc
      [ "decision", `String "unavailable"
      ; "reason", `String (unavailable_reason_to_string reason)
      ]
;;

let authorization_metadata ?producer_metadata authorization =
  let fields =
    [ "gate", decision_to_yojson (Allow authorization) ]
  in
  `Assoc
    (fields
     @ Option.fold
         ~none:[]
         ~some:(fun metadata -> [ "producer", metadata ])
         producer_metadata)
;;
