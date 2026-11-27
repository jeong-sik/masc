type skip_reason =
  | Context_only_after_persisted_messages
  | Context_only_after_skipped_tool_results
  | Within_min_interval of
      { elapsed_sec : float
      ; min_interval_sec : float
      }

type decision =
  | Persist
  | Skip of skip_reason

type state =
  { mutable last_persisted_messages : Agent_core.Types.message list option
  ; mutable last_skipped_tool_results_messages : Agent_core.Types.message list option
  ; mutable last_mid_turn_save_s : float option
  ; mutable pending_deferred : (Agent_core.Agent.checkpoint_stage * Agent_core.Checkpoint.t) option
  }

let create () =
  { last_persisted_messages = None
  ; last_skipped_tool_results_messages = None
  ; last_mid_turn_save_s = None
  ; pending_deferred = None
  }

let observe_assistant_stop_reason state ~(stop_reason : Llm_provider.Types.stop_reason) =
  match stop_reason with
  | Llm_provider.Types.StopToolUse -> ()
  | EndTurn | MaxTokens | StopSequence | Refusal | ContentFilter
  | RepetitionTruncation | PauseTurn | Compaction | ContextWindowExceeded
  | UnmatchedToolCalls | Unknown _ ->
    (* Non-tool stop reasons end the attempt or enter truncation recovery
       ([Retry_without_thinking]), which needs a fresh pacing budget. *)
    state.last_mid_turn_save_s <- None

(* Physical equality on [messages] is sufficient for [After_context_injection]
   because [Agent_turn.apply_context_injection] (in [pipeline.ml]) only mutates
   [agent.context] and replaces [agent.state.messages] (returning the original
   [messages] list when [extra_messages = []]); it never modifies
   [working_context], [pending_input], or other checkpoint fields, and
   [Keeper_agent_run] stamps [working_context] from the turn-constant
   [checkpoint_sidecar]. [Masc_context_injector.make] emits [extra_messages = []]
   and writes only in-memory [session:*] telemetry keys into [agent.context]. *)
let same_messages_opt expected (checkpoint : Agent_core.Checkpoint.t) =
  match expected with
  | Some previous -> previous == checkpoint.messages
  | None -> false

let throttling_active min_interval_sec =
  Float.is_finite min_interval_sec && min_interval_sec > 0.0

let interval_decision state ~now_s ~min_interval_sec =
  if not (throttling_active min_interval_sec) then Persist
  else
    match state.last_mid_turn_save_s with
    | None -> Persist
    | Some last_s ->
      let elapsed_sec = Float.max 0.0 (now_s -. last_s) in
      if elapsed_sec >= min_interval_sec then Persist
      else Skip (Within_min_interval { elapsed_sec; min_interval_sec })

let decide state ~(stage : Agent_core.Agent.checkpoint_stage) ~checkpoint ~now_s ~min_interval_sec =
  match stage with
  | Agent_core.Agent.After_input_wait_changed
  | After_rejected_response_dropped ->
    state.last_skipped_tool_results_messages <- None;
    Persist
  | After_context_injection ->
    if same_messages_opt state.last_persisted_messages checkpoint then
      Skip Context_only_after_persisted_messages
    else if same_messages_opt state.last_skipped_tool_results_messages checkpoint then (
      (* Refresh deferred payload with the newest context while preserving the
         [After_tool_results_appended] stage witness for an error-path flush. *)
      state.pending_deferred <- Some (Agent_core.Agent.After_tool_results_appended, checkpoint);
      Skip Context_only_after_skipped_tool_results)
    else
      (match interval_decision state ~now_s ~min_interval_sec with
       | Persist -> Persist
       | Skip _ as skip ->
         state.pending_deferred <- Some (stage, checkpoint);
         skip)
  | After_assistant_collected ->
    (* Always persist assistant turns, including open [ToolUse] cycles under
       [StopToolUse]: a crash, OOM, or [SIGKILL] before
       [After_tool_results_appended] relies on this checkpoint so boot recovery
       and [Pipeline_execution_resume] see the in-flight [ToolUse] message
       rather than failing closed or reissuing side effects. *)
    state.last_skipped_tool_results_messages <- None;
    Persist
  | After_tool_results_appended ->
    (match interval_decision state ~now_s ~min_interval_sec with
     | Persist ->
       state.last_skipped_tool_results_messages <- None;
       Persist
     | Skip _ as skip ->
       state.last_skipped_tool_results_messages <- Some checkpoint.messages;
       state.pending_deferred <- Some (stage, checkpoint);
       skip)

let record_persisted state ~(stage : Agent_core.Agent.checkpoint_stage) ~checkpoint ~now_s =
  state.last_persisted_messages <- Some checkpoint.Agent_core.Checkpoint.messages;
  state.last_skipped_tool_results_messages <- None;
  state.pending_deferred <- None;
  match stage with
  | Agent_core.Agent.After_rejected_response_dropped ->
    state.last_mid_turn_save_s <- None
  | After_tool_results_appended | After_context_injection ->
    state.last_mid_turn_save_s <- Some now_s
  | After_input_wait_changed | After_assistant_collected ->
    ()

let take_deferred state =
  let deferred = state.pending_deferred in
  state.pending_deferred <- None;
  deferred

let skip_reason_to_string = function
  | Context_only_after_persisted_messages -> "context_only_after_persisted_messages"
  | Context_only_after_skipped_tool_results -> "context_only_after_skipped_tool_results"
  | Within_min_interval { elapsed_sec; min_interval_sec } ->
    Printf.sprintf "within_min_interval(elapsed_s=%.2f,min_s=%.2f)" elapsed_sec min_interval_sec
