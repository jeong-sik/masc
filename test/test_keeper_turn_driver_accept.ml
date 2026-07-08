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

    context = Agent_sdk.Context.create_sync ();
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
      | `Read_only_no_progress -> "read_only_no_progress"
      | `Thinking_only_no_progress -> "thinking_only_no_progress")
    kind

let direct_no_progress_retry_reason_string err =
  Option.map
    Masc.Keeper_error_classify.degraded_retry_reason_to_string
    (Masc.Keeper_turn_runtime_budget.direct_no_progress_retry_reason err)

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let source_path path =
  if Filename.is_relative path then
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> Filename.concat root path
    | None -> path
  else path

let read_source_file path =
  In_channel.with_open_text (source_path path) In_channel.input_all

let index_of ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    if i + needle_len > haystack_len then None
    else if String.equal (String.sub haystack i needle_len) needle then Some i
    else loop (i + 1)
  in
  if needle_len = 0 then Some 0 else loop 0

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

let direct_no_progress_retry_decision ?time_spent_in_turn_s err =
  Masc.Keeper_turn_runtime_budget.direct_no_progress_retry_decision
    ~base_runtime:"test_provider.test_model"
    ~effective_runtime:"runtime.direct-empty"
    ~attempted_runtimes:[ "runtime.direct-empty" ]
    ~estimated_input_tokens:1
    ?time_spent_in_turn_s
    ~remaining_turn_budget_s:60.0
    err

type direct_retry_observed_attempt =
  { observed_runtime_id : string
  ; observed_max_context : int
  ; observed_is_retry : bool
  ; observed_degraded_retry_runtime : string option
  ; observed_fallback_reason : string option
  ; observed_rotation_attempt_count : int
  }

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
    ?(stop_reason = None)
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
       ; stop_reason
       ; last_tool_effect
       ; any_mutating_tool
       ; tool_effects_seen
       ; reason
       })

let test_accept_rejected_threads_stop_reason () =
  (* RFC-0271 §4.5 slice 1: apply_accept preserves the provider's typed
     stop_reason on the rejected turn's Accept_rejected, so a MaxTokens
     truncation is later distinguishable from a clean EndTurn no-progress
     terminal. Behaviour-neutral groundwork — no classification change yet. *)
  let threaded sr =
    match
      Masc.Keeper_turn_driver.For_testing.apply_accept
        ~runtime_id:"runtime.truncation"
        ~accept:(fun _ -> false)
        (run_result ~stop_reason:sr ())
    with
    | Ok _ -> Alcotest.fail "rejected response should fail"
    | Error err ->
      (match Keeper_internal_error.classify_masc_internal_error err with
       | Some (Keeper_internal_error.Accept_rejected { stop_reason; _ }) ->
         stop_reason
       | _ -> Alcotest.fail "expected Accept_rejected")
  in
  Alcotest.(check bool) "MaxTokens threaded" true
    (threaded Agent_sdk.Types.MaxTokens = Some Agent_sdk.Types.MaxTokens);
  Alcotest.(check bool) "EndTurn threaded" true
    (threaded Agent_sdk.Types.EndTurn = Some Agent_sdk.Types.EndTurn)

let test_accept_rejected_stop_reason_survives_codec () =
  (* to_json -> of_json preserves the typed stop_reason (Slice 1 codec). *)
  let err =
    accept_rejected_sdk_error
      ~stop_reason:(Some Agent_sdk.Types.MaxTokens)
      ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
      ~last_tool_effect:None
      ~reason:"response rejected by accept (runtime=x): shape=empty"
      ()
  in
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Accept_rejected { stop_reason; _ }) ->
    Alcotest.(check bool) "stop_reason survives codec round-trip" true
      (stop_reason = Some Agent_sdk.Types.MaxTokens)
  | _ -> Alcotest.fail "expected Accept_rejected after codec round-trip"

let test_reject_reason_describes_thinking_only_response () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-model"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { signature = None; content = "abcde" };
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
    "thinking-only without read-only tool is not a read-only retry"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check bool)
    "thinking-only without tool can try next candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next err);
  Alcotest.(check (option string))
    "thinking-only without tool is runtime-recoverable"
    (Some "thinking_only_no_progress")
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err))

let test_finalization_blank_response_is_typed_accept_rejection () =
  let result =
    Masc.Keeper_agent_run.For_testing.normalize_response_text_for_finalization
      ~runtime_id:"ollama.gemma4-26b-a4b-qat"
      ~initial_messages:[]
      ~run_result:(run_result ())
      ~text:""
      ~tool_names:[]
      ()
  in
  match result with
  | Ok text -> Alcotest.failf "blank response should fail, got %S" text
  | Error err ->
    (match Keeper_internal_error.classify_masc_internal_error err with
     | Some
         (Keeper_internal_error.Accept_rejected
            { scope; reason_kind; reason; _ }) ->
       Alcotest.(check string)
         "scope"
         "ollama.gemma4-26b-a4b-qat"
         scope;
       Alcotest.(check bool)
         "reason kind is no usable progress"
         true
         (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
       Alcotest.(check bool)
         "reason identifies empty shape"
         true
         (contains ~needle:"shape=empty" reason);
       Alcotest.(check bool)
         "typed no-progress classification"
         true
         (Masc.Keeper_error_classify.is_accept_no_usable_progress_error err)
     | Some other ->
       Alcotest.failf "expected Accept_rejected, got %s"
         (Keeper_internal_error.kind_of_masc_internal_error other)
     | None ->
       Alcotest.failf "expected typed keeper error, got %s"
         (Agent_sdk.Error.to_string err))

let test_runtime_error_mapping_preserves_no_progress_accept_rejection () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-model"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { signature = None; content = "internal chain" };
           ]
         ())
  in
  let err, _reason_kind, _reason = expect_accept_rejected result in
  let mapped =
    Masc.Keeper_turn_driver.For_testing.sdk_error_of_nonretryable_attempt_error
      ~runtime_id:"runtime.thinking-model"
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
               { signature = None; content = "internal chain" };
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
               { signature = None; content = "internal chain" };
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
               { signature = None; content = "internal chain" };
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
  Alcotest.(check bool)
    "non-last read-only accept rejection advances provider candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:false
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
               { signature = None; content = "internal chain" };
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
  Alcotest.(check bool)
    "non-last read-only WebFetch accept rejection advances provider candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:false
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
                    { signature = None; content = "internal chain" };
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
    (direct_no_progress_retry_reason_string typed_err);
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

