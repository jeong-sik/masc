(** How a candidate's durable quarantine relates to the partition row of the
    same candidate.

    Two readers act on this pair: process-start reconciliation in
    [Keeper_board_attention_worker] and the operator requeue command in
    [Keeper_board_attention_quarantine_command]. Both match on this one
    classification, so a pair either reader accepts is accepted by the other
    and a pair one of them treats as inconsistent is inconsistent for both. *)

type inconsistency =
  | Ready_without_requeue_request
      (** The partition is [Ready] while the quarantine has no requeue
          request. *)
  | Ready_before_requeue_recorded
      (** The partition is [Ready] while the operator's requeue request is not
          recorded as finished. *)
  | Ready_not_after_requeued_generation
      (** The quarantine is requeued, but the [Ready] partition is at or
          before the generation the quarantine names. *)

type t =
  | Blocked_awaiting_request
      (** [Blocked] at the quarantined generation; no requeue was asked. *)
  | Blocked_requeue_requested
      (** [Blocked] at the quarantined generation; the operator asked for a
          requeue that the candidate has not recorded as finished. *)
  | Blocked_requeued
      (** [Blocked] at the quarantined generation; the candidate recorded the
          requeue and the partition has not left [Blocked]. *)
  | Blocked_unrecorded
      (** [Blocked] at a partition or generation the quarantine does not
          name: a block the candidate has not recorded yet. *)
  | Ready_requeued
      (** [Ready] after the quarantined generation and the candidate recorded
          the requeue: a finished requeue, possibly followed by deferrals and
          restarts that each advanced the generation. *)
  | Advanced_requeued
      (** [Running], [Completed], [Settled] or [Abandoned] after a recorded
          requeue. *)
  | Advanced_without_requeue
      (** [Running], [Completed], [Settled] or [Abandoned] while the
          quarantine has no finished requeue. *)
  | Other_partition
      (** Not [Blocked], and the quarantine names another partition. *)
  | Inconsistent of inconsistency

val classify :
  Keeper_board_attention_partition.t ->
  Keeper_board_attention_candidate.quarantine_state ->
  t

val inconsistency_to_string : inconsistency -> string
