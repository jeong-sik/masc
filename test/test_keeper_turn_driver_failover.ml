module Runtime_manifest = Masc.Keeper_runtime_manifest
module Driver = Masc.Keeper_turn_driver

let contains ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  let rec loop i =
    i + needle_len <= haystack_len
    && (String.sub haystack i needle_len = needle || loop (i + 1))
  in
  needle_len = 0 || loop 0

let write_file path content =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let with_model_catalog_content content f =
  let original = Llm_provider.Model_catalog.global () in
  let path = Filename.temp_file "runtime-failover-oas-models" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      (match original with
       | Some catalog -> Llm_provider.Model_catalog.set_global catalog
       | None -> Llm_provider.Model_catalog.clear_global ());
      try Sys.remove path with
      | _ -> ())
    (fun () ->
      write_file path content;
      match Llm_provider.Model_catalog.load_file path with
      | Error msg -> Alcotest.failf "test OAS model catalog should load: %s" msg
      | Ok catalog ->
        Llm_provider.Model_catalog.set_global catalog;
        f ())

let checkpoint_with_session_id session_id : Agent_sdk.Checkpoint.t =
  { version = Agent_sdk.Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "agent-test"
  ; model = "model-test"
  ; system_prompt = None
  ; messages = []
  ; usage = Agent_sdk.Types.empty_usage
  ; turn_count = 1
  ; created_at = 0.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_sdk.Types.Off
  ; thinking_budget = None
  ; cache_system_prompt = false
  ; context = Agent_sdk.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }

let retryable_network_error message =
  Agent_sdk.Error.Api
    (Agent_sdk.Retry.NetworkError
       { message; kind = Llm_provider.Http_client.Unknown })

let provider_cooldown_backpressure_error runtime_id =
  Driver.sdk_error_of_masc_internal_error
    (Driver.Capacity_backpressure
       { runtime_id
       ; source = Driver.Provider_capacity
       ; detail = "provider health cooldown active before dispatch"
       ; retry_after = Driver.Synthetic_default 30.0
       })

let accept_empty_no_progress_error scope =
  Driver.sdk_error_of_masc_internal_error
    (Driver.Accept_rejected
       { scope
       ; model = Some "runtime"
       ; reason_kind = Some Driver.Accept_no_usable_progress
       ; response_shape = Some Driver.Accept_response_empty
       ; last_tool_effect = None
       ; any_mutating_tool = None
       ; tool_effects_seen = []
       ; reason = "empty assistant response"
       })

let runtime_toml_with_lane =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
strategy = "ordered"
candidates = [ "primary.test_model", "fallback.test_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.fallback]
display-name = "Fallback Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
|}

let runtime_toml_thinking_lane =
  {|
[runtime]
default = "thinking.reasoning_big"

[runtime.lanes.mixed]
strategy = "ordered"
candidates = [ "thinking.reasoning_big", "plain.non_reasoning" ]

[providers.thinking]
display-name = "Thinking Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.plain]
display-name = "Plain Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.reasoning_big]
api-name = "reasoning-big-out"
max-context = 1000000
tools-support = true
thinking-support = true
preserve-thinking = true
streaming = true

[models.non_reasoning]
api-name = "non-reasoning"
max-context = 8192
tools-support = true
thinking-support = false
preserve-thinking = false
streaming = true

[thinking.reasoning_big]
is-default = true
max-concurrent = 1

[plain.non_reasoning]
max-concurrent = 1
|}

let runtime_thinking_lane_model_catalog =
  {|
[[models]]
id_prefix = "openai_compat/reasoning-big-out"
base = "openai_chat"
max_context_tokens = 1000000
max_output_tokens = 200000
supports_tools = true
supports_reasoning = true
supports_extended_thinking = true
supports_native_streaming = true
|}

