(* Runtime-stop and final-disposition domains remain distinct:
   [Runtime_agent.Completed] remains ["completed"] in runtime
   telemetry, while a terminal receipt projects it to canonical ["success"]. *)

module D = Masc.Keeper_turn_disposition
module Receipt = Masc.Keeper_execution_receipt_types

let failures = ref []
let check name cond = if not cond then failures := name :: !failures

let input_required_request () : Agent_sdk.Error.input_required =
  { request_id = "receipt-input-1"
  ; participant_name = None
  ; question = "Which repository?"
  ; schema = None
  ; timeout_s = None
  ; created_at = 1_000.0
  }

let () =
  let runtime_stop_wire = Receipt.stop_reason_to_string Runtime_agent.Completed in
  check
    (Printf.sprintf "runtime stop keeps completed wire (got %S)" runtime_stop_wire)
    (String.equal runtime_stop_wire "completed");
  let success_wire =
    Receipt.receipt_terminal_reason_code_of_stop_reason Runtime_agent.Completed
  in
  check
    (Printf.sprintf "terminal receipt emits canonical success (got %S)" success_wire)
    (String.equal success_wire "success");
  check
    "canonical success round-trips as Success"
    (D.is_success (D.of_wire success_wire));
  check
    "runtime completed is not a final disposition"
    (match D.of_wire "completed" with
     | D.Unknown _ -> true
     | _ -> false);
  check
    "whitespace success is not silently normalized"
    (match D.of_wire " success " with
     | D.Unknown _ -> true
     | _ -> false);
  check
    "uppercase legacy spelling is not silently normalized"
    (match D.of_wire "COMPLETED" with
     | D.Unknown _ -> true
     | _ -> false);
  check
    "runtime-attempt completion keeps its distinct typed wire"
    (String.equal
       (Receipt.runtime_outcome_to_string Receipt.Runtime_completed)
       "completed");
  let input_required_stop =
    Runtime_agent.InputRequired
      { turns_used = 2; request = input_required_request () }
  in
  let input_required_wire = Receipt.stop_reason_to_string input_required_stop in
  check
    "runtime input-required stop uses the typed disposition wire"
    (String.equal input_required_wire "input_required");
  let input_required_terminal =
    Receipt.receipt_terminal_reason_code_of_stop_reason input_required_stop
  in
  check
    "terminal receipt preserves input-required instead of success"
    (match D.of_wire input_required_terminal with
     | D.Input_required -> true
     | _ -> false);
  match !failures with
  | [] -> print_endline "test_keeper_execution_receipt_observation_wire: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d disposition-wire contract assertion(s) failed" (List.length xs))
;;
