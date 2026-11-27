type skip_reason =
  | Context_only_after_persisted_messages
  | Context_only_after_skipped_tool_results
  | Deferred_until_tool_results
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
  ; mutable last_assistant_stop_reason : Llm_provider.Types.stop_reason option
  ; mutable last_mid_turn_save_s : float option
  ; mutable pending_deferred : (Agent_core.Agent.checkpoint_stage * Agent_core.Checkpoint.t) option
  }

let create () =
  { last_persisted_messages = None
  ; last_skipped_tool_results_messages = None
  ; last_assistant_stop_reason = None
  ; last_mid_turn_save_s = None
  ; pending_deferred = None
  }

let block_is_tool_use (block : Agent_core.Types.content_block) =
  match block with
  | ToolUse _ -> true
  | Text _ | Thinking _ | ReasoningDetails _ | RedactedThinking _
  | ToolReference _ | ToolResult _ | Image _ | Document _ | Audio _ -> false

let rec last_message = function
  | [] -> None
  | [ msg ] -> Some msg
  | _ :: rest -> last_message rest

let checkpoint_has_pending_tool_use (checkpoint : Agent_core.Checkpoint.t) =
  match last_message checkpoint.messages with
  | None -> false
  | Some (msg : Agent_core.Types.message) ->
    (match msg.role with
     | Agent_core.Types.Assistant -> List.exists block_is_tool_use msg.content
     | System | User | Tool -> false)

let observe_assistant_stop_reason state ~(stop_reason : Llm_provider.Types.stop_reason) =
  state.last_assistant_stop_reason <- Some stop_reason;
  match stop_reason with
  | Llm_provider.Types.StopToolUse -> ()
  | EndTurn | MaxTokens | StopSequence | Refusal | ContentFilter
  | RepetitionTruncation | PauseTurn | Compaction | ContextWindowExceeded
  | UnmatchedToolCalls | Unknown _ ->
    (* Non-tool stop reasons end the attempt or enter truncation recovery
       ([Retry_without_thinking]), which needs a fresh pacing budget. *)
    state.last_mid_turn_save_s <- None

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

let stop_reason_executes_tools = function
  | Some Llm_provider.Types.StopToolUse -> true
  | Some
      ( EndTurn | MaxTokens | StopSequence | Refusal | ContentFilter
      | RepetitionTruncation | PauseTurn | Compaction | ContextWindowExceeded
      | UnmatchedToolCalls | Unknown _ )
  | None ->
    false

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
    let observed_stop_reason = state.last_assistant_stop_reason in
    state.last_assistant_stop_reason <- None;
    state.last_skipped_tool_results_messages <- None;
    let will_execute_tools =
      stop_reason_executes_tools observed_stop_reason
      && checkpoint_has_pending_tool_use checkpoint
    in
    if not will_execute_tools then
      Persist
    else if throttling_active min_interval_sec then
      Skip Deferred_until_tool_results
    else
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
  | Deferred_until_tool_results -> "deferred_until_tool_results"
  | Within_min_interval { elapsed_sec; min_interval_sec } ->
    Printf.sprintf "within_min_interval(elapsed_s=%.2f,min_s=%.2f)" elapsed_sec min_interval_sec
