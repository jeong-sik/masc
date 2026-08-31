(** Event-Layer stimulus intake for the keeper heartbeat loop.

    Extracted from [keeper_heartbeat_loop.ml] (lines 375-553) as part of
    the godfile decomp campaign. Owns:

    - the [heartbeat_event_intake] record returned to the heartbeat loop;
    - per-class string labels used in Otel_metric_store and log lines;
    - per-stimulus consumption ([consume_single_heartbeat_stimulus]);
    - the top-level all-ready draining function ([heartbeat_event_intake])
      that admits one durable snapshot. *)

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
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Hitl_resolved _
  | Keeper_event_queue.Ask_answered _
  | Keeper_event_queue.Completion_authority_rejected _
  | Keeper_event_queue.Task_cancelled _
  | Keeper_event_queue.Workspace_message _
  | Keeper_event_queue.Delegate_completed _
  | Keeper_event_queue.Composition_completed _ ->
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
   retry; intake reads an immutable pending selection, so retaining it requires
   no mutation — only withholding consumption and ACK. *)
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
  pending_selection : Keeper_event_queue_state.pending_selection option;
  consumed_selections : Keeper_event_queue_state.pending_selection list;
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
       | Keeper_external_attention.Ignored _
       | Keeper_external_attention.Quarantined _ ->
         None)
;;

let event_queue_trigger_of_stimulus (stim : Keeper_event_queue.stimulus) =
  match stim.payload with
  | Keeper_event_queue.Bootstrap -> Some Keeper_world_observation.Bootstrap_stimulus
  | Keeper_event_queue.Schedule_due _ ->
    Some Keeper_world_observation.Scheduled_automation_stimulus
  | Keeper_event_queue.Connector_attention _ ->
    Some Keeper_world_observation.Connector_attention_stimulus
  | Keeper_event_queue.Ask_answered _ ->
    (* A dedicated turn_reason for the same reason the HITL one below has it:
       the prompt has to steer the keeper back to the question it asked, not
       let it proceed on its own state as if nothing came back. *)
    Some Keeper_world_observation.Ask_answered_stimulus
  | Keeper_event_queue.Hitl_resolved _ ->
    (* RFC-0320 W3b: give the HITL-resolution wake a dedicated turn_reason so
       the prompt can steer the keeper back to the originating conversation
       instead of silently proceeding on its own state. This changes only how
       the turn is described, not whether it runs. *)
    Some Keeper_world_observation.Hitl_resolved_stimulus
  | Keeper_event_queue.Board_signal _
  | Keeper_event_queue.Board_attention _
  | Keeper_event_queue.Fusion_completed _
  | Keeper_event_queue.Delegate_completed _
  | Keeper_event_queue.Composition_completed _ ->
    (* No dedicated turn_reason: like the other async-completion wakes, the
       stimulus itself forces the keeper to re-run its cycle and proceed on its
       own state. The answer travels in the Board Activity row, so the turn
       does not have to be named for the Keeper to read it. *)
    None
  | Keeper_event_queue.Completion_authority_rejected _ ->
    Some Keeper_world_observation.Completion_authority_rejection_stimulus
  (* Dedicated turn_reason: the author has to be able to tell a cancellation
     wake from an autonomous tick, otherwise the turn is indistinguishable from
     the 96%-of-turns scheduled channel and the cancellation reads as noise. *)
  | Keeper_event_queue.Task_cancelled _ ->
    Some Keeper_world_observation.Task_cancellation_stimulus
  (* Dedicated turn_reason: the transcript scan reports the same message as
     [Mention_pending] only while the row is still ahead of the ack watermark.
     The queue entry is the durable delivery, so the turn names it as such. *)
  | Keeper_event_queue.Workspace_message _ ->
    Some Keeper_world_observation.Workspace_message_stimulus
;;