let test_direct_no_progress_retry_uses_shared_budget_decision () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
        ~last_tool_effect:None
        ~reason:"shape=empty"
        ()
    in
    (match direct_no_progress_retry_decision empty_err with
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
       direct_no_progress_retry_decision
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
    let thinking_only_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_thinking_only)
        ~last_tool_effect:None
        ~reason:"shape=thinking_only"
        ()
    in
    (match direct_no_progress_retry_decision thinking_only_err with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed retry ->
       Alcotest.(check string)
         "thinking-only allowed reason"
         "thinking_only_no_progress"
         (Masc.Keeper_error_classify.degraded_retry_reason_to_string
            retry.fallback_reason)
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted _ ->
       Alcotest.fail
         "fresh direct thinking-only retry should not exhaust slot phase"
     | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
       Alcotest.fail "fresh direct thinking-only retry should rotate");
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
      (match direct_no_progress_retry_decision read_only_err with
       | Masc.Keeper_turn_runtime_budget.No_degraded_retry -> true
	       | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed _
	       | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted _ ->
	         false))

let cascade_decision_to_string
    (decision : Masc.Keeper_unified_turn_cascade_resolution.cascade_decision_kind) =
  match decision with
  | Degraded_retry_allowed -> "degraded_retry_allowed"
  | Degraded_retry_slot_phase_exhausted -> "degraded_retry_slot_phase_exhausted"
  | No_degraded_retry -> "no_degraded_retry"
  | Transient_network_retry -> "transient_network_retry"

let prepare_retry_observers () =
  let published = ref [] in
  let selected = ref [] in
  let rotated = ref [] in
  let publish_cascade_resolution
      ~runtime_id ~decision ~reason ~next_runtime ~attempt _err =
    published :=
      ( runtime_id
      , cascade_decision_to_string decision
      , reason
      , next_runtime
      , attempt )
      :: !published
  in
  let emit_runtime_selected ~runtime_id ~fallback_reason =
    selected := (runtime_id, fallback_reason) :: !selected
  in
  let emit_runtime_rotation ~from_runtime ~to_runtime ~reason =
    rotated := (from_runtime, to_runtime, reason) :: !rotated
  in
  published, selected, rotated, publish_cascade_resolution,
  emit_runtime_selected, emit_runtime_rotation

let test_prepare_degraded_retry_rejects_empty_runtime () =
  let published, selected, rotated, publish_cascade_resolution,
      emit_runtime_selected, emit_runtime_rotation =
    prepare_retry_observers ()
  in
  let setup_called = ref false in
  let err = Agent_sdk.Error.Internal "empty direct response" in
  let retry : Masc.Keeper_error_classify.degraded_retry =
    {
      next_runtime = " \t ";
      fallback_reason = Masc.Keeper_error_classify.Empty_no_progress;
    }
  in
  match
    Masc.Keeper_turn_runtime_budget.prepare_degraded_retry_allowed
      ~current_runtime_id:"runtime.direct-empty"
      ~attempt:1
      ~err
      ~retry
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime:(fun _ ->
        setup_called := true;
        Ok ())
  with
  | Masc.Keeper_turn_runtime_budget.Degraded_retry_prepared _ ->
    Alcotest.fail "empty next_runtime must not prepare a retry"
  | Masc.Keeper_turn_runtime_budget.Degraded_retry_setup_failed
      { reason; fail_open_err; _ } ->
    Alcotest.(check string) "reason preserved" "empty_no_progress" reason;
    Alcotest.(check bool) "setup not called" false !setup_called;
    Alcotest.(check bool)
      "failure is explicit"
      true
      (contains
         ~needle:"degraded retry selected empty next_runtime"
         (Agent_sdk.Error.to_string fail_open_err));
    Alcotest.(check (list (pair string string)))
      "no runtime-selected metric for empty target"
      []
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "no rotation metric for empty target"
      []
      (List.rev !rotated);
    (match List.rev !published with
     | [ (runtime_id, decision, reason, next_runtime, attempt) ] ->
       Alcotest.(check string)
         "published from current runtime"
         "runtime.direct-empty"
         runtime_id;
       Alcotest.(check string)
         "empty target publishes terminal decision"
         "no_degraded_retry"
         decision;
       Alcotest.(check string)
         "publish reason identifies empty target"
         "empty_degraded_retry_runtime"
         reason;
       Alcotest.(check (option string)) "no next runtime" None next_runtime;
       Alcotest.(check int) "attempt" 1 attempt
     | rows ->
       Alcotest.failf "expected one cascade event, got %d" (List.length rows))

let test_prepare_degraded_retry_reports_setup_failure () =
  let published, selected, rotated, publish_cascade_resolution,
      emit_runtime_selected, emit_runtime_rotation =
    prepare_retry_observers ()
  in
  let err = Agent_sdk.Error.Internal "empty direct response" in
  let setup_err = Agent_sdk.Error.Internal "retry setup failed" in
  let retry : Masc.Keeper_error_classify.degraded_retry =
    {
      next_runtime = " runtime.fallback ";
      fallback_reason = Masc.Keeper_error_classify.Empty_no_progress;
    }
  in
  match
    Masc.Keeper_turn_runtime_budget.prepare_degraded_retry_allowed
      ~current_runtime_id:"runtime.direct-empty"
      ~attempt:2
      ~err
      ~retry
      ~publish_cascade_resolution
      ~emit_runtime_selected
      ~emit_runtime_rotation
      ~setup_runtime:(fun runtime_id ->
        Alcotest.(check string)
          "setup sees normalized runtime"
          "runtime.fallback"
          runtime_id;
        Error setup_err)
  with
  | Masc.Keeper_turn_runtime_budget.Degraded_retry_prepared _ ->
    Alcotest.fail "setup failure must not prepare a retry"
  | Masc.Keeper_turn_runtime_budget.Degraded_retry_setup_failed
      { retry; reason; fail_open_err } ->
    Alcotest.(check string) "normalized retry runtime" "runtime.fallback"
      retry.next_runtime;
    Alcotest.(check string) "reason" "empty_no_progress" reason;
    Alcotest.(check string)
      "failure propagated"
      (Agent_sdk.Error.to_string setup_err)
      (Agent_sdk.Error.to_string fail_open_err);
    Alcotest.(check (list (pair string string)))
      "no runtime-selected metric on setup failure"
      []
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "no rotation metric on setup failure"
      []
      (List.rev !rotated);
    (match List.rev !published with
     | [ (_runtime_id, decision, reason, next_runtime, attempt) ] ->
       Alcotest.(check string) "decision" "degraded_retry_allowed" decision;
       Alcotest.(check string) "publish reason" "empty_no_progress" reason;
       Alcotest.(check (option string))
         "next runtime"
         (Some "runtime.fallback")
         next_runtime;
       Alcotest.(check int) "attempt" 2 attempt
     | rows ->
       Alcotest.failf "expected one cascade event, got %d" (List.length rows))

