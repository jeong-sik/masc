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

let message ?(role = Agent_sdk.Types.Assistant) content : Agent_sdk.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

let tool_use ?(input = `Assoc []) name =
  Agent_sdk.Types.ToolUse { id = "tool-1"; name; input }

let checkpoint_with_messages messages : Agent_sdk.Checkpoint.t =
  {
    Agent_sdk.Checkpoint.version = Agent_sdk.Checkpoint.checkpoint_version;
    session_id = "session-test";
    agent_name = "agent-test";
    model = "model-test";
    system_prompt = None;
    messages;
    usage = Agent_sdk.Types.empty_usage;
    turn_count = 1;
    created_at = 0.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_sdk.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;
    max_input_tokens = None;
    max_total_tokens = None;
    context = Agent_sdk.Context.create ();
    mcp_sessions = [];
    working_context = None;
  }

let run_result ?content ?stop_reason ?checkpoint () : Runtime_agent.run_result =
  {
    response = response ?content ?stop_reason ();
    checkpoint;
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

let test_runtime_error_mapping_preserves_no_progress_accept_rejection () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-model"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { thinking_type = "reasoning"; content = "internal chain" };
           ]
         ())
  in
  let err, _reason_kind, _reason = expect_accept_rejected result in
  let mapped =
    Masc.Keeper_turn_driver.For_testing.sdk_error_of_nonretryable_attempt_error
      ~original_error:err
      (Llm_provider.Http_client.AcceptRejected { reason = "flattened" })
  in
  let _mapped_err, mapped_reason_kind, mapped_reason =
    expect_accept_rejected (Error mapped)
  in
  Alcotest.(check bool)
    "runtime mapper keeps no usable progress kind"
    true
    (mapped_reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "runtime mapper keeps response-shape diagnostics"
    true
    (contains ~needle:"shape=thinking_only" mapped_reason);
  Alcotest.(check bool)
    "runtime mapper does not collapse to generic internal"
    true
    (Masc.Keeper_error_classify.is_accept_no_usable_progress_error mapped)

let test_last_tool_context_classifies_checkpoint_tool_use () =
  let read_messages =
    [
      message
        [
          tool_use
            ~input:(`Assoc [ ("file_path", `String "dune") ])
            "Read";
        ];
    ]
  in
  let write_messages =
    [
      message
        [
          tool_use
            ~input:
              (`Assoc
                [
                  ("file_path", `String "tmp.txt");
                  ("content", `String "hello");
                ])
            "Write";
        ];
    ]
  in
  let read_context =
    Masc.Keeper_turn_driver.For_testing.last_tool_progress_context_string_of_messages
      read_messages
  in
  let write_context =
    Masc.Keeper_turn_driver.For_testing.last_tool_progress_context_string_of_messages
      write_messages
  in
  Alcotest.(check (option string))
    "read-only alias context"
    (Some "last_tool=Read; last_tool_effect=read_only")
    read_context;
  Alcotest.(check (option string))
    "mutating alias context"
    (Some "last_tool=Write; last_tool_effect=mutating")
    write_context

let test_accept_reason_includes_last_tool_context () =
  let checkpoint =
    checkpoint_with_messages
      [
        message
          [
            tool_use
              ~input:
                (`Assoc
                  [
                    ("file_path", `String "tmp.txt");
                    ("content", `String "hello");
                  ])
              "Write";
          ];
      ]
  in
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-after-tool"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~checkpoint
         ~content:
           [
             Agent_sdk.Types.Thinking
               { thinking_type = "reasoning"; content = "internal chain" };
           ]
         ())
  in
  let _err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "reason includes last tool name"
    true
    (contains ~needle:"last_tool=Write" reason);
  Alcotest.(check bool)
    "reason includes last tool effect"
    true
    (contains ~needle:"last_tool_effect=mutating" reason)

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

let check_accept_matches_oas_shape label content =
  let response = response ~content () in
  let expected =
    response
    |> Agent_sdk.Response_shape.summarize
    |> Agent_sdk.Response_shape.has_deliverable_content
  in
  Alcotest.(check bool)
    label
    expected
    (Keeper_tool_response.response_has_text_or_tool_progress response)

let test_accept_contract_delegates_to_oas_response_shape () =
  check_accept_matches_oas_shape "empty" [];
  check_accept_matches_oas_shape
    "thinking only"
    [
      Agent_sdk.Types.Thinking
        { thinking_type = "reasoning"; content = "internal chain" };
    ];
  check_accept_matches_oas_shape "blank text" [ Agent_sdk.Types.Text " \n\t " ];
  check_accept_matches_oas_shape "text" [ Agent_sdk.Types.Text "visible answer" ];
  check_accept_matches_oas_shape
    "tool use"
    [
      Agent_sdk.Types.ToolUse
        { id = "tool-1"; name = "keeper_board_search"; input = `Assoc [] };
    ];
  check_accept_matches_oas_shape
    "tool result"
    [
      Agent_sdk.Types.ToolResult
        {
          tool_use_id = "tool-1";
          content = "ok";
          is_error = false;
          json = None;
          content_blocks = None;
        };
    ];
  check_accept_matches_oas_shape
    "media"
    [
      Agent_sdk.Types.Image
        { media_type = "image/png"; data = "redacted"; source_type = "base64" };
    ]

let test_thinking_only_non_end_turn_response_is_rejected () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-stop-sequence"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { thinking_type = "reasoning"; content = "internal chain" };
           ]
         ~stop_reason:Agent_sdk.Types.StopSequence
         ())
  in
  let _err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "reason identifies thinking-only shape"
    true
    (contains ~needle:"shape=thinking_only" reason);
  Alcotest.(check bool)
    "reason keeps non-end stop reason"
    true
    (contains ~needle:"stop_reason=stop_sequence" reason)