let consume_single_heartbeat_stimulus
      ~(ctx : _ context)
      ~meta_after_triage
      ?connector_attention_items
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
    | Keeper_event_queue.Schedule_due sw ->
      Log.Keeper.info
        "turn entry: scheduled wake delivered schedule_id=%s due_at=%.3f (keeper=%s)"
        sw.schedule_id
        sw.due_at
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Completion_authority_rejected rejection ->
      Log.Keeper.info
        "turn entry: completion authority rejection delivered task_id=%s \
         verification_id=%s (keeper=%s)"
        rejection.car_task_id
        rejection.car_verification_id
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Task_cancelled cancellation ->
      Log.Keeper.info
        "turn entry: task cancellation delivered task_id=%s cancelled_by=%s \
         (keeper=%s)"
        cancellation.tc_task_id
        cancellation.tc_cancelled_by
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Ask_answered answered ->
      (* The ask_id is a pointer only; the answer stays in Keeper_ask_store.
         Load it here and promote it to a pending observation, the same split
         Connector_attention makes — a wake carrying no answer is one the
         Keeper cannot act on, which is how this feature went unused. *)
      let resolved =
        List.assoc_opt
          answered.ask_id
          (Keeper_ask_store.rows
             ~base_path:ctx.config.base_path
             ~keeper_name:meta_after_triage.name)
      in
      let pending_events =
        match resolved with
        | Some
            ( ask
            , Keeper_ask.Answered_by { answers; responder; answered_at } ) ->
          [ Keeper_world_observation.pending_board_event_of_ask_answer
              ~meta:meta_after_triage
              ~ask
              ~answers
              ~responder
              ~answered_at
          ]
        | Some (_, Keeper_ask.Open)
        | Some (_, Keeper_ask.Withdrawn_because _)
        | None ->
          (* The wake outlived what it pointed at, or the answer is not
             recorded. Say so rather than injecting a row about nothing. *)
          Log.Keeper.warn
            "ask answer stimulus has no recorded answer ask_id=%s (keeper=%s)"
            answered.ask_id
            meta_after_triage.name;
          []
      in
      Log.Keeper.info
        "turn entry: ask answer delivered ask_id=%s rows=%d (keeper=%s)"
        answered.ask_id
        (List.length pending_events)
        meta_after_triage.name;
      Stimulus_consumed pending_events
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
      let recorded_item =
        match connector_attention_items with
        | Some preloaded ->
          (* RFC-0377 P1-1: the caller already loaded every batch member's
             attention item in one scan (see
             [connector_attention_items_of_batch] below) — reuse it instead
             of re-scanning the whole event log for this one id. *)
          List.assoc_opt ca.event_id preloaded
        | None ->
          recorded_attention_item_by_event_id
            ~base_path:ctx.config.base_path
            ~keeper_name:meta_after_triage.name
            ~event_id:ca.event_id
      in
      let pending_events =
        match recorded_item with
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
    | Keeper_event_queue.Delegate_completed dc ->
      (* Same shape as [Fusion_completed]: a turn this Keeper asked another to
         run has ended, and the answer is surfaced as a pending_board_event so
         this turn acts on it. *)
      (* The level comes from the outcome: a delegation the asker is still
         waiting on that could not finish is not routine. *)
      (match dc.dc_terminal with
       | Keeper_event_queue.Delegate_failed _ -> Log.Keeper.warn
       | Keeper_event_queue.Delegate_replied _ | Keeper_event_queue.Delegate_no_reply -> Log.Keeper.info)
        "turn entry: delegation answer delivered operation_id=%s from=%s \
         outcome=%s (keeper=%s)"
        dc.dc_operation_id
        dc.dc_keeper
        (match dc.dc_terminal with
         | Keeper_event_queue.Delegate_replied _ -> "replied"
         | Keeper_event_queue.Delegate_no_reply -> "no_reply"
         | Keeper_event_queue.Delegate_failed _ -> "failed")
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Composition_completed cc ->
      (* Same shape as [Delegate_completed]: work this Keeper started and did
         not wait for has settled, surfaced as a pending_board_event so this
         turn acts on it instead of the Keeper having to remember the id. *)
      (match cc.cc_terminal with
       | Keeper_event_queue.Composition_failed _
       | Keeper_event_queue.Composition_cancelled _ -> Log.Keeper.warn
       | Keeper_event_queue.Composition_succeeded -> Log.Keeper.info)
        "turn entry: composition result delivered request_id=%s tool=%s \
         outcome=%s (keeper=%s)"
        cc.cc_request_id
        cc.cc_tool
        (match cc.cc_terminal with
         | Keeper_event_queue.Composition_succeeded -> "succeeded"
         | Keeper_event_queue.Composition_failed _ -> "failed"
         | Keeper_event_queue.Composition_cancelled _ -> "cancelled")
        meta_after_triage.name;
      pending_board_events_of_stimulus_result ~meta_after_triage stim
    | Keeper_event_queue.Workspace_message message ->
      (* The transcript row committed at the delivery boundary carries the
         content and the message lane reads it, so there is no observation to
         fabricate here — injecting one would put the same message in front of
         the keeper twice. *)
      Log.Keeper.info
        "turn entry: keeper message delivered request_id=%s from=%s (keeper=%s)"
        message.wmsg_request_id
        message.wmsg_from
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
  (* Nothing else has to settle first: the answer is already durable when the
     wake is enqueued. *)
  | Keeper_event_queue.Ask_answered _ -> true
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
  | Keeper_event_queue.Schedule_due _
  | Keeper_event_queue.Connector_attention _
  | Keeper_event_queue.Completion_authority_rejected _
  | Keeper_event_queue.Task_cancelled _
  | Keeper_event_queue.Workspace_message _
  | Keeper_event_queue.Delegate_completed _
  | Keeper_event_queue.Composition_completed _ ->
    true