let test_plan_degraded_retry_step_covers_direct_outcomes () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
        ~last_tool_effect:None
        ~reason:"shape=empty"
        ()
    in
    let expected_retry_runtime =
      match direct_no_progress_retry_decision empty_err with
      | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed retry ->
        retry.next_runtime
      | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted _ ->
        Alcotest.fail
          "fresh direct empty retry should not exhaust slot phase before planning"
      | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
        Alcotest.fail "fresh direct empty retry should select a fallback runtime"
    in
    let plan
        ?time_spent_in_turn_s
        ?(allow_retry = fun _ -> true)
        ?(setup_runtime = fun runtime_id -> Ok ("prepared:" ^ runtime_id))
        err =
      let published, selected, rotated, publish_cascade_resolution,
          emit_runtime_selected, emit_runtime_rotation =
        prepare_retry_observers ()
      in
      ( Masc.Keeper_turn_runtime_budget.plan_degraded_retry_step
          ~base_runtime:"test_provider.test_model"
          ~current_runtime_id:"runtime.direct-empty"
          ~attempted_runtimes:[ "runtime.direct-empty" ]
          ~estimated_input_tokens:1
          ~time_spent_in_turn_s
          ~remaining_turn_budget_s:60.0
          ~attempt:1
          ~err
          ~allow_retry
          ~publish_cascade_resolution
          ~emit_runtime_selected
          ~emit_runtime_rotation
          ~setup_runtime
      , published
      , selected
      , rotated )
    in
    let step, published, selected, rotated =
      plan ~allow_retry:(fun _ -> false) empty_err
    in
    (match step with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_step_not_allowed -> ()
     | _ -> Alcotest.fail "retry policy denial should not plan a retry");
    Alcotest.(check (list (pair string string)))
      "policy denial emits no selected metric"
      []
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "policy denial emits no rotation metric"
      []
      (List.rev !rotated);
    Alcotest.(check int)
      "policy denial emits no cascade event"
      0
      (List.length !published);
    let step, published, selected, rotated = plan empty_err in
    (match step with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_step_prepared
         { retry; reason; next } ->
       Alcotest.(check string)
         "prepared runtime"
         expected_retry_runtime
         retry.next_runtime;
       Alcotest.(check string) "prepared reason" "empty_no_progress" reason;
       Alcotest.(check string)
         "prepared payload"
         ("prepared:" ^ expected_retry_runtime)
         next
     | _ -> Alcotest.fail "allowed empty retry should prepare fallback runtime");
    Alcotest.(check (list (pair string string)))
      "prepared emits selected metric"
      [ expected_retry_runtime, "empty_no_progress" ]
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "prepared emits rotation metric"
      [ "runtime.direct-empty", expected_retry_runtime, "empty_no_progress" ]
      (List.rev !rotated);
    (match List.rev !published with
     | [ (runtime_id, decision, reason, next_runtime, attempt) ] ->
       Alcotest.(check string)
         "prepared cascade runtime"
         "runtime.direct-empty"
         runtime_id;
       Alcotest.(check string)
         "prepared cascade decision"
         "degraded_retry_allowed"
         decision;
       Alcotest.(check string) "prepared cascade reason" "empty_no_progress" reason;
       Alcotest.(check (option string))
         "prepared cascade target"
         (Some expected_retry_runtime)
         next_runtime;
       Alcotest.(check int) "prepared cascade attempt" 1 attempt
     | rows ->
       Alcotest.failf "expected one prepared cascade event, got %d"
         (List.length rows));
    let setup_err = Agent_sdk.Error.Internal "plan setup failed" in
    let step, published, selected, rotated =
      plan ~setup_runtime:(fun _ -> Error setup_err) empty_err
    in
    (match step with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_step_setup_failed
         { retry; reason; fail_open_err } ->
       Alcotest.(check string)
         "setup failure retry runtime"
         expected_retry_runtime
         retry.next_runtime;
       Alcotest.(check string) "setup failure reason" "empty_no_progress" reason;
       Alcotest.(check string)
         "setup failure error"
         (Agent_sdk.Error.to_string setup_err)
         (Agent_sdk.Error.to_string fail_open_err)
     | _ -> Alcotest.fail "setup error should produce setup-failed step");
    Alcotest.(check (list (pair string string)))
      "setup failure emits no selected metric"
      []
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "setup failure emits no rotation metric"
      []
      (List.rev !rotated);
    Alcotest.(check int)
      "setup failure still publishes allowed cascade"
      1
      (List.length !published);
    let exhausted_after =
      Masc.Keeper_turn_runtime_budget.degraded_retry_slot_phase_budget_sec +. 1.0
    in
    let step, published, selected, rotated =
      plan ~time_spent_in_turn_s:exhausted_after empty_err
    in
    (match step with
     | Masc.Keeper_turn_runtime_budget.Degraded_retry_step_slot_phase_exhausted
         { retry; reason } ->
       Alcotest.(check string)
         "slot exhausted runtime"
         expected_retry_runtime
         retry.next_runtime;
       Alcotest.(check string) "slot exhausted reason" "empty_no_progress" reason
     | _ -> Alcotest.fail "expired slot phase should produce exhausted step");
    Alcotest.(check (list (pair string string)))
      "slot exhaustion emits no selected metric"
      []
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "slot exhaustion emits no rotation metric"
      []
      (List.rev !rotated);
    (match List.rev !published with
     | [ (runtime_id, decision, reason, next_runtime, attempt) ] ->
       Alcotest.(check string)
         "slot exhausted cascade runtime"
         "runtime.direct-empty"
         runtime_id;
       Alcotest.(check string)
         "slot exhausted cascade decision"
         "degraded_retry_slot_phase_exhausted"
         decision;
       Alcotest.(check string)
         "slot exhausted cascade reason"
         "empty_no_progress"
         reason;
       Alcotest.(check (option string))
         "slot exhausted cascade target"
         (Some expected_retry_runtime)
         next_runtime;
       Alcotest.(check int) "slot exhausted cascade attempt" 1 attempt
     | rows ->
       Alcotest.failf "expected one slot-exhausted cascade event, got %d"
         (List.length rows)))

