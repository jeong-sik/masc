open Keeper_approval_queue_rules_types

type storage_error =
  { path : string
  ; reason : string
  }

type summary_transition_rejection =
  | Summary_exact_attempt_bound of exact_attempt_binding

type summary_transition_error =
  | Summary_transition_storage_error of storage_error
  | Summary_transition_rejected of summary_transition_rejection

type summary_owner_retirement_error =
  | Summary_owner_retirement_storage_error of storage_error
  | Summary_owner_retirement_exact_attempt_unsettled of exact_attempt_binding

type exact_attempt_rejection =
  | Exact_attempt_not_found of string
  | Exact_attempt_key_mismatch of
      { approval_id : string
      ; input_hash : string
      ; sequence : int
      }
  | Exact_attempt_invalid_identity of string
  | Exact_attempt_summary_not_pending of string
  | Exact_attempt_unbound_state of string
  | Exact_attempt_disposition_conflict of
      { approval_id : string
      ; disposition : summary_attempt_disposition
      }
  | Exact_attempt_identity_conflict of exact_attempt_binding
  | Exact_attempt_status_conflict of exact_attempt_binding
  | Exact_attempt_provenance_mismatch of
      { approval_id : string
      ; expected_call_id : string
      ; actual_model_run_id : string
      }
  | Exact_attempt_content_conflict of string

type exact_attempt_error =
  | Exact_attempt_storage_error of storage_error
  | Exact_attempt_rejected of exact_attempt_rejection

type exact_write_outcome =
  Keeper_event_queue_persistence.exact_write_outcome =
  | Fsync_completed
  | Visible_sync_unconfirmed of string

type exact_attempt_transition =
  { changed : bool
  ; write_outcome : exact_write_outcome
  }

type approved_resolution_request =
  { keeper_name : string
  ; tool_name : string
  ; input : Yojson.Safe.t
  }

type grant_error =
  | Grant_store_unavailable of storage_error
  | Grant_replay_projection_unavailable of storage_error
  | Grant_workspace_mismatch of
      { approval_id : string
      ; requested_base_path : string
      ; stored_base_path : string
      }
  | Grant_still_pending of string
  | Grant_resolution_not_approved of string
  | Grant_resolution_missing of string
  | Grant_replay_not_consumed of string
  | Grant_replay_outcome_conflict of string

type resolution_absence =
  | Resolution_missing
  | Resolution_still_pending
  | Resolution_not_approved
  | Resolution_workspace_mismatch of { stored_base_path : string }

type approved_resolution_state =
  | Resolution_unconsumed
  | Resolution_consumed

type resolution_replay_outcome =
  | Replay_applied of Tool_output.artifact_ref
  | Replay_applied_with_warning of Tool_output.artifact_ref
  | Replay_failed of Tool_output.artifact_ref
  | Replay_indeterminate of Tool_output.artifact_ref

type approved_resolution_delivery =
  { request : approved_resolution_request
  ; state : approved_resolution_state
  ; replay_outcome : resolution_replay_outcome option
  }

type grant_consumption =
  | Consumption_committed of Keeper_approval.Audit.receipt
  | Consumption_already_committed
  | Consumption_not_matching

type pending_submission_disposition =
  | Pending_created of Keeper_approval.Audit.receipt
  | Pending_deduplicated
  | Folded_onto_unconsumed_grant

type pending_submission =
  { approval_id : string
  ; disposition : pending_submission_disposition
  }

type replay_recording =
  | Replay_recorded
  | Replay_already_recorded

type delivery_replay_failure =
  { approval_id : string
  ; reason : string
  }

type install_report =
  { loaded_pending : int
  ; replayed_deliveries : int
  ; delivery_replay_failures : delivery_replay_failure list
  ; replay_projection_error : storage_error option
  ; retired_deliveries : int
  ; delivery_retirement_error : storage_error option
  }

type install_error = Install_storage_failed of storage_error

type resolution_result =
  { remembered_rule : approval_rule option
  ; audit_receipts : Keeper_approval.Audit.receipt list
  }

let storage_error_to_string error =
  Printf.sprintf "%s: %s" error.path error.reason
;;

let approval_queue_unavailable_title =
  "Gate durable queue unavailable · runtime reset required"
;;

let approval_queue_unavailable_severity = "bad"
let approval_queue_unavailable_icon = "!"
let approval_queue_ready_state_json = `Assoc [ "state", `String "ready" ]

let summary_attempt_start_reserved_operator_detail =
  "Auto Judge worker start is durably reserved before exact attempt binding."
;;