;;

(* #28809: a ready [Hitl_resolved] may sit behind the stimulus that woke this
   turn — typically a redelivered workspace message whose own earlier turn
   deferred on that very approval. The resolution is durable truth in the
   approval journal, not queue-ordered content, so a turn may project it as
   cycle context without admitting it (the queue entry is untouched here).
   After the projected replay
   spends the grant, [reconcile_spent_selection] retires the still-queued
   entry without costing a turn. *)
let ready_hitl_resolution_peek ~base_path ~keeper_name =
  match Keeper_registry_event_queue.snapshot_result ~base_path keeper_name with
  | Error _ -> None
  | Ok pending ->
    List.find_map
      (fun (stimulus : Keeper_event_queue.stimulus) ->
         match stimulus.payload with
         | Keeper_event_queue.Hitl_resolved resolution ->
           if stimulus_ready_for_intake ~base_path stimulus
           then Some resolution
           else None
         | Keeper_event_queue.Board_signal _
         | Keeper_event_queue.Board_attention _
         | Keeper_event_queue.Bootstrap
         | Keeper_event_queue.Fusion_completed _
         | Keeper_event_queue.Schedule_due _
         | Keeper_event_queue.Connector_attention _
         | Keeper_event_queue.Ask_answered _
         | Keeper_event_queue.Completion_authority_rejected _
         | Keeper_event_queue.Task_cancelled _
         | Keeper_event_queue.Workspace_message _
         | Keeper_event_queue.Delegate_completed _
         | Keeper_event_queue.Composition_completed _ -> None)
      (Keeper_event_queue.to_list pending)
;;

(* A selection can be ready to intake and still have nothing left for a turn to
   do, because the work it refers to settled elsewhere. Delivering one costs a
   full turn and leaves the entry at the queue head, so a turn that checkpoints
   instead of completing re-reads the same entry on the next cycle and the
   Keeper makes no progress for as long as that entry stays spent. Retire them
   here, before a turn is spent on them. *)
type spent_selection_reconciliation =
  | Selection_actionable
  | Spent_grant_replay_acknowledged

