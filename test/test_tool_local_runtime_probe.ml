open Alcotest

let check_float_close label expected actual =
  check bool label true (Float.abs (expected -. actual) < 0.001)

let test_ollama_ps_parser_extracts_loaded_models () =
  let json =
    Yojson.Safe.from_string
      {|{"models":[{"name":"qwen3.5:35b-a3b-coding-nvfp4","model":"qwen3.5:35b-a3b-coding-nvfp4","size_vram":21474836480,"context_length":262144,"expires_at":"2026-04-10T00:00:00Z"}]}|}
  in
  let models = Masc.Tool_local_runtime_probe.ollama_loaded_models_of_ps_json json in
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
    Masc.Tool_local_runtime_probe.ollama_probe_run_of_generate_json ~run_index:1
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

let test_runtime_probe_preserves_positive_timeout () =
  let timeout_of requested =
    Eio_main.run @@ fun _env ->
    Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
      ~server_url:"http://127.0.0.1:1"
      ~model:"dummy-probe-model"
      ~run_generate:false
      ~timeout_sec:requested
      ~ps_timeout_sec:1
      ()
    |> Yojson.Safe.Util.member "timeout_sec"
    |> Yojson.Safe.Util.to_int
  in
  check int "below old floor is unchanged" 1 (timeout_of 1);
  check int "above old cap is unchanged" 301 (timeout_of 301)

let test_runtime_probe_rejects_nonpositive_timeout () =
  check_raises
    "zero timeout is rejected before I/O"
    (Invalid_argument "timeout_sec must be a positive integer (got 0)")
    (fun () ->
      ignore
        (Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
           ~server_url:"http://127.0.0.1:1"
           ~timeout_sec:0
           ()))

