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
  | Ask_answered_stimulus
  | Hitl_resolved_stimulus
      (** RFC-0320 W3b: an operator resolved a gated-tool approval this keeper
          was waiting on. When the original turn already ended (the approval
          outlived it), the wake arrives with no live tool call to resume, so
          the keeper must be steered back to the originating conversation
          instead of proceeding on its own state. *)
  | Completion_authority_rejection_stimulus
      (** A system LLM completion authority rejected evidence submitted by this
          Keeper. The rejection is a distinct reactive input, not Board or
          scheduled-work activity. *)
  | Task_cancellation_stimulus
      (** Another Keeper cancelled a Task this Keeper authored. A distinct
          reactive input: it is not Board activity (no post exists), not
          scheduled work, and not a completion-authority decision. *)
  | Manual_compaction_stimulus
  | Workspace_message_stimulus
      (** A committed workspace message named this Keeper and was delivered as
          a durable queue entry. The transcript scan reports the same message
          as [Mention_pending] when it can still see it; the queue entry is
          what survives a restart, an ack watermark past the row, and a busy
          cycle, so the drain reports it in its own right. *)

type turn_reason =
  | Mention_pending
  | Board_event_pending
  | Scope_message_pending
  | Bootstrap_stimulus_pending
  | Connector_attention_pending
  | Ask_answered_pending
  | Hitl_resolved_pending
  | Completion_authority_rejection_pending
  | Task_cancellation_pending
  | Manual_compaction_pending
  | Workspace_message_pending
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
  | Ask_answered_pending -> "ask_answered_pending"
  | Hitl_resolved_pending -> "hitl_resolved_pending"
  | Completion_authority_rejection_pending ->
    "completion_authority_rejection_pending"
  | Task_cancellation_pending -> "task_cancellation_pending"
  | Manual_compaction_pending -> "manual_compaction_pending"
  | Workspace_message_pending -> "workspace_message_pending"
  | Scheduled_autonomous_turn -> "scheduled_autonomous_turn"
  | Scheduled_automation_due -> "scheduled_automation_due"
  | Task_backlog _ -> "task_backlog"
  | Never_started -> "never_started"
;;

let turn_reason_of_event_queue_trigger = function
  | Bootstrap_stimulus -> Bootstrap_stimulus_pending
  | Scheduled_automation_stimulus -> Scheduled_automation_due
  | Connector_attention_stimulus -> Connector_attention_pending
  | Ask_answered_stimulus -> Ask_answered_pending
  | Hitl_resolved_stimulus -> Hitl_resolved_pending
  | Completion_authority_rejection_stimulus ->
    Completion_authority_rejection_pending
  | Task_cancellation_stimulus -> Task_cancellation_pending
  | Manual_compaction_stimulus -> Manual_compaction_pending
  | Workspace_message_stimulus -> Workspace_message_pending
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
