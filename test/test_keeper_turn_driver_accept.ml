let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let response ?(content = []) ?(stop_reason = Agent_core.Types.EndTurn) () =
  {
    Agent_core.Types.id = "resp-test";
    model = "model-test";
    stop_reason;
    content;
    usage = None;
    telemetry = None;
  }

let message ?(role = Agent_core.Types.Assistant) content : Agent_core.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

let checkpoint_with_messages messages : Agent_core.Checkpoint.t =
  {
    Agent_core.Checkpoint.version = Agent_core.Checkpoint.checkpoint_version;
    session_id = "session-test";
    agent_name = "agent-test";
    model = "model-test";
    system_prompt = None;
    messages;
    usage = Agent_core.Types.empty_usage;
    turn_count = 1;
    created_at = 0.0;
    tools = [];
    tool_choice = None;
    disable_parallel_tool_use = false;
    temperature = None;
    top_p = None;
    top_k = None;
    min_p = None;
    reasoning_effort = None;
    enable_thinking = None;
    preserve_thinking = None;
    response_format = Agent_core.Types.Off;
    thinking_budget = None;
    cache_system_prompt = false;

    context = Agent_core.Context.create_sync ();
    mcp_sessions = [];
    working_context = None;
  }

let run_result ?content ?stop_reason ?checkpoint () : Runtime_agent.run_result =
  {
    response = response ?content ?stop_reason ();
    checkpoint;
    session_id = "session-test";
    session_resumed = None;
    turns = 1;
    trace_ref = None;
    run_validation = None;
    runtime_observation = None;
    stop_reason = Runtime_agent.Completed;
  }

let input_required_request () : Agent_core.Error.input_required =
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
      | `Thinking_only_no_progress -> "thinking_only_no_progress"
      | `Truncated_no_progress -> "truncated_no_progress")
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
max-request-body-bytes = 65536
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

let test_dispatch_rejects_runtime_without_serialized_request_cap () =
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "uncapped_keeper_runtime_" ".toml" in
  let uncapped =
    String.concat
      "\n"
      [ "[runtime]"
      ; "default = \"test_provider.test_model\""
      ; ""
      ; "[providers.test_provider]"
      ; "protocol = \"openai-compatible-http\""
      ; "endpoint = \"http://127.0.0.1:1/v1\""
      ; ""
      ; "[models.test_model]"
      ; "api-name = \"test-model\""
      ; "max-context = 8192"
      ; "tools-support = true"
      ; "streaming = true"
      ; ""
      ; "[test_provider.test_model]"
      ]
  in
  write_file path uncapped;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.init_default ~config_path:path with
       | Error error -> Alcotest.failf "fixture load failed: %s" error
       | Ok () ->
         (match
            Masc.Keeper_turn_driver.For_testing.resolve_runtime_candidate_for_attempt
              "test_provider.test_model"
          with
          | Error
              (Agent_core.Error.Config
                (Agent_core.Error.InvalidConfig
                  { field = "max-request-body-bytes"; _ })) ->
            ()
          | Error error ->
            Alcotest.failf
              "wrong typed cap rejection: %s"
              (Agent_core.Error.to_string error)
          | Ok _ ->
            Alcotest.fail
              "uncapped Keeper runtime must be rejected before provider dispatch"))

type direct_retry_observed_attempt =
  { observed_runtime_id : string
  ; observed_max_context : int
  ; observed_is_retry : bool
  ; observed_degraded_retry_runtime : string option
  ; observed_fallback_reason : string option
  ; observed_rotation_attempt_count : int
  }

let test_keeper_hook_relaxes_strict_tool_choice () =
  let open Agent_core.Types in
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
      (Agent_core.Error.to_string err)

