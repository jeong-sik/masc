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

let accept_no_progress_retry_kind_string err =
  let kind =
    match Masc.Keeper_turn_driver.classify_masc_internal_error err with
    | Some internal_error ->
      Masc.Keeper_turn_driver.accept_no_progress_retry_kind internal_error
    | None -> None
  in
  Option.map
    (function
      | `Empty_no_progress -> "empty_no_progress"
      | `Read_only_no_progress -> "read_only_no_progress")
    kind

let direct_empty_no_progress_retry_reason_string err =
  Option.map
    Masc.Keeper_error_classify.degraded_retry_reason_to_string
    (Masc.Keeper_turn.For_testing.direct_empty_no_progress_retry_reason err)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let direct_retry_runtime_toml =
  {|
[runtime]
default = "test_provider.test_model"

[providers.test_provider]
display-name = "Test Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[test_provider.test_model]
is-default = true
max-concurrent = 1
|}

let with_direct_retry_runtime f =
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "direct_retry_runtime_" ".toml" in
  write_file path direct_retry_runtime_toml;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.init_default ~config_path:path with
       | Ok () -> f ()
       | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e)

let direct_empty_no_progress_retry_decision ?time_spent_in_turn_s err =
  Masc.Keeper_turn.For_testing.direct_empty_no_progress_retry_decision
    ~base_runtime:"test_provider.test_model"
    ~effective_runtime:"runtime.direct-empty"
    ~attempted_runtimes:[ "runtime.direct-empty" ]
    ~estimated_input_tokens:1
    ?time_spent_in_turn_s
    ~remaining_turn_budget_s:60.0
    err

let test_keeper_hook_relaxes_strict_tool_choice () =
  let open Agent_sdk.Types in
  let relax = Masc.Keeper_run_tools_hooks.relax_strict_tool_choice_for_keeper in
  Alcotest.(check bool) "Any -> Auto" true (relax (Some Any) = Some Auto);
  Alcotest.(check bool)
    "Tool -> Auto"
    true
    (relax (Some (Tool "keeper_context_status")) = Some Auto);
  Alcotest.(check bool)
    "Auto unchanged"
    true
    (relax (Some Auto) = Some Auto);
  Alcotest.(check bool)
    "None_ unchanged"
    true
    (relax (Some None_) = Some None_);
  Alcotest.(check bool) "unset unchanged" true (relax None = None)

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

let accept_rejected_sdk_error
    ?any_mutating_tool
    ?(tool_effects_seen = [])
    ~response_shape
    ~last_tool_effect
    ~reason
    () =
  Keeper_internal_error.sdk_error_of_masc_internal_error
    (Keeper_internal_error.Accept_rejected
       { scope = "runtime.changed-diagnostic"
       ; model = None
       ; reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
       ; response_shape
       ; last_tool_effect
       ; any_mutating_tool
       ; tool_effects_seen
       ; reason
       })

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
    (Masc.Keeper_error_classify.is_runtime_exhausted_error err);
  Alcotest.(check bool)
    "thinking-only without read-only tool does not try next candidate"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "thinking-only without read-only tool is not runtime-recoverable"
    None
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err))

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
    (Some
       "last_tool=Read; last_tool_effect=read_only; any_mutating_tool=false; \
        tool_effects_seen=read_only")
    read_context;
  Alcotest.(check (option string))
    "mutating alias context"
    (Some
       "last_tool=Write; last_tool_effect=mutating; any_mutating_tool=true; \
        tool_effects_seen=mutating")
    write_context

let test_last_tool_context_treats_workspace_mutations_as_mutating () =
  let cases =
    [
      ( "keeper_board_post"
      , `Assoc [ "title", `String "t"; "body", `String "b" ] );
      "keeper_broadcast", `Assoc [ "message", `String "hello" ];
      ( "masc_transition"
      , `Assoc [ "task_id", `String "t1"; "status", `String "done" ] );
    ]
  in
  List.iter
    (fun (tool_name, input) ->
       let context =
         Masc.Keeper_turn_driver.For_testing
         .last_tool_progress_context_string_of_messages
           [ message [ tool_use ~input tool_name ] ]
       in
       Alcotest.(check (option string))
         (tool_name ^ " context")
         (Some
            (Printf.sprintf
               "last_tool=%s; last_tool_effect=mutating; any_mutating_tool=true; \
                tool_effects_seen=mutating"
               tool_name))
         context)
    cases

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
  let err, reason_kind, reason = expect_accept_rejected result in
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
    (contains ~needle:"last_tool_effect=mutating" reason);
  Alcotest.(check bool)
    "reason includes any mutating summary"
    true
    (contains ~needle:"any_mutating_tool=true" reason);
  Alcotest.(check bool)
    "reason includes effects seen"
    true
    (contains ~needle:"tool_effects_seen=mutating" reason);
  Alcotest.(check bool)
    "thinking-only after mutating tool does not try next candidate"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "thinking-only after mutating tool is not runtime-recoverable"
    None
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err))

