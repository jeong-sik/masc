module Runtime_manifest = Masc.Keeper_runtime_manifest
module Driver = Masc.Keeper_turn_driver
module Deferred_store = Masc.Keeper_deferred_runtime_lane_store
module Agent_run_receipt = Masc.Keeper_agent_run_receipt.For_testing
module Run_tools_setup = Masc.Keeper_run_tools_setup

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
  let path = Filename.temp_file "runtime-failover-agent_core-models" ".toml" in
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
      | Error msg -> Alcotest.failf "test AGENT_CORE model catalog should load: %s" msg
      | Ok catalog ->
        Llm_provider.Model_catalog.set_global catalog;
        f ())

let checkpoint_with_session_id session_id : Agent_core.Checkpoint.t =
  { version = Agent_core.Checkpoint.checkpoint_version
  ; session_id
  ; agent_name = "agent-test"
  ; model = "model-test"
  ; system_prompt = None
  ; messages = []
  ; usage = Agent_core.Types.empty_usage
  ; turn_count = 1
  ; created_at = 0.0
  ; tools = []
  ; tool_choice = None
  ; disable_parallel_tool_use = false
  ; temperature = None
  ; top_p = None
  ; top_k = None
  ; min_p = None
  ; reasoning_effort = None
  ; enable_thinking = None
  ; preserve_thinking = None
  ; response_format = Agent_core.Types.Off
  ; thinking_budget = None
  ; cache_system_prompt = false
  ; context = Agent_core.Context.create_sync ()
  ; mcp_sessions = []
  ; working_context = None
  }

let completed_run_result () : Runtime_agent.run_result =
  { response =
      { Agent_core.Types.id = "response-test"
      ; model = "model-test"
      ; stop_reason = Agent_core.Types.EndTurn
      ; content = []
      ; usage = None
      ; telemetry = None
      }
  ; checkpoint = Some (checkpoint_with_session_id "selected-runtime")
  ; session_id = "selected-runtime"
  ; session_resumed = None
  ; turns = 1
  ; trace_ref = None
  ; run_validation = None
  ; runtime_observation = None
  ; stop_reason = Runtime_agent.Completed
  }

let message ?(role = Agent_core.Types.Assistant) content : Agent_core.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

let retryable_network_error message =
  Agent_core.Error.Api
    (Agent_core.Retry.NetworkError
       { message; kind = Llm_provider.Http_client.Unknown })

let attempt_without_effect result checkpoint =
  result, checkpoint, Masc.Keeper_provider_attempt_effect.No_effect_observed
;;

let accept_empty_no_progress_error scope =
  Driver.core_error_of_masc_internal_error
    (Driver.Accept_rejected
       { scope
       ; model = Some "runtime"
       ; reason_kind = Some Driver.Accept_no_usable_progress
       ; response_shape = Some Driver.Accept_response_empty
       ; stop_reason = None
       ; reason = "empty assistant response"
       })

let runtime_toml_with_lane =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
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
max-request-body-bytes = 65536

[fallback.test_model]
max-concurrent = 1
max-request-body-bytes = 65536
|}

let runtime_toml_quota_lane_with_shared_credential shared_credential =
  Printf.sprintf
    {|
[runtime]
default = "shared_a.test_model"

[runtime.lanes.quota_lane]
candidates = [ "shared_a.test_model", "shared_b.test_model", "other.test_model" ]

[providers.shared_a]
display-name = "Shared account A"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.shared_a.credentials]
type = "env"
key = %S

[providers.shared_b]
display-name = "Shared account B"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[providers.shared_b.credentials]
type = "env"
key = %S

[providers.other]
display-name = "Other account"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:3"

[providers.other.credentials]
type = "env"
key = "OTHER_QUOTA_TEST_KEY"

[models.test_model]
api-name = "test-model"
max-context = 8192
tools-support = true
streaming = true

[shared_a.test_model]
is-default = true
max-request-body-bytes = 65536

[shared_b.test_model]
max-request-body-bytes = 65536

[other.test_model]
max-request-body-bytes = 65536
|}
    shared_credential
    shared_credential
;;

let runtime_toml_quota_lane =
  runtime_toml_quota_lane_with_shared_credential "SHARED_QUOTA_TEST_KEY"
;;

let runtime_toml_official_provider_named_like_registry =
  {|
[runtime]
default = "openai.official_model"

[providers.openai]
protocol = "codex-app-server"
command = "/definitely/missing/masc-codex-app-server"
is-non-interactive = true

[models.official_model]
api-name = "gpt-fixture"
max-context = 400000

[openai.official_model]
|}

let runtime_toml_checkpoint_lane =
  {|
[runtime]
default = "codex.codex"

[runtime.lanes.checkpoint_lane]
candidates = [ "codex.codex", "primary.test_model" ]

[providers.codex]
protocol = "codex-app-server"
command = "/definitely/missing/masc-codex-app-server"
is-non-interactive = true

[models.codex]
api-name = "gpt-fixture"
max-context = 400000

[codex.codex]

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
max-request-body-bytes = 65536
|}

let runtime_toml_thinking_lane =
  {|
[runtime]
default = "thinking.reasoning_big"

[runtime.lanes.mixed]
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
temperature = 1.0
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
max-request-body-bytes = 65536

[plain.non_reasoning]
max-concurrent = 1
max-request-body-bytes = 65536
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
|}

let runtime_toml_media_lane_with_global_outside =
  {|
[runtime]
default = "primary.text_model"
media_failover = [ "outsidevision.vision_model" ]

[runtime.lanes.resilient]
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
max-request-body-bytes = 65536

[lanevision.vision_model]
max-concurrent = 1
max-request-body-bytes = 65536

[outsidevision.vision_model]
max-concurrent = 1
max-request-body-bytes = 65536
|}

let runtime_toml_unknown_lane_candidate =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
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
max-request-body-bytes = 65536

[fallback.test_model]
max-concurrent = 1
max-request-body-bytes = 65536
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

let reload_runtime_config toml =
  let path = Filename.temp_file "runtime_failover_reload_" ".toml" in
  Fun.protect
    ~finally:(fun () ->
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
       write_file path toml;
       match Runtime.init_default ~config_path:path with
       | Ok () -> ()
       | Error e -> Alcotest.failf "Runtime.init_default reload failed: %s" e)

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
    | `Lane lane ->
      Alcotest.(check string)
        "lane id shadows runtime id"
        "primary.test_model"
        (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "declared candidates keep their order, then the default terminates"
        [ "fallback.test_model"; "primary.test_model" ]
        (Runtime_lane.ordered_candidates lane))

(* A keeper assigned to a bare runtime id used to dispatch without a lane, which
   turned off failover, sticky candidate preference and quota demotion at once.
   It now gets a lane of its own that ends at [runtime].default. *)
let test_bare_runtime_assignment_gets_a_lane_with_somewhere_to_go () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "fallback.test_model" with
    | `Missing -> Alcotest.fail "expected runtime to resolve"
    | `Lane lane ->
      Alcotest.(check string)
        "lane is named after the runtime it was assigned"
        "fallback.test_model"
        (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "the assigned runtime is head, the default terminates the walk"
        [ "fallback.test_model"; "primary.test_model" ]
        (Runtime_lane.ordered_candidates lane))

(* The default must not be appended twice when a lane already names it. *)
let test_lane_already_naming_the_default_is_unchanged () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing -> Alcotest.fail "expected lane to resolve"
    | `Lane lane ->
      Alcotest.(check (list string))
        "declared candidates already terminate at the default"
        [ "primary.test_model"; "fallback.test_model" ]
        (Runtime_lane.ordered_candidates lane))

