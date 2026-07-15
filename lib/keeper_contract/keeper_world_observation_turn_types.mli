(** Keeper cycle channel + turn-verdict variants + bijection helpers. *)

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type event_queue_trigger =
  | Bootstrap_stimulus
  | Scheduled_automation_stimulus
  | Connector_attention_stimulus
      (** RFC-connector-ambient-attention-wake P1: ambient connector message
          recorded as external attention; edge-triggered, carries an event_id
          pointer. Dormant until a producer enqueues it (P3). *)
  | Hitl_resolved_stimulus
      (** RFC-0320 W3b: an operator resolved a gated-tool approval this keeper
          waited on; when the original turn already ended, the wake has no live
          tool call to resume and must steer the keeper back to the originating
          conversation. *)
  | Failure_judgment_stimulus
      (** Durable recovery control for a deterministic failed turn. *)
  | Keeper_invocation_completed_stimulus

type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | Connector_attention_pending
  | Hitl_resolved_pending
  | Failure_judgment_pending
  | Keeper_invocation_completed_pending
  | Scheduled_autonomous_turn
  | Scheduled_automation_due
  | Task_backlog of
      { unclaimed : int
      ; failed : int
      }
  | Never_started

type skip_reason =
  | Keeper_paused
  | Scheduled_autonomous_disabled
  | Reactive_disabled

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
