(** Pure durable state machine for one Keeper event queue owner.

    [event-queue.json] is the sole authority for pending stimuli, active
    leases, monotonic lease identity, and settlement projection work.  This
    module performs no I/O; persistence supplies the atomic file boundary and
    publishes [pending] into the live registry only after a durable commit. *)

type lease_kind =
  | Single
  | Board_batch
  | Legacy_inflight

type requeue_reason =
  | Cycle_busy
  | Turn_not_scheduled
  | Retry_after_pacing
  | Rotate_now
  | Cancelled
  | Cycle_crashed
  | Registration_recovery

type escalation_reason =
  | Failure_judgment_requested
  | Failure_judgment_failed

type settlement =
  | Ack
  | Requeue of requeue_reason
  | Escalate of
      { reason : escalation_reason
      ; successor : Keeper_event_queue.stimulus option
      }

type lease =
  { lease_id : string
  ; sequence : int64
  ; kind : lease_kind
  ; claimed_at : float option
  ; stimuli : Keeper_event_queue.stimulus list
  }

type transition_receipt =
  { transition_id : string
  ; event_id : string
  ; lease_id : string
  ; lease_sequence : int64
  ; settled_at : float
  ; settlement : settlement
  }

type outbox_entry =
  { receipt : transition_receipt
  ; stimuli : Keeper_event_queue.stimulus list
  ; projected_to_reaction_ledger : bool
  }

type t

type settle_result =
  | Settled of transition_receipt
  | Already_settled of transition_receipt

val empty : t
val revision : t -> int64
val next_lease_sequence : t -> int64
val pending : t -> Keeper_event_queue.t
val leases : t -> lease list
val transition_outbox : t -> outbox_entry list
val lease_kind : lease -> lease_kind

val with_pending : Keeper_event_queue.t -> t -> t
val with_revision : int64 -> t -> t

val claim_when :
  claimed_at:float ->
  ready:(Keeper_event_queue.stimulus -> bool) ->
  t ->
  (t * lease option, string) result
(** Lease the pending head when [ready] accepts it.  A successful claim removes
    the stimuli from [pending] and advances the monotonic lease sequence in the
    same returned state. *)

val claim_board : claimed_at:float -> t -> (t * lease option, string) result
(** Lease every pending board stimulus as one ordered digest. *)

val add_legacy_inflight :
  Keeper_event_queue.stimulus list -> t -> (t * lease option, string) result
(** Migration/test compatibility boundary.  Adds one lease for legacy
    [event-queue-inflight.json] rows and removes matching pending identities. *)

val settle :
  settled_at:float ->
  lease:lease ->
  settlement:settlement ->
  t ->
  (t * settle_result, string) result
(** Atomically project one lease disposition into pure state.  Repeating the
    same semantic settlement returns [Already_settled]; a different settlement
    for an already-settled lease is an explicit conflict. *)

val recover_leases : settled_at:float -> t -> (t, string) result
(** Requeue every active lease with [Registration_recovery], preserving claim
    and stimulus order and emitting stable transition receipts. *)

val active_lease : t -> lease option
(** Oldest unsettled lease, if any.  A restarted lane resumes this lease before
    claiming new pending work. *)

val mark_transition_projected : transition_id:string -> t -> (t, string) result
(** Idempotently mark a durable outbox entry after an external projector has
    materialized its stable [event_id].  Unknown transition ids fail closed. *)

val remove_by_post_id :
  Keeper_event_queue.post_id -> t -> Keeper_event_queue.stimulus list * t

val release_legacy_inflight :
  Keeper_event_queue.stimulus list -> t -> t
(** Compatibility-only projection for the retired split-file API.  Removes
    matching identities from active leases while leaving pending untouched.
    New runtime code must settle the opaque lease instead. *)

val lease_to_yojson : lease -> Yojson.Safe.t
val lease_of_yojson : Yojson.Safe.t -> (lease, string) result
val to_yojson : t -> Yojson.Safe.t
val of_yojson : Yojson.Safe.t -> (t, string) result

val schema : string
(** ["keeper.event_queue.state.v2"]. *)