let test_direct_no_progress_retry_loop_runs_fallback_attempt () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
        ~last_tool_effect:None
        ~reason:"shape=empty"
        ()
    in
    let expected_retry_runtime =
      match direct_no_progress_retry_decision empty_err with
      | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed retry ->
        retry.next_runtime
      | Masc.Keeper_turn_runtime_budget.Degraded_retry_slot_phase_exhausted _ ->
        Alcotest.fail
          "fresh direct empty retry should not exhaust slot phase before loop"
      | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
        Alcotest.fail "fresh direct empty retry should select a fallback runtime"
    in
    let retry_context_resolution
        : Masc.Keeper_context_runtime.max_context_resolution =
      { requested_override = None
      ; primary_budget = 4096
      ; runtime_budget = 4096
      ; turn_budget = 4096
      ; effective_budget = 4096
      }
    in
    let attempts = ref [] in
    let published = ref [] in
    let selected = ref [] in
    let rotated = ref [] in
    let validated = ref [] in
    let setup_failures = ref [] in
    let yielded = ref 0 in
    let retry_execution runtime_id : Masc.Keeper_turn_runtime_budget.runtime_execution =
      { runtime_id
      ; max_context_resolution = retry_context_resolution
      ; max_context = retry_context_resolution.turn_budget
      ; temperature = 0.0
      ; max_tokens = 1024
      }
    in
    let result =
      Masc.Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
        ~keeper_name:"keeper-test"
        ~base_runtime:"test_provider.test_model"
        ~initial_runtime:"runtime.direct-empty"
        ~initial_max_context:1024
        ~estimated_input_tokens:1
        ~timeout_sec:60.0
        ~remaining_turn_budget_s:(fun () -> 60.0)
        ~current_turn_phase_elapsed_ms:(function
          | None -> 7, None
          | Some _ -> 7, Some 0)
        ~now_s:(fun () -> 10.0)
        ~setup_retry_runtime:(fun runtime_id ->
          validated := runtime_id :: !validated;
          Ok (retry_execution runtime_id))
        ~publish_cascade_resolution:
          (fun ~runtime_id ~decision ~reason ~next_runtime ~attempt _err ->
             published :=
               ( runtime_id
               , cascade_decision_to_string decision
               , reason
               , next_runtime
               , attempt )
               :: !published)
        ~emit_runtime_selected:(fun ~runtime_id ~fallback_reason ->
          selected := (runtime_id, fallback_reason) :: !selected)
        ~emit_runtime_rotation:(fun ~from_runtime ~to_runtime ~reason ->
          rotated := (from_runtime, to_runtime, reason) :: !rotated)
        ~record_retry_setup_failure:(fun ~from_runtime ~retry:_ ~rotation_attempt:_
                                      ~fail_open_err:_ ->
          setup_failures := from_runtime :: !setup_failures)
        ~before_retry:(fun () -> yielded := !yielded + 1)
        ~run_once:
          (fun ~runtime_id ~max_context ~is_retry ~degraded_retry_runtime
               ~fallback_reason ~runtime_rotation_attempts ->
             attempts :=
               { observed_runtime_id = runtime_id
               ; observed_max_context = max_context
               ; observed_is_retry = is_retry
               ; observed_degraded_retry_runtime = degraded_retry_runtime
               ; observed_fallback_reason =
                   Option.map
                     Masc.Keeper_error_classify.degraded_retry_reason_to_string
                     fallback_reason
               ; observed_rotation_attempt_count =
                   List.length runtime_rotation_attempts
               }
               :: !attempts;
             if is_retry then Ok ("ok:" ^ runtime_id) else Error empty_err)
        ()
    in
    (match result with
     | Error err ->
       Alcotest.failf
         "retry loop should succeed on fallback runtime: %s"
         (Agent_sdk.Error.to_string err)
     | Ok (value, final_max_context) ->
       Alcotest.(check string)
         "retry result comes from fallback runtime"
         ("ok:" ^ expected_retry_runtime)
         value;
       Alcotest.(check int)
         "final max context comes from fallback runtime"
         4096
         final_max_context);
    (match List.rev !attempts with
     | [ first; second ] ->
       Alcotest.(check string)
         "first attempt uses initial runtime"
         "runtime.direct-empty"
         first.observed_runtime_id;
       Alcotest.(check int)
         "first attempt uses initial max context"
         1024
         first.observed_max_context;
       Alcotest.(check bool) "first attempt is not retry" false
         first.observed_is_retry;
       Alcotest.(check (option string))
         "first attempt has no degraded runtime"
         None
         first.observed_degraded_retry_runtime;
       Alcotest.(check string)
         "second attempt uses fallback runtime"
         expected_retry_runtime
         second.observed_runtime_id;
       Alcotest.(check int)
         "second attempt uses fallback max context"
         4096
         second.observed_max_context;
       Alcotest.(check bool) "second attempt is retry" true
         second.observed_is_retry;
       Alcotest.(check (option string))
         "second attempt carries degraded retry runtime"
         (Some expected_retry_runtime)
         second.observed_degraded_retry_runtime;
       Alcotest.(check (option string))
         "second attempt carries fallback reason"
         (Some "empty_no_progress")
         second.observed_fallback_reason;
       Alcotest.(check int)
         "second attempt receives scheduled rotation attempt"
         1
         second.observed_rotation_attempt_count
     | attempts ->
       Alcotest.failf "expected exactly two attempts, got %d"
         (List.length attempts));
    Alcotest.(check (list string))
      "fallback runtime was validated"
      [ expected_retry_runtime ]
      (List.rev !validated);
    Alcotest.(check (list (pair string string)))
      "runtime selected metric emitted"
      [ expected_retry_runtime, "empty_no_progress" ]
      (List.rev !selected);
    Alcotest.(check (list (triple string string string)))
      "runtime rotation metric emitted"
      [ "runtime.direct-empty", expected_retry_runtime, "empty_no_progress" ]
      (List.rev !rotated);
    Alcotest.(check int) "cooperative retry yield runs once" 1 !yielded;
    Alcotest.(check (list string)) "no setup failure recorded" [] !setup_failures;
    (match List.rev !published with
     | [ (runtime_id, decision, reason, next_runtime, attempt) ] ->
       Alcotest.(check string)
         "cascade published from initial runtime"
         "runtime.direct-empty"
         runtime_id;
       Alcotest.(check string)
         "cascade records allowed retry"
         "degraded_retry_allowed"
         decision;
       Alcotest.(check string) "cascade reason" "empty_no_progress" reason;
       Alcotest.(check (option string))
         "cascade next runtime"
         (Some expected_retry_runtime)
         next_runtime;
       Alcotest.(check int) "cascade attempt" 1 attempt
     | published ->
       Alcotest.failf "expected one cascade event, got %d"
         (List.length published)))