let reconcile_spent_selection
      ~config
      ~keeper_name
      (selection : Keeper_event_queue_state.pending_selection)
  =
  match selection.source.Keeper_event_queue.payload with
  | Schedule_due _ -> Ok Selection_actionable
  | Hitl_resolved
      { approval_id; decision = Keeper_event_queue.Hitl_approved; _ } ->
    (* An approved grant is one-shot, but consumption alone is not terminal:
       host replay consumes before running the effect, then durably records the
       outcome. If evidence or journal persistence fails after the effect,
       [Keeper_gate_replay] keeps the raw result in-process and needs this wake
       to repair publication without running the effect again.

       Retire only [consumed + durable outcome + continuation receipt]. The
       final receipt is written after the replay-owning model turn completed or
       durably checkpointed; without it, a crash between effect journaling and
       model continuation must replay the evidence into a fresh turn instead of
       silently draining the wake. A read error, an unconsumed grant, or a
       consumed grant without its outcome stays actionable. *)
    (match Keeper_approval_queue.approved_resolution_delivery
             ~base_path:config.Workspace_utils.base_path
             ~id:approval_id
     with
     | Ok
         { request
         ; state = Keeper_approval_queue.Resolution_consumed
         ; replay_outcome = Some replay_outcome
         ; _
         } ->
       (match
          Keeper_approval_queue.ensure_resolution_chat_projection
            ~base_path:config.Workspace_utils.base_path
            ~keeper_name
            ~approval_id
            ~tool_name:(Some request.tool_name)
            ~decision:Keeper_approval_queue_rules_types.Decision.Approve
        with
        | Error message -> Error ("approval resolution projection failed: " ^ message)
        | Ok () ->
          (match
             Keeper_approval_queue.ensure_replay_chat_projection
               ~base_path:config.Workspace_utils.base_path
               ~keeper_name
               ~approval_id
               ~tool_name:(Some request.tool_name)
               ~outcome:replay_outcome
           with
           | Error message -> Error ("approval replay projection failed: " ^ message)
           | Ok () ->
             if
               not
                 (Keeper_approval_queue.continuation_chat_projection_present
                    ~base_path:config.Workspace_utils.base_path
                    ~keeper_name
                    ~approval_id)
             then Ok Selection_actionable
             else
               (match
                  Keeper_registry_event_queue.ack_pending_result
                    ~base_path:config.Workspace_utils.base_path
                    keeper_name
                    ~selection
                with
                | Error message ->
                  Error ("spent grant replay ack failed: " ^ message)
                | Ok () -> Ok Spent_grant_replay_acknowledged)))
     | Ok
         { request
         ; state =
             ( Keeper_approval_queue.Resolution_unconsumed
             | Keeper_approval_queue.Resolution_consumed )
         ; replay_outcome = None
         ; _
         }
     | Ok
         { request
         ; state = Keeper_approval_queue.Resolution_unconsumed
         ; replay_outcome = Some _
         ; _
         } ->
       (match
          Keeper_approval_queue.ensure_resolution_chat_projection
            ~base_path:config.Workspace_utils.base_path
            ~keeper_name
            ~approval_id
            ~tool_name:(Some request.tool_name)
            ~decision:Keeper_approval_queue_rules_types.Decision.Approve
        with
        | Ok () -> Ok Selection_actionable
        | Error message -> Error ("approval resolution projection failed: " ^ message))
     | Error _ ->
       (match
          Keeper_approval_queue.ensure_resolution_chat_projection
            ~base_path:config.Workspace_utils.base_path
            ~keeper_name
            ~approval_id
            ~tool_name:None
            ~decision:Keeper_approval_queue_rules_types.Decision.Approve
        with
        | Ok () -> Ok Selection_actionable
        | Error message -> Error ("approval resolution projection failed: " ^ message)))
  | Hitl_resolved
      { approval_id; decision = Keeper_event_queue.Hitl_rejected rationale; _ } ->
    (match
       Keeper_approval_queue.ensure_resolution_chat_projection
         ~base_path:config.Workspace_utils.base_path
         ~keeper_name
         ~approval_id
         ~tool_name:None
         ~decision:(Keeper_approval_queue_rules_types.Decision.Reject rationale)
     with
     | Ok () ->
       if
         not
           (Keeper_approval_queue.continuation_chat_projection_present
              ~base_path:config.Workspace_utils.base_path
              ~keeper_name
              ~approval_id)
       then Ok Selection_actionable
       else
         (match
            Keeper_registry_event_queue.ack_pending_result
              ~base_path:config.Workspace_utils.base_path
              keeper_name
              ~selection
          with
          | Error message ->
            Error ("rejected approval continuation ack failed: " ^ message)
          | Ok () -> Ok Spent_grant_replay_acknowledged)
     | Error message -> Error ("approval resolution projection failed: " ^ message))
  | Ask_answered _
  | Board_signal _
  | Board_attention _
  | Bootstrap
  | Fusion_completed _
  | Connector_attention _
  | Completion_authority_rejected _
  (* A committed cancellation cannot be undone or settled elsewhere, so the
     selection is always still worth a turn. *)
  | Task_cancelled _
  (* A committed workspace message cannot be withdrawn, so the selection stays
     worth a turn. *)
  | Workspace_message _
  (* An answer that has arrived cannot be un-sent, so the selection stays worth
     a turn. *)
  | Delegate_completed _
  (* A settled composition cannot un-settle, so the selection stays worth a
     turn. *)
  | Composition_completed _ ->
    Ok Selection_actionable
;;