let test_input_required_bypasses_response_accept () =
  let accept_calls = ref 0 in
  let reject (_ : Agent_core.Types.api_response) =
    incr accept_calls;
    false
  in
  let request = input_required_request () in
  let result =
    { (run_result ()) with
      stop_reason = Runtime_agent.InputRequired { turns_used = 2; request }
    }
  in
  (match
     Masc.Keeper_turn_driver.For_testing.apply_accept
       ~runtime_id:"runtime.reasoning-model"
       ~accept:reject
       result
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.failf
       "InputRequired rotated through response acceptance: %s"
       (Agent_core.Error.to_string error));
  Alcotest.(check int)
    "InputRequired never invokes the deliverable accept predicate"
    0
    !accept_calls

let test_terminal_tool_completion_bypasses_empty_response_rejection () =
  let accept_calls = ref 0 in
  let reject (_ : Agent_core.Types.api_response) =
    incr accept_calls;
    false
  in
  let completed_state () =
    Masc.Keeper_tools_agent_core.Terminal_effect_completed
      (Masc.Keeper_tool_execution.Surface_post_completed
         Masc.Keeper_surface_post.To_dashboard)
  in
  (match
     Masc.Keeper_turn_driver.For_testing.apply_official_client_accept
       ~runtime_id:"runtime.official-client"
       ~accept:reject
       ~terminal_effect_state:completed_state
       (run_result ~content:[] ())
   with
   | Ok _ -> ()
   | Error error ->
     Alcotest.failf
       "settled terminal tool completion was rejected: %s"
       (Agent_core.Error.to_string error));
  Alcotest.(check int)
    "terminal completion does not invoke response-content acceptance"
    0
    !accept_calls

let test_open_terminal_state_keeps_empty_response_rejection () =
  match
    Masc.Keeper_turn_driver.For_testing.apply_official_client_accept
      ~runtime_id:"runtime.official-client"
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      ~terminal_effect_state:(fun () ->
        Masc.Keeper_tools_agent_core.Terminal_effect_open)
      (run_result ~content:[] ())
  with
  | Error error ->
    (match Keeper_internal_error.classify_masc_internal_error error with
     | Some (Keeper_internal_error.Accept_rejected { reason; _ }) ->
       Alcotest.(check bool)
         "ordinary empty response remains typed no-progress"
         true
         (contains ~needle:"response rejected by accept" reason)
     | Some other ->
       Alcotest.failf
         "ordinary empty response produced %s"
         (Keeper_internal_error.kind_of_masc_internal_error other)
     | None ->
       Alcotest.failf
         "ordinary empty response produced the wrong rejection: %s"
         (Agent_core.Error.to_string error))
  | Ok _ -> Alcotest.fail "ordinary empty response was incorrectly accepted"

let test_replay_projection_failure_preserves_provider_success () =
  let open Agent_core.Types in
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
       (Agent_core.Error.to_string error));
  match Masc.Keeper_turn_driver.For_testing.turn_result outcomes with
  | Error (Agent_core.Error.Internal detail) ->
    Alcotest.(check bool)
      "local replay-prefix drift fails the turn explicitly"
      true
      (String.trim detail <> "")
  | Error error ->
    Alcotest.failf
      "expected typed Internal replay-prefix failure, got %s"
      (Agent_core.Error.to_string error)
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
         (Agent_core.Error.to_string err))

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
         (Agent_core.Error.to_string err))

let accept_rejected_core_error
    ?(stop_reason = None)
    ~response_shape
    ~reason
    () =
  Keeper_internal_error.core_error_of_masc_internal_error
    (Keeper_internal_error.Accept_rejected
       { scope = "runtime.changed-diagnostic"
       ; model = None
       ; reason_kind = Some Keeper_internal_error.Accept_no_usable_progress
       ; response_shape
       ; stop_reason
       ; reason
       })

(* A max-tokens rejection owed the checkpoint two different things, and one
   condition decided both: the cut only happened when thinking had been on.
   With thinking already off there was no second attempt to make -- and the
   response accept had just called unusable stayed in the checkpoint, becoming
   input on every later turn.

   Measured on sangsu, 2026-09-03, thinking off throughout: collapse into one
   repeated word, rejected at max_tokens, message_assistant_text 136 KB ->
   308 KB over twelve turns in 30-40 KB steps -- the size of the rejected
   text each time. *)
