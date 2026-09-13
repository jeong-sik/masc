
(* These tests assert on the operator-facing wording, so the typed failure is
   rendered once here instead of at every call below. *)
let load_list_text ~config_path =
  Runtime.load_list ~config_path
  |> Result.map_error (Runtime.to_diagnostic_text ~config_path)
;;

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
  ; cooperative_boundary = None
  ; stop_reason = Runtime_agent.Completed
  }

let message ?(role = Agent_core.Types.Assistant) content : Agent_core.Types.message =
  { role; content; name = None; tool_call_id = None; metadata = [] }

let retryable_network_error message =
  Agent_core.Error.Api
    (Agent_core.Retry.NetworkError
       { message; kind = Llm_provider.Http_client.Unknown })

let dispatch_disposition : Masc.Keeper_attempt_dispatch.t Alcotest.testable =
  Alcotest.testable
    (fun fmt d -> Format.pp_print_string fmt (Masc.Keeper_attempt_dispatch.to_string d))
    ( = )

let attempt_without_effect result checkpoint =
  ( result
  , checkpoint
  , Masc.Keeper_provider_attempt_effect.No_effect_observed
  , Masc.Keeper_attempt_dispatch.Dispatched )
;;

(* A candidate the walk refuses before invoking anything: its error is the
   walk's own verdict, not the candidate's answer. *)
let attempt_rejected_before_dispatch error =
  ( Error error
  , None
  , Masc.Keeper_provider_attempt_effect.No_effect_observed
  , Masc.Keeper_attempt_dispatch.Rejected_before_dispatch )
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
    | `Missing | `Unavailable _ -> Alcotest.fail "expected assignment to resolve"
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
    | `Missing | `Unavailable _ -> Alcotest.fail "expected runtime to resolve"
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
    | `Missing | `Unavailable _ -> Alcotest.fail "expected lane to resolve"
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
    | `Lane _ | `Unavailable _ -> Alcotest.fail "expected missing assignment")

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
       match load_list_text ~config_path:path with
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
       match load_list_text ~config_path:path with
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
         ~system_prompt:"You are the runtime failover test Keeper."
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

let test_deferred_tail_rejects_transformed_invalid_request_cap () =
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
        ~system_prompt:"You are the runtime failover test Keeper."
        ~runtime_id:"resilient"
        ~keeper_name:"deferred-request-cap"
        ~base_path:(Filename.get_temp_dir_name ())
        ~agent_core_tools:[]
        ~goal:"prove final provider request admission"
        ~deferred_runtime_lane
        ~provider_config_transform:(fun provider_config ->
          transformed_urls := provider_config.base_url :: !transformed_urls;
          if String.equal provider_config.base_url "http://127.0.0.1:2"
          then Ok { provider_config with max_request_body_bytes = Some 0 }
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
         "transformed invalid-cap deferred runtime reached provider execution");
    Alcotest.(check (list string))
      "capped next candidate runs, then transformed tail is checked"
      [ "http://127.0.0.1:1"; "http://127.0.0.1:2" ]
      (List.rev !transformed_urls))

