(** Response text and [STATE] snapshot finalization for keeper agent runs. *)

type finalized = {
  state_snapshot : Keeper_memory_policy.keeper_state_snapshot;
  state_snapshot_source : Keeper_memory_policy.state_snapshot_source;
  response_text : string;
}

let stop_reason_label = function
  | Runtime_agent.Completed -> "completed"
  | Runtime_agent.TurnBudgetExhausted _ -> "budget_exhausted"
  | Runtime_agent.MutationBoundaryReached { tool_name; _ } ->
    (match tool_name with
     | Some tool -> Printf.sprintf "mutation_boundary(%s)" tool
     | None -> "mutation_boundary")
  | Runtime_agent.Yielded_to_chat_waiting _ -> "yielded_to_chat_waiting"
;;

let stop_reason_is_turn_budget_exhausted = function
  | Runtime_agent.TurnBudgetExhausted _ -> true
  | Runtime_agent.Completed
  | Runtime_agent.MutationBoundaryReached _
  | Runtime_agent.Yielded_to_chat_waiting _ -> false
;;

let direct_assistant_source = "direct_assistant"

let completion_contract_suppresses_visible_response
      ~history_assistant_source
  = function
  | Keeper_execution_receipt.Contract_passive_only ->
    not (String.equal history_assistant_source direct_assistant_source)
  | result ->
    Keeper_execution_receipt.completion_contract_result_requires_attention result
;;

let state_snapshot ~reported_state_snapshot ~keeper_name ~goal ~actual_keeper_tool_names
      ~stop_reason ~raw_response_text
      ()
  =
  match reported_state_snapshot with
  | Some snapshot -> (snapshot, Keeper_memory_policy.Structured_state_tool)
  | None ->
    (match
       Keeper_memory_policy.parse_structured_state_snapshot_from_reply
         raw_response_text
     with
     | Some snapshot -> (snapshot, Keeper_memory_policy.Structured_state_reply)
     | None ->
       (match Keeper_memory_policy.parse_state_snapshot_from_reply raw_response_text with
        | Some snapshot -> (snapshot, Keeper_memory_policy.State_block)
        | None ->
          let stop_reason_str = stop_reason_label stop_reason in
          let synth =
            Keeper_memory_policy.synthesize_state_from_run_result
              ~goal
              ~tools_used:actual_keeper_tool_names
              ~stop_reason:stop_reason_str
              ~response_text:raw_response_text
          in
          Log.Keeper.info ~keeper_name:keeper_name
            "state metadata missing, synthesized from %d tools (stop=%s)"
            (List.length actual_keeper_tool_names)
            stop_reason_str;
          (synth, Keeper_memory_policy.Synthesized)))
;;

let response_text ~state_snapshot_source ~raw_response_text =
  match (state_snapshot_source : Keeper_memory_policy.state_snapshot_source) with
  | Structured_state_reply -> ""
  | Synthesized | Structured_state_tool | State_block ->
    Keeper_text_processing.strip_internal_reply_markup raw_response_text
;;

let finalize ~reported_state_snapshot ~keeper_name ~goal ~actual_keeper_tool_names
      ~completion_contract_result ~stop_reason ~raw_response_text
      ?suppress_response_text
      ()
  =
  let budget_exhausted = stop_reason_is_turn_budget_exhausted stop_reason in
  let contract_requires_attention =
    Keeper_execution_receipt.completion_contract_result_requires_attention
      completion_contract_result
  in
  let suppress_response_text =
    match suppress_response_text with
    | Some suppress -> suppress
    | None -> budget_exhausted || contract_requires_attention
  in
  let raw_response_text = if suppress_response_text then "" else raw_response_text in
  let state_snapshot, state_snapshot_source =
    state_snapshot
      ~reported_state_snapshot
      ~keeper_name
      ~goal
      ~actual_keeper_tool_names
      ~stop_reason
      ~raw_response_text
      ()
  in
  let response_text =
    response_text ~state_snapshot_source ~raw_response_text
  in
  { state_snapshot
  ; state_snapshot_source
  ; response_text = if suppress_response_text then "" else response_text
  }
;;