let truncation_recovery ~enable_thinking ~result ~checkpoint =
  Masc.Keeper_turn_driver_try_provider.For_testing.truncation_recovery
    ~enable_thinking ~result ~checkpoint

let max_tokens_rejection () =
  Error
    (accept_rejected_core_error
       ~stop_reason:(Some Agent_core.Types.MaxTokens)
       ~response_shape:None
       ~reason:"response rejected by accept: stop_reason=max_tokens"
       ())

let assistant_ended_checkpoint () =
  checkpoint_with_messages
    [ message ~role:Agent_core.Types.Tool [ Agent_core.Types.Text "tool output" ]
    ; message [ Agent_core.Types.Text "collapsed" ]
    ]

let test_a_rejected_response_leaves_the_checkpoint_either_way () =
  let checkpoint = assistant_ended_checkpoint () in
  let cut_messages = function
    | Masc.Keeper_turn_driver_try_provider.For_testing.Retry_without_thinking c
    | Masc.Keeper_turn_driver_try_provider.For_testing.Drop_rejected_response c ->
      List.length c.Agent_core.Checkpoint.messages
    | Masc.Keeper_turn_driver_try_provider.For_testing.Recovery_not_applicable ->
      Alcotest.fail "a max-tokens rejection must reach the checkpoint"
  in
  (match
     truncation_recovery ~enable_thinking:(Some true)
       ~result:(max_tokens_rejection ()) ~checkpoint:(Some checkpoint)
   with
   | Masc.Keeper_turn_driver_try_provider.For_testing.Retry_without_thinking _ as
     plan ->
     Alcotest.(check int) "thinking on: retry on the cut checkpoint" 1
       (cut_messages plan)
   | _ -> Alcotest.fail "thinking on must still retry without thinking");
  (* The case that was silently keeping the rejected text. *)
  match
    truncation_recovery ~enable_thinking:(Some false)
      ~result:(max_tokens_rejection ()) ~checkpoint:(Some checkpoint)
  with
  | Masc.Keeper_turn_driver_try_provider.For_testing.Drop_rejected_response _ as
    plan ->
    Alcotest.(check int) "thinking off: the rejected response is still dropped" 1
      (cut_messages plan)
  | Masc.Keeper_turn_driver_try_provider.For_testing.Retry_without_thinking _ ->
    Alcotest.fail "thinking is already off; there is no remedy to retry"
  | Masc.Keeper_turn_driver_try_provider.For_testing.Recovery_not_applicable ->
    Alcotest.fail "the rejected response must leave the checkpoint"

let test_recovery_is_scoped_to_max_tokens_rejections () =
  let checkpoint = assistant_ended_checkpoint () in
  let not_applicable name plan =
    match plan with
    | Masc.Keeper_turn_driver_try_provider.For_testing.Recovery_not_applicable ->
      ()
    | _ -> Alcotest.failf "%s must not cut the checkpoint" name
  in
  not_applicable "a successful turn"
    (truncation_recovery ~enable_thinking:(Some false)
       ~result:(Ok (run_result ())) ~checkpoint:(Some checkpoint));
  not_applicable "a rejection that did not stop at max_tokens"
    (truncation_recovery ~enable_thinking:(Some false)
       ~result:
         (Error
            (accept_rejected_core_error ~stop_reason:(Some Agent_core.Types.EndTurn)
               ~response_shape:None ~reason:"clean no-progress" ()))
       ~checkpoint:(Some checkpoint));
  not_applicable "a rejection with no checkpoint to cut"
    (truncation_recovery ~enable_thinking:(Some false)
       ~result:(max_tokens_rejection ()) ~checkpoint:None)

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
    (threaded Agent_core.Types.MaxTokens = Some Agent_core.Types.MaxTokens);
  Alcotest.(check bool) "EndTurn threaded" true
    (threaded Agent_core.Types.EndTurn = Some Agent_core.Types.EndTurn)