let test_lane_media_degrade_uses_first_candidate_runtime_id () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing | `Unavailable _ ->
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
      (* The whole lane, head included, so the assigned runtime is offered back to
         the decision as a candidate. It still must not be picked: a reroute to
         the runtime being rerouted away from is not an outcome the decision can
         produce. *)
      let remaining_runtimes =
        List.map
          (fun runtime_id ->
             match Runtime.get_runtime_by_id runtime_id with
             | Some runtime -> runtime
             | None -> Alcotest.failf "missing lane candidate %s" runtime_id)
          (Runtime_lane.ordered_candidates lane)
      in
      let image_block =
        Agent_core.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string "image"
          ; source_type = Agent_core.Types.Base64
          }
      in
      (* The decision is produced, not hand-built: [reroute_decision] is private,
         so a degrade floor value can only come from the decision function. No
         candidate in this lane takes images, so that is what it returns. *)
      let decision_for_image =
        Driver.For_testing.lane_modality_reroute_decision
          ~checkpoint_messages:[]
          ~initial_messages:[]
          ~goal_blocks:[ image_block ]
          ~first_candidate
          ~candidates:remaining_runtimes
      in
      (match decision_for_image with
       | Runtime_agent.No_capable_runtime { required } ->
         Alcotest.(check (list string))
           "degrade floor names the required modality"
           [ "image" ]
           required
       | Runtime_agent.No_reroute_needed ->
         Alcotest.fail "text-only lane should not admit an image turn"
       | Runtime_agent.Reroute { target; _ } ->
         Alcotest.failf "text-only lane rerouted to %s" target.Runtime.id);
      let selected_runtime_id, selected_runtime =
        Driver.For_testing.first_runtime_after_modality_reroute
          ~keeper_name:"test-keeper" ~assignment_id:"resilient"
          ~first_candidate_id ~first_candidate decision_for_image
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
    let audio =
      Agent_core.Types.audio_block
        ~media_type:"audio/wav"
        ~data:(Base64.encode_string "synthetic-audio")
        ()
    in
    ignore
      (Driver.run_named
         ~system_prompt:"You are the runtime failover test Keeper."
         ~runtime_id:"resilient"
         ~keeper_name:"media-degrade-keeper"
         ~base_path:(Filename.get_temp_dir_name ())
         ~agent_core_tools:[]
         ~goal:"inspect the audio"
         ~goal_blocks:[ audio ]
         ~runtime_manifest_context:context
         ~runtime_manifest_append:(fun manifest -> manifests := manifest :: !manifests)
         ~body_timeout_s:0.5
         ~sw
         ~net:env#net
         ()
       : (Driver.named_run_result, Agent_core.Error.t) result);
    let degraded =
      (* Manifest rows arrive newest-first here; [List.rev] puts them back in
         emission order so the walk takes the first row the run emitted, not
         the last. #33165 decides the degrade per lane candidate, so a turn
         that degrades on the head and falls through to the next candidate
         emits one degraded row per attempt, and the operator-facing account
         starts where the turn actually started. *)
      List.find_opt
        (fun (manifest : Runtime_manifest.t) ->
           manifest.event = Runtime_manifest.Runtime_routed
           && String.equal manifest.status "degraded")
        (List.rev !manifests)
    in
    match degraded with
    | None -> Alcotest.fail "run_named omitted the media degradation manifest"
    | Some manifest ->
      (* #33165 decides the degrade per lane candidate, so this turn degrades
         on both candidates: the head run first, then the fallback. Assert the
         full row set rather than the head alone, so this test cannot pass by
         accidentally reading whichever row happens to sit at the head of the
         collected list. *)
      let degraded_rows =
        List.rev
          (List.filter
             (fun (row : Runtime_manifest.t) ->
                row.event = Runtime_manifest.Runtime_routed
                && String.equal row.status "degraded")
             !manifests)
      in
      Alcotest.(check int)
        "degraded rows: one per lane candidate" 2
        (List.length degraded_rows);
      Alcotest.(check string)
        "first degraded row names the head runtime"
        "primary.test_model"
        (string_member "degraded_runtime_id"
           (Runtime_manifest.public_projection_of_decision
              (List.nth degraded_rows 0).decision));
      Alcotest.(check string)
        "second degraded row names the fallback runtime"
        "fallback.test_model"
        (string_member "degraded_runtime_id"
           (Runtime_manifest.public_projection_of_decision
              (List.nth degraded_rows 1).decision));
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

let image_count_in_blocks blocks =
  List.length
    (List.filter
       (function
         | Agent_core.Types.Image _ -> true
         | _ -> false)
       blocks)

let image_count_in_messages (messages : Agent_core.Types.message list) =
  List.fold_left
    (fun count (entry : Agent_core.Types.message) ->
       count + image_count_in_blocks entry.content)
    0
    messages

let synthetic_image () =
  Agent_core.Types.image_block
    ~media_type:"image/png"
    ~source_type:Agent_core.Types.Url
    ~data:"https://example.invalid/screenshot.png"
    ()

(* Per-attempt image projection: one image turn projected for the text-only
   candidate retains image references in the goal and the history and records
   delegation against that runtime; projected for the vision candidate it is
   untouched and records nothing. The view is a property of the runtime being
   dispatched, not of the lane head. *)
let test_attempt_input_is_projected_per_runtime () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    let runtime id =
      match Runtime.get_runtime_by_id id with
      | Some runtime -> runtime
      | None -> Alcotest.failf "missing runtime %s" id
    in
    let image = synthetic_image () in
    let history =
      [ message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "earlier image turn"; image ]
      ]
    in
    let project_images =
      Masc.Keeper_vision_ingest.fallback_projector
        ~keeper_name:"per-attempt-projection" ()
    in
    let project runtime_id =
      let events = ref [] in
      let projected =
        Driver.For_testing.project_input_for_attempt
          ~project_images
          ~keeper_name:"per-attempt-projection"
          ~emit_runtime_manifest:(emit_manifest_collector events)
          ~goal_blocks:(Some [ Agent_core.Types.Text "describe"; image ])
          ~initial_messages:history
          ~agent_core_checkpoint:None
          ~runtime_id
          (runtime runtime_id)
      in
      projected, List.rev !events
    in
    let text_view, text_events = project "primary.text_model" in
    (match text_view.Driver.attempt_goal_blocks with
     | None -> Alcotest.fail "the degraded goal must stay present"
     | Some blocks ->
       Alcotest.(check int)
         "text-only goal loses the image"
         0
         (image_count_in_blocks blocks);
       Alcotest.(check bool)
         "the unread URL remains in the provider input"
         true
         (List.exists
            (function
              | Agent_core.Types.Text text ->
                contains ~needle:"https://example.invalid/screenshot.png" text
              | _ -> false)
            blocks);
       Alcotest.(check int)
         "text-only goal retains the image reference alongside the text"
         2
         (List.length blocks));
    Alcotest.(check int)
      "text-only history loses the image"
      0
      (image_count_in_messages text_view.Driver.attempt_initial_messages);
    (match text_events with
     | [ (Runtime_manifest.Runtime_routed, Some "delegated", Some decision) ] ->
       Alcotest.(check string)
         "the delegation names the text-only runtime"
         "primary.text_model"
         (string_member "runtime_id" decision)
     | events ->
       Alcotest.failf "expected one delegated row, got %d" (List.length events));
    let vision_view, vision_events = project "lanevision.vision_model" in
    (match vision_view.Driver.attempt_goal_blocks with
     | None -> Alcotest.fail "the vision goal must stay present"
     | Some blocks ->
       Alcotest.(check int)
         "vision goal keeps the image"
         1
         (image_count_in_blocks blocks);
       Alcotest.(check int) "vision goal is untouched" 2 (List.length blocks));
    Alcotest.(check int)
      "vision history keeps the image"
      1
      (image_count_in_messages vision_view.Driver.attempt_initial_messages);
    Alcotest.(check int)
      "the vision projection records nothing"
      0
      (List.length vision_events))

let test_image_fallback_checkpoint_keeps_canonical_prefix () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    let runtime id =
      match Runtime.get_runtime_by_id id with
      | Some value -> value
      | None -> Alcotest.failf "missing runtime %s" id
    in
    let image = synthetic_image () in
    let nested =
      Agent_core.Types.ToolResult
        { tool_use_id = "screenshot"; content = "captured screenshot"
        ; outcome = Agent_core.Types.Tool_succeeded; json = None
        ; content_blocks = Some [ image ] }
    in
    let history = [ message [ nested ] ] in
    let checkpoint =
      { (checkpoint_with_session_id "image-fallback") with messages = history }
    in
    let project_images =
      Masc.Keeper_vision_ingest.fallback_projector ~keeper_name:"image-checkpoint" ()
    in
    let project ?(goal_blocks = Some [ image ]) runtime_id =
      Driver.For_testing.project_input_for_attempt
        ~project_images ~keeper_name:"image-checkpoint"
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~goal_blocks ~initial_messages:history
        ~agent_core_checkpoint:(Some checkpoint) ~runtime_id (runtime runtime_id)
    in
    let history_only = project ~goal_blocks:None "primary.text_model" in
    Alcotest.(check bool) "history projection preserves the separate plain goal"
      true (history_only.Driver.attempt_goal_blocks = None);
    let text = project "primary.text_model" in
    let dispatch_checkpoint =
      match text.Driver.attempt_agent_core_checkpoint with
      | Some value -> value
      | None -> Alcotest.fail "checkpoint disappeared"
    in
    Alcotest.(check (list string)) "nested images became text references" []
      (Runtime_agent.For_testing.required_modalities_for_run_with_checkpoint
         ~checkpoint_messages:dispatch_checkpoint.messages
         ~initial_messages:text.Driver.attempt_initial_messages
         ~goal_blocks:(Option.value text.Driver.attempt_goal_blocks ~default:[]));
    let suffix = [ message [ Agent_core.Types.Text "answer" ] ] in
    let current_input = Agent_core.Types.user_msg_blocks
        (Option.get text.Driver.attempt_goal_blocks) in
    (match Masc.Keeper_replay_prefix.restore_messages
             text.Driver.attempt_replay_prefix_projection
             (dispatch_checkpoint.messages @ [ current_input ] @ suffix) with
     | Error error -> Alcotest.fail (Masc.Keeper_replay_prefix.restore_error_to_string error)
     | Ok restored ->
       Alcotest.(check bool) "persisted prefix keeps the original image"
         true (restored = history @ [ Agent_core.Types.user_msg_blocks [ image ] ] @ suffix));
    let vision = project "lanevision.vision_model" in
    Alcotest.(check bool) "a later vision candidate gets the original checkpoint"
      true (vision.Driver.attempt_agent_core_checkpoint = Some checkpoint);
    Alcotest.(check bool) "a later vision candidate gets the original goal"
      true (vision.Driver.attempt_goal_blocks = Some [ image ]))

let test_current_image_checkpoint_survives_text_fallback () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    let runtime id = match Runtime.get_runtime_by_id id with
      | Some runtime -> runtime
      | None -> Alcotest.failf "missing runtime %s" id in
    let image = Agent_core.Types.image_block ~media_type:"image/png"
        ~data:(Base64.encode_string "original current-goal pixels") () in
    let canonical_blocks = [ Agent_core.Types.Text "inspect this"; image ] in
    let history = [ message [ Agent_core.Types.Text "previous turn" ] ] in
    let checkpoint =
      { (checkpoint_with_session_id "current-image-checkpoint") with messages = history } in
    (* Only the semantic-reader boundary is substituted. The driver captures
       the exact current-input boundary and restores the emitted checkpoint. *)
    let project_images ~mode:_ blocks =
      { Masc.Keeper_vision_ingest.blocks =
          List.map (function
            | Agent_core.Types.Image _ -> Agent_core.Types.Text "[image reading: blue circle]"
            | block -> block) blocks
      ; delegated_images = image_count_in_blocks blocks } in
    let text_view = Driver.For_testing.project_input_for_attempt
        ~project_images ~keeper_name:"current-image-checkpoint"
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~goal_blocks:(Some canonical_blocks) ~initial_messages:history
        ~agent_core_checkpoint:(Some checkpoint)
        ~runtime_id:"primary.text_model" (runtime "primary.text_model") in
    let projected_input = Agent_core.Types.user_msg_blocks
        (Option.get text_view.Driver.attempt_goal_blocks) in
    let canonical_input = Agent_core.Types.user_msg_blocks canonical_blocks in
    let dispatch_prefix =
      (Option.get text_view.Driver.attempt_agent_core_checkpoint).messages in
    let suffix =
      [ message [ Agent_core.Types.ToolUse
          { id = "status-call"; name = "status"; input = `Assoc [] } ]
      ; message ~role:Agent_core.Types.Tool
          [ Agent_core.Types.ToolResult
              { tool_use_id = "status-call"; content = "unchanged tool answer"
              ; outcome = Agent_core.Types.Tool_succeeded; json = None
              ; content_blocks = None } ]
      ; message ~role:Agent_core.Types.User [ Agent_core.Types.Text "injected context" ]
      ; message [ Agent_core.Types.Text "The circle is blue." ] ] in
    let provider_checkpoint =
      { checkpoint with messages = dispatch_prefix @ [ projected_input ] @ suffix } in
    let provider_result =
      { (completed_run_result ()) with checkpoint = Some provider_checkpoint } in
    let projection = text_view.Driver.attempt_replay_prefix_projection in
    let restored =
      match Driver.For_testing.project_provider_attempt_result
              ~replay_prefix_projection:projection (Ok provider_result)
            |> Driver.For_testing.turn_result with
      | Ok { Runtime_agent.checkpoint = Some checkpoint; _ } -> checkpoint
      | Ok _ -> Alcotest.fail "successful text fallback lost its checkpoint"
      | Error error -> Alcotest.fail (Agent_core.Error.to_string error) in
    Alcotest.(check bool) "successful text fallback retains current-goal pixels and exact suffix"
      true (restored.messages = history @ [ canonical_input ] @ suffix);
    let sidecar = `Assoc ["original_task",`String "image-fallback-task"] in
    let failed = Driver.For_testing.project_provider_attempt_result
      ~checkpoint_after:{provider_checkpoint with working_context=Some sidecar}
      ~replay_prefix_projection:projection (Error (retryable_network_error "checkpoint persistence failed")) in
    let failed_checkpoint = Driver.For_testing.produced_checkpoint failed |> Option.get in
    Alcotest.(check bool) "failed producer keeps canonical pixels and exact suffix"
      true (failed_checkpoint.messages=restored.messages);
    Alcotest.(check bool) "failed producer keeps its working context"
      true (failed_checkpoint.working_context=Some sidecar);
    let persisted = ref [] in
    let sink = Driver.For_testing.canonical_checkpoint_sink
        ~replay_prefix_projection:projection
        (fun (snapshot : Agent_core.Agent.checkpoint_snapshot) ->
          persisted := snapshot.checkpoint :: !persisted; Ok ()) in
    let snapshot checkpoint =
      { Agent_core.Agent.stage = Agent_core.Agent.After_tool_results_appended
      ; turn = 1; timestamp = 1.; checkpoint } in
    (match sink (snapshot provider_checkpoint) with
     | Ok () -> () | Error detail -> Alcotest.fail detail);
    Alcotest.(check bool) "mutation-boundary sink also stores canonical current input"
      true ((List.hd !persisted).messages = restored.messages);
    (match sink (snapshot restored) with
     | Ok () -> () | Error detail -> Alcotest.fail detail);
    Alcotest.(check bool) "already-canonical checkpoints remain identical"
      true ((List.hd !persisted).messages = restored.messages);
    let bad_inputs =
      [ suffix
      ; message ~role:Agent_core.Types.User [ Agent_core.Types.Text "different input" ]
        :: projected_input :: suffix
      ; { projected_input with role = Agent_core.Types.Assistant } :: suffix
      ; { projected_input with metadata = [ "unexpected", `Bool true ] } :: suffix ] in
    List.iter (fun bad_suffix ->
      match sink (snapshot { provider_checkpoint with messages = dispatch_prefix @ bad_suffix }) with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "mismatched current input reached checkpoint persistence") bad_inputs;
    Alcotest.(check int) "invalid boundaries never call the persistence sink" 2 (List.length !persisted);
    let reloaded =
      match Agent_core.Checkpoint.of_json (Agent_core.Checkpoint.to_json restored) with
      | Ok checkpoint -> checkpoint
      | Error error -> Alcotest.fail (Agent_core.Error.to_string error) in
    let native_view = Driver.For_testing.project_input_for_attempt
        ~project_images ~keeper_name:"current-image-checkpoint"
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~goal_blocks:(Some [ Agent_core.Types.Text "inspect the earlier picture again" ])
        ~initial_messages:reloaded.messages ~agent_core_checkpoint:(Some reloaded)
        ~runtime_id:"lanevision.vision_model" (runtime "lanevision.vision_model") in
    Alcotest.(check bool) "fresh native turn recovers the persisted canonical image blocks"
      true (native_view.Driver.attempt_initial_messages = history @ [ canonical_input ] @ suffix);
    Alcotest.(check bool) "native checkpoint replay retains original current-input bytes"
      true (native_view.Driver.attempt_agent_core_checkpoint = Some reloaded))

(* Drives a two-candidate deferred lane through [run_named] on an image turn
   and records, per dispatched candidate, whether the history the provider
   request was built from still carried the image. Both endpoints refuse the
   connection, so each attempt fails at the wire and the walk moves on; under
   test is the view each candidate was handed before that. The projection
   runs when Agent Core prepares the request, after the multimodal gate, so a
   candidate that hit the gate leaves no observation at all. *)
let run_deferred_lane_with_image ~next_runtime_id ~later_runtime_ids =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    Eio_main.run
    @@ fun env ->
    Eio.Switch.run
    @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let manifests = ref [] in
    let context : Runtime_manifest.turn_context =
      { manifest_keeper_name = "deferred-per-candidate"
      ; manifest_trace_id = "deferred-per-candidate-trace"
      ; manifest_keeper_turn_id = Some 1
      }
    in
    let image = synthetic_image () in
    let history =
      [ message
          ~role:Agent_core.Types.User
          [ Agent_core.Types.Text "earlier image turn"; image ]
      ]
    in
    let current_attempt = ref None in
    let observed = ref [] in
    let rec carries_reference blocks =
      List.exists
        (function
          | Agent_core.Types.Text text ->
            contains ~needle:"[unread image URL:" text
            && contains ~needle:"https://example.invalid/screenshot.png" text
          | Agent_core.Types.ToolResult { content_blocks = Some nested; _ } ->
            carries_reference nested
          | _ -> false)
        blocks
    in
    let deferred_runtime_lane =
      Driver.For_testing.make_deferred_runtime_lane
        ~assignment_id:"resilient"
        ~failed_runtime_id:"previous.test_model"
        ~next_runtime_id
        ~later_runtime_ids
        ~failure:(retryable_network_error "previous cycle failed")
    in
    let result =
      Driver.run_named
        ~system_prompt:"You are the runtime failover test Keeper."
        ~runtime_id:"resilient"
        ~keeper_name:"deferred-per-candidate"
        ~base_path:(Filename.get_temp_dir_name ())
        ~agent_core_tools:[]
        ~goal:"describe the image"
        ~goal_blocks:[ Agent_core.Types.Text "describe the image"; image ]
        ~initial_messages:history
        ~model_input_projection:(fun messages ->
          observed :=
            ( !current_attempt
            , image_count_in_messages messages > 0
            , List.exists (fun (message : Agent_core.Types.message) ->
                carries_reference message.content) messages ) :: !observed;
          Ok messages)
        ~on_runtime_attempt:(fun attempt ->
          current_attempt := Some attempt.Driver.runtime_id)
        ~runtime_manifest_context:context
        ~runtime_manifest_append:(fun manifest -> manifests := manifest :: !manifests)
        ~deferred_runtime_lane
        ~body_timeout_s:0.5
        ~sw
        ~net:env#net
        ()
    in
    result, List.rev !observed, !manifests)

let check_deferred_lane_views ~order (result, observed, manifests) =
  let saw_image runtime_id =
    match
      List.filter_map
        (fun (attempt, has_image, _) ->
           match attempt with
           | Some id when String.equal id runtime_id -> Some has_image
           | Some _ | None -> None)
        observed
    with
    | [] -> Alcotest.failf "no provider request was built for %s" runtime_id
    | first :: rest ->
      if List.for_all (Bool.equal first) rest
      then first
      else Alcotest.failf "%s was handed inconsistent views" runtime_id
  in
  let first_seen =
    List.fold_left
      (fun seen (attempt, _, _) ->
         match attempt with
         | Some id when not (List.mem id seen) -> seen @ [ id ]
         | Some _ | None -> seen)
      []
      observed
  in
  Alcotest.(check (list string))
    "requests were built for the candidates in lane order"
    order
    first_seen;
  Alcotest.(check bool)
    "the vision candidate keeps the image"
    true
    (saw_image "lanevision.vision_model");
  Alcotest.(check bool)
    "the text-only candidate receives references instead of image blocks"
    false
    (saw_image "primary.text_model");
  Alcotest.(check bool)
    "real driver includes the surviving image reference in the text request"
    true
    (List.exists
       (fun (runtime_id, _, has_reference) ->
         runtime_id = Some "primary.text_model" && has_reference)
       observed);
  (match routed_rows_with_status "delegated" manifests with
   | [ manifest ] ->
     let decision =
       Runtime_manifest.public_projection_of_decision manifest.decision
     in
     Alcotest.(check string)
       "delegation names the text-only candidate"
       "primary.text_model"
       (string_member "runtime_id" decision)
   | rows -> Alcotest.failf "expected one delegated row, got %d" (List.length rows));
  match result with
  | Error
      (Agent_core.Error.Config
         (Agent_core.Error.InvalidConfig { field = "multimodal_input"; detail })) ->
    Alcotest.failf
      "a candidate hit the multimodal gate instead of its own degrade: %s"
      detail
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "connection-refused endpoints cannot complete a turn"

(* Order [vision; text-only]: the vision head admits the image, so nothing is
   stripped for it; when it fails over, the text-only tail must receive its own
   degraded view rather than the head's images (which hit the multimodal gate
   #33034 moved the deferred head off). *)
let test_deferred_lane_vision_then_text_projects_per_candidate () =
  run_deferred_lane_with_image
    ~next_runtime_id:"lanevision.vision_model"
    ~later_runtime_ids:[ "primary.text_model" ]
  |> check_deferred_lane_views
       ~order:[ "lanevision.vision_model"; "primary.text_model" ]

(* Order [text-only; vision]: the text-only head is degraded; when it fails
   over, the vision tail must receive the original image, not the head's
   stripped view. *)
let test_deferred_lane_text_then_vision_projects_per_candidate () =
  run_deferred_lane_with_image
    ~next_runtime_id:"primary.text_model"
    ~later_runtime_ids:[ "lanevision.vision_model" ]
  |> check_deferred_lane_views
       ~order:[ "primary.text_model"; "lanevision.vision_model" ]

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
        ~system_prompt:"You are the runtime failover test Keeper."
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

let test_lane_media_reroute_prefers_lane_candidate () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    match Runtime.resolve_assignment "resilient" with
    | `Missing | `Unavailable _ ->
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
          ~candidates:
            (Driver.For_testing.modality_reroute_candidates
               ~now:(Unix.gettimeofday ())
               ~deferred_runtime_lane:None
               ~first_candidate
               ~remaining_runtimes)
      with
      | Runtime_agent.Reroute { target; _ } ->
        Alcotest.(check string)
          "a capable lane candidate precedes global media_failover"
          "lanevision.vision_model"
          target.Runtime.id
      | Runtime_agent.No_reroute_needed ->
        Alcotest.fail "text-only first candidate should require image reroute"
      | Runtime_agent.No_capable_runtime _ ->
        Alcotest.fail "lane second candidate should be image-capable")

(* RFC-0440: a lane whose remaining candidates cannot take the image reroutes
   to [runtime.media_failover]; a deferred lane offers no candidates, because
   its walk dispatches the frozen suffix and would never perform the move. *)
let test_lane_media_reroute_reaches_media_failover () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    let runtime id =
      match Runtime.get_runtime_by_id id with
      | Some runtime -> runtime
      | None -> Alcotest.failf "missing runtime %s" id
    in
    let image_block =
      Agent_core.Types.Image
        { media_type = "image/png"
        ; data = Base64.encode_string "image"
        ; source_type = Agent_core.Types.Base64
        }
    in
    (match
       Driver.For_testing.lane_modality_reroute_decision
         ~checkpoint_messages:[]
         ~initial_messages:[]
         ~goal_blocks:[ image_block ]
         ~first_candidate:(runtime "primary.text_model")
         ~candidates:
           (Driver.For_testing.modality_reroute_candidates
              ~now:(Unix.gettimeofday ())
              ~deferred_runtime_lane:None
              ~first_candidate:(runtime "primary.text_model")
              ~remaining_runtimes:[])
     with
     | Runtime_agent.Reroute { target; _ } ->
       Alcotest.(check string)
         "a lane with no capable candidate reroutes to media_failover"
         "outsidevision.vision_model"
         target.Runtime.id
     | Runtime_agent.No_reroute_needed ->
       Alcotest.fail "a text-only head must reroute an image turn"
     | Runtime_agent.No_capable_runtime _ ->
       Alcotest.fail "media_failover holds an image-capable runtime");
    let deferred =
      Driver.For_testing.make_deferred_runtime_lane
        ~assignment_id:"resilient"
        ~failed_runtime_id:"primary.text_model"
        ~next_runtime_id:"lanevision.vision_model"
        ~later_runtime_ids:[]
        ~failure:(retryable_network_error "previous cycle failed")
    in
    Alcotest.(check (list string))
      "a deferred lane offers no reroute candidates"
      []
      (List.map
         (fun (runtime : Runtime.t) -> runtime.Runtime.id)
         (Driver.For_testing.modality_reroute_candidates
            ~now:(Unix.gettimeofday ())
            ~deferred_runtime_lane:(Some deferred)
            ~first_candidate:(runtime "primary.text_model")
            ~remaining_runtimes:[ runtime "lanevision.vision_model" ])))

(* RFC-0440 §3: a candidate whose account answered a hard quota rejection moves
   behind the live candidates, so the reroute picks a live one and the image
   walk visits the exhausted one last. A text turn keeps its lane order. *)
let test_lane_media_reroute_walks_past_exhausted_candidate () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let runtime id =
        match Runtime.get_runtime_by_id id with
        | Some runtime -> runtime
        | None -> Alcotest.failf "missing runtime %s" id
      in
      let ids = List.map (fun (runtime : Runtime.t) -> runtime.Runtime.id) in
      let head = runtime "primary.text_model" in
      let lanevision = runtime "lanevision.vision_model" in
      Runtime_quota_window.note_observed_exhausted
        ~scope:(Runtime.quota_scope_of_runtime lanevision);
      let candidates =
        Driver.For_testing.modality_reroute_candidates
          ~now:(Unix.gettimeofday ())
          ~deferred_runtime_lane:None
          ~first_candidate:head
          ~remaining_runtimes:[ lanevision ]
      in
      Alcotest.(check (list string))
        "the exhausted lane candidate moves behind media_failover"
        [ "primary.text_model"
        ; "outsidevision.vision_model"
        ; "lanevision.vision_model"
        ]
        (ids candidates);
      let image_block =
        Agent_core.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string "image"
          ; source_type = Agent_core.Types.Base64
          }
      in
      let first_runtime =
        match
          Driver.For_testing.lane_modality_reroute_decision
            ~checkpoint_messages:[]
            ~initial_messages:[]
            ~goal_blocks:[ image_block ]
            ~first_candidate:head
            ~candidates
        with
        | Runtime_agent.Reroute { target; _ } ->
          Alcotest.(check string)
            "the reroute picks the live candidate"
            "outsidevision.vision_model"
            target.Runtime.id;
          target
        | Runtime_agent.No_reroute_needed ->
          Alcotest.fail "a text-only head must reroute an image turn"
        | Runtime_agent.No_capable_runtime _ ->
          Alcotest.fail "two image-capable candidates are declared"
      in
      let media_walk = Runtime_agent.media_walk ~candidates [ image_block ] in
      Alcotest.(check (list string))
        "the image walk holds the image-capable candidates, live first"
        [ "outsidevision.vision_model"; "lanevision.vision_model" ]
        (ids media_walk);
      (* The assigned text-only runtime closes the list. The reroute took it out
         of the head, and without the tail a lane whose media candidates all
         answer 402 would exhaust into an error instead of reaching the runtime
         whose per-attempt projection drops the image and delegates. *)
      Alcotest.(check (list string))
        "the turn walks the live candidate, then the exhausted one, then degrades"
        [ "outsidevision.vision_model"
        ; "lanevision.vision_model"
        ; "primary.text_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk
              ~assigned_runtime:head
              ~first_runtime
              ~remaining_runtimes:[ lanevision ]));
      Alcotest.(check (list string))
        "a single-candidate lane still reaches its assigned runtime"
        [ "outsidevision.vision_model"
        ; "lanevision.vision_model"
        ; "primary.text_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk
              ~assigned_runtime:head
              ~first_runtime
              ~remaining_runtimes:[]));
      Alcotest.(check (list string))
        "a text turn keeps the lane order"
        [ "primary.text_model"; "lanevision.vision_model" ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk:
                (Runtime_agent.media_walk ~candidates
                   [ Agent_core.Types.Text "hello" ])
              ~assigned_runtime:head
              ~first_runtime:head
              ~remaining_runtimes:[ lanevision ]))))

(* RFC-0440 §3: an assigned runtime that takes the image itself never reroutes
   -- the decision reads capability, not the account -- so the exhausted head is
   still the head after the decision. The turn must start from the walk anyway,
   or every image turn calls the dead account first while a live candidate sits
   behind it. *)
let test_media_turn_starts_from_the_live_walk_head () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let runtime id =
        match Runtime.get_runtime_by_id id with
        | Some runtime -> runtime
        | None -> Alcotest.failf "missing runtime %s" id
      in
      let ids = List.map (fun (runtime : Runtime.t) -> runtime.Runtime.id) in
      let assigned = runtime "lanevision.vision_model" in
      let text_only = runtime "primary.text_model" in
      Runtime_quota_window.note_observed_exhausted
        ~scope:(Runtime.quota_scope_of_runtime assigned);
      let image_block =
        Agent_core.Types.Image
          { media_type = "image/png"
          ; data = Base64.encode_string "image"
          ; source_type = Agent_core.Types.Base64
          }
      in
      let candidates =
        Driver.For_testing.modality_reroute_candidates
          ~now:(Unix.gettimeofday ())
          ~deferred_runtime_lane:None
          ~first_candidate:assigned
          ~remaining_runtimes:[ text_only ]
      in
      (match
         Driver.For_testing.lane_modality_reroute_decision
           ~checkpoint_messages:[]
           ~initial_messages:[]
           ~goal_blocks:[ image_block ]
           ~first_candidate:assigned
           ~candidates
       with
       | Runtime_agent.No_reroute_needed -> ()
       | Runtime_agent.Reroute { target; _ } ->
         Alcotest.failf
           "an image-capable head must not reroute, got %s"
           target.Runtime.id
       | Runtime_agent.No_capable_runtime _ ->
         Alcotest.fail "the assigned runtime takes the image");
      let media_walk = Runtime_agent.media_walk ~candidates [ image_block ] in
      Alcotest.(check (list string))
        "the walk puts the live candidate ahead of the exhausted head"
        [ "outsidevision.vision_model"; "lanevision.vision_model" ]
        (ids media_walk);
      Alcotest.(check (list string))
        "the turn starts from the live candidate, not the exhausted head"
        [ "outsidevision.vision_model"
        ; "lanevision.vision_model"
        ; "primary.text_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk
              ~assigned_runtime:assigned
              ~first_runtime:assigned
              ~remaining_runtimes:[ text_only ]))))

(* The media walk reaches past the lane, so a winner can be a runtime the lane
   does not declare. Recording it for the lane erases the last in-lane success
   and promotes nothing in its place: prefer_order reorders the lane's own
   candidates, and the winner is in none of them. The next text turn then
   starts from the declared head again (#34823). *)
let test_an_out_of_lane_winner_keeps_the_lanes_own_preference () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    Runtime_lane_preference.reset_for_testing ();
    (* An in-lane success the lane is entitled to keep. *)
    Runtime_lane_preference.note_success ~lane_id:"resilient"
      ~candidate:"fallback.test_model";
    let events = ref [] in
    let result =
      Driver.For_testing.attempt_runtime_candidates
        ~lane_id:"resilient"
        ~runtime_id:"resilient"
        ~runtime_id_of:(fun runtime_id -> runtime_id)
        ~emit_runtime_manifest:(emit_manifest_collector events)
        ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
          attempt_without_effect (Ok runtime_id) None)
        [ "media.out_of_lane_model" ]
    in
    (match result with
     | Ok runtime_id ->
       Alcotest.(check string)
         "the out-of-lane candidate served the turn"
         "media.out_of_lane_model"
         runtime_id
     | Error error ->
       Alcotest.failf "expected candidate success, got %s"
         (Agent_core.Error.to_string error));
    match Runtime.get_lane_by_id "resilient" with
    | None -> Alcotest.fail "expected lane 'resilient' to be configured"
    | Some lane ->
      Alcotest.(check (list string))
        "the in-lane success still leads the lane's order"
        [ "fallback.test_model"; "primary.test_model" ]
        (Runtime_lane_preference.prefer_order ~lane_id:"resilient"
           (Runtime_lane.ordered_candidates lane)))

(* RFC-0440 §3: a 402 belongs to the candidate's account, so the walk moves to
   the next candidate in the same turn and does not call the first one again. *)
let test_attempt_loop_moves_past_payment_required () =
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
        | "dead.vision_model" ->
          attempt_without_effect
            (Error
               (Agent_core.Error.Api
                  (Llm_provider.Retry.PaymentRequired
                     { message = "Insufficient Balance" })))
            None
        | "live.vision_model" -> attempt_without_effect (Ok runtime_id) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "dead.vision_model"; "live.vision_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string) "the live candidate answers" "live.vision_model" runtime_id
   | Error error ->
     Alcotest.failf
       "the walk stopped at the 402: %s"
       (Agent_core.Error.to_string error));
  Alcotest.(check (list string))
    "each candidate is called once, in order"
    [ "dead.vision_model"; "live.vision_model" ]
    !attempts

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
    (List.map decision_runtime_id events);
  List.iter (fun (event, _, decision) ->
      match event, decision with
      | Runtime_manifest.Runtime_failed, Some json ->
          let open Yojson.Safe.Util in
          Alcotest.(check string) "failed attempt usage is unresolved" "unresolved"
            (json |> member "attempt_usage_status" |> to_string);
          Alcotest.(check bool) "failure is not zero-token consumption" true
            (json |> member "attempt_total_usage" = `Null)
      | _ -> ()) events

let test_failed_lane_receipt_counts_missing_tail () =
  let last_attempt_index = ref 0 in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_attempt_error:(fun ~runtime_id:_ ~attempt ~dispatch:_ _error ->
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

let native_settlement_fixture runtime_id : Masc.Keeper_official_client_session_store.t =
  {client_kind=Masc.Keeper_official_client_session_store.Codex;runtime_id;
   phase=Masc.Keeper_official_client_session_store.Settled {session_id="winning-session";turn_id="winning-turn"};
   turn_count=1;tool_surface_sha256=String.make 64 'a';last_recovery_resolution=None;
   last_transient_release=None;updated_at=1.}

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
              (Driver.For_testing.selected_runtime_result
                 ~official_client_settlement:(native_settlement_fixture primary.id)
                 runtime ~lane_attempt_index:idx
                 (Error (retryable_network_error "primary failed")))
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
      Alcotest.(check bool) "failed native candidate cannot transfer its receipt to Core fallback"
        true (selected.official_client_settlement = None);
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
               ~official_client_settlement:(native_settlement_fixture runtime.id)
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
      Alcotest.(check bool) "winning native candidate keeps its exact producer settlement"
        true (selected.official_client_settlement = Some (native_settlement_fixture primary.id));
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
          , effect_disposition
          , Masc.Keeper_attempt_dispatch.Dispatched )
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
          , Masc.Keeper_provider_attempt_effect.Effect_attempted
          , Masc.Keeper_attempt_dispatch.Dispatched )
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

