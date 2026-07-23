(** Adversarial-review coverage for #25582: the [Api (InvalidRequest _)] class
    is exempt from crash accounting via [is_auto_recoverable_turn_error], so
    it must carry its own bounded compensating accounting
    ([Keeper_unified_turn_failure.note_invalid_request_failure]) instead of
    retrying the same deterministic 400 forever with [consecutive] pinned at
    0. *)

open Alcotest

module EC = Masc.Keeper_error_classify
module KUF = Masc.Keeper_unified_turn_failure

let invalid_request message =
  Agent_sdk.Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message; reason = Llm_provider.Retry.Unknown_invalid_request })
;;

let test_is_invalid_request_error_only_for_api_invalid_request () =
  check
    bool
    "Api InvalidRequest matches"
    true
    (EC.is_invalid_request_error (invalid_request "bad body"));
  check
    bool
    "provider-side InvalidRequest does not match"
    false
    (EC.is_invalid_request_error
       (Agent_sdk.Error.Provider
          (Llm_provider.Error.InvalidRequest
             { provider = "provider"; reason = "bad body" })));
  check
    bool
    "ContextOverflow does not match"
    false
    (EC.is_invalid_request_error
       (Agent_sdk.Error.Api
          (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "Internal does not match"
    false
    (EC.is_invalid_request_error (Agent_sdk.Error.Internal "some error"))
;;

let test_invalid_request_is_auto_recoverable () =
  check
    bool
    "Api InvalidRequest is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error (invalid_request "bad body"))
;;

let test_consecutive_counter_bounds_exemption () =
  let keeper = Printf.sprintf "test-ir-bounded-%d" (Unix.getpid ()) in
  KUF.reset_invalid_request_failures ~keeper_name:keeper;
  for i = 1 to KUF.max_consecutive_invalid_request_failures do
    check
      bool
      (Printf.sprintf "attempt %d stays exempt from crash accounting" i)
      false
      (KUF.note_invalid_request_failure ~keeper_name:keeper)
  done;
  check
    bool
    "attempt beyond the bound degrades to crash accounting"
    true
    (KUF.note_invalid_request_failure ~keeper_name:keeper);
  check
    bool
    "degradation persists while failures continue"
    true
    (KUF.note_invalid_request_failure ~keeper_name:keeper);
  KUF.reset_invalid_request_failures ~keeper_name:keeper;
  check
    bool
    "reset after success/operator clear restores the exemption budget"
    false
    (KUF.note_invalid_request_failure ~keeper_name:keeper);
  KUF.reset_invalid_request_failures ~keeper_name:keeper
;;

let test_counters_are_per_keeper () =
  let keeper_a = Printf.sprintf "test-ir-a-%d" (Unix.getpid ()) in
  let keeper_b = Printf.sprintf "test-ir-b-%d" (Unix.getpid ()) in
  KUF.reset_invalid_request_failures ~keeper_name:keeper_a;
  KUF.reset_invalid_request_failures ~keeper_name:keeper_b;
  for _ = 1 to KUF.max_consecutive_invalid_request_failures + 1 do
    ignore (KUF.note_invalid_request_failure ~keeper_name:keeper_a)
  done;
  check
    bool
    "keeper A exhausted its budget"
    true
    (KUF.note_invalid_request_failure ~keeper_name:keeper_a);
  check
    bool
    "keeper B budget is unaffected"
    false
    (KUF.note_invalid_request_failure ~keeper_name:keeper_b);
  KUF.reset_invalid_request_failures ~keeper_name:keeper_a;
  KUF.reset_invalid_request_failures ~keeper_name:keeper_b
;;

let () =
  run
    "keeper_invalid_request_auto_recover"
    [ ( "invalid_request"
      , [ test_case
            "is_invalid_request_error only matches Api InvalidRequest"
            `Quick
            test_is_invalid_request_error_only_for_api_invalid_request
        ; test_case
            "Api InvalidRequest is auto-recoverable"
            `Quick
            test_invalid_request_is_auto_recoverable
        ; test_case
            "consecutive counter bounds the crash-accounting exemption"
            `Quick
            test_consecutive_counter_bounds_exemption
        ; test_case
            "consecutive counters are per-keeper"
            `Quick
            test_counters_are_per_keeper
        ] )
    ]
;;
