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

let input_required_request () : Agent_sdk.Error.input_required =
  { request_id = "input-request-1"
  ; participant_name = Some "operator"
  ; question = "Which repository should I inspect?"
  ; schema = Some (`Assoc [ "type", `String "string" ])
  ; timeout_s = None
  ; created_at = 1_000.0
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

let direct_no_progress_retry_decision err =
  Masc.Keeper_turn_runtime_budget.direct_no_progress_retry_decision
    ~base_runtime:"test_provider.test_model"
    ~effective_runtime:"runtime.direct-empty"
    ~attempted_runtimes:[ "runtime.direct-empty" ]
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

let test_typed_recovery_control_stops_bypass_response_accept () =
  let accept_calls = ref 0 in
  let reject (_ : Agent_sdk.Types.api_response) =
    incr accept_calls;
    false
  in
  let request = input_required_request () in
  let input_required =
    { (run_result ()) with
      stop_reason = Runtime_agent.InputRequired { turns_used = 2; request }
    }
  in
  let deferred =
    { (run_result ()) with
      stop_reason =
        Runtime_agent.ToolFailureRecoveryDeferred
          { turns_used = 2; reason = "wait"; tool_names = [ "Execute" ] }
    }
  in
  List.iter
    (fun (label, result) ->
       match
         Masc.Keeper_turn_driver.For_testing.apply_accept
           ~runtime_id:"runtime.reasoning-model"
           ~accept:reject
           result
       with
       | Ok _ -> ()
       | Error error ->
         Alcotest.failf
           "%s control stop rotated through response acceptance: %s"
           label
           (Agent_sdk.Error.to_string error))
    [ "input_required", input_required; "defer", deferred ];
  Alcotest.(check int)
    "typed control stops never invoke the deliverable accept predicate"
    0
    !accept_calls

let test_replay_projection_failure_preserves_provider_success () =
  let open Agent_sdk.Types in
  let canonical_prefix =
    [ message
        ~role:User
        [ Text "canonical history"
        ; image_block ~media_type:"image/png" ~data:"canonical-image" ()
        ]
    ]
  in
  let dispatch_prefix = [ message ~role:User [ Text "canonical history" ] ] in
  let drifted_checkpoint =
    checkpoint_with_messages [ message ~role:User [ Text "unrelated history" ] ]
  in
  let outcomes =
    Masc.Keeper_turn_driver.For_testing.project_provider_attempt_result
      ~replay_prefix_projection:
        (Masc.Keeper_replay_prefix.media_degraded
           ~canonical_prefix
           ~dispatch_prefix)
      (Ok (run_result ~checkpoint:drifted_checkpoint ()))
  in
  (match Masc.Keeper_turn_driver.For_testing.provider_result outcomes with
   | Ok _ -> ()
   | Error error ->
     Alcotest.failf
       "provider success source was overwritten: %s"
       (Agent_sdk.Error.to_string error));
  match Masc.Keeper_turn_driver.For_testing.turn_result outcomes with
  | Error (Agent_sdk.Error.Internal detail) ->
    Alcotest.(check bool)
      "local replay-prefix drift fails the turn explicitly"
      true
      (String.trim detail <> "")
  | Error error ->
    Alcotest.failf
      "expected typed Internal replay-prefix failure, got %s"
      (Agent_sdk.Error.to_string error)
  | Ok _ -> Alcotest.fail "replay-prefix drift did not fail closed"

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
    ?(stop_reason = None)
    ~response_shape
    ~reason
    () =
  Keeper_internal_error.sdk_error_of_masc_internal_error
    (Keeper_internal_error.Accept_rejected
       { scope = "runtime.changed-diagnostic"
       ; model = None
       ; reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
       ; response_shape
       ; stop_reason
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

let test_finalization_does_not_surface_hidden_reasoning () =
  let hidden = "private chain of thought must not become a user reply" in
  let response =
    run_result
      ~content:
        [ Agent_sdk.Types.Thinking { signature = None; content = hidden }
        ; Agent_sdk.Types.ReasoningDetails
            { reasoning_content = Some "provider-private reasoning"
            ; details = []
            }
        ]
      ()
  in
  let finalize tool_names =
    Masc.Keeper_agent_run.For_testing.normalize_response_text_for_finalization
      ~runtime_id:"runtime.reasoning-model"
      ~initial_messages:[]
      ~run_result:response
      ~text:""
      ~tool_names
      ()
  in
  (match finalize [ "masc_schedule_get" ] with
   | Error err ->
     Alcotest.failf "tool fallback should succeed: %s" (Agent_sdk.Error.to_string err)
   | Ok text ->
     Alcotest.(check string)
       "hidden reasoning is replaced by the generic tool-list fallback"
       "No textual reply was produced. Tools invoked: masc_schedule_get."
       text;
     Alcotest.(check bool)
       "Thinking content is not user-facing"
       false
       (contains ~needle:hidden text);
     Alcotest.(check bool)
       "ReasoningDetails content is not user-facing"
       false
       (contains ~needle:"provider-private reasoning" text));
  let _err, reason_kind, reason = expect_accept_rejected (finalize []) in
  Alcotest.(check bool)
    "reasoning-only finalization keeps the typed no-progress rejection"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "typed rejection diagnostic does not expose Thinking content"
    false
    (contains ~needle:hidden reason);
  Alcotest.(check bool)
    "typed rejection diagnostic does not expose ReasoningDetails content"
    false
    (contains ~needle:"provider-private reasoning" reason)

let test_recovery_defer_does_not_synthesize_tool_narration () =
  let deferred =
    { (run_result ()) with
      stop_reason =
        Runtime_agent.ToolFailureRecoveryDeferred
          { turns_used = 2
          ; reason = "wait for repository state"
          ; tool_names = [ "Execute" ]
          }
    }
  in
  match
    Masc.Keeper_agent_run.For_testing.normalize_response_text_for_finalization
      ~runtime_id:"runtime.reasoning-model"
      ~initial_messages:[]
      ~run_result:deferred
      ~text:""
      ~tool_names:[ "Execute" ]
      ()
  with
  | Ok text ->
    Alcotest.(check string)
      "control checkpoint has no synthetic assistant narration"
      ""
      text
  | Error error ->
    Alcotest.failf
      "typed recovery checkpoint should finalize without a chat reply: %s"
      (Agent_sdk.Error.to_string error)

let test_direct_no_progress_retry_uses_runtime_decision () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
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
     | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
       Alcotest.fail "fresh direct empty retry should rotate");
    let thinking_only_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_thinking_only)
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
     | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
       Alcotest.fail "fresh direct thinking-only retry should rotate"))

