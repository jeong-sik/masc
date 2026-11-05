(** Vocabulary of a publication recovery reconciliation: what was observed,
    how each prepared or bound record ended, the rows of a report, the
    cancellation value, and the report with its accessors and readiness
    predicates.

    This module is private to [fs_compat_internal] and has no interface file.
    [Capability_recovery_reconciler] includes it. *)

module Core = Capability_recovery_obligation
module Resource_scope = Eio_resource_scope

type identity =
  { device : int64
  ; inode : int64
  }

type entry_observation =
  | Entry_absent
  | Entry_present of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type resource_mismatch =
  { expected : identity
  ; observed : entry_observation
  }

type prepared_outcome =
  | Prepared_unmaterialized
  | Prepared_allowed_root_mismatch of resource_mismatch
  | Prepared_parent_mismatch of resource_mismatch
  | Prepared_unbound_stage_preserved of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      }

type bound_outcome =
  | Bound_stage_absent of { observed_target : entry_observation }
  | Bound_allowed_root_mismatch of resource_mismatch
  | Bound_parent_mismatch of resource_mismatch
  | Bound_stage_mismatch of
      { mismatch : resource_mismatch
      ; observed_target : entry_observation
      }
  | Bound_stage_preserved of
      { kind : Eio.File.Stat.kind
      ; identity : identity
      ; observed_target : entry_observation
      }

type record_area =
  | Active
  | Owned
  | Forensic

type source_state =
  | Prepared
  | Bound

type release_scope =
  | Owner_store_scope
  | Record_scope of
      { source_state : source_state
      ; operation_id : string
      }

type cleanup_failure =
  | Core_cleanup_failure of Core.failure
  | Scope_release_failure of
      { scope : release_scope
      ; exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }

type observation_subject =
  | Allowed_root of string
  | Parent_component of
      { index : int
      ; component : string
      }
  | Stage_leaf of string
  | Target_leaf of string

type observation_cause =
  | Observation_io_failed of
      { exception_ : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Observation_identity_invalid of Core.validation_error
  | Opened_resource_kind_changed of
      { observed : Eio.File.Stat.kind
      ; opened : Eio.File.Stat.kind
      }
  | Opened_resource_identity_changed of
      { observed : identity
      ; opened : identity
      }

type observation_failure =
  { subject : observation_subject
  ; cause : observation_cause
  }

type digest_evidence =
  { canonical_json_byte_count : int
  ; canonical_json_sha256 : string
  }

type corrupt_validation_error_kind =
  | Corrupt_invalid_owner
  | Corrupt_invalid_operation_id
  | Corrupt_invalid_identity
  | Corrupt_invalid_allowed_root_path
  | Corrupt_empty_parent_path_identity_mismatch
  | Corrupt_invalid_parent_component
  | Corrupt_invalid_target_leaf
  | Corrupt_invalid_permissions
  | Corrupt_invalid_record_json
  | Corrupt_invalid_record_shape
  | Corrupt_unsupported_record_version
  | Corrupt_record_state_mismatch
  | Corrupt_record_owner_mismatch
  | Corrupt_record_operation_id_mismatch
  | Corrupt_record_stage_leaf_mismatch
  | Corrupt_record_identity_mismatch
  | Corrupt_record_kind_mismatch
  | Corrupt_record_permissions_mismatch
  | Corrupt_record_outcome_observation_not_mismatch
  | Corrupt_record_field_invalid

type corrupt_validation_error =
  { kind : corrupt_validation_error_kind
  ; payload : digest_evidence option
  }

type row =
  | Unexpected_lane_entry of
      { name : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_lane_entry of { name : string }
  | Lane_entry_unavailable of
      { name : string
      ; error : Core.transition_error
      }
  | Area_inventory_unavailable of
      { area : record_area
      ; error : Core.transition_error
      }
  | Source_transition_capabilities_unavailable of
      { source_state : source_state
      ; operation_id : string
      ; area_failures : (record_area * Core.transition_error) list
      }
  | Prepared_reconciled of
      { operation_id : string
      ; outcome : prepared_outcome
      }
  | Bound_reconciled of
      { operation_id : string
      ; outcome : bound_outcome
      }
  | Existing_forensic_record of
      { operation_id : string
      ; source_state : source_state
      }
  | Conflicting_source_records of
      { operation_id : string
      ; areas : record_area list
      }
  | Invalid_record_name of
      { area : record_area
      ; name : string
      }
  | Unexpected_record_kind of
      { area : record_area
      ; operation_id : string
      ; kind : Eio.File.Stat.kind
      }
  | Missing_record_entry of
      { area : record_area
      ; operation_id : string
      }
  | Record_entry_unavailable of
      { area : record_area
      ; operation_id : string
      ; error : Core.transition_error
      }
  | Corrupt_record_preserved of
      { area : record_area
      ; operation_id : string
      ; raw_byte_count : int
      ; raw_sha256 : string
      ; validation_error : corrupt_validation_error
      }
  | Record_observation_failed of
      { source_state : source_state
      ; operation_id : string
      ; failure : observation_failure
      }
  | Record_transition_failed of
      { source_state : source_state
      ; operation_id : string
      ; error : Core.transition_error
      }
  | Record_scope_release_failed of
      { source_state : source_state
      ; operation_id : string
      ; failure : cleanup_failure
      }
  | Owner_store_release_failed of cleanup_failure
  | Owner_store_unavailable of Core.transition_error
  | Owner_inventory_unavailable of Core.transition_error

type cancellation =
  { original_reason : exn
  ; original_backtrace : Printexc.raw_backtrace
  ; owner : string
  ; completed_rows : row list
  ; interrupted_store_effect : Core.transition_effect
  ; cleanup_failures : cleanup_failure list
  }

exception Reconciliation_cancelled of cancellation
exception Internal_resource_scope_callback_not_entered

type report =
  { owner : string
  ; rows : row list
  }

let identity_of_core identity =
  { device = Core.identity_dev identity; inode = Core.identity_ino identity }
;;

let report_owner report = report.owner
let report_rows report = report.rows

let row_is_ready = function
  | Prepared_reconciled _
  | Bound_reconciled _
  | Existing_forensic_record _ -> true
  | Unexpected_lane_entry _
  | Missing_lane_entry _
  | Lane_entry_unavailable _
  | Area_inventory_unavailable _
  | Source_transition_capabilities_unavailable _
  | Conflicting_source_records _
  | Invalid_record_name _
  | Unexpected_record_kind _
  | Missing_record_entry _
  | Record_entry_unavailable _
  | Corrupt_record_preserved _
  | Record_observation_failed _
  | Record_transition_failed _
  | Record_scope_release_failed _
  | Owner_store_release_failed _
  | Owner_store_unavailable _
  | Owner_inventory_unavailable _ -> false
;;

let report_is_ready report = List.for_all row_is_ready report.rows
