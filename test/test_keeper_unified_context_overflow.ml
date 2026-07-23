open Alcotest

module EC = Masc.Keeper_error_classify
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
        ] )
    ]
;;
