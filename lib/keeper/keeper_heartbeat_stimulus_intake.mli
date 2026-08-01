(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Selects the earliest ready Event Layer stimulus per turn following
    RFC-0020 §3 Rule 4. Payload families share one order except for explicit
    owner-lane manual compaction, which preempts at a persisted turn boundary
    without removing the current source. An unready input remains queued
    without blocking later ready work in the same Keeper lane. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

(** [stimulus_urgency_to_string u] returns the Otel_metric_store / log label
    for [u] ([immediate] / [normal] / [low]). *)
val stimulus_urgency_to_string : Keeper_event_queue.urgency -> string

(** [pending_board_event_of_stimulus ~meta_after_triage stim] wraps a
    stimulus into a pending board event, threading the keeper meta's
    continuity summary. [Error unavailable] reports a failed board read
    (board-unavailable-result); this function only reports, it does not
    decide disposition — see [pending_board_events_of_stimulus_result] for
    the consuming layer's classify + drop/retain behavior. *)
val pending_board_event_of_stimulus
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> (Keeper_world_observation.pending_board_event option, Keeper_world_observation_board_signal.board_unavailable) result

(** Closed consumption result for an Event-Layer stimulus. A transient Board
    read cannot be represented as an empty successful rendering: it retains
    the exact pending queue selection for a later heartbeat. *)
type stimulus_intake_result =
  | Stimulus_consumed of Keeper_world_observation.pending_board_event list
  | Stimulus_retry_later of
      Keeper_world_observation_board_signal.board_unavailable

(** Pure disposition boundary for one rendered Board event. Permanent
    unavailability is consumed as an empty event; transient unavailability
    remains a typed retry. *)
val classify_pending_board_event_result
  :  (Keeper_world_observation.pending_board_event option, Keeper_world_observation_board_signal.board_unavailable) result
  -> stimulus_intake_result

(** [pending_board_events_of_stimulus_result ~meta_after_triage stim] renders
    [stim] into zero-or-one pending board events. On [Error unavailable] it
    classifies the failure via
    {!Keeper_world_observation_board_signal.disposition_of_unavailable},
    logs and counts it, and returns either [Stimulus_consumed []] for a
    permanent failure or [Stimulus_retry_later unavailable] for a transient
    failure. *)
val pending_board_events_of_stimulus_result
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> stimulus_intake_result

type event_queue_intake_error =
  | Pending_selection_failed of string
  | Transient_board_read of
      Keeper_world_observation_board_signal.board_unavailable

val event_queue_intake_error_to_string : event_queue_intake_error -> string
val event_queue_intake_error_reason_label : event_queue_intake_error -> string

(** Only durable selection corruption/read failures count as a crashed cycle.
    A transient Board read is an expected retry condition: it blocks dispatch
    and retains the exact source without advancing Keeper failure state. *)
val event_queue_intake_error_counts_as_cycle_failure :
  event_queue_intake_error -> bool

(** [record_event_queue_stimulus_turn_started ~ctx ~keeper_name stim] writes
    a generic [Turn_started] reaction for an event-queue stimulus after the
    heartbeat scheduler has admitted a real keeper turn. Logs and swallows
    errors except [Eio.Cancel.Cancelled]. *)
val record_event_queue_stimulus_turn_started
  :  ctx:_ context
  -> keeper_name:string
  -> Keeper_event_queue.stimulus
  -> unit

(** Result of one heartbeat intake — accumulated pending board events
    after dedup and the number of stimuli consumed from the queue. *)
type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  pending_selection : Keeper_event_queue_state.pending_selection option;
  event_queue_intake_error : event_queue_intake_error option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

(** [consume_single_heartbeat_stimulus ~ctx ~meta_after_triage stim]
    increments Otel_metric_store and logs only after consumption is known.
    A transient Board read returns [Stimulus_retry_later] without incrementing
    the consumed counter. *)
val consume_single_heartbeat_stimulus
  :  ctx:_ context
  -> meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> stimulus_intake_result

type spent_selection_reconciliation =
  | Selection_actionable
  | Spent_schedule_acknowledged
  | Spent_grant_replay_acknowledged

val reconcile_spent_selection
  :  config:Workspace_utils.config
  -> keeper_name:string
  -> Keeper_event_queue_state.pending_selection
  -> (spent_selection_reconciliation, string) result
(** Acknowledges a selection whose work has already settled elsewhere, so no
    turn is spent re-observing it. Two kinds settle that way.

    An exact schedule stimulus is acknowledged only when its execution is
    terminal; the schedule ledger stays locked through the queue ACK, so a
    same-occurrence retry cannot start between the observation and deletion.

    An approved Gate resolution is acknowledged once its one-shot grant is
    consumed, because the replay then authorizes nothing and a turn spent on it
    can only re-read the same entry. That path takes no lock: consumption is
    monotonic, so a consumed state cannot revert to usable. A read error leaves
    the selection actionable rather than discarding a possibly live grant. *)

(** [heartbeat_event_intake ~ctx ~meta_after_triage
     ~pending_board_events]
    peeks at most one ready Event-Layer stimulus (per RFC-0020 §3 Rule 4).
    A pending [Manual_compaction_requested] is the sole runtime
    exception: it is selected ahead of data-plane stimuli so an in-flight
    source checkpoint can yield, compact, and then resume from the unchanged
    durable queue. The selected observation is merged with the
    [pending_board_events] already accumulated by the caller, deduplicating by
    [post_id]. A
    [Hitl_resolved] stimulus remains queued until its exact approval id has
    left the pending map, while later ready stimuli can still be selected.
    A transient Board read returns no consumed stimuli, keeps the exact
    [pending_selection], and sets [event_queue_intake_error]; the heartbeat
    loop must not dispatch or acknowledge that selection. *)
val heartbeat_event_intake
  :  ctx:'a context
  -> meta_after_triage:keeper_meta
  -> pending_board_events:Keeper_world_observation.pending_board_event list
  -> heartbeat_event_intake

module For_testing : sig
  (** Force the next [count] Board stimulus reads to report a transient
      [Io_error], allowing the durable retry path to be exercised without a
      real store outage. *)
  val force_transient_board_reads : int -> unit
end