let heartbeat_event_intake
      ~ctx
      ~meta_after_triage
      ~pending_board_events
  =
  (* RFC-event-queue-admit-all-ready — one turn observes every source that is
     ready in this durable snapshot. The queue is a wake/attention layer, not a
     second work tracker: admitting one row per turn made a steady arrival rate
     an unbounded backlog even while every Keeper remained alive.

     Connector attention keeps RFC-0377's conversation boundary: the
     first ready connector conversation is admitted as a whole, while rows for
     other conversations remain pending for their own routed turn. *)
  let base_path = ctx.config.base_path in
  let keeper_name = meta_after_triage.name in
  let connector_attention_event_id (s : Keeper_event_queue.stimulus) =
    match s.Keeper_event_queue.payload with
    | Keeper_event_queue.Connector_attention { event_id; _ } -> Some event_id
    | Keeper_event_queue.Board_signal _
    | Keeper_event_queue.Board_attention _
    | Keeper_event_queue.Bootstrap
    | Keeper_event_queue.Fusion_completed _
    | Keeper_event_queue.Schedule_due _
    | Keeper_event_queue.Hitl_resolved _
    | Keeper_event_queue.Ask_answered _
    | Keeper_event_queue.Completion_authority_rejected _
    | Keeper_event_queue.Task_cancelled _
    | Keeper_event_queue.Workspace_message _
    | Keeper_event_queue.Delegate_completed _
    | Keeper_event_queue.Composition_completed _ ->
      None
  in
  let ready_batch selections =
    let first_connector_conversation =
        List.find_map
          (fun (selection : Keeper_event_queue_state.pending_selection) ->
             if stimulus_ready_for_intake ~base_path selection.source
             then
               Keeper_event_queue.connector_attention_channel
                 selection.source.payload
             else None)
          selections
      in
      let hitl_selected = ref false in
      List.filter
        (fun (selection : Keeper_event_queue_state.pending_selection) ->
           stimulus_ready_for_intake ~base_path selection.source
           &&
           match selection.source.payload with
           | Keeper_event_queue.Hitl_resolved _ ->
             (* One tool bundle carries one exact cycle grant. Admitting two
                HITL resolutions would replay only the first while a completed
                turn ACKed both durable sources. Leave later resolutions queued
                for their own exact replay turn. *)
             if !hitl_selected
             then false
             else (
               hitl_selected := true;
               true)
           | _ ->
             (match
                Keeper_event_queue.connector_attention_channel
                  selection.source.payload,
                first_connector_conversation
              with
              | None, _ -> true
              | Some _, None -> false
              | Some channel, Some first_channel ->
                Keeper_continuation_channel.same_conversation
                  channel
                  first_channel))
        selections
  in
  let connector_attention_items_of_batch selections =
    let event_ids =
      List.filter_map
        (fun (selection : Keeper_event_queue_state.pending_selection) ->
           connector_attention_event_id selection.source)
        selections
    in
    match event_ids with
    | [] | [ _ ] -> None
    | _ :: _ :: _ ->
      Some
        (Keeper_external_attention.recorded_items_by_event_ids
           ~base_path
           ~keeper_name
           ~event_ids)
  in
  let is_board_source (selection : Keeper_event_queue_state.pending_selection) =
    match selection.source.payload with
    | Keeper_event_queue.Board_signal _ | Keeper_event_queue.Board_attention _ -> true
    | Keeper_event_queue.Ask_answered _
    | Keeper_event_queue.Bootstrap
    | Keeper_event_queue.Fusion_completed _
    | Keeper_event_queue.Schedule_due _
    | Keeper_event_queue.Connector_attention _
    | Keeper_event_queue.Hitl_resolved _
    | Keeper_event_queue.Completion_authority_rejected _
    | Keeper_event_queue.Task_cancelled _
    | Keeper_event_queue.Workspace_message _
    | Keeper_event_queue.Delegate_completed _
    | Keeper_event_queue.Composition_completed _ -> false
  in
  let consume_batch selections =
    let connector_attention_items =
      connector_attention_items_of_batch selections
    in
    let rec loop
          observations_rev
          stimuli_rev
          selections_rev
          first_withdrawn
          = function
      | [] ->
        ( List.rev observations_rev
        , List.rev stimuli_rev
        , List.rev selections_rev
        , first_withdrawn
        , None )
      | selection :: rest ->
        (match
           reconcile_spent_selection
             ~config:ctx.config
             ~keeper_name
             selection
         with
         | Error message ->
           ( List.rev observations_rev
           , List.rev stimuli_rev
           , List.rev selections_rev
           , first_withdrawn
           , Some (selection, Pending_selection_failed message) )
         | Ok Spent_grant_replay_acknowledged ->
           Log.Keeper.info
             "turn entry: acknowledged spent Gate grant replay without a turn \
              keeper=%s"
             keeper_name;
           loop observations_rev stimuli_rev selections_rev first_withdrawn rest
         | Ok Selection_actionable ->
           (match
              consume_single_heartbeat_stimulus
                ~ctx
                ~meta_after_triage
                ?connector_attention_items
                selection.source
            with
            | Stimulus_retry_later unavailable ->
              Log.Keeper.info
                "turn entry: withdrew transiently unavailable stimulus from this \
                 cycle keeper=%s: %s"
                keeper_name
                (Keeper_world_observation_board_signal.unavailable_to_string
                   unavailable);
              let first_withdrawn =
                match first_withdrawn with
                | None -> Some (selection, unavailable)
                | Some _ as kept -> kept
              in
              loop observations_rev stimuli_rev selections_rev first_withdrawn rest
            | Stimulus_consumed [] when is_board_source selection ->
              (* Permanent Board absence is terminal before dispatch. It is the
                 one safe empty-source ACK: the post id cannot become readable
                 later, while retaining it would reselect the same poison on
                 every snapshot. Transient failures take the arm above. *)
              (match
                 Keeper_registry_event_queue.ack_pending_result
                   ~base_path
                   keeper_name
                   ~selection
               with
               | Ok () ->
                 Log.Keeper.info
                   "turn entry: acknowledged Board stimulus with no remaining \
                    observation stimulus_id=%s keeper=%s"
                   selection.source.post_id
                   keeper_name;
                 loop observations_rev stimuli_rev selections_rev first_withdrawn rest
               | Error message ->
                 let detail =
                   "failed to acknowledge Board stimulus with no remaining \
                    observation: "
                   ^ message
                 in
                 ( List.rev observations_rev
                 , List.rev stimuli_rev
                 , List.rev selections_rev
                 , first_withdrawn
                 , Some (selection, Pending_selection_failed detail) ))
            | Stimulus_consumed observations ->
              loop
                (List.rev_append observations observations_rev)
                (selection.source :: stimuli_rev)
                (selection :: selections_rev)
                first_withdrawn
                rest))
    in
    loop [] [] [] None selections
  in
  let ( queued_observations
      , consumed_stimuli
      , consumed_selections
      , first_withdrawn
      , hard_error )
    =
    match
      Keeper_registry_event_queue.pending_selections_result
        ~base_path
        keeper_name
    with
    | Error message ->
      Log.Keeper.error
        "turn entry: event queue selection failed keeper=%s: %s"
        keeper_name
        message;
      [], [], [], None, Some (None, Pending_selection_failed message)
    | Ok selections ->
      let batch = ready_batch selections in
      let observations, stimuli, selections, withdrawn, error =
        consume_batch batch
      in
      ( observations
      , stimuli
      , selections
      , withdrawn
      , Option.map (fun (selection, error) -> Some selection, error) error )
  in
  let pending_selection =
    match consumed_selections, hard_error, first_withdrawn with
    | selection :: _, _, _ -> Some selection
    | [], Some (Some selection, _), _ -> Some selection
    | [], _, Some (selection, _) -> Some selection
    | [], (None | Some (None, _)), None -> None
  in
  let event_queue_intake_error =
    match hard_error, first_withdrawn with
    | Some (_, error), _ -> Some error
    | None, Some (_, unavailable) -> Some (Transient_board_read unavailable)
    | None, None -> None
  in
  let consumed_stimulus_count = List.length consumed_stimuli in
  let event_queue_triggers =
    List.filter_map event_queue_trigger_of_stimulus consumed_stimuli
    |> List.sort_uniq compare
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
           (match event.Keeper_world_observation.event_kind with
            | Keeper_world_observation.Schedule_due wake ->
              Log.Keeper.info
                "turn entry: promoted scheduled work schedule_id=%s \
                 occurrence_id=%s keeper=%s"
                wake.Keeper_event_queue.schedule_id
                event.Keeper_world_observation.post_id
                meta_after_triage.name
            | Keeper_world_observation.Board_post_created
            | Keeper_world_observation.Board_comment_added
            | Keeper_world_observation.Board_reaction_changed _
            | Keeper_world_observation.Board_vote_cast _
            | Keeper_world_observation.Fusion_completed
            | Keeper_world_observation.External_attention _
            | Keeper_world_observation.Completion_authority_rejected _
            | Keeper_world_observation.Task_cancelled _
            | Keeper_world_observation.Delegate_completed
            | Keeper_world_observation.Ask_answered_row
            | Keeper_world_observation.Composition_completed ->
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
  ; consumed_selections
  ; event_queue_intake_error
  ; event_queue_triggers
  }
;;