let test_accept_rejected_stop_reason_survives_codec () =
  (* to_json -> of_json preserves the typed stop_reason (Slice 1 codec). *)
  let err =
    accept_rejected_core_error
      ~stop_reason:(Some Agent_core.Types.MaxTokens)
      ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
      ~reason:"response rejected by accept (runtime=x): shape=empty"
      ()
  in
  match Keeper_internal_error.classify_masc_internal_error err with
  | Some (Keeper_internal_error.Accept_rejected { stop_reason; _ }) ->
    Alcotest.(check bool) "stop_reason survives codec round-trip" true
      (stop_reason = Some Agent_core.Types.MaxTokens)
  | _ -> Alcotest.fail "expected Accept_rejected after codec round-trip"

(* A max_tokens stop on a response with nothing deliverable keeps the shape's
   rotation kind, so the lane moves on when the continuation cannot run; the
   continuation attempt itself is still offered to every max_tokens
   no-progress rejection. Pinned after analyst repeated a thinking-only
   max_tokens turn nine times on 2026-09-02 with a second lane candidate
   idle. *)
let test_max_tokens_without_content_keeps_rotation_kind () =
  let thinking_only =
    accept_rejected_core_error
      ~stop_reason:(Some Agent_core.Types.MaxTokens)
      ~response_shape:(Some Keeper_internal_error.Accept_response_thinking_only)
      ~reason:"shape=thinking_only stop_reason=max_tokens"
      ()
  in
  let empty =
    accept_rejected_core_error
      ~stop_reason:(Some Agent_core.Types.MaxTokens)
      ~response_shape:(Some Keeper_internal_error.Accept_response_empty)
      ~reason:"shape=empty stop_reason=max_tokens"
      ()
  in
  let partial =
    accept_rejected_core_error
      ~stop_reason:(Some Agent_core.Types.MaxTokens)
      ~response_shape:
        (Some Keeper_internal_error.Accept_response_has_deliverable_content)
      ~reason:"shape=has_deliverable_content stop_reason=max_tokens"
      ()
  in
  let kind err =
    match Keeper_internal_error.classify_masc_internal_error err with
    | Some internal_error ->
      Option.map
        (function
          | `Empty_no_progress -> "empty_no_progress"
          | `Thinking_only_no_progress -> "thinking_only_no_progress"
          | `Truncated_no_progress -> "truncated_no_progress")
        (Keeper_internal_error.accept_no_progress_retry_kind internal_error)
    | None -> None
  in
  Alcotest.(check (option string))
    "thinking-only max_tokens keeps the thinking-only kind"
    (Some "thinking_only_no_progress")
    (kind thinking_only);
  Alcotest.(check (option string))
    "empty max_tokens keeps the empty kind"
    (Some "empty_no_progress")
    (kind empty);
  Alcotest.(check (option string))
    "partial-content max_tokens is the truncation kind"
    (Some "truncated_no_progress")
    (kind partial);
  Alcotest.(check bool)
    "thinking-only max_tokens can try the next candidate"
    true
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next
       thinking_only);
  Alcotest.(check bool)
    "partial-content max_tokens does not rotate"
    false
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next
       partial);
  List.iter
    (fun (label, err) ->
       Alcotest.(check bool)
         (label ^ " is offered the max_tokens continuation")
         true
         (Masc.Keeper_turn_driver_try_provider.For_testing
          .max_tokens_truncation_error
            err))
    [ "thinking-only", thinking_only; "empty", empty; "partial", partial ];
  let end_turn_thinking_only =
    accept_rejected_core_error
      ~stop_reason:(Some Agent_core.Types.EndTurn)
      ~response_shape:(Some Keeper_internal_error.Accept_response_thinking_only)
      ~reason:"shape=thinking_only stop_reason=end_turn"
      ()
  in
  Alcotest.(check bool)
    "an end_turn thinking-only rejection is not a truncation"
    false
    (Masc.Keeper_turn_driver_try_provider.For_testing.max_tokens_truncation_error
       end_turn_thinking_only)
;;

let test_reject_reason_describes_thinking_only_response () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-model"
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_core.Types.Thinking
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
         (Agent_core.Error.to_string err))

let test_external_effect_finalization_returns_no_synthetic_prose () =
  let run_result =
    { (run_result ()) with
      stop_reason = Runtime_agent.Awaiting_external_effect { turns_used = 1 }
    }
  in
  match
    Masc.Keeper_agent_run.For_testing.normalize_response_text_for_finalization
      ~runtime_id:"test-runtime"
      ~initial_messages:[]
      ~run_result
      ~text:""
      ~tool_names:[]
      ()
  with
  | Ok response_text ->
    Alcotest.(check string)
      "external effect status stays out of assistant speech"
      ""
      response_text
  | Error error ->
    Alcotest.failf
      "external effect typed status unexpectedly rejected: %s"
      (Agent_core.Error.to_string error)
;;

let test_finalization_does_not_surface_hidden_reasoning () =
  let hidden = "private chain of thought must not become a user reply" in
  let response =
    run_result
      ~content:
        [ Agent_core.Types.Thinking { signature = None; content = hidden }
        ; Agent_core.Types.ReasoningDetails
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
     Alcotest.failf "tool fallback should succeed: %s" (Agent_core.Error.to_string err)
   | Ok text ->
     Alcotest.(check string)
       "tool-only completion does not fabricate assistant prose"
       ""
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

let test_direct_no_progress_retry_uses_runtime_decision () =
  with_direct_retry_runtime (fun () ->
    let empty_err =
      accept_rejected_core_error
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
      accept_rejected_core_error
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
  let err = Agent_core.Error.Internal "empty direct response" in
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
         (Agent_core.Error.to_string fail_open_err));
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
  let err = Agent_core.Error.Internal "empty direct response" in
  let setup_err = Agent_core.Error.Internal "retry setup failed" in
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
      (Agent_core.Error.to_string setup_err)
      (Agent_core.Error.to_string fail_open_err);
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
      accept_rejected_core_error
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
    let setup_err = Agent_core.Error.Internal "plan setup failed" in
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
         (Agent_core.Error.to_string setup_err)
         (Agent_core.Error.to_string fail_open_err)
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
      accept_rejected_core_error
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
      ; runtime_budget_source = Some Runtime.Capability
      ; requested_context_window = 4096
      ; effective_budget = 4096
      }
    in
    (* #27331: distinct from [retry_context_resolution] on purpose. The two
       assertions below ("first attempt uses initial max context" = 1024,
       "final max context comes from fallback runtime" = 4096) exist to prove
       [run_direct_no_progress_retry_loop] threads each attempt's OWN
       [runtime_execution.max_context] through instead of reusing whichever
       runtime happened to run first. #26177 migrated this call site from
       [~initial_max_context:1024] to [~initial_execution] but built the new
       value via [retry_execution], which carries [retry_context_resolution]
       (4096) — collapsing the two runtimes onto one budget and silently
       making the first assertion false. Restoring a resolution of its own
       is the fix; the sibling test below (2048, its own record) shows the
       migration done correctly. *)
    let initial_context_resolution
        : Masc.Keeper_context_runtime.max_context_resolution =
      { requested_override = None
      ; primary_budget = 1024
      ; runtime_budget = 1024
      ; runtime_budget_source = Some Runtime.Capability
      ; requested_context_window = 1024
      ; effective_budget = 1024
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
    let initial_execution : Masc.Keeper_turn_runtime_budget.runtime_execution =
      { runtime_id = "runtime.direct-empty"
      ; max_context_resolution = initial_context_resolution
      ; max_context = initial_context_resolution.requested_context_window
      ; temperature = 0.0
      }
    in
    let result =
      Masc.Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
        ~keeper_name:"keeper-test"
        ~base_runtime:"test_provider.test_model"
        ~initial_execution
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
         (Agent_core.Error.to_string err)
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
  let terminal_err = Agent_core.Error.Internal "not retryable" in
  let initial_execution : Masc.Keeper_turn_runtime_budget.runtime_execution =
    { runtime_id = "runtime.initial"
    ; max_context_resolution =
        { requested_override = None
        ; primary_budget = 2048
        ; runtime_budget = 2048
        ; runtime_budget_source = Some Runtime.Capability
        ; requested_context_window = 2048
        ; effective_budget = 2048
        }
    ; max_context = 2048
    ; temperature = 0.0
    }
  in
  let published = ref [] in
  let run_count = ref 0 in
  let result =
      Masc.Keeper_turn_runtime_budget.run_direct_no_progress_retry_loop
      ~keeper_name:"keeper-test"
      ~base_runtime:"runtime.initial"
      ~initial_execution
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
       (Agent_core.Error.to_string terminal_err)
       (Agent_core.Error.to_string err));
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

let test_thinking_with_text_is_accepted () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-text"
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_core.Types.Thinking
               { signature = None; content = "internal chain" };
             Agent_core.Types.Text "final answer";
           ]
         ())
  in
  match result with
  | Ok kept ->
    Alcotest.(check string) "session preserved" "session-test" kept.session_id
  | Error err ->
    Alcotest.failf "thinking plus text should pass accept: %s"
      (Agent_core.Error.to_string err)

let test_thinking_with_tool_use_is_accepted () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-tool"
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_core.Types.Thinking
               { signature = None; content = "internal chain" };
             Agent_core.Types.ToolUse
               { id = "tool-1"; name = "masc_board_search"; input = `Assoc [] };
           ]
         ())
  in
  match result with
  | Ok kept ->
    Alcotest.(check string) "session preserved" "session-test" kept.session_id
  | Error err ->
    Alcotest.failf "thinking plus tool use should pass accept: %s"
      (Agent_core.Error.to_string err)

