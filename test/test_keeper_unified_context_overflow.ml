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

let test_is_context_overflow_only_for_overflow_errors () =
  check
    bool
    "ContextOverflow matches"
    true
    (EC.is_context_overflow
       (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })));
  check
    bool
    "ContextOverflow without limit"
    true
    (EC.is_context_overflow
       (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "NetworkError does not match"
    false
    (EC.is_context_overflow
       (Agent_core.Error.Api
          (NetworkError
             { message = "Connection_reset"
             ; kind = Llm_provider.Http_client.Connection_refused
             })));
  let rendered_only =
    Agent_core.Error.Internal
      "Context overflow: model_context_window_exceeded arbitrary provider text"
  in
  check bool "rendered internal text does not match" false
    (EC.is_context_overflow rendered_only);
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
    (EC.is_context_overflow unmodeled_stop_reason);
  check bool "unmodeled stop reason is not auto-recoverable"
    false
    (EC.is_auto_recoverable_turn_error unmodeled_stop_reason);
  let overflow_token_stop_reason =
    Agent_core.Error.Agent
      (UnrecognizedStopReason { reason = "model_context_window_exceeded" })
  in
  check bool "overflow token on an agent stop reason is still not classified here"
    false
    (EC.is_context_overflow overflow_token_stop_reason)
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
       .Provider_context_overflow _ -> false)
;;

(* ContextOverflow counts toward the ordinary crash threshold (#26546): the
   automatic overflow-compaction recovery was removed after producing no
   committed compaction. Exempting it would pin [consecutive] at 0 while a
   request with no state-changing successor loops every cycle. *)
let test_context_overflow_is_not_auto_recoverable () =
  check
    bool
    "ContextOverflow is not auto-recoverable at turn level"
    false
    (EC.is_auto_recoverable_turn_error
       (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 })))
;;

module Budget = Masc.Keeper_turn_runtime_budget

let request_body_too_large ~actual_bytes ~limit_bytes =
  Agent_core.Error.Api
    (InvalidRequest
       { message = "serialized request body exceeds the declared limit"
       ; reason = Agent_core.Retry.Request_body_too_large { actual_bytes; limit_bytes }
       })
;;

let request_body_refused_by_provider ~status =
  Agent_core.Error.Api
    (InvalidRequest
       { message = "provider refused the serialized request body"
       ; reason = Agent_core.Retry.Request_body_refused_by_provider { status }
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
   | Some (Budget.Provider_request_body_refusal _) ->
     fail "a locally measured refusal was classified as a provider refusal"
   | None -> fail "a declared-byte refusal was not classified as a capacity refusal");
  (match
     Budget.capacity_refusal_of_error
       (request_body_refused_by_provider ~status:413)
   with
   | Some (Budget.Provider_request_body_refusal { status = 413 }) -> ()
   | Some _ | None -> fail "provider refusal status was not preserved");
  match
    Budget.capacity_refusal_of_error
      (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = Some 32768 }))
  with
  | Some (Budget.Provider_context_window { limit_tokens = Some 32768 }) -> ()
  | Some _ | None -> fail "the context window axis regressed"
;;

let test_byte_axis_forwards_exact_request_wire_observation () =
  let observed = ref None in
  Masc.Keeper_turn_driver_try_provider.For_testing.observe_request_wire_error
    ~runtime_id:"anthropic.fallback"
    ~max_request_body_bytes:1_048_576
    ~on_request_wire_observation:
      (Some
         (fun ~runtime_id ~max_request_body_bytes ~body_bytes ~serialized ->
           check bool "serialized request absent on refusal" true
             (Option.is_none serialized);
           observed := Some (runtime_id, max_request_body_bytes, body_bytes)))
    (request_body_too_large
       ~actual_bytes:1_671_330
       ~limit_bytes:1_048_576);
  check
    (option (triple string int int))
    "typed byte refusal preserves runtime, cap and exact body bytes"
    (Some ("anthropic.fallback", 1_048_576, 1_671_330))
    !observed;
  observed := None;
  Masc.Keeper_turn_driver_try_provider.For_testing.observe_request_wire_error
    ~runtime_id:"anthropic.fallback"
    ~max_request_body_bytes:1_048_576
    ~on_request_wire_observation:
      (Some
         (fun ~runtime_id ~max_request_body_bytes ~body_bytes ~serialized ->
           check bool "serialized request absent on refusal" true
             (Option.is_none serialized);
           observed := Some (runtime_id, max_request_body_bytes, body_bytes)))
    (Agent_core.Error.Api
       (ContextOverflow { message = "exceeded"; limit = Some 32768 }));
  check
    (option (triple string int int))
    "token-axis refusal does not fabricate request wire bytes"
    None
    !observed
