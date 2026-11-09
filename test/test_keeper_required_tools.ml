open Alcotest
open Masc
module Required = Keeper_required_tools

let write path value = Out_channel.with_open_bin path (fun ch -> output_string ch value)
let quoted s = "'" ^ String.concat "'\"'\"'" (String.split_on_char '\'' s) ^ "'"

let test_required_candidate_delivery () =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
  Masc_test_deps.init_eio_clock ~sw env;
  let previous = Runtime.For_testing.snapshot () in
  let previous_catalog = Llm_provider.Catalog_snapshot.current () in
  let root = Filename.temp_file "keeper-required-tools" "" in
  Unix.unlink root; Unix.mkdir root 0o700;
  Eio.Switch.on_release sw (fun () ->
    Runtime.For_testing.restore previous;
    (Llm_provider.Catalog_snapshot.publish previous_catalog);
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
    "[[models]]\nmodel_id=%S\nprovider_name=%S\nbase=\"openai_chat\"\nmax_context_tokens=200000\nmax_output_tokens=128\nsupports_tools=%b\nsupports_native_streaming=false\n"
    model provider supports_tools in
  let catalog_path = Filename.concat root "models.toml" in
  write catalog_path (row "binding" "tool-fixture" false ^ row "good" "tool-fixture" true ^
    row "native" "tool-fixture" true ^ row "good" "no-tools-model" false);
  (match Llm_provider.Model_catalog.load_file catalog_path with
   | Ok catalog -> (Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some (catalog)) ~providers:(None))) | Error e -> fail e);
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
max-context = 200000
tools-support = true
streaming = false
[models.no_tools]
api-name = "tool-fixture"
max-context = 200000
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
    Keeper_turn_driver.run_named ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "required-tools-proof" }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk ~runtime_id ~keeper_name:"required-tools-proof"
      ~base_path:root ~media_store:(Tool_blob_media_store.of_base_path ~base_path:root) ~system_prompt:"Tool requirement dispatch fixture."
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
  (match Runtime.get_lane_by_id "unsupported_tools_fixture" with
   | Some lane -> check (list string) "all resolved candidates are actually unsupported"
       ["native.no_tools";"binding.sample"] (Runtime_lane.ordered_candidates lane)
   | None -> fail "unsupported fixture lane disappeared");
  run ~tool_requirement:Required.Required ~tools:[tool] "unsupported_tools_fixture"
  |> expect Required.Binding_tools_unsupported;
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
     requirement the verdict tool never had. The turn itself fails: Required
     refuses the only candidate before dispatch, which is the point -- left
     Optional this runtime is dispatched with its tools replaced by [] and no
     channel left to report a verdict on. *)
  let rejected_dispatches = ref 0 in
  let invalid_schema_result =
    Keeper_turn_driver_wrappers.run_named_with_masc_tools
      ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "invalid-schema-wrapper" })
      ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
      ~runtime_id:"native.no_tools" ~keeper_name:"invalid-schema-wrapper"
      ~base_path:root ~media_store:(Tool_blob_media_store.of_base_path ~base_path:root)
      ~system_prompt:"Invalid schema fixture." ~goal:"Answer the request."
      ~masc_tools:[ { Masc_domain.name = "broken_tool"; description = "Bad schema"
                    ; input_schema = `Assoc [ "type", `String "array" ] } ]
      ~dispatch:(fun ~name ~args:_ ->
        incr rejected_dispatches;
        Tool_result.ok ~tool_name:name ~start_time:(Tool_timing.start ()) "unexpected")
      ~sw ~net:env#net ()
  in
  (match invalid_schema_result with
   | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig { field; detail })) ->
     check string "schema failure field" "tool input_schema" field;
     check bool "schema failure names tool" true (String.starts_with ~prefix:"tool \"broken_tool\"" detail)
   | Error error -> fail (Agent_core.Error.to_string error)
   | Ok _ -> fail "invalid tool schema must refuse turn setup");
  check int "invalid schema never dispatches" 0 !rejected_dispatches;
  let wrapper_attempts = ref [] in
  ignore
    (Keeper_turn_driver_wrappers.run_named_with_masc_tools ~input_source:(Masc.Keeper_request_source.Keeper_history { trace_id = "required-tools-wrapper" }) ~raw_trace:None ~walk_owner:Masc.Keeper_turn_driver.One_shot_walk
       ~runtime_id:"native.no_tools" ~keeper_name:"required-tools-wrapper"
       ~base_path:root ~media_store:(Tool_blob_media_store.of_base_path ~base_path:root) ~system_prompt:"Wrapper requirement fixture."
       ~goal:"Answer the request."
       ~masc_tools:
         [ { Masc_domain.name = "fixture_tool"
           ; description = "Offered callable tool."
           ; input_schema = `Assoc [ "type", `String "object" ]
           } ]
       ~dispatch:(fun ~name ~args:_ ->
         Tool_result.ok ~tool_name:name ~start_time:(Tool_timing.start ()) "wrapper fixture")
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

