(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
}

let stop_reason_suppresses_visible_response = function
  | Runtime_agent.Yielded_to_operation_queued _
  | Runtime_agent.Yielded_to_durable_stimulus _
  | Runtime_agent.Yielded_after_repeated_tool_call _
  | Runtime_agent.Yielded_after_repeated_assistant_text _
  | Runtime_agent.Awaiting_external_effect _ ->
    true
  | Runtime_agent.Completed
  | Runtime_agent.InputRequired _ ->
    false
;;

let finalize ~stop_reason ~raw_response_text ?suppress_response_text ()
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