let runtime_toml_media_lane_with_global_outside =
  {|
[runtime]
default = "primary.text_model"
media_failover = [ "outsidevision.vision_model" ]

[runtime.lanes.resilient]
strategy = "ordered"
candidates = [ "primary.text_model", "lanevision.vision_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.lanevision]
display-name = "Lane Vision Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[providers.outsidevision]
display-name = "Outside Vision Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:3"

[models.text_model]
api-name = "text-model"
max-context = 8192
tools-support = true
streaming = true

[models.vision_model]
api-name = "vision-model"
max-context = 8192
tools-support = true
streaming = true

[models.vision_model.capabilities]
supports-image-input = true

[primary.text_model]
is-default = true
max-concurrent = 1

[lanevision.vision_model]
max-concurrent = 1

[outsidevision.vision_model]
max-concurrent = 1
|}

let runtime_toml_unknown_lane_candidate =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
strategy = "ordered"
candidates = [ "primary.test_model", "missing.test_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1
|}

let runtime_toml_lane_shadows_runtime =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes."primary.test_model"]
strategy = "ordered"
candidates = [ "fallback.test_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.fallback]
display-name = "Fallback Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
|}

let with_runtime_config toml f =
  let snapshot = Runtime.For_testing.snapshot () in
  let path = Filename.temp_file "runtime_failover_" ".toml" in
  write_file path toml;
  Fun.protect
    ~finally:(fun () ->
      Runtime.For_testing.restore snapshot;
      try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.init_default ~config_path:path with
       | Ok () -> f ()
       | Error e -> Alcotest.failf "Runtime.init_default failed: %s" e)

let test_lane_loads_ordered_candidates () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.get_lane_by_id "resilient" with
    | None -> Alcotest.fail "expected lane 'resilient' to be configured"
    | Some lane ->
      Alcotest.(check string) "lane id" "resilient" (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "ordered candidates"
        [ "primary.test_model"; "fallback.test_model" ]
        (Runtime_lane.ordered_candidates lane))

let test_lanes_accessor_returns_declared_lanes () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    let lanes = Runtime.lanes () in
    Alcotest.(check int) "one lane declared" 1 (List.length lanes);
    match lanes with
    | [ lane ] ->
      Alcotest.(check string)
        "lane id via lanes ()"
        "resilient"
        (Runtime_lane.id lane)
    | _ -> Alcotest.fail "expected exactly one lane")

let test_resolve_assignment_prefers_lane_over_runtime () =
  with_runtime_config runtime_toml_lane_shadows_runtime (fun () ->
    match Runtime.resolve_assignment "primary.test_model" with
    | `Missing -> Alcotest.fail "expected assignment to resolve"
    | `Single_runtime _ -> Alcotest.fail "expected lane to shadow runtime"
    | `Lane lane ->
      Alcotest.(check string)
        "lane id shadows runtime id"
        "primary.test_model"
        (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "lane candidates"
        [ "fallback.test_model" ]
        (Runtime_lane.ordered_candidates lane))

let test_resolve_assignment_to_single_runtime () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "fallback.test_model" with
    | `Missing -> Alcotest.fail "expected runtime to resolve"
    | `Lane _ -> Alcotest.fail "expected single runtime, not lane"
    | `Single_runtime rt ->
      Alcotest.(check string) "runtime id" "fallback.test_model" rt.Runtime.id)

let test_attempt_inference_policy_uses_attempt_runtime () =
  with_model_catalog_content runtime_thinking_lane_model_catalog @@ fun () ->
  with_runtime_config runtime_toml_thinking_lane (fun () ->
    let max_tokens_for_runtime ~runtime_id =
      Masc.Keeper_run_context.resolve_max_tokens_for_runtime
        ~keeper_name:"policy-test"
        ~runtime_id
        ()
    in
    let lane_policy =
      Driver.For_testing.attempt_inference_policy
        ~max_tokens_for_runtime
        ~runtime_id:"mixed"
        ~fallback_enable_thinking:None
        ~fallback_max_tokens:8192
        ()
    in
    Alcotest.(check (option bool))
      "lane id has no runtime thinking policy"
      None
      lane_policy.Driver.attempt_enable_thinking;
    Alcotest.(check (option bool))
      "lane id has no preserve thinking policy"
      None
      lane_policy.Driver.attempt_preserve_thinking;
    Alcotest.(check int)
      "lane id keeps caller max_tokens fallback"
      8192
      lane_policy.Driver.attempt_max_tokens;
    let thinking_policy =
      Driver.For_testing.attempt_inference_policy
        ~max_tokens_for_runtime
        ~runtime_id:"thinking.reasoning_big"
        ~fallback_enable_thinking:(Some false)
        ~fallback_max_tokens:8192
        ()
    in
    Alcotest.(check (option bool))
      "thinking candidate enables thinking"
      (Some true)
      thinking_policy.Driver.attempt_enable_thinking;
    Alcotest.(check (option bool))
      "thinking candidate preserves thinking when configured"
      (Some true)
      thinking_policy.Driver.attempt_preserve_thinking;
    Alcotest.(check int)
      "thinking candidate sizes from catalog ceiling"
      32768
      thinking_policy.Driver.attempt_max_tokens;
    let non_thinking_policy =
      Driver.For_testing.attempt_inference_policy
        ~max_tokens_for_runtime
        ~runtime_id:"plain.non_reasoning"
        ~fallback_enable_thinking:(Some true)
        ~fallback_max_tokens:8192
        ()
    in
    Alcotest.(check (option bool))
      "non-thinking candidate forces thinking off"
      (Some false)
      non_thinking_policy.Driver.attempt_enable_thinking;
    Alcotest.(check (option bool))
      "non-thinking candidate disables preserve thinking"
      (Some false)
      non_thinking_policy.Driver.attempt_preserve_thinking;
    Alcotest.(check int)
      "non-thinking candidate keeps caller max_tokens fallback"
      8192
      non_thinking_policy.Driver.attempt_max_tokens)