let test_empty_non_end_turn_response_is_rejected () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.empty-stop-sequence"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result ~stop_reason:Agent_sdk.Types.StopSequence ())
  in
  let err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "reason identifies empty shape"
    true
    (contains ~needle:"shape=empty" reason);
  Alcotest.(check bool)
    "reason keeps non-end stop reason"
    true
    (contains ~needle:"stop_reason=stop_sequence" reason);
  Alcotest.(check bool)
    "no-progress accept rejection is typed"
    true
    (Masc.Keeper_error_classify.is_accept_no_usable_progress_error err)

let test_blank_text_non_end_turn_response_is_rejected () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.blank-max-tokens"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:[ Agent_sdk.Types.Text " \n\t " ]
         ~stop_reason:Agent_sdk.Types.MaxTokens
         ())
  in
  let _err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "reason identifies blank text"
    true
    (contains ~needle:"shape=blank_text_only" reason);
  Alcotest.(check bool)
    "reason reports zero trimmed text chars"
    true
    (contains ~needle:"text_chars=0" reason);
  Alcotest.(check bool)
    "reason keeps max-token stop reason"
    true
    (contains ~needle:"stop_reason=max_tokens" reason)

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

let test_sse_event_progress_kind_classifies_known_deltas () =
  let open Agent_sdk.Types in
  let kind event = Masc.Keeper_agent_run_turn_helpers.sse_event_progress_kind event in
  Alcotest.(check (option string))
    "text delta"
    (Some "sse_text_delta")
    (kind (ContentBlockDelta { index = 0; delta = TextDelta "visible" }));
  Alcotest.(check (option string))
    "thinking delta"
    (Some "sse_thinking_delta")
    (kind (ContentBlockDelta { index = 0; delta = ThinkingDelta "hidden" }));
  Alcotest.(check (option string))
    "tool arg delta"
    (Some "sse_tool_arg_delta")
    (kind (ContentBlockDelta { index = 0; delta = InputJsonDelta "{}" }))

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
          Alcotest.test_case
            "runtime mapping preserves no-progress accept rejection"
            `Quick
            test_runtime_error_mapping_preserves_no_progress_accept_rejection;
          Alcotest.test_case "last tool context classifies checkpoint tools" `Quick
            test_last_tool_context_classifies_checkpoint_tool_use;
          Alcotest.test_case
            "accept rejection reason includes last tool context"
            `Quick
            test_accept_reason_includes_last_tool_context;
          Alcotest.test_case "thinking plus text is accepted" `Quick
            test_thinking_with_text_is_accepted;
          Alcotest.test_case "thinking plus tool use is accepted" `Quick
            test_thinking_with_tool_use_is_accepted;
          Alcotest.test_case "accept delegates to OAS response shape" `Quick
            test_accept_contract_delegates_to_oas_response_shape;
          Alcotest.test_case "thinking-only non-end-turn response is rejected" `Quick
            test_thinking_only_non_end_turn_response_is_rejected;
          Alcotest.test_case "empty non-end-turn response is rejected" `Quick
            test_empty_non_end_turn_response_is_rejected;
          Alcotest.test_case "blank text non-end-turn response is rejected" `Quick
            test_blank_text_non_end_turn_response_is_rejected;
          Alcotest.test_case "custom predicate rejection stays distinct" `Quick
            test_custom_accept_reject_preserves_predicate_reason;
          Alcotest.test_case "mixed non-progress rejection is diagnosed" `Quick
            test_reject_reason_describes_mixed_non_progress_response;
          Alcotest.test_case "sse progress classifies known deltas" `Quick
            test_sse_event_progress_kind_classifies_known_deltas;
        ] );
    ]
