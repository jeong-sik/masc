(** Keeper cycle channel + turn-verdict variants + bijection helpers. *)

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type event_queue_trigger =
  | Bootstrap_stimulus
  | No_progress_recovery_stimulus
  | Connector_attention_stimulus
      (** RFC-connector-ambient-attention-wake P1: ambient connector message
          recorded as external attention; edge-triggered, carries an event_id
          pointer. The Discord ambient producer enqueues it when the registry
          flag enables ambient connector wakes. *)

type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | No_progress_recovery_stimulus_pending
  | Connector_attention_pending
  | Scheduled_autonomous_turn
  | Scheduled_automation_due
  | Idle_cooldown_elapsed of
      { idle_sec : int
      ; cooldown : int
      }
  | Cooldown_elapsed
  | Task_backlog of
      { unclaimed : int
      ; failed : int
      }
  | Task_reactive_cooldown_elapsed
  | Never_started
  | Min_interval_elapsed

type skip_reason =
  | Keeper_paused
  | Approval_pending
  | Scheduled_autonomous_disabled
  | Reactive_disabled
  | Provider_cooldown_pending of { remaining_sec : int }
  | Idle_gate_pending of { remaining_sec : int }
  | Cooldown_pending of { remaining_sec : int }
  | No_signal

type turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

val turn_reason_to_string : turn_reason -> string
val turn_reason_of_event_queue_trigger : event_queue_trigger -> turn_reason
val skip_reason_to_string : skip_reason -> string
val channel_to_string : keeper_cycle_channel -> string

(** Strict inverse of {!channel_to_string}. Returns [None] for any string
    outside the canonical set ("turn", "scheduled_autonomous") — including
    the legacy "reactive"/"proactive" aliases and the "heartbeat"
    status-tick marker. *)
val channel_of_string : string -> keeper_cycle_channel option

val is_autonomous : keeper_cycle_channel -> bool
val verdict_reasons_to_strings : turn_verdict -> string list