let test_resolve_assignment_missing () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "not.configured" with
    | `Missing -> ()
    | `Single_runtime _ | `Lane _ ->
      Alcotest.fail "expected missing assignment")

let test_unknown_lane_candidate_rejected_at_load () =
  let path = Filename.temp_file "runtime_failover_bad_" ".toml" in
  write_file path runtime_toml_unknown_lane_candidate;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> Alcotest.fail "expected load to fail on unknown lane candidate"
       | Error msg ->
         Alcotest.(check bool)
           "error names unknown candidate"
           true
           (contains ~needle:"missing.test_model" msg))

let assoc_member key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_member key json =
  match assoc_member key json with
  | Some (`String value) -> value
  | _ -> Alcotest.failf "expected string member %S in %s" key (Yojson.Safe.to_string json)

let emit_manifest_collector events ?status ?decision event =
  events := (event, status, decision) :: !events

let event_name event = Runtime_manifest.event_kind_to_string event

let decision_runtime_id = function
  | _, _, Some decision -> string_member "runtime_id" decision
  | event, _, None ->
    Alcotest.failf "missing decision for event %s" (event_name event)

let test_lane_media_degrade_uses_first_candidate_runtime_id () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing | `Single_runtime _ ->
      Alcotest.fail "expected resilient assignment to resolve to a lane"
    | `Lane lane ->
      let first_candidate_id =
        match Runtime_lane.ordered_candidates lane with
        | first :: _ -> first
        | [] -> Alcotest.fail "expected non-empty lane candidates"
      in
      let first_candidate =
        match Runtime.get_runtime_by_id first_candidate_id with
        | Some runtime -> runtime
        | None ->
          Alcotest.failf
            "expected first candidate runtime %S to be configured"
            first_candidate_id
      in
      let selected_runtime_id, selected_runtime =
        Driver.For_testing.first_runtime_after_modality_reroute
          ~keeper_name:"test-keeper" ~assignment_id:"resilient"
          ~first_candidate_id ~first_candidate
          (Runtime_agent.No_capable_runtime { required = [ "image" ] })
      in
      Alcotest.(check string)
        "selected runtime id"
        "primary.test_model"
        selected_runtime_id;
      Alcotest.(check string)
        "selected runtime binding"
        "primary.test_model"
        selected_runtime.Runtime.id;
      let decision =
        Driver.For_testing.media_degrade_manifest_decision
          ~runtime_id:selected_runtime_id
          [ "image", 1 ]
      in
      Alcotest.(check string)
        "degraded runtime id"
        "primary.test_model"
        (string_member "degraded_runtime_id" decision))

