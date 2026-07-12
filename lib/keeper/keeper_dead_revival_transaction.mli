(** Crash-recoverable explicit revival of a durable [Dead_tombstone]. *)

type registry_conflict =
  | Registry_phase_conflict of Keeper_state_machine.phase
  | Registry_identity_conflict of
      { expected_trace_id : Keeper_id.Trace_id.t
      ; expected_generation : int
      ; actual_trace_id : Keeper_id.Trace_id.t
      ; actual_generation : int
      }
  | Registry_dead_lane_not_settled
  | Registry_remove_missing
  | Registry_remove_replaced

type rollback_error =
  | Rollback_meta_missing
  | Rollback_meta_identity_changed
  | Rollback_meta_payload_changed
  | Rollback_meta_write_failed of string
  | Rollback_registry_occupied of Keeper_registry.registry_entry
  | Rollback_registry_invalid of Keeper_registry.registry_entry_validation_error
  | Rollback_registry_reservation_changed of Keeper_lifecycle_reservation.snapshot
  | Rollback_journal_delete_failed of string

type error =
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Journal_write_failed of string
  | Durable_snapshot_missing
  | Durable_snapshot_changed
  | Registry_conflict of registry_conflict
  | Durable_commit_failed of string
  | Durable_commit_unreadable of string
  | Launch_failed of Keeper_keepalive.start_keepalive_outcome
  | Rollback_failed of
      { cause : string
      ; errors : rollback_error list
      }

type success =
  { meta : Keeper_meta_contract.keeper_meta
  ; entry : Keeper_registry.registry_entry
  ; journal_cleanup_pending : string option
  }

val error_to_string : error -> string

val revive :
  'a Keeper_types_profile.context ->
  original:Keeper_meta_contract.keeper_meta ->
  candidate:Keeper_meta_contract.keeper_meta ->
  (success, error) result

type recovery_summary =
  { recovered : int
  ; cleared : int
  ; unresolved : (string * string) list
  }

(** Roll back every durable revival journal before keeper autoboot or request
    mutation paths become available. A journal whose keeper identity changed
    is retained and reported as unresolved. *)
val recover_pending : Workspace.config -> recovery_summary