let test_thinking_only_after_mutation_then_read_does_not_try_next_candidate () =
  let checkpoint =
    checkpoint_with_messages
      [
        message
          [
            tool_use
              ~input:
                (`Assoc
                  [
                    ("title", `String "checkpoint");
                    ("body", `String "keeper posted progress");
                  ])
              "keeper_board_post";
          ];
        message
          [ tool_use ~input:(`Assoc [ ("file_path", `String "dune") ]) "Read" ];
      ]
  in
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-after-mutation-then-read"
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
  let err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "last tool remains visible"
    true
    (contains ~needle:"last_tool=Read" reason);
  Alcotest.(check bool)
    "last tool remains read-only"
    true
    (contains ~needle:"last_tool_effect=read_only" reason);
  Alcotest.(check bool)
    "earlier mutation is summarized"
    true
    (contains ~needle:"any_mutating_tool=true" reason);
  Alcotest.(check bool)
    "effects seen captures both classes"
    true
    (contains ~needle:"tool_effects_seen=mutating,read_only" reason);
  Alcotest.(check bool)
    "earlier mutation disables read-only retry"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "earlier mutation is not runtime-recoverable"
    None
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err))

let test_historical_mutation_does_not_block_current_read_only_retry () =
  let history_messages =
    [
      message
        [
          tool_use
            ~input:
              (`Assoc
                [
                  ("title", `String "old checkpoint");
                  ("body", `String "previous turn posted progress");
                ])
            "keeper_board_post";
        ];
    ]
  in
  let current_attempt_messages =
    [ message [ tool_use ~input:(`Assoc [ ("file_path", `String "dune") ]) "Read" ] ]
  in
  let checkpoint =
    checkpoint_with_messages (history_messages @ current_attempt_messages)
  in
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~initial_messages:history_messages
      ~runtime_id:"runtime.thinking-after-historical-mutation-current-read"
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
  let err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "current last tool remains visible"
    true
    (contains ~needle:"last_tool=Read" reason);
  Alcotest.(check bool)
    "historical mutation is not counted as current attempt mutation"
    true
    (contains ~needle:"any_mutating_tool=false" reason);
  Alcotest.(check bool)
    "effects seen only includes current attempt read-only tool"
    true
    (contains ~needle:"tool_effects_seen=read_only" reason);
  Alcotest.(check bool)
    "current read-only no-progress tries next candidate"
    true
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "current read-only no-progress classified by internal-error SSOT"
    (Some "read_only_no_progress")
    (accept_no_progress_retry_kind_string err);
  Alcotest.(check (option string))
    "current read-only no-progress is runtime-recoverable"
    (Some "read_only_no_progress")
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err))

let test_thinking_only_after_read_only_webfetch_can_try_next_candidate () =
  let checkpoint =
    checkpoint_with_messages
      [
        message
          [
            tool_use
              ~input:(`Assoc [ ("url", `String "https://example.com") ])
              "WebFetch";
          ];
      ]
  in
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-after-webfetch"
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
    "reason includes read-only tool name"
    true
    (contains ~needle:"last_tool=WebFetch" reason);
  Alcotest.(check bool)
    "reason includes read-only tool effect"
    true
    (contains ~needle:"last_tool_effect=read_only" reason);
  Alcotest.(check bool)
    "reason includes no-mutating summary"
    true
    (contains ~needle:"any_mutating_tool=false" reason);
  Alcotest.(check bool)
    "reason includes read-only effects seen"
    true
    (contains ~needle:"tool_effects_seen=read_only" reason);
  Alcotest.(check bool)
    "thinking-only after read-only tool tries next candidate"
    true
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "thinking-only after read-only tool is runtime-recoverable"
    (Some "read_only_no_progress")
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err))

