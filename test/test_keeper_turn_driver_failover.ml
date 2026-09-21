
(* These tests assert on the operator-facing wording, so the typed failure is
   rendered once here instead of at every call below. *)
let load_list_text ~config_path =
  Runtime.load_list ~config_path
  |> Result.map_error (Runtime.to_diagnostic_text ~config_path)
;;

module Runtime_manifest = Masc.Keeper_runtime_manifest
module Driver = Masc.Keeper_turn_driver
module Try_provider = Masc.Keeper_turn_driver_try_provider
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

let collecting_deferral continuation deferred =
  { Driver.continuation; on_deferred = (fun hint -> deferred := hint :: !deferred) }
;;

(* The chat lane's continuation names the operation that would resume; only a
   lane running one can build it. *)
let resume_chat_operation =
  Driver.Resume_operation_checkpoint
    { operation_id =
        (match Keeper_operation_id.of_string "kmsg-walk-under-test" with
         | Ok operation_id -> operation_id
         | Error detail -> failwith detail)
    }
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
max-context = 200000
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
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
max-context = 200000
tools-support = true
streaming = true

[shared_a.test_model]
is-default = true

[shared_b.test_model]

[other.test_model]
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
max-context = 200000
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1
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
max-context = 200000
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
max-context = 200000
tools-support = true
streaming = true

[models.vision_model]
api-name = "vision-model"
max-context = 200000
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

(* A lane that holds two image-capable candidates, with the vision fleet
   ([runtime].media_failover) outside it. *)
let runtime_toml_media_lane_with_two_vision_candidates =
  {|
[runtime]
default = "primary.text_model"
media_failover = [ "outsidevision.vision_model" ]

[runtime.lanes.resilient]
candidates = [ "primary.text_model", "lanevision.vision_model", "backupvision.vision_model" ]

[providers.primary]
display-name = "Primary Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.lanevision]
display-name = "Lane Vision Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[providers.backupvision]
display-name = "Backup Vision Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:4"

[providers.outsidevision]
display-name = "Outside Vision Provider"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:3"

[models.text_model]
api-name = "text-model"
max-context = 200000
tools-support = true
streaming = true

[models.vision_model]
api-name = "vision-model"
max-context = 200000
tools-support = true
streaming = true

[models.vision_model.capabilities]
supports-image-input = true

[primary.text_model]
is-default = true
max-concurrent = 1

[lanevision.vision_model]
max-concurrent = 1

[backupvision.vision_model]
max-concurrent = 1

[outsidevision.vision_model]
max-concurrent = 1
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
max-context = 200000
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
max-context = 200000
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

(* The order the forecast shows is the order the walk takes: the declared
   order, demoted only by quota and backpressure. Nothing is remembered from
   an earlier success, so a lane always starts from its head (#36858). *)
let test_assignment_walk_order_is_the_declared_order () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    let now = Unix.gettimeofday () in
    match Driver.assignment_walk_order ~now "resilient" with
    | Error _ -> Alcotest.fail "the lane resolves"
    | Ok walk ->
      Alcotest.(check string) "the lane" "resilient" walk.Driver.lane_id;
      Alcotest.(check (list string)) "as declared"
        [ "primary.test_model"; "fallback.test_model" ] walk.Driver.declared;
      Alcotest.(check (list string)) "the walk is the declared order"
        [ "primary.test_model"; "fallback.test_model" ] walk.Driver.order)

(* A head under 429 backpressure walks behind its sibling. The declaration
   does not move; only the order does, and it says so (RFC-0457 §3). *)
let test_assignment_walk_order_demotes_a_resting_head () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    let head = Option.get (Runtime.get_runtime_by_id "primary.test_model") in
    Runtime_candidate_backpressure.note_rate_limit
      ~candidate:head.Runtime.candidate_backpressure ~retry_after:None;
    match Driver.assignment_walk_order ~now:(Unix.gettimeofday ()) "resilient" with
    | Error _ -> Alcotest.fail "the lane resolves"
    | Ok walk ->
      Alcotest.(check (list string)) "the declaration is untouched"
        [ "primary.test_model"; "fallback.test_model" ] walk.Driver.declared;
      Alcotest.(check (list string)) "the resting head walks last"
        [ "fallback.test_model"; "primary.test_model" ] walk.Driver.order)

let test_assignment_walk_order_refuses_a_missing_assignment () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Driver.assignment_walk_order ~now:(Unix.gettimeofday ()) "not.configured" with
    | Error Driver.Assignment_missing -> ()
    | Error (Driver.Catalog_unavailable _) -> Alcotest.fail "missing, not unavailable"
    | Ok _ -> Alcotest.fail "an id that names nothing is refused, not walked")

(* A route is a routing label; the binding a turn opens is the lane's entry
   candidate. Callers that need a materialized runtime resolve it here rather
   than handing the label to [get_runtime_by_id], which answers [None] for a
   lane name. *)
let test_entry_runtime_id_resolves_a_route_to_the_binding_it_opens () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    Alcotest.(check (option string))
      "a lane name resolves to its first candidate"
      (Some "primary.test_model")
      (Runtime.entry_runtime_id_of_route "resilient");
    Alcotest.(check (option string))
      "a bare runtime id resolves to itself"
      (Some "primary.test_model")
      (Runtime.entry_runtime_id_of_route "primary.test_model");
    Alcotest.(check (option string))
      "a name that is neither resolves to nothing"
      None
      (Runtime.entry_runtime_id_of_route "no-such-route");
    Alcotest.(check bool)
      "the lane name itself names no binding, which is why this exists"
      true
      (Option.is_none (Runtime.get_runtime_by_id "resilient")))

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
        "the lane walks exactly its declared candidates"
        [ "fallback.test_model" ]
        (Runtime_lane.ordered_candidates lane))

(* A keeper assigned to a runtime that no lane names walks that runtime and
   nothing else. *)