let test_lane_media_reroute_stays_within_lane () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing | `Single_runtime _ ->
      Alcotest.fail "expected resilient assignment to resolve to a lane"
    | `Lane lane ->
      let first_candidate_id, remaining_candidate_ids =
        match Runtime_lane.ordered_candidates lane with
        | first :: rest -> first, rest
        | [] -> Alcotest.fail "expected non-empty lane candidates"
      in
      let first_candidate =
        match Runtime.get_runtime_by_id first_candidate_id with
        | Some runtime -> runtime
        | None -> Alcotest.fail "missing first candidate"
      in
      let remaining_runtimes =
        List.map
          (fun runtime_id ->
             match Runtime.get_runtime_by_id runtime_id with
             | Some runtime -> runtime
             | None -> Alcotest.failf "missing lane candidate %s" runtime_id)
          remaining_candidate_ids
      in
      let image_block =
        Agent_sdk.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string "image"
          ; source_type = Agent_sdk.Types.Base64
          }
      in
      match
        Driver.For_testing.lane_modality_reroute_decision
          ~checkpoint_messages:[]
          ~initial_messages:[]
          ~goal_blocks:[ image_block ]
          ~first_candidate
          ~remaining_runtimes
      with
      | Runtime_agent.Reroute { to_runtime_id; _ } ->
        Alcotest.(check string)
          "reroute uses lane candidate, not global media_failover"
          "lanevision.vision_model"
          to_runtime_id
      | Runtime_agent.No_reroute_needed ->
        Alcotest.fail "text-only first candidate should require image reroute"
      | Runtime_agent.No_capable_runtime _ ->
        Alcotest.fail "lane second candidate should be image-capable")

let test_runtime_dedupe_preserves_first_occurrence () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    let runtime id =
      match Runtime.get_runtime_by_id id with
      | Some runtime -> runtime
      | None -> Alcotest.failf "missing runtime %s" id
    in
    let deduped =
      Driver.For_testing.dedupe_runtimes_preserve_order
        [
          runtime "lanevision.vision_model";
          runtime "lanevision.vision_model";
          runtime "outsidevision.vision_model";
          runtime "primary.text_model";
          runtime "outsidevision.vision_model";
        ]
    in
    Alcotest.(check (list string))
      "dedupe preserves first occurrence order"
      [
        "lanevision.vision_model";
        "outsidevision.vision_model";
        "primary.text_model";
      ]
      (List.map (fun (runtime : Runtime.t) -> runtime.Runtime.id) deduped))

let test_attempt_loop_stops_on_nonretryable_failure () =
  let attempts = ref [] in
  let events = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ?resume_checkpoint ~idx:_ ~runtime_id candidate ->
        Alcotest.(check bool)
          "nonretryable attempt does not receive resume checkpoint"
          false
          (Option.is_some resume_checkpoint);
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          Error (Agent_sdk.Error.Internal "primary terminal failure"), None
        | "fallback.test_model" -> Ok runtime_id, None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id -> Alcotest.failf "unexpected fallback success: %s" runtime_id
   | Error (Agent_sdk.Error.Internal msg) ->
     Alcotest.(check string) "primary error preserved" "primary terminal failure" msg
   | Error e ->
     Alcotest.failf "expected primary Internal error, got %s" (Agent_sdk.Error.to_string e));
  Alcotest.(check (list string))
    "attempted candidates"
    [ "primary.test_model" ]
    !attempts;
  let events = List.rev !events in
  Alcotest.(check (list string))
    "manifest events"
    (List.map event_name
       [
         Runtime_manifest.Runtime_routed;
         Runtime_manifest.Runtime_failed;
       ])
    (List.map (fun (event, _, _) -> event_name event) events);
  Alcotest.(check (list string))
    "manifest runtime ids"
    [ "primary.test_model"; "primary.test_model" ]
    (List.map decision_runtime_id events)

let test_attempt_loop_retries_network_error_with_checkpoint () =
  let attempts = ref [] in
  let fallback_resume_session = ref None in
  let events = ref [] in
  let checkpoint_after_primary = checkpoint_with_session_id "after-primary" in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ?resume_checkpoint ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          Alcotest.(check bool)
            "primary starts from initial checkpoint"
            false
            (Option.is_some resume_checkpoint);
          Error (retryable_network_error "primary network failed"), Some checkpoint_after_primary
        | "fallback.test_model" ->
          fallback_resume_session :=
            Option.map
              (fun (checkpoint : Agent_sdk.Checkpoint.t) -> checkpoint.session_id)
              resume_checkpoint;
          Ok runtime_id, None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "fallback selected" "fallback.test_model" runtime_id
   | Error e ->
     Alcotest.failf
       "expected fallback success, got %s"
       (Agent_sdk.Error.to_string e));
  Alcotest.(check (list string))
    "attempted candidates"
    [ "primary.test_model"; "fallback.test_model" ]
    !attempts;
  Alcotest.(check (option string))
    "fallback receives post-attempt checkpoint"
    (Some "after-primary")
    !fallback_resume_session;
  let events = List.rev !events in
  Alcotest.(check (list string))
    "manifest events"
    (List.map event_name
       [
         Runtime_manifest.Runtime_routed;
         Runtime_manifest.Runtime_failed;
         Runtime_manifest.Runtime_routed;
         Runtime_manifest.Runtime_completed;
       ])
    (List.map (fun (event, _, _) -> event_name event) events)