let test_attempt_inference_policy_uses_attempt_runtime () =
  with_model_catalog_content runtime_thinking_lane_model_catalog @@ fun () ->
  with_runtime_config runtime_toml_thinking_lane (fun () ->
    (* Runtime candidates resolve their own thinking and temperature policy. *)
    let lane_policy =
      Driver.For_testing.attempt_inference_policy
        ~runtime_id:"mixed"
        ~fallback_enable_thinking:None
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
    let thinking_policy =
      Driver.For_testing.attempt_inference_policy
        ~runtime_id:"thinking.reasoning_big"
        ~fallback_enable_thinking:(Some false)
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
    let non_thinking_policy =
      Driver.For_testing.attempt_inference_policy
        ~runtime_id:"plain.non_reasoning"
        ~fallback_enable_thinking:(Some true)
        ()
    in
    Alcotest.(check (option bool))
      "non-thinking candidate forces thinking off"
      (Some false)
      non_thinking_policy.Driver.attempt_enable_thinking;
    Alcotest.(check (option bool))
      "non-thinking candidate disables preserve thinking"
      (Some false)
      non_thinking_policy.Driver.attempt_preserve_thinking)

let test_resolve_assignment_missing () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "not.configured" with
    | `Missing -> ()
    | `Lane _ -> Alcotest.fail "expected missing assignment")

let runtime_toml_assignment_to_lane =
  {|
[runtime]
default = "primary.test_model"

[runtime.lanes.resilient]
candidates = [ "primary.test_model", "fallback.test_model" ]

[runtime.assignments]
canary = "resilient"

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
max-request-body-bytes = 65536

[fallback.test_model]
max-concurrent = 1
max-request-body-bytes = 65536
|}

(* Pins the current assignment contract: [runtime.assignments] targets must be
   runtime ids, so a keeper can only reach a lane when the lane id shadows a
   runtime id ([resolve_assignment] prefers lanes on collision). Direct lane
   assignment also has no pre-dispatch context budget resolution
   ([resolve_max_context_resolution_for_runtime_id] resolves runtime ids only),
   so accepting it at load would just move this failure to every turn. *)
let test_assignment_to_lane_id_rejected_at_load () =
  let path = Filename.temp_file "runtime_failover_lane_assign_" ".toml" in
  write_file path runtime_toml_assignment_to_lane;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match Runtime.load_list ~config_path:path with
       | Ok _ -> Alcotest.fail "expected load to fail on lane-targeted assignment"
       | Error msg ->
         Alcotest.(check bool)
           "error names the assignment"
           true
           (contains ~needle:"[runtime.assignments].canary" msg))

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

let test_prior_checkpoint_appends_current_goal_once () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let prior_checkpoint =
      { (checkpoint_with_session_id "prior-session") with
        messages =
          [ message ~role:Agent_core.Types.User [ Agent_core.Types.Text "prior goal" ] ]
      }
    in
    let agent_ref = ref None in
    let current_goal = "current goal" in
    (match
       Driver.run_named
         ~runtime_id:"primary.test_model"
         ~keeper_name:"prior-checkpoint-current-goal"
         ~base_path:(Filename.get_temp_dir_name ())
         ~agent_core_tools:[]
         ~goal:current_goal
         ~session_id:prior_checkpoint.session_id
         ~agent_core_checkpoint:prior_checkpoint
         ~agent_ref
         ~sw
         ~net:env#net
         ()
     with
     | Error _ -> ()
     | Ok _ ->
       Alcotest.fail
         "invalid provider endpoints unexpectedly completed the resumed run");
    let messages =
      match !agent_ref with
      | Some agent -> (Agent_core.Agent.state agent).messages
      | None -> Alcotest.fail "expected resumed AGENT_CORE agent"
    in
    let user_messages =
      List.filter
        (fun (entry : Agent_core.Types.message) ->
           entry.role = Agent_core.Types.User)
        messages
    in
    let current_goal_count =
      List.fold_left
        (fun count (entry : Agent_core.Types.message) ->
           match entry.role, entry.content with
           | Agent_core.Types.User, [ Agent_core.Types.Text text ]
             when String.equal text current_goal ->
             count + 1
           | _ -> count)
        0
        messages
    in
    Alcotest.(check int)
      "prior user plus one current user"
      2
      (List.length user_messages);
    Alcotest.(check int)
      "current goal appended exactly once"
      1
      current_goal_count)

let test_deferred_tail_rejects_transformed_uncapped_runtime () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let transformed_urls = ref [] in
    let deferred_runtime_lane =
      Driver.For_testing.make_deferred_runtime_lane
        ~assignment_id:"resilient"
        ~failed_runtime_id:"previous.test_model"
        ~next_runtime_id:"primary.test_model"
        ~later_runtime_ids:[ "fallback.test_model" ]
        ~failure:(retryable_network_error "previous cycle failed")
    in
    let result =
      Driver.run_named
        ~runtime_id:"resilient"
        ~keeper_name:"deferred-request-cap"
        ~base_path:(Filename.get_temp_dir_name ())
        ~agent_core_tools:[]
        ~goal:"prove final provider request admission"
        ~deferred_runtime_lane
        ~provider_config_transform:(fun provider_config ->
          transformed_urls := provider_config.base_url :: !transformed_urls;
          if String.equal provider_config.base_url "http://127.0.0.1:2"
          then Ok { provider_config with max_request_body_bytes = None }
          else Ok provider_config)
        ~body_timeout_s:0.5
        ~sw
        ~net:env#net
        ()
    in
    (match result with
     | Error
         (Agent_core.Error.Config
           (Agent_core.Error.InvalidConfig
             { field = "max-request-body-bytes"; detail })) ->
       Alcotest.(check bool)
         "typed rejection names the deferred tail runtime"
         true
         (contains ~needle:"fallback.test_model" detail)
     | Error error ->
       Alcotest.failf
         "expected final request-cap rejection, got %s"
         (Agent_core.Error.to_string error)
     | Ok _ ->
       Alcotest.fail
         "transformed uncapped deferred runtime reached provider execution");
    Alcotest.(check (list string))
      "capped next candidate runs, then transformed tail is checked"
      [ "http://127.0.0.1:1"; "http://127.0.0.1:2" ]
      (List.rev !transformed_urls))

let test_lane_media_degrade_uses_first_candidate_runtime_id () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing ->
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

let test_run_named_media_degrade_emits_typed_manifest () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let manifests = ref [] in
    let context : Runtime_manifest.turn_context =
      { manifest_keeper_name = "media-degrade-keeper"
      ; manifest_trace_id = "media-degrade-trace"
      ; manifest_keeper_turn_id = Some 1
      }
    in
    let image =
      Agent_core.Types.image_block
        ~media_type:"image/png"
        ~data:(Base64.encode_string "synthetic-image")
        ()
    in
    ignore
      (Driver.run_named
         ~runtime_id:"resilient"
         ~keeper_name:"media-degrade-keeper"
         ~base_path:(Filename.get_temp_dir_name ())
         ~agent_core_tools:[]
         ~goal:"inspect the image"
         ~goal_blocks:[ image ]
         ~runtime_manifest_context:context
         ~runtime_manifest_append:(fun manifest -> manifests := manifest :: !manifests)
         ~body_timeout_s:0.5
         ~sw
         ~net:env#net
         ()
       : (Driver.named_run_result, Agent_core.Error.t) result);
    let degraded =
      List.find_opt
        (fun (manifest : Runtime_manifest.t) ->
           manifest.event = Runtime_manifest.Runtime_routed
           && String.equal manifest.status "degraded")
        !manifests
    in
    match degraded with
    | None -> Alcotest.fail "run_named omitted the media degradation manifest"
    | Some manifest ->
      let decision = Runtime_manifest.public_projection_of_decision manifest.decision in
      Alcotest.(check string)
        "typed routing action"
        "media_degraded_to_text"
        (string_member "routing_action" decision);
      Alcotest.(check string)
        "typed routing reason"
        "no_configured_runtime_accepts_required_media"
        (string_member "routing_reason" decision);
      Alcotest.(check string)
        "degraded runtime identity"
        "primary.test_model"
        (string_member "degraded_runtime_id" decision))

let routed_rows_with_status status manifests =
  List.filter
    (fun (manifest : Runtime_manifest.t) ->
       manifest.event = Runtime_manifest.Runtime_routed
       && String.equal manifest.status status)
    manifests