let test_direct_retry_loop_publishes_non_retry_terminal_cascade () =
  let terminal_err = Agent_sdk.Error.Internal "not retryable" in
  let published = ref [] in
  let run_count = ref 0 in
  let result =
    Masc.Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
      ~keeper_name:"keeper-test"
      ~base_runtime:"runtime.initial"
      ~initial_runtime:"runtime.initial"
      ~initial_max_context:2048
      ~estimated_input_tokens:1
      ~timeout_sec:60.0
      ~remaining_turn_budget_s:(fun () -> 60.0)
      ~current_turn_phase_elapsed_ms:(fun _ -> 3, None)
      ~now_s:(fun () -> 10.0)
      ~setup_retry_runtime:(fun _ ->
        Alcotest.fail "non-retryable terminal errors must not set up a retry")
      ~publish_cascade_resolution:
        (fun ~runtime_id ~decision ~reason ~next_runtime ~attempt _err ->
           published :=
             ( runtime_id
             , cascade_decision_to_string decision
             , reason
             , next_runtime
             , attempt )
             :: !published)
      ~emit_runtime_selected:(fun ~runtime_id:_ ~fallback_reason:_ ->
        Alcotest.fail "non-retryable terminal errors must not emit selection")
      ~emit_runtime_rotation:(fun ~from_runtime:_ ~to_runtime:_ ~reason:_ ->
        Alcotest.fail "non-retryable terminal errors must not emit rotation")
      ~record_retry_setup_failure:
        (fun ~from_runtime:_ ~retry:_ ~rotation_attempt:_ ~fail_open_err:_ ->
           Alcotest.fail "non-retryable terminal errors must not record setup failure")
      ~before_retry:(fun () ->
        Alcotest.fail "non-retryable terminal errors must not yield before retry")
      ~run_once:
        (fun ~runtime_id ~max_context ~is_retry ~degraded_retry_runtime:_
             ~fallback_reason:_ ~runtime_rotation_attempts:_ ->
           incr run_count;
           Alcotest.(check string) "initial runtime" "runtime.initial" runtime_id;
           Alcotest.(check int) "initial max context" 2048 max_context;
           Alcotest.(check bool) "not retry" false is_retry;
           Error terminal_err)
      ()
  in
  (match result with
   | Ok _ -> Alcotest.fail "terminal error should be returned"
   | Error err ->
     Alcotest.(check string)
       "terminal error propagated"
       (Agent_sdk.Error.to_string terminal_err)
       (Agent_sdk.Error.to_string err));
  Alcotest.(check int) "only initial attempt runs" 1 !run_count;
  match List.rev !published with
  | [ (runtime_id, decision, reason, next_runtime, attempt) ] ->
    Alcotest.(check string) "published from initial runtime" "runtime.initial" runtime_id;
    Alcotest.(check string) "terminal decision" "no_degraded_retry" decision;
    Alcotest.(check string)
      "terminal reason"
      "terminal_error_not_degraded_retry_eligible"
      reason;
    Alcotest.(check (option string)) "no next runtime" None next_runtime;
    Alcotest.(check int) "attempt" 1 attempt
  | rows ->
    Alcotest.failf "expected one cascade event, got %d" (List.length rows)

let test_manual_direct_turn_uses_effective_context_budget () =
  let source = read_source_file "lib/keeper/keeper_turn.ml" in
  let start_marker = "let max_runtime_context =" in
  let end_marker = "~initial_max_context:max_runtime_context" in
  let start =
    match index_of ~needle:start_marker source with
    | Some index -> index
    | None -> Alcotest.fail "manual max_runtime_context block missing"
  in
  let stop =
    match index_of ~needle:end_marker source with
    | Some index -> index + String.length end_marker
    | None -> Alcotest.fail "manual direct initial_max_context call missing"
  in
  let slice = String.sub source start (stop - start) in
  Alcotest.(check bool)
    "manual direct turn resolves max context from runtime/meta"
    true
    (contains
       ~needle:
         "Keeper_context_runtime.resolve_max_context_resolution\n\
          \t                  ~requested_override:meta.max_context_override \
          effective_models"
       slice);
  Alcotest.(check bool)
    "manual direct first attempt uses provider-effective budget"
    true
    (contains ~needle:"resolution.effective_budget" slice);
  Alcotest.(check bool)
    "manual direct first attempt does not use raw turn_budget"
    false
    (contains ~needle:"resolution.turn_budget\n\t            in" slice)

let test_thinking_with_text_is_accepted () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-text"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { signature = None; content = "internal chain" };
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
               { signature = None; content = "internal chain" };
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
        { signature = None; content = "internal chain" };
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
        { media_type = "image/png"
        ; data = "redacted"
        ; source_type = Agent_sdk.Types.Base64
        };
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
               { signature = None; content = "internal chain" };
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

(* RFC-0271 §4.1 [Retry_no_thinking] gate truth table: only a thinking-only
   rejection on a thinking-enabled attempt, once per turn, triggers the cheap
   thinking-off re-shape before reroute. *)
