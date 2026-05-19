(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Extracted from [keeper_heartbeat_loop.ml] (lines 375-553) as part of
    the godfile decomp campaign. Owns:

    - the [heartbeat_event_intake] record returned to the heartbeat loop;
    - per-class string labels used in Prometheus and log lines;
    - per-stimulus consumption ([consume_single_heartbeat_stimulus]) +
      board-batch consumption ([consume_board_stimulus_batch]);
    - the top-level RFC-0020 §3 Rule 4 draining function
      ([heartbeat_event_intake]) that prefers a debounced board batch and
      falls back to a single non-board queue dequeue. *)

open Keeper_types
open Keeper_execution

let stimulus_urgency_to_string = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Keeper_event_queue.Normal -> "normal"
  | Keeper_event_queue.Low -> "low"
;;

let stimulus_class_to_string = function
  | Keeper_event_queue.Board_signal -> "board_signal"
  | Bootstrap -> "bootstrap"
  | Alive_but_stuck_recovery -> "alive_but_stuck_recovery"
  | Stay_silent_recovery -> "stay_silent_recovery"
  | Unsupported _ -> "unsupported"
;;

let pending_board_event_of_stimulus ~meta_after_triage stim =
  Keeper_world_observation.pending_board_event_of_stimulus
    ~continuity_summary:meta_after_triage.continuity_summary
    ~meta:meta_after_triage
    stim
;;

let record_recovery_stimulus_turn_started
      ~(ctx : _ context)
      ~keeper_name
      (stimulus : Keeper_event_queue.stimulus)
  =
  try
    Keeper_reaction_ledger.record_event_queue_reaction
      ~base_path:ctx.config.base_path
      ~keeper_name
      ~reaction_kind:Keeper_reaction_ledger.Turn_started
      stimulus
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error
      "turn entry: failed to persist recovery stimulus reaction post_id=%s \
       (keeper=%s): %s"
      stimulus.post_id
      keeper_name
      (Printexc.to_string exn)
;;

type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
}

let consume_single_heartbeat_stimulus
      ~(ctx : _ context)
      ~meta_after_triage
      (stim : Keeper_event_queue.stimulus)
  =
  let stimulus_class = Keeper_event_queue.classify stim in
  let class_str = stimulus_class_to_string stimulus_class in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_stimulus_consumed
    ~labels:[ "keeper", meta_after_triage.name; "class", class_str ]
    ();
  Log.Keeper.info
    "turn entry: consumed stimulus stimulus_id=%s urgency=%s class=%s \
     payload_len=%d (keeper=%s)"
    stim.post_id
    (stimulus_urgency_to_string stim.urgency)
    class_str
    (String.length stim.payload)
    meta_after_triage.name;
  match stimulus_class with
  | Board_signal -> pending_board_event_of_stimulus ~meta_after_triage stim |> Option.to_list
  | Bootstrap ->
    Log.Keeper.info
      "turn entry: bootstrap stimulus consumed (keeper=%s)"
      meta_after_triage.name;
    []
  | Alive_but_stuck_recovery ->
    Log.Keeper.info
      "turn entry: alive-but-stuck recovery stimulus consumed post_id=%s \
       (keeper=%s)"
      stim.post_id
      meta_after_triage.name;
    record_recovery_stimulus_turn_started
      ~ctx
      ~keeper_name:meta_after_triage.name
      stim;
    []
  | Stay_silent_recovery ->
    Log.Keeper.info
      "turn entry: stay-silent recovery stimulus consumed post_id=%s \
       (keeper=%s)"
      stim.post_id
      meta_after_triage.name;
    record_recovery_stimulus_turn_started
      ~ctx
      ~keeper_name:meta_after_triage.name
      stim;
    []
  | Unsupported prefix ->
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_unsupported_stimulus
      ~labels:[ "keeper", meta_after_triage.name ]
      ();
    Log.Keeper.warn
      "turn entry: unsupported stimulus consumed prefix=%S post_id=%s \
       (keeper=%s) — wake→no_signal gap #12684"
      prefix
      stim.post_id
      meta_after_triage.name;
    []
;;

let consume_board_stimulus_batch ~meta_after_triage batch =
  let batch_len = List.length batch in
  if batch_len > 1 then
    Log.Keeper.info
      "debounce: coalesced %d board signals (keeper=%s)"
      batch_len
      meta_after_triage.name;
  List.filter_map
    (fun (stim : Keeper_event_queue.stimulus) ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_stimulus_consumed
         ~labels:[ "keeper", meta_after_triage.name; "class", "board_signal" ]
         ();
       Log.Keeper.info
         "turn entry: consumed stimulus stimulus_id=%s urgency=%s class=board_signal \
          payload_len=%d (keeper=%s)"
         stim.post_id
         (stimulus_urgency_to_string stim.urgency)
         (String.length stim.payload)
         meta_after_triage.name;
       pending_board_event_of_stimulus ~meta_after_triage stim)
    batch
;;

let heartbeat_event_intake ~ctx ~meta_after_triage ~pending_board_events =
  (* RFC-0020 §3 Rule 4 — drain at most one Event Layer stimulus
     per turn. Board signals are coalesced by a debounce window before
     falling back to a single non-board queue dequeue. *)
  let window = Keeper_config.keeper_board_debounce_window_sec () in
  let board_batch =
    Keeper_registry_event_queue.drain_board
      ~window_sec:window
      ~base_path:ctx.config.base_path
      meta_after_triage.name
  in
  let queued_observations, consumed_stimulus_count =
    match board_batch with
    | [] ->
      (match
         Keeper_registry_event_queue.dequeue
           ~base_path:ctx.config.base_path
           meta_after_triage.name
       with
       | None -> [], 0
       | Some stim -> consume_single_heartbeat_stimulus ~ctx ~meta_after_triage stim, 1)
    | batch -> consume_board_stimulus_batch ~meta_after_triage batch, List.length batch
  in
  let pending_board_events =
    List.fold_left
      (fun acc (event : Keeper_world_observation.pending_board_event) ->
         if
           List.exists
             (fun existing ->
                String.equal
                  existing.Keeper_world_observation.post_id
                  event.Keeper_world_observation.post_id)
             acc
         then acc
         else (
           Log.Keeper.info
             "turn entry: promoted queued board stimulus post_id=%s keeper=%s"
             event.Keeper_world_observation.post_id
             meta_after_triage.name;
           event :: acc))
      pending_board_events
      (List.rev queued_observations)
  in
  { pending_board_events; consumed_stimulus_count }
;;