let approval_queue_unavailable_state_json error =
  `Assoc
    [ "state", `String "unavailable"
    ; "code", `String "reset_required"
    ; "title", `String approval_queue_unavailable_title
    ; "operator_detail", `String (storage_error_to_string error)
    ; "severity", `String approval_queue_unavailable_severity
    ; "icon", `String approval_queue_unavailable_icon
    ]
;;

let exact_attempt_binding_to_string binding =
  let status =
    match binding.status with
    | Exact_quarantined cause ->
      Printf.sprintf
        "quarantined:%s"
        (exact_attempt_quarantine_cause_to_string cause)
    | Exact_dispatch_uncertain
    | Exact_released_before_dispatch
    | Exact_released_recovery_required
    | Exact_restart_quarantined
    | Exact_completed ->
      exact_attempt_status_to_string binding.status
  in
  Printf.sprintf
    "approval=%s input_hash=%s sequence=%d slot=%s call=%s plan=%s request=%s status=%s"
    binding.approval_id
    binding.input_hash
    binding.sequence
    binding.slot_id
    binding.call_id
    binding.plan_fingerprint
    binding.request_body_sha256
    status
;;

let summary_transition_error_to_string = function
  | Summary_transition_storage_error error -> storage_error_to_string error
  | Summary_transition_rejected (Summary_exact_attempt_bound binding) ->
    "unbound summary transition rejected for exact attempt: "
    ^ exact_attempt_binding_to_string binding
;;

let summary_owner_retirement_error_to_string = function
  | Summary_owner_retirement_storage_error error ->
    storage_error_to_string error
  | Summary_owner_retirement_exact_attempt_unsettled binding ->
    Printf.sprintf
      "approval summary owner retirement blocked by unsettled exact attempt: approval=%s slot=%s call=%s"
      binding.approval_id
      binding.slot_id
      binding.call_id
;;

let exact_attempt_error_to_string = function
  | Exact_attempt_storage_error error -> storage_error_to_string error
  | Exact_attempt_rejected (Exact_attempt_not_found approval_id) ->
    Printf.sprintf "exact attempt approval %s was not found" approval_id
  | Exact_attempt_rejected
      (Exact_attempt_key_mismatch { approval_id; input_hash; sequence }) ->
    Printf.sprintf
      "exact attempt key mismatch approval=%s input_hash=%s sequence=%d"
      approval_id
      input_hash
      sequence
  | Exact_attempt_rejected (Exact_attempt_invalid_identity field) ->
    Printf.sprintf "exact attempt identity field %s is invalid" field
  | Exact_attempt_rejected (Exact_attempt_summary_not_pending approval_id) ->
    Printf.sprintf "exact attempt approval %s summary is not pending" approval_id
  | Exact_attempt_rejected (Exact_attempt_unbound_state approval_id) ->
    Printf.sprintf "exact attempt approval %s has no bound identity" approval_id
  | Exact_attempt_rejected
      (Exact_attempt_disposition_conflict { approval_id; disposition }) ->
    let disposition =
      match disposition with
      | Summary_attempt_ready -> "ready"
      | Summary_attempt_in_flight -> "in_flight"
      | Summary_attempt_identity_unbound -> "identity_unbound"
      | Summary_attempt_persistence_uncertain -> "persistence_uncertain"
      | Summary_attempt_pre_worker_unavailable blocked ->
        "pre_worker_unavailable:"
        ^ summary_attempt_pre_worker_unavailable_code_to_string
            blocked.reason_code
      | Summary_attempt_settled -> "settled"
    in
    Printf.sprintf
      "exact attempt approval %s rejects dispatch from disposition %s"
      approval_id
      disposition
  | Exact_attempt_rejected (Exact_attempt_identity_conflict binding) ->
    "exact attempt identity conflicts with durable binding: "
    ^ exact_attempt_binding_to_string binding
  | Exact_attempt_rejected (Exact_attempt_status_conflict binding) ->
    "exact attempt status rejects this transition: "
    ^ exact_attempt_binding_to_string binding
  | Exact_attempt_rejected
      (Exact_attempt_provenance_mismatch
        { approval_id; expected_call_id; actual_model_run_id }) ->
    Printf.sprintf
      "exact attempt approval %s summary provenance mismatch: expected call_id=%s, \
       actual model_run_id=%s"
      approval_id
      expected_call_id
      actual_model_run_id
  | Exact_attempt_rejected (Exact_attempt_content_conflict approval_id) ->
    Printf.sprintf
      "exact attempt approval %s already completed with different content"
      approval_id
;;

let grant_error_to_string = function
  | Grant_store_unavailable error -> storage_error_to_string error
  | Grant_replay_projection_unavailable error ->
    Printf.sprintf
      "derived replay projection unavailable: %s"
      (storage_error_to_string error)
  | Grant_workspace_mismatch
      { approval_id; requested_base_path; stored_base_path } ->
    Printf.sprintf
      "approval %s belongs to workspace %s, not %s"
      approval_id
      stored_base_path
      requested_base_path
  | Grant_still_pending approval_id ->
    Printf.sprintf "approval %s has not been resolved" approval_id
  | Grant_resolution_not_approved approval_id ->
    Printf.sprintf "approval %s was not approved" approval_id
  | Grant_resolution_missing approval_id ->
    Printf.sprintf "approval %s has no durable resolution journal" approval_id
  | Grant_replay_not_consumed approval_id ->
    Printf.sprintf
      "approval %s cannot record a replay outcome before its grant is consumed"
      approval_id
  | Grant_replay_outcome_conflict approval_id ->
    Printf.sprintf
      "approval %s already has a different durable replay outcome"
      approval_id
;;

let resolution_absence_of_grant_error = function
  | Grant_resolution_missing _ -> Some Resolution_missing
  | Grant_still_pending _ -> Some Resolution_still_pending
  | Grant_resolution_not_approved _ -> Some Resolution_not_approved
  | Grant_workspace_mismatch { stored_base_path; _ } ->
    Some (Resolution_workspace_mismatch { stored_base_path })
  | Grant_store_unavailable _
  | Grant_replay_projection_unavailable _
  | Grant_replay_not_consumed _
  | Grant_replay_outcome_conflict _ -> None
;;

let resolution_absence_to_string = function
  | Resolution_missing -> "resolution_missing"
  | Resolution_still_pending -> "resolution_still_pending"
  | Resolution_not_approved -> "resolution_not_approved"
  | Resolution_workspace_mismatch { stored_base_path } ->
    "resolution_workspace_mismatch:" ^ stored_base_path
;;

let install_error_to_string = function
  | Install_storage_failed error -> storage_error_to_string error
;;
