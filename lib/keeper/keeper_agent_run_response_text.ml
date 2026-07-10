(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
}

let stop_reason_is_turn_budget_exhausted = function
  | Runtime_agent.TurnBudgetExhausted _ -> true
  | Runtime_agent.Completed
  | Runtime_agent.MutationBoundaryReached _
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_to_blocking_approval _ -> false
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

let finalize ~completion_contract_result ~stop_reason ~raw_response_text
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
  let response_text =
    Keeper_text_processing.strip_internal_reply_markup raw_response_text
  in
  { response_text = if suppress_response_text then "" else response_text }
;;
