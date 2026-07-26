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
  | Rollback_registry_reservation_changed of Keeper_lifecycle_reservation.snapshot
  | Rollback_registry_admission_denied
  | Rollback_payload_delete_failed of Keeper_dead_revival_payload.error
  | Rollback_journal_clear_failed of string
  | Rollback_runtime_assignment_failed of string

type payload_operation =
  | Payload_prepare
  | Payload_create
  | Payload_verify
  | Payload_delete

type error =
  | Reservation_conflict of Keeper_lifecycle_reservation.snapshot
  | Nonce_allocation_failed of Keeper_lifecycle_nonce.error
  | Journal_conflict of string
  | Journal_ownership_changed of string
  | Journal_publication_indeterminate of
      Fs_compat.Capability_head.failure
  | Journal_published_with_failure of
      Fs_compat.Capability_head.failure
  | Journal_published_with_warnings of
      { evidence : Fs_compat.Capability_head.publication_evidence
      ; warnings : Fs_compat.Capability_head.settlement_warning list
      }
  | Journal_read_settlement_failed of
      Fs_compat.Capability_head.settlement_warning list
  | Journal_write_failed of string
  | Runtime_assignment_failed of string
  | Payload_operation_failed of
      { operation : payload_operation
      ; failure : Keeper_dead_revival_payload.error
      }
  | Transaction_lock_failed of File_lock_eio.durable_lock_error
  | Post_commit_cleanup_required of
      { committed : Keeper_meta_contract.keeper_meta
      ; entry : Keeper_registry.registry_entry
      ; cleanup_error : error
      }
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
  }

val error_to_string : error -> string

exception Cancellation_recovery_failed of
  { original : exn
  ; recovery_errors : rollback_error list
  }

val revive :
  ?runtime_id:string ->
  'a Keeper_types_profile.context ->
  original:Keeper_meta_contract.keeper_meta ->
  candidate:Keeper_meta_contract.keeper_meta ->
  (success, error) result

type recovery_summary =
  { recovered : int
    (** Transactions whose candidate metadata had durably committed and was
        rolled back during recovery. *)
  ; cleared : int
    (** Transactions or orphan payloads cleared without rolling back a
        durably committed candidate. *)
  ; unresolved : (string * string) list
  }

(** Roll back every durable revival journal before keeper autoboot or request
    mutation paths become available. A journal whose keeper identity changed
    is retained and reported as unresolved. *)
val recover_pending : Workspace.config -> recovery_summary

module For_testing : sig
  val cancellation_with_runtime_recovery_failure :
    detail:string ->
    exn ->
    exn

  val with_boundary_hooks :
    ?after_nonce_allocation:(unit -> unit) ->
    ?after_journal_write:(unit -> unit) ->
    (unit -> 'a) ->
    'a

  val with_reserved_publication_failure :
    (unit -> 'a) ->
    'a

  val with_cleanup_boundary_hooks :
    ?after_cleanup_pending:
      ([ `Forward | `Rollback ] -> string option) ->
    ?after_payload_delete:
      ([ `Forward | `Rollback ] -> string option) ->
    (unit -> 'a) ->
    'a

  val with_final_clear_failure :
    detail:string ->
    (unit -> 'a) ->
    'a

  val with_recovery_claim_hook :
    before_recovery_claim:(unit -> unit) ->
    (unit -> 'a) ->
    'a

  val with_durable_publication_settlement_warning :
    (unit -> 'a) ->
    'a

  val with_launch_publication_settlement_warning :
    (unit -> 'a) ->
    'a

  val with_launch_publication_unchanged :
    (unit -> 'a) ->
    'a

  val with_launch_publication_indeterminate :
    (unit -> 'a) ->
    'a

  val with_launch_publication_reread_attention :
    detail:string ->
    (unit -> 'a) ->
    'a

  val with_after_launch_publication :
    after_launch_publication:(unit -> unit) ->
    (unit -> 'a) ->
    'a

  val with_fd_backed_parent_opening : (unit -> 'a) -> 'a

  val reserved_journal_row :
    owner_id:string ->
    original:Keeper_meta_contract.keeper_meta ->
    candidate:Keeper_meta_contract.keeper_meta ->
    string

  val current_journal_row :
    config:Workspace.config ->
    keeper_name:string ->
    (string option, error) result

  val current_journal_stage :
    config:Workspace.config ->
    keeper_name:string ->
    ( [ `Missing
      | `Reserved
      | `Durable_committed
      | `Launch_committed
      | `Rollback_reserved
      | `Rollback_durable_committed
      | `Forward_cleanup_pending
      | `Rollback_cleanup_pending
      | `Cleared
      ]
    , error )
    result

end
