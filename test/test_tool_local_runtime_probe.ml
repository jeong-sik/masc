open Alcotest

let check_float_close label expected actual =
  check bool label true (Float.abs (expected -. actual) < 0.001)

let contains_substring text needle =
  let len_text = String.length text in
  let len_needle = String.length needle in
  if len_needle = 0 then true
  else if len_needle > len_text then false
  else
    let rec loop idx =
      if idx > len_text - len_needle then false
      else if String.equal (String.sub text idx len_needle) needle then true
      else loop (idx + 1)
    in
    loop 0

let test_ollama_ps_parser_extracts_loaded_models () =
  let json =
    Yojson.Safe.from_string
      {|{"models":[{"name":"qwen3.5:35b-a3b-coding-nvfp4","model":"qwen3.5:35b-a3b-coding-nvfp4","size_vram":21474836480,"context_length":262144,"expires_at":"2026-04-10T00:00:00Z"}]}|}
  in
  let models = Masc.Tool_local_runtime.ollama_loaded_models_of_ps_json json in
  let open Yojson.Safe.Util in
  check int "one loaded model" 1 (List.length models);
  let model = List.hd models in
  check (option string) "name extracted"
    (Some "qwen3.5:35b-a3b-coding-nvfp4")
    (model |> member "name" |> to_string_option);
  check (option int) "context length extracted" (Some 262144)
    (match model |> member "context_length" with
    | `Int value -> Some value
    | _ -> None)

let test_ollama_generate_parser_computes_tok_per_second () =
  let json =
    Yojson.Safe.from_string
      {|{"response":"READY","done":true,"done_reason":"stop","total_duration":9104952708,"load_duration":3338399458,"prompt_eval_count":20,"prompt_eval_duration":337442459,"eval_count":311,"eval_duration":5428288000,"thinking":"hidden"}|}
  in
  let run_json =
    Masc.Tool_local_runtime.ollama_probe_run_of_generate_json ~run_index:1
      ~http_status:(Some 200) ~wall_clock_ms:9120 json
  in
  let prompt_tps =
    Option.value ~default:(-1.0) run_json.prompt_tokens_per_second
  in
  let generation_tps =
    Option.value ~default:(-1.0) run_json.generation_tokens_per_second
  in
  check_float_close "prompt tok/sec computed" 59.2693642029203 prompt_tps;
  check_float_close "generation tok/sec computed" 57.2924649539597
    generation_tps;
  check bool "thinking detected" true run_json.thinking_present;
  check (option string) "response preview kept" (Some "READY")
    run_json.response_preview

let test_request_body_omits_keep_alive_by_default () =
  let json =
    Masc.Tool_local_runtime_probe.request_body_json
      ~think_enabled:false ~keep_alive:None
      ~model_id:"qwen3.5:35b-a3b-coding-nvfp4" ~prompt:"READY" ~max_tokens:8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check (option string) "keep_alive omitted"
    None
    (json |> member "keep_alive" |> to_string_option);
  check bool "thinking disabled by default" false
    (json |> member "think" |> to_bool)

let test_request_body_can_enable_thinking () =
  let json =
    Masc.Tool_local_runtime_probe.request_body_json ~think_enabled:true
      ~keep_alive:None ~model_id:"qwen3.5:35b-a3b-coding-nvfp4" ~prompt:"READY"
      ~max_tokens:8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check bool "thinking can be requested" true
    (json |> member "think" |> to_bool)

let test_request_body_keeps_explicit_keep_alive () =
  let json =
    Masc.Tool_local_runtime_probe.request_body_json
      ~think_enabled:false ~keep_alive:(Some "90s")
      ~model_id:"qwen3.5:35b-a3b-coding-nvfp4" ~prompt:"READY" ~max_tokens:8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check (option string) "keep_alive included"
    (Some "90s")
    (json |> member "keep_alive" |> to_string_option)

let test_think_mode_parses_adaptive_policy () =
  let parse raw =
    Masc.Tool_local_runtime_probe.ollama_probe_think_mode_of_string raw
    |> Option.map
         Masc.Tool_local_runtime_probe.ollama_probe_think_mode_to_string
  in
  check (option string) "auto parsed" (Some "auto") (parse " auto ");
  check (option string) "disabled alias parsed" (Some "disabled")
    (parse "off");
  check (option string) "enabled alias parsed" (Some "enabled")
    (parse "YES");
  check (option string) "invalid rejected" None (parse "maybe")

let test_auto_think_policy_prioritizes_response () =
  check bool "auto disables thinking for readiness" false
    (Masc.Tool_local_runtime_probe.effective_think_enabled
       Masc.Tool_local_runtime_probe.Think_auto);
  check bool "enabled opts into thinking" true
    (Masc.Tool_local_runtime_probe.effective_think_enabled
       Masc.Tool_local_runtime_probe.Think_enabled)

let test_runtime_probe_reports_effective_think_mode () =
  let open Yojson.Safe.Util in
  let run mode =
    Eio_main.run @@ fun _env ->
    Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
      ~server_url:"http://127.0.0.1:1" ~model:"dummy-probe-model" ~think_mode:mode
      ~timeout_sec:3 ~ps_timeout_sec:1 ()
  in
  let auto = run Masc.Tool_local_runtime_probe.Think_auto in
  check string "auto mode reported" "auto"
    (auto |> member "think_mode" |> to_string);
  check bool "auto effective think false" false
    (auto |> member "think" |> to_bool);
  let enabled = run Masc.Tool_local_runtime_probe.Think_enabled in
  check string "enabled mode reported" "enabled"
    (enabled |> member "think_mode" |> to_string);
  check bool "enabled effective think true" true
    (enabled |> member "think" |> to_bool)

let test_runtime_probe_status_only_skip_reports_reason () =
  let json =
    Eio_main.run @@ fun _env ->
    Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
      ~server_url:"http://127.0.0.1:1" ~model:"dummy-probe-model" ~run_generate:false
      ~timeout_sec:3 ~ps_timeout_sec:1 ()
  in
  let open Yojson.Safe.Util in
  check string "skip reason reported" "status_only"
    (json |> member "generate_skip_reason" |> to_string);
  check bool "status-only flag reported" false
    (json |> member "run_generate" |> to_bool)

let test_normalize_server_url_strips_trailing_slashes () =
  check string "normalizes trailing slash" "http://127.0.0.1:11434"
    (Masc.Tool_local_runtime_probe.normalize_ollama_server_url
       " http://127.0.0.1:11434/// ")

let test_endpoint_urls_use_normalized_base () =
  check string "ps endpoint normalized" "http://127.0.0.1:11434/api/ps"
    (Masc.Tool_local_runtime_probe.ollama_ps_url
       "http://127.0.0.1:11434/");
  check string "generate endpoint normalized"
    "http://127.0.0.1:11434/api/generate"
    (Masc.Tool_local_runtime_probe.ollama_generate_url
       "http://127.0.0.1:11434///")

let test_curl_get_argv_keeps_curl_as_executable_with_headers () =
  let argv =
    Masc.Tool_local_runtime_http.curl_get_argv_for_test
      ~timeout_sec:30
      ~headers:
        [
          ("User-Agent", "Mozilla/5.0 (compatible; MASC-FetchWeb/1.0)");
          ("Accept-Language", "en-US,en;q=0.8");
        ]
      ~follow_redirects:true
      ~max_redirects:3
      ~compressed:true
      ~max_response_bytes:2_000_000
      "https://example.com/page"
  in
  check string "argv0 remains curl" "curl" (List.hd argv);
  check bool "header arg present" true (List.mem "-H" argv);
  check bool "redirect arg present" true (List.mem "--location" argv);
  check bool "compression arg present" true (List.mem "--compressed" argv);
  check bool "body cap arg present" true (List.mem "--max-filesize" argv);
  check bool "body cap does not force range response" false (List.mem "--range" argv);
  check bool "curl emits structured metadata" true
    (List.exists
       (fun arg ->
         contains_substring arg "%{url_effective}"
         && contains_substring arg "%{content_type}")
       argv);
  check bool "curl is not repeated after headers" false (List.mem "curl" (List.tl argv))

let test_ollama_ps_non_200_is_reported_as_error () =
  check string "ps non-200 surfaced" "ollama ps returned http 503"
    (Masc.Tool_local_runtime_probe.ollama_http_error "ps" (Some 503))

let test_kv_cache_assessment_detects_repeat_improvement () =
  let runs =
    [
      `Assoc
        [
          ("run_index", `Int 1);
          ("prompt_eval_duration_ms", `Float 500.0);
        ];
      `Assoc
        [
          ("run_index", `Int 2);
          ("prompt_eval_duration_ms", `Float 260.0);
        ];
      `Assoc
        [
          ("run_index", `Int 3);
          ("prompt_eval_duration_ms", `Float 280.0);
        ];
    ]
  in
  let assessment = Masc.Tool_local_runtime.kv_cache_assessment_json runs in
  let open Yojson.Safe.Util in
  check string "likely reuse" "likely_reused"
    (assessment |> member "signal" |> to_string);
  check (option int) "best repeat run"
    (Some 2)
    (match assessment |> member "best_repeat_run_index" with
    | `Int value -> Some value
    | _ -> None)

let test_kv_cache_assessment_requires_two_successful_runs () =
  let assessment =
    Masc.Tool_local_runtime.kv_cache_assessment_json
      [ `Assoc [ ("run_index", `Int 1) ] ]
  in
  let open Yojson.Safe.Util in
  check string "insufficient data" "insufficient_data"
    (assessment |> member "signal" |> to_string)

let test_generate_probe_decision_reports_typed_reasons () =
  let decision ?(effective_model = Some "qwen3") ?before_status
      ?before_error ?(run_generate = true) ?(generate_when_unloaded = true)
      ?(effective_model_loaded_before = false) () =
    Masc.Tool_local_runtime_probe.decide_generate_probe ~effective_model
      ~before_status ~before_error ~run_generate ~generate_when_unloaded
      ~effective_model_loaded_before
    |> Masc.Tool_local_runtime_probe.generate_probe_decision_to_string
  in
  check string "no model reason" "no_effective_model"
    (decision ~effective_model:None ());
  check string "status-only reason" "status_only"
    (decision ~run_generate:false ());
  check string "preflight error reason" "ps_error"
    (decision ~before_status:200 ~before_error:"curl exit code 28" ());
  check string "cold model skip reason" "model_unloaded"
    (decision ~before_status:200 ~generate_when_unloaded:false ());
  check string "unknown preflight skip reason" "policy_skip"
    (decision ~generate_when_unloaded:false ());
  check string "default path with no status runs when enabled" "run_generate"
    (decision ());
  check string "loaded model runs even with cold-load disabled" "run_generate"
    (decision ~before_status:200 ~generate_when_unloaded:false
       ~effective_model_loaded_before:true ())

let () =
  run "tool_local_runtime_probe"
    [
      ( "ps",
        [
          test_case "extracts loaded models" `Quick
            test_ollama_ps_parser_extracts_loaded_models;
        ] );
      ( "generate",
        [
          test_case "normalizes server url before endpoint join" `Quick
            test_normalize_server_url_strips_trailing_slashes;
          test_case "builds normalized endpoint urls" `Quick
            test_endpoint_urls_use_normalized_base;
          test_case "curl argv keeps executable before headers" `Quick
            test_curl_get_argv_keeps_curl_as_executable_with_headers;
          test_case "reports ps non-200 as error" `Quick
            test_ollama_ps_non_200_is_reported_as_error;
          test_case "omits keep_alive by default" `Quick
            test_request_body_omits_keep_alive_by_default;
          test_case "can enable thinking explicitly" `Quick
            test_request_body_can_enable_thinking;
          test_case "keeps explicit keep_alive when requested" `Quick
            test_request_body_keeps_explicit_keep_alive;
          test_case "parses adaptive think policy" `Quick
            test_think_mode_parses_adaptive_policy;
          test_case "auto think policy prioritizes response" `Quick
            test_auto_think_policy_prioritizes_response;
          test_case "runtime probe reports effective think mode" `Quick
            test_runtime_probe_reports_effective_think_mode;
          test_case "status-only skip reports reason" `Quick
            test_runtime_probe_status_only_skip_reports_reason;
          test_case "computes tok per second from generate response" `Quick
            test_ollama_generate_parser_computes_tok_per_second;
        ] );
      ( "kv_assessment",
        [
          test_case "detects likely reuse from repeated prompt eval drop" `Quick
            test_kv_cache_assessment_detects_repeat_improvement;
          test_case "needs at least two successful runs" `Quick
            test_kv_cache_assessment_requires_two_successful_runs;
          test_case "generate probe decision reports typed reasons" `Quick
            test_generate_probe_decision_reports_typed_reasons;
        ] );
    ]
