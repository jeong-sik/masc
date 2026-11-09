module Trail = Masc_tui_keeper_trail
module Decode = Masc.Tui_decode
module Receipt = Masc.Keeper_execution_receipt
module Evidence = Keeper_runtime_walk_evidence
module Fault = Llm_provider.Candidate_fault
module Request_failure = Keeper_request_failure

let health raw = Option.get (Decode.keeper_health_of_string raw)

let runtime ?last_failure ?lane_observation () : Decode.keeper_runtime =
  { kr_name = "keeper"
  ; kr_identity =
      Ok
        { k_trace_id = "trace"
        ; k_created_at = "2026-01-01T00:00:00Z"
        ; k_updated_at = "2026-01-01T00:00:00Z"
        }
  ; kr_portrait = Decode.Unavailable "test"
  ; kr_candle_account_revision = Ok None
  ; kr_health = health "failing"
  ; kr_paused = false
  ; kr_next_action = None
  ; kr_keepalive_running = true
  ; kr_activation_mode = Decode.Activation_autonomous
  ; kr_runtime_id = "test.runtime"
  ; kr_phase = Option.get (Decode.keeper_phase_of_string "running")
  ; kr_sandbox_profile = "docker"
  ; kr_runtime_blocker_summary = None
  ; kr_last_failure = last_failure
  ; kr_runtime_blocker_signature = None
  ; kr_runtime_lane_observation = lane_observation
  ; kr_runtime_path_rest = Ok None
  ; kr_operator_disposition = Ok None
  ; kr_failing_since = None
  ; kr_recent_turns = None
  }

let reported_at = 1_000.
let reported cause : Decode.keeper_failure = { kf_cause = cause; kf_at_unix = Some reported_at }
let receipt_ended_at = "2026-11-06T01:00:00Z"

let receipt_turn : Receipt.receipt_turn =
  { receipt_trace_id = "trace-1"; receipt_turn_count = Some 1; receipt_ended_at }

let candidate ~attempt ~runtime_id cause : Evidence.failure =
  { attempt
  ; runtime_id
  ; dispatch = Runtime_attempt_dispatch.Dispatched
  ; failure = { Request_failure.cause }
  ; api_candidate_fault = None
  }

let observed ?(terminal = Evidence.Terminal_not_observed) failures =
  Receipt.Runtime_lane_observed
    { turn = receipt_turn; evidence = { Evidence.failures; terminal } }

let rate_limited =
  Request_failure.Provider_rate_limited { provider = None; retry_after = None; detail = "" }

let turn_causes =
  [ Decode.Keeper_failure_turn
  ; Decode.Keeper_failure_provider
  ; Decode.Keeper_failure_configuration
  ; Decode.Keeper_failure_client_recovery
  ]

let other_causes =
  [ Decode.Keeper_failure_heartbeat
  ; Decode.Keeper_failure_fiber
  ; Decode.Keeper_failure_exception
  ; Decode.Keeper_failure_operator_interrupt
  ]

let failing_trail ?last_failure ?lane_observation () =
  Trail.of_readings
    ~health:(Some (health "failing"))
    ~runtime:(Some (runtime ?last_failure ?lane_observation ()))

(* [receipt_ended_at] as a Unix time, written out so the expectation does not
   depend on the parser the trail uses. *)
let receipt_time = Some 1_793_926_800.

let two_candidates =
  [ candidate ~attempt:0 ~runtime_id:"a" rate_limited
  ; candidate ~attempt:1 ~runtime_id:"b" rate_limited
  ]

(* The time and walk read for a provider failure whose receipt ends at candidate
   "b" with [terminal_cause]. *)
let walk_of terminal_cause failures =
  let terminal =
    Evidence.Candidate_terminal
      { runtime_id = "b"; attempt = 1; failure = { Request_failure.cause = terminal_cause } }
  in
  match
    failing_trail ~last_failure:(reported Decode.Keeper_failure_provider)
      ~lane_observation:(observed ~terminal failures) ()
  with
  | Trail.Trail_failed { ended_at; walk; _ } -> (ended_at, walk)
  | Trail.Trail_sound -> (None, Trail.Walk_absent)

let ended group =
  (receipt_time, Trail.Walk_ended { runtime_id = "b"; cause = group; tried = 2 })