let test_dispatch_rejects_invalid_timeout_before_authorization () =
  let authorization_calls = ref 0 in
  let authorize_external_effect ~operation:_ ~input:_ ~continue:_ =
    incr authorization_calls;
    fail "invalid input must not reach authorization"
  in
  let context : Masc.Tool_local_runtime_core.context =
    {
      config = Masc.Workspace.default_config "/tmp";
      agent_name = "probe-timeout-test";
      authorize_external_effect = Some authorize_external_effect;
    }
  in
  let expect_rejection label timeout_json =
    match
      Masc.Tool_local_runtime.dispatch context
        ~name:"masc_runtime_ollama_probe"
        ~args:(`Assoc [ ("timeout_sec", timeout_json) ])
    with
    | None -> fail "Ollama probe handler was not selected"
    | Some result ->
        check bool (label ^ " failed") true (Tool_result.is_failed result);
        check
          bool
          (label ^ " is a typed workflow rejection")
          true
          (Tool_result.failure_class result
           = Some Tool_result.Workflow_rejection)
  in
  expect_rejection "non-positive timeout" (`Int 0);
  expect_rejection "wrong-shape timeout" (`String "301");
  check int "authorization was not invoked" 0 !authorization_calls

(* #24851 stopped timeout_sec from quietly rewriting operator intent. The
   knobs beside it kept doing it: probe_runs 10 ran 4 times and reported ok,
   and ps_timeout_sec was declared on the function but never read from the
   tool arguments at all, so it was pinned at its default. #25006 brings the
   three in line -- same rejection shape, same place, before the Gate. *)
let test_bounded_knobs_are_rejected_not_rewritten () =
  let cases =
    [ ("probe_runs above range", "probe_runs must be an integer in [1, 4] (got 10)",
       fun () ->
         Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
           ~server_url:"http://127.0.0.1:1" ~probe_runs:10 ())
    ; ("probe_runs below range", "probe_runs must be an integer in [1, 4] (got 0)",
       fun () ->
         Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
           ~server_url:"http://127.0.0.1:1" ~probe_runs:0 ())
    ; ("max_tokens above range", "max_tokens must be an integer in [1, 128] (got 129)",
       fun () ->
         Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
           ~server_url:"http://127.0.0.1:1" ~max_tokens:129 ())
    ; ("ps_timeout_sec above range",
       "ps_timeout_sec must be an integer in [1, 30] (got 31)",
       fun () ->
         Masc.Tool_local_runtime_probe.runtime_ollama_probe_json
           ~server_url:"http://127.0.0.1:1" ~ps_timeout_sec:31 ())
    ]
  in
  List.iter
    (fun (label, message, run) ->
      check_raises label (Invalid_argument message) (fun () -> ignore (run ())))
    cases

let test_dispatch_rejects_bounded_knobs_before_authorization () =
  let authorization_calls = ref 0 in
  let authorize_external_effect ~operation:_ ~input:_ ~continue:_ =
    incr authorization_calls;
    fail "out-of-range input must not reach authorization"
  in
  let context : Masc.Tool_local_runtime_core.context =
    {
      config = Masc.Workspace.default_config "/tmp";
      agent_name = "probe-bounds-test";
      authorize_external_effect = Some authorize_external_effect;
    }
  in
  let expect_rejection label args =
    match
      Masc.Tool_local_runtime.dispatch context
        ~name:"masc_runtime_ollama_probe"
        ~args:(`Assoc args)
    with
    | None -> fail "Ollama probe handler was not selected"
    | Some result ->
        check bool (label ^ " failed") true (Tool_result.is_failed result);
        check bool
          (label ^ " is a typed workflow rejection")
          true
          (Tool_result.failure_class result = Some Tool_result.Workflow_rejection)
  in
  expect_rejection "probe_runs above range" [ ("probe_runs", `Int 10) ];
  expect_rejection "max_tokens above range" [ ("max_tokens", `Int 500) ];
  expect_rejection "ps_timeout_sec above range" [ ("ps_timeout_sec", `Int 60) ];
  (* A string where an integer belongs used to read back as the default and
     run a probe the caller never asked for. *)
  expect_rejection "wrong-shape probe_runs" [ ("probe_runs", `String "2") ];
  expect_rejection "wrong-shape max_tokens" [ ("max_tokens", `Bool true) ];
  check int "authorization was not invoked" 0 !authorization_calls

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
  check string "-q disables ~/.curlrc and must come first" "-q" (List.nth argv 1);
  check bool "header arg present" true (List.mem "-H" argv);
  check bool "redirect arg present" true (List.mem "--location" argv);
  check bool "compression arg present" true (List.mem "--compressed" argv);
  check bool "body cap arg present" true (List.mem "--max-filesize" argv);
  check bool "body cap does not force range response" false (List.mem "--range" argv);
  check bool "curl emits structured metadata" true
    (List.exists
       (fun arg ->
         String_util.contains_substring arg "%{url_effective}"
         && String_util.contains_substring arg "%{content_type}")
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
  let assessment = Masc.Tool_local_runtime_probe.kv_cache_assessment_json runs in
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
    Masc.Tool_local_runtime_probe.kv_cache_assessment_json
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

let required_runtime_metadata name =
  match Tool_catalog.registered_metadata name with
  | Some metadata -> metadata
  | None -> failf "missing runtime metadata for %s" name
;;

let test_runtime_tool_authority_matches_effects () =
  let verify = required_runtime_metadata "masc_runtime_verify" in
  check bool "verify requires operator authority" true
    (verify.required_permission = Masc_domain.CanAdmin);
  check (option bool) "verify is not read-only" (Some false) verify.readonly;
  check (option bool) "verify is not idempotent" (Some false) verify.idempotent;
  let probe = required_runtime_metadata "masc_runtime_ollama_probe" in
  check bool "probe requires operator authority" true
    (probe.required_permission = Masc_domain.CanAdmin);
  check (option bool) "probe is not read-only" (Some false) probe.readonly;
  check (option bool) "probe is not idempotent" (Some false) probe.idempotent;
  List.iter
    (fun tool_name ->
      (match
         Auth.authorize_tool_for_role
           ~agent_name:"runtime-probe-worker"
           ~role:Masc_domain.Worker
           ~tool_name
       with
       | Error (Masc_domain.Auth (Masc_domain.Auth_error.Forbidden _)) -> ()
       | Ok () -> failf "Worker must not invoke operator tool %s" tool_name
       | Error error ->
         failf "unexpected Worker authorization error: %s"
           (Masc_domain.masc_error_to_string error));
      match
        Auth.authorize_tool_for_role
          ~agent_name:"runtime-probe-admin"
          ~role:Masc_domain.Admin
          ~tool_name
      with
      | Ok () -> ()
      | Error error ->
        failf "Admin must retain %s access: %s" tool_name
          (Masc_domain.masc_error_to_string error))
    [ "masc_runtime_verify"; "masc_runtime_ollama_probe" ]
;;

let test_runtime_verify_pool_selection_fails_closed () =
  let select ?runtime_pool () =
    Masc.Tool_local_runtime_verify.For_testing.select_endpoint_urls_for_pool
      ?runtime_pool
      [ "http://127.0.0.1:19001"; "http://127.0.0.1:19002" ]
  in
  check (option (list string)) "default selects the discovered pool"
    (Some [ "http://127.0.0.1:19001"; "http://127.0.0.1:19002" ])
    (select ());
  check (option (list string)) "runtime id selects one endpoint"
    (Some [ "http://127.0.0.1:19002" ])
    (select ~runtime_pool:"local-19002" ());
  check (option (list string)) "unknown explicit pool selects nothing"
    None
    (select ~runtime_pool:"missing-pool" ())
;;

let test_runtime_verify_requests_external_effect_authorization () =
  let calls = ref [] in
  let authorize_external_effect ~operation ~input ~continue:_ =
    calls := (operation, input) :: !calls;
    Tool_result.ok
      ~tool_name:operation
      ~start_time:0.0
      {|{"ok":true,"effect":"intercepted"}|}
  in
  let args = `Assoc [ "runtime_pool", `String "local-19002" ] in
  let context : Masc.Tool_local_runtime_core.context =
    { config = Masc.Workspace.default_config "/tmp"
    ; agent_name = "runtime-verify-effect-test"
    ; authorize_external_effect = Some authorize_external_effect
    }
  in
  (match
     Masc.Tool_local_runtime.dispatch context ~name:"masc_runtime_verify" ~args
   with
   | Some result ->
     check bool "authorizer intercepts before completion" true
       (Tool_result.is_success result)
   | None -> fail "runtime verify handler was not selected");
  match !calls with
  | [ operation, input ] ->
    check string "exact operation" "masc_runtime_verify" operation;
    check string "complete input"
      (Yojson.Safe.to_string args)
      (Yojson.Safe.to_string input)
  | calls -> failf "expected one authorization request, got %d" (List.length calls)
;;

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
          test_case "preserves every positive explicit timeout" `Quick
            test_runtime_probe_preserves_positive_timeout;
          test_case "rejects non-positive timeout before I/O" `Quick
            test_runtime_probe_rejects_nonpositive_timeout;
          test_case "rejects invalid timeout before authorization" `Quick
            test_dispatch_rejects_invalid_timeout_before_authorization;
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
      ( "policy",
        [
          test_case "authority and execution policy match effects" `Quick
            test_runtime_tool_authority_matches_effects;
          test_case "explicit runtime pool selection fails closed" `Quick
            test_runtime_verify_pool_selection_fails_closed;
          test_case "runtime verify requests external effect authorization" `Quick
            test_runtime_verify_requests_external_effect_authorization;
        ] );
      ( "bounded_knobs",
        [
          test_case "out-of-range knobs are rejected, not rewritten" `Quick
            test_bounded_knobs_are_rejected_not_rewritten;
          test_case "dispatch rejects them before authorization" `Quick
            test_dispatch_rejects_bounded_knobs_before_authorization;
        ] );
    ]
