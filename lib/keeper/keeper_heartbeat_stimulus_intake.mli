(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Leases the earliest ready Event Layer stimulus per turn following
    RFC-0020 §3 Rule 4. Payload families share one order; an unready input
    remains queued without blocking later ready work in the same Keeper lane. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

(** [stimulus_urgency_to_string u] returns the Otel_metric_store / log label
    for [u] ([immediate] / [normal] / [low]). *)
val stimulus_urgency_to_string : Keeper_event_queue.urgency -> string

(** Pure projection from the durable payload. Board intake never re-reads the
    mutable Board; [Error invalid] identifies a corrupt in-memory snapshot. *)
val pending_board_event_of_stimulus
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> (Keeper_world_observation.pending_board_event option, Keeper_event_queue.board_stimulus_error) result

(** Render zero-or-one prompt events without swallowing projection failure.
    The heartbeat loop requeues the owning lease on [Error], so ACK cannot
    discard an unrendered durable payload. *)
val pending_board_events_of_stimulus_result
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> (Keeper_world_observation.pending_board_event list, string) result

(** [record_event_queue_stimulus_turn_started ~ctx ~keeper_name stim] writes
    a generic [Turn_started] reaction after a real keeper turn is admitted.
    Persistence failure is explicit so the owner cycle can requeue the lease. *)
val record_event_queue_stimulus_turn_started
  :  ctx:_ context
  -> keeper_name:string
  -> lease_sequence:int64
  -> Keeper_event_queue.stimulus
  -> (unit, string) result

(** [record_event_queue_turn_admission ~ctx ~keeper_name ~lease_sequence stimuli]
    atomically records the exact stimulus roots and their admitted turn-start
    children for one claimed queue lease. *)
val record_event_queue_turn_admission
  :  ctx:_ context
  -> keeper_name:string
  -> lease_sequence:int64
  -> Keeper_event_queue.stimulus list
  -> (unit, string) result

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

val merge_queued_board_events :
  queued:Keeper_world_observation.pending_board_event list ->
  scanned:Keeper_world_observation.pending_board_event list ->
  Keeper_world_observation.pending_board_event list
(** Put durable queued projections first, preserve every distinct same-post
    occurrence, and remove only exactly equal scan projections. *)

(** [consume_single_heartbeat_stimulus ~ctx ~meta_after_triage stim]
    increments Otel_metric_store, logs the consumption, and returns a list of
    pending board events derived from [stim]. *)
val consume_single_heartbeat_stimulus
  :  ctx:_ context
  -> meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus
  -> (Keeper_world_observation.pending_board_event list, string) result

(** [consume_board_stimulus_batch ~meta_after_triage batch] increments
    Otel_metric_store per stimulus, logs debounce coalescing, and returns the
    pending board events derived from [batch]. *)
val consume_board_stimulus_batch
  :  meta_after_triage:keeper_meta
  -> Keeper_event_queue.stimulus list
  -> (Keeper_world_observation.pending_board_event list, string) result

(** [heartbeat_event_intake ~ctx ~meta_after_triage
     ~pending_board_events]
    drains the Event-Layer queue (per RFC-0020 §3 Rule 4) and merges
    newly-consumed board events with the [pending_board_events] already
    accumulated by the caller, deduplicating by [post_id]. A
    [Hitl_resolved] stimulus remains queued until its exact approval id has
    left the pending map, while later ready stimuli can still be leased.
    Runtime/provider availability cannot defer a durable claim; boundary
    failures settle explicitly through the existing failure route. *)
val heartbeat_event_intake
  :  ctx:'a context
  -> meta_after_triage:keeper_meta
  -> pending_board_events:Keeper_world_observation.pending_board_event list
  -> heartbeat_event_intake
