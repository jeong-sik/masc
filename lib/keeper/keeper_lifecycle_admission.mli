(** Pure lifecycle admission for keeper execution boundaries.

    The persisted [paused] bit remains the pause authority.  A typed
    [Dead_tombstone] latch refines that state into a terminal lifecycle state.
    [Transcript_corruption_reset_required] refines it into a pause that generic
    resume cannot clear. Both remain fail-closed even if a racing/stale writer
    cleared [paused]. Missing latch detail while [paused = true] is fail-closed
    as an unclassified pause. *)

type paused_latch = private
  | Classified of Keeper_latched_reason.t
  | Unclassified

type state = private
  | Active
  | Paused of paused_latch
  | Dead_tombstone

val state :
  paused:bool ->
  latched_reason:Keeper_latched_reason.t option ->
  state

type manual_one_shot_admission =
  | Manual_admitted_active
  | Manual_admitted_paused_recovery of paused_latch
  | Manual_denied_dead_tombstone
  | Manual_denied_transcript_reset_required

val admit_manual_one_shot : state -> manual_one_shot_admission

type autonomous_denial =
  | Autonomous_paused of paused_latch
  | Autonomous_dead_tombstone

type autonomous_admission =
  | Autonomous_admitted
  | Autonomous_denied of autonomous_denial

val admit_autonomous : state -> autonomous_admission

(** Stable boundary projections.  Execution decisions must pattern-match on
    the typed values above rather than compare these strings. *)
val paused_latch_to_wire : paused_latch -> string
val state_to_wire : state -> string
val autonomous_denial_to_wire : autonomous_denial -> string

module Durable_transaction : sig
  type stage = Keeper_lifecycle_admission_durable_transaction.stage =
    | Reserved
    | Durable_committed
    | Launch_committed
    | Rollback_reserved
    | Rollback_durable_committed
    | Forward_cleanup_pending
    | Rollback_cleanup_pending_from_reserved
    | Rollback_cleanup_pending_from_durable_committed
    | Cleared

  type evidence = Keeper_lifecycle_admission_durable_transaction.evidence =
    { keeper_name : string
    ; transaction_id : string
    ; stage : stage
    }

  type authority_failure =
    Keeper_lifecycle_admission_durable_transaction.authority_failure =
    | Authority_path_unavailable
    | Filesystem_capability_unavailable
    | Entropy_unavailable
    | Durable_lock_unavailable
    | Durable_lock_release_failed
    | Authority_read_failed
    | Authority_read_settlement_failed
    | Invalid_current_schema

  type blocked_reason =
    Keeper_lifecycle_admission_durable_transaction.blocked_reason =
    | Authority_unreadable of
        { keeper_name : string
        ; failure : authority_failure
        }
    | Authority_invalid of
        { keeper_name : string
        ; failure : authority_failure
        }
      | Rollback_capable_authority of evidence
      | Forward_cleanup_authority of evidence
      | Revival_transaction_mismatch of
        { keeper_name : string
        ; observed : evidence option
        }

  type permit = Keeper_lifecycle_admission_durable_transaction.permit

  type decision = Keeper_lifecycle_admission_durable_transaction.decision =
    | Admitted of evidence option
    | Blocked of blocked_reason

  type projection = Keeper_lifecycle_admission_durable_transaction.projection =
    { keeper_name : string
    ; decision : decision
    }

  type 'a admission_result =
    'a Keeper_lifecycle_admission_durable_transaction.admission_result =
    | Admission_completed of 'a
    | Admission_completed_with_attention of 'a * authority_failure
    | Admission_blocked of blocked_reason

  type 'a permit_lease_result =
    'a Keeper_lifecycle_admission_durable_transaction.permit_lease_result =
    | Permit_lease_completed of 'a
    | Permit_lease_denied

  val with_permit_lease :
    permit ->
    base_path:string ->
    string ->
    (unit -> 'a) ->
    'a permit_lease_result
  (** Execute one permit-authorized operation under a counted lease. The
      enclosing durable admission cannot release its authority lock until the
      operation returns, raises, or is cancelled and the lease is released. *)

  val with_durable_lifecycle_admission :
    Workspace.config ->
    keeper_name:string ->
    (permit -> 'a) ->
    'a admission_result
  (** The point read and callback execute under the same per-Keeper durable
      authority lock used by revival and recovery. *)

  val inspect : Workspace.config -> keeper_name:string -> projection
  (** Backend-safe projection containing no journal payload or credential data. *)

  val stage_to_wire : stage -> string
  val authority_failure_to_wire : authority_failure -> string
  val blocked_reason_to_wire : blocked_reason -> string
  val blocked_reason_to_yojson : blocked_reason -> Yojson.Safe.t
  val projection_to_yojson : projection -> Yojson.Safe.t

  module For_testing : sig
    val permit_matches : permit -> base_path:string -> string -> bool
  end
end