let run_checkpoint_lane_turn ~history_messages ~on_manifests =
  with_runtime_config runtime_toml_checkpoint_lane (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let manifests = ref [] in
    let context : Runtime_manifest.turn_context =
      { manifest_keeper_name = "checkpoint-runtime-compat-keeper"
      ; manifest_trace_id = "checkpoint-runtime-compat-trace"
      ; manifest_keeper_turn_id = Some 1
      }
    in
    let checkpoint =
      { (checkpoint_with_session_id "agent_core-session") with
        messages = history_messages
      }
    in
    match
      Driver.run_named
        ~runtime_id:"checkpoint_lane"
        ~keeper_name:"checkpoint-runtime-compat-keeper"
        ~base_path:(Filename.get_temp_dir_name ())
        ~agent_core_tools:[]
        ~goal:"continue the AGENT_CORE turn"
        ~initial_messages:history_messages
        ~agent_core_checkpoint:checkpoint
        ~runtime_manifest_context:context
        ~runtime_manifest_append:(fun manifest -> manifests := manifest :: !manifests)
        ~body_timeout_s:0.5
        ~sw
        ~net:env#net
        ()
    with
    | Ok _ -> Alcotest.fail "the AGENT_CORE fixture endpoint unexpectedly completed"
    | Error
        (Agent_core.Error.Config
           (Agent_core.Error.InvalidConfig { field = "agent_core_checkpoint"; _ })) ->
      Alcotest.fail "the official-client runtime must start without AGENT_CORE resume"
    | Error
        (Agent_core.Error.Config
           (Agent_core.Error.InvalidConfig { field = "initial_messages"; _ })) ->
      Alcotest.fail
        "canonical official-client history must stay representable"
    | Error _ -> on_manifests !manifests)

