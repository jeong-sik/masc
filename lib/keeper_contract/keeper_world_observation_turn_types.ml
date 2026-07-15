(** Keeper cycle channel + turn-verdict variants + their bijection
    helpers.

    [keeper_cycle_channel] tags whether a keeper cycle is reactive
    (driven by mentions/board/messages/tasks) or scheduled-autonomous
    (proactive turns on a timer).

    [turn_reason] carries the reasons a keeper *runs* a turn
    (mention, board event, scope message, scheduled autonomous, idle
    cooldown elapsed with timers, etc.). Inline-record variants carry
    the timing fields the dashboard surfaces.

    [skip_reason] carries the reasons a keeper *skips* a turn
    (paused, autonomous disabled, cooldown
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
  | Scheduled_automation_stimulus
  | Connector_attention_stimulus
      (** RFC-connector-ambient-attention-wake P1: an ambient connector message
          recorded as Keeper_external_attention. Edge-triggered (dequeued once),
          carries an event_id pointer (not content). Dormant until a producer
          enqueues it (P3). *)
  | Hitl_resolved_stimulus
      (** RFC-0320 W3b: an operator resolved a gated-tool approval this keeper
          was waiting on. When the original turn already ended (the approval
          outlived it), the wake arrives with no live tool call to resume, so
          the keeper must be steered back to the originating conversation
          instead of proceeding on its own state. *)
  | Failure_judgment_stimulus
      (** Durable recovery control for a deterministic failed turn. This opens
          the independent judge even when the failed Keeper is unhealthy or
          its ordinary reactive lane is disabled. *)
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
      (** RFC-0297 P0-1: the global reactive kill-switch
          (MASC_KEEPER_REACTIVE_ENABLED) is off, so a pending reactive trigger
          (mention / board event / scope message) does not open a turn. *)

type turn_verdict =
  | Run of { reasons : turn_reason * turn_reason list }
  | Skip of { reasons : skip_reason * skip_reason list }

let turn_reason_to_string = function
  | Mention_pending -> "mention_pending"
  | Board_event_pending -> "board_event_pending"
  | Scope_message_pending -> "scope_message_pending"
  | Bootstrap_stimulus_pending -> "bootstrap_stimulus_pending"
  | Connector_attention_pending -> "connector_attention_pending"
  | Hitl_resolved_pending -> "hitl_resolved_pending"
  | Failure_judgment_pending -> "failure_judgment_pending"
  | Keeper_invocation_completed_pending -> "keeper_invocation_completed_pending"
  | Scheduled_autonomous_turn -> "scheduled_autonomous_turn"
  | Scheduled_automation_due -> "scheduled_automation_due"
  | Task_backlog _ -> "task_backlog"
  | Never_started -> "never_started"
;;

let turn_reason_of_event_queue_trigger = function
  | Bootstrap_stimulus -> Bootstrap_stimulus_pending
  | Scheduled_automation_stimulus -> Scheduled_automation_due
  | Connector_attention_stimulus -> Connector_attention_pending
  | Hitl_resolved_stimulus -> Hitl_resolved_pending
  | Failure_judgment_stimulus -> Failure_judgment_pending
  | Keeper_invocation_completed_stimulus -> Keeper_invocation_completed_pending
;;

let skip_reason_to_string = function
  | Keeper_paused -> "keeper_paused"
  | Scheduled_autonomous_disabled -> "scheduled_autonomous_disabled"
  | Reactive_disabled -> "reactive_disabled"
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
