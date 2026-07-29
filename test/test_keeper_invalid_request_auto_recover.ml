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

let request_body_too_large () =
  Agent_sdk.Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message = "serialized request body exceeds the declared limit"
       ; reason =
           Llm_provider.Retry.Request_body_too_large
             { actual_bytes = 526_155; limit_bytes = 524_288 }
       })
;;

let request_body_refused () =
  Agent_sdk.Error.Api
    (Llm_provider.Retry.InvalidRequest
       { message = "provider refused the serialized request body"
       ; reason =
           Llm_provider.Retry.Request_body_refused_by_provider { status = 413 }
       })
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
             { provider = "provider"; reason = "Invalid request: bad body" })));
  check
    bool
    "ContextOverflow does not match"
    false
    (EC.is_invalid_request_error
       (Agent_sdk.Error.Api
          (ContextOverflow { message = "exceeded"; limit = None })));
  check
    bool
    "rendered internal text does not match"
    false
    (EC.is_invalid_request_error
       (Agent_sdk.Error.Internal "Bad Request: arbitrary provider text"))
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
      (EC.is_invalid_request_error (Agent_sdk.Error.Api classified))
  | _ ->
    fail "HTTP 400 transport classification did not produce InvalidRequest"
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

let test_capacity_invalid_request_has_one_retry_authority () =
  let keeper = Printf.sprintf "test-ir-capacity-%d" (Unix.getpid ()) in
  KUF.reset_invalid_request_failures ~keeper_name:keeper;
  List.iter
    (fun error ->
       check bool "capacity reason stays a typed InvalidRequest" true
         (EC.is_invalid_request_error error);
       match
         Masc.Keeper_turn_runtime_budget.capacity_transition_of_error error
       with
       | Masc.Keeper_turn_runtime_budget.Compact_next_cycle _ -> ()
       | Masc.Keeper_turn_runtime_budget.Not_capacity
       | Masc.Keeper_turn_runtime_budget.Capacity_non_compacting _ ->
         fail "capacity reason did not enter the canonical compaction lane")
    [ request_body_too_large (); request_body_refused () ];
  (match
     Masc.Keeper_turn_runtime_budget.capacity_transition_of_error
       (invalid_request "bad body")
   with
   | Masc.Keeper_turn_runtime_budget.Not_capacity -> ()
   | Masc.Keeper_turn_runtime_budget.Compact_next_cycle _
   | Masc.Keeper_turn_runtime_budget.Capacity_non_compacting _ ->
     fail "generic InvalidRequest entered the compaction lane");
  for attempt = 1 to KUF.max_consecutive_invalid_request_failures + 2 do
    check
      bool
      (Printf.sprintf "capacity attempt %d does not consume generic budget" attempt)
      false
      (KUF.account_failure_counting
         ~keeper_name:keeper
         ~is_auto_recoverable:true
         (request_body_too_large ()))
  done;
  check
    bool
    "first later generic InvalidRequest still has its full budget"
    false
    (KUF.account_failure_counting
       ~keeper_name:keeper
       ~is_auto_recoverable:true
       (invalid_request "bad body"));
  KUF.reset_invalid_request_failures ~keeper_name:keeper
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
        ; test_case
            "consecutive counter bounds the crash-accounting exemption"
            `Quick
            test_consecutive_counter_bounds_exemption
        ; test_case
            "consecutive counters are per-keeper"
            `Quick
            test_counters_are_per_keeper
        ; test_case
            "capacity InvalidRequest uses only the compaction retry authority"
            `Quick
            test_capacity_invalid_request_has_one_retry_authority
        ] )
    ]
;;
