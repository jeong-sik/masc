(** Response text finalization for keeper agent runs. *)

type finalized = {
  response_text : string;
  withheld_from_replay : bool;
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
  let withheld_from_replay =
    match suppress_response_text with
    | Some suppress -> suppress
    | None -> control_checkpoint
  in
  { response_text = String.trim raw_response_text; withheld_from_replay }
;;
