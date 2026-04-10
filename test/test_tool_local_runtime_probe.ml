open Alcotest

let check_float_close label expected actual =
  check bool label true (Float.abs (expected -. actual) < 0.001)

let test_ollama_ps_parser_extracts_loaded_models () =
  let json =
    Yojson.Safe.from_string
      {|{"models":[{"name":"qwen3.5:35b-a3b-coding-nvfp4","model":"qwen3.5:35b-a3b-coding-nvfp4","size_vram":21474836480,"context_length":262144,"expires_at":"2026-04-10T00:00:00Z"}]}|}
  in
  let models = Masc_mcp.Tool_local_runtime.ollama_loaded_models_of_ps_json json in
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
    Masc_mcp.Tool_local_runtime.ollama_probe_run_of_generate_json ~run_index:1
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
    Masc_mcp.Tool_local_runtime_probe.request_body_json
      ~keep_alive:None ~model_id:"qwen3.5:35b-a3b-coding-nvfp4" ~prompt:"READY"
      ~max_tokens:8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check (option string) "keep_alive omitted"
    None
    (json |> member "keep_alive" |> to_string_option)

let test_request_body_keeps_explicit_keep_alive () =
  let json =
    Masc_mcp.Tool_local_runtime_probe.request_body_json
      ~keep_alive:(Some "90s") ~model_id:"qwen3.5:35b-a3b-coding-nvfp4"
      ~prompt:"READY" ~max_tokens:8
    |> Yojson.Safe.from_string
  in
  let open Yojson.Safe.Util in
  check (option string) "keep_alive included"
    (Some "90s")
    (json |> member "keep_alive" |> to_string_option)

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
  let assessment = Masc_mcp.Tool_local_runtime.kv_cache_assessment_json runs in
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
    Masc_mcp.Tool_local_runtime.kv_cache_assessment_json
      [ `Assoc [ ("run_index", `Int 1) ] ]
  in
  let open Yojson.Safe.Util in
  check string "insufficient data" "insufficient_data"
    (assessment |> member "signal" |> to_string)

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
          test_case "omits keep_alive by default" `Quick
            test_request_body_omits_keep_alive_by_default;
          test_case "keeps explicit keep_alive when requested" `Quick
            test_request_body_keeps_explicit_keep_alive;
          test_case "computes tok per second from generate response" `Quick
            test_ollama_generate_parser_computes_tok_per_second;
        ] );
      ( "kv_assessment",
        [
          test_case "detects likely reuse from repeated prompt eval drop" `Quick
            test_kv_cache_assessment_detects_repeat_improvement;
          test_case "needs at least two successful runs" `Quick
            test_kv_cache_assessment_requires_two_successful_runs;
        ] );
    ]