(* Use the actual agent transport projection. Mapping through
   Error.of_retry_api_error here would manufacture Provider.RateLimit and miss
   the Api.RateLimited variant returned by the real provider path. *)
let rate_limit_error_from_a_429 ?(retry_after_header = None) ~body () =
  Agent_core.Provider_failure_attribution.core_error_of_http_error
    (Llm_provider.Http_client.HttpError { code = 429; body; retry_after_header })
;;

let observed_candidate runtime_id =
  let runtime = Option.get (Runtime.get_runtime_by_id runtime_id) in
  Runtime_lane_preference.candidate_backpressure
    ~now:(Unix.gettimeofday ()) ~candidate:runtime.candidate_preference
;;

let backpressure_order runtime_ids =
  match runtime_ids with
  | [] -> []
  | next_runtime_id :: later_runtime_ids ->
    let hint = Driver.For_testing.make_deferred_runtime_lane
      ~assignment_id:"quota_lane" ~failed_runtime_id:"previous.test_model"
      ~next_runtime_id ~later_runtime_ids
      ~failure:(retryable_network_error "previous attempt") in
    Driver.quota_ordered_deferred_runtime_lane ~now:(Unix.gettimeofday ()) hint
    |> Driver.deferred_runtime_ids
;;

let test_http_429_preserves_unknown_scope_and_fallback () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Runtime_quota_window.reset_for_testing ();
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      let attempts = ref [] in
      let result = Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"quota_lane" ~runtime_id_of:Fun.id
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
          attempts := !attempts @ [runtime_id];
          attempt_without_effect (match runtime_id with
            | "shared_a.test_model" -> Error (rate_limit_error_from_a_429
                ~body:{|{"error":{"message":"rate limited"}}|} ())
            | "shared_b.test_model" -> Error (Agent_core.Error.Provider
                (Llm_provider.Error.RateLimit
                  { provider = "shared_b"; retry_after = None; detail = "rate limited" }))
            | "other.test_model" -> Ok runtime_id
            | other -> Alcotest.failf "unexpected candidate %s" other) None)
        ["shared_a.test_model"; "shared_b.test_model"; "other.test_model"] in
      Alcotest.(check (list string)) "both unknown-scope refusals allow sibling and disjoint fallback"
        ["shared_a.test_model"; "shared_b.test_model"; "other.test_model"] !attempts;
      (match result with
       | Ok id -> Alcotest.(check string) "disjoint candidate completes" "other.test_model" id
       | Error error -> Alcotest.failf "fallback failed: %s" (Agent_core.Error.to_string error));
      List.iter (fun id ->
        (match observed_candidate id with
         | Some (Runtime_lane_preference.Unknown_scope_rate_limit { retry_after = None; _ }) -> ()
         | Some (Runtime_lane_preference.Unknown_scope_rate_limit _) | None ->
           Alcotest.fail "rate limit must retain unknown scope and absent hint");
        let scope = Option.get (Runtime.quota_scope_of_runtime_id id) in
        Alcotest.(check bool) "no credential quota inferred" false
          (Runtime_quota_window.is_exhausted ~scope ~now:(Unix.gettimeofday ())))
        ["shared_a.test_model"; "shared_b.test_model"];
      Alcotest.(check (list string)) "independent later resolution demotes only observed candidates"
        ["other.test_model"; "shared_a.test_model"; "shared_b.test_model"]
        (backpressure_order ["shared_a.test_model"; "shared_b.test_model"; "other.test_model"])))