let test_attempt_loop_blocks_no_progress_when_gate_denies () =
  let attempts = ref [] in
  let gate_calls = ref [] in
  let events = ref [] in
  let checkpoint_after_primary = checkpoint_with_session_id "after-primary" in
  let primary_error = accept_empty_no_progress_error "primary.test_model" in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~allow_accept_no_progress_retry:(fun ~runtime_id ~attempt error ->
        gate_calls
        := ( runtime_id,
             attempt,
             Driver.For_testing.accept_no_progress_should_try_next error )
           :: !gate_calls;
        false)
      ~run_attempt:(fun ?resume_checkpoint ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          Alcotest.(check bool)
            "primary starts from initial checkpoint"
            false
            (Option.is_some resume_checkpoint);
          Error primary_error, Some checkpoint_after_primary
        | "fallback.test_model" ->
          Alcotest.fail "no-progress retry gate should block fallback candidate"
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Error err ->
     Alcotest.(check string)
       "primary no-progress error preserved"
       (Agent_sdk.Error.to_string primary_error)
       (Agent_sdk.Error.to_string err)
   | Ok runtime_id ->
     Alcotest.failf "unexpected fallback success: %s" runtime_id);
  Alcotest.(check (list string))
    "attempted candidates"
    [ "primary.test_model" ]
    !attempts;
  (match List.rev !gate_calls with
   | [ (runtime_id, attempt, should_try_next) ] ->
     Alcotest.(check string) "gate runtime" "primary.test_model" runtime_id;
     Alcotest.(check int) "gate attempt" 0 attempt;
     Alcotest.(check bool)
       "gate sees no-progress error"
       true
       should_try_next
   | calls ->
     Alcotest.failf "expected one no-progress gate call, got %d"
       (List.length calls));
  let events = List.rev !events in
  Alcotest.(check (list string))
    "manifest events"
    (List.map event_name
       [
         Runtime_manifest.Runtime_routed;
         Runtime_manifest.Runtime_failed;
       ])
    (List.map (fun (event, _, _) -> event_name event) events)

let test_attempt_loop_does_not_gate_network_retry () =
  let attempts = ref [] in
  let gate_called = ref false in
  let events = ref [] in
  let checkpoint_after_primary = checkpoint_with_session_id "after-primary" in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~allow_accept_no_progress_retry:(fun ~runtime_id:_ ~attempt:_ _ ->
        gate_called := true;
        false)
      ~run_attempt:(fun ?resume_checkpoint ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          Alcotest.(check bool)
            "primary starts from initial checkpoint"
            false
            (Option.is_some resume_checkpoint);
          Error (retryable_network_error "primary network failed"), Some checkpoint_after_primary
        | "fallback.test_model" -> Ok runtime_id, None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "fallback selected" "fallback.test_model" runtime_id
   | Error e ->
     Alcotest.failf
       "expected fallback success, got %s"
       (Agent_sdk.Error.to_string e));
  Alcotest.(check bool)
    "network retry does not call no-progress gate"
    false
    !gate_called;
  Alcotest.(check (list string))
    "attempted candidates"
    [ "primary.test_model"; "fallback.test_model" ]
    !attempts;
  Alcotest.(check int)
    "network retry still emits all manifest events"
    4
    (List.length !events)