let cascade_decision_to_string
    (decision : Masc.Keeper_unified_turn_cascade_resolution.cascade_decision_kind) =
  match decision with
  | Degraded_retry_allowed -> "degraded_retry_allowed"
  | No_degraded_retry -> "no_degraded_retry"

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
        ~reason:"shape=empty"
        ()
    in
    let expected_retry_runtime =
      match direct_no_progress_retry_decision empty_err with
      | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed retry ->
        retry.next_runtime
      | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
        Alcotest.fail "fresh direct empty retry should select a fallback runtime"
    in
    let plan
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
      (List.length !published))

let test_direct_no_progress_retry_loop_runs_fallback_attempt () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_sdk_error
        ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
        ~reason:"shape=empty"
        ()
    in
    let expected_retry_runtime =
      match direct_no_progress_retry_decision empty_err with
      | Masc.Keeper_turn_runtime_budget.Degraded_retry_allowed retry ->
        retry.next_runtime
      | Masc.Keeper_turn_runtime_budget.No_degraded_retry ->
        Alcotest.fail "fresh direct empty retry should select a fallback runtime"
    in
    let retry_context_resolution
        : Masc.Keeper_context_runtime.max_context_resolution =
      { requested_override = None
      ; primary_budget = 4096
      ; runtime_budget = 4096
      ; requested_context_window = 4096
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
      ; max_context = retry_context_resolution.requested_context_window
      ; temperature = 0.0
      }
    in
    let result =
      Masc.Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
        ~keeper_name:"keeper-test"
        ~base_runtime:"test_provider.test_model"
        ~initial_runtime:"runtime.direct-empty"
        ~initial_max_context:1024
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
    "manual direct first attempt uses provider-effective context window"
    false
    (contains
       ~needle:"resolution.requested_context_window\n\t            in"
       slice)

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
          outcome = Agent_sdk.Types.Tool_succeeded;
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
   | None -> ()
   | Some other ->
     Alcotest.failf
       "accept rejection must not become a runtime blocker, got %s"
       (Masc.Keeper_meta_contract.blocker_class_to_string other));
  Alcotest.(check (option string))
    "direct keeper_msg rotates empty no-progress"
    (Some "empty_no_progress")
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

