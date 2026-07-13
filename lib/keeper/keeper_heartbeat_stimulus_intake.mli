(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Drains at most one Event Layer stimulus per turn following
    RFC-0020 §3 Rule 4. Board signals are coalesced by a debounce
    window before falling back to a single non-board queue dequeue. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

(** [stimulus_urgency_to_string u] returns the Otel_metric_store / log label
    for [u] ([immediate] / [normal] / [low]). *)
val stimulus_urgency_to_string : Keeper_event_queue.urgency -> string

(** [pending_board_event_of_stimulus ~meta_after_triage stim] wraps a
    stimulus into a pending board event, threading the keeper meta's
    continuity summary. *)
val pending_board_event_of_stimulus
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> Keeper_world_observation.pending_board_event option

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
  claimed_lease : Keeper_registry_event_queue.lease option;
  event_queue_claim_error : string option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

(** [consume_single_heartbeat_stimulus ~ctx ~meta_after_triage stim]
    increments Otel_metric_store, logs the consumption, and returns a list of
    pending board events derived from [stim] (empty for non-board
    classes). *)
val consume_single_heartbeat_stimulus
  :  ctx:_ context
  -> meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> Keeper_world_observation.pending_board_event list

(** [consume_board_stimulus_batch ~meta_after_triage batch] increments
    Otel_metric_store per stimulus, logs debounce coalescing, and returns the
    pending board events derived from [batch]. *)
val consume_board_stimulus_batch
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus list
  -> Keeper_world_observation.pending_board_event list

(** [heartbeat_event_intake ~ctx ~meta_after_triage
     ~pending_board_events]
    drains the Event-Layer queue (per RFC-0020 §3 Rule 4) and merges
    newly-consumed board events with the [pending_board_events] already
    accumulated by the caller, deduplicating by [post_id]. A
    [Hitl_resolved] head remains queued until its exact approval id has left
    the pending map, so domain callbacks complete before continuation intake.
    Runtime/provider availability cannot defer a durable claim; boundary
    failures settle explicitly through the existing failure route. *)
val heartbeat_event_intake
  :  ctx:'a context
  -> meta_after_triage:keeper_meta
  -> pending_board_events:Keeper_world_observation.pending_board_event list
  -> heartbeat_event_intake
