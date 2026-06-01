open Alcotest
open Masc_mcp

let header_count name headers =
  headers
  |> List.filter (fun (k, _) -> String.equal k name)
  |> List.length

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

let () =
  run "runtime_provider_auth_headers"
    [ ( "provider_config"
      , [ test_case
            "runtime adapter carries auth in api_key only"
            `Quick
            test_runtime_adapter_keeps_auth_out_of_headers
        ] )
    ]
