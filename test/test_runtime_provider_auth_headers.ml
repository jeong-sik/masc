open Alcotest
open Masc_mcp

let header_count name headers =
  headers
  |> List.filter (fun (k, _) -> String.equal k name)
  |> List.length

let normalized_header_count name headers =
  let name = String.lowercase_ascii name in
  headers
  |> List.filter (fun (k, _) -> String.equal name (String.lowercase_ascii k))
  |> List.length

let normalized_header_value name headers =
  let name = String.lowercase_ascii name in
  headers
  |> List.find_map (fun (k, v) ->
    if String.equal name (String.lowercase_ascii k) then Some v else None)

let runpod_provider =
  { Runtime_schema.id = "runpod_mtp"
  ; display_name = "RunPod"
  ; protocol = "provider_d-http"
  ; api_format = Chat_completions_api
  ; transport = Http "https://example-runpod.proxy.runpod.net/v1"
  ; is_non_interactive = true
  ; credentials = Some (Inline "rp-test-token")
  ; capabilities = None
  ; headers = None
  }

let qwen_model =
  { Runtime_schema.id = "qwen"
  ; api_name = "qwen"
  ; tools_support = true
  ; max_context = 160000
  ; thinking_support = true
  ; max_thinking_budget = None
  ; streaming = true
  ; capabilities = None
  ; match_prefixes = []
  }

let runpod_binding =
  { Runtime_schema.provider_id = "runpod_mtp"
  ; model_id = "qwen"
  ; is_default = true
  ; max_concurrent = 4
  ; price_input = None
  ; price_output = None
  ; keep_alive = None
  ; num_ctx = None
  }

let test_runtime_adapter_keeps_auth_out_of_headers () =
  let cfg =
    { Runtime_schema.providers = [ runpod_provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; keeper_assignments = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Error msg -> failf "unexpected adapter error: %s" msg
  | Ok provider_cfg ->
    check string "api key" "rp-test-token" provider_cfg.api_key;
    check int "Authorization header count" 0
      (header_count "Authorization" provider_cfg.headers);
    check int "Content-Type header count" 1
      (header_count "Content-Type" provider_cfg.headers)

let test_runtime_adapter_filters_toml_auth_headers () =
  let provider =
    { runpod_provider with
      headers =
        Some
          [ "Authorization", "Bearer from-toml"
          ; "X-API-Key", "from-toml"
          ; "Content-Type", "application/custom+json"
          ; "X-Trace-Id", "trace-1"
          ]
    }
  in
  let cfg =
    { Runtime_schema.providers = [ provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; keeper_assignments = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Error msg -> failf "unexpected adapter error: %s" msg
  | Ok provider_cfg ->
    check string "api key" "rp-test-token" provider_cfg.api_key;
    check int "Authorization header count" 0
      (normalized_header_count "Authorization" provider_cfg.headers);
    check int "x-api-key header count" 0
      (normalized_header_count "x-api-key" provider_cfg.headers);
    check int "Content-Type header count" 1
      (normalized_header_count "Content-Type" provider_cfg.headers);
    check
      (option string)
      "Content-Type override"
      (Some "application/custom+json")
      (normalized_header_value "Content-Type" provider_cfg.headers);
    check
      (option string)
      "non-auth custom header"
      (Some "trace-1")
      (normalized_header_value "X-Trace-Id" provider_cfg.headers)

let provider_cfg () =
  let cfg =
    { Runtime_schema.providers = [ runpod_provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; keeper_assignments = []
    }
  in
  match Runtime_adapter.binding_to_provider_config cfg runpod_binding with
  | Ok provider_cfg -> provider_cfg
  | Error msg -> failf "unexpected adapter error: %s" msg

let test_runtime_agent_terminal_observation_uses_runtime_identity () =
  let config =
    Runtime_agent.default_config
      ~name:"oas-runpod_mtp.qwen"
      ~provider_cfg:(provider_cfg ())
      ~system_prompt:""
      ~tools:[]
  in
  let config =
    { config with description = Some "runtime:runpod_mtp.qwen/runtime" }
  in
  let observation =
    Runtime_agent.For_testing.runtime_observation_for_completed_config
      ~total_duration_ms:42.9
      config
  in
  check string "runtime id" "runpod_mtp.qwen" observation.runtime_id;
  check (option string) "selected model" (Some "qwen")
    observation.selected_model;
  check int "attempt count" 1 (List.length observation.attempts);
  check string "attempt detail source" "runtime_agent_terminal"
    observation.attempt_details_source

let () =
  run "runtime_provider_auth_headers"
    [ ( "provider_config"
      , [ test_case
            "runtime adapter carries auth in api_key only"
            `Quick
            test_runtime_adapter_keeps_auth_out_of_headers
        ; test_case
            "runtime adapter filters TOML auth headers"
            `Quick
            test_runtime_adapter_filters_toml_auth_headers
        ; test_case
            "runtime agent terminal observation carries model identity"
            `Quick
            test_runtime_agent_terminal_observation_uses_runtime_identity
        ] )
    ]