;;

let test_rate_limit_order_never_excludes_and_success_clears () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    let ids = ["shared_a.test_model"; "shared_b.test_model"] in
    List.iter (fun id ->
      let runtime = Option.get (Runtime.get_runtime_by_id id) in
      Runtime_lane_preference.note_rate_limit ~candidate:runtime.candidate_preference
        ~retry_after:(Some 300.)) ids;
    Alcotest.(check (list string)) "all observed candidates remain in declared order"
      ids (backpressure_order ids);
    let attempts = ref [] in
    let result = Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"quota_lane" ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
        attempts := !attempts @ [runtime_id];
        attempt_without_effect
          (if String.equal runtime_id "shared_a.test_model" then
            Error (rate_limit_error_from_a_429 ~retry_after_header:(Some 300.) ~body:"{}" ())
           else Ok ()) None)
      (backpressure_order ids) in
    (match result with Ok () -> () | Error _ -> Alcotest.fail "all-demoted fallback was blocked");
    Alcotest.(check (list string)) "Retry-After is ordering, not admission" ids !attempts;
    Alcotest.(check bool) "success clears even an unexpired hint" true
      (Option.is_none (observed_candidate "shared_b.test_model"));
    match observed_candidate "shared_a.test_model" with
    | Some (Runtime_lane_preference.Unknown_scope_rate_limit { retry_after = Some seconds; _ }) ->
        Alcotest.(check (float 0.)) "actual HTTP header survives driver ingress" 300. seconds
    | Some (Runtime_lane_preference.Unknown_scope_rate_limit _) | None ->
        Alcotest.fail "actual Retry-After hint was lost")