let check_accept_matches_agent_core_shape label content =
  let response = response ~content () in
  let expected =
    response
    |> Agent_core.Response_shape.summarize
    |> Agent_core.Response_shape.has_deliverable_content
  in
  Alcotest.(check bool)
    label
    expected
    (Keeper_tooling.Response.response_has_text_or_tool_progress response)

let test_accept_contract_delegates_to_agent_core_response_shape () =
  check_accept_matches_agent_core_shape "empty" [];
  check_accept_matches_agent_core_shape
    "thinking only"
    [
      Agent_core.Types.Thinking
        { signature = None; content = "internal chain" };
    ];
  check_accept_matches_agent_core_shape "blank text" [ Agent_core.Types.Text " \n\t " ];
  check_accept_matches_agent_core_shape "text" [ Agent_core.Types.Text "visible answer" ];
  check_accept_matches_agent_core_shape
    "tool use"
    [
      Agent_core.Types.ToolUse
        { id = "tool-1"; name = "masc_board_search"; input = `Assoc [] };
    ];
  check_accept_matches_agent_core_shape
    "tool result"
    [
      Agent_core.Types.ToolResult
        {
          tool_use_id = "tool-1";
          content = "ok";
          outcome = Agent_core.Types.Tool_succeeded;
          json = None;
          content_blocks = None;
        };
    ];
  check_accept_matches_agent_core_shape
    "media"
    [
      Agent_core.Types.Image
        { media_type = "image/png"
        ; data = "redacted"
        ; source_type = Agent_core.Types.Base64
        };
    ]

let test_thinking_only_non_end_turn_response_is_rejected () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.thinking-stop-sequence"
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_core.Types.Thinking
               { signature = None; content = "internal chain" };
           ]
         ~stop_reason:Agent_core.Types.StopSequence
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
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_core.Types.Thinking
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
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result ~stop_reason:Agent_core.Types.StopSequence ())
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
  (match Masc.Keeper_status_bridge.blocker_class_of_core_error err with
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
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:[ Agent_core.Types.Text " \n\t " ]
         ~stop_reason:Agent_core.Types.MaxTokens
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

let test_max_tokens_text_is_rejected_for_checkpoint_continuation () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.max-tokens"
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:[ Agent_core.Types.Text "partial partial partial" ]
         ~stop_reason:Agent_core.Types.MaxTokens
         ())
  in
  let err, reason_kind, reason = expect_accept_rejected result in
  Alcotest.(check bool)
    "typed MaxTokens response is no usable completion"
    true
    (reason_kind = Some Keeper_internal_error.Accept_no_usable_progress);
  Alcotest.(check bool)
    "diagnostic retains typed stop reason"
    true
    (contains ~needle:"stop_reason=max_tokens" reason);
  Alcotest.(check (option string))
    "MaxTokens with visible text classifies as truncation"
    (Some "truncated_no_progress")
    (accept_no_progress_retry_kind_string err);
  Alcotest.(check bool)
    "truncation is handled by same-runtime continuation, not lane rotation"
    false
    (Masc.Keeper_turn_driver.For_testing.accept_no_progress_should_try_next err);
  Alcotest.(check bool)
    "provider helper recognizes the continuation trigger"
    true
    (Masc.Keeper_turn_driver_try_provider.For_testing.max_tokens_truncation_error
       err)
;;

let test_truncation_checkpoint_drops_only_incomplete_assistant () =
  let tool_result =
    { Agent_core.Types.role = Agent_core.Types.Tool
    ; content =
        [ Agent_core.Types.ToolResult
            { tool_use_id = "call-1"
            ; content = "effect already recorded"
            ; outcome = Agent_core.Types.Tool_succeeded
            ; json = None
            ; content_blocks = None
            }
        ]
    ; name = None
    ; tool_call_id = Some "call-1"
    ; metadata = []
    }
  in
  let incomplete = message [ Agent_core.Types.Text "partial" ] in
  let checkpoint = checkpoint_with_messages [ tool_result; incomplete ] in
  match
    Masc.Keeper_turn_driver_try_provider.For_testing
    .checkpoint_before_incomplete_response
      checkpoint
  with
  | None -> Alcotest.fail "assistant-ended checkpoint should be continuable"
  | Some prepared ->
    Alcotest.(check bool)
      "post-tool result is preserved and incomplete assistant is removed"
      true
      (prepared.messages = [ tool_result ]);
    Alcotest.(check int)
      "turn count remains provider-observation history"
      checkpoint.turn_count
      prepared.turn_count
;;

let test_custom_accept_reject_preserves_predicate_reason () =
  let result =
    Masc.Keeper_turn_driver.For_testing.apply_accept
      ~runtime_id:"runtime.custom"
      ~accept:(fun _ -> false)
      (run_result ~content:[ Agent_core.Types.Text "visible answer" ] ())
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
      ~accept:Keeper_tooling.Response.response_has_text_or_tool_progress
      (run_result
         ~content:
           [
             Agent_core.Types.ToolResult
               {
                 tool_use_id = "tool-1";
                 content = "ok";
                 outcome = Agent_core.Types.Tool_succeeded;
                 json = None;
                 content_blocks = None;
               };
             Agent_core.Types.Image
               {
                 media_type = "image/png";
                 data = "redacted";
                 source_type = Agent_core.Types.Base64;
               };
           ]
         ())
  in
  match result with
  | Ok _ -> ()
  | Error err ->
    Alcotest.failf
      "multimodal response with an image must remain deliverable: %s"
      (Agent_core.Error.to_string err)

let test_sse_event_progress_kind_classifies_known_deltas () =
  let open Agent_core.Types in
  let kind event = Masc.Keeper_agent_run_turn_helpers.sse_event_progress_kind event in
  let watchdog_kind event =
    Masc.Keeper_agent_run_turn_helpers.sse_event_watchdog_progress_kind event
  in
  Alcotest.(check (option string))
    "tool block start follows agent-core stream classifier"
    (Some "sse_tool_block_start")
    (kind
       (ContentBlockStart
          { index = 0; content_type = "tool_use"; tool_id = None; tool_name = None }));
  Alcotest.(check (option string))
    "text delta"
    (Some "sse_text_delta")
    (kind (ContentBlockDelta { index = 0; delta = TextDelta "visible" }));
  Alcotest.(check (option string))
    "NDJSON provider error"
    (Some "ndjson_error")
    (kind
       (NDJSONError
          { message = "request rejected"
          ; error_type = Some "rate_limit_exceeded"
          ; raw = "{}"
          }));
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
  let open Agent_core.Types in
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
  let open Agent_core.Types in
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
    Keeper_internal_error.core_error_of_masc_internal_error
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
      (Agent_core.Error.to_string mapped)

let test_no_candidates_exhaustion_classifies_as_no_providers_available () =
  let mapped =
    Keeper_internal_error.core_error_of_masc_internal_error
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
      (Agent_core.Error.to_string mapped)

let test_capacity_failure_exhaustion_classifies_as_capacity_exhausted () =
  let mapped =
    Keeper_internal_error.core_error_of_masc_internal_error
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
      (Agent_core.Error.to_string mapped)

let test_session_conflict_exhaustion_preserves_typed_terminal_reason () =
  let mapped =
    Keeper_internal_error.core_error_of_masc_internal_error
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
      (Agent_core.Error.to_string mapped)

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
            "InputRequired bypasses response acceptance"
            `Quick
            test_input_required_bypasses_response_accept;
          Alcotest.test_case
            "terminal tool completion bypasses empty response rejection"
            `Quick
            test_terminal_tool_completion_bypasses_empty_response_rejection;
          Alcotest.test_case
            "open terminal state keeps empty response rejection"
            `Quick
            test_open_terminal_state_keeps_empty_response_rejection;
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
            "max_tokens without content keeps its rotation kind"
            `Quick
            test_max_tokens_without_content_keeps_rotation_kind;
          Alcotest.test_case
            "blank finalization response is typed no-progress"
            `Quick
            test_finalization_blank_response_is_typed_accept_rejection;
          Alcotest.test_case
            "external effect finalization returns no synthetic prose"
            `Quick
            test_external_effect_finalization_returns_no_synthetic_prose;
          Alcotest.test_case
            "finalization does not surface hidden reasoning"
            `Quick
            test_finalization_does_not_surface_hidden_reasoning;
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
	          Alcotest.test_case "thinking plus text is accepted" `Quick
	            test_thinking_with_text_is_accepted;
          Alcotest.test_case "thinking plus tool use is accepted" `Quick
            test_thinking_with_tool_use_is_accepted;
          Alcotest.test_case "accept delegates to AGENT_CORE response shape" `Quick
            test_accept_contract_delegates_to_agent_core_response_shape;
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
          Alcotest.test_case
            "MaxTokens text uses checkpoint continuation"
            `Quick
            test_max_tokens_text_is_rejected_for_checkpoint_continuation;
          Alcotest.test_case
            "truncation checkpoint preserves tools and drops partial assistant"
            `Quick
            test_truncation_checkpoint_drops_only_incomplete_assistant;
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
            "capacity exhaustion classifies as retryable Runtime_exhausted"
            `Quick
            test_capacity_failure_exhaustion_classifies_as_capacity_exhausted;
          Alcotest.test_case
            "session conflict preserves typed terminal exhaustion"
            `Quick
            test_session_conflict_exhaustion_preserves_typed_terminal_reason;
          Alcotest.test_case
            "dispatch rejects runtime without serialized-request cap"
            `Quick
            test_dispatch_rejects_runtime_without_serialized_request_cap;
          Alcotest.test_case
            "runtime exhaustion labels cap free-text detail"
            `Quick
            test_runtime_exhaustion_label_caps_free_text_detail;
          Alcotest.test_case
            "keeper tool slot callbacks are always wired"
            `Quick
            test_keeper_tool_slot_callbacks_are_always_wired;
          Alcotest.test_case
            "a rejected response leaves the checkpoint either way"
            `Quick
            test_a_rejected_response_leaves_the_checkpoint_either_way;
          Alcotest.test_case
            "truncation recovery is scoped to max-tokens rejections"
            `Quick
            test_recovery_is_scoped_to_max_tokens_rejections;
        ] );
    ]
