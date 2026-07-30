(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Extracted from [keeper_heartbeat_loop.ml] (lines 375-553) as part of
    the godfile decomp campaign. Owns:

    - the [heartbeat_event_intake] record returned to the heartbeat loop;
    - per-class string labels used in Otel_metric_store and log lines;
    - per-stimulus consumption ([consume_single_heartbeat_stimulus]);
    - the top-level RFC-0020 §3 Rule 4 draining function
      ([heartbeat_event_intake]) that selects the earliest ready stimulus
      without assigning priority to a payload family. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_execution

let stimulus_urgency_to_string = function
  | Keeper_event_queue.Immediate -> "immediate"
  | Keeper_event_queue.Normal -> "normal"
  | Keeper_event_queue.Low -> "low"
;;

let forced_transient_board_reads_for_test : int Atomic.t = Atomic.make 0

module For_testing = struct
  let force_transient_board_reads count =
    Atomic.set forced_transient_board_reads_for_test (Int.max 0 count)
  ;;
end

let consume_forced_transient_board_read () =
  let rec loop () =
    let remaining = Atomic.get forced_transient_board_reads_for_test in
    if remaining <= 0
    then false
    else
      Atomic.compare_and_set
        forced_transient_board_reads_for_test
        remaining
        (remaining - 1)
      || loop ()
  in
  loop ()
;;

let pending_board_event_of_stimulus ~meta_after_triage stim =
  match stim.Keeper_event_queue.payload with
  | (Keeper_event_queue.Board_signal _ | Keeper_event_queue.Board_attention _)
    when consume_forced_transient_board_read () ->
    Error
      { Keeper_world_observation_board_signal.operation =
          Keeper_world_observation_board_signal.Get_post
      ; post_id = stim.post_id
      ; error = Board.Io_error "forced transient Board stimulus read failure"
      }
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _ ->
    Keeper_world_observation.pending_board_event_of_stimulus
      ~meta:meta_after_triage
      stim
;;

type stimulus_intake_result =
  | Stimulus_consumed of Keeper_world_observation.pending_board_event list
  | Stimulus_retry_later of
      Keeper_world_observation_board_signal.board_unavailable

type event_queue_intake_error =
  | Pending_selection_failed of string
  | Transient_board_read of
      Keeper_world_observation_board_signal.board_unavailable

let event_queue_intake_error_to_string = function
  | Pending_selection_failed detail ->
    "event queue pending selection failed: " ^ detail
  | Transient_board_read unavailable ->
    "event queue stimulus intake retry: "
    ^ Keeper_world_observation_board_signal.unavailable_to_string unavailable
;;

let event_queue_intake_error_reason_label = function
  | Pending_selection_failed _ -> "event_queue_selection_failed"
  | Transient_board_read _ -> "event_queue_transient_board_read"
;;

let event_queue_intake_error_counts_as_cycle_failure = function
  | Pending_selection_failed _ -> true
  | Transient_board_read _ -> false
;;

let classify_pending_board_event_result = function
  | Ok events_opt -> Stimulus_consumed (Option.to_list events_opt)
  | Error
      (unavailable : Keeper_world_observation_board_signal.board_unavailable) ->
    (match
       Keeper_world_observation_board_signal.disposition_of_unavailable unavailable
     with
     | Keeper_world_observation_board_signal.Permanent -> Stimulus_consumed []
     | Keeper_world_observation_board_signal.Transient ->
       Stimulus_retry_later unavailable)
;;

(* Board-unavailable-result: permanent poison is consumed so a swept post
   cannot crash-loop forever. A transient environment failure remains a typed
   retry; the queue selection came from [peek_when_result], so retaining it
   requires no mutation — only withholding consumption and ACK. *)
let pending_board_events_of_stimulus_result ~meta_after_triage stim =
  let read_result = pending_board_event_of_stimulus ~meta_after_triage stim in
  match read_result with
  | Ok _ -> classify_pending_board_event_result read_result
  | Error (unavailable : Keeper_world_observation_board_signal.board_unavailable) ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ObservationQueryFailures)
      ~labels:
        [ ( "operation"
          , Runtime_observation_query_operation.(to_label Board_stimulus_intake) )
        ]
      ();
    (match Keeper_world_observation_board_signal.disposition_of_unavailable unavailable with
     | Keeper_world_observation_board_signal.Permanent ->
       Log.Keeper.warn
         "stimulus intake: board read permanently unavailable, consuming stimulus \
          without retry stimulus_id=%s keeper=%s: %s"
         stim.Keeper_event_queue.post_id
         meta_after_triage.name
         (Keeper_world_observation_board_signal.unavailable_to_string unavailable)
     | Keeper_world_observation_board_signal.Transient ->
       Log.Keeper.warn
         "stimulus intake: board read transiently unavailable, retaining exact \
          pending source stimulus_id=%s keeper=%s: %s"
         stim.Keeper_event_queue.post_id
         meta_after_triage.name
         (Keeper_world_observation_board_signal.unavailable_to_string unavailable));
    classify_pending_board_event_result read_result
