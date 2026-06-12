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
    Masc.Keeper_turn_driver.For_testing.apply_accept
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

let test_rejects_as_typed_accept_error () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"ollama.gemma4-26b-a4b-qat"
      ~accept:(fun _ -> false)
      (run_result ())
  in
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
         (contains ~needle:"response rejected by accept" reason)
     | Some other ->
       Alcotest.failf "expected Accept_rejected, got %s"
         (Keeper_internal_error.kind_of_masc_internal_error other)
     | None ->
       Alcotest.failf "expected typed keeper error, got %s"
         (Agent_sdk.Error.to_string err))

let expect_accept_rejected result =
  match result with
  | Ok _ -> Alcotest.fail "rejected response should fail"
  | Error err ->
    (match Keeper_internal_error.classify_masc_internal_error err with
     | Some (Keeper_internal_error.Accept_rejected { reason_kind; reason; _ }) ->
       err, reason_kind, reason
     | Some other ->
       Alcotest.failf "expected Accept_rejected, got %s"
         (Keeper_internal_error.kind_of_masc_internal_error other)
     | None ->
       Alcotest.failf "expected typed keeper error, got %s"
         (Agent_sdk.Error.to_string err))

let test_reject_reason_describes_thinking_only_response () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-model"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { thinking_type = "reasoning"; content = "abcde" };
           ]
         ())
  in
  let err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "reason identifies thinking-only shape"
    true
    (contains ~needle:"shape=thinking_only" reason);
  Alcotest.(check bool)
    "reason reports thinking block count"
    true
    (contains ~needle:"thinking_blocks=1" reason);
  Alcotest.(check bool)
    "reason reports thinking char count without content"
    true
    (contains ~needle:"thinking_chars=5" reason);
  Alcotest.(check bool)
    "no-progress accept rejection is typed"
    true
    (Masc.Keeper_error_classify.is_accept_no_usable_progress_error err);
  Alcotest.(check bool)
    "no-progress accept rejection is not auto-recoverable"
    false
    (Masc.Keeper_error_classify.is_auto_recoverable_turn_error err);
  Alcotest.(check bool)
    "no-progress accept rejection is not warn-handled"
    false
    (Masc.Keeper_error_classify.should_warn_keeper_cycle_failed err);
  Alcotest.(check bool)
    "no-progress accept rejection is not runtime exhaustion"
    false
    (Masc.Keeper_error_classify.is_runtime_exhausted_error err)

let test_thinking_with_text_is_accepted () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-text"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { thinking_type = "reasoning"; content = "internal chain" };
             Agent_sdk.Types.Text "final answer";
           ]
         ())
  in
  match result with
  | Ok kept ->
    Alcotest.(check string) "session preserved" "session-test" kept.session_id
  | Error err ->
    Alcotest.failf "thinking plus text should pass accept: %s"
      (Agent_sdk.Error.to_string err)

let test_thinking_with_tool_use_is_accepted () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-tool"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { thinking_type = "reasoning"; content = "internal chain" };
             Agent_sdk.Types.ToolUse
               { id = "tool-1"; name = "keeper_board_search"; input = `Assoc [] };
           ]
         ())
  in
  match result with
  | Ok kept ->
    Alcotest.(check string) "session preserved" "session-test" kept.session_id
  | Error err ->
    Alcotest.failf "thinking plus tool use should pass accept: %s"
      (Agent_sdk.Error.to_string err)

let test_custom_accept_reject_preserves_predicate_reason () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.custom"
      ~accept:(fun _ -> false)
      (run_result ~content:[ Agent_sdk.Types.Text "visible answer" ] ())
  in
  let err, reason_kind, _reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "custom predicate rejection kind is distinct"
    true
    (reason_kind = Some Keeper_internal_error.Accept_predicate_rejected);
  Alcotest.(check bool)
    "custom predicate rejection is not no-progress"
    false
    (Masc.Keeper_error_classify.is_accept_no_usable_progress_error err);
  Alcotest.(check bool)
    "custom predicate rejection is not auto-recoverable"
    false
    (Masc.Keeper_error_classify.is_auto_recoverable_turn_error err)

let test_reject_reason_describes_mixed_non_progress_response () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.mixed"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.ToolResult
               {
                 tool_use_id = "tool-1";
                 content = "ok";
                 is_error = false;
                 json = None;
                 content_blocks = None;
               };
             Agent_sdk.Types.Image
               {
                 media_type = "image/png";
                 data = "redacted";
                 source_type = "base64";
               };
           ]
         ())
  in
  let _err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "mixed non-progress response is not labeled tool-result-only"
    true
    (contains ~needle:"shape=mixed_without_deliverable_content" reason);
  Alcotest.(check bool)
    "reason reports tool result count"
    true
    (contains ~needle:"tool_result_count=1" reason);
  Alcotest.(check bool)
    "reason reports image count"
    true
    (contains ~needle:"image_count=1" reason)

let () =
  Alcotest.run "keeper_turn_driver_accept"
    [
      ( "accept"
      , [
          Alcotest.test_case "accepted response passes through" `Quick
            test_accept_keeps_result;
          Alcotest.test_case "rejected response is typed" `Quick
            test_rejects_as_typed_accept_error;
          Alcotest.test_case "thinking-only rejection is diagnosed" `Quick
            test_reject_reason_describes_thinking_only_response;
          Alcotest.test_case "thinking plus text is accepted" `Quick
            test_thinking_with_text_is_accepted;
          Alcotest.test_case "thinking plus tool use is accepted" `Quick
            test_thinking_with_tool_use_is_accepted;
          Alcotest.test_case "custom predicate rejection stays distinct" `Quick
            test_custom_accept_reject_preserves_predicate_reason;
          Alcotest.test_case "mixed non-progress rejection is diagnosed" `Quick
            test_reject_reason_describes_mixed_non_progress_response;
        ] );
    ]