let test_should_retry_no_thinking_gate () =
  let gate = Masc.Keeper_turn_driver_try_runtime.For_testing.should_retry_no_thinking in
  let check label expected actual = Alcotest.(check bool) label expected actual in
  check "thinking_only + thinking on + fresh turn -> retry" true
    (gate ~recovered:false ~enable_thinking:(Some true)
       ~retry_kind:(Some `Thinking_only_no_progress));
  check "thinking_only + thinking default(None=on) -> retry" true
    (gate ~recovered:false ~enable_thinking:None
       ~retry_kind:(Some `Thinking_only_no_progress));
  check "thinking_only + already recovered -> no second retry (bounded)" false
    (gate ~recovered:true ~enable_thinking:(Some true)
       ~retry_kind:(Some `Thinking_only_no_progress));
  check "thinking_only + thinking already off -> nothing to re-shape" false
    (gate ~recovered:false ~enable_thinking:(Some false)
       ~retry_kind:(Some `Thinking_only_no_progress));
  check "empty_no_progress -> no retry" false
    (gate ~recovered:false ~enable_thinking:(Some true)
       ~retry_kind:(Some `Empty_no_progress));
  check "read_only_no_progress -> no retry" false
    (gate ~recovered:false ~enable_thinking:(Some true)
       ~retry_kind:(Some `Read_only_no_progress));
  check "no retry kind -> no retry" false
    (gate ~recovered:false ~enable_thinking:(Some true) ~retry_kind:None)

let test_thinking_only_no_tool_can_try_next_candidate () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-only-no-tool"
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_sdk.Types.Thinking
               { signature = None; content = "internal chain" };
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
    "thinking-only no-tool can try next provider candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next err);
  Alcotest.(check bool)
    "non-last thinking-only no-tool advances provider candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:false
       err);
  Alcotest.(check bool)
    "last thinking-only no-tool stays in same-attempt loop terminal"
    false
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:true
       err);
  Alcotest.(check bool)
    "thinking-only no-tool is not a read-only retry"
    false
    (Masc.Keeper_turn_driver.For_testing
     .accept_no_progress_read_only_should_try_next
       err);
  Alcotest.(check (option string))
    "thinking-only no-tool classified by internal-error SSOT"
    (Some "thinking_only_no_progress")
    (accept_no_progress_retry_kind_string err);
  Alcotest.(check (option string))
    "thinking-only no-tool is runtime-recoverable"
    (Some "thinking_only_no_progress")
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err));
  Alcotest.(check (option string))
    "direct keeper_msg rotates thinking-only no-progress"
    (Some "thinking_only_no_progress")
    (direct_no_progress_retry_reason_string err)

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
    "non-last empty accept rejection advances provider candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:false
       err);
  Alcotest.(check bool)
    "last empty accept rejection stays terminal"
    false
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:true
       err);
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
    (direct_no_progress_retry_reason_string err)

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
  Alcotest.(check bool)
    "mutating accept rejection does not advance provider candidate"
    false
    (Masc.Keeper_turn_driver.For_testing.accept_rejected_result_should_try_next
       ~is_last:false
       err);
  Alcotest.(check (option string))
    "empty response after mutation is not runtime-recoverable"
    None
    (Option.map
       Masc.Keeper_error_classify.degraded_retry_reason_to_string
       (Masc.Keeper_error_classify.recoverable_runtime_failure_reason err));
  Alcotest.(check (option string))
    "direct keeper_msg does not rotate after mutation"
    None
    (direct_no_progress_retry_reason_string err)

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
                 source_type = Agent_sdk.Types.Base64;
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
  let watchdog_kind event =
    Masc.Keeper_agent_run_turn_helpers.sse_event_watchdog_progress_kind event
  in
  Alcotest.(check (option string))
    "tool block start follows SDK stream classifier"
    (Some "sse_tool_block_start")
    (kind
       (ContentBlockStart
          { index = 0; content_type = "tool_use"; tool_id = None; tool_name = None }));
  Alcotest.(check (option string))
    "text delta"
    (Some "sse_text_delta")
    (kind (ContentBlockDelta { index = 0; delta = TextDelta "visible" }));
  Alcotest.(check (option string))
    "thinking delta"
    (Some "sse_thinking_delta")
    (kind (ContentBlockDelta { index = 0; delta = ThinkingDelta "hidden" }));
  Alcotest.(check (option string))
    "reasoning details delta"
    (Some "sse_thinking_delta")
    (kind
       (ContentBlockDelta
          { index = 0
          ; delta =
              ReasoningDetailsDelta
                { reasoning_content = None
                ; details =
                    [ { raw = `Assoc [ "text", `String "hidden" ]
                      ; text = Some "hidden"
                      }
                    ]
                }
          }));
  Alcotest.(check (option string))
    "tool arg delta"
    (Some "sse_tool_arg_delta")
    (kind (ContentBlockDelta { index = 0; delta = InputJsonDelta "{}" }));
  Alcotest.(check (option string))
    "tool arg snapshot"
    (Some "sse_tool_arg_delta")
    (kind (ContentBlockDelta { index = 0; delta = InputJsonSnapshot "{}" }));
  Alcotest.(check (option string))
    "media delta"
    (Some "sse_media_delta")
    (kind
       (ContentBlockDelta
          {
            index = 0;
            delta =
              MediaDelta
                { media_type = "image/png"; source_type = Base64; data = "abcd" };
          }));
  Alcotest.(check (option string))
    "empty text delta falls back to carrier progress"
    (Some "sse_content_delta")
    (kind (ContentBlockDelta { index = 0; delta = TextDelta "" }));
  Alcotest.(check (option string))
    "empty text delta is not watchdog progress"
    None
    (watchdog_kind (ContentBlockDelta { index = 0; delta = TextDelta "" }));
  Alcotest.(check (option string))
    "thinking delta is diagnostic but not watchdog progress"
    None
    (watchdog_kind (ContentBlockDelta { index = 0; delta = ThinkingDelta "hidden" }));
  Alcotest.(check (option string))
    "reasoning details delta is diagnostic but not watchdog progress"
    None
    (watchdog_kind
       (ContentBlockDelta
          { index = 0
          ; delta =
              ReasoningDetailsDelta
                { reasoning_content = Some "hidden"; details = [] }
          }));
  Alcotest.(check (option string))
    "visible text delta is watchdog progress"
    (Some "sse_text_delta")
    (watchdog_kind (ContentBlockDelta { index = 0; delta = TextDelta "visible" }));
  Alcotest.(check (option string))
    "stream incomplete"
    (Some "sse_stream_incomplete")
    (kind (StreamIncomplete { reason = "max_output_tokens" }))

let registry_recorded_progress events =
  let recorded = ref [] in
  let downstream_count = ref 0 in
  let on_event =
    Masc.Keeper_agent_run_turn_helpers.registry_progress_on_event
      ~record_turn_progress:(fun kind -> recorded := kind :: !recorded)
      (Some (fun _ -> incr downstream_count))
  in
  List.iter on_event events;
  (List.rev !recorded, !downstream_count)