let test_only_a_failing_health_reading_has_a_failed_trail () =
  let lane_observation = observed [ candidate ~attempt:0 ~runtime_id:"a" rate_limited ] in
  let runtime =
    Some (runtime ~last_failure:(reported Decode.Keeper_failure_turn) ~lane_observation ())
  in
  List.iter
    (fun raw ->
      Alcotest.(check bool) (raw ^ " has no trail") true
        (Trail.of_readings ~health:(Some (health raw)) ~runtime = Trail.Trail_sound))
    [ "healthy"; "offline" ];
  Alcotest.(check bool) "an unread health has no trail" true
    (Trail.of_readings ~health:None ~runtime = Trail.Trail_sound)

let test_a_failing_keeper_with_no_last_failure_reads_no_receipt () =
  let lane_observation = observed [ candidate ~attempt:0 ~runtime_id:"a" rate_limited ] in
  Alcotest.(check bool) "no last failure" true
    (failing_trail ~lane_observation ()
     = Trail.Trail_failed { ended_at = None; last = None; walk = Trail.Walk_not_applicable });
  Alcotest.(check bool) "no runtime row" true
    (Trail.of_readings ~health:(Some (health "failing")) ~runtime:None
     = Trail.Trail_failed { ended_at = None; last = None; walk = Trail.Walk_not_applicable })

let test_a_failure_that_ends_no_turn_keeps_the_server_time_and_reads_no_receipt () =
  let lane_observation = observed [ candidate ~attempt:0 ~runtime_id:"a" rate_limited ] in
  List.iter
    (fun cause ->
      Alcotest.(check bool) "walk not applicable" true
        (failing_trail ~last_failure:(reported cause) ~lane_observation ()
         = Trail.Trail_failed
             { ended_at = Some reported_at; last = Some cause; walk = Trail.Walk_not_applicable }))
    other_causes

let test_a_turn_failure_without_a_receipt_has_an_absent_walk () =
  List.iter
    (fun cause ->
      Alcotest.(check bool) "walk absent" true
        (failing_trail ~last_failure:(reported cause) ()
         = Trail.Trail_failed
             { ended_at = Some reported_at; last = Some cause; walk = Trail.Walk_absent }))
    turn_causes

let test_a_receipt_without_a_walk_keeps_the_server_time () =
  let failure = reported Decode.Keeper_failure_turn in
  Alcotest.(check bool) "not captured" true
    (failing_trail ~last_failure:failure
       ~lane_observation:(Receipt.Runtime_lane_not_observed receipt_turn) ()
     = Trail.Trail_failed
         { ended_at = Some reported_at
         ; last = Some Decode.Keeper_failure_turn
         ; walk = Trail.Walk_not_captured
         });
  Alcotest.(check bool) "unreadable" true
    (failing_trail ~last_failure:failure
       ~lane_observation:(Receipt.Runtime_lane_unreadable { turn = Some receipt_turn; field = "x" }) ()
     = Trail.Trail_failed
         { ended_at = Some reported_at
         ; last = Some Decode.Keeper_failure_turn
         ; walk = Trail.Walk_unreadable
         })

let test_a_walk_without_a_terminal_counts_candidates_once_and_takes_the_receipt_time () =
  let lane_observation =
    observed
      [ candidate ~attempt:0 ~runtime_id:"a" rate_limited
      ; candidate ~attempt:1 ~runtime_id:"b" rate_limited
      ; candidate ~attempt:1 ~runtime_id:"b" rate_limited
      ]
  in
  Alcotest.(check bool) "no terminal" true
    (failing_trail ~last_failure:(reported Decode.Keeper_failure_provider) ~lane_observation ()
     = Trail.Trail_failed
         { ended_at = receipt_time
         ; last = Some Decode.Keeper_failure_provider
         ; walk = Trail.Walk_no_terminal { tried = 2 }
         })

let test_a_terminal_names_the_runtime_and_groups_the_cause_of_its_failure () =
  Alcotest.(check bool) "rate limited" true
    (walk_of rate_limited two_candidates = ended Trail.Rate_limited);
  Alcotest.(check bool) "a terminal outside the failures still counts" true
    (walk_of Request_failure.Operator_cancelled []
     = (receipt_time, Trail.Walk_ended { runtime_id = "b"; cause = Trail.Stopped; tried = 1 }));
  let core category =
    Request_failure.Core { Keeper_request_failure_core.category; message = "" }
  in
  Alcotest.(check bool) "a configuration category" true
    (walk_of (core Agent_core.Error.Config_category) two_candidates = ended Trail.Configuration);
  Alcotest.(check bool) "an api category" true
    (walk_of (core Agent_core.Error.Api_category) two_candidates = ended Trail.Provider)

