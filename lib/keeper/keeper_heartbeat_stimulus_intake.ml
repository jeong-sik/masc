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

let record_event_queue_stimulus_reaction
      ~(ctx : _ context)
      ~keeper_name
      ~reaction_kind
      (stimulus : Keeper_event_queue.stimulus)
  =
  try
    Keeper_reaction_ledger.record_event_queue_reaction
      ~base_path:ctx.config.base_path
      ~keeper_name
      ~reaction_kind
      stimulus
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Log.Keeper.error
      "turn entry: failed to persist event queue stimulus reaction post_id=%s \
       (keeper=%s): %s"
      stimulus.post_id
      keeper_name
      (Printexc.to_string exn)
;;

let record_event_queue_stimulus_turn_started ~ctx ~keeper_name stimulus =
  record_event_queue_stimulus_reaction
    ~ctx
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Turn_started
    stimulus
;;

let record_event_queue_stimulus_ack ~ctx ~keeper_name stimulus =
  record_event_queue_stimulus_reaction
    ~ctx
    ~keeper_name
    ~reaction_kind:Keeper_reaction_ledger.Event_queue_ack
    stimulus
;;

let record_recovery_stimulus_turn_started ~ctx ~keeper_name stimulus =
  record_event_queue_stimulus_turn_started ~ctx ~keeper_name stimulus
;;

type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

let recorded_attention_item_by_event_id ~base_path ~keeper_name ~event_id =
  Keeper_external_attention.load_events ~base_path ~keeper_name
  |> List.find_map (function
       | Keeper_external_attention.Recorded item
         when String.equal item.Keeper_external_attention.event_id event_id ->
         Some item
       | Keeper_external_attention.Recorded _
       | Keeper_external_attention.Claimed_for_turn _
       | Keeper_external_attention.Resolved _
       | Keeper_external_attention.Ignored _ ->
         None)
;;

let event_queue_trigger_of_stimulus (stim : Keeper_event_queue.stimulus) =
  match stim.payload with
  | Keeper_event_queue.Bootstrap -> Some Keeper_world_observation.Bootstrap_stimulus
  | Keeper_event_queue.No_progress_recovery ->
    Some Keeper_world_observation.No_progress_recovery_stimulus
  | Keeper_event_queue.Schedule_due _ ->
    Some Keeper_world_observation.Scheduled_automation_stimulus
  | Keeper_event_queue.Connector_attention _ ->
    Some Keeper_world_observation.Connector_attention_stimulus
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Goal_verification_failed _
  | Keeper_event_queue.Failure_judgment _ ->
    (* No dedicated turn_reason: like the other async-completion wakes, the
       stimulus itself forces the keeper to re-run its cycle. Once the resolved
       approval has left the queue the keeper no longer skips on
       [Approval_pending] and proceeds on its own state. *)
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
  | Keeper_event_queue.Schedule_due sw ->
    Log.Keeper.info
      "turn entry: scheduled wake delivered schedule_id=%s due_at=%.3f (keeper=%s)"
      sw.schedule_id
      sw.due_at
      meta_after_triage.name;
    pending_board_event_of_stimulus ~meta_after_triage stim |> Option.to_list
  | Keeper_event_queue.Goal_verification_failed failure ->
    (* A rejected completion claim is actionable work for the assigned keeper.
       Promote it to a pending observation so the cycle does not wake empty. *)
    Log.Keeper.info
      "turn entry: goal verification failure delivered goal_id=%s request_id=%s \
       rejected_by=%s (keeper=%s)"
      failure.goal_id
      failure.request_id
      failure.rejected_by
      meta_after_triage.name;
    pending_board_event_of_stimulus ~meta_after_triage stim |> Option.to_list
  | Keeper_event_queue.Failure_judgment fj ->
    (* RFC-0313 W2: a deterministic turn failure awaits an LLM-boundary
       verdict. Promote it to a pending observation so the judgment turn does
       not wake empty — returning [] would silently drop the escalation. *)
    Log.Keeper.info
      "turn entry: failure judgment delivered runtime=%s class=%s (keeper=%s)"
      fj.fj_runtime_id
      (Keeper_runtime_failure_route.judgment_class_label fj.fj_judgment)
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
    (* RFC-connector-ambient-attention-wake: the stimulus woke this keeper.
       The event_id is a pointer only; the message/surface content stays in
       Keeper_external_attention. Load it here and promote it to a pending
       observation so the turn has real connector context instead of a
       contentless wake reason. *)
    let pending_events =
      match
        recorded_attention_item_by_event_id
          ~base_path:ctx.config.base_path
          ~keeper_name:meta_after_triage.name
          ~event_id:ca.event_id
      with
      | Some item ->
        [ Keeper_world_observation.pending_board_event_of_external_attention
            ~meta:meta_after_triage
            item
        ]
      | None ->
        Log.Keeper.warn
          "connector attention stimulus missing recorded item event_id=%s (keeper=%s)"
          ca.event_id
          meta_after_triage.name;
        []
    in
    (match
       Keeper_external_attention.claim_for_turn
         ~base_path:ctx.config.base_path
         ~keeper_name:meta_after_triage.name
         ~event_ids:[ ca.event_id ]
         ~claim_id:(Printf.sprintf "heartbeat-wake:%s" stim.post_id)
         ~turn_id:None
         ()
     with
     | Ok () -> ()
     | Error err ->
       Log.Keeper.warn
         "connector attention claim_for_turn failed event_id=%s (keeper=%s): %s"
         ca.event_id meta_after_triage.name err);
    Log.Keeper.info
      "turn entry: connector attention stimulus consumed event_id=%s (keeper=%s)"
      ca.event_id
      meta_after_triage.name;
    pending_events
  | Keeper_event_queue.Hitl_resolved r ->
    (* The HITL approval this keeper was skipping on ([Skip Approval_pending])
       was resolved. The wake is the whole point: the approval has left the
       queue, so this cycle no longer skips and the keeper resumes on its own
       state. There is no observation to inject — the decision reached the
       keeper's suspended tool call (or the reject/expire teardown) through the
       resolver, not turn input; injecting a pending event would fabricate one. *)
    Log.Keeper.info
      "turn entry: hitl resolution delivered approval=%s decision=%s (keeper=%s)"
      r.approval_id
      (Keeper_event_queue.hitl_resolution_decision_to_string r.decision)
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
