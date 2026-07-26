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
  type stage =
    | Reserved
    | Durable_committed
    | Launch_committed
    | Rollback_reserved
    | Rollback_durable_committed
    | Forward_cleanup_pending
    | Rollback_cleanup_pending_from_reserved
    | Rollback_cleanup_pending_from_durable_committed
    | Cleared

  type evidence =
    { keeper_name : string
    ; transaction_id : string
    ; stage : stage
    }

  type authority_failure =
    | Authority_path_unavailable
    | Filesystem_capability_unavailable
    | Entropy_unavailable
    | Durable_lock_unavailable
    | Durable_lock_release_failed
    | Authority_read_failed
    | Authority_read_settlement_failed
    | Invalid_current_schema

  type blocked_reason =
    | Authority_unreadable of
        { keeper_name : string
        ; failure : authority_failure
        }
    | Authority_invalid of
        { keeper_name : string
        ; failure : authority_failure
        }
    | Rollback_capable_authority of evidence
    | Revival_transaction_mismatch of
        { keeper_name : string
        ; observed : evidence option
        }

  type permit

  type decision =
    | Admitted of evidence option
    | Blocked of blocked_reason

  type projection =
    { keeper_name : string
    ; decision : decision
    }

  type 'a admission_result =
    | Admission_completed of 'a
    | Admission_completed_with_attention of 'a * authority_failure
    | Admission_blocked of blocked_reason

  val permit_matches : permit -> string -> bool

  val with_durable_lifecycle_admission :
    Workspace.config ->
    keeper_name:string ->
    (permit -> 'a) ->
    'a admission_result
  (** The point read and callback execute under the same per-Keeper durable
      authority lock used by revival and recovery. *)

  val with_revival_launch_admission_under_lock :
    Workspace.config ->
    keeper_name:string ->
    owner_id:string ->
    (permit -> 'a) ->
    ('a, blocked_reason) result
  (** Admit only the exact active [Durable_committed] row owned by the supplied
      lifecycle reservation. The caller already holds the durable authority
      lock continuously through launch. *)

  val inspect : Workspace.config -> keeper_name:string -> projection
  (** Backend-safe projection containing no journal payload or credential data. *)

  val stage_to_wire : stage -> string
  val authority_failure_to_wire : authority_failure -> string
  val blocked_reason_to_wire : blocked_reason -> string
  val blocked_reason_to_yojson : blocked_reason -> Yojson.Safe.t
  val projection_to_yojson : projection -> Yojson.Safe.t

  module For_testing : sig
    val replace_current_row :
      config:Workspace.config ->
      keeper_name:string ->
      row:string ->
      (unit, string) result
  end
end
