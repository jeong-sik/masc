open Types

let input_required_of_request
      ~agent_name
      ?created_at
      (req : Hooks.elicitation_request)
  =
  let created_at = Option.value created_at ~default:(Unix.gettimeofday ()) in
  { Error.request_id = Event_bus.fresh_id ()
  ; participant_name = Some agent_name
  ; question = req.Hooks.question
  ; schema = req.schema
  ; timeout_s = req.timeout_s
  ; created_at
  }
;;

let message_of_response ?(metadata = []) ~question = function
  | Hooks.Answer json ->
    let text =
      Printf.sprintf "[User input] %s: %s" question (Yojson.Safe.to_string json)
    in
    Some
      { role = User; content = [ Text text ]; name = None; tool_call_id = None; metadata }
  | Hooks.Declined | Hooks.Timeout -> None
;;

let apply_response ?metadata agent supplied response =
  Agent_input_checkpoint.respond agent supplied
    ~message:(fun owned ->
      message_of_response ?metadata ~question:owned.request.question response)
;;
