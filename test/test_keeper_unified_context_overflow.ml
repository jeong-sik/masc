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
  Agent_core.Error.Api
    (InputCapacity
       { message = "Context overflow: typed capacity"
       ; constraint_
       ; reason = Agent_core.Retry.Serving_constraint_rejected reason
       })

let measurement_unavailable constraint_ =
  Agent_core.Error.Api
    (InputCapacity
       { message = "token measurement unavailable"
       ; constraint_
       ; reason =
           Agent_core.Retry.Token_measurement_unavailable
             Llm_provider.Input_token_count.Anthropic_messages_count_tokens
       })

let is_provider_context_overflow error =
  let module E = Masc.Keeper_unified_turn_execution.For_testing in
  match E.declared_lane_failure_of_error error with
  | E.Provider_context_overflow -> true
  | E.Declared_runtime_lane_exhausted -> false

let test_only_a_typed_context_overflow_is_a_provider_overflow () =
  check
    bool
    "ContextOverflow matches"
    true
    (is_provider_context_overflow
       (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check
    bool
    "ContextOverflow without limit"
    true
    (is_provider_context_overflow
       (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "NetworkError does not match"
    false
    (is_provider_context_overflow
       (Agent_core.Error.Api
          (NetworkError
             { message = "Connection_reset"
             ; kind = Llm_provider.Http_client.Connection_reset
             })));
  let rendered_only =
    Agent_core.Error.Internal
      "Context overflow: model_context_window_exceeded arbitrary provider text"
  in
  check bool "rendered internal text does not match" false
    (is_provider_context_overflow rendered_only);
  check bool "rendered internal text is not auto-recoverable" false
    (EC.is_auto_recoverable_turn_error rendered_only);
  (* [Error.Agent (UnrecognizedStopReason _)] is never a context overflow here,
     whatever token it carries. Both an unmodeled provider token and an overflow
     token are asserted, because agent core CAN deliver the latter: only
     [Types.stop_reason_of_string] maps overflow tokens to the typed
     [ContextWindowExceeded], and the Ollama / Ollama-NDJSON / OpenAI-Responses
     decoders build [Types.Unknown <raw>] without it. Classifying that here would
     be a string classifier standing in for a typed provider signal. *)
  let unmodeled_stop_reason =
    Agent_core.Error.Agent
      (UnrecognizedStopReason { reason = "provider_specific_halt" })
  in
  check bool "unmodeled stop reason is not a context overflow" false
    (is_provider_context_overflow unmodeled_stop_reason);
  check bool "unmodeled stop reason is not auto-recoverable"
    false
    (EC.is_auto_recoverable_turn_error unmodeled_stop_reason);
  let overflow_token_stop_reason =
    Agent_core.Error.Agent
      (UnrecognizedStopReason { reason = "model_context_window_exceeded" })
  in
  check bool "overflow token on an agent stop reason is still not classified here"
    false
    (is_provider_context_overflow overflow_token_stop_reason)
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
    "typed input capacity does not classify as a lane overflow"
    true
    (match
       Masc.Keeper_unified_turn_execution.For_testing
       .declared_lane_failure_of_error
         capacity_error
     with
     | Masc.Keeper_unified_turn_execution.For_testing
       .Declared_runtime_lane_exhausted -> true
     | Masc.Keeper_unified_turn_execution.For_testing
       .Provider_context_overflow -> false)
;;

(* ContextOverflow counts toward the ordinary crash threshold: nothing
   recovers from it automatically, so exempting it would pin [consecutive] at
   0 while a request with no state-changing successor loops every cycle. *)
let test_context_overflow_is_not_auto_recoverable () =
  check
    bool
    "ContextOverflow is not auto-recoverable at turn level"
    false
    (EC.is_auto_recoverable_turn_error
       (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })))
;;

let request_body_refused_by_provider ~status =
  Agent_core.Error.Api
    (InvalidRequest
       { message = "provider refused the serialized request body"
       ; reason = Agent_core.Retry.Request_body_refused_by_provider { status }
       })
;;

(* Serving-evidence validity and unmeasurable tokens are facts about the
   measurement, not a context window. Neither may be guessed into one. *)
let test_unusable_capacity_evidence_is_not_context_overflow () =
  let constraint_ = serving_constraint () in
  check bool "expired serving evidence is not a context overflow" false
    (is_provider_context_overflow
       (input_capacity
          constraint_
          (Llm_provider.Serving_constraint.Evidence_expired
             { now_unix_s = 200; expires_at_unix_s = 199 })));
  check bool "unmeasurable tokens are not a context overflow" false
    (is_provider_context_overflow (measurement_unavailable constraint_))
;;

(* The classifier feeding the cascade path publishes
   reason="provider_context_overflow" and the execution-error phase of the same
   name, so admitting a byte refusal there would label it as a window exceedance. *)
let test_lane_classifier_admits_only_the_token_axis () =
  let module E = Masc.Keeper_unified_turn_execution.For_testing in
  (match
     E.declared_lane_failure_of_error
       (request_body_refused_by_provider ~status:413)
   with
   | E.Declared_runtime_lane_exhausted -> ()
   | E.Provider_context_overflow ->
     fail "a provider byte refusal was classified as a token overflow");
  match
    E.declared_lane_failure_of_error
      (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = None }))
  with
  | E.Provider_context_overflow -> ()
  | E.Declared_runtime_lane_exhausted ->
    fail "the context overflow lane classification regressed"
;;

let () =
  run
    "keeper_unified_context_overflow"
    [ ( "context_overflow"
      , [ test_case
            "only a typed ContextOverflow is a provider context overflow"
            `Quick
            test_only_a_typed_context_overflow_is_a_provider_overflow
        ; test_case
            "context overflow is not auto-recoverable"
            `Quick
            test_context_overflow_is_not_auto_recoverable
        ; test_case
            "input capacity is not context overflow"
            `Quick
            test_input_capacity_is_not_context_overflow
        ; test_case
            "unusable capacity evidence is not context overflow"
            `Quick
            test_unusable_capacity_evidence_is_not_context_overflow
        ; test_case
            "lane classifier admits only the token axis"
            `Quick
            test_lane_classifier_admits_only_the_token_axis
        ] )
    ]
;;