let test_media_with_tool_result_is_deliverable () =
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
                 outcome = Agent_sdk.Types.Tool_succeeded;
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
  match result with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf
      "multimodal response with an image must remain deliverable: %s"
      (Agent_sdk.Error.to_string err)

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

let test_carrier_only_stream_remains_observable_without_lifecycle_gate () =
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
    "carrier-only stream does not invent progress"
    []
    recorded;
  Alcotest.(check int) "diagnostic downstream receives carrier stream" 5 downstream_count

(* Candidate exhaustion must retain its typed runtime-exhausted identity so a
   DNS/network failure remains observable without relying on free-text error
   matching. *)
let test_dns_failure_exhaustion_classifies_as_runtime_exhausted () =
  let mapped =
    Keeper_internal_error.sdk_error_of_masc_internal_error
      (Keeper_internal_error.Runtime_exhausted
         { runtime_id = "runtime.dns-test"
         ; reason = Keeper_internal_error.Dns_failure
         })
  in
  Alcotest.(check bool)
    "DNS exhaustion is a runtime-exhausted error"
    true
    (Masc.Keeper_error_classify.is_runtime_exhausted_error mapped);
  Alcotest.(check bool)
    "DNS exhaustion is not auto-recoverable (counts toward crash threshold, \
     per record_failure_observation's counts_toward_crash)"
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
    Keeper_internal_error.sdk_error_of_masc_internal_error
      (Keeper_internal_error.Runtime_exhausted
         { runtime_id = "runtime.no-candidates"
         ; reason = Keeper_internal_error.No_providers_available
         })
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

let test_provider_turn_limit_remains_an_execution_observation () =
  let mapped =
    Agent_sdk.Error.Agent
      (Agent_sdk.Error.MaxTurnsExceeded { turns = 12; limit = 12 })
  in
  (match mapped with
   | Agent_sdk.Error.Agent (Agent_sdk.Error.MaxTurnsExceeded { turns; limit }) ->
     Alcotest.(check int) "turns preserved" 12 turns;
     Alcotest.(check int) "limit preserved" 12 limit
   | _ ->
     Alcotest.failf
       "expected typed MaxTurnsExceeded observation, got %s"
       (Agent_sdk.Error.to_string mapped));
  Alcotest.(check bool)
    "provider turn limit is not runtime exhaustion"
    false
    (Masc.Keeper_error_classify.is_runtime_exhausted_error mapped);
  Alcotest.(check bool)
    "provider turn limit cannot increment Keeper failure streak"
    true
    (Masc.Keeper_error_classify.is_auto_recoverable_turn_error mapped);
  Alcotest.(check bool)
    "provider turn limit grants no blocker"
    true
    (Masc.Keeper_status_bridge.blocker_class_of_sdk_error mapped = None)

let test_capacity_failure_exhaustion_classifies_as_capacity_exhausted () =
  let mapped =
    Keeper_internal_error.sdk_error_of_masc_internal_error
      (Keeper_internal_error.Runtime_exhausted
         { runtime_id = "runtime.capacity-test"
         ; reason = Keeper_internal_error.Capacity_exhausted
         })
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

let test_session_conflict_exhaustion_preserves_typed_terminal_reason () =
  let mapped =
    Keeper_internal_error.sdk_error_of_masc_internal_error
      (Keeper_internal_error.Runtime_exhausted
         { runtime_id = "runtime.session-conflict"
         ; reason = Keeper_internal_error.Session_conflict
         })
  in
  match Keeper_internal_error.classify_masc_internal_error mapped with
  | Some (Keeper_internal_error.Runtime_exhausted { reason; _ }) ->
    Alcotest.(check bool)
      "reason is Session_conflict"
      true
      (reason = Keeper_internal_error.Session_conflict);
    Alcotest.(check bool)
      "session conflict is not automatically retryable"
      false
      (Keeper_internal_error.runtime_exhaustion_reason_retryable reason);
    Alcotest.(check string)
      "session conflict has a stable observation label"
      "session_conflict"
      (Keeper_internal_error.runtime_exhaustion_reason_to_label reason);
    let encoded = Keeper_internal_error.runtime_exhaustion_reason_to_json reason in
    Alcotest.(check bool)
      "session conflict survives persistence round-trip"
      true
      (Keeper_internal_error.runtime_exhaustion_reason_of_json encoded
       = Some Keeper_internal_error.Session_conflict);
    Alcotest.(check bool)
      "session conflict is not auto-recoverable"
      false
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

