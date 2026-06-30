(** Keeper cycle channel + turn-verdict variants + their bijection
    helpers.

    [keeper_cycle_channel] tags whether a keeper cycle is reactive
    (driven by mentions/board/messages/tasks) or scheduled-autonomous
    (proactive turns on a timer).

    [turn_reason] carries the reasons a keeper *runs* a turn
    (mention, board event, scope message, scheduled autonomous, idle
    cooldown elapsed with timers, etc.). Inline-record variants carry
    the timing fields the dashboard surfaces.

    [skip_reason] carries the 7 reasons a keeper *skips* a turn
    (paused, approval pending, autonomous disabled, cooldown
    pending with remaining_sec, etc.).

    [turn_verdict] is [Run of { reasons }] or [Skip of { reasons }]
    with non-empty list-of-reasons payload.

    Pure variants + total to_string helpers. Verbatim extract from
    [Keeper_world_observation]; the parent retains transparent
    variant aliases so .mli concrete declarations + inline-record
    payloads stay valid. *)

type keeper_cycle_channel =
  | Reactive
  | Scheduled_autonomous

type event_queue_trigger =
  | Bootstrap_stimulus
  | No_progress_recovery_stimulus
  | Connector_attention_stimulus
      (** RFC-connector-ambient-attention-wake P1: an ambient connector message
          recorded as Keeper_external_attention. Edge-triggered (dequeued once),
          carries an event_id pointer (not content). Dormant until a producer
          enqueues it (P3). *)

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
  | Provider_cooldown_pending of { remaining_sec : int }
  | Idle_gate_pending of { remaining_sec : int }
  | Cooldown_pending of { remaining_sec : int }
  | No_signal

type turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

let turn_reason_to_string = function
  | Mention_pending -> "mention_pending"
  | Board_event_pending -> "board_event_pending"
  | Scope_message_pending -> "scope_message_pending"
  | Bootstrap_stimulus_pending -> "bootstrap_stimulus_pending"
  | No_progress_recovery_stimulus_pending -> "no_progress_recovery_stimulus_pending"
  | Connector_attention_pending -> "connector_attention_pending"
  | Scheduled_autonomous_turn -> "scheduled_autonomous_turn"
  | Scheduled_automation_due -> "scheduled_automation_due"
  | Idle_cooldown_elapsed _ -> "idle_cooldown_elapsed"
  | Cooldown_elapsed -> "cooldown_elapsed"
  | Task_backlog _ -> "task_backlog"
  | Task_reactive_cooldown_elapsed -> "task_reactive_cooldown_elapsed"
  | Never_started -> "never_started"
  | Min_interval_elapsed -> "min_interval_elapsed"
;;

let turn_reason_of_event_queue_trigger = function
  | Bootstrap_stimulus -> Bootstrap_stimulus_pending
  | No_progress_recovery_stimulus -> No_progress_recovery_stimulus_pending
  | Connector_attention_stimulus -> Connector_attention_pending
;;

let skip_reason_to_string = function
  | Keeper_paused -> "keeper_paused"
  | Approval_pending -> "approval_pending"
  | Scheduled_autonomous_disabled -> "scheduled_autonomous_disabled"
  | Provider_cooldown_pending _ -> "provider_cooldown_pending"
  | Idle_gate_pending _ -> "idle_gate_pending"
  | Cooldown_pending _ -> "cooldown_pending"
  | No_signal -> "no_signal"
;;

(* Canonical wire encoding. [Reactive] serialises as "turn" (the value the
   majority of producers + the JSON default already emit); the prior
   "reactive" spelling is dropped (RFC-0020 Phase 1 PR-3, owner decision
   2026-06-15). *)
let channel_to_string = function
  | Reactive -> "turn"
  | Scheduled_autonomous -> "scheduled_autonomous"
;;

(* Strict parse at the persistence/telemetry read boundary: only the
   canonical strings produced by [channel_to_string] round-trip. Legacy
   aliases ("reactive"/"proactive") and the non-interaction "heartbeat"
   status-tick marker return [None] — callers decide how to treat an
   unrecognised channel rather than silently coercing it. *)
let channel_of_string = function
  | "turn" -> Some Reactive
  | "scheduled_autonomous" -> Some Scheduled_autonomous
  | _ -> None
;;

let is_autonomous = function
  | Reactive -> false
  | Scheduled_autonomous -> true
;;

let verdict_reasons_to_strings = function
  | Run { reasons = first, rest } -> List.map turn_reason_to_string (first :: rest)
  | Skip { reasons = first, rest } -> List.map skip_reason_to_string (first :: rest)
;;
