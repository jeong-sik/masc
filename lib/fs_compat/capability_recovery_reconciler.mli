(** Portable startup reconciliation for capability-publication obligations.

    This module inventories only the exact records supplied by
    {!Capability_recovery_obligation.inventory}. For each valid Prepared or
    Bound source it reacquires the persisted allowed-root path below the
    caller-provided filesystem capability, validates every opened directory
    against a no-follow observation, and inspects only the exact derived stage
    and target leaves. It never scans a target tree and never renames, unlinks,
    removes, or republishes a target-tree entry. The only durable mutations it
    can request are typed source-record transitions to [forensic]. *)

module Core = Capability_recovery_obligation

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

(** Raised only as the reason inside [Eio.Cancel.Cancelled]. The original
    cancellation stays primary; completed rows and all Core/scope cleanup
    failures remain typed evidence. *)
exception Reconciliation_cancelled of cancellation

type record_scope_callback_and_release_failure =
  { callback : Eio.Exn.with_bt
  ; release : cleanup_failure
  }

(** An unexpected callback exception and the exact resource-release failure
    occurred at the same record scope. Neither is relabelled as observation
    I/O. *)
exception Record_scope_callback_and_release_failed of
  record_scope_callback_and_release_failure

type report

val reconcile_owner
  :  fs:Eio.Fs.dir_ty Eio.Path.t
  -> registry:Core.registry
  -> owner:Core.owner
  -> report

val report_owner : report -> string
val report_rows : report -> row list

(** [true] exactly when every source record was transitioned to forensic (or
    was already forensic), the exact owner lane has no residue, every fixed
    area was inventoried, and no invalid, corrupt, raced, or failed row
    remains. *)
val report_is_ready : report -> bool

val report_to_string : report -> string

(** Constructor-directed structured evidence. No diagnostic string is parsed
    to produce this projection. Corrupt raw records remain only in their
    forensic-file SSOT; the projection exposes byte count and SHA-256 identity.
    Exception diagnostics, backtraces, transition effects, and cleanup
    failures stay explicit. *)
val report_to_yojson : report -> Yojson.Safe.t

module For_testing : sig
  type resource_scope_callback =
    | Return_completed_rows of string list
    | Cancel_callback of exn

  type resource_scope_evidence =
    | Returned_rows of
        { completed_rows : string list
        ; release_failure : exn option
        }
    | Cancelled_callback of
        { reason : exn
        ; release_failure : exn option
        }
    | Raised_callback of
        { exception_ : exn
        ; release_failure : exn option
        }

  (** Runs the real private resource-scope boundary. The optional failure is
      raised by a real [Switch.on_release] hook after the callback outcome has
      been captured. *)
  val run_resource_scope
    :  callback:resource_scope_callback
    -> release_failure:exn option
    -> resource_scope_evidence
end