;;

let record_event_queue_stimulus_turn_started
      ~(ctx : _ context)
      ~keeper_name
      (stimulus : Keeper_event_queue.stimulus)
  =
  try
    Keeper_reaction_ledger.record_event_queue_turn_started
      ~base_path:ctx.config.base_path
      ~keeper_name
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

type heartbeat_event_intake = {
  pending_board_events : Keeper_world_observation.pending_board_event list;
  consumed_stimulus_count : int;
  consumed_stimuli : Keeper_event_queue.stimulus list;
  pending_selection : Keeper_event_queue.stimulus option;
  event_queue_intake_error : event_queue_intake_error option;
  event_queue_triggers : Keeper_world_observation.event_queue_trigger list;
}

let recorded_attention_item_by_event_id ~base_path ~keeper_name ~event_id =
  Keeper_external_attention.load_events ~base_path ~keeper_name
  |> List.find_map (function
       | Keeper_external_attention.Recorded item
         when String.equal item.Keeper_external_attention.event_id event_id ->
         Some item
       | Keeper_external_attention.Recorded _
       | Keeper_external_attention.Resolved _
       | Keeper_external_attention.Ignored _ ->
         None)
;;

let event_queue_trigger_of_stimulus (stim : Keeper_event_queue.stimulus) =
  match stim.payload with
  | Keeper_event_queue.Bootstrap -> Some Keeper_world_observation.Bootstrap_stimulus
  | Keeper_event_queue.Schedule_due _ ->
    Some Keeper_world_observation.Scheduled_automation_stimulus
  | Keeper_event_queue.Connector_attention _ ->
    Some Keeper_world_observation.Connector_attention_stimulus
  | Keeper_event_queue.Hitl_resolved _ ->
    (* RFC-0320 W3b: give the HITL-resolution wake a dedicated turn_reason so
       the prompt can steer the keeper back to the originating conversation
       instead of silently proceeding on its own state. This changes only how
       the turn is described, not whether it runs. *)
    Some Keeper_world_observation.Hitl_resolved_stimulus
  | Keeper_event_queue.Manual_compaction_requested ->
    Some Keeper_world_observation.Manual_compaction_stimulus
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _ ->
    (* No dedicated turn_reason: like the other async-completion wakes, the
       stimulus itself forces the keeper to re-run its cycle and proceed on its
       own state. *)
    None
;;