let test_attempt_loop_retries_provider_cooldown_with_checkpoint () =
  let attempts = ref [] in
  let events = ref [] in
  let checkpoint_after_primary = checkpoint_with_session_id "after-primary" in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ?resume_checkpoint ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          Alcotest.(check bool)
            "primary starts from initial checkpoint"
            false
            (Option.is_some resume_checkpoint);
          ( Error (provider_cooldown_backpressure_error runtime_id)
          , Some checkpoint_after_primary )
        | "fallback.test_model" ->
          Alcotest.(check (option string))
            "fallback receives post-cooldown checkpoint"
            (Some "after-primary")
            (Option.map
               (fun (cp : Agent_sdk.Checkpoint.t) -> cp.session_id)
               resume_checkpoint);
          Ok runtime_id, None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "fallback selected" "fallback.test_model" runtime_id
   | Error e ->
     Alcotest.failf
       "expected fallback success, got %s"
       (Agent_sdk.Error.to_string e));
  Alcotest.(check (list string))
    "attempted candidates"
    [ "primary.test_model"; "fallback.test_model" ]
    !attempts;
  let events = List.rev !events in
  Alcotest.(check (list string))
    "manifest events"
    (List.map event_name
       [
         Runtime_manifest.Runtime_routed;
         Runtime_manifest.Runtime_failed;
         Runtime_manifest.Runtime_routed;
         Runtime_manifest.Runtime_completed;
       ])
    (List.map (fun (event, _, _) -> event_name event) events)

let test_attempt_loop_preserves_last_sdk_error () =
  let events = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ?resume_checkpoint:_ ~idx:_ ~runtime_id _candidate ->
        Error (retryable_network_error (runtime_id ^ " failed")), None)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok _ -> Alcotest.fail "expected final candidate error"
   | Error (Agent_sdk.Error.Api (Agent_sdk.Retry.NetworkError { message; _ })) ->
     Alcotest.(check string)
       "last candidate error preserved"
       "fallback.test_model failed"
       message
   | Error e ->
     Alcotest.failf
       "expected final network error, got %s"
       (Agent_sdk.Error.to_string e));
  let events = List.rev !events in
  Alcotest.(check (list string))
    "failed runtime ids"
    [ "primary.test_model"; "fallback.test_model" ]
    (events
     |> List.filter (fun (event, _, _) ->
       match event with
       | Runtime_manifest.Runtime_failed -> true
       | _ -> false)
     |> List.map decision_runtime_id)

let () =
  Alcotest.run
    "keeper_turn_driver_failover"
    [
      ( "runtime_lane_resolution"
      , [
          Alcotest.test_case
            "lane loads ordered candidate ids"
            `Quick
            test_lane_loads_ordered_candidates;
          Alcotest.test_case
            "lanes accessor returns declared lanes"
            `Quick
            test_lanes_accessor_returns_declared_lanes;
          Alcotest.test_case
            "resolve_assignment prefers lane over runtime"
            `Quick
            test_resolve_assignment_prefers_lane_over_runtime;
          Alcotest.test_case
            "resolve_assignment returns single runtime"
            `Quick
            test_resolve_assignment_to_single_runtime;
          Alcotest.test_case
            "resolve_assignment reports missing id"
            `Quick
            test_resolve_assignment_missing;
          Alcotest.test_case
            "unknown lane candidate rejected at load"
            `Quick
            test_unknown_lane_candidate_rejected_at_load;
          Alcotest.test_case
            "lane media degrade uses first candidate runtime id"
            `Quick
            test_lane_media_degrade_uses_first_candidate_runtime_id;
          Alcotest.test_case
            "lane media reroute stays within lane"
            `Quick
            test_lane_media_reroute_stays_within_lane;
          Alcotest.test_case
            "runtime dedupe preserves first occurrence"
            `Quick
            test_runtime_dedupe_preserves_first_occurrence;
          Alcotest.test_case
            "attempt inference policy uses attempt runtime"
            `Quick
            test_attempt_inference_policy_uses_attempt_runtime;
          Alcotest.test_case
            "attempt loop stops on nonretryable failure"
            `Quick
            test_attempt_loop_stops_on_nonretryable_failure;
          Alcotest.test_case
            "attempt loop retries network error with checkpoint"
            `Quick
            test_attempt_loop_retries_network_error_with_checkpoint;
          Alcotest.test_case
            "attempt loop blocks no-progress when gate denies"
            `Quick
            test_attempt_loop_blocks_no_progress_when_gate_denies;
          Alcotest.test_case
            "attempt loop does not gate network retry"
            `Quick
            test_attempt_loop_does_not_gate_network_retry;
          Alcotest.test_case
            "attempt loop retries provider cooldown with checkpoint"
            `Quick
            test_attempt_loop_retries_provider_cooldown_with_checkpoint;
          Alcotest.test_case
            "attempt loop preserves last SDK error"
            `Quick
            test_attempt_loop_preserves_last_sdk_error;
        ] );
    ]
