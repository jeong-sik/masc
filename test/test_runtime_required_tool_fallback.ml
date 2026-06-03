module Runtime = Masc.Runtime
module EC = Masc.Keeper_error_classify
module Tool_surface = Masc.Keeper_agent_tool_surface
module SdkE = Agent_sdk.Error

let write_temp_runtime_config content =
  let path = Filename.temp_file "masc_runtime_required_tool_fallback_" ".toml" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content);
  path
;;

let runtime_toml =
  {|
[runtime]
default = "runpod_mtp.qwen"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "provider_d-http"
endpoint = "https://runpod.example/v1"

[providers.runpod_mtp.capabilities]
supports-runtime-mcp-tools = true
supports-runtime-tool-events = true

[providers.openai]
display-name = "OpenAI"
protocol = "provider_d-http"
endpoint = "https://api.openai.example/v1"

[providers.local_mtp]
display-name = "Local MTP"
protocol = "provider_d-http"
endpoint = "http://127.0.0.1:8080"

[providers.local_mtp.capabilities]
supports-runtime-mcp-tools = true
supports-runtime-tool-events = true

[models.qwen]
api-name = "qwen"
max-context = 65536
tools-support = true
streaming = true

[models.qwen.capabilities]
supports-tool-choice = true

[models.gpt]
api-name = "gpt"
max-context = 128000
tools-support = true
streaming = true

[models.gpt.capabilities]
supports-tool-choice = true

[models.local-qwen]
api-name = "qwen-local"
max-context = 65536
tools-support = true
streaming = true

[models.local-qwen.capabilities]
supports-tool-choice = true

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4

[openai.gpt]
is-default = true
max-concurrent = 1

[local_mtp.local-qwen]
is-default = true
max-concurrent = 1
|}
;;

let contract_violation =
  SdkE.Agent
    (SdkE.CompletionContractViolation
       { contract = Agent_sdk.Completion_contract_id.Require_tool_use
       ; reason = "model emitted text instead of keeper tool"
       ; violation_detail = None
       })
;;

let with_runtime_config f =
  let path = write_temp_runtime_config runtime_toml in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () -> f path)
;;

let load_runtimes path =
  match Runtime.load_list ~config_path:path with
  | Ok (runtimes, _default_runtime, _assignments) -> runtimes
  | Error msg -> Alcotest.fail msg
;;

let init_runtime path =
  match Runtime.init_default ~config_path:path with
  | Ok () -> ()
  | Error msg -> Alcotest.fail msg
;;

let test_required_tool_runtime_ids_preserve_configured_fallback () =
  with_runtime_config (fun path ->
    let runtimes = load_runtimes path in
    Alcotest.(check (list string))
      "runtime ids"
      [ "runpod_mtp.qwen"; "local_mtp.local-qwen" ]
      (Runtime.required_tool_runtime_ids runtimes))
;;

let test_required_tool_contract_violation_rotates_to_local_runtime () =
  with_runtime_config (fun path ->
    init_runtime path;
    match
      EC.degraded_rotation_after_recoverable_error
        ~base_runtime:"runpod_mtp.qwen"
        ~effective_runtime:"runpod_mtp.qwen"
        ~tool_requirement:Tool_surface.Required
        ~attempted_runtimes:[ "runpod_mtp.qwen" ]
        contract_violation
    with
    | Some retry ->
      Alcotest.(check string)
        "next runtime"
        "local_mtp.local-qwen"
        retry.EC.next_runtime;
      Alcotest.(check string)
        "reason"
        "required_tool_contract_violation"
        (EC.degraded_retry_reason_to_string retry.EC.fallback_reason)
    | None -> Alcotest.fail "expected local runtime fallback")
;;

let test_required_tool_contract_violation_rotates_back_to_default_runtime () =
  with_runtime_config (fun path ->
    init_runtime path;
    match
      EC.degraded_rotation_after_recoverable_error
        ~base_runtime:"local_mtp.local-qwen"
        ~effective_runtime:"local_mtp.local-qwen"
        ~tool_requirement:Tool_surface.Required
        ~attempted_runtimes:[ "local_mtp.local-qwen" ]
        contract_violation
    with
    | Some retry ->
      Alcotest.(check string) "next runtime" "runpod_mtp.qwen" retry.EC.next_runtime
    | None -> Alcotest.fail "expected default runtime fallback")
;;

let () =
  Alcotest.run
    "runtime_required_tool_fallback"
    [ ( "required-tool fallback"
      , [ Alcotest.test_case
            "runtime list exposes configured tool-capable fallback"
            `Quick
            test_required_tool_runtime_ids_preserve_configured_fallback
        ; Alcotest.test_case
            "contract violation rotates from default RunPod to local MTP"
            `Quick
            test_required_tool_contract_violation_rotates_to_local_runtime
        ; Alcotest.test_case
            "contract violation rotates from local MTP back to default RunPod"
            `Quick
            test_required_tool_contract_violation_rotates_back_to_default_runtime
        ] )
    ]
;;
