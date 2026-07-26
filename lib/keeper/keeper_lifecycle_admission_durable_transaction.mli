(** Sealed durable lifecycle admission authority implementation. *)

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

type 'a permit_lease_result =
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

val with_recovery_lifecycle_admission :
  Workspace.config ->
  keeper_name:string ->
  transaction_id:string ->
  (permit -> 'a) ->
  'a admission_result
(** Acquire the ordinary per-Keeper durable authority lock, then admit only
    the exact current-schema journal transaction discovered by recovery. *)

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
  val permit_matches : permit -> base_path:string -> string -> bool

  val replace_current_row :
    config:Workspace.config ->
    keeper_name:string ->
    row:string ->
    (unit, string) result
end