let test_bare_runtime_assignment_walks_only_itself () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    match Runtime.resolve_assignment "fallback.test_model" with
    | `Missing | `Unavailable _ -> Alcotest.fail "expected runtime to resolve"
    | `Lane lane ->
      Alcotest.(check string)
        "lane is named after the runtime it was assigned"
        "fallback.test_model"
        (Runtime_lane.id lane);
      Alcotest.(check (list string))
        "the assigned runtime is the whole walk"
        [ "fallback.test_model" ]
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
max-context = 200000
tools-support = true
streaming = true

[primary.test_model]
is-default = true
max-concurrent = 1

[fallback.test_model]
max-concurrent = 1
|}

(* RFC-0457: [runtime.assignments] targets name a declared lane or a runtime.
   A lane target loads, and the pre-dispatch context budget resolves through
   the lane's entry binding ([entry_runtime_id_of_route]) — the failure the
   old contract refused this config for rather than hit at every turn. *)
let test_assignment_to_lane_id_loads () =
  let path = Filename.temp_file "runtime_failover_lane_assign_" ".toml" in
  write_file path runtime_toml_assignment_to_lane;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
       match load_list_text ~config_path:path with
       | Error msg ->
         Alcotest.failf "a lane-targeted assignment must load: %s" msg
       | Ok (_runtimes, _default, assignments, _media_failover, lanes) ->
         Alcotest.(check (option string))
           "the assignment keeps its lane target" (Some "resilient")
           (List.assoc_opt "canary" assignments);
         Alcotest.(check bool)
           "the named lane is materialized"
           true
           (List.exists
              (fun lane -> String.equal (Runtime_lane.id lane) "resilient")
              lanes))

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
      let decision =
        Driver.For_testing.media_degrade_manifest_decision
          ~runtime_id:first_candidate_id
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
          "the reroute picks the lane's capable candidate"
          "lanevision.vision_model"
          target.Runtime.id
      | Runtime_agent.No_reroute_needed ->
        Alcotest.fail "text-only first candidate should require image reroute"
      | Runtime_agent.No_capable_runtime _ ->
        Alcotest.fail "lane second candidate should be image-capable")

(* An image turn reroutes over its lane only. A lane with no candidate that
   takes the image gets [No_capable_runtime] and walks its own runtime, even
   though [runtime.media_failover] holds an image-capable runtime; a deferred
   lane offers no candidates, because its walk dispatches the frozen suffix
   and would never perform the move. *)
let test_lane_media_reroute_stays_in_lane () =
  with_runtime_config runtime_toml_media_lane_with_global_outside (fun () ->
    let runtime id =
      match Runtime.get_runtime_by_id id with
      | Some runtime -> runtime
      | None -> Alcotest.failf "missing runtime %s" id
    in
    let ids = List.map (fun (runtime : Runtime.t) -> runtime.Runtime.id) in
    let head = runtime "primary.text_model" in
    let image_block =
      Agent_core.Types.Image
        { media_type = "image/png"
        ; data = Base64.encode_string "image"
        ; source_type = Agent_core.Types.Base64
        }
    in
    let candidates remaining_runtimes =
      Driver.For_testing.modality_reroute_candidates
        ~now:(Unix.gettimeofday ())
        ~deferred_runtime_lane:None
        ~first_candidate:head
        ~remaining_runtimes
    in
    Alcotest.(check (list string))
      "the reroute set is the lane"
      [ "primary.text_model"; "lanevision.vision_model" ]
      (ids (candidates [ runtime "lanevision.vision_model" ]));
    let text_only_lane = candidates [] in
    Alcotest.(check (list string))
      "a text-only lane's reroute set holds only its own runtime"
      [ "primary.text_model" ]
      (ids text_only_lane);
    (match
       Driver.For_testing.lane_modality_reroute_decision
         ~checkpoint_messages:[]
         ~initial_messages:[]
         ~goal_blocks:[ image_block ]
         ~first_candidate:head
         ~candidates:text_only_lane
     with
     | Runtime_agent.No_capable_runtime _ -> ()
     | Runtime_agent.Reroute { target; _ } ->
       Alcotest.failf "an image turn left its lane for %s" target.Runtime.id
     | Runtime_agent.No_reroute_needed ->
       Alcotest.fail "a text-only head must not claim the image");
    Alcotest.(check (list string))
      "the turn walks its own runtime and nothing outside the lane"
      [ "primary.text_model" ]
      (ids
         (Driver.For_testing.attempt_runtimes_for_turn
            ~media_walk:
              (Runtime_agent.media_walk ~candidates:text_only_lane [ image_block ])
            ~lane:[ head ]));
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
      (ids
         (Driver.For_testing.modality_reroute_candidates
            ~now:(Unix.gettimeofday ())
            ~deferred_runtime_lane:(Some deferred)
            ~first_candidate:head
            ~remaining_runtimes:[ runtime "lanevision.vision_model" ])))

(* A lane candidate whose account answered a hard quota rejection moves behind
   the live lane candidates, so the reroute picks a live one and the image walk
   visits the exhausted one last. A text turn keeps its lane order. *)
let test_lane_media_reroute_walks_past_exhausted_candidate () =
  with_runtime_config runtime_toml_media_lane_with_two_vision_candidates (fun () ->
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
      let backupvision = runtime "backupvision.vision_model" in
      Runtime_quota_window.note_observed_exhausted
        ~scope:(Runtime.quota_scope_of_runtime lanevision);
      let candidates =
        Driver.For_testing.modality_reroute_candidates
          ~now:(Unix.gettimeofday ())
          ~deferred_runtime_lane:None
          ~first_candidate:head
          ~remaining_runtimes:[ lanevision; backupvision ]
      in
      Alcotest.(check (list string))
        "the exhausted lane candidate moves behind the live one"
        [ "primary.text_model"
        ; "backupvision.vision_model"
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
      (match
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
           "backupvision.vision_model"
           target.Runtime.id
       | Runtime_agent.No_reroute_needed ->
         Alcotest.fail "a text-only head must reroute an image turn"
       | Runtime_agent.No_capable_runtime _ ->
         Alcotest.fail "two image-capable candidates are in the lane");
      let media_walk = Runtime_agent.media_walk ~candidates [ image_block ] in
      Alcotest.(check (list string))
        "the image walk holds the image-capable candidates, live first"
        [ "backupvision.vision_model"; "lanevision.vision_model" ]
        (ids media_walk);
      (* The text-only head is still walked after the image candidates, where
         per-attempt projection turns the image into a reading, so a turn whose
         media candidates all answer 402 degrades instead of ending in an
         error. *)
      Alcotest.(check (list string))
        "the turn walks the live candidate, then the exhausted one, then degrades"
        [ "backupvision.vision_model"
        ; "lanevision.vision_model"
        ; "primary.text_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk
              ~lane:[ head; lanevision; backupvision ]));
      (* The degrade tail keeps the lane's declared order. Stand-ins: the
         function orders by identity, so any three runtimes show it. *)
      Alcotest.(check (list string))
        "text candidates after the image walk keep the declared order"
        [ "lanevision.vision_model"
        ; "primary.text_model"
        ; "backupvision.vision_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk:[ lanevision ]
              ~lane:[ head; lanevision; backupvision ]));
      Alcotest.(check (list string))
        "a text turn keeps the lane order"
        [ "primary.text_model"
        ; "lanevision.vision_model"
        ; "backupvision.vision_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk:
                (Runtime_agent.media_walk ~candidates
                   [ Agent_core.Types.Text "hello" ])
              ~lane:[ head; lanevision; backupvision ]))))

(* An assigned runtime that takes the image itself never reroutes -- the
   decision reads capability, not the account -- so the exhausted head is still
   the head after the decision. The turn must start from the walk anyway, or
   every image turn calls the dead account first while a live lane candidate
   sits behind it. *)
let test_media_turn_starts_from_the_live_walk_head () =
  with_runtime_config runtime_toml_media_lane_with_two_vision_candidates (fun () ->
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
      let backupvision = runtime "backupvision.vision_model" in
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
          ~remaining_runtimes:[ text_only; backupvision ]
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
        [ "backupvision.vision_model"; "lanevision.vision_model" ]
        (ids media_walk);
      Alcotest.(check (list string))
        "the turn starts from the live candidate, not the exhausted head"
        [ "backupvision.vision_model"
        ; "lanevision.vision_model"
        ; "primary.text_model"
        ]
        (ids
           (Driver.For_testing.attempt_runtimes_for_turn
              ~media_walk
              ~lane:[ assigned; text_only; backupvision ]))))

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
  let checkpoint_progress = Atomic.make Try_provider.No_checkpoint_stage in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"resilient"
      ~runtime_id_of:(fun runtime_id -> runtime_id)
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _error ->
        Driver.For_testing.same_run_retry_allowed checkpoint_progress)
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
    (Driver.For_testing.same_run_retry_allowed checkpoint_progress);
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
   last_transient_release=None;context_frontier=None;updated_at=1.}

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
      ~retry_deferral:
        { Driver.continuation = Driver.Restart_cycle
        ; on_deferred = (fun _ -> incr deferred)
        }
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
      ~retry_deferral:(collecting_deferral Driver.Restart_cycle deferred)
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
             ; cause
             }) ->
        Alcotest.(check bool)
          (label ^ " keeps the exact effect disposition")
          true
          (observed = effect_disposition);
        Alcotest.(check bool)
          (label ^ " keeps what failed the attempt")
          true
          (match cause with
           | Keeper_internal_error.Fenced_core core ->
             String.length core.Keeper_request_failure_core.message > 0
           | Keeper_internal_error.Fenced_masc _ -> true)
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

let accept_no_progress_error ~response_shape ~stop_reason scope =
  Driver.core_error_of_masc_internal_error
    (Driver.Accept_rejected
       { scope
       ; model = Some "runtime"
       ; reason_kind = Some Driver.Accept_no_usable_progress
       ; response_shape
       ; stop_reason
       ; reason = "no usable progress"
       })

(* The three answers the accept gate reads as no progress: nothing, thinking
   only, and a reply cut off at the token limit. *)
let no_progress_heads =
  [ ( "empty"
    , accept_no_progress_error
        ~response_shape:(Some Driver.Accept_response_empty)
        ~stop_reason:None )
  ; ( "thinking only"
    , accept_no_progress_error
        ~response_shape:(Some Driver.Accept_response_thinking_only)
        ~stop_reason:None )
  ; ( "truncated"
    , accept_no_progress_error
        ~response_shape:(Some Driver.Accept_response_blank_text_only)
        ~stop_reason:(Some Agent_core.Types.MaxTokens) )
  ]

(* This pins a premise the deletion of the direct-path rotation relies on, not
   code that deletion changed: with that rotation gone, the lane walk is the
   only way a turn reaches another runtime after a head that made no progress.
   If the walk ever stops at the head, the deletion becomes a regression, and
   this test is what breaks.

   With the walk's default gates, a head that made no progress moves the same
   turn to the lane's next candidate. The defaults are what the one production
   caller passes while no checkpoint stage has been reached: [allow_retry] is
   [same_run_retry_allowed], which is true before a checkpoint and false after
   it, and then the head defers to the next keeper cycle instead. *)
let test_attempt_loop_moves_past_no_progress_by_default () =
  List.iter
    (fun (shape, head_error) ->
       Alcotest.(check bool)
         (shape ^ " is a no-progress answer")
         true
         (Driver.For_testing.accept_no_progress_should_try_next
            (head_error "primary.test_model"));
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
               attempt_without_effect (Error (head_error "primary.test_model")) None
             | "fallback.test_model" -> attempt_without_effect (Ok runtime_id) None
             | other -> Alcotest.failf "unexpected candidate %s" other)
           [ "primary.test_model"; "fallback.test_model" ]
       in
       (match result with
        | Ok runtime_id ->
          Alcotest.(check string)
            (shape ^ ": the next lane candidate served")
            "fallback.test_model"
            runtime_id
        | Error err ->
          Alcotest.failf
            "%s: no-progress head ended the walk: %s"
            shape
            (Agent_core.Error.to_string err));
       Alcotest.(check (list string))
         (shape ^ ": the walk tried the head, then the next lane candidate")
         [ "primary.test_model"; "fallback.test_model" ]
         !attempts)
    no_progress_heads

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
    (Llm_provider.Http_client.HttpError
       { code = 429
       ; body = Llm_provider.Http_client.Received body
       ; retry_after_header
       })
;;

let observed_candidate runtime_id =
  let runtime = Option.get (Runtime.get_runtime_by_id runtime_id) in
  Runtime_candidate_backpressure.candidate_backpressure
    ~now:(Unix.gettimeofday ()) ~candidate:runtime.candidate_backpressure
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
         | Some
             { Runtime_candidate_backpressure.rate_limit =
                 Some (Runtime_candidate_backpressure.Unknown_scope_rate_limit { retry_after = None; _ })
             ; failed_attempt = None
             } -> ()
         | Some _ | None ->
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
      Runtime_candidate_backpressure.note_rate_limit ~candidate:runtime.candidate_backpressure
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
    | Some
        { Runtime_candidate_backpressure.rate_limit =
            Some (Runtime_candidate_backpressure.Unknown_scope_rate_limit { retry_after = Some seconds; _ })
        ; failed_attempt = _
        } ->
        Alcotest.(check (float 0.)) "actual HTTP header survives driver ingress" 300. seconds
    | Some _ | None ->
        Alcotest.fail "actual Retry-After hint was lost")
;;

let quota_lane_candidate id =
  (Option.get (Runtime.get_runtime_by_id id)).Runtime.candidate_backpressure
;;

(* Every quota_lane path starts serving: no candidate observation, no quota
   window. *)
let reset_quota_lane_rests () =
  Runtime_quota_window.reset_for_testing ();
  List.iter
    (fun id ->
       Runtime_candidate_backpressure.note_candidate_success ~candidate:(quota_lane_candidate id))
    [ "shared_a.test_model"; "shared_b.test_model"; "other.test_model" ]
;;

let quota_lane_suffix ?(failure = retryable_network_error "previous attempt") = function
  | next_runtime_id :: later_runtime_ids ->
    Driver.For_testing.make_deferred_runtime_lane
      ~assignment_id:"quota_lane" ~failed_runtime_id:"previous.test_model"
      ~next_runtime_id ~later_runtime_ids ~failure
  | [] -> Alcotest.fail "a deferred suffix names at least one path"
;;

let rate_limited_route =
  Keeper_runtime_failure_route.Retry_after_observed
    { retry_class = Keeper_runtime_failure_route.Rate_limited; retry_after = None }
;;

let describe_dispatch ~now = function
  | None -> "no provider wait"
  | Some (Driver.Dispatch_now { runtime_id }) -> "dispatch " ^ runtime_id
  | Some (Driver.Wait_until { release_at; waiting_on; wait }) ->
    Printf.sprintf "wait %.0fs for %s (%s)" (release_at -. now) waiting_on
      (match wait with
       | Driver.Capacity_release -> "capacity"
       | Driver.Path_release -> "path")
;;

let failed_attempt_of runtime_id =
  match observed_candidate runtime_id with
  | Some
      { Runtime_candidate_backpressure.failed_attempt =
          Some (Runtime_candidate_backpressure.Failed_attempt { failure; noted_at = _ })
      ; rate_limit = _
      } -> Some failure
  | Some { Runtime_candidate_backpressure.failed_attempt = None; rate_limit = _ } | None -> None
;;

let attempt_failure : Runtime_candidate_backpressure.attempt_failure option Alcotest.testable =
  Alcotest.testable
    (fun fmt failure ->
       Format.pp_print_string fmt
         (match failure with
          | None -> "none"
          | Some Runtime_candidate_backpressure.Server_error -> "server_error"
          | Some Runtime_candidate_backpressure.Network_transient -> "network_transient"
          | Some Runtime_candidate_backpressure.Provider_timeout -> "provider_timeout"
          | Some Runtime_candidate_backpressure.Access_refused -> "access_refused"))
    ( = )
;;

let walk_once ?provider_answered outcomes ids =
  Driver.For_testing.attempt_runtime_candidates
    ?provider_answered
    ~runtime_id:"quota_lane" ~runtime_id_of:Fun.id
    ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
    ~run_attempt:(fun ~idx:_ ~runtime_id _ -> attempt_without_effect (outcomes runtime_id) None)
    ids
;;

(* RFC-0458 §3.4: a timeout, a server error and a network failure leave the
   same kind of evidence a 429 does, carry no time and make no dispatch wait,
   and an answer from that candidate clears it. Before, the driver recorded
   only 429, 402 and HardQuota, and the next turn led with the dead head. *)
let test_failed_attempts_demote_until_the_candidate_answers () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let ids = ["shared_a.test_model"; "shared_b.test_model"; "other.test_model"] in
      let result =
        walk_once
          (function
            | "shared_a.test_model" ->
              Error (Agent_core.Error.Api
                (Agent_core.Retry.Timeout { message = "no first token"; phase = None }))
            | "shared_b.test_model" ->
              Error (Agent_core.Error.Api
                (Agent_core.Retry.ServerError { status = 503; message = "unavailable" }))
            | "other.test_model" -> Ok ()
            | other -> Alcotest.failf "unexpected candidate %s" other)
          ids
      in
      (match result with
       | Ok () -> ()
       | Error error -> Alcotest.failf "fallback failed: %s" (Agent_core.Error.to_string error));
      Alcotest.check attempt_failure "a timeout is evidence"
        (Some Runtime_candidate_backpressure.Provider_timeout) (failed_attempt_of "shared_a.test_model");
      Alcotest.check attempt_failure "a server error is evidence"
        (Some Runtime_candidate_backpressure.Server_error) (failed_attempt_of "shared_b.test_model");
      Alcotest.check attempt_failure "the candidate that answered holds none"
        None (failed_attempt_of "other.test_model");
      Alcotest.(check (list string)) "the next walk leads with the candidate that answered"
        ["other.test_model"; "shared_a.test_model"; "shared_b.test_model"]
        (backpressure_order ids);
      let now = Unix.gettimeofday () in
      List.iter
        (fun id ->
           match Driver.path_rest ~now id with
           | Driver.Path_serving -> ()
           | Driver.Path_resting _ -> Alcotest.failf "%s: a failed attempt made the path rest" id)
        ["shared_a.test_model"; "shared_b.test_model"];
      let (_ : (unit, Agent_core.Error.t) result) =
        walk_once
          (function
            | "shared_a.test_model" -> Ok ()
            | other -> Alcotest.failf "unexpected candidate %s" other)
          ["shared_a.test_model"]
      in
      Alcotest.check attempt_failure "an answer clears the timeout"
        None (failed_attempt_of "shared_a.test_model");
      Alcotest.(check (list string)) "the answered candidate returns to its declared place"
        ["shared_a.test_model"; "other.test_model"; "shared_b.test_model"]
        (backpressure_order ids)))
;;

(* An attributed empty completion is still an answer from the candidate. It
   must clear stale failure and undated-quota evidence even though the turn
   itself remains an error because it produced no usable assistant content. *)
let test_an_empty_completion_clears_stale_unavailability_evidence () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let id = "shared_a.test_model" in
      let runtime = Option.get (Runtime.get_runtime_by_id id) in
      Runtime_candidate_backpressure.note_failed_attempt
        ~candidate:runtime.candidate_backpressure
        ~failure:Runtime_candidate_backpressure.Provider_timeout;
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:runtime.candidate_backpressure ~retry_after:None;
      let scope = Option.get (Runtime.quota_scope_of_runtime_id id) in
      Runtime_quota_window.note_observed_exhausted ~scope;
      let error =
        Agent_core.Error.Provider
          (Llm_provider.Error.EmptyCompletion
             { provider = "openrouter"
             ; stop_reason = Llm_provider.Types.MaxTokens
             ; detail = "empty assistant turn"
             })
      in
      let result = walk_once (fun _ -> Error error) [ id ] in
      (match result with
       | Error _ -> ()
       | Ok () -> Alcotest.fail "an empty completion unexpectedly succeeded");
      Alcotest.(check bool) "the stale candidate evidence is cleared" true
        (Option.is_none (observed_candidate id));
      Alcotest.(check bool) "the undated quota observation is cleared" false
        (Runtime_quota_window.is_exhausted ~scope ~now:(Unix.gettimeofday ()))))
;;
(* An HTTP access denial already rotates within its Tick. Retaining the typed
   route as candidate evidence prevents the next Tick from paying for the same
   known refusal again. It remains ordering evidence: the path still serves,
   and one later answer restores declared order. *)
let test_access_refusal_demotes_until_the_candidate_answers () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let refused = "shared_a.test_model" and fallback = "shared_b.test_model" in
      let ids = [ refused; fallback ] in
      let attempts = ref [] in
      let access_refusal =
        Agent_core.Provider_failure_attribution.core_error_of_http_error
          ~provider:"candidate-access-fixture"
          (Llm_provider.Http_client.HttpError
             { code = 403
             ; body = Llm_provider.Http_client.Received "arbitrary provider denial"
             ; retry_after_header = None
             })
      in
      let result =
        walk_once
          (fun runtime_id ->
             attempts := runtime_id :: !attempts;
             if String.equal runtime_id refused
             then Error access_refusal
             else Ok ())
          ids
      in
      (match result with
       | Ok () -> ()
       | Error error ->
         Alcotest.failf "access fallback failed: %s" (Agent_core.Error.to_string error));
      Alcotest.(check (list string)) "the first Tick rotates within the declared lane"
        ids (List.rev !attempts);
      Alcotest.check attempt_failure "the actual HTTP 403 is retained as typed evidence"
        (Some Runtime_candidate_backpressure.Access_refused) (failed_attempt_of refused);
      Alcotest.(check (list string)) "the next Tick leads with the available sibling"
        [ fallback; refused ] (backpressure_order ids);
      (match Driver.path_rest ~now:(Unix.gettimeofday ()) refused with
       | Driver.Path_serving -> ()
       | Driver.Path_resting _ -> Alcotest.fail "access evidence made the path wait");
      let (_ : (unit, Agent_core.Error.t) result) =
        walk_once (fun _ -> Ok ()) [ refused ]
      in
      Alcotest.check attempt_failure "an answer clears the access refusal"
        None (failed_attempt_of refused);
      Alcotest.(check (list string)) "the answered candidate returns to declared order"
        ids (backpressure_order ids)))
;;
(* The evidence follows the failure route. A closed runtime connection is
   routed as a server error, so it is evidence; MASC's own capacity, a
   candidate that answered badly, and a failure of the turn's input are not
   facts about the candidate. *)
let test_only_the_candidates_own_failures_are_evidence () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let one id error =
        let (_ : (unit, Agent_core.Error.t) result) =
          walk_once (fun _ -> Error error) [id]
        in
        failed_attempt_of id
      in
      Alcotest.check attempt_failure "a closed runtime connection"
        (Some Runtime_candidate_backpressure.Server_error)
        (one "shared_a.test_model"
           (Keeper_internal_error.core_error_of_masc_internal_error
              (Keeper_internal_error.Runtime_connection_closed
                 { runtime_id = "shared_a.test_model"; detail = "stdout closed"; turn_accepted = true })));
      Alcotest.check attempt_failure "a network failure"
        (Some Runtime_candidate_backpressure.Network_transient)
        (one "shared_b.test_model" (retryable_network_error "connection refused"));
      reset_quota_lane_rests ();
      Alcotest.check attempt_failure "a provider that sent no first token"
        (Some Runtime_candidate_backpressure.Provider_timeout)
        (one "shared_a.test_model"
           (Agent_core.Error.Provider
              (Llm_provider.Error.Timeout
                 { provider = "shared_a"
                 ; timeout_phase = Some Llm_provider.Http_client.First_token
                 ; detail = "no first token"
                 })));
      reset_quota_lane_rests ();
      List.iter
        (fun (label, error) ->
           Alcotest.check attempt_failure label None (one "other.test_model" error);
           Alcotest.(check bool) (label ^ " leaves no rate limit either") true
             (Option.is_none (observed_candidate "other.test_model")))
        [ "a permit that MASC's own queue never granted"
        , Agent_core.Error.Provider
            (Llm_provider.Error.Timeout
               { provider = "other"
               ; timeout_phase = Some Llm_provider.Http_client.Queue
               ; detail = "no admission permit"
               })
        ; "local capacity that expired before sending"
        , Agent_core.Error.Api
            (Agent_core.Retry.Timeout
               { message = "capacity"; phase = Some Llm_provider.Http_client.Capacity_backpressure })
        ; "provider overload is MASC-side capacity"
        , Agent_core.Error.Api (Agent_core.Retry.Overloaded { message = "overloaded" })
        ; "a model the provider does not know rotates"
        , Agent_core.Error.Api (Agent_core.Retry.NotFound { message = "no such model" })
        ; "a context overflow is the turn's input"
        , Agent_core.Error.Api
            (Agent_core.Retry.ContextOverflow { message = "too long"; limit = None })
        ]))
;;

(* An attempt that yielded before its first token never heard from the
   candidate, so it must not clear evidence that it was down. *)
let test_a_yield_before_the_first_token_clears_no_evidence () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let id = "shared_a.test_model" in
      let runtime = Option.get (Runtime.get_runtime_by_id id) in
      Runtime_candidate_backpressure.note_failed_attempt
        ~candidate:runtime.candidate_backpressure
        ~failure:Runtime_candidate_backpressure.Provider_timeout;
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:runtime.candidate_backpressure ~retry_after:None;
      let scope = Option.get (Runtime.quota_scope_of_runtime_id id) in
      Runtime_quota_window.note_observed_exhausted ~scope;
      let (_ : (unit, Agent_core.Error.t) result) =
        walk_once ~provider_answered:(fun () -> false) (fun _ -> Ok ()) [id]
      in
      Alcotest.(check bool) "the observed quota survives the yield" true
        (Runtime_quota_window.is_exhausted ~scope ~now:(Unix.gettimeofday ()));
      Alcotest.check attempt_failure "the timeout survives the yield"
        (Some Runtime_candidate_backpressure.Provider_timeout) (failed_attempt_of id);
      Alcotest.(check bool) "the rate limit survives the yield" true
        (match observed_candidate id with
         | Some { Runtime_candidate_backpressure.rate_limit = Some _; failed_attempt = _ } -> true
         | Some { Runtime_candidate_backpressure.rate_limit = None; failed_attempt = _ } | None -> false)))
;;

(* The review of this change found a failed path waiting for a resting one:
   with the failed attempt behind a path told to rest, the next dispatch waited
   for that head's release though the failed path could serve now. *)
let test_a_path_that_only_failed_walks_before_one_told_to_rest () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let resting = "shared_a.test_model" and failed = "other.test_model" in
      Runtime_quota_window.note_observed_exhausted
        ~scope:(Option.get (Runtime.quota_scope_of_runtime_id resting));
      Runtime_candidate_backpressure.note_failed_attempt
        ~candidate:(quota_lane_candidate failed)
        ~failure:Runtime_candidate_backpressure.Provider_timeout;
      Alcotest.(check (list string)) "the failed path walks before the resting one"
        [ failed; resting ]
        (backpressure_order [ resting; failed ]);
      let now = Unix.gettimeofday () in
      Alcotest.(check string) "and the next dispatch goes to it now"
        ("dispatch " ^ failed)
        (describe_dispatch ~now
           (Driver.next_dispatch_after_failure ~now ~route:rate_limited_route
              ~assignment_id:"quota_lane" (Some (quota_lane_suffix [ resting; failed ]))))))
;;

(* 402 still records through the route: the credential's quota window. *)
let test_payment_required_still_exhausts_the_quota_scope () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let id = "other.test_model" in
      let (_ : (unit, Agent_core.Error.t) result) =
        walk_once
          (fun _ -> Error (Agent_core.Error.Api (Agent_core.Retry.PaymentRequired { message = "pay" })))
          [ id ]
      in
      Alcotest.(check bool) "the quota scope is exhausted" true
        (Runtime_quota_window.is_exhausted
           ~scope:(Option.get (Runtime.quota_scope_of_runtime_id id))
           ~now:(Unix.gettimeofday ()))))
;;

(* A hint that names no time -- zero, negative, NaN -- must not be planted as
   a reset: that window is already over, and it replaces the observation the
   scope was carrying, leaving an exhausted account looking available. *)
let test_a_quota_hint_that_names_no_time_is_recorded_as_observed () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    List.iter
      (fun retry_after ->
         reset_quota_lane_rests ();
         let id = "other.test_model" in
         let (_ : (unit, Agent_core.Error.t) result) =
           walk_once
             (fun _ ->
                Error
                  (Agent_core.Error.Provider
                     (Llm_provider.Error.HardQuota
                        { provider = "other"; retry_after; detail = "out of credit" })))
             [ id ]
         in
         Alcotest.(check bool)
           (match retry_after with
            | None -> "no hint"
            | Some hint -> Printf.sprintf "a hint of %.1f" hint)
           true
           (Runtime_quota_window.is_exhausted
              ~scope:(Option.get (Runtime.quota_scope_of_runtime_id id))
              ~now:(Unix.gettimeofday () +. 1.0)))
      [ None; Some 0.0; Some (-30.0); Some Float.nan ];
    reset_quota_lane_rests ())
;;

let test_the_production_answer_test_reads_provider_turns () =
  let yielded = Runtime_agent.yielded_pre_first_token ~session_id:"session" in
  Alcotest.(check bool) "a pre-first-token yield did not hear the candidate" false
    (Driver.For_testing.run_result_answered yielded);
  Alcotest.(check bool) "a yield after a provider turn did" true
    (Driver.For_testing.run_result_answered
       { yielded with stop_reason = Runtime_agent.Yielded_to_durable_stimulus { turns_used = 1 } });
  Alcotest.(check bool) "a completed run did" true
    (Driver.For_testing.run_result_answered
       { yielded with stop_reason = Runtime_agent.Completed })
;;

(* RFC-provider-path-rest §3.3 and #34653: the head of a deferred suffix in
   walk order decides whether a failed cycle waits. A serving head takes the
   input at once. A resting head waits until the next turn's head can serve,
   and that wait does not serve a wakeup before it ends, so a stimulus arriving
   meanwhile cannot re-dispatch a resting path. *)
let test_a_deferred_suffix_waits_only_while_its_walk_head_rests () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      reset_quota_lane_rests ();
      let now = Unix.gettimeofday () in
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate "shared_a.test_model") ~retry_after:(Some 300.);
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate "shared_b.test_model") ~retry_after:(Some 120.);
      let describe = function
        | Driver.Walk_head_serving { runtime_id } -> "serving " ^ runtime_id
        | Driver.Walk_waits_until { release_at; resting_runtime_id } ->
          Printf.sprintf "resting %s for %.0fs" resting_runtime_id (release_at -. now)
      in
      let all_three = [ "shared_a.test_model"; "shared_b.test_model"; "other.test_model" ] in
      let both_shared = [ "shared_a.test_model"; "shared_b.test_model" ] in
      Alcotest.(check string) "a serving head in walk order takes the input"
        "serving other.test_model"
        (describe (Driver.deferred_lane_rest ~now (quota_lane_suffix all_three)));
      Alcotest.(check string) "a resting head waits for the earliest promoted release"
        "resting shared_b.test_model for 120s"
        (describe (Driver.deferred_lane_rest ~now (quota_lane_suffix both_shared)));
      Runtime_quota_window.note_exhausted
        ~scope:(Option.get (Runtime.quota_scope_of_runtime_id "other.test_model"))
        ~resets_at:(now +. 30.);
      Alcotest.(check string) "a stated quota reset is a release too"
        "resting other.test_model for 30s"
        (describe (Driver.deferred_lane_rest ~now (quota_lane_suffix all_three)));
      (* An unstated rest ends the wait but not the demotion, so the walk keeps
         that path behind the resting head: waiting for its shorter release
         would dispatch the head while it still rests. *)
      Runtime_candidate_backpressure.note_candidate_success
        ~candidate:(quota_lane_candidate "shared_b.test_model");
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate "shared_b.test_model") ~retry_after:None;
      Alcotest.(check string) "an unstated rest behind the head does not shorten the wait"
        "resting shared_a.test_model for 300s"
        (describe (Driver.deferred_lane_rest ~now (quota_lane_suffix both_shared)));
      let decision =
        Masc.Keeper_heartbeat_loop.For_testing.after_failure
          ~now
          ~assignment_id:"quota_lane"
          { Masc.Keeper_unified_turn.error = retryable_network_error "rate limited"
          ; runtime_id = "previous.test_model"
          ; route = rate_limited_route
          ; source_disposition = Masc.Keeper_unified_turn.Follow_failure_route
          ; deferred_runtime_lane = Some (quota_lane_suffix both_shared)
          }
      in
      let waits_without_serving_a_wakeup =
        match decision with
        | Some
            (Masc.Keeper_heartbeat_loop.Wait_for_path_release
               { wake_policy = Masc.Keeper_keepalive_signal.Serve_wakeup_after_duration
               ; release_at = _
               ; waiting_on = _
               }) ->
          true
        | Some
            (Masc.Keeper_heartbeat_loop.Wait_for_path_release
               { wake_policy = Masc.Keeper_keepalive_signal.Interrupt_on_wakeup; _ })
        | Some (Masc.Keeper_heartbeat_loop.Continue_on_deferred_lane _)
        | None ->
          false
      in
      Alcotest.(check bool) "a failed cycle whose walk head rests waits without serving a wakeup"
        true waits_without_serving_a_wakeup))
;;

(* A failure without a suffix used every path the input may take. Its wait
   covers the failed path's own rest and never ends before a fresh walk of the
   assignment can start on a serving head: with A resting 600 s and B failing
   on an unstated 429, the walk still starts on A, so B's 60 s is not enough. *)
let test_a_failure_without_a_suffix_waits_until_a_fresh_walk_head_serves () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      reset_quota_lane_rests ();
      let now = Unix.gettimeofday () in
      let floor_sec = Env_config_keeper.KeeperKeepalive.rate_limit_backoff_floor_sec in
      let decide () =
        describe_dispatch ~now
          (Driver.next_dispatch_after_failure
             ~now ~route:rate_limited_route ~assignment_id:"quota_lane" None)
      in
      Alcotest.(check string) "a serving fresh walk head waits only for the failed path"
        (Printf.sprintf "wait %.0fs for quota_lane (path)" floor_sec)
        (decide ());
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate "shared_a.test_model") ~retry_after:(Some 600.);
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate "shared_b.test_model") ~retry_after:None;
      Runtime_quota_window.note_exhausted
        ~scope:(Option.get (Runtime.quota_scope_of_runtime_id "other.test_model"))
        ~resets_at:(now +. 900.);
      Alcotest.(check string) "a resting fresh walk head extends the wait to its release"
        "wait 600s for shared_a.test_model (path)"
        (decide ())))
;;

(* RFC-provider-path-rest §3.4: the chat lane's deferred retry reads the same
   next dispatch as the heartbeat. A suffix whose walk head serves is claimable
   at once; a resting head holds the retry until its release; capacity
   backpressure holds it for its own rest whatever the suffix is. *)
let test_a_chat_retry_follows_the_shared_next_dispatch () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    Fun.protect ~finally:Runtime_quota_window.reset_for_testing (fun () ->
      reset_quota_lane_rests ();
      let now = Unix.gettimeofday () in
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate "shared_a.test_model") ~retry_after:(Some 300.);
      let not_before lane =
        match Masc.Keeper_direct_runtime_continuation.For_testing.retry_not_before ~now lane with
        | None -> "claimable now"
        | Some at -> Printf.sprintf "claimable in %.0fs" (at -. now)
      in
      let rate_limited =
        Agent_core.Error.Provider
          (Llm_provider.Error.RateLimit
             { provider = "shared_a"; retry_after = None; detail = "rate limited" })
      in
      let capacity =
        Agent_core.Error.Provider
          (Llm_provider.Error.CapacityExhausted
             { scope = Llm_provider.Error.CapacityUnknown
             ; affected = []
             ; retry_after = Some 5.0
             ; detail = "pool saturated"
             })
      in
      Alcotest.(check string) "a serving walk head is claimable at once"
        "claimable now"
        (not_before
           (quota_lane_suffix ~failure:rate_limited
              [ "shared_a.test_model"; "other.test_model" ]));
      Alcotest.(check string) "a resting walk head holds the retry until its release"
        "claimable in 300s"
        (not_before (quota_lane_suffix ~failure:rate_limited [ "shared_a.test_model" ]));
      Alcotest.(check string) "capacity backpressure holds the retry for its own rest"
        "claimable in 5s"
        (not_before (quota_lane_suffix ~failure:capacity [ "other.test_model" ]))))
;;

let test_rate_limit_candidate_survives_unchanged_reload_only () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    let old = Option.get (Runtime.get_runtime_by_id "shared_a.test_model") in
    let attempt runtime reload =
      let result = Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"quota_lane" ~runtime_id_of:(fun (rt : Runtime.t) -> rt.id)
        ~quota_scope_of:(fun rt -> Some (Runtime.quota_scope_of_runtime rt))
        ~candidate_backpressure_of:(fun (rt : Runtime.t) -> Some rt.candidate_backpressure)
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
      (Option.is_some (Runtime_candidate_backpressure.candidate_backpressure
        ~now:(Unix.gettimeofday ()) ~candidate:old.candidate_backpressure));
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
          ~candidate_backpressure_of:(fun (rt : Runtime.t) -> Some rt.candidate_backpressure)
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
          (Option.is_some (Runtime_candidate_backpressure.candidate_backpressure
            ~now:(Unix.gettimeofday ()) ~candidate:old.candidate_backpressure));
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

(* A success leaves no trace on the walk: the next assignment_walk_order is
   the declared order whichever candidate served the previous turn. *)
let test_a_success_leaves_the_next_walk_declared () =
  with_runtime_config runtime_toml_with_lane (fun () ->
    let events = ref [] in
    let result =
      Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"resilient"
        ~runtime_id_of:(fun runtime_id -> runtime_id)
        ~emit_runtime_manifest:(emit_manifest_collector events)
        ~run_attempt:(fun ~idx:_ ~runtime_id _candidate ->
          attempt_without_effect (Ok runtime_id) None)
        [ "fallback.test_model" ]
    in
    (match result with
     | Ok runtime_id ->
       Alcotest.(check string) "the fallback served the turn"
         "fallback.test_model" runtime_id
     | Error e ->
       Alcotest.failf "expected candidate success, got %s"
         (Agent_core.Error.to_string e));
    match Driver.assignment_walk_order ~now:(Unix.gettimeofday ()) "resilient" with
    | Error _ -> Alcotest.fail "the lane resolves"
    | Ok walk ->
      Alcotest.(check (list string)) "the next walk starts from the declared head"
        [ "primary.test_model"; "fallback.test_model" ] walk.Driver.order)

let test_typed_checkpoint_is_the_same_run_retry_authority () =
  let stages =
    [ Agent_core.Agent.After_assistant_collected
    ; Agent_core.Agent.After_tool_results_appended
    ; Agent_core.Agent.After_context_injection
    ; Agent_core.Agent.After_rejected_response_dropped
    ]
  in
  List.iter
    (fun stage ->
       let attempts = ref [] in
       let events = ref [] in
       let checkpoint_progress = Atomic.make Try_provider.No_checkpoint_stage in
       Driver.For_testing.observe_checkpoint_stage checkpoint_progress stage;
       let primary_error = retryable_network_error "response-stage failure" in
       let result =
         Driver.For_testing.attempt_runtime_candidates
           ~runtime_id:"resilient"
           ~runtime_id_of:(fun runtime_id -> runtime_id)
           ~emit_runtime_manifest:(emit_manifest_collector events)
           ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _error ->
             Driver.For_testing.same_run_retry_allowed checkpoint_progress)
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

(* A generation that repeated itself is the model's failure, not the
   provider's: the same model behind another provider repeats the same way.
   After the repeat the walk refuses every later candidate on that model
   before dispatch and lands on a different model. *)
let repeating_generation_error ~provider =
  Agent_core.Error.Provider
    (Llm_provider.Error.RepeatingGeneration
       { provider
       ; shape = Llm_provider.Types.Repeated_reasoning_cycle
       ; occurrences = 3
       ; unit_bytes = 749
       ; detail = "reasoning repeated one 749-byte unit 3 times verbatim"
       })

let flash_or_plus = function
  | "ollama_cloud.flash" | "glm_coding.flash" -> Some "glm-5.3-flash"
  | "glm_coding.plus" -> Some "glm-5.3"
  | other -> Alcotest.failf "unexpected candidate %s" other

let test_repeating_generation_leaves_the_model_not_only_the_provider () =
  let attempt_errors = ref [] in
  let refusal = ref None in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"lane.glm"
      ~runtime_id_of:Fun.id
      ~model_of:flash_or_plus
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_attempt_error:(fun ~runtime_id ~attempt ~dispatch error ->
        if runtime_id = "glm_coding.flash" then refusal := Some error;
        attempt_errors := !attempt_errors @ [ runtime_id, attempt, dispatch ])
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
        match candidate with
        | "ollama_cloud.flash" ->
          attempt_without_effect
            (Error (repeating_generation_error ~provider:"ollama_cloud"))
            None
        | "glm_coding.flash" ->
          Alcotest.fail "the same model behind another provider must not be dispatched"
        | "glm_coding.plus" -> attempt_without_effect (Ok (completed_run_result ())) None
        | other -> Alcotest.failf "unexpected candidate %s" other)
      [ "ollama_cloud.flash"; "glm_coding.flash"; "glm_coding.plus" ]
  in
  (match result with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "the different model must serve the turn, got %s" (Agent_core.Error.to_string e));
  Alcotest.(check (list (triple string int dispatch_disposition)))
    "the repeat is the dispatched candidate's answer; the same model is refused before dispatch"
    [ "ollama_cloud.flash", 0, Masc.Keeper_attempt_dispatch.Dispatched
    ; "glm_coding.flash", 1, Masc.Keeper_attempt_dispatch.Rejected_before_dispatch
    ]
    !attempt_errors;
  match !refusal with
  | Some
      (Agent_core.Error.Api
         (Agent_core.Retry.InvalidRequest
            { reason = Agent_core.Retry.Attempt_rejected; message })) ->
    Alcotest.(check bool) "the refusal names the model and where it repeated" true
      (contains ~needle:"glm-5.3-flash" message
       && contains ~needle:"ollama_cloud.flash" message)
  | Some e -> Alcotest.failf "the refusal must be a typed pre-dispatch rejection, got %s" (Agent_core.Error.to_string e)
  | None -> Alcotest.fail "the refused candidate must reach the attempt observer"

(* When every remaining candidate runs the model that repeated, the lane's
   error is the repeat that was observed, not the walk's own refusal. *)
let test_repeat_on_the_only_model_reports_the_repeat () =
  let lane_terminal = ref None in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"lane.flash-only"
      ~runtime_id_of:Fun.id
      ~model_of:flash_or_plus
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_lane_terminal_error:(fun terminal -> lane_terminal := Some terminal)
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
        match candidate with
        | "ollama_cloud.flash" ->
          attempt_without_effect
            (Error (repeating_generation_error ~provider:"ollama_cloud"))
            None
        | other -> Alcotest.failf "candidate %s must not be dispatched" other)
      [ "ollama_cloud.flash"; "glm_coding.flash" ]
  in
  (match result with
   | Error (Agent_core.Error.Provider (Llm_provider.Error.RepeatingGeneration { provider; _ })) ->
     Alcotest.(check string) "the lane reports the observed repeat" "ollama_cloud" provider
   | Error e -> Alcotest.failf "expected the observed repeat, got %s" (Agent_core.Error.to_string e)
   | Ok _ -> Alcotest.fail "no candidate could serve the turn");
  match !lane_terminal with
  | None -> Alcotest.fail "the lane must report which candidate's error it returned"
  | Some (terminal : Driver.lane_terminal_error) ->
    Alcotest.(check (pair string int))
      "the lane error originates from the candidate that repeated"
      ("ollama_cloud.flash", 0)
      (terminal.origin_runtime_id, terminal.origin_attempt)

(* The live runtime.toml declares one [models.*] row per provider for the same
   model, so their ids differ while the served name is the same. The default
   identity reads the registry's api-name: the walk leaves "glm-5.3-flash"
   behind whichever id the second provider gave it, and lands on the
   candidate whose served name differs. *)
let runtime_toml_same_model_twice =
  {|
[runtime]
default = "ollama_cloud.ollama-cloud-flash"

[runtime.lanes.glm]
candidates = [ "ollama_cloud.ollama-cloud-flash", "glm_coding.flash", "glm_coding.plus" ]

[providers.ollama_cloud]
display-name = "Ollama Cloud"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:1"

[providers.glm_coding]
display-name = "GLM Coding"
protocol = "openai-compatible-http"
endpoint = "http://127.0.0.1:2"

[models.ollama-cloud-flash]
api-name = "glm-5.3-flash"
max-context = 200000
tools-support = true
streaming = true

[models.flash]
api-name = "glm-5.3-flash"
max-context = 200000
tools-support = true
streaming = true

[models.plus]
api-name = "glm-5.3"
max-context = 200000
tools-support = true
streaming = true

[ollama_cloud.ollama-cloud-flash]
is-default = true
max-concurrent = 1

[glm_coding.flash]
max-concurrent = 1

[glm_coding.plus]
max-concurrent = 1
|}

let test_registry_identity_is_the_served_name_not_the_model_id () =
  with_runtime_config runtime_toml_same_model_twice (fun () ->
    let dispatched = ref [] in
    let result =
      Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"glm"
        ~runtime_id_of:Fun.id
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
          dispatched := !dispatched @ [ candidate ];
          match candidate with
          | "ollama_cloud.ollama-cloud-flash" ->
            attempt_without_effect
              (Error (repeating_generation_error ~provider:"ollama_cloud"))
              None
          | "glm_coding.plus" -> attempt_without_effect (Ok (completed_run_result ())) None
          | other -> Alcotest.failf "candidate %s must not be dispatched" other)
        [ "ollama_cloud.ollama-cloud-flash"; "glm_coding.flash"; "glm_coding.plus" ]
    in
    (match result with
     | Ok _ -> ()
     | Error e -> Alcotest.failf "the differently named model must serve the turn, got %s" (Agent_core.Error.to_string e));
    Alcotest.(check (list string))
      "the second provider's row for the same served name is never dispatched"
      [ "ollama_cloud.ollama-cloud-flash"; "glm_coding.plus" ]
      !dispatched)

(* A refused tail does not get to speak over what the walk saw before it:
   an overflow observed anywhere in the rotation still outranks the repeat
   (#26530), so the failure route reaches the compaction path. *)
let test_overflow_seen_before_a_repeat_outranks_the_refused_tail () =
  let lane_terminal = ref None in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"lane.overflow-then-repeat"
      ~runtime_id_of:Fun.id
      ~model_of:(function
        | "wide.plus" -> Some "glm-5.3"
        | "ollama_cloud.flash" | "glm_coding.flash" -> Some "glm-5.3-flash"
        | other -> Alcotest.failf "unexpected candidate %s" other)
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~on_lane_terminal_error:(fun terminal -> lane_terminal := Some terminal)
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
        match candidate with
        | "wide.plus" ->
          attempt_without_effect
            (Error
               (Agent_core.Error.Api
                  (Agent_core.Retry.ContextOverflow
                     { message = "prompt exceeds the window"; limit = Some 32768 })))
            None
        | "ollama_cloud.flash" ->
          attempt_without_effect
            (Error (repeating_generation_error ~provider:"ollama_cloud"))
            None
        | other -> Alcotest.failf "candidate %s must not be dispatched" other)
      [ "wide.plus"; "ollama_cloud.flash"; "glm_coding.flash" ]
  in
  (match result with
   | Error (Agent_core.Error.Api (Agent_core.Retry.ContextOverflow { limit = Some 32768; _ })) -> ()
   | Error e -> Alcotest.failf "the observed overflow must outrank the repeat, got %s" (Agent_core.Error.to_string e)
   | Ok _ -> Alcotest.fail "no candidate could serve the turn");
  match !lane_terminal with
  | None -> Alcotest.fail "the lane must report which candidate's error it returned"
  | Some (terminal : Driver.lane_terminal_error) ->
    Alcotest.(check (pair string int))
      "the lane error originates from the overflowing candidate"
      ("wide.plus", 0)
      (terminal.origin_runtime_id, terminal.origin_attempt)

(* When the same-run retry is denied after a repeat, the next cycle starts
   from the deferred hint with no memory of this walk. The hint therefore
   names no candidate on the model that repeated; with no other model left,
   there is no hint at all. *)
let test_deferred_hint_after_a_repeat_names_a_different_model () =
  let walk candidates =
    let deferred = ref [] in
    let result =
      Driver.For_testing.attempt_runtime_candidates
        ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ -> false)
        ~retry_deferral:(collecting_deferral Driver.Restart_cycle deferred)
        ~runtime_id:"lane.glm"
        ~runtime_id_of:Fun.id
        ~model_of:flash_or_plus
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
          match candidate with
          | "ollama_cloud.flash" ->
            attempt_without_effect
              (Error (repeating_generation_error ~provider:"ollama_cloud"))
              None
          | other -> Alcotest.failf "candidate %s must not be dispatched" other)
        candidates
    in
    (match result with
     | Error (Agent_core.Error.Provider (Llm_provider.Error.RepeatingGeneration _)) -> ()
     | Error e -> Alcotest.failf "the denied walk ends on the repeat, got %s" (Agent_core.Error.to_string e)
     | Ok _ -> Alcotest.fail "the same-run retry was denied");
    List.rev !deferred
  in
  (match walk [ "ollama_cloud.flash"; "glm_coding.flash"; "glm_coding.plus" ] with
   | [ hint ] ->
     Alcotest.(check (list string))
       "the hint skips the same model and names the different one"
       [ "glm_coding.plus" ]
       (Driver.deferred_runtime_ids hint)
   | hints -> Alcotest.failf "expected one deferred hint, got %d" (List.length hints));
  Alcotest.(check int)
    "no different model left means no hint"
    0
    (List.length (walk [ "ollama_cloud.flash"; "glm_coding.flash" ]))

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
      ~retry_deferral:(collecting_deferral Driver.Restart_cycle deferred)
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
      ~retry_deferral:(collecting_deferral Driver.Restart_cycle deferred)
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
      ~retry_deferral:(collecting_deferral Driver.Restart_cycle deferred)
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


let progress_snapshot stage =
  { Agent_core.Agent.stage
  ; turn = 1
  ; timestamp = 1.
  ; checkpoint =
      Masc.Keeper_context_runtime.checkpoint_of_context
        (Masc.Keeper_context_runtime.create ~eio:false ~system_prompt:"progress")
  }
;;

let progress_label = function
  | Try_provider.No_checkpoint_stage -> "no checkpoint stage"
  | Try_provider.Checkpoint_stage_reached -> "checkpoint stage reached"
  | Try_provider.Tool_results_saved -> "tool results saved"
;;

(* RFC last-path-resumes-after-progress §3.2: reaching a stage ends same-run
   retry whatever the sink answers, and only the sink's owner marks the tool
   results it actually wrote. A sink answers [Ok ()] for a write it skipped as
   well ([Keeper_checkpoint_store.Stale_noop]), so the wrapper never reads
   progress out of that answer. *)
let test_a_sink_answer_is_not_progress () =
  let sinks =
    [ "no sink", None, Ok ()
    ; "a save that answers Ok", Some (fun _ -> Ok ()), Ok ()
    ; "a save that fails", Some (fun _ -> Error "disk full"), Error "disk full"
    ]
  in
  List.iter
    (fun stage ->
       List.iter
         (fun (sink_label, sink, answer) ->
            let progress = Atomic.make Try_provider.No_checkpoint_stage in
            let returned =
              Driver.For_testing.observing_checkpoint_sink progress sink (progress_snapshot stage)
            in
            let label =
              Agent_core.Agent.checkpoint_stage_to_string stage ^ " with " ^ sink_label
            in
            Alcotest.(check (result unit string)) (label ^ ": the sink's answer passes through")
              answer returned;
            Alcotest.(check string) label
              (progress_label Try_provider.Checkpoint_stage_reached)
              (progress_label (Atomic.get progress));
            Alcotest.(check bool) (label ^ ": no same-run retry") false
              (Driver.For_testing.same_run_retry_allowed progress);
            Alcotest.(check bool) (label ^ ": no tool results") false
              (Driver.For_testing.tool_results_saved progress))
         sinks)
    [ Agent_core.Agent.After_assistant_collected
    ; Agent_core.Agent.After_tool_results_appended
    ; Agent_core.Agent.After_context_injection
    ; Agent_core.Agent.After_rejected_response_dropped
    ]
;;

(* What the owner marks: a stage written after tools ran counts, the answer
   stages do not, and a later answer stage does not erase it. *)
let test_the_sink_owner_marks_written_tool_results () =
  List.iter
    (fun (stage, counts) ->
       let progress = Atomic.make Try_provider.No_checkpoint_stage in
       Driver.For_testing.observe_checkpoint_saved progress stage;
       Alcotest.(check string)
         (Agent_core.Agent.checkpoint_stage_to_string stage)
         (progress_label
            (if counts then Try_provider.Tool_results_saved else Try_provider.No_checkpoint_stage))
         (progress_label (Atomic.get progress)))
    [ Agent_core.Agent.After_tool_results_appended, true
    ; Agent_core.Agent.After_context_injection, true
    ; Agent_core.Agent.After_assistant_collected, false
    ; Agent_core.Agent.After_rejected_response_dropped, false
    ];
  let progress = Atomic.make Try_provider.No_checkpoint_stage in
  Driver.For_testing.observe_checkpoint_saved progress Agent_core.Agent.After_tool_results_appended;
  let (_ : (unit, string) result) =
    Driver.For_testing.observing_checkpoint_sink
      progress
      (Some (fun _ -> Ok ()))
      (progress_snapshot Agent_core.Agent.After_assistant_collected)
  in
  Alcotest.(check string) "a later answer stage keeps the written tool results"
    (progress_label Try_provider.Tool_results_saved)
    (progress_label (Atomic.get progress))
;;

let bad_gateway =
  Agent_core.Error.Api
    (Agent_core.Retry.ServerError { status = 502; message = "bad gateway" })
;;

let attributed_empty_completion stop_reason =
  Agent_core.Error.Provider
    (Llm_provider.Error.EmptyCompletion
       { provider = "openrouter"
       ; stop_reason
       ; detail = "empty assistant turn"
       })
;;

let same_path_manifest_rows events =
  List.filter_map
    (function
      | _, Some "deferred_same_path", Some decision -> Some (string_member "runtime_id" decision)
      | _, _, _ -> None)
    (List.rev !events)
;;

(* What a keeper's checkpoint write did, as its sink sees it. *)
type write_outcome =
  | Wrote
  | Wrote_nothing
  | Write_failed

(* One chat-lane walk. [attempt ~save candidate] may save checkpoint stages
   through the production sink wrapper before it returns the candidate's
   error; the walk reads progress from the same value the driver does. *)
let same_path_walk ~continuation candidates attempt =
  let deferred = ref [] in
  let events = ref [] in
  let progress = Atomic.make Try_provider.No_checkpoint_stage in
  (* As the keeper's own sink does: the stage goes through the wrapper, and the
     owner marks what its write actually reached. [Wrote_nothing] is the
     store's stale no-op, which answers [Ok ()] and leaves the canonical
     checkpoint as it was. *)
  let save stage outcome =
    let answer =
      match outcome with
      | Wrote | Wrote_nothing -> Ok ()
      | Write_failed -> Error "disk full"
    in
    let (_ : (unit, string) result) =
      Driver.For_testing.observing_checkpoint_sink progress
        (Some (fun _ -> answer))
        (progress_snapshot stage)
    in
    match outcome with
    | Wrote -> Driver.For_testing.observe_checkpoint_saved progress stage
    | Wrote_nothing | Write_failed -> ()
  in
  let result =
    Driver.For_testing.attempt_runtime_candidates
      ~allow_retry:(fun ~runtime_id:_ ~attempt:_ _ ->
        Driver.For_testing.same_run_retry_allowed progress)
      ~retry_deferral:(collecting_deferral continuation deferred)
      ~tool_results_saved:(fun () -> Driver.For_testing.tool_results_saved progress)
      ~runtime_id:"lane.chat"
      ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(emit_manifest_collector events)
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ candidate ->
        attempt_without_effect (Error (attempt ~save candidate)) None)
      candidates
  in
  result, List.rev !deferred, same_path_manifest_rows events
;;

let describe_hint (hint : Driver.deferred_runtime_lane) =
  Printf.sprintf "%s: %s -> [%s]" hint.Driver.assignment_id hint.Driver.failed_runtime_id
    (String.concat "; " (Driver.deferred_runtime_ids hint))
;;

(* RFC last-path-resumes-after-progress §3.1: the last candidate of a chat
   operation saved tool results and then failed on a server error, so the
   operation continues on that candidate. The hint keeps the assignment and
   names nothing but the failed candidate, alone or at the end of a lane. *)
let test_a_chat_operation_resumes_its_last_candidate_after_saved_tool_results () =
  let tools_then_bad_gateway ~save _candidate =
    save Agent_core.Agent.After_tool_results_appended Wrote;
    bad_gateway
  in
  let result, hints, rows =
    same_path_walk ~continuation:resume_chat_operation [ "only" ]
      tools_then_bad_gateway
  in
  Alcotest.(check (list string)) "a lone candidate defers to itself"
    [ "lane.chat: only -> [only]" ] (List.map describe_hint hints);
  Alcotest.(check (list string)) "and the walk records that decision"
    [ "only" ] rows;
  Alcotest.(check (result string string)) "the turn still fails with its own error"
    (Error (Agent_core.Error.to_string bad_gateway))
    (Result.map_error Agent_core.Error.to_string result);
  let _result, hints, _rows =
    same_path_walk ~continuation:resume_chat_operation [ "first"; "last" ]
      (fun ~save candidate ->
         match candidate with
         | "first" -> retryable_network_error "first dropped before any stage"
         | _ -> tools_then_bad_gateway ~save candidate)
  in
  Alcotest.(check (list string)) "the end of a lane defers to that candidate only"
    [ "lane.chat: last -> [last]" ] (List.map describe_hint hints)
;;

(* An attributed empty answer still proves that the provider saw the request,
   but a direct operation must not discard tool results it already saved. The
   next attempt can resume once; without another saved tool result the progress
   guard withholds a second hint. *)
let test_a_chat_operation_resumes_after_attributed_empty_completion () =
  List.iter
    (fun stop_reason ->
       let result, hints, rows =
         same_path_walk ~continuation:resume_chat_operation [ "only" ]
           (fun ~save _candidate ->
              save Agent_core.Agent.After_tool_results_appended Wrote;
              attributed_empty_completion stop_reason)
       in
       Alcotest.(check (list string))
         (Llm_provider.Types.stop_reason_to_metric_label stop_reason)
         [ "lane.chat: only -> [only]" ]
         (List.map describe_hint hints);
       Alcotest.(check (list string)) "the decision is recorded" [ "only" ] rows;
       match result with
       | Error _ -> ()
       | Ok _ -> Alcotest.fail "an empty completion unexpectedly succeeded")
    [ Llm_provider.Types.EndTurn
    ; Llm_provider.Types.MaxTokens
    ; Llm_provider.Types.StopSequence
    ]
;;

let test_deterministic_empty_stops_do_not_resume_after_saved_tool_results () =
  List.iter
    (fun stop_reason ->
       let error = attributed_empty_completion stop_reason in
       let result, hints, rows =
         same_path_walk ~continuation:resume_chat_operation [ "only" ]
           (fun ~save _candidate ->
              save Agent_core.Agent.After_tool_results_appended Wrote;
              error)
       in
       Alcotest.(check (list string))
         (Llm_provider.Types.stop_reason_to_metric_label stop_reason)
         [] (List.map describe_hint hints);
       Alcotest.(check (list string)) "no resume decision is recorded" [] rows;
       Alcotest.(check (result string string)) "the terminal error is preserved"
         (Error (Agent_core.Error.to_string error))
         (Result.map_error Agent_core.Error.to_string result))
    [ Llm_provider.Types.Refusal
    ; Llm_provider.Types.ContentFilter
    ; Llm_provider.Types.RepetitionTruncation
    ]
;;

(* §3.1–§3.5: each condition alone withholds the same-path hint. *)
let test_no_same_path_hint_unless_every_condition_holds () =
  let overflow =
    Agent_core.Error.Api
      (Agent_core.Retry.ContextOverflow { message = "too long"; limit = Some 32768 })
  in
  let cases =
    [ ( "no stage saved"
      , resume_chat_operation
      , [ "only" ]
      , fun ~save:_ _ -> bad_gateway )
    ; ( "only the answer saved"
      , resume_chat_operation
      , [ "only" ]
      , fun ~save _ ->
          save Agent_core.Agent.After_assistant_collected Wrote;
          bad_gateway )
    ; ( "the tool-results save failed"
      , resume_chat_operation
      , [ "only" ]
      , fun ~save _ ->
          save Agent_core.Agent.After_tool_results_appended Write_failed;
          bad_gateway )
    (* The store's stale no-op: the sink answered [Ok ()] and the canonical
       checkpoint the operation would resume from was left as it was. *)
    ; ( "the tool-results write was skipped as stale"
      , resume_chat_operation
      , [ "only" ]
      , fun ~save _ ->
          save Agent_core.Agent.After_tool_results_appended Wrote_nothing;
          bad_gateway )
    ; ( "a heartbeat cycle restarts"
      , Driver.Restart_cycle
      , [ "only" ]
      , fun ~save _ ->
          save Agent_core.Agent.After_tool_results_appended Wrote;
          bad_gateway )
    ; ( "a failure that waiting does not change"
      , resume_chat_operation
      , [ "only" ]
      , fun ~save _ ->
          save Agent_core.Agent.After_context_injection Wrote;
          Agent_core.Error.Api (Agent_core.Retry.NotFound { message = "no such model" }) )
    ; ( "an earlier candidate overflowed"
      , resume_chat_operation
      , [ "wide"; "narrow" ]
      , fun ~save candidate ->
          match candidate with
          | "wide" -> overflow
          | _ ->
            save Agent_core.Agent.After_tool_results_appended Wrote;
            bad_gateway )
    ]
  in
  List.iter
    (fun (label, continuation, candidates, attempt) ->
       let _result, hints, rows = same_path_walk ~continuation candidates attempt in
       Alcotest.(check (list string)) label [] (List.map describe_hint hints);
       Alcotest.(check (list string)) (label ^ ": and no decision is recorded") [] rows)
    cases
;;

(* The heartbeat lane must never ask to resume an operation: its hint replaces
   the next cycle's candidates, so a hint naming the path this cycle failed on
   would leave that cycle one candidate and no failover. Its only caller is
   production, so the value it passes is read here instead. *)
let test_the_heartbeat_lane_restarts_its_cycle () =
  Alcotest.(check bool) "the autonomous lane restarts instead of resuming" true
    (match Masc.Keeper_unified_turn_execution.lane_retry_continuation with
     | Driver.Restart_cycle -> true
     | Driver.Resume_operation_checkpoint _ -> false)
;;

(* §3.4: the wait of a same-path suffix is the rest recorded on the path. A
   server error records none, so the retry dispatches at once; a 429 that
   stated its wait holds the path until then.

   This pins a branch the resume relies on and does not change: it passes on
   main too, because a suffix naming one path already read that path's rest.
   It is here as the record of what the resume inherits -- in particular that
   a server error, a dropped stream and a timeout resume with no wait at all,
   which is the case RFC §1.1 was written about (RFC §7 measures how often a
   resume with no wait fails again before running a tool). *)
let test_a_same_path_suffix_waits_only_for_a_recorded_rest () =
  with_runtime_config runtime_toml_quota_lane (fun () ->
    reset_quota_lane_rests ();
    Fun.protect ~finally:reset_quota_lane_rests (fun () ->
      let path = "other.test_model" in
      let same_path failure =
        Driver.For_testing.make_deferred_runtime_lane
          ~assignment_id:"quota_lane" ~failed_runtime_id:path ~next_runtime_id:path
          ~later_runtime_ids:[] ~failure
      in
      let next ~route failure =
        let now = Unix.gettimeofday () in
        describe_dispatch ~now
          (Driver.next_dispatch_after_failure ~now ~route ~assignment_id:"quota_lane"
             (Some (same_path failure)))
      in
      let server_route =
        Keeper_runtime_failure_route.route_of_error
          ~boundary:Keeper_runtime_failure_route.Agent_core_execution bad_gateway
      in
      Alcotest.(check string) "a server error dispatches the same path at once"
        ("dispatch " ^ path) (next ~route:server_route bad_gateway);
      Runtime_candidate_backpressure.note_rate_limit
        ~candidate:(quota_lane_candidate path) ~retry_after:(Some 120.);
      Alcotest.(check string) "a stated 429 rest holds the same path until it ends"
        ("wait 120s for " ^ path ^ " (path)")
        (next ~route:rate_limited_route bad_gateway)))
;;

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
       { code; body = Llm_provider.Http_client.Received "candidate access denied"; retry_after_header = None })
;;

(* Exercise the lane with both API and official-client error carriage. Codex
   uses its real boundary projection so a configuration-error regression cannot
   be hidden by constructing the expected core error in the fixture. *)
let candidate_access_errors =
  [ "HTTP 401", access_error_from_http 401
  ; "HTTP 403", access_error_from_http 403
  ; "Claude authentication",
    Agent_core.Error.Provider
      (Llm_provider.Error.AuthError
         { provider = "claude_code"; detail = "login required" })
  ; "Claude authorization",
    Agent_core.Error.Provider
      (Llm_provider.Error.AuthorizationError
         { provider = "claude_code"; detail = "access denied" })
  ; "Codex subscription",
    Masc.Keeper_codex_runtime.For_testing.codex_error_to_core_error
      (Runtime_codex_app_server.Subscription_required "login required")
  ]
;;

let test_candidate_access_denial_reaches_the_next_declared_runtime () =
  List.iter (fun (label, denied) ->
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
     | Error error -> Alcotest.failf "%s stopped the lane: %s" label (Agent_core.Error.to_string error));
    Alcotest.(check (list string)) "walk stays inside declared candidates"
      ["denied"; "available"] (List.rev !attempts)) candidate_access_errors
;;

let test_access_failover_preserves_effect_and_caller_authority () =
  List.iter (fun (_label, denied) ->
    List.iter (fun disposition ->
      let attempts = ref 0 in
      let result = Driver.For_testing.attempt_runtime_candidates
        ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
        ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
        ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
          incr attempts;
          if runtime_id <> "denied" then Alcotest.fail "possible effect was replayed";
          ( Error denied
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
      ~retry_deferral:(collecting_deferral Driver.Restart_cycle deferred)
      ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id:_ _ ->
        incr attempts; attempt_without_effect (Error denied) None)
      ["denied"; "available"] in
    Alcotest.(check bool) "caller denial remains an error" true (Result.is_error result);
    Alcotest.(check int) "caller denies immediate second attempt" 1 !attempts;
    Alcotest.(check int) "existing deferred retry path retains the successor" 1 (List.length !deferred))
    candidate_access_errors
;;

let test_exhausted_access_errors_and_bad_requests_remain_terminal () =
  let cases =
    (access_error_from_http 400, ["first"])
    :: (Masc.Keeper_codex_runtime.For_testing.codex_error_to_core_error
          (Runtime_codex_app_server.Invalid_config "bad path"), ["first"])
    :: List.map (fun (_, error) -> error, ["first"; "last"])
         candidate_access_errors
  in
  List.iter (fun (denied, expected) ->
    let attempts = ref [] in
    let result = Driver.For_testing.attempt_runtime_candidates
      ~runtime_id:"access-lane" ~runtime_id_of:Fun.id
      ~emit_runtime_manifest:(fun ?status:_ ?decision:_ _ -> ())
      ~run_attempt:(fun ~idx:_ ~runtime_id _ ->
        attempts := runtime_id :: !attempts; attempt_without_effect (Error denied) None)
      ["first"; "last"] in
    Alcotest.(check (list string)) "no candidate beyond the declared suffix"
      expected (List.rev !attempts);
    match result with
    | Error error -> Alcotest.(check string) "original terminal diagnostic retained"
        (Agent_core.Error.to_string denied) (Agent_core.Error.to_string error)
    | Ok _ -> Alcotest.fail "exhausted lane unexpectedly succeeded") cases
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
            "assignment_walk_order is the declared order"
            `Quick
            test_assignment_walk_order_is_the_declared_order;
          Alcotest.test_case
            "assignment_walk_order demotes a resting head"
            `Quick
            test_assignment_walk_order_demotes_a_resting_head;
          Alcotest.test_case
            "assignment_walk_order refuses a missing assignment"
            `Quick
            test_assignment_walk_order_refuses_a_missing_assignment;
          Alcotest.test_case
            "entry_runtime_id_of_route resolves a route to the binding it opens"
            `Quick
            test_entry_runtime_id_resolves_a_route_to_the_binding_it_opens;
          Alcotest.test_case
            "a bare runtime assignment walks only itself"
            `Quick
            test_bare_runtime_assignment_walks_only_itself;
          Alcotest.test_case
            "resolve_assignment reports missing id"
            `Quick
            test_resolve_assignment_missing;
          Alcotest.test_case
            "unknown lane candidate rejected at load"
            `Quick
            test_unknown_lane_candidate_rejected_at_load;
          Alcotest.test_case
            "assignment to lane id loads"
            `Quick
            test_assignment_to_lane_id_loads;
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
            "lane media reroute stays in the lane"
            `Quick
            test_lane_media_reroute_stays_in_lane;
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
            "attempt loop moves past no-progress by default"
            `Quick
            test_attempt_loop_moves_past_no_progress_by_default;
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
          Alcotest.test_case "failed attempts demote until the candidate answers" `Quick
            test_failed_attempts_demote_until_the_candidate_answers;
          Alcotest.test_case
            "an empty completion clears stale unavailability evidence"
            `Quick
            test_an_empty_completion_clears_stale_unavailability_evidence;
          Alcotest.test_case "access refusal demotes until the candidate answers" `Quick
            test_access_refusal_demotes_until_the_candidate_answers;
          Alcotest.test_case "only the candidate's own failures are evidence" `Quick
            test_only_the_candidates_own_failures_are_evidence;
          Alcotest.test_case "a yield before the first token clears no evidence" `Quick
            test_a_yield_before_the_first_token_clears_no_evidence;
          Alcotest.test_case "the production answer test reads provider turns" `Quick
            test_the_production_answer_test_reads_provider_turns;
          Alcotest.test_case "a path that only failed walks before one told to rest" `Quick
            test_a_path_that_only_failed_walks_before_one_told_to_rest;
          Alcotest.test_case "402 still exhausts the quota scope" `Quick
            test_payment_required_still_exhausts_the_quota_scope;
          Alcotest.test_case "a quota hint that names no time is recorded as observed" `Quick
            test_a_quota_hint_that_names_no_time_is_recorded_as_observed;
          Alcotest.test_case "a deferred suffix waits only while its walk head rests" `Quick
            test_a_deferred_suffix_waits_only_while_its_walk_head_rests;
          Alcotest.test_case "a failure without a suffix waits until a fresh walk head serves"
            `Quick test_a_failure_without_a_suffix_waits_until_a_fresh_walk_head_serves;
          Alcotest.test_case "a chat retry follows the shared next dispatch" `Quick
            test_a_chat_retry_follows_the_shared_next_dispatch;
          Alcotest.test_case "a same-path suffix waits only for a recorded rest" `Quick
            test_a_same_path_suffix_waits_only_for_a_recorded_rest;
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
            "a success leaves the next walk declared"
            `Quick
            test_a_success_leaves_the_next_walk_declared;
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
            "a repeating generation leaves the model, not only the provider"
            `Quick
            test_repeating_generation_leaves_the_model_not_only_the_provider;
          Alcotest.test_case
            "a repeat on the only model reports the repeat"
            `Quick
            test_repeat_on_the_only_model_reports_the_repeat;
          Alcotest.test_case
            "the registry identity is the served name, not the model id"
            `Quick
            test_registry_identity_is_the_served_name_not_the_model_id;
          Alcotest.test_case
            "an overflow seen before a repeat outranks the refused tail"
            `Quick
            test_overflow_seen_before_a_repeat_outranks_the_refused_tail;
          Alcotest.test_case
            "the deferred hint after a repeat names a different model"
            `Quick
            test_deferred_hint_after_a_repeat_names_a_different_model;
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
            "a sink answer is not progress"
            `Quick
            test_a_sink_answer_is_not_progress;
          Alcotest.test_case
            "the sink owner marks written tool results"
            `Quick
            test_the_sink_owner_marks_written_tool_results;
          Alcotest.test_case
            "a chat operation resumes its last candidate after saved tool results"
            `Quick
            test_a_chat_operation_resumes_its_last_candidate_after_saved_tool_results;
          Alcotest.test_case
            "a chat operation resumes after an attributed empty completion"
            `Quick
            test_a_chat_operation_resumes_after_attributed_empty_completion;
          Alcotest.test_case
            "deterministic empty stops do not resume after saved tool results"
            `Quick
            test_deterministic_empty_stops_do_not_resume_after_saved_tool_results;
          Alcotest.test_case
            "no same-path hint unless every condition holds"
            `Quick
            test_no_same_path_hint_unless_every_condition_holds;
          Alcotest.test_case
            "the heartbeat lane restarts its cycle"
            `Quick
            test_the_heartbeat_lane_restarts_its_cycle;
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