let test_agent_core_checkpoint_preserves_official_client_history () =
  let history_messages =
    [ message
        ~role:Agent_core.Types.User
        [ Agent_core.Types.Text "prior user turn" ]
    ; message
        [ Agent_core.Types.Thinking
            { content = "prior provider reasoning"; signature = None }
        ; Agent_core.Types.ToolUse
            { id = "prior-tool-call"
            ; name = "prior_tool"
            ; input = `Assoc []
            }
        ]
    ; Agent_core.Types.tool_result_msg
        ~tool_use_id:"prior-tool-call"
        ~content:"prior tool result"
        ()
    ]
  in
  run_checkpoint_lane_turn ~history_messages ~on_manifests:(fun manifests ->
    (match routed_rows_with_status "fresh_session" manifests with
     | [] -> ()
     | _ :: _ ->
       Alcotest.fail "the retired fresh_session manifest row must not reappear");
    (match routed_rows_with_status "checkpoint_not_replayed" manifests with
     | [ manifest ] ->
       let decision =
         Runtime_manifest.public_projection_of_decision manifest.decision
       in
       Alcotest.(check string)
         "checkpoint routing action"
         "official_client_checkpoint_not_replayed"
         (string_member "routing_action" decision);
       Alcotest.(check string)
         "checkpoint routing reason"
         "official_client_session_store_owns_resume"
         (string_member "routing_reason" decision)
     | [] ->
       Alcotest.fail "checkpoint_not_replayed manifest row was not observable"
     | _ :: _ :: _ ->
       Alcotest.fail "expected exactly one checkpoint_not_replayed row");
    ())

let test_text_official_client_history_stays_admissible () =
  let history_messages =
    [ message
        ~role:Agent_core.Types.User
        [ Agent_core.Types.Text "prior user turn" ]
    ; message [ Agent_core.Types.Text "prior assistant reply" ]
    ]
  in
  run_checkpoint_lane_turn ~history_messages ~on_manifests:(fun manifests ->
    (match routed_rows_with_status "fresh_session" manifests with
     | [] -> ()
     | _ :: _ ->
       Alcotest.fail "the retired fresh_session manifest row must not reappear");
    (match routed_rows_with_status "checkpoint_not_replayed" manifests with
     | [ _ ] -> ()
     | [] ->
       Alcotest.fail "checkpoint_not_replayed manifest row was not observable"
     | _ :: _ :: _ ->
       Alcotest.fail "expected exactly one checkpoint_not_replayed row");
    ())

let test_lane_media_reroute_stays_within_lane () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing ->
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
        Agent_core.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string "image"
          ; source_type = Agent_core.Types.Base64
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
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          attempt_without_effect
            (Error (Agent_core.Error.Internal "primary terminal failure"))
            None
        | "fallback.test_model" -> attempt_without_effect (Ok runtime_id) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id -> Alcotest.failf "unexpected fallback success: %s" runtime_id
   | Error (Agent_core.Error.Internal msg) ->
     Alcotest.(check string) "primary error preserved" "primary terminal failure" msg
   | Error e ->
     Alcotest.failf "expected primary Internal error, got %s" (Agent_core.Error.to_string e));
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

let test_failed_lane_receipt_counts_missing_tail () =
  let last_attempt_index = ref 0 in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_attempt_error:(fun ~runtime_id:_ ~attempt _error ->
        Run_tools_setup.record_lane_attempt_index last_attempt_index attempt)
      ~run_attempt:(fun ~idx ~runtime_id:_ candidate ->
        match candidate with
        | "resolved.test_model" ->
          (* Production's [on_runtime_attempt] sees this materialized runtime
             before dispatch. *)
          Run_tools_setup.record_lane_attempt_index last_attempt_index idx;
          attempt_without_effect
            (Error (retryable_network_error "resolved candidate failed"))
            None
        | "missing.test_model" ->
          (* A disappeared runtime never reaches [on_runtime_attempt]; its
             typed attempt error is the only receipt observation. *)
          attempt_without_effect
            (Error (Agent_core.Error.Internal "runtime candidate missing"))
            None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "resolved.test_model"; "missing.test_model" ]
  in
  (match result with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "a lane with no winning candidate must fail");
  let count, fallback =
    Agent_run_receipt.lane_attempt_facts
      ~turn_succeeded:false
      ~last_attempt_index:!last_attempt_index
  in
  Alcotest.(check int) "receipt retains both routed candidates" 2 count;
  Alcotest.(check bool) "total failure is not a successful fallback" false fallback

let test_attempt_loop_retries_transport_failure_before_checkpoint () =
  let attempts = ref [] in
  let events = ref [] in
  let checkpoint_stage_observed = Atomic.make false in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _error ->
        Driver.For_testing.same_run_retry_allowed checkpoint_stage_observed)
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          attempt_without_effect
            (Error (retryable_network_error "primary network failed"))
            None
        | "fallback.test_model" -> attempt_without_effect (Ok runtime_id) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "fallback selected" "fallback.test_model" runtime_id
   | Error e ->
     Alcotest.failf
       "expected fallback success, got %s"
       (Agent_core.Error.to_string e));
  Alcotest.(check (list string))
    "attempted candidates"
    [ "primary.test_model"; "fallback.test_model" ]
    !attempts;
  Alcotest.(check bool)
    "transport failed before any checkpoint stage"
    true
    (Driver.For_testing.same_run_retry_allowed checkpoint_stage_observed);
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

let test_cross_owner_fallback_returns_winning_runtime_authority () =
  with_runtime_config runtime_toml_checkpoint_lane (fun () ->
    let runtime runtime_id =
      match Runtime.get_runtime_by_id runtime_id with
      | Some runtime -> runtime
      | None -> Alcotest.failf "missing runtime %s" runtime_id
    in
    let primary = runtime "codex.codex" in
    let fallback = runtime "primary.test_model" in
    let result =
      Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"checkpoint_lane"
        ~runtime_id_of:(fun (runtime : Runtime.t) -> runtime.id)
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx ~runtime_id runtime ->
          if String.equal runtime_id primary.id
          then
            attempt_without_effect
              (Error (retryable_network_error "primary failed"))
              None
          else
            attempt_without_effect
              (Driver.For_testing.selected_runtime_result
                 runtime
                 ~lane_attempt_index:idx
                 (Ok (completed_run_result ())))
              None)
        [ primary; fallback ]
    in
    match result with
    | Error error ->
      Alcotest.failf
        "expected fallback success, got %s"
        (Agent_core.Error.to_string error)
    | Ok selected ->
      Alcotest.(check string)
        "selected runtime id"
        "primary.test_model"
        selected.Driver.selected_runtime_id;
      Alcotest.(check int)
        "selected context window"
        (Runtime.max_context_of_runtime fallback)
        selected.selected_max_context;
      Alcotest.(check int)
        "fallback candidate wins at lane index 1 (primary at 0 failed first)"
        1
        selected.lane_attempt_index;
      (match selected.checkpoint_owner with
       | Runtime_execution.Masc_agent_core -> ()
       | Runtime_execution.Official_client ->
         Alcotest.fail "fallback checkpoint owner must be AGENT_CORE"))

let test_first_candidate_success_keeps_lane_attempt_index_zero () =
  with_runtime_config runtime_toml_checkpoint_lane (fun () ->
    let primary = Runtime.get_runtime_by_id "codex.codex" in
    let primary =
      match primary with
      | Some runtime -> runtime
      | None -> Alcotest.fail "missing runtime codex.codex"
    in
    let result =
      Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"checkpoint_lane"
        ~runtime_id_of:(fun (runtime : Runtime.t) -> runtime.id)
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx ~runtime_id:_ runtime ->
          attempt_without_effect
            (Driver.For_testing.selected_runtime_result
               runtime
               ~lane_attempt_index:idx
               (Ok (completed_run_result ())))
            None)
        [ primary ]
    in
    match result with
    | Error error ->
      Alcotest.failf
        "expected first-candidate success, got %s"
        (Agent_core.Error.to_string error)
    | Ok selected ->
      Alcotest.(check int)
        "no rotation: lane_attempt_index stays 0"
        0
        selected.Driver.lane_attempt_index)

let test_attempt_loop_retries_provider_wire_failure_same_turn () =
  let attempts = ref [] in
  let deferred = ref 0 in
  let events = ref [] in
  let provider_wire_error =
    Agent_core.Error.Provider
      (Llm_provider.Error.ProviderWireError
         { provider = "test-provider"
         ; format = Llm_provider.Http_client.Sse
         ; kind = Llm_provider.Http_client.Malformed_payload
         ; detail = "malformed SSE payload"
         })
  in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~on_retry_deferred:(fun _ -> incr deferred)
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          attempt_without_effect (Error provider_wire_error) None
        | "fallback.test_model" -> attempt_without_effect (Ok runtime_id) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string)
       "malformed provider stream rotates within the same turn"
       "fallback.test_model"
       runtime_id
   | Error error ->
     Alcotest.failf
       "expected same-turn provider-wire fallback, got %s"
       (Agent_core.Error.to_string error));
  Alcotest.(check (list string))
    "provider-wire failure advances to the next lane candidate"
    [ "primary.test_model"; "fallback.test_model" ]
    !attempts;
  Alcotest.(check int)
    "provider-wire failure does not create a deferred whole-runtime retry"
    0
    !deferred;
  let events = List.rev !events in
  Alcotest.(check int) "both candidate attempts remain observable" 4 (List.length events)

let check_effect_disposition_blocks_same_turn_retry label effect_disposition =
  let attempts = ref [] in
  let deferred = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ -> true)
      ~on_retry_deferred:(fun hint -> deferred := hint :: !deferred)
      ~runtime_id:"primary.test_model"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          ( Error (retryable_network_error "primary failed after possible effect")
          , None
          , effect_disposition )
        | "fallback.test_model" ->
          Alcotest.failf "%s allowed duplicate-capable fallback" label
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Error error ->
     (match Driver.classify_masc_internal_error error with
      | Some
          (Driver.Provider_attempt_effect_fenced
             { runtime_id = "primary.test_model"
             ; effect_disposition = observed
             ; diagnostic
             }) ->
        Alcotest.(check bool)
          (label ^ " keeps the exact effect disposition")
          true
          (observed = effect_disposition);
        Alcotest.(check bool)
          (label ^ " keeps a diagnostic")
          true
          (String.length diagnostic > 0)
      | Some other ->
        Alcotest.failf
          "%s returned wrong typed failure %s"
          label
          (Driver.kind_of_masc_internal_error other)
      | None -> Alcotest.failf "%s dropped the typed effect fence" label)
   | Ok _ -> Alcotest.failf "%s unexpectedly succeeded" label);
  Alcotest.(check (list string))
    (label ^ " attempts only the effect owner")
    [ "primary.test_model" ]
    !attempts;
  Alcotest.(check int)
    (label ^ " does not defer the same unsafe suffix")
    0
    (List.length !deferred)

let test_attempt_loop_stops_after_effect_attempt () =
  check_effect_disposition_blocks_same_turn_retry
    "effect attempted"
    Masc.Keeper_provider_attempt_effect.Effect_attempted

let test_attempt_loop_fails_closed_without_effect_observation () =
  check_effect_disposition_blocks_same_turn_retry
    "effect observation unavailable"
    Masc.Keeper_provider_attempt_effect.Observation_unavailable

let test_effect_fence_outranks_an_earlier_overflow () =
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
        match candidate with
        | "small.test_model" ->
          attempt_without_effect
            (Error
               (Agent_core.Error.Api
                  (Agent_core.Retry.ContextOverflow
                     { message = "small context"; limit = Some 1024 })))
            None
        | "effect-owner.test_model" ->
          ( Error (retryable_network_error "failed after an effect")
          , None
          , Masc.Keeper_provider_attempt_effect.Effect_attempted )
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "small.test_model"; "effect-owner.test_model" ]
  in
  match result with
  | Error error ->
    (match Driver.classify_masc_internal_error error with
     | Some
         (Driver.Provider_attempt_effect_fenced
            { runtime_id = "effect-owner.test_model"
            ; effect_disposition =
                Masc.Keeper_provider_attempt_effect.Effect_attempted
            ; _
            }) ->
       ()
     | Some other ->
       Alcotest.failf
         "later effect fence was replaced by %s"
         (Driver.kind_of_masc_internal_error other)
     | None -> Alcotest.fail "later effect fence was replaced by the first overflow")
  | Ok _ -> Alcotest.fail "effect-fenced lane unexpectedly succeeded"

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
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          attempt_without_effect
            (Error primary_error)
            (Some checkpoint_after_primary)
        | "fallback.test_model" ->
          Alcotest.fail "no-progress retry gate should block fallback candidate"
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Error err ->
     Alcotest.(check string)
       "primary no-progress error preserved"
       (Agent_core.Error.to_string primary_error)
       (Agent_core.Error.to_string err)
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
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~allow_accept_no_progress_retry:(fun ~runtime_id:_ ~attempt:_ _ ->
        gate_called := true;
        false)
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "primary.test_model" ->
          attempt_without_effect
            (Error (retryable_network_error "primary network failed"))
            None
        | "fallback.test_model" -> attempt_without_effect (Ok runtime_id) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "fallback selected" "fallback.test_model" runtime_id
   | Error e ->
     Alcotest.failf
       "expected fallback success, got %s"
       (Agent_core.Error.to_string e));
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

let test_attempt_loop_reorders_shared_quota_sibling_same_turn () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect
      ~finally:Runtime_quota_window.reset_for_testing
      (fun () ->
         let attempts = ref [] in
         let result =
           Driver.For_testing.attempt_runtime_candidates
             ~runtime_id:"quota_lane"
             ~runtime_id_of:Fun.id
             ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
             ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
               attempts := !attempts @ [ runtime_id ];
               match runtime_id with
               | "shared_a.test_model" ->
                 attempt_without_effect
                   (Error
                      (Agent_core.Error.Provider
                         (Llm_provider.Error.HardQuota
                            { provider = "shared_a"
                            ; retry_after = Some 300.0
                            ; detail = "account quota exhausted"
                            })))
                   None
               | "other.test_model" -> attempt_without_effect (Ok runtime_id) None
               | "shared_b.test_model" ->
                 Alcotest.fail
                   "same-credential sibling must move behind the unrelated account"
               | other -> Alcotest.failf "unexpected candidate %s" other)
             [ "shared_a.test_model"; "shared_b.test_model"; "other.test_model" ]
         in
         (match result with
          | Ok runtime_id ->
            Alcotest.(check string)
              "unrelated account serves the turn"
              "other.test_model"
              runtime_id
          | Error error ->
            Alcotest.failf
              "expected unrelated fallback success: %s"
              (Agent_core.Error.to_string error));
         Alcotest.(check (list string))
           "new quota window reorders the remaining walk immediately"
           [ "shared_a.test_model"; "other.test_model" ]
           !attempts))

let test_attempt_quota_scope_survives_runtime_reload () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect
      ~finally:Runtime_quota_window.reset_for_testing
      (fun () ->
         let attempted_runtime =
           Option.get (Runtime.get_runtime_by_id "shared_a.test_model")
         in
         let attempted_scope = Runtime.quota_scope_of_runtime attempted_runtime in
         let result =
           Driver.For_testing.attempt_runtime_candidates
             ~runtime_id:"quota_lane"
             ~runtime_id_of:(fun (runtime : Runtime.t) -> runtime.id)
             ~quota_scope_of:(fun runtime ->
               Some (Runtime.quota_scope_of_runtime runtime))
             ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
             ~run_attempt:(fun ~idx:_ ~runtime_id:_ _candidate ->
               reload_runtime_config
                 (runtime_toml_quota_lane_with_shared_credential
                    "REBOUND_QUOTA_TEST_KEY");
               attempt_without_effect
                 (Error
                    (Agent_core.Error.Provider
                       (Llm_provider.Error.HardQuota
                          { provider = "shared_a"
                          ; retry_after = Some 300.0
                          ; detail = "old account quota exhausted"
                          })))
                 None)
             [ attempted_runtime ]
         in
         (match result with
          | Error (Agent_core.Error.Provider (Llm_provider.Error.HardQuota _)) -> ()
          | Error error ->
            Alcotest.failf
              "expected hard-quota result, got %s"
              (Agent_core.Error.to_string error)
          | Ok _ -> Alcotest.fail "hard-quota attempt unexpectedly succeeded");
         let rebound_scope =
           Option.get (Runtime.quota_scope_of_runtime_id "shared_a.test_model")
         in
         let now = Unix.gettimeofday () in
         Alcotest.(check bool)
           "response remains attributed to attempted credential"
           true
           (Option.is_some
              (Runtime_quota_window.active_until ~scope:attempted_scope ~now));
         Alcotest.(check (option (float 0.0)))
           "replacement credential is not charged for old response"
           None
           (Runtime_quota_window.active_until ~scope:rebound_scope ~now)))

let test_deferred_quota_order_is_frozen_before_predispatch () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect
      ~finally:Runtime_quota_window.reset_for_testing
      (fun () ->
         let shared_scope =
           Option.get (Runtime.quota_scope_of_runtime_id "shared_a.test_model")
         in
         Runtime_quota_window.note_exhausted
           ~scope:shared_scope
           ~resets_at:500.0;
         let hint =
           Driver.For_testing.make_deferred_runtime_lane
             ~assignment_id:"quota_lane"
             ~failed_runtime_id:"previous.test_model"
             ~next_runtime_id:"shared_a.test_model"
             ~later_runtime_ids:
               [ "shared_b.test_model"; "other.test_model" ]
             ~failure:(retryable_network_error "previous cycle failed")
         in
         let ordered =
           Driver.quota_ordered_deferred_runtime_lane ~now:100.0 hint
         in
         Alcotest.(check (list string))
           "pre-dispatch and driver share the same reordered suffix"
           [ "other.test_model"
           ; "shared_a.test_model"
           ; "shared_b.test_model"
           ]
           (Driver.deferred_runtime_ids ordered)))

let test_deferred_dispatch_preserves_predispatch_quota_order () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect
      ~finally:Runtime_quota_window.reset_for_testing
      (fun () ->
         let hint =
           Driver.For_testing.make_deferred_runtime_lane
             ~assignment_id:"quota_lane"
             ~failed_runtime_id:"previous.test_model"
             ~next_runtime_id:"shared_a.test_model"
             ~later_runtime_ids:
               [ "shared_b.test_model"; "other.test_model" ]
             ~failure:(retryable_network_error "previous cycle failed")
         in
         let frozen =
           Driver.quota_ordered_deferred_runtime_lane
             ~now:(Unix.gettimeofday ())
             hint
         in
         let shared_scope =
           Option.get (Runtime.quota_scope_of_runtime_id "shared_a.test_model")
         in
         Runtime_quota_window.note_exhausted
           ~scope:shared_scope
           ~resets_at:(Unix.gettimeofday () +. 300.0);
         Eio_main.run
         @@ fun env ->
         Eio.Switch.run
         @@ fun sw ->
         Masc_test_deps.init_eio_clock ~sw env;
         let transformed_urls = ref [] in
         let result =
           Driver.run_named
             ~runtime_id:"quota_lane"
             ~keeper_name:"deferred-frozen-quota-order"
             ~base_path:(Filename.get_temp_dir_name ())
             ~agent_core_tools:[]
             ~goal:"preserve the pre-dispatch runtime binding"
             ~deferred_runtime_lane:frozen
             ~provider_config_transform:(fun provider_config ->
               transformed_urls := provider_config.base_url :: !transformed_urls;
               Error
                 (Agent_core.Error.Config
                    (Agent_core.Error.InvalidConfig
                       { field = "provider-config-transform"
                       ; detail = "stop after observing the selected runtime"
                       })))
             ~sw
             ~net:env#net
             ()
         in
         (match result with
          | Error error when !transformed_urls = [] ->
            Alcotest.failf
              "dispatch did not reach the selected runtime: %s"
              (Agent_core.Error.to_string error)
          | Error _ -> ()
          | Ok _ -> Alcotest.fail "test provider transform unexpectedly succeeded");
         Alcotest.(check (list string))
           "dispatch keeps the runtime frozen before pre-dispatch"
           [ "http://127.0.0.1:1" ]
           (List.rev !transformed_urls)))

let test_official_client_does_not_inherit_registry_api_key_scope () =
  with_runtime_config runtime_toml_official_provider_named_like_registry (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect
      ~finally:Runtime_quota_window.reset_for_testing
      (fun () ->
         let official_scope =
           Option.get (Runtime.quota_scope_of_runtime_id "openai.official_model")
         in
         let registry_api_key_scope =
           Runtime_quota_window.scope_of_credential
             ~provider_id:"openai"
             (Some (Runtime_schema.Env "OPENAI_API_KEY"))
         in
         Runtime_quota_window.note_exhausted
           ~scope:official_scope
           ~resets_at:500.0;
         Alcotest.(check (option (float 0.0)))
           "subscription quota does not demote an API-key account"
           None
           (Runtime_quota_window.active_until
              ~scope:registry_api_key_scope
              ~now:100.0)))

let test_typed_checkpoint_is_the_same_run_retry_authority () =
  let stages =
    [ Agent_core.Agent.After_assistant_collected
    ; Agent_core.Agent.After_tool_results_appended
    ; Agent_core.Agent.After_context_injection
    ]
  in
  List.iter
    (fun stage ->
       let attempts = ref [] in
       let events = ref [] in
       let checkpoint_stage_observed = Atomic.make false in
       Driver.For_testing.observe_checkpoint_stage checkpoint_stage_observed stage;
       let primary_error = retryable_network_error "response-stage failure" in
       let result =
         Driver.For_testing.attempt_runtime_candidates
           ~runtime_id:"resilient"
           ~runtime_id_of:(fun runtime_id -> runtime_id)
           ~emit_runtime_manifest:(emit_manifest_collector events)
           ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _error ->
             Driver.For_testing.same_run_retry_allowed checkpoint_stage_observed)
           ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
             attempts := !attempts @ [ runtime_id ];
             match candidate with
             | "primary.test_model" ->
               attempt_without_effect (Error primary_error) None
             | "fallback.test_model" ->
               Alcotest.fail "checkpoint stage must block same-run fallback"
             | other -> Alcotest.failf "unexpected candidate %s" other)
           [ "primary.test_model"; "fallback.test_model" ]
       in
       (match result with
        | Error err ->
          Alcotest.(check string)
            "primary error preserved"
            (Agent_core.Error.to_string primary_error)
            (Agent_core.Error.to_string err)
        | Ok runtime_id ->
          Alcotest.failf "unexpected fallback success: %s" runtime_id);
       Alcotest.(check (list string))
         "only primary attempted after checkpoint stage"
         [ "primary.test_model" ]
         !attempts;
       Alcotest.(check int)
         "only routed and failed manifests emitted"
         2
         (List.length !events))
    stages

let test_attempt_loop_preserves_last_core_error () =
  let events = ref [] in
  let observed_errors = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~on_attempt_error:(fun ~runtime_id ~attempt error ->
        observed_errors := (runtime_id, attempt, error) :: !observed_errors)
      ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
        attempt_without_effect
          (Error (retryable_network_error (runtime_id ^ " failed")))
          None)
      [ "primary.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok _ -> Alcotest.fail "expected final candidate error"
   | Error (Agent_core.Error.Api (Agent_core.Retry.NetworkError { message; _ })) ->
     Alcotest.(check string)
       "last candidate error preserved"
       "fallback.test_model failed"
       message
   | Error e ->
     Alcotest.failf
       "expected final network error, got %s"
       (Agent_core.Error.to_string e));
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
  ;
  let observed_errors = List.rev !observed_errors in
  Alcotest.(check (list (pair string int)))
    "typed attempt observer sees every candidate without changing the terminal error"
    [ "primary.test_model", 0; "fallback.test_model", 1 ]
    (List.map (fun (runtime_id, attempt, _) -> runtime_id, attempt) observed_errors);
  Alcotest.(check bool)
    "attempt observer preserves typed retryability"
    true
    (List.exists
       (fun (_, _, error) -> Agent_core.Error.is_retryable error)
       observed_errors)

let context_overflow_error message =
  Agent_core.Error.Api
    (Agent_core.Retry.ContextOverflow { message; limit = Some 32768 })

let serving_constraint () =
  Llm_provider.Serving_constraint.make
    ~source_kind:Llm_provider.Serving_constraint.Probe
    ~source_ref:"probe://incident/2793"
    ~checked_at_unix_s:0
    ~confidence:Llm_provider.Serving_constraint.High
    ~expires_at_unix_s:200
    ~accepted_through:524298
    ~rejected_from:524299
    ()
  |> Result.get_ok

let input_capacity_error reason =
  Agent_core.Error.Api
    (Agent_core.Retry.InputCapacity
       { message = "typed input-capacity admission"
       ; constraint_ = serving_constraint ()
       ; reason
       })

let test_attempt_loop_input_capacity_does_not_advance_masc_lane () =
  let attempts = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "unmeasurable.test_model" ->
          attempt_without_effect
            (Error
               (input_capacity_error
                  (Agent_core.Retry.Token_measurement_unavailable
                     Llm_provider.Input_token_count.Anthropic_messages_count_tokens)))
            None
        | other ->
          Alcotest.failf
            "MASC advanced to candidate %s without an AGENT_CORE flow receipt"
            other)
      [ "unmeasurable.test_model"; "measurable.test_model" ]
  in
  (match result with
   | Error (Agent_core.Error.Api (Agent_core.Retry.InputCapacity _)) -> ()
   | Error error ->
     Alcotest.failf
       "typed input capacity was not preserved: %s"
       (Agent_core.Error.to_string error)
   | Ok _ -> Alcotest.fail "MASC must not advance an InputCapacity failure");
  Alcotest.(check (list string))
    "only AGENT_CORE may advance the candidate flow"
    [ "unmeasurable.test_model" ]
    !attempts

(* A typed ContextOverflow is a per-candidate capacity bound: a later lane
   candidate with a larger context window can still serve the same turn, so
   the walk must continue instead of treating the 400 mapping as terminal. *)
let test_attempt_loop_overflow_tries_next_candidate () =
  let attempts = ref [] in
  let events = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "small.test_model" ->
          attempt_without_effect
            (Error (context_overflow_error "prompt exceeds context window"))
            None
        | "large.test_model" -> attempt_without_effect (Ok runtime_id) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "small.test_model"; "large.test_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string)
       "larger-context candidate serves the turn"
       "large.test_model"
       runtime_id
   | Error e ->
     Alcotest.failf
       "expected larger-context fallback success, got %s"
       (Agent_core.Error.to_string e));
  Alcotest.(check (list string))
    "overflow continues the lane walk"
    [ "small.test_model"; "large.test_model" ]
    !attempts

(* When every candidate overflows, the last typed ContextOverflow must be
   preserved so the lane classifier
   ([Keeper_unified_turn_execution.declared_lane_failure_of_error]) still
   reports the capacity bound. *)
let test_attempt_loop_overflow_on_last_candidate_is_terminal () =
  let attempts = ref [] in
  let events = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
        attempts := !attempts @ [ runtime_id ];
        attempt_without_effect
          (Error (context_overflow_error (runtime_id ^ " overflow")))
          None)
      [ "small.test_model"; "smaller.test_model" ]
  in
  (match result with
   | Ok _ -> Alcotest.fail "expected terminal overflow"
   | Error err ->
     Alcotest.(check bool)
       "typed overflow preserved for reactive compaction"
       true
       (Masc.Keeper_error_classify.is_context_overflow err));
  Alcotest.(check (list string))
    "every candidate attempted before terminal overflow"
    [ "small.test_model"; "smaller.test_model" ]
    !attempts

(* #26530: an overflow on an earlier candidate must survive lane exhaustion.
   Live incident 2026-07-31: glm overflowed, the ollama fallback then failed
   with a rate limit, and the lane returned that rate limit — hiding the
   deterministic capacity bound from the failure route while every cycle
   replayed the same oversized checkpoint. *)
let test_attempt_loop_exhaustion_preserves_earlier_overflow () =
  let attempts = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "small.test_model" ->
          attempt_without_effect
            (Error (context_overflow_error "prompt exceeds context window"))
            None
        | "fallback.test_model" ->
          attempt_without_effect
            (Error
               (Agent_core.Error.Api
                  (Agent_core.Retry.RateLimited
                     { retry_after = None; message = "weekly usage limit" })))
            None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "small.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok _ -> Alcotest.fail "expected exhausted lane"
   | Error err ->
     Alcotest.(check bool)
       "typed overflow outranks the fallback rate limit"
       true
       (Masc.Keeper_error_classify.is_context_overflow err));
  Alcotest.(check (list string))
    "both candidates attempted"
    [ "small.test_model"; "fallback.test_model" ]
    !attempts

(* Overflow precedence applies only to an exhausted lane: a walk stopped
   mid-lane by a non-retryable error keeps that stopping error, which is the
   immediate operator signal. *)
let test_attempt_loop_midwalk_terminal_outranks_observed_overflow () =
  let attempts = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "small.test_model" ->
          attempt_without_effect
            (Error (context_overflow_error "prompt exceeds context window"))
            None
        | "broken.test_model" ->
          attempt_without_effect
            (Error (Agent_core.Error.Internal "hard mid-lane failure"))
            None
        | other ->
          Alcotest.failf "walk must stop before candidate %s" other)
      [ "small.test_model"; "broken.test_model"; "fallback.test_model" ]
  in
  (match result with
   | Ok _ -> Alcotest.fail "expected mid-lane stop"
   | Error (Agent_core.Error.Internal msg) ->
     Alcotest.(check string)
       "stopping error preserved"
       "hard mid-lane failure"
       msg
   | Error e ->
     Alcotest.failf
       "expected stopping Internal error, got %s"
       (Agent_core.Error.to_string e));
  Alcotest.(check (list string))
    "walk stopped at the terminal candidate"
    [ "small.test_model"; "broken.test_model" ]
    !attempts

let test_checkpoint_denial_defers_exact_frozen_suffix_once () =
  let attempts = ref [] in
  let deferred = ref [] in
  let err =
    Agent_core.Error.Api
      (Agent_core.Retry.ServerError
         { status = 500; message = "checkpoint-observed failure" })
  in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ -> false)
      ~on_retry_deferred:(fun hint -> deferred := hint :: !deferred)
      ~runtime_id:"lane.frozen"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
        attempts := runtime_id :: !attempts;
        attempt_without_effect (Error err) None)
      [ "runtime.a"; "runtime.b"; "runtime.c"; "runtime.d" ]
  in
  (match result with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "checkpoint denial must end the current run");
  Alcotest.(check (list string))
    "no same-run second POST"
    [ "runtime.a" ]
    (List.rev !attempts);
  match List.rev !deferred with
  | [ hint ] ->
    Alcotest.(check string)
      "failed runtime"
      "runtime.a"
      hint.Driver.failed_runtime_id;
    Alcotest.(check (list string))
      "frozen suffix preserved"
      [ "runtime.b"; "runtime.c"; "runtime.d" ]
      (Driver.deferred_runtime_ids hint)
  | hints ->
    Alcotest.failf "expected one deferred suffix, got %d" (List.length hints)

let test_deferred_cycle_starts_at_supplied_successor_and_keeps_tail () =
  let attempts = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"runtime.b"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
        attempts := runtime_id :: !attempts;
        match runtime_id with
        | "runtime.b" ->
          attempt_without_effect (Error (retryable_network_error "b failed")) None
        | "runtime.c" -> attempt_without_effect (Ok runtime_id) None
        | "runtime.a" ->
          Alcotest.fail "failed lane prefix must not replay on the next cycle"
        | other -> Alcotest.failf "unexpected runtime %s" other)
      [ "runtime.b"; "runtime.c"; "runtime.d" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "same-run tail succeeds" "runtime.c" runtime_id
   | Error error ->
     Alcotest.failf "expected suffix success: %s" (Agent_core.Error.to_string error));
  Alcotest.(check (list string))
    "next cycle starts at B then advances to C"
    [ "runtime.b"; "runtime.c" ]
    (List.rev !attempts)

let test_deferred_cycle_post_checkpoint_replaces_hint_with_tail () =
  let deferred = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ -> false)
      ~on_retry_deferred:(fun hint -> deferred := hint :: !deferred)
      ~runtime_id:"runtime.b"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
        Alcotest.(check string) "only B attempted" "runtime.b" runtime_id;
        attempt_without_effect
          (Error (retryable_network_error "b checkpoint failure"))
          None)
      [ "runtime.b"; "runtime.c"; "runtime.d" ]
  in
  (match result with Error _ -> () | Ok _ -> Alcotest.fail "expected B failure");
  match List.rev !deferred with
  | [ hint ] ->
    Alcotest.(check (list string))
      "replacement hint is C,D"
      [ "runtime.c"; "runtime.d" ]
      (Driver.deferred_runtime_ids hint)
  | hints ->
    Alcotest.failf "expected one replacement hint, got %d" (List.length hints)

let test_single_candidate_checkpoint_failure_has_no_hint () =
  let deferred = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ -> false)
      ~on_retry_deferred:(fun hint -> deferred := hint :: !deferred)
      ~runtime_id:"runtime.only"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ _candidate ->
        attempt_without_effect
          (Error (retryable_network_error "only failed"))
          None)
      [ "runtime.only" ]
  in
  (match result with Error _ -> () | Ok _ -> Alcotest.fail "expected failure");
  Alcotest.(check int) "no successor means no hint" 0 (List.length !deferred)

let test_deferred_hint_refs_are_not_shared () =
  let failure = retryable_network_error "checkpoint failure" in
  let hint =
    Driver.For_testing.make_deferred_runtime_lane
      ~assignment_id:"lane.one"
      ~failed_runtime_id:"runtime.a"
      ~next_runtime_id:"runtime.b"
      ~later_runtime_ids:[ "runtime.c" ]
      ~failure
  in
  let first = ref (Some hint) in
  let second = ref (Some hint) in
  Alcotest.(check bool)
    "first owner consumes its hint"
    true
    (Masc.Keeper_heartbeat_loop.For_testing.consume_deferred_runtime_lane_hint
       first
       hint);
  Alcotest.(check bool) "first hint cleared" true (Option.is_none !first);
  Alcotest.(check bool)
    "second owner remains independent"
    true
    (Option.is_some !second)

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path
    |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error _ -> ()
;;

let with_deferred_store f =
  let base_path = Filename.temp_dir "masc-deferred-runtime-" "" in
  Fun.protect ~finally:(fun () -> remove_tree base_path) (fun () -> f base_path)
;;

let test_deferred_hint_survives_store_restart_and_clears_after_settlement () =
  with_deferred_store (fun base_path ->
    let original =
      Driver.For_testing.make_deferred_runtime_lane
        ~assignment_id:"lane.restart"
        ~failed_runtime_id:"runtime.a"
        ~next_runtime_id:"runtime.b"
        ~later_runtime_ids:[ "runtime.c" ]
        ~failure:(accept_empty_no_progress_error "runtime.a")
    in
    (match Deferred_store.save ~base_path ~keeper_name:"backend" original with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf "save failed: %s" (Deferred_store.error_to_string error));
    let restored =
      match Deferred_store.load ~base_path ~keeper_name:"backend" with
      | Ok (Some hint) -> hint
      | Ok None -> Alcotest.fail "restart lost the durable deferred suffix"
      | Error error ->
        Alcotest.failf "load failed: %s" (Deferred_store.error_to_string error)
    in
    Alcotest.(check (list string))
      "restart starts from frozen successor"
      [ "runtime.b"; "runtime.c" ]
      (Driver.deferred_runtime_ids restored);
    Alcotest.(check bool)
      "typed accept rejection survives durable codec"
      true
      (match Driver.classify_masc_internal_error restored.failure with
       | Some (Driver.Accept_rejected { reason_kind; _ }) ->
         reason_kind = Some Driver.Accept_no_usable_progress
       | _ -> false);
    (match Deferred_store.clear ~base_path ~keeper_name:"backend" with
     | Ok () -> ()
     | Error error ->
       Alcotest.failf "clear failed: %s" (Deferred_store.error_to_string error));
    match Deferred_store.load ~base_path ~keeper_name:"backend" with
    | Ok None -> ()
    | Ok (Some _) -> Alcotest.fail "settled suffix remained replayable"
    | Error error ->
      Alcotest.failf "post-clear load failed: %s" (Deferred_store.error_to_string error))
;;

let test_deferred_store_rejects_unknown_schema_without_fallback () =
  with_deferred_store (fun base_path ->
    let path = Deferred_store.path_for ~base_path ~keeper_name:"backend" in
    let dir = Filename.dirname path in
    Fs_compat.mkdir_p dir;
    write_file path {|{"schema":"keeper.deferred_runtime_lane.v0"}|};
    match Deferred_store.load ~base_path ~keeper_name:"backend" with
    | Error (Deferred_store.Malformed _) -> ()
    | Error error ->
      Alcotest.failf
        "expected malformed current-only schema, got %s"
        (Deferred_store.error_to_string error)
    | Ok _ -> Alcotest.fail "unknown schema must not fall back to a fresh lane")
;;

let test_missing_deferred_successor_is_typed_error () =
  match
    Driver.For_testing.resolve_runtime_candidates
      [ "runtime.definitely-missing-deferred-successor" ]
  with
  | Error (Agent_core.Error.Internal detail) ->
    Alcotest.(check bool)
      "missing successor is loud"
      true
      (String.length (String.trim detail) > 0)
  | Error error ->
    Alcotest.failf
      "expected typed internal missing-successor error, got %s"
      (Agent_core.Error.to_string error)
  | Ok _ -> Alcotest.fail "missing successor unexpectedly resolved"

let test_missing_deferred_head_is_consumed_once () =
  let consumed = ref 0 in
  let result =
    Driver.For_testing.resolve_runtime_candidate_for_attempt
      ~on_missing:(fun () -> incr consumed)
      "runtime.definitely-missing-deferred-head"
  in
  (match result with
   | Error (Agent_core.Error.Internal _) -> ()
   | Error error ->
     Alcotest.failf
       "expected typed missing-head error, got %s"
       (Agent_core.Error.to_string error)
   | Ok _ -> Alcotest.fail "missing deferred head unexpectedly resolved");
  Alcotest.(check int) "missing head consumed once" 1 !consumed

let test_initial_lane_exhaustion_cannot_escape_declared_candidates () =
  match
    Masc.Keeper_unified_turn_execution.For_testing
      .declared_lane_failure_of_error
      (retryable_network_error "declared lane exhausted")
  with
  | Masc.Keeper_unified_turn_execution.For_testing
      .Declared_runtime_lane_exhausted ->
    ()
  | Masc.Keeper_unified_turn_execution.For_testing
      .Provider_context_overflow _ ->
    Alcotest.fail "network exhaustion must not enter an outer catalog fallback"

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
            "a bare runtime assignment gets a lane with somewhere to go"
            `Quick
            test_bare_runtime_assignment_gets_a_lane_with_somewhere_to_go;
          Alcotest.test_case
            "a lane already naming the default is unchanged"
            `Quick
            test_lane_already_naming_the_default_is_unchanged;
          Alcotest.test_case
            "resolve_assignment reports missing id"
            `Quick
            test_resolve_assignment_missing;
          Alcotest.test_case
            "unknown lane candidate rejected at load"
            `Quick
            test_unknown_lane_candidate_rejected_at_load;
          Alcotest.test_case
            "assignment to lane id rejected at load"
            `Quick
            test_assignment_to_lane_id_rejected_at_load;
          Alcotest.test_case
            "lane media degrade uses first candidate runtime id"
            `Quick
            test_lane_media_degrade_uses_first_candidate_runtime_id;
          Alcotest.test_case
            "run_named media degrade emits typed manifest"
            `Quick
            test_run_named_media_degrade_emits_typed_manifest;
          Alcotest.test_case
            "AGENT_CORE checkpoint preserves official-client history"
            `Quick
            test_agent_core_checkpoint_preserves_official_client_history;
          Alcotest.test_case
            "text official-client history stays admissible"
            `Quick
            test_text_official_client_history_stays_admissible;
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
            "prior checkpoint appends current goal once"
            `Quick
            test_prior_checkpoint_appends_current_goal_once;
          Alcotest.test_case
            "deferred tail rejects transformed uncapped runtime"
            `Quick
            test_deferred_tail_rejects_transformed_uncapped_runtime;
          Alcotest.test_case
            "attempt loop stops on nonretryable failure"
            `Quick
            test_attempt_loop_stops_on_nonretryable_failure;
          Alcotest.test_case
            "failed lane receipt counts missing tail"
            `Quick
            test_failed_lane_receipt_counts_missing_tail;
          Alcotest.test_case
            "transport failure before checkpoint safely falls back"
            `Quick
            test_attempt_loop_retries_transport_failure_before_checkpoint;
          Alcotest.test_case
            "cross-owner fallback returns winning runtime authority"
            `Quick
            test_cross_owner_fallback_returns_winning_runtime_authority;
          Alcotest.test_case
            "first-candidate success keeps lane_attempt_index at 0"
            `Quick
            test_first_candidate_success_keeps_lane_attempt_index_zero;
          Alcotest.test_case
            "provider-wire failure rotates in the same turn"
            `Quick
            test_attempt_loop_retries_provider_wire_failure_same_turn;
          Alcotest.test_case
            "effect attempt blocks same-turn fallback"
            `Quick
            test_attempt_loop_stops_after_effect_attempt;
          Alcotest.test_case
            "missing effect observation fails closed"
            `Quick
            test_attempt_loop_fails_closed_without_effect_observation;
          Alcotest.test_case
            "effect fence outranks an earlier overflow"
            `Quick
            test_effect_fence_outranks_an_earlier_overflow;
          Alcotest.test_case
            "attempt loop blocks no-progress when gate denies"
            `Quick
            test_attempt_loop_blocks_no_progress_when_gate_denies;
          Alcotest.test_case
            "attempt loop does not gate network retry"
            `Quick
            test_attempt_loop_does_not_gate_network_retry;
          Alcotest.test_case
            "hard quota reorders shared sibling in same turn"
            `Quick
            test_attempt_loop_reorders_shared_quota_sibling_same_turn;
          Alcotest.test_case
            "hard quota keeps attempted scope across runtime reload"
            `Quick
            test_attempt_quota_scope_survives_runtime_reload;
          Alcotest.test_case
            "deferred quota order is frozen before pre-dispatch"
            `Quick
            test_deferred_quota_order_is_frozen_before_predispatch;
          Alcotest.test_case
            "deferred dispatch preserves pre-dispatch quota order"
            `Quick
            test_deferred_dispatch_preserves_predispatch_quota_order;
          Alcotest.test_case
            "official client quota excludes registry API-key scope"
            `Quick
            test_official_client_does_not_inherit_registry_api_key_scope;
          Alcotest.test_case
            "typed checkpoint is same-run retry authority"
            `Quick
            test_typed_checkpoint_is_the_same_run_retry_authority;
          Alcotest.test_case
            "attempt loop preserves last Agent Core error"
            `Quick
            test_attempt_loop_preserves_last_core_error;
          Alcotest.test_case
            "context overflow tries next lane candidate"
            `Quick
            test_attempt_loop_overflow_tries_next_candidate;
          Alcotest.test_case
            "input capacity does not advance MASC lane"
            `Quick
            test_attempt_loop_input_capacity_does_not_advance_masc_lane;
          Alcotest.test_case
            "context overflow on last candidate stays terminal"
            `Quick
            test_attempt_loop_overflow_on_last_candidate_is_terminal;
          Alcotest.test_case
            "lane exhaustion preserves earlier overflow"
            `Quick
            test_attempt_loop_exhaustion_preserves_earlier_overflow;
          Alcotest.test_case
            "mid-lane terminal outranks observed overflow"
            `Quick
            test_attempt_loop_midwalk_terminal_outranks_observed_overflow;
          Alcotest.test_case
            "checkpoint denial defers exact frozen suffix once"
            `Quick
            test_checkpoint_denial_defers_exact_frozen_suffix_once;
          Alcotest.test_case
            "deferred cycle starts at supplied successor and keeps tail"
            `Quick
            test_deferred_cycle_starts_at_supplied_successor_and_keeps_tail;
          Alcotest.test_case
            "deferred post-checkpoint failure replaces hint with tail"
            `Quick
            test_deferred_cycle_post_checkpoint_replaces_hint_with_tail;
          Alcotest.test_case
            "single candidate checkpoint failure has no hint"
            `Quick
            test_single_candidate_checkpoint_failure_has_no_hint;
          Alcotest.test_case
            "deferred hint refs are not shared"
            `Quick
            test_deferred_hint_refs_are_not_shared;
          Alcotest.test_case
            "deferred hint survives restart and settles durably"
            `Quick
            test_deferred_hint_survives_store_restart_and_clears_after_settlement;
          Alcotest.test_case
            "deferred store rejects unknown schema"
            `Quick
            test_deferred_store_rejects_unknown_schema_without_fallback;
          Alcotest.test_case
            "missing deferred successor is typed error"
            `Quick
            test_missing_deferred_successor_is_typed_error;
          Alcotest.test_case
            "missing deferred head is consumed once"
            `Quick
            test_missing_deferred_head_is_consumed_once;
          Alcotest.test_case
            "initial lane exhaustion cannot escape declared candidates"
            `Quick
            test_initial_lane_exhaustion_cannot_escape_declared_candidates;
        ] );
    ]
