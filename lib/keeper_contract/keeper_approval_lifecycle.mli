(** Durable operator-visible lifecycle of one Gate approval: the HITL
    vocabulary for the steps an approval has durably passed, persisted one
    row per step. The chat store stores and reads these rows; the steps and
    their meaning belong here, next to
    {!Keeper_approval_queue_rules_types.approval_queue_phase}, which is the
    derived queue progression of a still-pending request and is never
    persisted.

    Request, resolution and replay are distinct phases: a requested call is
    parked but the turn it was asked on keeps running, an approved request
    has permission, and its effect is not reported as applied until a replay
    row exists. The continuation settles once, at the continuation slot:
    [Approval_continuation_recorded] when the turn that received the replay
    completed or durably checkpointed, [Approval_continuation_failed] when
    that turn failed after the provider answered. Either settlement retires
    the approval's queued wake; a turn that failed before any answer leaves
    the slot empty so the evidence is delivered again. *)
type approval_lifecycle_phase =
  | Approval_requested
  | Approval_resolved_approved
  | Approval_resolved_rejected
  | Approval_replay_applied
  | Approval_replay_applied_with_warning
  | Approval_replay_failed
  | Approval_replay_indeterminate
  | Approval_continuation_recorded
  | Approval_continuation_failed

val approval_lifecycle_phases : approval_lifecycle_phase list
(** Every phase once, in declaration order. The list is walked through an
    exhaustive successor match, so a new constructor needs a successor arm
    before it compiles; the contract tests pin the list against every
    constructor. *)

val approval_lifecycle_phase_to_label : approval_lifecycle_phase -> string
(** The durable label one phase is persisted under. *)

val approval_lifecycle_phase_of_label : string -> approval_lifecycle_phase option
(** The phase a persisted label names. [None] for a label this vocabulary
    does not hold: a reader treats such a row as undecodable rather than as a
    phase it can draw. *)
