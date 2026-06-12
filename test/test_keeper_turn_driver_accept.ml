let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let response ?(content = []) ?(stop_reason = Agent_sdk.Types.EndTurn) () =
  {
    Agent_sdk.Types.id = "resp-test";
    model = "model-test";
    stop_reason;
    content;
    usage = None;
    telemetry = None;
  }

let run_result ?content ?stop_reason () : Runtime_agent.run_result =
  {
    response = response ?content ?stop_reason ();
    checkpoint = None;
    session_id = "session-test";
    turns = 1;
    trace_ref = None;
    run_validation = None;
    runtime_observation = None;
    stop_reason = Runtime_agent.Completed;
  }

let test_accept_keeps_result () =
  let result =
    Masc.Keeper_turn_driver_try_provider.For_testing.apply_accept
      ~runtime_id:"ollama.test"
      ~accept:(fun _ -> true)
      (run_result ())
  in
  match result with
  | Ok kept ->
    Alcotest.(check string) "session preserved" "session-test" kept.session_id
  | Error err ->
    Alcotest.failf "accepted response should pass through: %s"
      (Agent_sdk.Error.to_string err)

let check_accept_rejected_reason ~expected_reason result =
  match result with
  | Ok _ -> Alcotest.fail "rejected response should fail"
  | Error err ->
    (match Keeper_internal_error.classify_masc_internal_error err with
     | Some (Keeper_internal_error.Accept_rejected { scope; reason; _ }) ->
       Alcotest.(check string)
         "scope"
         "ollama.gemma4-26b-a4b-qat"
         scope;
       Alcotest.(check bool)
         "reason mentions accept rejection"
         true
         (contains ~needle:"response rejected by accept" reason);
       Alcotest.(check bool)
         "reason includes response shape"
         true
         (contains ~needle:expected_reason reason)
     | Some other ->
       Alcotest.failf "expected Accept_rejected, got %s"
         (Keeper_internal_error.kind_of_masc_internal_error other)
     | None ->
       Alcotest.failf "expected typed keeper error, got %s"
         (Agent_sdk.Error.to_string err))

let reject_result run_result =
  Masc.Keeper_turn_driver_try_provider.For_testing.apply_accept
    ~runtime_id:"ollama.gemma4-26b-a4b-qat"
    ~accept:(fun _ -> false)
    run_result

let test_rejects_empty_end_turn_with_reason () =
  let result =
    reject_result
      (run_result ~content:[] ~stop_reason:Agent_sdk.Types.EndTurn ())
  in
  check_accept_rejected_reason ~expected_reason:"reason=empty_end_turn" result

let test_rejects_thinking_only_with_reason () =
  let result =
    reject_result
      (run_result
         ~content:
           [ Agent_sdk.Types.Thinking
               { thinking_type = "thinking"; content = "reasoning only" }
           ]
         ~stop_reason:Agent_sdk.Types.EndTurn
         ())
  in
  check_accept_rejected_reason ~expected_reason:"reason=thinking_only" result

let test_rejects_visible_response_as_predicate_false () =
  let result =
    reject_result
      (run_result
         ~content:[ Agent_sdk.Types.Text "visible but custom-rejected" ]
         ~stop_reason:Agent_sdk.Types.EndTurn
         ())
  in
  check_accept_rejected_reason ~expected_reason:"reason=accept_predicate_false" result

let () =
  Alcotest.run "keeper_turn_driver_accept"
    [
      ( "accept"
      , [
          Alcotest.test_case "accepted response passes through" `Quick
            test_accept_keeps_result;
          Alcotest.test_case "empty end_turn rejection is typed" `Quick
            test_rejects_empty_end_turn_with_reason;
          Alcotest.test_case "thinking-only rejection is typed" `Quick
            test_rejects_thinking_only_with_reason;
          Alcotest.test_case "custom predicate rejection is typed" `Quick
            test_rejects_visible_response_as_predicate_false;
        ] );
    ]
