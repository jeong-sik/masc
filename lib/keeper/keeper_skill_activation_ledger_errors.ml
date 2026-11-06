open Keeper_skill_activation_types

type decode_error =
  | Expected_object of { field : string }
  | Missing_string of { field : string }
  | Missing_string_in_event_row of
      { field : string
      ; row_in_batch : int
      ; row_sha256 : string
      }
  | Duplicate_field of
      { object_name : string
      ; field : string
      }
  | Unexpected_field of
      { object_name : string
      ; field : string
      }
  | Unsupported_schema of string
  | Invalid_source_id of string
  | Invalid_skill_name of string
  | Invalid_package_id of Skill_reference.package_id_error
  | Invalid_content_revision of Skill_reference.revision_error
  | Invalid_snapshot_revision of Skill_catalog_snapshot.revision_error
  | Invalid_workspace_key of Skill_catalog_snapshot.revision_error
  | Invalid_session_id of string
  | Invalid_origin_kind of string
  | Invalid_task_id of string
  | Empty_task_ids
  | Duplicate_task_id of string
  | Invalid_tool_name of string
  | Invalid_composition_execution_id
  | Invalid_nested_composition_scope of string
  | Invalid_turn_ref of string
  | Turn_ref_session_mismatch
  | Invalid_runtime_id
  | Invalid_skill_tool_use_id
  | Invalid_agent_core_turn of int
  | Invalid_served_content_kind of string
  | Invalid_served_content_path of string
  | Invalid_served_content_bytes of int
  | Invalid_served_content_sha256 of Skill_reference.revision_error
  | Invalid_delivery_agent_core_turn of int
  | Invalid_delivery_boundary_kind of string
  | Invalid_delivery_time of string
  | Invalid_action_identity_field
  | Invalid_action_tool_name_field of string
  | Invalid_action_agent_core_turn of int
  | Invalid_action_time of string
  | Invalid_transition_rejection_kind of string
  | Orphan_transition_rejection of string
  | Transition_rejection_activation_mismatch of string
  | Duplicate_action_identity
  | Invalid_activated_at of string
  | Duplicate_skill_tool_use_id
  | Session_id_mismatch
  | Workspace_key_mismatch
  | Invalid_ledger_revision of Skill_catalog_snapshot.revision_error
  | Ledger_revision_mismatch
  | Invalid_event_kind of string
  | Blank_event_row
  | Activation_recorded_with_evidence of string
  | Unknown_event_activation of string
  | Delivery_already_observed of string
  | Action_target_not_delivered of string
  | Unterminated_header_row
  | Invalid_async_result_evidence of string
  | Invalid_async_action_evidence of string

type store_error =
  | Lock_failed of string
  | Canonical_root_failed of
      { path : string
      ; cause : Unix.error
      }
  | Read_failed of Fs_compat.owned_regular_file_read_error
  | Decode_failed of decode_error
  | Invocation_id_collision of string
  | Action_identity_collision of action_identity
  | Invalid_delivery_order of
      { skill_tool_use_id : string
      ; activation_turn : int
      ; delivery_turn : int
      }
  | Conflicting_delivery of string
  | Action_before_delivery of string
  | Invalid_action_identity
  | Invalid_action_tool_name of string
  | Invalid_action_turn of int
  | Invalid_action_observed_at of string
  | Event_log_failed of Fs_compat.private_jsonl_transaction_error

