(* Producer contract for non-gating runtime stop observations.

   Runtime stop metadata and the MASC terminal disposition are distinct axes.
   An unexpected OAS turn-limit observation remains visible in [stop_reason]
   while [terminal_reason_code] stays canonical success: it must not create a
   Keeper blocker, checkpoint, claim veto, or operator follow-up action. *)

(* The same boundary must keep runtime-stop and final-disposition domains
   distinct: [Runtime_agent.Completed] remains ["completed"] in runtime
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
  let turns_used = 1070 and limit = 1070 in
  let observation_wire =
    Receipt.stop_reason_to_string
      (Runtime_agent.TurnLimitObserved { turns_used; limit })
  in
  check
    (Printf.sprintf "turn-limit fact remains an observation (got %S)" observation_wire)
    (String.equal
       observation_wire
       (Printf.sprintf "turn_limit_observed:turns=%d,limit=%d" turns_used limit));
  let terminal_wire =
    Receipt.receipt_terminal_reason_code_of_stop_reason
      (Runtime_agent.TurnLimitObserved { turns_used; limit })
  in
  check
    (Printf.sprintf "turn-limit observation is non-gating (got %S)" terminal_wire)
    (String.equal terminal_wire "success");
  check
    "turn-limit observation projects to successful MASC disposition"
    (D.is_success (D.of_wire terminal_wire));
  let timeout_observations =
    [ ( Runtime_agent.ExecutionTimeoutObserved
          { elapsed_sec = 300.0
          ; timeout_sec = 300.0
          ; turn_count = 7
          ; max_turns = Runtime_agent_context.unbounded_max_turns
          }
      , Printf.sprintf
          "execution_timeout_observed:elapsed_sec=300.0,timeout_sec=300.0,turn_count=7,max_turns=%d"
          Runtime_agent_context.unbounded_max_turns )
    ; ( Runtime_agent.ExecutionIdleTimeoutObserved
          { idle_sec = 120.0
          ; idle_timeout_sec = 120.0
          ; turn_count = 7
          ; max_turns = Runtime_agent_context.unbounded_max_turns
          }
      , Printf.sprintf
          "execution_idle_timeout_observed:idle_sec=120.0,idle_timeout_sec=120.0,turn_count=7,max_turns=%d"
          Runtime_agent_context.unbounded_max_turns )
    ]
  in
  List.iter
    (fun (stop_reason, expected_observation) ->
       check
         "execution timeout keeps typed observation metadata"
         (String.equal (Receipt.stop_reason_to_string stop_reason) expected_observation);
       let terminal = Receipt.receipt_terminal_reason_code_of_stop_reason stop_reason in
       check
         "execution timeout observation has no terminal authority"
         (D.is_success (D.of_wire terminal)))
    timeout_observations;
  match !failures with
  | [] -> print_endline "test_keeper_execution_receipt_observation_wire: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d disposition-wire contract assertion(s) failed" (List.length xs))
;;