;;

let test_typed_capacity_transition_preserves_axes () =
  let constraint_ = serving_constraint () in
  let boundary =
    input_capacity
      constraint_
      (Llm_provider.Serving_constraint.Boundary_unknown
         { input_tokens = 524_299
         ; accepted_through = 524_298
         ; rejected_from = None
         })
  in
  (* A serving-constraint boundary is provider capacity evidence, not a
     measured token or byte limit. It must stay outside the two refusal
     axes rather than being folded into one of them. *)
  (match Budget.capacity_refusal_of_error boundary with
   | None -> ()
   | Some _ -> fail "a serving boundary was folded into a capacity refusal");
  (match
     Budget.capacity_refusal_of_error
       (request_body_too_large
          ~actual_bytes:2_000_000
          ~limit_bytes:1_048_576)
   with
   | Some (Budget.Serialized_request_body
             { actual_bytes = 2_000_000; limit_bytes = 1_048_576 }) ->
     ()
   | _ -> fail "serialized byte provenance was not preserved");
  match
    Budget.capacity_refusal_of_error
      (request_body_refused_by_provider ~status:413)
  with
  | Some (Budget.Provider_request_body_refusal { status = 413 }) -> ()
  | _ -> fail "provider refusal did not keep its status"
;;

(* Serving-evidence validity and unmeasurable tokens are facts about the
   measurement, not a capacity limit. Neither may be guessed into one. *)
let test_unusable_capacity_evidence_is_ignored () =
  let constraint_ = serving_constraint () in
  (match
     Budget.capacity_refusal_of_error
       (input_capacity
          constraint_
          (Llm_provider.Serving_constraint.Evidence_expired
             { now_unix_s = 200; expires_at_unix_s = 199 }))
   with
   | None -> ()
   | Some _ -> fail "expired serving evidence became a capacity refusal");
  match Budget.capacity_refusal_of_error (measurement_unavailable constraint_) with
  | None -> ()
  | Some _ -> fail "measurement-unavailable became a capacity refusal"
;;

(* The classifier feeding the cascade path publishes
   reason="provider_context_overflow" and the Agent_core_context_window_exceeded blocker
   class, so admitting a byte refusal there would label it as a window exceedance. *)
let test_lane_classifier_admits_only_the_token_axis () =
  let module E = Masc.Keeper_unified_turn_execution.For_testing in
  (match
     E.declared_lane_failure_of_error
       (request_body_too_large ~actual_bytes:2_000_000 ~limit_bytes:1_048_576)
   with
   | E.Declared_runtime_lane_exhausted -> ()
   | E.Provider_context_overflow _ ->
     fail "a byte refusal was classified as a context overflow");
  (match
     E.declared_lane_failure_of_error
       (request_body_refused_by_provider ~status:413)
   with
   | E.Declared_runtime_lane_exhausted -> ()
   | E.Provider_context_overflow _ ->
     fail "a provider byte refusal was classified as a token overflow");
  match
    E.declared_lane_failure_of_error
      (Agent_core.Error.Api (ContextOverflow { message = "exceeded"; limit = None }))
  with
  | E.Provider_context_overflow { limit_tokens = None } -> ()
  | E.Provider_context_overflow { limit_tokens = Some _ }
  | E.Declared_runtime_lane_exhausted ->
    fail "the context overflow lane classification regressed"
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
            "context overflow is not auto-recoverable"
            `Quick
            test_context_overflow_is_not_auto_recoverable
        ; test_case
            "input capacity is not context overflow"
            `Quick
            test_input_capacity_is_not_context_overflow
        ; test_case
            "declared-byte refusal is a capacity refusal"
            `Quick
            test_byte_axis_is_a_capacity_refusal
        ; test_case
            "declared-byte refusal forwards exact request wire observation"
            `Quick
            test_byte_axis_forwards_exact_request_wire_observation
        ; test_case
            "typed capacity transition preserves axes"
            `Quick
            test_typed_capacity_transition_preserves_axes
        ; test_case
            "unusable capacity evidence is ignored"
            `Quick
            test_unusable_capacity_evidence_is_ignored
        ; test_case
            "lane classifier admits only the token axis"
            `Quick
            test_lane_classifier_admits_only_the_token_axis
        ] )
    ]
;;
