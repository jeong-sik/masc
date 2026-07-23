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

(* Drift guard for the legacy string arms in [EC.is_invalid_request_error]
   (#25606).  The classification shape and the rendered prefix are both
   produced by the pinned OAS SDK (oas 5851df2e, lib/llm_provider/retry.ml):
   [Retry.classify_error] maps HTTP 400/422 to
   [InvalidRequest { reason = Unknown_invalid_request; message = body }] and
   [Retry.error_message] renders it as ["Invalid request (%s): %s"] — the
   prefix the legacy string arm matches.  This test generates the real SDK
   product and asserts the predicate catches it and the rendering keeps the
   matched prefix, so an SDK-side shape change fails here instead of
   silently deadening the matcher.  At the pin no [sdk_error] rendering
   starts with ["Bad Request"] or ["oas-ollama_cloud"]; those string arms
   are defensive legacy shapes with no SDK producer to pin. *)
let test_sdk_invalid_request_shape_drift_guard () =
  let api_error =
    Llm_provider.Retry.classify_error
      ~retry_after_header:None
      ~status:400
      ~body:"Bad Request"
  in
  let err = Agent_sdk.Error.Api api_error in
  check
    bool
    "SDK-classified 400 is caught by the predicate"
    true
    (EC.is_invalid_request_error err);
  check
    bool
    "SDK rendering keeps the Invalid request prefix the string arm matches"
    true
    (String.starts_with
       ~prefix:"Invalid request"
       (Agent_sdk.Error.to_string err))
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
        ; test_case
            "SDK 400 classification/rendering shape drift guard"
            `Quick
            test_sdk_invalid_request_shape_drift_guard
        ] )
    ]
;;