;;

let test_rate_limit_candidate_survives_unchanged_reload_only () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    let old = Option.get (Runtime.get_runtime_by_id "shared_a.test_model") in
    let attempt runtime reload =
      let result = Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"quota_lane" ~runtime_id_of:(fun (rt : Runtime.t) -> rt.id)
        ~quota_scope_of:(fun rt -> Some (Runtime.quota_scope_of_runtime rt))
        ~candidate_preference_of:(fun (rt : Runtime.t) -> Some rt.candidate_preference)
        ~candidate_dispatchable:(fun _ -> true)
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx:_ ~runtime_id:_ _ ->
          reload ();
          attempt_without_effect (Error (rate_limit_error_from_a_429
            ~body:{|{"error":{"message":"rate limited","retry_after":300.0}}|} ())) None)
        [runtime] in
      match result with
      | Error (Agent_core.Error.Api (Llm_provider.Retry.RateLimited { retry_after = Some seconds; _ })) ->
          Alcotest.(check (float 0.)) "body hint preserved" 300. seconds
      | Error _ | Ok _ -> Alcotest.fail "real transport 429 variant/hint changed"
    in
    attempt old (fun () -> ());
    let assert_order () = Alcotest.(check (list string)) "same binding remains demoted"
      ["other.test_model"; "shared_a.test_model"]
      (backpressure_order ["shared_a.test_model"; "other.test_model"]) in
    assert_order ();
    reload_runtime_config runtime_toml_quota_lane;
    assert_order ();
    (* A frozen dispatch finishes after the same id is bound to another
       credential reference. It must update only the old observation cell. *)
    attempt old (fun () -> reload_runtime_config
      (runtime_toml_quota_lane_with_shared_credential "REBOUND_QUOTA_TEST_KEY"));
    Alcotest.(check bool) "old response remains on old frozen binding" true
      (Option.is_some (Runtime_lane_preference.candidate_backpressure
        ~now:(Unix.gettimeofday ()) ~candidate:old.candidate_preference));
    Alcotest.(check bool) "replacement does not inherit old response" true
      (Option.is_none (observed_candidate "shared_a.test_model"));
    Alcotest.(check (list string)) "replacement starts in declared order"
      ["shared_a.test_model"; "other.test_model"]
      (backpressure_order ["shared_a.test_model"; "other.test_model"]))