let test_causes_are_grouped_by_what_an_operator_does_about_them () =
  let exhausted reason =
    Request_failure.Masc (Keeper_internal_error.Runtime_exhausted { runtime_id = "b"; reason })
  in
  Alcotest.(check bool) "a refused connection joins the connection group" true
    (walk_of (exhausted Keeper_internal_error.Connection_refused) two_candidates
     = ended Trail.Connection);
  Alcotest.(check bool) "a failed name lookup joins the connection group" true
    (walk_of (exhausted Keeper_internal_error.Dns_failure) two_candidates
     = ended Trail.Connection);
  Alcotest.(check bool) "every provider failing stays a provider failure" true
    (walk_of (exhausted Keeper_internal_error.All_providers_failed) two_candidates
     = ended Trail.Provider);
  let transcript =
    Request_failure.Masc
      (Keeper_internal_error.Incomplete_tool_transcript
         { reason = Keeper_internal_error.Unresolved_tool_results
         ; detail = ""
         ; tool_use_ids = []
         })
  in
  Alcotest.(check bool) "a transcript that fails validation needs a recovery step" true
    (walk_of transcript two_candidates = ended Trail.Recovery);
  Alcotest.(check bool) "an input-capacity failure shares the group of a context overflow" true
    (walk_of Request_failure.Input_capacity two_candidates = ended Trail.Input
     && walk_of (Request_failure.Context_overflow { limit = None }) two_candidates
        = ended Trail.Input)

let test_an_observed_walk_with_no_failure_and_no_terminal_names_no_cause () =
  Alcotest.(check bool) "the server time and word stay" true
    (failing_trail ~last_failure:(reported Decode.Keeper_failure_turn)
       ~lane_observation:(observed []) ()
     = Trail.Trail_failed
         { ended_at = Some reported_at
         ; last = Some Decode.Keeper_failure_turn
         ; walk = Trail.Walk_no_candidate_failure
         })

let test_a_receipt_time_that_does_not_parse_does_not_borrow_the_server_time () =
  let lane_observation =
    Receipt.Runtime_lane_observed
      { turn = { receipt_turn with receipt_ended_at = "not a time" }
      ; evidence =
          { Evidence.failures = [ candidate ~attempt:0 ~runtime_id:"a" rate_limited ]
          ; terminal = Evidence.Terminal_not_observed
          }
      }
  in
  Alcotest.(check bool) "no time" true
    (failing_trail ~last_failure:(reported Decode.Keeper_failure_provider) ~lane_observation ()
     = Trail.Trail_failed
         { ended_at = None
         ; last = Some Decode.Keeper_failure_provider
         ; walk = Trail.Walk_no_terminal { tried = 1 }
         })


(* The attempts a failing Keeper's last receipt records, read the way the list
   reads them: [failures] are the candidate failures, [terminal] the error the
   lane ended on. *)
let attempts_of ?terminal failures =
  Trail.attempts_of_runtime
    (Some
       (runtime ~last_failure:(reported Decode.Keeper_failure_provider)
          ~lane_observation:(observed ?terminal failures) ()))

let with_fault fault (failure : Evidence.failure) =
  { failure with Evidence.api_candidate_fault = Some fault }

let ended_by ~runtime_id ~attempt cause =
  Evidence.Candidate_terminal { runtime_id; attempt; failure = { Request_failure.cause } }

let ordinals_of attempts = List.map (fun (a : Trail.attempt) -> a.ordinal) attempts
let runtimes_of attempts = List.map (fun (a : Trail.attempt) -> a.runtime_id) attempts
let terminals_of attempts = List.map (fun (a : Trail.attempt) -> a.terminal) attempts
let faults_of attempts = List.map (fun (a : Trail.attempt) -> a.fault) attempts
let causes_of attempts = List.map (fun (a : Trail.attempt) -> a.cause) attempts