let test_frozen_runtime_media_survives_registry_replacement () =
  List.iter (fun (label,initial,replacement,present) ->
    Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw ->
    Masc_test_deps.init_eio_clock ~sw env;
    let previous=Runtime.For_testing.snapshot () in
    let catalog=Llm_provider.Catalog_snapshot.current () in
    let root=Filename.temp_dir "keeper-frozen-media-" "" in
    Eio.Switch.on_release sw (fun () ->
      Runtime.For_testing.restore previous;
      Llm_provider.Catalog_snapshot.publish catalog;
      Fs_compat.remove_tree root);
    let expected=initial=Some true in
    let tool_calls=ref 0 in
    let image_tool=Agent_core.Tool.create
      ~descriptor:(Agent_core.Tool.ordinary_descriptor Agent_core.Tool_contract.Concurrent)
      ~name:"keeper_image_read" ~description:"Fixture image read" ~parameters:[]
      (fun _ -> incr tool_calls;Ok {Agent_core.Types.content="image read";content_blocks=None;_meta=None}) in
    let server=Exact_output_fixture.start_server ~sw ~net:env#net ~clock:env#clock
      (Exact_output_fixture.Reply_with (fun index _ ->
        if expected && index=0 then `OK,{|{"id":"read-image","model":"frozen-image-model","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"image-read","type":"function","function":{"name":"keeper_image_read","arguments":"{}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}|}
        else `OK,Exact_output_fixture.openai_response (`String "accepted"))) in
    let catalog_text=String.concat "" (List.map (fun provider -> Printf.sprintf
      "[[models]]\nmodel_id=\"frozen-image-model\"\nprovider_name=%S\nbase=\"openai_chat\"\nmax_context_tokens=200000\nmax_output_tokens=128\nsupports_tools=true\nsupports_native_streaming=false\n"
      provider) ["image";"standby"]) in
    (match Llm_provider.Model_catalog.of_toml_string ~source:label catalog_text with
     | Ok models ->
       let _,providers=Llm_provider.Catalog_snapshot.sources catalog in
       Llm_provider.Catalog_snapshot.publish (Masc_test_deps.admit_catalogs ~models:(Some models) ~providers)
     | Error error -> fail error);
    let path=Filename.concat root "runtime.toml" in
    let config_text image present =
      Printf.sprintf "[runtime]\ndefault=%S\nmedia_failover=[]\n"
        (if present then "image.sample" else "standby.sample")
      ^ (if present then Printf.sprintf
          "[providers.image]\nprotocol=\"openai-compatible-http\"\nendpoint=%S\n" server.base_url else "")
      ^ Printf.sprintf "[providers.standby]\nprotocol=\"openai-compatible-http\"\nendpoint=%S\n" server.base_url
      ^ "[models.sample]\napi-name=\"frozen-image-model\"\nmax-context=200000\ntools-support=true\nstreaming=false\n"
      ^ (match image with None -> "" | Some value ->
          "[models.sample.capabilities]\nsupports-image-input=" ^ string_of_bool value ^ "\n")
      ^ (if present then "[image.sample]\n" else "") ^ "[standby.sample]\n" in
    let reload image present =
      write path (config_text image present);
      match Runtime.init_default ~config_path:path with Ok () -> () | Error error -> fail error in
    reload initial true;
    let media_store=Agent_core.History.Memory_store.create () in
    let image=Agent_core.Types.image_block ~media_type:"image/png"
      ~source:(Agent_core.Types.Url "https://example.invalid/frozen-input.png") in
    let selected=ref None and transformed=ref None in
    let project_for_runtime ~runtime ~carried:_ =
      selected:=Some runtime;
      let accepts=Runtime_agent.runtime_accepts_image_input ~runtime in
      check bool (label ^ ": tool projection captures the selected model") expected accepts;
      let tools=if accepts then [image_tool] else [] in
      Keeper_tools_agent_core.assemble_model_tool_surface
        ~image_admission:(if accepts then Keeper_tools_agent_core.Image_input_admitted else Image_input_unavailable)
        ~tools ~agent_core_tools:tools ~on_demand_tool_names:[] ~result_bounds:[]
        ~listing:Keeper_tools_agent_core.No_listing in
    let provider_config_transform (provider:Llm_provider.Provider_config.t) =
      check bool "catalogued provider config does not carry the runtime media declarations" true
        (Option.is_none provider.model_capabilities_override);
      reload replacement present;
      let provider={provider with temperature=Some 0.3125;max_tokens=Some 31;
        response_format=Agent_core.Types.JsonMode} in
      transformed:=Some provider;
      Ok provider in
    (match Keeper_turn_driver.run_named
       ~input_source:(Keeper_request_source.Keeper_history {trace_id="frozen-media-proof"})
       ~raw_trace:None ~walk_owner:Keeper_turn_driver.One_shot_walk
       ~runtime_id:"image.sample" ~keeper_name:"frozen-media-proof" ~base_path:root ~media_store
       ~system_prompt:"Keep the selected runtime's input contract."
       ~goal:"Inspect the image." ~goal_blocks:[image] ~tools:[image_tool] ~agent_core_tools:[image_tool]
       ~project_for_runtime ~provider_config_transform ~sw ~net:env#net () with
     | Error error -> failf "%s: %s" label (Agent_core.Error.to_string error)
     | Ok result -> check string "dispatch remains attributed to the selected runtime" "image.sample" result.selected_runtime_id);
    let runtime=Option.get !selected in
    check bool "the captured runtime retains its model after reload" expected
      (Runtime_agent.runtime_accepts_image_input ~runtime);
    check (option bool) "the live registry really changed or removed the same runtime"
      (if present then Some (replacement=Some true) else None)
      (Option.map (fun runtime -> Runtime_agent.runtime_accepts_image_input ~runtime)
         (Runtime.get_runtime_by_id "image.sample"));
    let bodies=Exact_output_fixture.request_bodies server in
    check int "only an admitted image reader executes" (if expected then 1 else 0) !tool_calls;
    check int "preflight reaches the fake provider with the frozen policy" (if expected then 2 else 1) (List.length bodies);
    let rec has_image = function
      | `Assoc fields -> List.assoc_opt "type" fields=Some (`String "image_url")
        || List.exists (fun (_,value) -> has_image value) fields
      | `List values -> List.exists has_image values
      | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ -> false in
    List.iter (fun body ->
      let json=Yojson.Safe.from_string body in
      check bool "frozen media projection and preflight agree on the actual wire" expected (has_image json);
      check (float 0.0) "provider transform temperature survives" 0.3125
        Yojson.Safe.Util.(json |> member "temperature" |> to_float);
      check int "provider transform output budget survives" 31 Yojson.Safe.Util.(json |> member "max_tokens" |> to_int);
      check bool "provider transform serialization format survives" true
        (Yojson.Safe.Util.(json |> member "response_format" |> member "type")=`String "json_object")) bodies;
    let first=Yojson.Safe.from_string (List.hd bodies) in
    let offered=match Yojson.Safe.Util.member "tools" first with `List tools -> tools | _ -> [] in
    check bool "only the frozen image-capable surface offers the native image reader" expected
      (List.exists (fun tool -> Yojson.Safe.Util.(tool |> member "function" |> member "name")=`String "keeper_image_read") offered);
    if not expected then (
      let config=Runtime_agent.default_config ~media_store ~name:"direct-frozen-media"
        ~provider_cfg:(Option.get !transformed) ~system_prompt:"Frozen preflight boundary" ~tools:[] in
      let config={config with runtime_id=Some "image.sample";input_runtime=Some runtime} in
      (match Runtime_agent.run_blocks ~sw ~net:env#net ~config [Agent_core.Types.Text "Inspect the image.";image] with
       | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field="multimodal_input";_})) -> ()
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ -> fail "a frozen false or unknown declaration was widened by the replacement");
      check int "direct preflight refuses before any extra provider request" (List.length bodies)
        (Exact_output_fixture.post_count server));
    if initial=Some true && replacement=Some false && present then (
      let config=Runtime_agent.default_config ~media_store ~name:"id-only-media"
        ~provider_cfg:(Option.get !transformed) ~system_prompt:"Existing ID-only boundary" ~tools:[] in
      let config={config with runtime_id=Some "image.sample"} in
      (match Runtime_agent.run_blocks ~sw ~net:env#net ~config [Agent_core.Types.Text "Inspect the image.";image] with
       | Error (Agent_core.Error.Config (Agent_core.Error.InvalidConfig {field="multimodal_input";_})) -> ()
       | Error error -> fail (Agent_core.Error.to_string error)
       | Ok _ -> fail "ID-only caller stopped honoring the live runtime declaration");
      check int "ID-only refusal still precedes provider dispatch" (List.length bodies)
        (Exact_output_fixture.post_count server)))
    ["true to false",Some true,Some false,true;"true to unknown",Some true,None,true;
     "true to removed",Some true,None,false;"false to true",Some false,Some true,true;
     "unknown to true",None,Some true,true]

let () = Alcotest.run "Required tool delivery across runtime candidates"
  ["actual-dispatch",[
    test_case "skip unsupported owners and bindings before dispatch" `Quick test_required_candidate_delivery;
    test_case "selected media and tool policy survives registry replacement" `Quick test_frozen_runtime_media_survives_registry_replacement]]
