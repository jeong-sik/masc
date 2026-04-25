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
    request_latency_ms = 42;
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
      request_latency_ms = 0;
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
    (json |> member "provider" |> to_string)

let test_emit_cost_event_writes_wall_tok_s_without_provider_timings () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry = {
    system_fingerprint = None;
    timings = None;
    reasoning_tokens = None;
    request_latency_ms = 250;
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
      request_latency_ms = 250;
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
      request_latency_ms = 100;
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
      request_latency_ms = 100;
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
    request_latency_ms;
    peak_memory_gb = None;
    provider_kind;
    reasoning_effort = None;
    canonical_model_id = None;
    effective_context_window = None;
    provider_internal_action_count = None;
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
    ]