let test_registry_progress_on_event_records_only_watchdog_progress () =
  let open Agent_sdk.Types in
  let recorded, downstream_count =
    registry_recorded_progress
      [ ContentBlockDelta { index = 0; delta = TextDelta "" }
      ; ContentBlockDelta { index = 0; delta = ThinkingDelta "hidden" }
      ; ContentBlockStop { index = 0 }
      ; MessageDelta { stop_reason = None; usage = None }
      ; ContentBlockDelta { index = 0; delta = TextDelta "visible" }
      ; ContentBlockStart
          { index = 1; content_type = "tool_use"; tool_id = None; tool_name = None }
      ]
  in
  Alcotest.(check (list string))
    "carrier/control events do not reset watchdog progress"
    [ "sse_text_delta"; "sse_tool_block_start" ]
    recorded;
  Alcotest.(check int) "downstream still sees every event" 6 downstream_count

let test_carrier_only_stream_does_not_suppress_mid_turn_no_progress () =
  let open Agent_sdk.Types in
  let recorded, downstream_count =
    registry_recorded_progress
      [ ContentBlockDelta { index = 0; delta = TextDelta "" }
      ; ContentBlockDelta { index = 0; delta = ThinkingDelta "hidden" }
      ; ContentBlockStop { index = 0 }
      ; MessageDelta { stop_reason = None; usage = None }
      ; MessageStop
      ]
  in
  Alcotest.(check (list string))
    "carrier-only stream does not record watchdog progress"
    []
    recorded;
  Alcotest.(check int) "diagnostic downstream receives carrier stream" 5 downstream_count;
  let turn_observation =
    let open Masc.Keeper_registry_types in
    ({ turn_id = 1
     ; started_at = 0.0
     ; last_progress_at = 0.0
     ; last_progress_kind = Some "turn_started"
     ; active_tool_count = 0
     ; turn_phase = Packed Turn_prompting
     ; decision_stage = Packed Decision_undecided
     ; measurement = None
     ; measurement_bind_count = 0
     ; selected_model = None
     }
      : Masc.Keeper_registry_types.turn_observation)
  in
  match
    Masc.Keeper_supervisor.assess_in_turn_progress
      ~phase:Keeper_state_machine.Running
      ~in_turn:(Some turn_observation)
      ~now:45.0
      ~progress_timeout:30.0
  with
  | Some
      (Masc.Keeper_registry.Stale_turn_timeout
         (Masc.Keeper_registry.Mid_turn_no_progress
            { since_progress_seconds
            ; progress_timeout_threshold
            ; last_progress_kind
            ; _
            })) ->
    Alcotest.(check int)
      "carrier-only stream stays stale"
      45
      (int_of_float since_progress_seconds);
    Alcotest.(check int)
      "progress timeout threshold preserved"
      30
      (int_of_float progress_timeout_threshold);
    Alcotest.(check (option string))
      "last watchdog progress remains turn start"
      (Some "turn_started")
      last_progress_kind
  | _ ->
    Alcotest.fail
      "carrier-only stream must not suppress Mid_turn_no_progress"

let test_per_provider_timeout_not_forwarded_to_oas_hard_deadline () =
  (* RFC-0129 (§62, 2026-05-17 fleet incident): per_provider_timeout_s must NOT
     forward to OAS max_execution_time_s. That field is a cumulative wall-clock
     kill switch that truncates healthy slow streams (307.5s cluster). The
     attempt deadline stays progress-based, so this helper always returns None. *)
  Alcotest.(check (option (float 0.0)))
    "per-provider timeout is not forwarded to OAS max_execution_time_s (RFC-0129)"
    None
    (Masc.Keeper_turn_driver.For_testing.max_execution_time_for_attempt
       ~per_provider_timeout_s:123.0
       ());
  Alcotest.(check (option (float 0.0)))
    "missing timeout stays disabled"
    None
    (Masc.Keeper_turn_driver.For_testing.max_execution_time_for_attempt ())

(* KLV-DNS (RFC-keeper-liveness-ssot §6): before this fix, candidate
   exhaustion always produced a plain [Agent_sdk.Error.Internal <free-text>],
   so [Keeper_error_classify.is_runtime_exhausted_error] never fired for
   DNS/network failures and the already-built Turn_consecutive_failures /
   Auto_resume_with_backoff auto-pause path was unreachable — every DNS
   outage fell back to the generic crash-restart-then-Dead path instead. *)
let test_dns_failure_exhaustion_classifies_as_runtime_exhausted () =
  let dns_err =
    Llm_provider.Http_client.NetworkError
      { message = "getaddrinfo failed"; kind = Llm_provider.Http_client.Dns_failure }
  in
  let mapped =
    Masc.Keeper_turn_driver.For_testing.sdk_error_of_exhausted
      ~runtime_id:"runtime.dns-test"
      (Some dns_err)
  in
  Alcotest.(check bool)
    "DNS exhaustion is a runtime-exhausted error"
    true
    (Masc.Keeper_error_classify.is_runtime_exhausted_error mapped);
  Alcotest.(check bool)
    "DNS exhaustion is not auto-recoverable (counts toward crash threshold, \
     per record_failure_and_maybe_escalate's counts_toward_crash)"
    false
    (Masc.Keeper_error_classify.is_auto_recoverable_turn_error mapped);
  match Keeper_internal_error.classify_masc_internal_error mapped with
  | Some (Keeper_internal_error.Runtime_exhausted { runtime_id; reason }) ->
    Alcotest.(check string) "runtime_id preserved" "runtime.dns-test" runtime_id;
    Alcotest.(check bool)
      "reason is Dns_failure"
      true
      (reason = Keeper_internal_error.Dns_failure);
    Alcotest.(check bool)
      "Dns_failure is policy-retryable (Auto_resume_with_backoff eligible)"
      true
      (Keeper_internal_error.runtime_exhaustion_reason_retryable reason)
  | Some other ->
    Alcotest.failf "expected Runtime_exhausted, got %s"
      (Keeper_internal_error.kind_of_masc_internal_error other)
  | None ->
    Alcotest.failf "expected typed keeper error, got %s"
      (Agent_sdk.Error.to_string mapped)