let test_attempts_are_ordered_and_the_terminal_ends_them () =
  let attempts =
    attempts_of
      ~terminal:(ended_by ~runtime_id:"c" ~attempt:2 Request_failure.Input_capacity)
      [ with_fault (Fault.Binding Fault.Rate_limit)
          (candidate ~attempt:0 ~runtime_id:"a" rate_limited)
      ; candidate ~attempt:1 ~runtime_id:"b" Request_failure.Server_restarted
      ]
  in
  Alcotest.(check (list int)) "ordinals" [ 0; 1; 2 ] (ordinals_of attempts);
  Alcotest.(check (list string)) "runtimes" [ "a"; "b"; "c" ] (runtimes_of attempts);
  Alcotest.(check (list bool)) "only the last is the terminal" [ false; false; true ]
    (terminals_of attempts);
  Alcotest.(check (list (option string))) "API facts" [ Some "rate limit"; None; None ]
    (faults_of attempts);
  Alcotest.(check bool) "causes" true
    (causes_of attempts = [ Trail.Rate_limited; Trail.Server; Trail.Input ])

let test_a_walk_without_a_terminal_has_no_terminal_attempt () =
  let attempts =
    attempts_of
      [ with_fault (Fault.Binding Fault.Capacity)
          (candidate ~attempt:0 ~runtime_id:"a" Request_failure.Server_restarted)
      ; with_fault Fault.Local_admission (candidate ~attempt:1 ~runtime_id:"b" rate_limited)
      ; with_fault (Fault.Binding Fault.Admission)
          (candidate ~attempt:2 ~runtime_id:"c" rate_limited)
      ]
  in
  Alcotest.(check (list int)) "ordinals" [ 0; 1; 2 ] (ordinals_of attempts);
  Alcotest.(check (list bool)) "no terminal attempt" [ false; false; false ]
    (terminals_of attempts);
  Alcotest.(check (list (option string))) "MASC's own wait is not the runtime's refusal"
    [ Some "capacity"; Some "MASC admission wait"; Some "admission" ]
    (faults_of attempts)

let test_the_terminal_keeps_the_dispatch_and_api_fact_of_its_candidate () =
  let attempts =
    attempts_of
      ~terminal:(ended_by ~runtime_id:"b" ~attempt:1 Request_failure.Server_restarted)
      [ candidate ~attempt:0 ~runtime_id:"a" rate_limited
      ; with_fault (Fault.Binding Fault.Server) (candidate ~attempt:1 ~runtime_id:"b" rate_limited)
      ]
  in
  Alcotest.(check (list int)) "the terminal replaces its candidate" [ 0; 1 ]
    (ordinals_of attempts);
  match List.rev attempts with
  | (ended : Trail.attempt) :: _ ->
      Alcotest.(check bool) "terminal" true ended.terminal;
      Alcotest.(check bool) "the cause is the terminal's" true (ended.cause = Trail.Server);
      Alcotest.(check (option string)) "the API fact is the candidate's" (Some "server")
        ended.fault;
      Alcotest.(check bool) "the dispatch is the candidate's" true
        (ended.dispatch = Some Runtime_attempt_dispatch.Dispatched)
  | [] -> Alcotest.fail "no attempts"

let test_the_first_failure_of_a_repeated_ordinal_is_kept () =
  let attempts =
    attempts_of
      [ candidate ~attempt:0 ~runtime_id:"first" rate_limited
      ; candidate ~attempt:0 ~runtime_id:"second" rate_limited
      ]
  in
  Alcotest.(check (list string)) "runtimes" [ "first" ] (runtimes_of attempts)

let test_a_failure_that_is_not_a_turn_failure_has_no_attempts () =
  let attempts =
    Trail.attempts_of_runtime
      (Some
         (runtime ~last_failure:(reported Decode.Keeper_failure_heartbeat)
            ~lane_observation:(observed two_candidates) ()))
  in
  Alcotest.(check (list int)) "ordinals" [] (ordinals_of attempts)

