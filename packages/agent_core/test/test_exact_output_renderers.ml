(* Leaf renderers of the exact-output error family (#27861). Every
   constructor is rendered at least once, and every numeric field must
   appear in the line: the numbers are what separate a local capacity
   refusal from a provider failure. The flow-level renderer is checked
   against real terminal flows in test_exact_output_flow. *)

open Alcotest
module EO = Agent_core.Exact_output
module Http = Llm_provider.Http_client

let check_cases name render cases =
  List.iter (fun (value, expected) -> check string name expected (render value)) cases
;;

let token_capacity_rejections : (EO.token_capacity_rejection * string) list =
  [ ( EO.Capacity_evidence_not_yet_valid
        { now_unix_s = 1700000000; checked_at_unix_s = 1700000050 }
    , "capacity evidence not yet valid (now=1700000000 checked_at=1700000050)" )
  ; ( EO.Capacity_evidence_expired
        { now_unix_s = 1700000100; expires_at_unix_s = 1700000000 }
    , "capacity evidence expired (now=1700000100 expires_at=1700000000)" )
  ; ( EO.Capacity_boundary_unknown
        { input_tokens = 5000; accepted_through_tokens = 4096; rejected_from_tokens = None }
    , "capacity boundary unknown (input=5000 accepted_through=4096 rejected_from=unknown)"
    )
  ; ( EO.Capacity_boundary_unknown
        { input_tokens = 5000
        ; accepted_through_tokens = 4096
        ; rejected_from_tokens = Some 8192
        }
    , "capacity boundary unknown (input=5000 accepted_through=4096 rejected_from=8192)" )
  ; ( EO.Capacity_input_rejected
        { input_tokens = 9000; accepted_through_tokens = 4096; rejected_from_tokens = 8192 }
    , "capacity input rejected (input=9000 accepted_through=4096 rejected_from=8192)" )
  ]
;;

let test_token_capacity_rejection () =
  check_cases
    "token capacity rejection"
    EO.token_capacity_rejection_to_string
    token_capacity_rejections
;;

let test_input_capacity_disposition () =
  let direct : (EO.input_capacity_disposition * string) list =
    [ ( EO.Token_measurement_required
          { accepted_through_tokens = 4096; rejected_from_tokens = Some 8192 }
      , "token measurement required (accepted_through=4096 rejected_from=8192)" )
    ; ( EO.Token_measurement_required
          { accepted_through_tokens = 4096; rejected_from_tokens = None }
      , "token measurement required (accepted_through=4096 rejected_from=unknown)" )
    ; ( EO.Context_window_exceeded
          { input_tokens = 9000; reserved_output_tokens = 2000; max_context_tokens = 8192 }
      , "context window exceeded (input=9000 reserved_output=2000 max_context=8192)" )
    ]
  in
  let wrapped =
    List.map
      (fun (rejection, expected) ->
         (EO.Token_capacity_rejected rejection : EO.input_capacity_disposition), expected)
      token_capacity_rejections
  in
  check_cases
    "input capacity disposition"
    EO.input_capacity_disposition_to_string
    (direct @ wrapped)
;;

let test_candidate_rejection_disposition () =
  let cases : (EO.candidate_rejection_disposition * string) list =
    [ EO.Runtime_slot_unavailable, "runtime slot unavailable"
    ; EO.Runtime_contract_rejected, "runtime contract rejected"
    ; EO.Input_contract_rejected, "input contract rejected"
    ; EO.Output_requirement_rejected, "output requirement rejected"
    ; ( EO.Input_capacity
          (EO.Context_window_exceeded
             { input_tokens = 9000; reserved_output_tokens = 2000; max_context_tokens = 8192 })
      , "context window exceeded (input=9000 reserved_output=2000 max_context=8192)" )
    ; EO.Request_preparation_failed, "request preparation failed"
    ]
  in
  check_cases
    "candidate rejection disposition"
    EO.candidate_rejection_disposition_to_string
    cases
;;

let test_execution_error_cause () =
  let cases : (EO.execution_error_cause * string) list =
    [ EO.Attempt_already_started, "attempt already started"
    ; EO.Clock_required_for_timeout, "clock required for timeout"
    ; EO.Frozen_request_mismatch, "frozen request mismatch"
    ; ( EO.Completion_failed
          { error = Http.NetworkError { message = "resolve failed"; kind = Http.Dns_failure }
          ; dispatch = EO.No_generation_dispatch
          }
      , "completion failed (network_error:dns_failure, not sent)" )
    ; ( EO.Completion_failed
          { error =
              Http.HttpError
                { code = 503; body = Http.Received ""; retry_after_header = None }
          ; dispatch = EO.Generation_dispatch_started
          }
      , "completion failed (http_status=503, sent)" )
    ; ( EO.Response_body_deadline_exceeded
      , "total request deadline exceeded while reading response body" )
    ; ( EO.Provider_response_refused { http_status = 429; refusal = EO.Rate_limited }
      , "provider refused (http_status=429 refusal=rate_limited)" )
    ; EO.Incomplete_output, "incomplete output"
    ; EO.Missing_output, "missing output"
    ; EO.Ambiguous_output 3, "ambiguous output (candidates=3)"
    ; EO.Unexpected_output_content, "unexpected output content"
    ; EO.Invalid_json_output, "invalid json output"
    ; EO.Internal_non_json_output, "internal non-json output"
    ]
  in
  check_cases "execution error cause" EO.execution_error_cause_to_string cases
;;

let test_start_errors () =
  check
    string
    "start attempt error"
    "call_id_generation_failed detail=\"random source unavailable\""
    (EO.start_attempt_error_to_string
       (EO.Call_id_generation_failed "random source unavailable"));
  check_cases
    "measurement start error"
    EO.measurement_start_error_to_string
    [ ( EO.Measurement_operation_id_generation_failed "operation id unavailable"
      , "operation_id_generation_failed detail=\"operation id unavailable\"" )
    ; ( EO.Measurement_clock_required_for_timeout
      , "measurement_clock_required_for_timeout" )
    ]
;;

let () =
  run
    "exact_output_renderers"
    [ ( "renderers"
      , [ test_case "token capacity rejection" `Quick test_token_capacity_rejection
        ; test_case "input capacity disposition" `Quick test_input_capacity_disposition
        ; test_case
            "candidate rejection disposition"
            `Quick
            test_candidate_rejection_disposition
        ; test_case "execution error cause" `Quick test_execution_error_cause
        ; test_case "start errors" `Quick test_start_errors
        ] )
    ]
;;