;;

let test_rate_limit_credential_rotation_under_same_reference () =
  let key = "MASC_HTTP429_CANDIDATE_ROTATION_TEST_KEY" in
  let original = Sys.getenv_opt key in
  Fun.protect
    ~finally:(fun () -> Unix.putenv key (Option.value original ~default:""))
    (fun () ->
      Unix.putenv key "fixture-credential-before";
      let toml = runtime_toml_quota_lane_with_shared_credential key in
      with_runtime_config toml (fun () ->
        let old = Option.get (Runtime.get_runtime_by_id "shared_a.test_model") in
        let result = Driver.For_testing.attempt_runtime_candidates
          ~runtime_id:"quota_lane" ~runtime_id_of:(fun (rt : Runtime.t) -> rt.id)
          ~quota_scope_of:(fun rt -> Some (Runtime.quota_scope_of_runtime rt))
          ~candidate_preference_of:(fun (rt : Runtime.t) -> Some rt.candidate_preference)
          ~candidate_dispatchable:(fun _ -> true)
          ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
          ~run_attempt:(fun ~idx:_ ~runtime_id:_ _ ->
            Unix.putenv key "fixture-credential-after";
            reload_runtime_config toml;
            attempt_without_effect (Error (rate_limit_error_from_a_429 ~body:"{}" ())) None)
          [old] in
        (match result with
         | Error (Agent_core.Error.Api (Llm_provider.Retry.RateLimited _)) -> ()
         | Error _ | Ok _ -> Alcotest.fail "expected actual transport rate limit");
        Alcotest.(check bool) "old observation stays attached to dispatched value" true
          (Option.is_some (Runtime_lane_preference.candidate_backpressure
            ~now:(Unix.gettimeofday ()) ~candidate:old.candidate_preference));
        Alcotest.(check bool) "same reference with new resolved credential has no old observation" true
          (Option.is_none (observed_candidate "shared_a.test_model"))))
