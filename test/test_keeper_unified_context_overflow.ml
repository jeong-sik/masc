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
  check
    bool
    "Internal does not match"
    false
    (EC.is_context_overflow (Agent_sdk.Error.Internal "some error"))
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
        ] )
    ]
;;