let test_matrix_separates_failed_walk_and_next_head () =
  let row = runtime ~last_failure:(reported Decode.Keeper_failure_turn)
      ~lane_observation:(observed two_candidates) () in
  let resting = { row with kr_runtime_path_rest = Ok (Some
      (Decode.Path_rest_resting { runtime_id = "a"; release_at = 1200.;
        release_basis = Decode.Stated_by_provider })) } in
  let check id expected runtime = Alcotest.(check bool) id true
      (Trail.matrix_cell ~runtime_id:id (Some runtime) = expected) in
  check "a" { Trail.failure = Trail.Matrix_failed; head = Trail.Head_resting } resting;
  check "b" { Trail.failure = Trail.Matrix_failed; head = Trail.Head_elsewhere } resting;
  check "untried" { Trail.failure = Trail.Matrix_clear; head = Trail.Head_elsewhere } resting;
  let serving = { row with kr_runtime_path_rest = Ok (Some
      (Decode.Path_rest_serving { runtime_id = "next" })) } in
  check "next" { Trail.failure = Trail.Matrix_clear; head = Trail.Head_serving } serving;
  check "a" { Trail.failure = Trail.Matrix_failed; head = Trail.Head_unknown }
    { row with kr_runtime_path_rest = Error "unread" };
  check "a" { Trail.failure = Trail.Matrix_unknown; head = Trail.Head_unknown }
    (runtime ~last_failure:(reported Decode.Keeper_failure_turn) ());
  check "a" { Trail.failure = Trail.Matrix_unknown; head = Trail.Head_unknown }
    (runtime ~last_failure:(reported Decode.Keeper_failure_heartbeat)
       ~lane_observation:(observed two_candidates) ());
  Alcotest.(check (list string)) "attempt and head identities only" [ "a"; "b"; "next" ]
    (Trail.matrix_runtime_ids (Some serving));
  Alcotest.(check bool) "missing runtime remains unknown" true
    (Trail.matrix_cell ~runtime_id:"missing" None = { Trail.failure = Trail.Matrix_unknown; head = Trail.Head_unknown })

let () =
  Alcotest.run "tui_keeper_trail"
    [ ( "decisions"
      , [ Alcotest.test_case "matrix separates failed walk and next head" `Quick
            test_matrix_separates_failed_walk_and_next_head
        ; Alcotest.test_case "only a failing health reading has a failed trail" `Quick
            test_only_a_failing_health_reading_has_a_failed_trail
        ; Alcotest.test_case "a failing Keeper with no last failure reads no receipt" `Quick
            test_a_failing_keeper_with_no_last_failure_reads_no_receipt
        ; Alcotest.test_case "a failure that ends no turn reads no receipt" `Quick
            test_a_failure_that_ends_no_turn_keeps_the_server_time_and_reads_no_receipt
        ; Alcotest.test_case "a turn failure without a receipt has an absent walk" `Quick
            test_a_turn_failure_without_a_receipt_has_an_absent_walk
        ; Alcotest.test_case "a receipt without a walk keeps the server time" `Quick
            test_a_receipt_without_a_walk_keeps_the_server_time
        ; Alcotest.test_case "a walk without a terminal counts candidates once" `Quick
            test_a_walk_without_a_terminal_counts_candidates_once_and_takes_the_receipt_time
        ; Alcotest.test_case "a terminal names the runtime and groups its cause" `Quick
            test_a_terminal_names_the_runtime_and_groups_the_cause_of_its_failure
        ; Alcotest.test_case "causes are grouped by what an operator does about them" `Quick
            test_causes_are_grouped_by_what_an_operator_does_about_them
        ; Alcotest.test_case "an observed walk with no failure names no cause" `Quick
            test_an_observed_walk_with_no_failure_and_no_terminal_names_no_cause
        ; Alcotest.test_case "a receipt time that does not parse is not replaced" `Quick
            test_a_receipt_time_that_does_not_parse_does_not_borrow_the_server_time
        ; Alcotest.test_case "attempts are ordered and the terminal ends them" `Quick
            test_attempts_are_ordered_and_the_terminal_ends_them
        ; Alcotest.test_case "a walk without a terminal has no terminal attempt" `Quick
            test_a_walk_without_a_terminal_has_no_terminal_attempt
        ; Alcotest.test_case "the terminal keeps the dispatch and API fact of its candidate" `Quick
            test_the_terminal_keeps_the_dispatch_and_api_fact_of_its_candidate
        ; Alcotest.test_case "the first failure of a repeated ordinal is kept" `Quick
            test_the_first_failure_of_a_repeated_ordinal_is_kept
        ; Alcotest.test_case "a failure that is not a turn failure has no attempts" `Quick
            test_a_failure_that_is_not_a_turn_failure_has_no_attempts
        ] )
    ]