let decode_error_code = function
  | Expected_object _ -> "expected_object"
  | Missing_string _ | Missing_string_in_event_row _ -> "missing_string"
  | Duplicate_field _ -> "duplicate_field"
  | Unexpected_field _ -> "unexpected_field"
  | Unsupported_schema _ -> "unsupported_schema"
  | Invalid_source_id _ -> "invalid_source_id"
  | Invalid_skill_name _ -> "invalid_skill_name"
  | Invalid_package_id _ -> "invalid_package_id"
  | Invalid_content_revision _ -> "invalid_content_revision"
  | Invalid_snapshot_revision _ -> "invalid_snapshot_revision"
  | Invalid_workspace_key _ -> "invalid_workspace_key"
  | Invalid_session_id _ -> "invalid_session_id"
  | Invalid_origin_kind _ -> "invalid_origin_kind"
  | Invalid_task_id _ -> "invalid_task_id"
  | Empty_task_ids -> "empty_task_ids"
  | Duplicate_task_id _ -> "duplicate_task_id"
  | Invalid_tool_name _ -> "invalid_tool_name"
  | Invalid_composition_execution_id -> "invalid_composition_execution_id"
  | Invalid_nested_composition_scope _ -> "invalid_nested_composition_scope"
  | Invalid_turn_ref _ -> "invalid_turn_ref"
  | Turn_ref_session_mismatch -> "turn_ref_session_mismatch"
  | Invalid_runtime_id -> "invalid_runtime_id"
  | Invalid_skill_tool_use_id -> "invalid_skill_tool_use_id"
  | Invalid_agent_core_turn _ -> "invalid_agent_core_turn"
  | Invalid_served_content_kind _ -> "invalid_served_content_kind"
  | Invalid_served_content_path _ -> "invalid_served_content_path"
  | Invalid_served_content_bytes _ -> "invalid_served_content_bytes"
  | Invalid_served_content_sha256 _ -> "invalid_served_content_sha256"
  | Invalid_delivery_agent_core_turn _ -> "invalid_delivery_agent_core_turn"
  | Invalid_delivery_boundary_kind _ -> "invalid_delivery_boundary_kind"
  | Invalid_delivery_time _ -> "invalid_delivery_time"
  | Invalid_action_identity_field -> "invalid_action_identity"
  | Invalid_action_tool_name_field _ -> "invalid_action_tool_name"
  | Invalid_action_agent_core_turn _ -> "invalid_action_agent_core_turn"
  | Invalid_action_time _ -> "invalid_action_time"
  | Invalid_transition_rejection_kind _ -> "invalid_transition_rejection_kind"
  | Orphan_transition_rejection _ -> "orphan_transition_rejection"
  | Transition_rejection_activation_mismatch _ ->
    "transition_rejection_activation_mismatch"
  | Duplicate_action_identity -> "duplicate_action_identity"
  | Invalid_activated_at _ -> "invalid_activated_at"
  | Duplicate_skill_tool_use_id -> "duplicate_skill_tool_use_id"
  | Session_id_mismatch -> "session_id_mismatch"
  | Workspace_key_mismatch -> "workspace_key_mismatch"
  | Invalid_ledger_revision _ -> "invalid_ledger_revision"
  | Ledger_revision_mismatch -> "ledger_revision_mismatch"
  | Invalid_event_kind _ -> "invalid_event_kind"
  | Blank_event_row -> "blank_event_row"
  | Activation_recorded_with_evidence _ -> "activation_recorded_with_evidence"
  | Unknown_event_activation _ -> "unknown_event_activation"
  | Delivery_already_observed _ -> "delivery_already_observed"
  | Action_target_not_delivered _ -> "action_target_not_delivered"
  | Unterminated_header_row -> "unterminated_header_row"
  | Invalid_async_result_evidence _ -> "invalid_async_result_evidence"
  | Invalid_async_action_evidence _ -> "invalid_async_action_evidence"
;;

let store_error_code = function
  | Lock_failed _ -> "lock_failed"
  | Canonical_root_failed _ -> "canonical_root_failed"
  | Read_failed _ -> "read_failed"
  | Decode_failed error -> "decode_failed." ^ decode_error_code error
  | Invocation_id_collision _ -> "invocation_id_collision"
  | Action_identity_collision _ -> "action_identity_collision"
  | Invalid_delivery_order _ -> "invalid_delivery_order"
  | Conflicting_delivery _ -> "conflicting_delivery"
  | Action_before_delivery _ -> "action_before_delivery"
  | Invalid_action_identity -> "invalid_action_identity"
  | Invalid_action_tool_name _ -> "invalid_action_tool_name"
  | Invalid_action_turn _ -> "invalid_action_turn"
  | Invalid_action_observed_at _ -> "invalid_action_observed_at"
  | Event_log_failed _ -> "event_log_failed"
;;

