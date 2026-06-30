(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Extracted from [keeper_heartbeat_loop.ml] (lines 375-553) as part of
    the godfile decomp campaign. Owns:

    - the [heartbeat_event_intake] record returned to the heartbeat loop;
    - per-class string labels used in Otel_metric_store and log lines;
    - per-stimulus consumption ([consume_single_heartbeat_stimulus]) +
      board-batch consumption ([consume_board_stimulus_batch]);
    - the top-level RFC-0020 §3 Rule 4 draining function
      ([heartbeat_event_intake]) that prefers a debounced board batch and
      falls back to a single non-board queue dequeue. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

let stimulus_urgency_to_string = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Keeper_event_queue.Normal -> "normal"
  | Keeper_event_queue.Low -> "low"
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
  consumed_stimuli : Keeper_event_queue.stimulus list;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

let event_queue_trigger_of_stimulus (stim : Keeper_event_queue.stimulus) =
  match stim.payload with
  | Keeper_event_queue.Bootstrap -> Some Keeper_world_observation.Bootstrap_stimulus
  | Keeper_event_queue.No_progress_recovery ->
    Some Keeper_world_observation.No_progress_recovery_stimulus
  | Keeper_event_queue.Connector_attention _ ->
    Some Keeper_world_observation.Connector_attention_stimulus
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _ ->
    None
;;

let consume_single_heartbeat_stimulus
      ~(ctx : _ context)
      ~meta_after_triage
      (stim : Keeper_event_queue.stimulus)
  =
  let class_str = Keeper_event_queue.payload_kind_label stim.payload in
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string StimulusConsumed)
    ~labels:[ "keeper", meta_after_triage.name; "class", class_str ]
    ();
  Log.Keeper.info
    "turn entry: consumed stimulus stimulus_id=%s urgency=%s class=%s (keeper=%s)"
    stim.post_id
    (stimulus_urgency_to_string stim.urgency)
    class_str
    meta_after_triage.name;
  match stim.payload with
  | Keeper_event_queue.Board_signal _ ->
    pending_board_event_of_stimulus ~meta_after_triage stim |> Option.to_list
  | Keeper_event_queue.Fusion_completed c ->
    (* RFC-0266: an async fusion deliberation finished and woke this keeper.
       Surface the resolved answer as a pending_board_event so this turn acts
       on it (a non-empty list, unlike Bootstrap/No_progress_recovery which
       inject nothing — returning [] here would silently drop the result). *)
    Log.Keeper.info
      "turn entry: fusion result delivered run_id=%s ok=%b (keeper=%s)"
      c.run_id
      c.ok
      meta_after_triage.name;
    pending_board_event_of_stimulus ~meta_after_triage stim |> Option.to_list
  | Keeper_event_queue.Bg_completed c ->
    (* RFC-0290: a background job finished and woke this keeper. Surface the
       outcome as a pending_board_event so the turn acts on it. Returning []
       would compile but silently drop the completed job result. *)
    Log.Keeper.info
      "turn entry: bg result delivered run_id=%s kind=%s ok=%b (keeper=%s)"
      c.bg_run_id
      (Keeper_event_queue.bg_job_kind_to_string c.bg_kind)
      (match c.bg_outcome with
       | Keeper_event_queue.Bg_ok _ -> true
       | Keeper_event_queue.Bg_failed _ -> false)
      meta_after_triage.name;
    pending_board_event_of_stimulus ~meta_after_triage stim |> Option.to_list
  | Keeper_event_queue.Bootstrap ->
    Log.Keeper.info
      "turn entry: bootstrap stimulus consumed (keeper=%s)"
      meta_after_triage.name;
    []
  | Keeper_event_queue.No_progress_recovery ->
    Log.Keeper.info
      "turn entry: no-progress recovery stimulus consumed post_id=%s \
       (keeper=%s)"
      stim.post_id
      meta_after_triage.name;
    record_recovery_stimulus_turn_started
      ~ctx
      ~keeper_name:meta_after_triage.name
      stim;
    []
  | Keeper_event_queue.Connector_attention ca ->
    (* RFC-connector-ambient-attention-wake P1: the stimulus woke this keeper.
       Content threading (reading the external_attention item by event_id into a
       pending input) is P3; for now the turn runs with no injected board event,
       like Bootstrap/No_progress_recovery. *)
    Log.Keeper.info
      "turn entry: connector attention stimulus consumed event_id=%s (keeper=%s)"
      ca.event_id
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
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string StimulusConsumed)
         ~labels:[ "keeper", meta_after_triage.name; "class", "board_signal" ]
         ();
       Log.Keeper.info
         "turn entry: consumed stimulus stimulus_id=%s urgency=%s class=board_signal \
          (keeper=%s)"
         stim.post_id
         (stimulus_urgency_to_string stim.urgency)
         meta_after_triage.name;
       pending_board_event_of_stimulus ~meta_after_triage stim)
    batch
;;

let heartbeat_event_intake ~ctx ~meta_after_triage ~pending_board_events =
  (* RFC-0020 §3 Rule 4 — drain at most one Event Layer stimulus
     per turn. Board signals are coalesced by the default debounce
     window in {!Keeper_event_queue.drain_board_window} (2 s). *)
  let board_batch =
    Keeper_registry_event_queue.drain_board
      ~base_path:ctx.config.base_path
      meta_after_triage.name
  in
  let queued_observations, consumed_stimuli =
    match board_batch with
    | [] ->
      (match
         Keeper_registry_event_queue.dequeue
           ~base_path:ctx.config.base_path
           meta_after_triage.name
       with
       | None -> [], []
       | Some stim -> consume_single_heartbeat_stimulus ~ctx ~meta_after_triage stim, [ stim ])
    | batch -> consume_board_stimulus_batch ~meta_after_triage batch, batch
  in
  let consumed_stimulus_count = List.length consumed_stimuli in
  let event_queue_triggers = List.filter_map event_queue_trigger_of_stimulus consumed_stimuli in
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
  { pending_board_events; consumed_stimulus_count; consumed_stimuli; event_queue_triggers }
;;
