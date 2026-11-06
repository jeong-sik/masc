(** Why a ledger cannot be decoded, and why its store cannot be read or
    changed.

    [decode_error] names why the JSON form of a ledger, an activation or an
    event row cannot be read. [store_error] names why a session's ledger
    cannot be read or changed, and wraps a [decode_error] as [Decode_failed].
    [decode_error_code] and [store_error_code] give the code of each error, and
    [store_error_to_string] renders a store error as text.
    [Keeper_skill_activation_ledger] includes this module. *)

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

val decode_error_code : decode_error -> string

val store_error_code : store_error -> string

val store_error_to_string : store_error -> string
