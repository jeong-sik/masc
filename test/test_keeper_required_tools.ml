open Alcotest
open Masc
module Required = Keeper_required_tools

let write path value = Out_channel.with_open_bin path (fun ch -> output_string ch value)
let quoted s = "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' s) ^ "'"

let test_required_candidate_delivery () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let previous = Runtime.For_testing.snapshot () in
  let previous_catalog = Llm_provider.Model_catalog.global () in
  let root = Filename.temp_file "keeper-required-tools" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore previous;
    (match previous_catalog with None -> Llm_provider.Model_catalog.clear_global ()
     | Some catalog -> Llm_provider.Model_catalog.set_global catalog);
    Fs_compat.remove_tree root);
  let server () = Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
    (Exact_output_fixture.Reply
      (Exact_output_fixture.openai_response (`Assoc ["answer",`String "accepted"]))) in
  let unsupported = server () in
  let supported = server () in
  let native_marker = Filename.concat root "native-was-spawned" in
  let native_command = Filename.concat root "native-fixture" in
  write native_command ("#!/bin/sh\nprintf 'unexpected dispatch' > " ^ quoted native_marker ^ "\nexit 99\n");
  Unix.chmod native_command 0o755;
  let row provider model supports_tools = Printf.sprintf
    "[[models]]\nid_prefix=%S\nprovider_name=%S\nbase=\"openai_chat\"\nmax_context_tokens=8192\nmax_output_tokens=128\nsupports_tools=%b\nsupports_native_streaming=false\n"
    model provider supports_tools in
  let catalog_path = Filename.concat root "models.toml" in
  write catalog_path (row "binding" "tool-fixture" false ^ row "good" "tool-fixture" true ^
    row "native" "tool-fixture" true ^ row "good" "no-tools-model" false);
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Ok catalog -> Llm_provider.Model_catalog.set_global catalog | Error e -> fail e);
  let config_path = Filename.concat root "runtime.toml" in
  let config_text default = Printf.sprintf {|[runtime]
default = %S
[providers.binding]
protocol = "openai-compatible-http"
endpoint = %S
[providers.good]
protocol = "openai-compatible-http"
endpoint = %S
[providers.native]
protocol = "claude-code"
command = %S
is-non-interactive = true
[models.sample]
api-name = "tool-fixture"
max-context = 8192
tools-support = true
streaming = false
[models.no_tools]
api-name = "tool-fixture"
max-context = 8192
tools-support = false
[binding.sample]
[good.sample]
[native.no_tools]
[runtime.lanes.required_tools_fixture]
candidates = ["native.no_tools", "binding.sample", "good.sample"]
[runtime.lanes.unsupported_tools_fixture]
candidates = ["native.no_tools", "binding.sample"]
|} default unsupported.base_url supported.base_url native_command in
  write config_path (config_text "good.sample");
  (match Runtime.init_default_degraded_report ~config_path with
   | Ok Runtime.Initialized -> ()
   | Ok (Runtime.Initialized_degraded _) -> fail "fixture must resolve every candidate"
   | Error e -> fail (Runtime.strict_init_error_to_string e));
  let tool = Agent_core.Tool.create
    ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
    ~name:"fixture_tool" ~description:"Offered callable tool." ~parameters:[]
    (fun _ -> Ok {Agent_core.Types.content="fixture result"; content_blocks = None; _meta = None}) in
  let errors = ref [] in
  let run ?provider_config_transform ?output_contract ~tool_requirement ~tools runtime_id =
    Keeper_turn_driver.run_named ~runtime_id ~keeper_name:"required-tools-proof"
      ~base_path:root ~system_prompt:"Tool requirement dispatch fixture."
      ~goal:"Answer the request." ~tools ~agent_core_tools:tools ~tool_requirement
      ?provider_config_transform ?output_contract
      ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch error -> errors := (runtime_id,dispatch,error) :: !errors)
      ~sw ~net:env#net () in
  (match run ~tool_requirement:Required.Required ~tools:[tool] "required_tools_fixture" with
   | Ok result -> check string "declared supported candidate selected" "good.sample" result.selected_runtime_id
   | Error e -> fail (Agent_core.Error.to_string e));
  let classified = List.rev !errors |> List.map (fun (runtime_id,_dispatch,error) ->
    match Required.of_core_error error with
    | Some failure -> runtime_id, failure.Required.reason
    | None -> fail "candidate lost typed tool support reason") in
  check bool "tool-surface refusals are reported as rejected before dispatch, never as the candidate's answer" true
    (List.for_all (fun (_,dispatch,_) -> dispatch = Keeper_attempt_dispatch.Rejected_before_dispatch) !errors);
  check bool "execution-owner and binding refusals remain distinct" true
    (classified=["native.no_tools",Required.Model_tools_disabled;"binding.sample",Required.Binding_tools_unsupported]);
  check bool "unsupported native owner never launched" false (Sys.file_exists native_marker);
  check int "unsupported binding performed no HTTP POST" 0 (Exact_output_fixture.post_count unsupported);
  check int "next declared provider received one request" 1 (Exact_output_fixture.post_count supported);
  let body = List.hd (Exact_output_fixture.request_bodies supported) |> Yojson.Safe.from_string in
  let tools = Yojson.Safe.Util.(body |> member "tools" |> to_list) in
  check bool "actual accepted wire includes offered tool" true
    (List.exists (fun t -> Yojson.Safe.Util.(t |> member "function" |> member "name") = `String "fixture_tool") tools);
  let expect reason = function
    | Ok _ -> fail "required tool refusal unexpectedly succeeded"
    | Error error ->
      (match Required.of_core_error error with Some f -> check bool "typed terminal reason" true (f.reason=reason)
       | None -> fail (Agent_core.Error.to_string error));
      check bool "rendered prose is not a retry authority" false
        (Required.should_try_next (Agent_core.Error.Internal (Agent_core.Error.to_string error))) in
  (match Runtime.save_config_text ~runtime_config_path:config_path (config_text "binding.sample") with
   | Ok _ -> () | Error e -> fail e);
  (match Runtime.get_lane_by_id "unsupported_tools_fixture" with
   | Some lane -> check (list string) "all resolved candidates are actually unsupported"
       ["native.no_tools";"binding.sample"] (Runtime_lane.ordered_candidates lane)
   | None -> fail "unsupported fixture lane disappeared");
  run ~tool_requirement:Required.Required ~tools:[tool] "unsupported_tools_fixture"
  |> expect Required.Binding_tools_unsupported;
  (match Runtime.save_config_text ~runtime_config_path:config_path (config_text "good.sample") with
   | Ok _ -> () | Error e -> fail e);
  run ~tool_requirement:Required.Required ~tools:[] "good.sample" |> expect Required.No_tools_supplied;
  let transform (cfg:Llm_provider.Provider_config.t) =
    Ok {cfg with model_id="no-tools-model";model_capabilities_override=None} in
  run ~provider_config_transform:transform ~tool_requirement:Required.Required ~tools:[tool] "good.sample"
  |> expect Required.Binding_tools_unsupported;
  check int "all refused attempts leave successful peer count unchanged" 1 (Exact_output_fixture.post_count supported);
  (match run ~tool_requirement:Required.Optional ~tools:[] "binding.sample" with
   | Ok _ -> () | Error e -> fail (Agent_core.Error.to_string e));
  check int "ordinary tool-free call remains valid" 1 (Exact_output_fixture.post_count unsupported);
  let preset_json (cfg:Llm_provider.Provider_config.t) =
    Ok {cfg with response_format=Agent_core.Types.JsonMode} in
  (match run ~provider_config_transform:preset_json
     ~output_contract:Keeper_turn_driver.Tool_verdict
     ~tool_requirement:Required.Required ~tools:[tool] "good.sample" with
   | Ok _ -> () | Error e -> fail (Agent_core.Error.to_string e));
  let body = Exact_output_fixture.request_bodies supported |> List.rev |> List.hd
    |> Yojson.Safe.from_string in
  check bool "tool verdict contract clears preset format on actual API wire" true
    (Yojson.Safe.Util.member "response_format" body = `Null);
  (* The completion verifier reaches the driver through this wrapper
     (workspace_metric_hooks.ml), so a requirement the wrapper drops is a
     requirement the verdict tool never had. The turn itself may still succeed:
     Required refuses the candidate before dispatch and the driver walks on,
     which is the point -- left Optional this runtime is dispatched with its
     tools replaced by [] and no channel left to report a verdict on. *)
  let wrapper_attempts = ref [] in
  ignore
    (Keeper_turn_driver_wrappers.run_named_with_masc_tools
       ~runtime_id:"native.no_tools" ~keeper_name:"required-tools-wrapper"
       ~base_path:root ~system_prompt:"Wrapper requirement fixture."
       ~goal:"Answer the request."
       ~masc_tools:
         [ { Masc_domain.name = "fixture_tool"
           ; description = "Offered callable tool."
           ; input_schema = `Assoc [ "type", `String "object" ]
           } ]
       ~dispatch:(fun ~name ~args:_ ->
         Tool_result.ok ~tool_name:name ~start_time:(Time_compat.now ()) "wrapper fixture")
       ~tool_requirement:Required.Required
       ~on_runtime_attempt_error:(fun ~runtime_id ~attempt:_ ~dispatch error ->
         wrapper_attempts := (runtime_id, dispatch, error) :: !wrapper_attempts)
       ~sw ~net:env#net ());
  (match List.rev !wrapper_attempts with
   | (runtime_id, dispatch, error) :: _ ->
     check string "the wrapper carries the requirement to the refused runtime"
       "native.no_tools" runtime_id;
     check bool "wrapper refusal is reported before dispatch" true
       (dispatch = Keeper_attempt_dispatch.Rejected_before_dispatch);
     (match Required.of_core_error error with
      | Some failure ->
        check bool "typed tool reason survives the wrapper" true
          (failure.Required.reason = Required.Model_tools_disabled)
      | None -> fail "wrapper refusal lost its typed tool reason")
   | [] ->
     fail "the wrapper dropped tool_requirement: a tools-disabled runtime was admitted");
  check bool "wrapper refusal never launched the native client" false
    (Sys.file_exists native_marker)

let () = Alcotest.run "Required tool delivery across runtime candidates"
  ["actual-dispatch",[test_case "skip unsupported owners and bindings before dispatch" `Quick test_required_candidate_delivery]]
