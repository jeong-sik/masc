open Types
open Agent_types

let sanitize_request_id_component value =
  let buf = Buffer.create (String.length value) in
  String.iter
    (fun ch ->
       match ch with
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> Buffer.add_char buf ch
       | '-' | '_' -> Buffer.add_char buf ch
       | _ -> Buffer.add_char buf '-')
    value;
  let raw = Buffer.contents buf |> String.lowercase_ascii in
  let trimmed = String.trim raw in
  if trimmed = "" then "agent" else trimmed
;;

let input_required_of_request
      ~agent_name
      ~turn
      ?created_at
      (req : Hooks.elicitation_request)
  =
  let created_at = Option.value created_at ~default:(Unix.gettimeofday ()) in
  let participant = sanitize_request_id_component agent_name in
  let created_ms = int_of_float (created_at *. 1000.0) in
  { Error.request_id = Printf.sprintf "%s-turn-%d-input-%d" participant turn created_ms
  ; participant_name = Some agent_name
  ; question = req.Hooks.question
  ; schema = req.schema
  ; timeout_s = req.timeout_s
  ; created_at
  }
;;

let runtime_input_request_of_input_required (req : Error.input_required) =
  { Runtime.request_id = req.request_id
  ; participant_name = req.participant_name
  ; question = req.question
  ; schema = req.schema
  ; timeout_s = req.timeout_s
  ; created_at = req.created_at
  }
;;

let runtime_response_to_hooks = function
  | Runtime.Input_answer json -> Hooks.Answer json
  | Runtime.Input_declined -> Hooks.Declined
  | Runtime.Input_timeout -> Hooks.Timeout
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

let apply_response ?metadata agent (req : Error.input_required) response =
  match message_of_response ?metadata ~question:req.question response with
  | None -> false
  | Some message ->
    update_state agent (fun state ->
      { state with messages = Util.snoc state.messages message });
    true
;;