let test_no_candidates_exhaustion_classifies_as_no_providers_available () =
  let mapped =
    Masc.Keeper_turn_driver.For_testing.sdk_error_of_exhausted
      ~runtime_id:"runtime.no-candidates"
      None
  in
  match Keeper_internal_error.classify_masc_internal_error mapped with
  | Some (Keeper_internal_error.Runtime_exhausted { reason; _ }) ->
    Alcotest.(check bool)
      "no last_err maps to No_providers_available"
      true
      (reason = Keeper_internal_error.No_providers_available)
  | Some other ->
    Alcotest.failf "expected Runtime_exhausted, got %s"
      (Keeper_internal_error.kind_of_masc_internal_error other)
  | None ->
    Alcotest.failf "expected typed keeper error, got %s"
      (Agent_sdk.Error.to_string mapped)

let test_capacity_failure_exhaustion_classifies_as_capacity_exhausted () =
  let capacity_err =
    Llm_provider.Http_client.ProviderFailure
      { kind =
          Llm_provider.Http_client.Capacity_exhausted
            { scope = Llm_provider.Http_client.Failure_scope_provider
            ; retry_after = Some 30.0
            ; model = Some "test-model"
            }
      ; message = "capacity exhausted"
      }
  in
  let mapped =
    Masc.Keeper_turn_driver.For_testing.sdk_error_of_exhausted
      ~runtime_id:"runtime.capacity-test"
      (Some capacity_err)
  in
  match Keeper_internal_error.classify_masc_internal_error mapped with
  | Some (Keeper_internal_error.Runtime_exhausted { reason; _ }) ->
    Alcotest.(check bool)
      "reason is Capacity_exhausted"
      true
      (reason = Keeper_internal_error.Capacity_exhausted);
    Alcotest.(check bool)
      "Capacity_exhausted is policy-retryable"
      true
      (Keeper_internal_error.runtime_exhaustion_reason_retryable reason);
    Alcotest.(check bool)
      "capacity exhaustion is auto-recoverable"
      true
      (Masc.Keeper_error_classify.is_auto_recoverable_turn_error mapped)
  | Some other ->
    Alcotest.failf "expected Runtime_exhausted, got %s"
      (Keeper_internal_error.kind_of_masc_internal_error other)
  | None ->
    Alcotest.failf "expected typed keeper error, got %s"
      (Agent_sdk.Error.to_string mapped)

let test_runtime_exhaustion_label_caps_free_text_detail () =
  let detail = String.make 260 'x' ^ "\nwith newline\tand spacing" in
  let label =
    Keeper_internal_error.runtime_exhaustion_reason_to_label
      (Keeper_internal_error.Other_detail detail)
  in
  Alcotest.(check bool)
    "label detail is byte-capped"
    true
    (String.length label <= 212);
  Alcotest.(check bool) "label has no newline" false (contains ~needle:"\n" label);
  Alcotest.(check bool) "label is marked truncated" true (contains ~needle:"..." label)

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
            "blank finalization response is typed no-progress"
            `Quick
            test_finalization_blank_response_is_typed_accept_rejection;
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
	            "direct no-progress retry uses shared budget decision"
	            `Quick
	            test_direct_no_progress_retry_uses_shared_budget_decision;
          Alcotest.test_case
            "degraded retry rejects empty runtime target"
            `Quick
            test_prepare_degraded_retry_rejects_empty_runtime;
          Alcotest.test_case
            "degraded retry reports setup failure"
            `Quick
            test_prepare_degraded_retry_reports_setup_failure;
          Alcotest.test_case
            "degraded retry planner covers direct outcomes"
            `Quick
            test_plan_degraded_retry_step_covers_direct_outcomes;
	          Alcotest.test_case
	            "direct no-progress retry runs fallback attempt"
	            `Quick
	            test_direct_no_progress_retry_loop_runs_fallback_attempt;
          Alcotest.test_case
            "direct retry publishes terminal non-retry cascade"
            `Quick
            test_direct_retry_loop_publishes_non_retry_terminal_cascade;
          Alcotest.test_case
            "manual direct turn uses effective context budget"
            `Quick
            test_manual_direct_turn_uses_effective_context_budget;
	          Alcotest.test_case "thinking plus text is accepted" `Quick
	            test_thinking_with_text_is_accepted;
          Alcotest.test_case "thinking plus tool use is accepted" `Quick
            test_thinking_with_tool_use_is_accepted;
          Alcotest.test_case "accept delegates to OAS response shape" `Quick
            test_accept_contract_delegates_to_oas_response_shape;
          Alcotest.test_case "thinking-only non-end-turn response is rejected" `Quick
            test_thinking_only_non_end_turn_response_is_rejected;
          Alcotest.test_case
            "thinking-only no-tool response rotates typed no-progress"
            `Quick
            test_thinking_only_no_tool_can_try_next_candidate;
          Alcotest.test_case
            "Retry_no_thinking gate is bounded and thinking-only-scoped (RFC-0271)"
            `Quick
            test_should_retry_no_thinking_gate;
          Alcotest.test_case
            "Accept_rejected threads typed stop_reason (RFC-0271 §4.5)"
            `Quick
            test_accept_rejected_threads_stop_reason;
          Alcotest.test_case
            "Accept_rejected stop_reason survives codec (RFC-0271 §4.5)"
            `Quick
            test_accept_rejected_stop_reason_survives_codec;
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
          Alcotest.test_case
            "sse watchdog progress records deliverable events only"
            `Quick
            test_registry_progress_on_event_records_only_watchdog_progress;
          Alcotest.test_case
            "carrier-only stream still trips mid-turn no-progress"
            `Quick
            test_carrier_only_stream_does_not_suppress_mid_turn_no_progress;
          Alcotest.test_case
            "keeper timeout is not forwarded to OAS hard deadline (RFC-0129)"
            `Quick
            test_per_provider_timeout_not_forwarded_to_oas_hard_deadline;
          Alcotest.test_case
            "DNS failure exhaustion classifies as Runtime_exhausted (KLV-DNS)"
            `Quick
            test_dns_failure_exhaustion_classifies_as_runtime_exhausted;
          Alcotest.test_case
            "no-candidates exhaustion classifies as No_providers_available"
            `Quick
            test_no_candidates_exhaustion_classifies_as_no_providers_available;
          Alcotest.test_case
            "capacity exhaustion classifies as retryable Runtime_exhausted"
            `Quick
            test_capacity_failure_exhaustion_classifies_as_capacity_exhausted;
          Alcotest.test_case
            "runtime exhaustion labels cap free-text detail"
            `Quick
            test_runtime_exhaustion_label_caps_free_text_detail;
        ] );
    ]