;;

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
             ~system_prompt:"You are the runtime failover test Keeper."
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

let test_attempt_loop_without_lane_id_does_not_update_sticky_preference () =
  Runtime_lane_preference.reset_for_testing ();
  let events = ref [] in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
        attempt_without_effect (Ok runtime_id) None)
      [ "media.fallback_model" ]
  in
  (match result with
   | Ok runtime_id ->
     Alcotest.(check string)
       "rerouted candidate can still serve turn"
       "media.fallback_model"
       runtime_id
   | Error e ->
     Alcotest.failf
       "expected candidate success, got %s"
       (Agent_core.Error.to_string e));
  Alcotest.(check (list string))
    "lane preference remains declared order without lane id"
    [ "primary.text_model"; "media.fallback_model" ]
    (Runtime_lane_preference.prefer_order
       ~lane_id:"resilient"
       [ "primary.text_model"; "media.fallback_model" ])

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
      ~on_attempt_error:(fun ~runtime_id ~attempt ~dispatch:_ error ->
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
       "typed overflow preserved through lane exhaustion"
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
  let attempt_errors = ref [] in
  let lane_terminal = ref None in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_attempt_error:(fun ~runtime_id ~attempt ~dispatch _error ->
        attempt_errors := !attempt_errors @ [ runtime_id, attempt, dispatch ])
      ~on_lane_terminal_error:(fun terminal -> lane_terminal := Some terminal)
      ~run_attempt:(fun ~idx:_ ~runtime_id candidate ->
        attempts := !attempts @ [ runtime_id ];
        match candidate with
        | "small.test_model" ->
          attempt_without_effect
            (Error (context_overflow_error "prompt exceeds context window"))
            (Some (checkpoint_with_session_id runtime_id))
        | "fallback.test_model" ->
          attempt_without_effect
            (Error
               (Agent_core.Error.Api
                  (Agent_core.Retry.RateLimited
                     { retry_after = None; message = "weekly usage limit" })))
            (Some (checkpoint_with_session_id runtime_id))
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
    !attempts;
  (* The last candidate the walk dispatched and the candidate whose error the
     lane returned are two facts: the fallback was dispatched last, the
     overflow came from the first candidate. *)
  Alcotest.(check (list (triple string int dispatch_disposition)))
    "every candidate's own error is observed with its dispatch disposition"
    [ "small.test_model", 0, Masc.Keeper_attempt_dispatch.Dispatched
    ; "fallback.test_model", 1, Masc.Keeper_attempt_dispatch.Dispatched
    ]
    !attempt_errors;
  match !lane_terminal with
  | None -> Alcotest.fail "exhausted lane must report which candidate's error it returned"
  | Some (terminal : Driver.lane_terminal_error) ->
    Alcotest.(check string)
      "the lane error originates from the overflowed first candidate, not \
       the last dispatched fallback"
      "small.test_model"
      terminal.origin_runtime_id;
    Alcotest.(check string) "checkpoint belongs to earlier terminal-error origin, not last candidate"
      "small.test_model" (Option.get terminal.checkpoint_after).session_id;
    Alcotest.(check int) "origin attempt index is the first walk index" 0 terminal.origin_attempt;
    Alcotest.(check bool)
      "the reported lane error is the overflow itself"
      true
      (Masc.Keeper_error_classify.is_context_overflow terminal.lane_error)

(* Overflow precedence applies only to an exhausted lane: a walk stopped
   mid-lane by a non-retryable error keeps that stopping error, which is the
   immediate operator signal. *)
let test_attempt_loop_midwalk_terminal_outranks_observed_overflow () =
  let attempts = ref [] in
  let lane_terminal = ref None in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_lane_terminal_error:(fun terminal -> lane_terminal := Some terminal)
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
    !attempts;
  match !lane_terminal with
  | None -> Alcotest.fail "a mid-lane stop must report which candidate's error it returned"
  | Some (terminal : Driver.lane_terminal_error) ->
    Alcotest.(check (pair string int))
      "the lane error originates from the candidate the walk stopped on"
      ("broken.test_model", 1)
      (terminal.origin_runtime_id, terminal.origin_attempt)

(* A candidate the walk refuses before dispatch is still an attempt error,
   but it reaches the observer as [Rejected_before_dispatch] so a consumer
   can keep it as evidence without naming it as the runtime that answered. *)
let test_attempt_loop_reports_pre_dispatch_refusal_disposition () =
  let attempt_errors = ref [] in
  let lane_terminal = ref None in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_attempt_error:(fun ~runtime_id ~attempt ~dispatch _error ->
        attempt_errors := !attempt_errors @ [ runtime_id, attempt, dispatch ])
      ~on_lane_terminal_error:(fun terminal -> lane_terminal := Some terminal)
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
        match candidate with
        | "resolved.test_model" ->
          attempt_without_effect
            (Error (retryable_network_error "resolved candidate failed"))
            None
        | "missing.test_model" ->
          attempt_rejected_before_dispatch
            (Agent_core.Error.Internal "runtime candidate missing")
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "resolved.test_model"; "missing.test_model" ]
  in
  (match result with
   | Ok _ -> Alcotest.fail "expected the refused tail to end the lane"
   | Error (Agent_core.Error.Internal msg) ->
     Alcotest.(check string) "refusal error preserved" "runtime candidate missing" msg
   | Error e ->
     Alcotest.failf "expected the refusal error, got %s" (Agent_core.Error.to_string e));
  Alcotest.(check (list (triple string int dispatch_disposition)))
    "the dispatched candidate and the refused tail carry distinct dispositions"
    [ "resolved.test_model", 0, Masc.Keeper_attempt_dispatch.Dispatched
    ; "missing.test_model", 1, Masc.Keeper_attempt_dispatch.Rejected_before_dispatch
    ]
    !attempt_errors;
  match !lane_terminal with
  | None -> Alcotest.fail "the lane must report which candidate's error it returned"
  | Some (terminal : Driver.lane_terminal_error) ->
    Alcotest.(check (pair string int))
      "the lane error originates from the refused tail"
      ("missing.test_model", 1)
      (terminal.origin_runtime_id, terminal.origin_attempt)

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

let access_error_from_http code =
  Agent_core.Provider_failure_attribution.core_error_of_http_error
    ~provider:"candidate-access-fixture"
    (Llm_provider.Http_client.HttpError
       { code; body = "candidate access denied"; retry_after_header = None })
;;

let test_candidate_access_denial_reaches_the_next_declared_runtime () =
  List.iter (fun code ->
    let denied = access_error_from_http code in
    let attempts = ref [] in
    let result = Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
        attempts := runtime_id :: !attempts;
        attempt_without_effect
          (if runtime_id = "denied" then Error denied else Ok runtime_id) None)
      ["denied"; "available"] in
    (match result with
     | Ok selected -> Alcotest.(check string) "available candidate finishes" "available" selected
     | Error error -> Alcotest.failf "HTTP%d stopped the lane: %s" code (Agent_core.Error.to_string error));
    Alcotest.(check (list string)) "walk stays inside declared candidates"
      ["denied"; "available"] (List.rev !attempts)) [401;403]
