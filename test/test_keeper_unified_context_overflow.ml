open Alcotest

module EC = Masc.Keeper_error_classify

(* Incident-bound probe fixture, not a catalog default. Keep the interval and
   expiry aligned with the evidence identified by [source_ref]. *)
let serving_constraint ?(expires_at_unix_s = 4_102_444_800) () =
  Llm_provider.Serving_constraint.make
    ~source_kind:Llm_provider.Serving_constraint.Probe
    ~source_ref:"probe://incident/2793"
    ~checked_at_unix_s:100
    ~confidence:Llm_provider.Serving_constraint.High
    ~expires_at_unix_s
    ~accepted_through:524298
    ~rejected_from:524299
    ()
  |> Result.get_ok

let input_capacity constraint_ reason =
  Agent_sdk.Error.Api
    (InputCapacity
       { message = "Context overflow: typed capacity"
       ; constraint_
       ; reason = Agent_sdk.Retry.Serving_constraint_rejected reason
       })

let test_is_context_overflow_only_for_overflow_errors () =
  check
    bool
    "ContextOverflow matches"
    true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check
    bool
    "ContextOverflow without limit"
    true
    (EC.is_context_overflow
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "NetworkError does not match"
    false
    (EC.is_context_overflow
       (Agent_sdk.Error.Api
          (NetworkError
             { message = "Connection_reset"
             ; kind = Llm_provider.Http_client.Connection_refused
             })));
  let rendered_only =
    Agent_sdk.Error.Internal
      "Context overflow: model_context_window_exceeded arbitrary provider text"
  in
  check bool "rendered internal text does not match" false
    (EC.is_context_overflow rendered_only);
  check bool "rendered internal text is not auto-recoverable" false
    (EC.is_auto_recoverable_turn_error rendered_only);
  let unrecognized_stop_reason =
    Agent_sdk.Error.Agent
      (UnrecognizedStopReason { reason = "model_context_window_exceeded" })
  in
  check bool "exact typed unrecognized stop reason matches" true
    (EC.is_context_overflow unrecognized_stop_reason);
  check bool "exact typed unrecognized stop reason is auto-recoverable" true
    (EC.is_auto_recoverable_turn_error unrecognized_stop_reason)
;;

let test_input_capacity_is_not_context_overflow () =
  let constraint_ = serving_constraint () in
  let capacity_error =
    input_capacity
      constraint_
      (Llm_provider.Serving_constraint.Boundary_unknown
         { input_tokens = 524299
         ; accepted_through = 524298
         ; rejected_from = None
         })
  in
  check
    bool
    "typed input capacity is not context overflow"
    false
    (EC.is_context_overflow capacity_error);
  check
    bool
    "typed input capacity emits no overflow event"
    true
    (Option.is_none
       (Masc.Keeper_unified_turn.context_overflow_event_of_error
          capacity_error))
;;

(* ContextOverflow is routed as an explicit recoverable turn failure after OAS
   has exhausted its own compaction retry. It must not rewrite Keeper lifecycle. *)
let test_context_overflow_is_auto_recoverable () =
  check
    bool
    "ContextOverflow is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error
       (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })))
;;

module Budget = Masc.Keeper_turn_runtime_budget

let request_body_too_large ~actual_bytes ~limit_bytes =
  Agent_sdk.Error.Api
    (InvalidRequest
       { message = "serialized request body exceeds the declared limit"
       ; reason = Agent_sdk.Retry.Request_body_too_large { actual_bytes; limit_bytes }
       })
;;

(* The byte axis used to fall through [| _ -> None] and produce no compaction
   request at all, so these two assertions are the ones that failed before. *)
let test_byte_axis_is_a_capacity_refusal () =
  (match
     Budget.capacity_refusal_of_error
       (request_body_too_large ~actual_bytes:2_000_000 ~limit_bytes:1_048_576)
   with
   | Some
       (Budget.Serialized_request_body
          { actual_bytes = 2_000_000; limit_bytes = 1_048_576 }) -> ()
   | Some (Budget.Serialized_request_body _) ->
     fail "the measured byte pair was not carried through"
   | Some (Budget.Provider_context_window _) ->
     fail "a byte refusal was classified on the token axis"
   | None -> fail "a declared-byte refusal was not classified as a capacity refusal");
  match
    Budget.capacity_refusal_of_error
      (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 }))
  with
  | Some (Budget.Provider_context_window { limit_tokens = Some 32768 }) -> ()
  | Some _ | None -> fail "the context window axis regressed"
;;

(* The projection feeding the cascade path publishes
   reason="provider_context_overflow" and the Sdk_context_window_exceeded blocker
   class, so admitting a byte refusal there would label it as a window exceedance. *)
let test_event_projection_admits_only_the_token_axis () =
  (match
     Budget.context_overflow_event_of_error
       (request_body_too_large ~actual_bytes:2_000_000 ~limit_bytes:1_048_576)
   with
   | None -> ()
   | Some _ -> fail "a byte refusal was projected as a context-overflow event");
  match
    Budget.context_overflow_event_of_error
      (Agent_sdk.Error.Api (ContextOverflow { message = "exceeded"; limit = None }))
  with
  | Some (Keeper_state_machine.Context_overflow_detected { limit_tokens = None }) -> ()
  | Some _ | None -> fail "the context overflow event projection regressed"
;;

let () =
  run
    "keeper_unified_context_overflow"
    [ ( "context_overflow"
      , [ test_case
            "is_context_overflow only matches ContextOverflow"
            `Quick
            test_is_context_overflow_only_for_overflow_errors
        ; test_case
            "context overflow is auto-recoverable"
            `Quick
            test_context_overflow_is_auto_recoverable
        ; test_case
            "input capacity is not context overflow"
            `Quick
            test_input_capacity_is_not_context_overflow
        ; test_case
            "declared-byte refusal is a capacity refusal"
            `Quick
            test_byte_axis_is_a_capacity_refusal
        ; test_case
            "event projection admits only the token axis"
            `Quick
            test_event_projection_admits_only_the_token_axis
        ] )
    ]
;;
