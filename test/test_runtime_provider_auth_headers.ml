open Alcotest
open Masc

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

let runtime_or_fail ?(provider = runpod_provider) () =
  let cfg =
    { Runtime_schema.providers = [ provider ]
    ; models = [ qwen_model ]
    ; bindings = [ runpod_binding ]
    ; default_runtime_id = Some "runpod_mtp.qwen"
    ; keeper_assignments = []
    }
  in
  match Runtime.of_binding cfg runpod_binding with
  | Some runtime -> runtime
  | None -> fail "expected runtime binding to materialize"

let with_dashboard_probe_http_get hook f =
  Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests
    hook;
  Fun.protect
    ~finally:(fun () ->
      Server_dashboard_http_runtime_info.clear_dashboard_runtime_provider_http_get_for_tests ())
    f

let first_provider_probe json =
  match Yojson.Safe.Util.(member "providers" json |> to_list) with
  | provider :: _ -> provider
  | [] -> fail "expected at least one provider probe"

let dashboard_probe_missing_auth_calls = ref 0

let assert_dashboard_runtime_probe_reachable runtime =
  let reachable_json =
    with_dashboard_probe_http_get
      (fun ~url ~headers ~timeout_sec:_ ->
         check string "models probe URL"
           "https://example-runpod.proxy.runpod.net/v1/models"
           url;
         check bool "auth header present" true
           (Option.is_some (normalized_header_value "authorization" headers));
         check bool "auth header is bearer" true
           (match normalized_header_value "authorization" headers with
            | Some value -> String.starts_with ~prefix:"Bearer " value
            | None -> false);
         Ok
           ( 200
           , [ "content-type", "application/json" ]
           , {|{"data":[{"id":"qwen"}]}|} ))
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_for_tests
           ~default_id:"runpod_mtp.qwen" [ runtime ])
  in
  let reachable_provider = first_provider_probe reachable_json in
  check string "provider status" "reachable"
    Yojson.Safe.Util.(member "status" reachable_provider |> to_string);
  check int "http status" 200
    Yojson.Safe.Util.(member "http_status" reachable_provider |> to_int);
  check int "model count" 1
    Yojson.Safe.Util.(member "model_count" reachable_provider |> to_int);
  let () =
    check bool "payload redacts inline token" false
      (String_util.contains_substring
         (Yojson.Safe.to_string reachable_json)
         "rp-test-token")
  in
  ()

let assert_dashboard_runtime_probe_missing_auth runtime =
  dashboard_probe_missing_auth_calls := 0;
  Server_dashboard_http_runtime_info.set_dashboard_runtime_provider_http_get_for_tests
    (fun ~url:_ ~headers:_ ~timeout_sec:_ ->
       incr dashboard_probe_missing_auth_calls;
       Ok (200, [], {|{"data":[]}|}));
  let json =
    Fun.protect
      ~finally:(fun () ->
        Server_dashboard_http_runtime_info.clear_dashboard_runtime_provider_http_get_for_tests ())
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_for_tests
           ~default_id:"runpod_mtp.qwen" [ runtime ])
  in
  let provider = first_provider_probe json in
  check int "missing auth does not execute HTTP" 0
    !dashboard_probe_missing_auth_calls;
  check string "provider status" "missing_auth"
    (Yojson.Safe.Util.(member "status" provider |> to_string));
  check bool "provider not reachable" false
    (Yojson.Safe.Util.(member "reachable" provider |> to_bool));
  let () =
    check bool "probe not ok" false
      (Yojson.Safe.Util.(member "probe_ok" json |> to_bool))
  in
  ()

let assert_dashboard_runtime_probe_redacts_url_credentials () =
  let provider =
    { runpod_provider with
      transport =
        Runtime_schema.Http
          "https://user:secret@example-runpod.proxy.runpod.net/v1?token=secret#frag"
    }
  in
  let runtime = runtime_or_fail ~provider () in
  let json =
    with_dashboard_probe_http_get
      (fun ~url:_ ~headers:_ ~timeout_sec:_ -> Ok (200, [], {|{"data":[]}|}))
      (fun () ->
         Server_dashboard_http_runtime_info.dashboard_runtime_probe_payload_json_for_tests
           ~default_id:"runpod_mtp.qwen" [ runtime ])
  in
  let provider = first_provider_probe json in
  check bool "payload redacts URL secrets" false
    (String_util.contains_substring (Yojson.Safe.to_string provider) "secret");
  check string "redacted endpoint URL"
    "https://example-runpod.proxy.runpod.net/v1"
    (Yojson.Safe.Util.(member "endpoint_url" provider |> to_string))

let test_dashboard_runtime_probe_reachability_contracts () =
  let runtime = runtime_or_fail () in
  assert_dashboard_runtime_probe_reachable runtime;
  assert_dashboard_runtime_probe_redacts_url_credentials ();
  let env_key = "MASC_TEST_RUNTIME_PROBE_TOKEN_MISSING_6F4C1D7A" in
  Unix.putenv env_key "";
  let provider =
    { runpod_provider with credentials = Some (Runtime_schema.Env env_key) }
  in
  let runtime = runtime_or_fail ~provider () in
  assert_dashboard_runtime_probe_missing_auth runtime

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

let test_runtime_agent_max_turns_is_continuation_checkpoint () =
  let lifecycle =
    Runtime_agent.worker_lifecycle_classification_of_result
      (Error
         (Agent_sdk.Error.Agent
            (Agent_sdk.Error.MaxTurnsExceeded { turns = 24; limit = 24 })))
  in
  check string "event" "completed" lifecycle.event;
  check string "status" "continuation_checkpoint" lifecycle.status;
  check (option string) "no error" None lifecycle.error

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
        ; test_case
            "max turns is continuation checkpoint"
            `Quick
            test_runtime_agent_max_turns_is_continuation_checkpoint
        ; test_case
            "dashboard runtime provider reachability contracts"
            `Quick
            test_dashboard_runtime_probe_reachability_contracts
        ] )
    ]