let test_thinking_only_after_workspace_mutation_stays_terminal () =
  let cases =
    [
      ( "keeper_board_post"
      , `Assoc [ "title", `String "t"; "body", `String "b" ] );
      "keeper_broadcast", `Assoc [ "message", `String "hello" ];
      ( "masc_transition"
      , `Assoc [ "task_id", `String "t1"; "status", `String "done" ] );
    ]
  in
  List.iter
    (fun (tool_name, input) ->
       let checkpoint =
         checkpoint_with_messages
           [ message [ tool_use ~input tool_name ] ]
       in
       let result =
         Masc.Keeper_turn_driver.For_testing.apply_accept
           ~runtime_id:("runtime.thinking-after-" ^ tool_name)
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
       let err, reason_kind, reason = expect_accept_rejected result in
       Alcotest.(check bool)
         (tool_name ^ " reason kind")
         true
         (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
       Alcotest.(check bool)
         (tool_name ^ " reason marks mutation")
         true
         (contains ~needle:"last_tool_effect=mutating" reason);
       Alcotest.(check bool)
         (tool_name ^ " does not try next candidate")
         false
         (Masc.Keeper_turn_driver.For_testing
          .accept_no_progress_read_only_should_try_next
            err);
       Alcotest.(check (option string))
         (tool_name ^ " is not runtime-recoverable")
         None
         (Option.map
            Masc.Keeper_error_classify.degraded_retry_reason_to_string
            (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err)))
    cases

let test_read_only_retry_uses_typed_context_not_reason_tokens () =
  let typed_err =
    accept_rejected_sdk_error
      ~response_shape:(Some Keeper_internal_error.Accept_response_thinking_only)
      ~last_tool_effect:(Some Keeper_internal_error.Tool_effect_read_only)
      ~any_mutating_tool:false
      ~tool_effects_seen:[ Keeper_internal_error.Tool_effect_read_only ]
      ~reason:"diagnostic wording changed; no legacy retry tokens"
      ()
  in
  Alcotest.(check bool)
    "typed thinking/read-only context retries despite changed wording"
    true
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       typed_err);
  Alcotest.(check (option string))
    "typed thinking/read-only context is runtime-recoverable"
    (Some "read_only_no_progress")
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason typed_err));
  Alcotest.(check (option string))
    "direct keeper_msg does not rotate read-only no-progress"
    None
    (direct_empty_no_progress_retry_reason_string typed_err);
  let string_only_err =
    accept_rejected_sdk_error
      ~response_shape:None
      ~last_tool_effect:None
      ~reason:
        "legacy text only: shape=thinking_only; last_tool_effect=read_only"
      ()
  in
  Alcotest.(check bool)
    "legacy reason tokens alone do not trigger retry"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       string_only_err);
	  Alcotest.(check (option string))
	    "legacy reason tokens alone are not runtime-recoverable"
	    None
	    (Option.map
	       Masc.Keeper_error_classify.degraded_retry_reason_to_string
	       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason
	          string_only_err))

let test_direct_empty_no_progress_retry_uses_shared_budget_decision () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
        ~last_tool_effect:None
        ~reason:"shape=empty"
        ()
    in
    (match direct_empty_no_progress_retry_decision empty_err with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed retry ->
       Alcotest.(check string)
         "allowed reason"
         "empty_no_progress"
         (Masc.Keeper_error_classify.degraded_retry_reason_to_string
            retry.fallback_reason)
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted _ ->
       Alcotest.fail "fresh direct empty retry should not exhaust slot phase"
     | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
       Alcotest.fail "fresh direct empty retry should rotate");
    let exhausted_after =
      Masc.Keeper_turn_runtime_budget.degraded_retry_slot_phase_budget_sec +. 1.0
    in
    (match
       direct_empty_no_progress_retry_decision
         ~time_spent_in_turn_s:exhausted_after
         empty_err
     with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted retry
       ->
       Alcotest.(check string)
         "slot-exhausted reason"
         "empty_no_progress"
         (Masc.Keeper_error_classify.degraded_retry_reason_to_string
            retry.fallback_reason)
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed _ ->
       Alcotest.fail "exhausted direct empty retry should not rotate"
     | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
       Alcotest.fail "exhausted direct empty retry should report slot exhaustion");
    let read_only_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_thinking_only)
        ~last_tool_effect:(Some Keeper_internal_error.Tool_effect_read_only)
        ~any_mutating_tool:false
        ~tool_effects_seen:[ Keeper_internal_error.Tool_effect_read_only ]
        ~reason:"shape=thinking_only"
        ()
    in
    Alcotest.(check bool)
      "direct read-only no-progress remains terminal"
      true
      (match direct_empty_no_progress_retry_decision read_only_err with
       | Masc.Keeper_turn_runtime_budget.No_degraded_retry -> true
       | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed _
       | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted _ ->
         false))

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
    (Masc.Keeper_error_classify.is_accept_no_usable_progress_error err);
  Alcotest.(check bool)
    "empty no-progress can try next candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next err);
  Alcotest.(check bool)
    "empty no-progress is not a read-only retry"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "empty no-progress classified by internal-error SSOT"
    (Some "empty_no_progress")
    (accept_no_progress_retry_kind_string err);
  Alcotest.(check (option string))
    "empty no-progress is runtime-recoverable"
    (Some "empty_no_progress")
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err));
  (match Masc.Keeper_turn_driver.classify_masc_internal_error err with
   | Some internal_error ->
     Alcotest.(check string)
       "accept rejection runtime id uses scope"
       "runtime.empty-stop-sequence"
       (Masc.Keeper_turn_driver.runtime_id_of_masc_internal_error internal_error);
     Alcotest.(check bool)
       "summary describes provider empty turn"
       true
       (Option.value
          ~default:false
          (Option.map
             (contains ~needle:"empty assistant turn")
             (Masc.Keeper_turn_driver.summary_of_masc_internal_error internal_error)))
   | None -> Alcotest.fail "expected typed accept rejection");
  (match Masc.Keeper_status_bridge.blocker_class_of_sdk_error err with
   | Some Masc.Keeper_meta_contract.Completion_contract_violation -> ()
   | Some other ->
     Alcotest.failf
       "expected completion_contract_violation blocker, got %s"
       (Masc.Keeper_meta_contract.blocker_class_to_string other)
   | None -> Alcotest.fail "expected accept rejection blocker class");
  Alcotest.(check (option string))
    "direct keeper_msg rotates empty no-progress"
    (Some "empty_no_progress")
    (direct_empty_no_progress_retry_reason_string err)