let store_error_to_string = function
  | Lock_failed detail -> "lock failed: " ^ detail
  | Canonical_root_failed { path; cause } ->
    Printf.sprintf
      "canonical trace root failed for %s: %s"
      path
      (Unix.error_message cause)
  | Read_failed error ->
    "read failed: " ^ Fs_compat.owned_regular_file_read_error_to_string error
  (* Keep the category in the human string too: a write reads the session's
     rows before it appends, so one undecodable row fails every later write
     for the session — the code is what identifies the poison row's shape. *)
  | Decode_failed (Missing_string { field }) ->
    Printf.sprintf "decode failed: missing_string field=%s" field
  | Decode_failed (Missing_string_in_event_row { field; row_in_batch; row_sha256 }) ->
    Printf.sprintf
      "decode failed: missing_string field=%s event_row_in_batch=%d row_sha256=%s"
      field row_in_batch row_sha256
  | Decode_failed
      ((Expected_object _
        | Duplicate_field _
        | Unexpected_field _
        | Unsupported_schema _
        | Invalid_source_id _
        | Invalid_skill_name _
        | Invalid_package_id _
        | Invalid_content_revision _
        | Invalid_snapshot_revision _
        | Invalid_workspace_key _
        | Invalid_session_id _
        | Invalid_origin_kind _
        | Invalid_task_id _
        | Empty_task_ids
        | Duplicate_task_id _
        | Invalid_tool_name _
        | Invalid_composition_execution_id
        | Invalid_nested_composition_scope _
        | Invalid_turn_ref _
        | Turn_ref_session_mismatch
        | Invalid_runtime_id
        | Invalid_skill_tool_use_id
        | Invalid_agent_core_turn _
        | Invalid_served_content_kind _
        | Invalid_served_content_path _
        | Invalid_served_content_bytes _
        | Invalid_served_content_sha256 _
        | Invalid_delivery_agent_core_turn _
        | Invalid_delivery_boundary_kind _
        | Invalid_delivery_time _
        | Invalid_action_identity_field
        | Invalid_action_tool_name_field _
        | Invalid_action_agent_core_turn _
        | Invalid_action_time _
        | Invalid_transition_rejection_kind _
        | Orphan_transition_rejection _
        | Transition_rejection_activation_mismatch _
        | Duplicate_action_identity
        | Invalid_activated_at _
        | Duplicate_skill_tool_use_id
        | Session_id_mismatch
        | Workspace_key_mismatch
        | Invalid_ledger_revision _
        | Ledger_revision_mismatch
        | Invalid_event_kind _
        | Blank_event_row
        | Activation_recorded_with_evidence _
        | Unknown_event_activation _
        | Delivery_already_observed _
        | Action_target_not_delivered _
        | Unterminated_header_row
        | Invalid_async_result_evidence _
        | Invalid_async_action_evidence _) as error) ->
    "decode failed: " ^ decode_error_code error
  | Invocation_id_collision tool_use_id ->
    "Skill invocation id collision: " ^ tool_use_id
  | Action_identity_collision _ -> "Skill action identity collision"
  | Invalid_delivery_order { skill_tool_use_id; activation_turn; delivery_turn } ->
    Printf.sprintf
      "Skill delivery precedes its activation: id=%s activation_turn=%d delivery_turn=%d"
      skill_tool_use_id
      activation_turn
      delivery_turn
  | Conflicting_delivery tool_use_id ->
    "Skill delivery observation conflicts with its durable receipt: " ^ tool_use_id
  | Action_before_delivery tool_use_id ->
    "Skill action was observed before body delivery: " ^ tool_use_id
  | Invalid_action_identity -> "Skill action identity is invalid"
  | Invalid_action_tool_name tool_name ->
    "Skill action tool name is invalid: " ^ tool_name
  | Invalid_action_turn turn ->
    Printf.sprintf "Skill action Agent Core turn is invalid: %d" turn
  | Invalid_action_observed_at value ->
    "Skill action observation time is invalid: " ^ value
  | Event_log_failed error ->
    "event log failed: " ^ Fs_compat.private_jsonl_transaction_error_to_string error
;;
