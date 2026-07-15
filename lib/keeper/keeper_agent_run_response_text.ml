(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
}

let stop_reason_suppresses_visible_response = function
  | Runtime_agent.ExecutionTimeoutObserved _
  | Runtime_agent.ExecutionIdleTimeoutObserved _
  | Runtime_agent.Yielded_to_chat_waiting _
  | Runtime_agent.Yielded_to_durable_stimulus _ -> true
  | Runtime_agent.Completed
  | Runtime_agent.TurnLimitObserved _
  | Runtime_agent.InputRequired _ ->
    false
;;

let finalize ~completion_contract_result:_ ~stop_reason ~raw_response_text
      ?suppress_response_text
      ()
  =
  let control_checkpoint = stop_reason_suppresses_visible_response stop_reason in
  let suppress_response_text =
    match suppress_response_text with
    | Some suppress -> suppress
    | None -> control_checkpoint
  in
  let raw_response_text = if suppress_response_text then "" else raw_response_text in
  let response_text = String.trim raw_response_text in
  { response_text = if suppress_response_text then "" else response_text }
;;