let test_empty_after_workspace_mutation_stays_terminal () =
  let checkpoint =
    checkpoint_with_messages
      [
        message
          [
            tool_use
              ~input:(`Assoc [ "title", `String "t"; "body", `String "b" ])
              "keeper_board_post";
          ];
      ]
  in
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.empty-after-mutation"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result ~checkpoint ())
  in
  let err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "reason kind is no usable progress"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "reason includes mutating tool context"
    true
    (contains ~needle:"last_tool_effect=mutating" reason);
  Alcotest.(check bool)
    "empty response after mutation does not try next candidate"
    false
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next err);
  Alcotest.(check (option string))
    "empty response after mutation is not runtime-recoverable"
    None
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err));
  Alcotest.(check (option string))
    "direct keeper_msg does not rotate after mutation"
    None
    (direct_empty_no_progress_retry_reason_string err)

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
    (kind (ContentBlockDelta { index = 0; delta = InputJsonDelta "{}" }));
  Alcotest.(check (option string))
    "stream incomplete"
    (Some "sse_stream_incomplete")
    (kind (StreamIncomplete { reason = "max_output_tokens" }))

let () =
  Alcotest.run "keeper_turn_driver_accept"
    [
      ( "accept"
      , [
          Alcotest.test_case "accepted response passes through" `Quick
            test_accept_keeps_result;
          Alcotest.test_case
            "strict tool_choice is relaxed to auto"
            `Quick
            test_keeper_hook_relaxes_strict_tool_choice;
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
            "last tool context treats workspace mutations as mutating"
            `Quick
            test_last_tool_context_treats_workspace_mutations_as_mutating;
          Alcotest.test_case
            "accept rejection reason includes last tool context"
            `Quick
            test_accept_reason_includes_last_tool_context;
          Alcotest.test_case
            "thinking-only after mutation then read does not try next candidate"
            `Quick
            test_thinking_only_after_mutation_then_read_does_not_try_next_candidate;
          Alcotest.test_case
            "historical mutation does not block current read-only retry"
            `Quick
            test_historical_mutation_does_not_block_current_read_only_retry;
          Alcotest.test_case
            "thinking-only after read-only WebFetch tries next candidate"
            `Quick
            test_thinking_only_after_read_only_webfetch_can_try_next_candidate;
          Alcotest.test_case
            "thinking-only after workspace mutation stays terminal"
            `Quick
            test_thinking_only_after_workspace_mutation_stays_terminal;
          Alcotest.test_case
            "read-only retry uses typed context, not reason tokens"
            `Quick
            test_read_only_retry_uses_typed_context_not_reason_tokens;
          Alcotest.test_case
            "direct empty no-progress retry uses shared budget decision"
            `Quick
            test_direct_empty_no_progress_retry_uses_shared_budget_decision;
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
          Alcotest.test_case
            "empty response after workspace mutation stays terminal"
            `Quick
            test_empty_after_workspace_mutation_stays_terminal;
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
