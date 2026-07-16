open Alcotest

module EC = Masc.Keeper_error_classify
module M = Masc.Keeper_runtime_manifest
module U = Masc.Keeper_unified_turn

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

let test_overflow_projection_never_requeues_unchanged_context () =
  let project = U.provider_overflow_manifest_projection in
  check bool "applied context requeues source" true
    (match project Masc.Keeper_context_runtime.Applied_checkpoint with
     | M.Context_compacted, true, U.Requeue_after_context_compaction -> true
     | _ -> false);
  List.iter
    (fun outcome ->
       check bool "unchanged context follows failure route" true
         (match project outcome with
          | (M.Context_compaction_noop | M.Runtime_failed), false,
            U.Follow_failure_route -> true
          | _ -> false))
    [ Masc.Keeper_context_runtime.No_checkpoint_change
    ; Masc.Keeper_context_runtime.Failed_compaction (Some "failed")
    ]
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
            "overflow projection never requeues unchanged context"
            `Quick
            test_overflow_projection_never_requeues_unchanged_context
        ] )
    ]
;;