let consume_single_heartbeat_stimulus
      ~(ctx : _ context)
      ~meta_after_triage
      (stim : Keeper_event_queue.stimulus)
  =
  let class_str = Keeper_event_queue.payload_kind_label stim.payload in
  let intake_result =
    match stim.payload with
    | Keeper_event_queue.Board_signal _ | Keeper_event_queue.Board_attention _ ->
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Fusion_completed c ->
      (* RFC-0266: an async fusion deliberation finished and woke this keeper.
         Surface the resolved answer as a pending_board_event so this turn acts
         on it (a non-empty list, unlike Bootstrap which injects nothing). *)
      let terminal =
        match c.terminal with
        | Keeper_event_queue.Fusion_succeeded _ -> "succeeded"
        | Keeper_event_queue.Fusion_failed _ -> "failed"
        | Keeper_event_queue.Fusion_cancelled -> "cancelled"
      in
      Log.Keeper.info
        "turn entry: fusion result delivered run_id=%s terminal=%s (keeper=%s)"
        c.run_id terminal meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Bg_completed c ->
      (* RFC-0290: a background job finished and woke this keeper. Surface the
         outcome as a pending_board_event so this turn acts on it. *)
      Log.Keeper.info
        "turn entry: bg result delivered run_id=%s kind=%s ok=%b (keeper=%s)"
        c.bg_run_id
        (Keeper_event_queue.bg_job_kind_to_string c.bg_kind)
        (match c.bg_outcome with
         | Keeper_event_queue.Bg_ok _ -> true
         | Keeper_event_queue.Bg_failed _ -> false)
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Schedule_due sw ->
      Log.Keeper.info
        "turn entry: scheduled wake delivered schedule_id=%s due_at=%.3f (keeper=%s)"
        sw.schedule_id
        sw.due_at
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Goal_assigned ga ->
      (* RFC-0315 P3 W0: a newly assigned standing objective is actionable
         work. Promote it to a pending observation so the assignment turn does
         not wake empty. *)
      Log.Keeper.info
        "turn entry: goal assignment delivered goal_id=%s assigned_by=%s (keeper=%s)"
        ga.ga_goal_id
        ga.ga_assigned_by
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Goal_reconciliation_ready ready ->
      Log.Keeper.info
        "turn entry: goal reconciliation ready goal_id=%s triggering_task_id=%s \
         (keeper=%s)"
        ready.gr_goal_id
        ready.gr_triggering_task_id
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Manual_compaction_requested ->
      Log.Keeper.info
        "turn entry: manual compaction request delivered (keeper=%s)"
        meta_after_triage.name;
      Stimulus_consumed []
    | Keeper_event_queue.Bootstrap ->
      Log.Keeper.info
        "turn entry: bootstrap stimulus consumed (keeper=%s)"
        meta_after_triage.name;
      Stimulus_consumed []
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
      Log.Keeper.info
        "turn entry: connector attention stimulus consumed event_id=%s (keeper=%s)"
        ca.event_id
        meta_after_triage.name;
      Stimulus_consumed pending_events
    | Keeper_event_queue.Hitl_resolved r ->
      (* The approval has left the queue, so this cycle no longer skips. There
         is no observation to fabricate: the typed resolution itself is
         threaded as cycle context. *)
      Log.Keeper.info
        "turn entry: hitl resolution delivered approval=%s decision=%s (keeper=%s)"
        r.approval_id
        (Keeper_event_queue.hitl_resolution_decision_to_string r.decision)
        meta_after_triage.name;
      Stimulus_consumed []
  in
  match intake_result with
  | Stimulus_retry_later _ -> intake_result
  | Stimulus_consumed _ ->
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
    intake_result
;;

let stimulus_ready_for_intake ~base_path (stimulus : Keeper_event_queue.stimulus) =
  match stimulus.payload with
  | Keeper_event_queue.Hitl_resolved resolution ->
    (match
       Keeper_approval_queue.get_pending_entry_for_workspace
         ~base_path
         ~id:resolution.approval_id
     with
     | Ok None -> true
     | Ok (Some _) | Error _ -> false)
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Bootstrap
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Bg_completed _
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Manual_compaction_requested
  | Keeper_event_queue.Goal_assigned _
  | Keeper_event_queue.Goal_reconciliation_ready _ ->
    true
