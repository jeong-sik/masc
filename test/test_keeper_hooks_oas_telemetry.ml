open Alcotest
open Yojson.Safe.Util

module Hooks = Masc_mcp.Keeper_hooks_oas

let temp_counter = ref 0

let temp_dir () =
  incr temp_counter;
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "keeper-hooks-oas-%d-%06d" (Unix.getpid ()) !temp_counter)
  in
  Unix.mkdir dir 0o755;
  dir

let read_jsonl_line path =
  let ic = open_in path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
      input_line ic |> Yojson.Safe.from_string)

let make_usage ?cost_usd ~input_tokens ~output_tokens ()
    : Agent_sdk.Types.api_usage =
  {
    input_tokens;
    output_tokens;
    cache_creation_input_tokens = 0;
    cache_read_input_tokens = 0;
    cost_usd;
  }

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [
          ("name", `String name);
          ("agent_name", `String name);
          ("trace_id", `String ("trace-" ^ name));
          ("cascade_name", `String Masc_mcp.Keeper_config.default_cascade_name);
          ("last_model_used", `String "test-model");
        ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)

let make_test_hooks keeper_name =
  let config = Masc_mcp.Coord.default_config (temp_dir ()) in
  let meta_ref = ref (make_meta keeper_name) in
  Hooks.make_hooks ~config ~meta_ref ~generation:1 ()

let lifecycle_callback_failure_count ~keeper ~callback =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_keeper_lifecycle_callback_failures
    ~labels:[ ("keeper", keeper); ("callback", callback) ]
    ()

let on_stop_count ~keeper ~stop_reason =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_keeper_oas_on_stop
    ~labels:[ ("keeper", keeper); ("stop_reason", stop_reason) ]
    ()

let on_idle_escalated_count ~keeper ~severity ~decision =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_keeper_oas_on_idle_escalated
    ~labels:
      [
        ("keeper", keeper);
        ("severity", severity);
        ("decision", decision);
      ]
    ()

let require_hook label = function
  | Some hook -> hook
  | None -> failf "expected active hook: %s" label

let check_continue label = function
  | Agent_sdk.Hooks.Continue -> ()
  | _ -> failf "%s: expected Continue" label

let check_nudge label = function
  | Agent_sdk.Hooks.Nudge _ -> ()
  | _ -> failf "%s: expected Nudge" label

let test_emit_cost_event_writes_inference_telemetry () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry = {
    system_fingerprint = None;
    timings = Some {
      prompt_n = Some 11;
      prompt_ms = Some 510.0;
      prompt_per_second = Some 21.55;
      predicted_n = Some 5;
      predicted_ms = Some 61.3;
      predicted_per_second = Some 81.56;
      cache_n = Some 7;
    };
    reasoning_tokens = Some 3;
    reasoning_tokens_estimated = false;
    request_latency_ms = Some 42;
    peak_memory_gb = Some 52.66;
    provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat;
    reasoning_effort = None;
    canonical_model_id = Some "gpt-4";
    effective_context_window = Some 128000;
    provider_internal_action_count = None;
  } in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:(Some "task-1") ~model:"glm-coding:glm-5.1"
    ~input_tokens:11 ~output_tokens:5 ~cost_usd:0.12
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider" "glm-coding" (json |> member "provider" |> to_string);
  check int "reasoning_tokens" 3 (json |> member "reasoning_tokens" |> to_int);
  check int "cache_n" 7 (json |> member "cache_n" |> to_int);
  check int "request_latency_ms" 42 (json |> member "request_latency_ms" |> to_int);
  check (float 0.001) "tokens_per_second" (5.0 /. 0.042)
    (json |> member "tokens_per_second" |> to_float);
  check (float 0.001) "prompt_per_second" 21.55
    (json |> member "prompt_per_second" |> to_float);
  check (float 0.001) "provider_tokens_per_second" 81.56
    (json |> member "provider_tokens_per_second" |> to_float);
  check (float 0.001) "hw_decode_tokens_per_second" 81.56
    (json |> member "hw_decode_tokens_per_second" |> to_float);
  check (float 0.001) "peak_memory_gb" 52.66
    (json |> member "peak_memory_gb" |> to_float)

let test_emit_cost_event_marks_usage_missing () =
  let root = temp_dir () in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"kimi_cli:kimi-for-coding"
    ~input_tokens:0 ~output_tokens:0 ~cost_usd:0.0
    ~usage_missing:true ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check bool "usage_missing" true
    (json |> member "usage_missing" |> to_bool)

let test_emit_cost_event_uses_typed_provider_kind_for_bare_model () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    {
      system_fingerprint = None;
      timings = None;
      reasoning_tokens = None;
      reasoning_tokens_estimated = false;
      request_latency_ms = Some 0;
      peak_memory_gb = None;
      provider_kind = Some Llm_provider.Provider_kind.Kimi_cli;
      reasoning_effort = None;
      canonical_model_id = None;
      effective_context_window = None;
      provider_internal_action_count = None;
    }
  in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"kimi-for-coding"
    ~input_tokens:0 ~output_tokens:0 ~cost_usd:0.0
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider from provider_kind" "kimi_cli"
    (json |> member "provider" |> to_string);
  check bool "zero latency is omitted" true
    (match json |> member "request_latency_ms" with `Null -> true | _ -> false)

let test_emit_cost_event_writes_wall_tok_s_without_provider_timings () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry = {
    system_fingerprint = None;
    timings = None;
    reasoning_tokens = None;
    reasoning_tokens_estimated = false;
    request_latency_ms = Some 250;
    peak_memory_gb = None;
    provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat;
    reasoning_effort = None;
    canonical_model_id = Some "auto";
    effective_context_window = Some 128000;
    provider_internal_action_count = None;
  } in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"ollama:qwen3.6:27b-coding-nvfp4"
    ~input_tokens:100 ~output_tokens:50 ~cost_usd:0.0
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check (float 0.001) "wall tokens_per_second" 200.0
    (json |> member "tokens_per_second" |> to_float);
  check bool "native prompt timing absent" true
    (match json |> member "prompt_per_second" with `Null -> true | _ -> false);
  check bool "native decode timing absent" true
    (match json |> member "hw_decode_tokens_per_second" with
     | `Null -> true
     | _ -> false)

let test_emit_cost_event_marks_untrusted_usage () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    {
      system_fingerprint = None;
      timings = None;
      reasoning_tokens = None;
      reasoning_tokens_estimated = false;
      request_latency_ms = Some 250;
      peak_memory_gb = None;
      provider_kind = Some Llm_provider.Provider_kind.Ollama;
      reasoning_effort = None;
      canonical_model_id = Some "ollama:qwen3.6:27b-coding-nvfp4";
      effective_context_window = Some 128000;
      provider_internal_action_count = None;
    }
  in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"ollama:qwen3.6:27b-coding-nvfp4"
    ~input_tokens:2_000_000 ~output_tokens:50 ~cost_usd:0.99
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "usage trust" "untrusted"
    (json |> member "usage_trust" |> to_string);
  check bool "usage anomaly" true
    (json |> member "usage_anomaly" |> to_bool);
  let reasons =
    json |> member "usage_anomaly_reasons" |> to_list |> List.map to_string
  in
  check bool "reason includes absurd input" true
    (List.mem "input_tokens_gt_1m" reasons);
  check bool "reason includes context overrun" true
    (List.mem "input_tokens_gt_2x_context_max" reasons);
  check int "safe input tokens" 0
    (json |> member "input_tokens" |> to_int);
  check int "safe output tokens" 0
    (json |> member "output_tokens" |> to_int);
  check (float 0.001) "safe cost" 0.0
    (json |> member "cost_usd" |> to_float);
  check int "raw input tokens retained" 2_000_000
    (json |> member "raw_input_tokens" |> to_int);
  check int "raw output tokens retained" 50
    (json |> member "raw_output_tokens" |> to_int);
  check bool "wall tok/s omitted" true
    (match json |> member "tokens_per_second" with
     | `Null -> true
     | _ -> false)

let test_emit_cost_event_marks_unpriced_paid_model () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    {
      system_fingerprint = None;
      timings = None;
      reasoning_tokens = None;
      reasoning_tokens_estimated = false;
      request_latency_ms = Some 100;
      peak_memory_gb = None;
      provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat;
      reasoning_effort = None;
      canonical_model_id = Some "future-openai-model-v9";
      effective_context_window = Some 128000;
      provider_internal_action_count = None;
    }
  in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"future-openai-model-v9"
    ~input_tokens:1000 ~output_tokens:500 ~cost_usd:0.0
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider" "openai" (json |> member "provider" |> to_string);
  check string "cost status" "unpriced_model"
    (json |> member "cost_status" |> to_string);
  check string "cost reason" "pricing_catalog_miss"
    (json |> member "cost_status_reason" |> to_string);
  check string "pricing model" "future-openai-model-v9"
    (json |> member "cost_pricing_model" |> to_string);
  check string "pricing catalog" "miss"
    (json |> member "cost_pricing_catalog" |> to_string)

let test_emit_cost_event_records_auto_resolution_source () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    {
      system_fingerprint = None;
      timings = None;
      reasoning_tokens = None;
      reasoning_tokens_estimated = false;
      request_latency_ms = Some 100;
      peak_memory_gb = None;
      provider_kind = Some Llm_provider.Provider_kind.OpenAI_compat;
      reasoning_effort = None;
      canonical_model_id = Some "gpt-4.1";
      effective_context_window = Some 128000;
      provider_internal_action_count = None;
    }
  in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"auto"
    ~input_tokens:1000 ~output_tokens:500 ~cost_usd:0.01
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider" "openai" (json |> member "provider" |> to_string);
  check string "pricing model" "gpt-4.1"
    (json |> member "cost_pricing_model" |> to_string);
  check string "model resolution source" "telemetry_canonical_alias"
    (json |> member "model_resolution_source" |> to_string);
  check string "pricing catalog" "hit_paid"
    (json |> member "cost_pricing_catalog" |> to_string);
  check string "cost status" "priced"
    (json |> member "cost_status" |> to_string)

let test_emit_cost_event_records_provider_prefixed_auto_resolution_source () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    {
      system_fingerprint = None;
      timings = None;
      reasoning_tokens = None;
      reasoning_tokens_estimated = false;
      request_latency_ms = Some 100;
      peak_memory_gb = None;
      provider_kind = Some Llm_provider.Provider_kind.Kimi_cli;
      reasoning_effort = None;
      canonical_model_id = Some "kimi-for-coding";
      effective_context_window = Some 128000;
      provider_internal_action_count = None;
    }
  in
  Hooks.emit_cost_event ~masc_root:root ~agent_name:"keeper"
    ~task_id:None ~model:"kimi_cli:auto"
    ~input_tokens:1000 ~output_tokens:500 ~cost_usd:0.0
    ~telemetry ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider" "kimi_cli" (json |> member "provider" |> to_string);
  check string "pricing model" "kimi-for-coding"
    (json |> member "cost_pricing_model" |> to_string);
  check string "model resolution source" "telemetry_canonical_alias"
    (json |> member "model_resolution_source" |> to_string);
  check string "cost status" "known_free"
    (json |> member "cost_status" |> to_string)

let test_cost_usd_for_usage_falls_back_for_paid_provider () =
  let model = "openai:gpt-4.1" in
  let usage = make_usage ~input_tokens:1000 ~output_tokens:500 () in
  let expected = Hooks.estimate_usage_cost_usd ~model usage in
  check (float 0.000001) "estimated fallback" expected
    (Hooks.cost_usd_for_usage ~model usage)

let test_cost_usd_for_usage_preserves_reported_cost () =
  let model = "openai:gpt-4.1" in
  let usage =
    make_usage ~cost_usd:0.42 ~input_tokens:1000 ~output_tokens:500 ()
  in
  check (float 0.000001) "reported cost" 0.42
    (Hooks.cost_usd_for_usage ~model usage)

let test_cost_usd_for_usage_keeps_cli_provider_zero () =
  let model = "kimi_cli:kimi-for-coding" in
  let usage = make_usage ~input_tokens:1000 ~output_tokens:500 () in
  check (float 0.000001) "cli cost stays zero" 0.0
    (Hooks.cost_usd_for_usage ~model usage)

let test_cost_usd_for_usage_keeps_typed_cli_provider_zero () =
  let model = "kimi-for-coding" in
  let usage = make_usage ~input_tokens:1000 ~output_tokens:500 () in
  check (float 0.000001) "typed cli cost stays zero" 0.0
    (Hooks.cost_usd_for_usage
       ~provider_kind:Llm_provider.Provider_kind.Kimi_cli
       ~model usage)

let test_tool_execution_summary_derives_provider_and_outcome () =
  let summary =
    Hooks.tool_execution_summary
      ~tool_name:"keeper_shell"
      ~model:"codex_cli:gpt-5.4"
      ~success:false
      ~duration_ms:12.5
  in
  check string "tool name" "keeper_shell" summary.tool_name;
  check string "provider" "codex_cli" summary.provider;
  check string "outcome" "error" summary.outcome;
  check (float 0.001) "duration" 12.5 summary.duration_ms

let test_trajectory_duration_ms_preserves_positive_sub_ms () =
  check int "positive sub-ms" 1 (Hooks.trajectory_duration_ms 0.4);
  check int "rounded positive" 13 (Hooks.trajectory_duration_ms 12.5)

let test_trajectory_duration_ms_rejects_zero_and_non_finite () =
  check int "zero" 0 (Hooks.trajectory_duration_ms 0.0);
  check int "negative" 0 (Hooks.trajectory_duration_ms (-0.1));
  check int "nan" 0 (Hooks.trajectory_duration_ms nan);
  check int "infinity" 0 (Hooks.trajectory_duration_ms infinity)

let test_record_keeper_tool_duration_metric_tracks_labels () =
  let summary =
    Hooks.tool_execution_summary
      ~tool_name:"keeper_board_post"
      ~model:"glm-coding:glm-5.1"
      ~success:true
      ~duration_ms:250.0
  in
  let labels =
    [ ("keeper", "telemetry-test")
    ; ("provider", "glm-coding")
    ; ("tool", "keeper_board_post")
    ; ("outcome", "ok")
    ]
  in
  let sum_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_tool_call_duration
      ~labels
      ()
  in
  let count_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      (Masc_mcp.Prometheus.metric_keeper_tool_call_duration ^ "_count")
      ~labels
      ()
  in
  Hooks.record_keeper_tool_duration_metric
    ~keeper_name:"telemetry-test"
    summary;
  let sum_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_keeper_tool_call_duration
      ~labels
      ()
  in
  let count_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      (Masc_mcp.Prometheus.metric_keeper_tool_call_duration ^ "_count")
      ~labels
      ()
  in
  check (float 0.0001) "sum delta" 0.25 (sum_after -. sum_before);
  check (float 0.0001) "count delta" 1.0 (count_after -. count_before)

let make_telemetry
    ?(prompt_per_second : float option = None)
    ?(predicted_per_second : float option = None)
    ?(request_latency_ms = 0)
    ?(provider_kind : Llm_provider.Provider_kind.t option = None)
    ?(include_timings = true)
    () : Agent_sdk.Types.inference_telemetry =
  let timings : Agent_sdk.Types.inference_timings option =
    if include_timings then
      Some {
        prompt_n = None;
        prompt_ms = None;
        prompt_per_second;
        predicted_n = None;
        predicted_ms = None;
        predicted_per_second;
        cache_n = None;
      }
    else None
  in
  {
    system_fingerprint = None;
    timings;
    reasoning_tokens = None;
    reasoning_tokens_estimated = false;
    request_latency_ms = Some request_latency_ms;
    peak_memory_gb = None;
    provider_kind;
    reasoning_effort = None;
    canonical_model_id = None;
    effective_context_window = None;
    provider_internal_action_count = None;
  }

let make_response ?(stop_reason = Agent_sdk.Types.EndTurn) ?telemetry () =
  {
    Agent_sdk.Types.id = "response-test";
    model = "test-model";
    stop_reason;
    content = [];
    usage = None;
    telemetry;
  }

let histogram_snapshot metric ~labels =
  let sum =
    Masc_mcp.Prometheus.metric_value_or_zero metric ~labels ()
  in
  let count =
    Masc_mcp.Prometheus.metric_value_or_zero (metric ^ "_count") ~labels ()
  in
  sum, count

let test_record_llm_tok_s_metrics_both_histograms_observe () =
  let telemetry =
    make_telemetry
      ~prompt_per_second:(Some 123.5)
      ~predicted_per_second:(Some 87.25)
      ~request_latency_ms:42
      ~provider_kind:(Some Llm_provider.Provider_kind.Ollama)
      () in
  let labels =
    [ "model", "ollama:qwen3.6"
    ; "provider", "ollama"
    ; "provider_kind", "ollama"
    ]
  in
  let prompt_sum_before, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  let decode_sum_before, decode_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec
      ~labels in
  Hooks.record_llm_tok_s_metrics ~model:"ollama:qwen3.6"
    ~telemetry:(Some telemetry);
  let prompt_sum_after, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  let decode_sum_after, decode_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec
      ~labels in
  check (float 0.001) "prompt sum delta" 123.5
    (prompt_sum_after -. prompt_sum_before);
  check (float 0.001) "prompt count delta" 1.0
    (prompt_count_after -. prompt_count_before);
  check (float 0.001) "decode sum delta" 87.25
    (decode_sum_after -. decode_sum_before);
  check (float 0.001) "decode count delta" 1.0
    (decode_count_after -. decode_count_before)

let test_record_llm_tok_s_metrics_timings_none_is_noop () =
  (* Anthropic/Gemini path: backends populate request_latency_ms but leave
     timings = None.  The helper must not touch the tok/s histograms in
     that case — otherwise the histogram would be polluted with zeros. *)
  let telemetry =
    make_telemetry ~include_timings:false ~request_latency_ms:250
      ~provider_kind:(Some Llm_provider.Provider_kind.Anthropic) ()
  in
  let labels =
    [ "model", "claude:claude-haiku-4-5-20251001"
    ; "provider", "claude"
    ; "provider_kind", "anthropic"
    ]
  in
  let _, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  let _, decode_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec
      ~labels in
  Hooks.record_llm_tok_s_metrics
    ~model:"claude:claude-haiku-4-5-20251001"
    ~telemetry:(Some telemetry);
  let _, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  let _, decode_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec
      ~labels in
  check (float 0.001) "prompt count unchanged" 0.0
    (prompt_count_after -. prompt_count_before);
  check (float 0.001) "decode count unchanged" 0.0
    (decode_count_after -. decode_count_before)

let test_record_llm_tok_s_metrics_zero_value_is_skipped () =
  (* Guard: a backend that reports prompt_per_second = Some 0.0 (e.g. a
     very short prompt processed in sub-millisecond time that rounds to
     zero) should not observe 0 into the histogram, which would skew the
     p50/p95 buckets. *)
  let telemetry =
    make_telemetry
      ~prompt_per_second:(Some 0.0)
      ~predicted_per_second:(Some 55.0)
      ~provider_kind:(Some Llm_provider.Provider_kind.OpenAI_compat) ()
  in
  let labels =
    [ "model", "openai:gpt-5.4"
    ; "provider", "openai"
    ; "provider_kind", "openai_compat"
    ]
  in
  let _, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  let _, decode_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec
      ~labels in
  Hooks.record_llm_tok_s_metrics ~model:"openai:gpt-5.4"
    ~telemetry:(Some telemetry);
  let _, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  let _, decode_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec
      ~labels in
  check (float 0.001) "prompt zero skipped" 0.0
    (prompt_count_after -. prompt_count_before);
  check (float 0.001) "decode positive observed" 1.0
    (decode_count_after -. decode_count_before)

let test_record_llm_tok_s_metrics_none_telemetry_is_noop () =
  (* Belt and braces: explicitly None telemetry must not raise or emit. *)
  let labels =
    [ "model", "unknown:nothing"
    ; "provider", "unknown"
    ; "provider_kind", "unknown"
    ]
  in
  let _, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  Hooks.record_llm_tok_s_metrics ~model:"unknown:nothing" ~telemetry:None;
  let _, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec
      ~labels in
  check (float 0.001) "prompt count unchanged" 0.0
    (prompt_count_after -. prompt_count_before)

let inference_latency_labels model = [("model", model)]

let test_record_llm_inference_latency_metric_positive_observes () =
  let model = "latency-positive-test-model" in
  let labels = inference_latency_labels model in
  let telemetry = make_telemetry ~request_latency_ms:42 () in
  let sum_before, count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration
      ~labels
  in
  let hook_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_hook ~labels ()
  in
  Hooks.record_llm_inference_latency_metric ~model
    ~telemetry:(Some telemetry);
  let sum_after, count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration
      ~labels
  in
  let hook_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_hook ~labels ()
  in
  check (float 0.0001) "latency sum +42ms" 0.042
    (sum_after -. sum_before);
  check (float 0.0001) "latency count +1" 1.0
    (count_after -. count_before);
  check (float 0.0001) "hook counter +1" 1.0
    (hook_after -. hook_before)

let test_record_llm_inference_latency_metric_zero_floors () =
  let model = "latency-zero-test-model" in
  let labels = inference_latency_labels model in
  let telemetry = make_telemetry ~request_latency_ms:0 () in
  let sum_before, count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration
      ~labels
  in
  let zero_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_zero_latency
      ~labels ()
  in
  Hooks.record_llm_inference_latency_metric ~model
    ~telemetry:(Some telemetry);
  let sum_after, count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration
      ~labels
  in
  let zero_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_zero_latency
      ~labels ()
  in
  check (float 0.0001) "zero latency counter +1" 1.0
    (zero_after -. zero_before);
  check (float 0.0001) "latency sum floored to 1ms" 0.001
    (sum_after -. sum_before);
  check (float 0.0001) "latency count +1" 1.0
    (count_after -. count_before)

let test_record_llm_inference_latency_metric_none_counts_missing () =
  let model = "latency-missing-test-model" in
  let labels = inference_latency_labels model in
  let _, count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration
      ~labels
  in
  let missing_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_missing ~labels ()
  in
  Hooks.record_llm_inference_latency_metric ~model ~telemetry:None;
  let _, count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration
      ~labels
  in
  let missing_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_missing ~labels ()
  in
  check (float 0.0001) "missing counter +1" 1.0
    (missing_after -. missing_before);
  check (float 0.0001) "latency histogram unchanged" 0.0
    (count_after -. count_before)

let slot json name = json |> member "slots" |> member name

let string_list_field json key =
  match json |> member key with
  | `List values -> List.map to_string values
  | `Null -> []
  | other ->
      failf "expected %s list, got %s" key (Yojson.Safe.to_string other)

let check_string_list_contains label needle values =
  check bool label true (List.mem needle values)

let check_string_list_not_contains label needle values =
  check bool label false (List.mem needle values)

let test_hook_introspection_reports_current_runtime_slots () =
  let json =
    Hooks.hook_introspection_json
      ~max_cost_usd:0.25
      ~destructive_check:false
      ()
  in
  check string "scope" "keeper_runtime_composite"
    (json |> member "scope" |> to_string);
  check int "slot_count" 14 (json |> member "slot_count" |> to_int);
  check int "active slots" 11
    (json |> member "active_slot_count" |> to_int);
  check int "inactive slots" 3
    (json |> member "inactive_slot_count" |> to_int);
  check bool "before_turn active" true
    (slot json "before_turn" |> member "active" |> to_bool);
  check_string_list_contains "before_turn includes work discovery"
    "work_discovery_nudge"
    (string_list_field (slot json "before_turn") "features");
  check bool "before_turn_params active" true
    (slot json "before_turn_params" |> member "active" |> to_bool);
  check string "before_turn_params source" "keeper_run_tools"
    (slot json "before_turn_params" |> member "source" |> to_string);
  let pre_tool_gates = string_list_field (slot json "pre_tool_use") "gates" in
  List.iter
    (fun gate ->
      check_string_list_contains ("pre_tool gate " ^ gate) gate pre_tool_gates)
    [
      "timing";
      "custom_guard";
      "streak_gate";
      "keeper_deny_list";
      "cost_budget";
      "destructive_pattern_off";
      "governance_approval";
    ];
  let failure_effects =
    string_list_field (slot json "post_tool_use_failure") "effects"
  in
  check_string_list_contains "failure hook records counter"
    "tool_use_failure_metric" failure_effects;
  check_string_list_not_contains "failure hook no stale heuristic label"
    "heuristic_metrics" failure_effects;
  check bool "on_stop active" true
    (slot json "on_stop" |> member "active" |> to_bool);
  check_string_list_contains "on_stop records stop reason"
    "stop_reason_metric"
    (string_list_field (slot json "on_stop") "effects");
  check bool "on_idle_escalated active" true
    (slot json "on_idle_escalated" |> member "active" |> to_bool);
  check_string_list_contains "on_idle_escalated records metric"
    "idle_escalation_metric"
    (string_list_field (slot json "on_idle_escalated") "effects");
  check bool "pre_compact inactive" false
    (slot json "pre_compact" |> member "active" |> to_bool);
  check bool "post_compact inactive" false
    (slot json "post_compact" |> member "active" |> to_bool);
  check bool "on_context_compacted inactive" false
    (slot json "on_context_compacted" |> member "active" |> to_bool)

let test_on_error_hook_records_callback_failure_metric () =
  let keeper = "callback-on-error-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_error" hooks.on_error in
  let before =
    lifecycle_callback_failure_count ~keeper ~callback:"on_error"
  in
  check_continue "on_error"
    (hook
       (Agent_sdk.Hooks.OnError
          { detail = "provider failed"; context = "unit-test" }));
  let after =
    lifecycle_callback_failure_count ~keeper ~callback:"on_error"
  in
  check (float 0.001) "on_error counter increments" 1.0 (after -. before)

let test_on_tool_error_hook_records_callback_failure_metric () =
  let keeper = "callback-on-tool-error-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_tool_error" hooks.on_tool_error in
  let before =
    lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error"
  in
  check_continue "on_tool_error"
    (hook
       (Agent_sdk.Hooks.OnToolError
          { tool_name = "keeper_bash"; error = "tool failed" }));
  let after =
    lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error"
  in
  check (float 0.001) "on_tool_error counter increments" 1.0
    (after -. before)

let test_on_stop_hook_records_stop_reason_metric () =
  let keeper = "callback-on-stop-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_stop" hooks.on_stop in
  let before = on_stop_count ~keeper ~stop_reason:"end_turn" in
  check_continue "on_stop"
    (hook
       (Agent_sdk.Hooks.OnStop
          {
            reason = Agent_sdk.Types.EndTurn;
            response = make_response ();
          }));
  let after = on_stop_count ~keeper ~stop_reason:"end_turn" in
  check (float 0.001) "on_stop counter increments" 1.0
    (after -. before);
  let unknown_before = on_stop_count ~keeper ~stop_reason:"unknown" in
  check_continue "on_stop unknown"
    (hook
       (Agent_sdk.Hooks.OnStop
          {
            reason = Agent_sdk.Types.Unknown "provider raw detail";
            response =
              make_response
                ~stop_reason:(Agent_sdk.Types.Unknown "provider raw detail")
                ();
          }));
  let unknown_after = on_stop_count ~keeper ~stop_reason:"unknown" in
  check (float 0.001) "unknown stop reason is bounded" 1.0
    (unknown_after -. unknown_before)

let test_on_idle_escalated_hook_records_metric () =
  let keeper = "callback-on-idle-escalated-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_idle_escalated" hooks.on_idle_escalated in
  let before =
    on_idle_escalated_count ~keeper ~severity:"final_warning"
      ~decision:"nudge"
  in
  check_nudge "on_idle_escalated"
    (hook
       (Agent_sdk.Hooks.OnIdleEscalated
          {
            severity = Agent_sdk.Hooks.Idle_severity.Final_warning;
            consecutive_idle_turns = 1;
            tool_names = [ "keeper_bash" ];
          }));
  let after =
    on_idle_escalated_count ~keeper ~severity:"final_warning"
      ~decision:"nudge"
  in
  check (float 0.001) "on_idle_escalated counter increments" 1.0
    (after -. before)

let test_on_idle_hook_returns_runtime_nudge () =
  let hooks = make_test_hooks "callback-on-idle-keeper" in
  let hook = require_hook "on_idle" hooks.on_idle in
  check_nudge "on_idle"
    (hook
       (Agent_sdk.Hooks.OnIdle
          {
            consecutive_idle_turns = 1;
            tool_names = [ "keeper_bash" ];
          }))

let pr_review_event ?route_via_fallback ~tool_name ~input ~output_text () =
  Hooks.For_testing.pr_review_action_metric_event_of_tool_io
    ~route_via_fallback ~tool_name ~input ~output_text
    ~transport_success:true

let require_pr_review_event label = function
  | Some event -> event
  | None -> failf "expected PR review action event for %s" label

let hook_output_parse_failures surface =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_keeper_oas_hook_output_parse_failures
    ~labels:[ ("surface", surface) ]
    ()

let test_pr_review_action_metric_extracts_approve () =
  let event =
    pr_review_event
      ~tool_name:"keeper_pr_review_comment"
      ~input:(`Assoc [ ("pr_number", `Int 13177); ("event", `String "COMMENT") ])
      ~output_text:
        {|{"ok":true,"pr_number":13177,"event":"APPROVE","keeper":"sangsu","via":"docker","credential":{"effective_github_identity":"root"},"identity_attestation":{"keeper":"sangsu","effective_github_identity":"root"}}|}
      ()
    |> require_pr_review_event "approve"
  in
  check string "action from output" "APPROVE" event.action;
  check (option int) "pr number" (Some 13177) event.pr_number;
  check bool "success" true event.success;
  check (option string) "route via" (Some "docker") event.route_via;
  let attestation =
    match event.identity_attestation with
    | Some json -> json
    | None -> fail "expected identity attestation"
  in
  check string "attested keeper" "sangsu"
    (attestation |> member "keeper" |> to_string);
  let credential =
    match event.credential with
    | Some json -> json
    | None -> fail "expected credential"
  in
  check string "credential identity" "root"
    (credential |> member "effective_github_identity" |> to_string)

let test_pr_review_action_metric_marks_structured_failure () =
  let event =
    pr_review_event
      ~tool_name:"keeper_pr_review_comment"
      ~input:(`Assoc [ ("number", `Int 42); ("event", `String "approve") ])
      ~output_text:{|{"ok":false,"error":"gh_failed"}|}
      ()
    |> require_pr_review_event "failed approve"
  in
  check string "action fallback from input" "APPROVE" event.action;
  check (option int) "number fallback" (Some 42) event.pr_number;
  check bool "structured ok=false wins" false event.success

let test_pr_review_action_metric_extracts_reply () =
  let event =
    pr_review_event
      ~tool_name:"keeper_pr_review_reply"
      ~input:(`Assoc [ ("pr_number", `Int 9); ("comment_id", `Int 1234) ])
      ~output_text:{|{"ok":true,"pr_number":9,"comment_id":1234,"via":"host"}|}
      ()
    |> require_pr_review_event "reply"
  in
  check string "reply action" "REPLY" event.action;
  check (option int) "reply pr" (Some 9) event.pr_number;
  check (option int) "comment id" (Some 1234) event.comment_id;
  check (option string) "reply route via" (Some "host") event.route_via

let test_pr_review_action_metric_observes_invalid_output_json () =
  let before = hook_output_parse_failures "pr_review_action" in
  let event =
    pr_review_event
      ~tool_name:"keeper_pr_review_comment"
      ~input:(`Assoc [ ("number", `Int 7); ("event", `String "comment") ])
      ~output_text:"{not-json"
      ()
    |> require_pr_review_event "invalid output json"
  in
  check string "action fallback from input" "COMMENT" event.action;
  check (option int) "number fallback" (Some 7) event.pr_number;
  check (float 0.001) "parse failure counted" (before +. 1.0)
    (hook_output_parse_failures "pr_review_action")

let test_pr_review_action_metric_extracts_fenced_output_json () =
  let before = hook_output_parse_failures "pr_review_action" in
  let event =
    pr_review_event
      ~tool_name:"keeper_pr_review_comment"
      ~input:(`Assoc [ ("number", `Int 71); ("event", `String "comment") ])
      ~output_text:
        "Review submitted.\n\
         ```json\n\
         {\"ok\":true,\"pr_number\":71,\"event\":\"APPROVE\",\"via\":\"docker\"}\n\
         ```\n"
      ()
    |> require_pr_review_event "fenced output json"
  in
  check string "action from fenced output" "APPROVE" event.action;
  check (option int) "pr number" (Some 71) event.pr_number;
  check (option string) "route via" (Some "docker") event.route_via;
  check (float 0.001) "parse failure not counted" before
    (hook_output_parse_failures "pr_review_action")

let test_pr_review_action_metric_extracts_keeper_shell_approve () =
  let event =
    pr_review_event
      ~tool_name:"keeper_shell"
      ~input:
        (`Assoc
          [
            ("op", `String "gh");
            ("cmd", `String "pr review 13680 --approve --body ok");
          ])
      ~output_text:
        {|{"ok":true,"op":"gh","command":"gh 'pr' 'review' '13680' '--approve' '--body' 'ok'","via":"docker"}|}
      ()
    |> require_pr_review_event "keeper_shell approve"
  in
  check string "approve action" "APPROVE" event.action;
  check (option int) "approve pr" (Some 13680) event.pr_number;
  check bool "approve success" true event.success;
  check (option string) "approve route via" (Some "docker") event.route_via

let pr_work_events ?route_via_fallback ~tool_name ~input ~output_text () =
  Hooks.For_testing.pr_work_action_metric_events_of_tool_io
    ~route_via_fallback ~tool_name ~input ~output_text
    ~transport_success:true

let work_actions events = List.map (fun e -> e.Hooks.work_action) events

let test_pr_work_action_metric_extracts_masc_code_git_push () =
  let events =
    pr_work_events
      ~tool_name:"masc_code_git"
      ~input:(`Assoc [ ("action", `String "push") ])
      ~output_text:{|{"status":"ok","action":"push","via":"docker"}|}
      ()
  in
  check (list string) "actions" [ "GIT_PUSH" ] (work_actions events);
  let event =
    match events with
    | [ event ] -> event
    | _ -> failf "expected one git push event"
  in
  check string "source" "masc_code_git" event.work_source;
  check bool "success" true event.success;
  check (option string) "route via" (Some "docker") event.route_via

let test_pr_work_action_metric_observes_invalid_output_json () =
  let before = hook_output_parse_failures "pr_work_action" in
  let events =
    pr_work_events
      ~tool_name:"masc_code_git"
      ~input:(`Assoc [ ("action", `String "push") ])
      ~output_text:"{not-json"
      ()
  in
  check (list string) "actions fallback from input" [ "GIT_PUSH" ]
    (work_actions events);
  check (float 0.001) "parse failure counted" (before +. 1.0)
    (hook_output_parse_failures "pr_work_action")

let test_pr_work_action_metric_extracts_embedded_output_json () =
  let before = hook_output_parse_failures "pr_work_action" in
  let events =
    pr_work_events
      ~tool_name:"keeper_pr_create"
      ~input:
        (`Assoc
          [
            ("title", `String "proof");
            ("head", `String "proof/embedded-json");
          ])
      ~output_text:
        "Created draft PR successfully:\n\
         {\"ok\":true,\"tool\":\"keeper_pr_create\",\"operation\":\"pr_create\",\
         \"via\":\"brokered\",\"result\":{\"output\":\"https://github.com/acme/repo/pull/43\\n\"}}\n\
         Done."
      ()
  in
  check (list string) "pr create action" [ "PR_CREATE" ]
    (work_actions events);
  (match events with
   | [ event ] ->
       check string "source" "keeper_pr_create" event.work_source;
       check (option string) "head ref" (Some "proof/embedded-json")
         event.work_ref;
       check (option string) "pr url"
         (Some "https://github.com/acme/repo/pull/43")
         event.pr_url;
       check (option string) "route via" (Some "brokered") event.route_via
   | _ -> failf "expected one keeper_pr_create event");
  check (float 0.001) "parse failure not counted" before
    (hook_output_parse_failures "pr_work_action")

let test_pr_work_action_metric_extracts_gh_pr_create () =
  let events =
    pr_work_events
      ~tool_name:"keeper_shell"
      ~input:
        (`Assoc
          [ ("op", `String "gh");
            ("cmd", `String "pr create --draft --title t") ])
      ~output_text:
        {|{"ok":true,"op":"gh","command":"gh pr create --draft","route":{"via":"docker"}}|}
      ()
  in
  check (list string) "pr create action" [ "PR_CREATE" ]
    (work_actions events);
  match events with
  | [ event ] ->
      check (option string) "route via nested" (Some "docker") event.route_via
  | _ -> failf "expected one pr create event"

let test_pr_work_action_metric_extracts_quoted_output_gh_pr_create () =
  let events =
    pr_work_events
      ~tool_name:"keeper_shell"
      ~input:
        (`Assoc
          [
            ("op", `String "gh");
            ("cmd", `String "pr status");
          ])
      ~output_text:
        {|{"ok":true,"op":"gh","command":"gh 'pr' 'create' '--draft' '--base' 'main' '--head' 'keeper/proof'","via":"docker"}|}
      ()
  in
  check (list string) "quoted output pr create action" [ "PR_CREATE" ]
    (work_actions events);
  match events with
  | [ event ] ->
      check (option string) "quoted output route via" (Some "docker")
        event.route_via
  | _ -> failf "expected one quoted output pr create event"

let test_pr_work_action_metric_extracts_keeper_pr_create () =
  let events =
    pr_work_events
      ~tool_name:"keeper_pr_create"
      ~input:
        (`Assoc
          [
            ("title", `String "proof");
            ("head", `String "proof/keeper-docker");
          ])
      ~output_text:
        {|{"ok":true,"tool":"keeper_pr_create","operation":"pr_create","via":"brokered","result":{"output":"https://github.com/acme/repo/pull/42\n"}}|}
      ()
  in
  check (list string) "pr create action" [ "PR_CREATE" ]
    (work_actions events);
  match events with
  | [ event ] ->
      check string "source" "keeper_pr_create" event.work_source;
      check (option string) "head ref" (Some "proof/keeper-docker")
        event.work_ref;
      check (option string) "pr url"
        (Some "https://github.com/acme/repo/pull/42")
        event.pr_url;
      check (option string) "route via" (Some "brokered") event.route_via
  | _ -> failf "expected one keeper_pr_create event"

let test_pr_work_action_metric_uses_native_pr_create_route_fallback () =
  let events =
    pr_work_events ~route_via_fallback:"brokered"
      ~tool_name:"keeper_pr_create"
      ~input:
        (`Assoc
          [
            ("title", `String "proof");
            ("head", `String "proof/keeper-docker");
          ])
      ~output_text:
        {|{"ok":true,"tool":"keeper_pr_create","operation":"pr_create"}|}
      ()
  in
  check (list string) "pr create action" [ "PR_CREATE" ]
    (work_actions events);
  match events with
  | [ event ] ->
      check (option string) "head ref" (Some "proof/keeper-docker")
        event.work_ref;
      check (option string) "route fallback" (Some "brokered")
        event.route_via
  | _ -> failf "expected one keeper_pr_create event"

let test_pr_work_action_metric_extracts_bash_git_push_with_redirection () =
  let events =
    pr_work_events
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
          [
            ( "cmd",
              `String "git push -u origin keeper/proof-branch 2>&1" );
          ])
      ~output_text:{|{"ok":true,"via":"docker"}|}
      ()
  in
  check (list string) "git push with redirection" [ "GIT_PUSH" ]
    (work_actions events);
  match events with
  | [ event ] ->
      check (option string) "route via" (Some "docker") event.route_via
  | _ -> failf "expected one git push event"

let test_pr_work_action_metric_extracts_bash_git_sequence_failure () =
  let events =
    pr_work_events
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
          [ ( "cmd",
              `String "git add lib/foo.ml && git commit -m x && git push origin feat/x" );
          ])
      ~output_text:{|{"ok":false,"cmd":"git push origin feat/x"}|}
      ()
  in
  check (list string) "git action sequence"
    [ "GIT_ADD" ]
    (work_actions events);
  check bool "failure propagated to every action" true
    (List.for_all (fun e -> not e.Hooks.success) events)

let test_pr_work_action_metric_ignores_quoted_command_words () =
  let bash_events =
    pr_work_events
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
          [
            ( "cmd",
              `String
                "git commit -m \"revert git push\" && gh issue comment 1 --body \"please pr create later\""
            );
          ])
      ~output_text:{|{"ok":true}|}
      ()
  in
  check (list string) "quoted command words do not add actions"
    [ "GIT_COMMIT" ] (work_actions bash_events);
  let gh_events =
    pr_work_events
      ~tool_name:"keeper_shell"
      ~input:
        (`Assoc
          [
            ("op", `String "gh");
            ("cmd", `String "issue comment 1 --body \"please pr create later\"");
          ])
      ~output_text:{|{"ok":true}|}
      ()
  in
  check (list string) "quoted pr create is not a command" [] (work_actions gh_events)

let test_pr_work_action_metric_skips_shell_control_flow_segments () =
  let and_events =
    pr_work_events
      ~tool_name:"keeper_bash"
      ~input:(`Assoc [ ("cmd", `String "false && git push origin feat/x") ])
      ~output_text:{|{"ok":false}|}
      ()
  in
  check (list string) "skipped && segment" [] (work_actions and_events);
  let or_events =
    pr_work_events
      ~tool_name:"keeper_bash"
      ~input:
        (`Assoc
          [
            ( "cmd",
              `String
                "git commit -m reviewed || gh pr create --draft --title retry" );
          ])
      ~output_text:{|{"ok":true}|}
      ()
  in
  check (list string) "skipped || fallback segment" [ "GIT_COMMIT" ]
    (work_actions or_events)

let () =
  run "keeper_hooks_oas/telemetry"
    [ ( "costs_jsonl",
        [ test_case "emit_cost_event keeps throughput and memory fields" `Quick
            test_emit_cost_event_writes_inference_telemetry
        ; test_case "emit_cost_event marks usage_missing" `Quick
            test_emit_cost_event_marks_usage_missing
        ; test_case "emit_cost_event uses typed provider kind for bare model" `Quick
            test_emit_cost_event_uses_typed_provider_kind_for_bare_model
        ; test_case "emit_cost_event computes wall tok/s without native timings" `Quick
            test_emit_cost_event_writes_wall_tok_s_without_provider_timings
        ; test_case "emit_cost_event marks untrusted usage" `Quick
            test_emit_cost_event_marks_untrusted_usage
        ; test_case "emit_cost_event marks unpriced paid model" `Quick
            test_emit_cost_event_marks_unpriced_paid_model
        ; test_case "emit_cost_event records auto resolution source" `Quick
            test_emit_cost_event_records_auto_resolution_source
        ; test_case
            "emit_cost_event records provider-prefixed auto resolution source"
            `Quick
            test_emit_cost_event_records_provider_prefixed_auto_resolution_source
        ; test_case "cost fallback estimates paid provider usage" `Quick
            test_cost_usd_for_usage_falls_back_for_paid_provider
        ; test_case "cost fallback preserves reported cost" `Quick
            test_cost_usd_for_usage_preserves_reported_cost
        ; test_case "cost fallback keeps CLI provider zero" `Quick
            test_cost_usd_for_usage_keeps_cli_provider_zero
        ; test_case "cost fallback keeps typed CLI provider zero" `Quick
            test_cost_usd_for_usage_keeps_typed_cli_provider_zero
        ] )
    ; ( "tool_telemetry",
        [ test_case "tool execution summary derives provider and outcome" `Quick
            test_tool_execution_summary_derives_provider_and_outcome
        ; test_case "trajectory duration keeps positive sub-ms values" `Quick
            test_trajectory_duration_ms_preserves_positive_sub_ms
        ; test_case "trajectory duration rejects non-positive values" `Quick
            test_trajectory_duration_ms_rejects_zero_and_non_finite
        ; test_case "keeper tool duration metric tracks labels" `Quick
            test_record_keeper_tool_duration_metric_tracks_labels
        ] )
    ; ( "llm_tok_s_metrics",
        [ test_case "both histograms observe when timings present" `Quick
            test_record_llm_tok_s_metrics_both_histograms_observe
        ; test_case "timings=None is no-op (Anthropic/Gemini path)" `Quick
            test_record_llm_tok_s_metrics_timings_none_is_noop
        ; test_case "Some 0.0 prompt rate is skipped (no bucket poisoning)" `Quick
            test_record_llm_tok_s_metrics_zero_value_is_skipped
        ; test_case "telemetry=None is a safe no-op" `Quick
            test_record_llm_tok_s_metrics_none_telemetry_is_noop
        ] )
    ; ( "llm_inference_latency",
        [ test_case "positive latency observes histogram" `Quick
            test_record_llm_inference_latency_metric_positive_observes
        ; test_case "zero latency increments counter and floors histogram" `Quick
            test_record_llm_inference_latency_metric_zero_floors
        ; test_case "missing telemetry increments missing counter" `Quick
            test_record_llm_inference_latency_metric_none_counts_missing
        ] )
    ; ( "hook_introspection",
        [ test_case "reports current runtime slots" `Quick
            test_hook_introspection_reports_current_runtime_slots
        ; test_case "on_error records callback metric" `Quick
            test_on_error_hook_records_callback_failure_metric
        ; test_case "on_tool_error records callback metric" `Quick
            test_on_tool_error_hook_records_callback_failure_metric
        ; test_case "on_stop records stop reason metric" `Quick
            test_on_stop_hook_records_stop_reason_metric
        ; test_case "on_idle_escalated records metric" `Quick
            test_on_idle_escalated_hook_records_metric
        ; test_case "on_idle returns runtime nudge" `Quick
            test_on_idle_hook_returns_runtime_nudge
        ] )
    ; ( "pr_review_action",
        [ test_case "extracts approve event from structured output" `Quick
            test_pr_review_action_metric_extracts_approve
        ; test_case "marks structured gh failure as not successful" `Quick
            test_pr_review_action_metric_marks_structured_failure
        ; test_case "extracts reply action" `Quick
            test_pr_review_action_metric_extracts_reply
        ; test_case "observes invalid output JSON" `Quick
            test_pr_review_action_metric_observes_invalid_output_json
        ; test_case "extracts fenced output JSON" `Quick
            test_pr_review_action_metric_extracts_fenced_output_json
        ; test_case "extracts keeper_shell approve" `Quick
            test_pr_review_action_metric_extracts_keeper_shell_approve
        ] )
    ; ( "pr_work_action",
        [ test_case "extracts masc_code_git push" `Quick
            test_pr_work_action_metric_extracts_masc_code_git_push
        ; test_case "observes invalid output JSON" `Quick
            test_pr_work_action_metric_observes_invalid_output_json
        ; test_case "extracts embedded output JSON" `Quick
            test_pr_work_action_metric_extracts_embedded_output_json
        ; test_case "extracts keeper_shell gh pr create" `Quick
            test_pr_work_action_metric_extracts_gh_pr_create
        ; test_case "extracts quoted output gh pr create" `Quick
            test_pr_work_action_metric_extracts_quoted_output_gh_pr_create
        ; test_case "extracts keeper_pr_create" `Quick
            test_pr_work_action_metric_extracts_keeper_pr_create
        ; test_case "uses native pr create route fallback" `Quick
            test_pr_work_action_metric_uses_native_pr_create_route_fallback
        ; test_case "extracts bash git push with redirection" `Quick
            test_pr_work_action_metric_extracts_bash_git_push_with_redirection
        ; test_case "extracts conservative bash git failure" `Quick
            test_pr_work_action_metric_extracts_bash_git_sequence_failure
        ; test_case "ignores quoted command words" `Quick
            test_pr_work_action_metric_ignores_quoted_command_words
        ; test_case "skips conditional control-flow segments" `Quick
            test_pr_work_action_metric_skips_shell_control_flow_segments
        ] )
    ]
