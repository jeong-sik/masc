(** Typed sender authority driving producer-selected wake timing. *)
type sender_kind =
  | Human_sender
  | Connector_sender
  | Keeper_sender
  | Own_async_sender
  | System_sender

(** Closed classification of Keeper inbound stimuli. *)
type input_kind =
  | Direct_message
  | Board_mention_or_reply
  | Board_broadcast
  | Board_reaction_or_vote
  | Board_attention_ambient
  | Delegate_completion
  | Own_async_completion
  | Task_cancelled_or_rejected
  | Task_outcome_approved
  | Scheduled_wake
  | Workspace_broadcast

(** Producer-selected wake policy (#54342):
    - [Now]: wake immediately (or steer if a turn is already active).
    - [At_tick]: coalesce onto the Keeper's deterministic staggered tick grid.
    - [Carry]: durably queue to ride the next reactive or spontaneous turn
      without forcing an extra wakeup. *)
type stimulus_wake_policy =
  | Now
  | At_tick
  | Carry

val stimulus_wake_policy_of :
  input_kind:input_kind -> sender_kind:sender_kind -> stimulus_wake_policy

val task_verdict_wake_policy :
  input_kind:input_kind -> Masc_domain.completion_authority -> stimulus_wake_policy
(** Use the verdict's recorded authority when choosing its wake timing. *)

val urgency_of_stimulus_wake_policy :
  stimulus_wake_policy -> Keeper_event_queue.urgency

val effective_urgency : Keeper_event_queue.stimulus -> Keeper_event_queue.urgency
(** Verdicts carry the authority that owns their wake timing. Other inputs
    retain the timing their producer recorded. The queued row stays intact. *)