let test_keeper_tool_slot_callbacks_are_always_wired () =
  let config = Masc.Workspace.default_config (Filename.get_temp_dir_name ()) in
  let _, yield_on_tool, on_yield, on_resume, _ =
    Masc.Keeper_agent_run_turn_helpers.turn_progress_callbacks
      ~config
      ~keeper_name:"slot-lease-test"
      ~downstream:None
      ~turn_id:1
  in
  Alcotest.(check bool) "tool execution always yields the provider lease" true yield_on_tool;
  Alcotest.(check bool) "yield callback is wired" true (Option.is_some on_yield);
  Alcotest.(check bool) "resume callback is wired" true (Option.is_some on_resume)

let () =
  Alcotest.run "keeper_turn_driver_accept"
    [
      ( "accept"
      , [
          Alcotest.test_case "accepted response passes through" `Quick
            test_accept_keeps_result;
          Alcotest.test_case
            "typed recovery control stops bypass response acceptance"
            `Quick
            test_typed_recovery_control_stops_bypass_response_accept;
          Alcotest.test_case
            "replay projection failure preserves provider success"
            `Quick
            test_replay_projection_failure_preserves_provider_success;
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
            "finalization does not surface hidden reasoning"
            `Quick
            test_finalization_does_not_surface_hidden_reasoning;
          Alcotest.test_case
            "recovery defer does not synthesize tool narration"
            `Quick
            test_recovery_defer_does_not_synthesize_tool_narration;
	          Alcotest.test_case
	            "direct no-progress retry uses runtime decision"
	            `Quick
	            test_direct_no_progress_retry_uses_runtime_decision;
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
            "Accept_rejected threads typed stop_reason (RFC-0271 §4.5)"
            `Quick
            test_accept_rejected_threads_stop_reason;
          Alcotest.test_case
            "Accept_rejected stop_reason survives codec (RFC-0271 §4.5)"
            `Quick
            test_accept_rejected_stop_reason_survives_codec;
          Alcotest.test_case "empty non-end-turn response is rejected" `Quick
            test_empty_non_end_turn_response_is_rejected;
          Alcotest.test_case "blank text non-end-turn response is rejected" `Quick
            test_blank_text_non_end_turn_response_is_rejected;
          Alcotest.test_case "custom predicate rejection stays distinct" `Quick
            test_custom_accept_reject_preserves_predicate_reason;
          Alcotest.test_case "media with tool result is deliverable" `Quick
            test_media_with_tool_result_is_deliverable;
          Alcotest.test_case "sse progress classifies known deltas" `Quick
            test_sse_event_progress_kind_classifies_known_deltas;
          Alcotest.test_case
            "sse watchdog progress records deliverable events only"
            `Quick
            test_registry_progress_on_event_records_only_watchdog_progress;
          Alcotest.test_case
            "carrier-only stream remains observable without lifecycle gate"
            `Quick
            test_carrier_only_stream_remains_observable_without_lifecycle_gate;
          Alcotest.test_case
            "DNS failure exhaustion classifies as Runtime_exhausted (KLV-DNS)"
            `Quick
            test_dns_failure_exhaustion_classifies_as_runtime_exhausted;
          Alcotest.test_case
            "no-candidates exhaustion classifies as No_providers_available"
            `Quick
            test_no_candidates_exhaustion_classifies_as_no_providers_available;
          Alcotest.test_case
            "provider turn limit stays an execution observation"
            `Quick
            test_provider_turn_limit_remains_an_execution_observation;
          Alcotest.test_case
            "capacity exhaustion classifies as retryable Runtime_exhausted"
            `Quick
            test_capacity_failure_exhaustion_classifies_as_capacity_exhausted;
          Alcotest.test_case
            "session conflict preserves typed terminal exhaustion"
            `Quick
            test_session_conflict_exhaustion_preserves_typed_terminal_reason;
          Alcotest.test_case
            "runtime exhaustion labels cap free-text detail"
            `Quick
            test_runtime_exhaustion_label_caps_free_text_detail;
          Alcotest.test_case
            "keeper tool slot callbacks are always wired"
            `Quick
            test_keeper_tool_slot_callbacks_are_always_wired;
        ] );
    ]