;;

(* A selection can be ready to intake and still have nothing left for a turn to
   do, because the work it refers to settled elsewhere. Delivering one costs a
   full turn and leaves the entry at the queue head, so a turn that checkpoints
   instead of completing re-reads the same entry on the next cycle and the
   Keeper makes no progress for as long as that entry stays spent. Retire them
   here, before a turn is spent on them. *)
type spent_selection_reconciliation =
  | Selection_actionable
  | Spent_schedule_acknowledged
  | Spent_grant_replay_acknowledged

let reconcile_spent_selection ~config ~keeper_name selection =
  match selection.Keeper_event_queue.payload with
  | Schedule_due wake ->
    (* The schedule lock covers both the terminal read and queue ACK. A retry
       must start under the same lock, so either it starts first and this sees
       its non-terminal execution, or this removes the old wake first and the
       retry enqueues it again afterwards. *)
    Workspace_utils.with_file_lock config (Schedule_store.schedules_path config)
    @@ fun () ->
    (match Schedule_store.read_state_result config with
     | Error err ->
       Error
         ("schedule terminal reconciliation read failed: "
          ^ Schedule_store.read_error_to_string err)
     | Ok state ->
       (match
          Schedule_store.execution_for_occurrence
            state
            ~schedule_id:wake.schedule_id
            ~due_at:wake.due_at
            ~payload_digest:wake.payload_digest
        with
        | Some
            { Schedule_domain.status =
                ( Schedule_domain.Execution_succeeded
                | Schedule_domain.Execution_failed )
            ; _
            } ->
          (match
             Keeper_registry_event_queue.ack_pending_result
               ~base_path:config.Workspace_utils.base_path
               keeper_name
               ~selection
           with
           | Error message ->
             Error ("schedule terminal reconciliation ack failed: " ^ message)
           | Ok () -> Ok Spent_schedule_acknowledged)
        | Some
            { Schedule_domain.status =
                ( Schedule_domain.Execution_running
                | Schedule_domain.Execution_dispatched )
            ; _
            }
        | None ->
          Ok Selection_actionable))
  | Hitl_resolved
      { approval_id; decision = Keeper_event_queue.Hitl_approved; _ } ->
    (* An approved grant is one-shot, but consumption alone is not terminal:
       host replay consumes before running the effect, then durably records the
       outcome. If evidence or journal persistence fails after the effect,
       [Keeper_gate_replay] keeps the raw result in-process and needs this wake
       to repair publication without running the effect again.

       Retire only [consumed + durable outcome]. The transition to that state is
       monotonic, so the ACK cannot race a result becoming unavailable. A read
       error, an unconsumed grant, or a consumed grant without its outcome stays
       actionable. *)
    (match Keeper_approval_queue.approved_resolution_delivery
             ~base_path:config.Workspace_utils.base_path
             ~id:approval_id
     with
     | Ok
         { state = Keeper_approval_queue.Resolution_consumed
         ; replay_outcome = Some _
         ; _
         } ->
       (match
          Keeper_registry_event_queue.ack_pending_result
            ~base_path:config.Workspace_utils.base_path
            keeper_name
            ~selection
        with
        | Error message ->
           Error ("spent grant replay ack failed: " ^ message)
        | Ok () -> Ok Spent_grant_replay_acknowledged)
     | Ok
         { state =
             ( Keeper_approval_queue.Resolution_unconsumed
             | Keeper_approval_queue.Resolution_consumed )
         ; replay_outcome = None
         ; _
         }
     | Ok
         { state = Keeper_approval_queue.Resolution_unconsumed
         ; replay_outcome = Some _
         ; _
         }
     | Error _ ->
       Ok Selection_actionable)
  | Hitl_resolved
      { decision =
          ( Keeper_event_queue.Hitl_rejected _
          | Keeper_event_queue.Hitl_edited _ )
      ; _
      }
  | Board_signal _
  | Board_attention _
  | Bootstrap
  | Fusion_completed _
  | Bg_completed _
  | Connector_attention _
  | Manual_compaction_requested
  | Goal_assigned _
  | Goal_reconciliation_ready _ ->
    Ok Selection_actionable