;;

let test_access_failover_preserves_effect_and_caller_authority () =
  List.iter (fun code ->
    List.iter (fun disposition ->
      let attempts = ref 0 in
      let result = Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
          incr attempts;
          if runtime_id <> "denied" then Alcotest.fail "possible effect was replayed";
          ( Error (access_error_from_http code)
          , None
          , disposition
          , Masc.Keeper_attempt_dispatch.Dispatched ))
        ["denied"; "available"] in
      Alcotest.(check int) "effect owner attempted once" 1 !attempts;
      match result with
      | Error error ->
        (match Driver.classify_masc_internal_error error with
         | Some (Driver.Provider_attempt_effect_fenced { effect_disposition; _ }) ->
           Alcotest.(check bool) "exact effect disposition preserved" true
             (effect_disposition = disposition)
         | _ -> Alcotest.fail "access error lost the effect fence")
      | Ok _ -> Alcotest.fail "effectful access denial unexpectedly succeeded")
      [Masc.Keeper_provider_attempt_effect.Effect_attempted;
       Masc.Keeper_provider_attempt_effect.Observation_unavailable];
    let attempts = ref 0 in
    let deferred = ref [] in
    let result = Driver.For_testing.attempt_runtime_candidates
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ -> false)
      ~on_retry_deferred:(fun hint -> deferred := hint :: !deferred)
      ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ _ ->
        incr attempts; attempt_without_effect (Error (access_error_from_http code)) None)
      ["denied"; "available"] in
    Alcotest.(check bool) "caller denial remains an error" true (Result.is_error result);
    Alcotest.(check int) "caller denies immediate second attempt" 1 !attempts;
    Alcotest.(check int) "existing deferred retry path retains the successor" 1 (List.length !deferred))
    [401;403]
;;

let test_exhausted_access_errors_and_bad_requests_remain_terminal () =
  List.iter (fun code ->
    let denied = access_error_from_http code in
    let attempts = ref [] in
    let result = Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
        attempts := runtime_id :: !attempts; attempt_without_effect (Error denied) None)
      ["first"; "last"] in
    let expected = if code = 400 then ["first"] else ["first"; "last"] in
    Alcotest.(check (list string)) "no candidate beyond the declared suffix"
      expected (List.rev !attempts);
    match result with
    | Error error -> Alcotest.(check string) "original terminal diagnostic retained"
        (Agent_core.Error.to_string denied) (Agent_core.Error.to_string error)
    | Ok _ -> Alcotest.fail "exhausted lane unexpectedly succeeded") [400;401;403]
;;

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
            "attempt input is projected per runtime"
            `Quick
            test_attempt_input_is_projected_per_runtime;
          Alcotest.test_case
            "image fallback restores canonical checkpoint and later vision input"
            `Quick
            test_image_fallback_checkpoint_keeps_canonical_prefix;
          Alcotest.test_case
            "text fallback preserves the current input at both checkpoint boundaries"
            `Quick
            test_current_image_checkpoint_survives_text_fallback;
          Alcotest.test_case
            "deferred lane vision then text projects per candidate"
            `Quick
            test_deferred_lane_vision_then_text_projects_per_candidate;
          Alcotest.test_case
            "deferred lane text then vision projects per candidate"
            `Quick
            test_deferred_lane_text_then_vision_projects_per_candidate;
          Alcotest.test_case
            "AGENT_CORE checkpoint preserves official-client history"
            `Quick
            test_agent_core_checkpoint_preserves_official_client_history;
          Alcotest.test_case
            "text official-client history stays admissible"
            `Quick
            test_text_official_client_history_stays_admissible;
          Alcotest.test_case
            "lane media reroute prefers a lane candidate"
            `Quick
            test_lane_media_reroute_prefers_lane_candidate;
          Alcotest.test_case
            "lane media reroute reaches media_failover"
            `Quick
            test_lane_media_reroute_reaches_media_failover;
          Alcotest.test_case
            "lane media reroute walks past an exhausted candidate"
            `Quick
            test_lane_media_reroute_walks_past_exhausted_candidate;
          Alcotest.test_case
            "a media turn starts from the live walk head"
            `Quick
            test_media_turn_starts_from_the_live_walk_head;
          Alcotest.test_case
            "attempt loop moves past a 402"
            `Quick
            test_attempt_loop_moves_past_payment_required;
          Alcotest.test_case
            "an out-of-lane winner keeps the lane's own preference"
            `Quick
            test_an_out_of_lane_winner_keeps_the_lanes_own_preference;
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
            "deferred tail rejects transformed invalid request cap"
            `Quick
            test_deferred_tail_rejects_transformed_invalid_request_cap;
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
            "actual HTTP 429 preserves unknown scope and disjoint fallback"
            `Quick
            test_http_429_preserves_unknown_scope_and_fallback;
          Alcotest.test_case "rate limit never excludes and success clears" `Quick
            test_rate_limit_order_never_excludes_and_success_clears;
          Alcotest.test_case "rate limit survives only unchanged binding reload" `Quick
            test_rate_limit_candidate_survives_unchanged_reload_only;
          Alcotest.test_case "rate limit identity detects same-reference credential rotation" `Quick
            test_rate_limit_credential_rotation_under_same_reference;
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
            "attempt loop without lane id does not update sticky preference"
            `Quick
            test_attempt_loop_without_lane_id_does_not_update_sticky_preference;
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
            "pre-dispatch refusal reaches the observer as rejected_before_dispatch"
            `Quick
            test_attempt_loop_reports_pre_dispatch_refusal_disposition;
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
          Alcotest.test_case "candidate access denial tries the next runtime" `Quick
            test_candidate_access_denial_reaches_the_next_declared_runtime;
          Alcotest.test_case "access failover preserves effect and caller authority" `Quick
            test_access_failover_preserves_effect_and_caller_authority;
          Alcotest.test_case "access exhaustion and bad requests remain terminal" `Quick
            test_exhausted_access_errors_and_bad_requests_remain_terminal;
          Alcotest.test_case
            "initial lane exhaustion cannot escape declared candidates"
            `Quick
            test_initial_lane_exhaustion_cannot_escape_declared_candidates;
        ] );
    ]
