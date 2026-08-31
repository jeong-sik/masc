(** Classification contract for the [Api (InvalidRequest _)] class.

    RFC turn-failure-visible-stop (#32105) removed the crash-accounting
    exemption this file used to pin: every turn failure now advances the
    durable crash-accounting streak regardless of class, so there is no
    per-keeper budget to test here. What remains pinned is the
    classification itself — [InvalidRequest] must stay a distinct typed
    class, because telemetry and failure routing depend on which boundary
    produced the rejection. *)

open Alcotest

module EC = Masc.Keeper_error_classify

let invalid_request message =
  Agent_core.Error.Api
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
       (Agent_core.Error.Provider
          (Llm_provider.Error.InvalidRequest
             { provider = "provider"; reason = "Invalid request: bad body" })));
  check
    bool
    "ContextOverflow does not match"
    false
    (EC.is_invalid_request_error
       (Agent_core.Error.Api
          (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "rendered internal text does not match"
    false
    (EC.is_invalid_request_error (Agent_core.Error.Internal "Bad Request: arbitrary provider text"))
;;

let test_invalid_request_is_auto_recoverable () =
  check
    bool
    "Api InvalidRequest is auto-recoverable at turn level"
    true
    (EC.is_auto_recoverable_turn_error (invalid_request "bad body"))
;;

let test_transport_400_bridges_to_typed_api_invalid_request () =
  let classified =
    Llm_provider.Retry.classify_error
      ~retry_after_header:None
      ~status:400
      ~body:"transport rejection"
  in
  match classified with
  | Llm_provider.Retry.InvalidRequest _ ->
    check
      bool
      "transport-classified 400 reaches the typed API predicate"
      true
      (EC.is_invalid_request_error (Agent_core.Error.Api classified))
  | _ ->
    fail "HTTP 400 transport classification did not produce InvalidRequest"
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
            "HTTP 400 transport classification bridges to typed Api InvalidRequest"
            `Quick
            test_transport_400_bridges_to_typed_api_invalid_request
        ] )
    ]
;;