;;

let heartbeat_event_intake
      ~ctx
      ~meta_after_triage
      ~pending_board_events
  =
(* RFC-0020 §3 Rule 4 — select at most one new Event Layer stimulus per
     turn. The queue chooses the earliest ready stimulus while preserving
     every skipped unready entry in place. Board, Connector, HITL, Schedule,
     Fusion, and Goal inputs therefore share one lane order instead of a
     payload-family priority hierarchy. *)
  let base_path = ctx.config.base_path in
  let keeper_name = meta_after_triage.name in
  let select_pending () =
    Keeper_registry_event_queue.peek_when_result
      ~base_path
      keeper_name
      ~ready:(stimulus_ready_for_intake ~base_path)
  in
  let rec select_pending_after_spent_reconciliation () =
    match select_pending () with
    | Error _ as error -> error
    | Ok None as empty -> empty
    | Ok (Some selection) ->
      (match
         reconcile_spent_selection ~config:ctx.config ~keeper_name selection
       with
       | Error message -> Error message
       | Ok Selection_actionable -> Ok (Some selection)
       | Ok Spent_schedule_acknowledged ->
         Log.Keeper.info
           "turn entry: acknowledged already-terminal scheduled occurrence \
            without duplicate turn keeper=%s"
           keeper_name;
         select_pending_after_spent_reconciliation ()
       | Ok Spent_grant_replay_acknowledged ->
         Log.Keeper.info
           "turn entry: acknowledged spent Gate grant replay without a turn \
            keeper=%s"
           keeper_name;
         select_pending_after_spent_reconciliation ())
  in
  let pending_selection = select_pending_after_spent_reconciliation () in
  let queued_observations, consumed_stimuli, pending_selection, event_queue_intake_error =
    match pending_selection with
    | Error message ->
      Log.Keeper.error
        "turn entry: event queue selection failed keeper=%s: %s"
        keeper_name
        message;
      [], [], None, Some (Pending_selection_failed message)
    | Ok None -> [], [], None, None
    | Ok (Some selection) ->
      (match
         consume_single_heartbeat_stimulus
           ~ctx
           ~meta_after_triage
           selection
       with
       | Stimulus_consumed observations ->
         observations, [ selection ], Some selection, None
       | Stimulus_retry_later unavailable ->
         [], [], Some selection, Some (Transient_board_read unavailable))
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
           (match event.Keeper_world_observation.event_kind with
            | Keeper_world_observation.Schedule_due ->
              Log.Keeper.info
                "turn entry: promoted scheduled work occurrence_id=%s keeper=%s"
                event.Keeper_world_observation.post_id
                meta_after_triage.name
            | Keeper_world_observation.Board_post_created
            | Keeper_world_observation.Board_comment_added
            | Keeper_world_observation.Board_reaction_changed _
            | Keeper_world_observation.Fusion_completed
            | Keeper_world_observation.Bg_completed
            | Keeper_world_observation.External_attention
            | Keeper_world_observation.Goal_assigned
            | Keeper_world_observation.Goal_reconciliation_ready ->
              Log.Keeper.info
                "turn entry: promoted queued observation post_id=%s keeper=%s"
                event.Keeper_world_observation.post_id
                meta_after_triage.name);
           event :: acc))
      pending_board_events
      (List.rev queued_observations)
  in
  { pending_board_events
  ; consumed_stimulus_count
  ; consumed_stimuli
  ; pending_selection
  ; event_queue_intake_error
  ; event_queue_triggers
  }
;;
