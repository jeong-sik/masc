open Alcotest
open Yojson.Safe.Util
module Hooks = Masc_mcp.Keeper_hooks_oas
module HGA = Masc_mcp.Keeper_hooks_oas_gate_attempt

let temp_counter = ref 0

let temp_dir () =
  incr temp_counter;
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "keeper-hooks-oas-%d-%06d" (Unix.getpid ()) !temp_counter)
  in
  Unix.mkdir dir 0o755;
  dir
;;

let read_jsonl_line path =
  let path =
    if Sys.file_exists path then path
    else
      let root = Filename.dirname path in
      let rec first_jsonl dir =
        Sys.readdir dir
        |> Array.to_list
        |> List.sort String.compare
        |> List.find_map (fun name ->
               let child = Filename.concat dir name in
               if Sys.is_directory child then first_jsonl child
               else if Filename.check_suffix child ".jsonl" then Some child
               else None)
      in
      match first_jsonl (Filename.concat root "costs") with
      | Some dated_path -> dated_path
      | None -> path
  in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> input_line ic |> Yojson.Safe.from_string)
;;

let make_usage ?cost_usd ~input_tokens ~output_tokens () : Agent_sdk.Types.api_usage =
  { input_tokens
  ; output_tokens
  ; cache_creation_input_tokens = 0
  ; cache_read_input_tokens = 0
  ; cost_usd
  }
;;

let check_json_absent field json =
  check
    bool
    (field ^ " absent")
    true
    (match json |> member field with
     | `Null -> true
     | _ -> false)
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
          [ "name", `String name
          ; "agent_name", `String name
          ; "trace_id", `String ("trace-" ^ name)
          ; "cascade_name", `String Masc_mcp.(Keeper_config.default_cascade_name ())
          ; "last_model_used", `String "test-model"
          ])
  with
  | Ok meta -> meta
  | Error err -> fail ("meta_of_json_fixture failed: " ^ err)
;;

let make_test_hooks keeper_name =
  let config = Masc_mcp.Coord.default_config (temp_dir ()) in
  let meta_ref = ref (make_meta keeper_name) in
  Hooks.make_hooks ~config ~meta_ref ~generation:1 ()
;;

let make_test_hooks_at_root keeper_name root =
  let config = Masc_mcp.Coord.default_config root in
  let meta_ref = ref (make_meta keeper_name) in
  Hooks.make_hooks ~config ~meta_ref ~generation:1 ()
;;

let lifecycle_callback_failure_count ~keeper ~callback =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.(to_string LifecycleCallbackFailures)
    ~labels:[ "keeper", keeper; "callback", callback ]
    ()
;;

let latest_log_seq () =
  match Log.Ring.recent ~limit:1 () with
  | entry :: _ -> entry.Log.Ring.seq
  | [] -> -1
;;

let find_keeper_log_since ~since_seq ~message_substring =
  Log.Ring.recent ~limit:50 ~module_filter:"Keeper" ~since_seq ()
  |> List.find_opt (fun (entry : Log.Ring.entry) ->
         String_util.contains_substring entry.message message_substring)
;;

let on_stop_count ~keeper ~stop_reason =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.(to_string OasOnStop)
    ~labels:[ "keeper", keeper; "stop_reason", stop_reason ]
    ()
;;

let on_idle_escalated_count ~keeper ~severity ~decision =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Keeper_metrics.(to_string OasOnIdleEscalated)
    ~labels:[ "keeper", keeper; "severity", severity; "decision", decision ]
    ()
;;

let require_hook label = function
  | Some hook -> hook
  | None -> failf "expected active hook: %s" label
;;

let check_continue label = function
  | Agent_sdk.Hooks.Continue -> ()
  | _ -> failf "%s: expected Continue" label
;;

let check_nudge label = function
  | Agent_sdk.Hooks.Nudge _ -> ()
  | _ -> failf "%s: expected Nudge" label
;;

let test_emit_cost_event_writes_inference_telemetry () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings =
        Some
          { prompt_n = Some 11
          ; prompt_ms = Some 510.0
          ; prompt_per_second = Some 21.55
          ; predicted_n = Some 5
          ; predicted_ms = Some 61.3
          ; predicted_per_second = Some 81.56
          ; cache_n = Some 7
          }
    ; reasoning_tokens = Some 3
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 42
    ; peak_memory_gb = Some 52.66
    ; provider_kind = Some Llm_provider.Provider_kind.Provider_d_compat
    ; reasoning_effort = None
    ; canonical_model_id = Some "model-d-4"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:(Some "task-1")
    ~input_tokens:11
    ~output_tokens:5
    ~cost_usd:0.12
    ~telemetry
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider redacted" "runtime" (json |> member "provider" |> to_string);
  check string "model redacted" "runtime" (json |> member "model" |> to_string);
  check int "reasoning_tokens" 3 (json |> member "reasoning_tokens" |> to_int);
  check int "cache_n" 7 (json |> member "cache_n" |> to_int);
  check int "request_latency_ms" 42 (json |> member "request_latency_ms" |> to_int);
  check
    (float 0.001)
    "tokens_per_second"
    (5.0 /. 0.042)
    (json |> member "tokens_per_second" |> to_float);
  check
    (float 0.001)
    "prompt_per_second"
    21.55
    (json |> member "prompt_per_second" |> to_float);
  check
    (float 0.001)
    "provider_tokens_per_second"
    81.56
    (json |> member "provider_tokens_per_second" |> to_float);
  check
    (float 0.001)
    "hw_decode_tokens_per_second"
    81.56
    (json |> member "hw_decode_tokens_per_second" |> to_float);
  check (float 0.001) "peak_memory_gb" 52.66 (json |> member "peak_memory_gb" |> to_float)
;;

let test_inference_telemetry_runtime_json_redacts_identity () =
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = Some "provider-fingerprint"
    ; timings = None
    ; reasoning_tokens = Some 9
    ; reasoning_tokens_estimated = true
    ; request_latency_ms = Some 123
    ; peak_memory_gb = Some 1.5
    ; provider_kind = Some Llm_provider.Provider_kind.Cli_tool_c
    ; reasoning_effort = Some "medium"
    ; canonical_model_id = Some "model-c-coding"
    ; effective_context_window = Some 256000
    ; provider_internal_action_count = Some 2
    ; ttfrc_ms = Some 4.5
    ; prefill_ms = Some 6.7
    }
  in
  let json = Hooks.inference_telemetry_to_runtime_json telemetry in
  check bool "provider_kind redacted" true (json |> member "provider_kind" = `Null);
  check bool "canonical_model_id redacted" true (json |> member "canonical_model_id" = `Null);
  check bool "system_fingerprint redacted" true (json |> member "system_fingerprint" = `Null);
  check int "reasoning_tokens kept" 9 (json |> member "reasoning_tokens" |> to_int);
  check int "request_latency_ms kept" 123 (json |> member "request_latency_ms" |> to_int);
  check int "context window kept" 256000 (json |> member "effective_context_window" |> to_int);
  check int "provider action count kept" 2 (json |> member "provider_internal_action_count" |> to_int)
;;

let test_emit_cost_event_marks_usage_missing () =
  let root = temp_dir () in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:0
    ~output_tokens:0
    ~cost_usd:0.0
    ~usage_missing:true
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check bool "usage_missing" true (json |> member "usage_missing" |> to_bool)
;;

let test_emit_cost_event_redacts_typed_provider_kind_for_bare_model () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 0
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Cli_tool_c
    ; reasoning_effort = None
    ; canonical_model_id = None
    ; effective_context_window = None
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:0
    ~output_tokens:0
    ~cost_usd:0.0
    ~telemetry
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check
    string
    "provider redacted"
    "runtime"
    (json |> member "provider" |> to_string);
  check
    bool
    "zero latency is omitted"
    true
    (match json |> member "request_latency_ms" with
     | `Null -> true
     | _ -> false)
;;

let test_emit_cost_event_writes_wall_tok_s_without_provider_timings () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 250
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Provider_d_compat
    ; reasoning_effort = None
    ; canonical_model_id = Some "auto"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:100
    ~output_tokens:50
    ~cost_usd:0.0
    ~telemetry
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check
    (float 0.001)
    "wall tokens_per_second"
    200.0
    (json |> member "tokens_per_second" |> to_float);
  check
    bool
    "native prompt timing absent"
    true
    (match json |> member "prompt_per_second" with
     | `Null -> true
     | _ -> false);
  check
    bool
    "native decode timing absent"
    true
    (match json |> member "hw_decode_tokens_per_second" with
     | `Null -> true
     | _ -> false)
;;

let test_emit_cost_event_derives_wall_tok_s_after_first_chunk () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 250
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Provider_d_compat
    ; reasoning_effort = None
    ; canonical_model_id = Some "auto"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = Some 50.0
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:100
    ~output_tokens:50
    ~cost_usd:0.0
    ~telemetry
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check
    (float 0.001)
    "tokens_per_second uses post-first-chunk duration"
    250.0
    (json |> member "tokens_per_second" |> to_float)
;;

let test_emit_cost_event_marks_untrusted_usage () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 250
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Ollama
    ; reasoning_effort = None
    ; canonical_model_id = Some "ollama:qwen3.6:27b-coding-nvfp4"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:2_000_000
    ~output_tokens:50
    ~cost_usd:0.99
    ~telemetry
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "usage trust" "untrusted" (json |> member "usage_trust" |> to_string);
  check bool "usage anomaly" true (json |> member "usage_anomaly" |> to_bool);
  let reasons = json |> member "usage_anomaly_reasons" |> to_list |> List.map to_string in
  check bool "reason includes absurd input" true (List.mem "input_tokens_gt_1m" reasons);
  check
    bool
    "reason includes context overrun"
    true
    (List.mem "input_tokens_gt_2x_context_max" reasons);
  check int "safe input tokens" 0 (json |> member "input_tokens" |> to_int);
  check int "safe output tokens" 0 (json |> member "output_tokens" |> to_int);
  check (float 0.001) "safe cost" 0.0 (json |> member "cost_usd" |> to_float);
  check
    int
    "raw input tokens retained"
    2_000_000
    (json |> member "raw_input_tokens" |> to_int);
  check int "raw output tokens retained" 50 (json |> member "raw_output_tokens" |> to_int);
  check
    bool
    "wall tok/s omitted"
    true
    (match json |> member "tokens_per_second" with
     | `Null -> true
     | _ -> false)
;;

let test_emit_cost_event_marks_unpriced_paid_model () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 100
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Provider_d_compat
    ; reasoning_effort = None
    ; canonical_model_id = Some "future-provider_d-model-v9"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:1000
    ~output_tokens:500
    ~cost_usd:0.0
    ~telemetry
    ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider redacted" "runtime" (json |> member "provider" |> to_string);
  check
    string
    "cost status"
    "oas_cost_unreported"
    (json |> member "cost_status" |> to_string);
  check
    string
    "cost reason"
    "oas_cost_unreported"
    (json |> member "cost_status_reason" |> to_string);
  check_json_absent "cost_pricing_model" json;
  check_json_absent "cost_pricing_catalog" json;
  check_json_absent "model_resolution_source" json
;;

let test_emit_cost_event_records_auto_resolution_source () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 100
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Provider_d_compat
    ; reasoning_effort = None
    ; canonical_model_id = Some "model-d-4.1"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:1000
    ~output_tokens:500
    ~cost_usd:0.01
    ~telemetry
  ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider redacted" "runtime" (json |> member "provider" |> to_string);
  check_json_absent "cost_pricing_model" json;
  check_json_absent "model_resolution_source" json;
  check_json_absent "cost_pricing_catalog" json;
  check string "cost status" "reported" (json |> member "cost_status" |> to_string)
;;

let test_emit_cost_event_records_provider_prefixed_auto_resolution_source () =
  let root = temp_dir () in
  let telemetry : Agent_sdk.Types.inference_telemetry =
    { system_fingerprint = None
    ; timings = None
    ; reasoning_tokens = None
    ; reasoning_tokens_estimated = false
    ; request_latency_ms = Some 100
    ; peak_memory_gb = None
    ; provider_kind = Some Llm_provider.Provider_kind.Cli_tool_c
    ; reasoning_effort = None
    ; canonical_model_id = Some "model-c-coding"
    ; effective_context_window = Some 128000
    ; provider_internal_action_count = None
    ; ttfrc_ms = None
    ; prefill_ms = None
    }
  in
  Hooks.emit_cost_event
    ~masc_root:root
    ~agent_name:"keeper"
    ~task_id:None
    ~input_tokens:1000
    ~output_tokens:500
    ~cost_usd:0.0
    ~telemetry
  ();
  let json = read_jsonl_line (Filename.concat root "costs.jsonl") in
  check string "provider redacted" "runtime" (json |> member "provider" |> to_string);
  check_json_absent "cost_pricing_model" json;
  check_json_absent "model_resolution_source" json;
  check string "cost status" "oas_cost_unreported" (json |> member "cost_status" |> to_string)
;;

let test_tool_execution_summary_derives_provider_and_outcome () =
  let summary =
    Hooks.tool_execution_summary
      ~tool_name:"tool_search_files"
      ~model:"cli_tool_a:gpt-5.4"
      ~success:false
      ~duration_ms:12.5
  in
  check string "tool name" "tool_search_files" summary.tool_name;
  check string "provider" "runtime" summary.provider;
  check string "outcome" "error" summary.outcome;
  check (float 0.001) "duration" 12.5 summary.duration_ms
;;

let test_trajectory_duration_ms_preserves_positive_sub_ms () =
  check int "positive sub-ms" 1 (HGA.trajectory_duration_ms 0.4);
  check int "rounded positive" 13 (HGA.trajectory_duration_ms 12.5)
;;

let test_trajectory_duration_ms_rejects_zero_and_non_finite () =
  check int "zero" 0 (HGA.trajectory_duration_ms 0.0);
  check int "negative" 0 (HGA.trajectory_duration_ms (-0.1));
  check int "nan" 0 (HGA.trajectory_duration_ms nan);
  check int "infinity" 0 (HGA.trajectory_duration_ms infinity)
;;

let test_record_keeper_tool_duration_metric_tracks_labels () =
  let summary =
    Hooks.tool_execution_summary
      ~tool_name:"keeper_board_post"
      ~model:"provider_k-coding:provider_k-5.1"
      ~success:true
      ~duration_ms:250.0
  in
  let labels =
    [ "keeper", "telemetry-test"
    ; "provider", "runtime"
    ; "tool", "keeper_board_post"
    ; "outcome", "ok"
    ]
  in
  let sum_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.(to_string ToolCallDuration)
      ~labels
      ()
  in
  let count_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      (Masc_mcp.Keeper_metrics.(to_string ToolCallDuration) ^ "_count")
      ~labels
      ()
  in
  Hooks.record_keeper_tool_duration_metric ~keeper_name:"telemetry-test" summary;
  let sum_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Keeper_metrics.(to_string ToolCallDuration)
      ~labels
      ()
  in
  let count_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      (Masc_mcp.Keeper_metrics.(to_string ToolCallDuration) ^ "_count")
      ~labels
      ()
  in
  check (float 0.0001) "sum delta" 0.25 (sum_after -. sum_before);
  check (float 0.0001) "count delta" 1.0 (count_after -. count_before)
;;

let make_telemetry
      ?(prompt_per_second : float option = None)
      ?(predicted_per_second : float option = None)
      ?(request_latency_ms = 0)
      ?(provider_kind : Llm_provider.Provider_kind.t option = None)
      ?(include_timings = true)
      ()
  : Agent_sdk.Types.inference_telemetry
  =
  let timings : Agent_sdk.Types.inference_timings option =
    if include_timings
    then
      Some
        { prompt_n = None
        ; prompt_ms = None
        ; prompt_per_second
        ; predicted_n = None
        ; predicted_ms = None
        ; predicted_per_second
        ; cache_n = None
        }
    else None
  in
  { system_fingerprint = None
  ; timings
  ; reasoning_tokens = None
  ; reasoning_tokens_estimated = false
  ; request_latency_ms = Some request_latency_ms
  ; peak_memory_gb = None
  ; provider_kind
  ; reasoning_effort = None
  ; canonical_model_id = None
  ; effective_context_window = None
  ; provider_internal_action_count = None
  ; ttfrc_ms = None
  ; prefill_ms = None
  }
;;

let make_response
    ?(stop_reason = Agent_sdk.Types.EndTurn)
    ?(content = [])
    ?telemetry
    () =
  { Agent_sdk.Types.id = "response-test"
  ; model = "test-model"
  ; stop_reason
  ; content
  ; usage = None
  ; telemetry
  }
;;

let histogram_snapshot metric ~labels =
  let sum = Masc_mcp.Prometheus.metric_value_or_zero metric ~labels () in
  let count = Masc_mcp.Prometheus.metric_value_or_zero (metric ^ "_count") ~labels () in
  sum, count
;;

let test_record_llm_tok_s_metrics_both_histograms_observe () =
  let telemetry =
    make_telemetry
      ~prompt_per_second:(Some 123.5)
      ~predicted_per_second:(Some 87.25)
      ~request_latency_ms:42
      ~provider_kind:(Some Llm_provider.Provider_kind.Ollama)
      ()
  in
  let labels = [ "model", "runtime"; "provider", "runtime"; "provider_kind", "runtime" ] in
  let prompt_sum_before, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  let decode_sum_before, decode_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec ~labels
  in
  Hooks.record_llm_tok_s_metrics ~telemetry:(Some telemetry);
  let prompt_sum_after, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  let decode_sum_after, decode_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec ~labels
  in
  check (float 0.001) "prompt sum delta" 123.5 (prompt_sum_after -. prompt_sum_before);
  check (float 0.001) "prompt count delta" 1.0 (prompt_count_after -. prompt_count_before);
  check (float 0.001) "decode sum delta" 87.25 (decode_sum_after -. decode_sum_before);
  check (float 0.001) "decode count delta" 1.0 (decode_count_after -. decode_count_before)
;;

let test_record_llm_tok_s_metrics_timings_none_is_noop () =
  (* Provider_a/Provider_f path: backends populate request_latency_ms but leave
     timings = None.  The helper must not touch the tok/s histograms in
     that case — otherwise the histogram would be polluted with zeros. *)
  let telemetry =
    make_telemetry
      ~include_timings:false
      ~request_latency_ms:250
      ~provider_kind:(Some Llm_provider.Provider_kind.Provider_a)
      ()
  in
  let labels = [ "model", "runtime"; "provider", "runtime"; "provider_kind", "runtime" ] in
  let _, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  let _, decode_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec ~labels
  in
  Hooks.record_llm_tok_s_metrics ~telemetry:(Some telemetry);
  let _, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  let _, decode_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec ~labels
  in
  check
    (float 0.001)
    "prompt count unchanged"
    0.0
    (prompt_count_after -. prompt_count_before);
  check
    (float 0.001)
    "decode count unchanged"
    0.0
    (decode_count_after -. decode_count_before)
;;

let test_record_llm_tok_s_metrics_zero_value_is_skipped () =
  (* Guard: a backend that reports prompt_per_second = Some 0.0 (e.g. a
     very short prompt processed in sub-millisecond time that rounds to
     zero) should not observe 0 into the histogram, which would skew the
     p50/p95 buckets. *)
  let telemetry =
    make_telemetry
      ~prompt_per_second:(Some 0.0)
      ~predicted_per_second:(Some 55.0)
      ~provider_kind:(Some Llm_provider.Provider_kind.Provider_d_compat)
      ()
  in
  let labels = [ "model", "runtime"; "provider", "runtime"; "provider_kind", "runtime" ] in
  let _, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  let _, decode_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec ~labels
  in
  Hooks.record_llm_tok_s_metrics ~telemetry:(Some telemetry);
  let _, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  let _, decode_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_decode_tok_per_sec ~labels
  in
  check (float 0.001) "prompt zero skipped" 0.0 (prompt_count_after -. prompt_count_before);
  check
    (float 0.001)
    "decode positive observed"
    1.0
    (decode_count_after -. decode_count_before)
;;

let test_record_llm_tok_s_metrics_none_telemetry_is_noop () =
  (* Belt and braces: explicitly None telemetry must not raise or emit. *)
  let labels = [ "model", "runtime"; "provider", "runtime"; "provider_kind", "runtime" ] in
  let _, prompt_count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  Hooks.record_llm_tok_s_metrics ~telemetry:None;
  let _, prompt_count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_prompt_tok_per_sec ~labels
  in
  check
    (float 0.001)
    "prompt count unchanged"
    0.0
    (prompt_count_after -. prompt_count_before)
;;

let test_summarize_thinking_blocks_metadata_only () =
  let summary =
    Hooks.summarize_thinking_blocks
      [
        Agent_sdk.Types.Text "visible";
        Agent_sdk.Types.Thinking
          { thinking_type = "extended"; content = "private reasoning" };
        Agent_sdk.Types.RedactedThinking "opaque-redacted-payload";
        Agent_sdk.Types.Thinking { thinking_type = "extended"; content = "more" };
      ]
  in
  check bool "thinking present" true summary.thinking_present;
  check int "thinking blocks" 2 summary.thinking_blocks;
  check int "thinking chars" 21 summary.thinking_chars;
  check int "redacted blocks" 1 summary.redacted_thinking_blocks;
  check string "mixed kind" "mixed" summary.thinking_kind
;;

let test_summarize_thinking_blocks_none () =
  let summary =
    Hooks.summarize_thinking_blocks
      [ Agent_sdk.Types.Text "visible"; Agent_sdk.Types.Text "" ]
  in
  check bool "thinking absent" false summary.thinking_present;
  check int "no thinking blocks" 0 summary.thinking_blocks;
  check int "no thinking chars" 0 summary.thinking_chars;
  check int "no redacted blocks" 0 summary.redacted_thinking_blocks;
  check string "none kind" "none" summary.thinking_kind
;;

let inference_latency_labels = [ "model", "runtime" ]

let test_record_llm_inference_latency_metric_positive_observes () =
  let labels = inference_latency_labels in
  let telemetry = make_telemetry ~request_latency_ms:42 () in
  let sum_before, count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration ~labels
  in
  let hook_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_hook
      ~labels
      ()
  in
  Hooks.record_llm_inference_latency_metric ~telemetry:(Some telemetry);
  let sum_after, count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration ~labels
  in
  let hook_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_hook
      ~labels
      ()
  in
  check (float 0.0001) "latency sum +42ms" 0.042 (sum_after -. sum_before);
  check (float 0.0001) "latency count +1" 1.0 (count_after -. count_before);
  check (float 0.0001) "hook counter +1" 1.0 (hook_after -. hook_before)
;;

let test_record_llm_inference_latency_metric_zero_floors () =
  let labels = inference_latency_labels in
  let telemetry = make_telemetry ~request_latency_ms:0 () in
  let sum_before, count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration ~labels
  in
  let zero_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_zero_latency
      ~labels
      ()
  in
  Hooks.record_llm_inference_latency_metric ~telemetry:(Some telemetry);
  let sum_after, count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration ~labels
  in
  let zero_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_zero_latency
      ~labels
      ()
  in
  check (float 0.0001) "zero latency counter +1" 1.0 (zero_after -. zero_before);
  check (float 0.0001) "latency sum floored to 1ms" 0.001 (sum_after -. sum_before);
  check (float 0.0001) "latency count +1" 1.0 (count_after -. count_before)
;;

let test_record_llm_inference_latency_metric_none_counts_missing () =
  let labels = inference_latency_labels in
  let _, count_before =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration ~labels
  in
  let missing_before =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_missing
      ~labels
      ()
  in
  Hooks.record_llm_inference_latency_metric ~telemetry:None;
  let _, count_after =
    histogram_snapshot Masc_mcp.Prometheus.metric_llm_inference_duration ~labels
  in
  let missing_after =
    Masc_mcp.Prometheus.metric_value_or_zero
      Masc_mcp.Prometheus.metric_after_turn_telemetry_missing
      ~labels
      ()
  in
  check (float 0.0001) "missing counter +1" 1.0 (missing_after -. missing_before);
  check (float 0.0001) "latency histogram unchanged" 0.0 (count_after -. count_before)
;;

let empty_content_labels ~keeper ~stop_reason ~shape =
  [ "keeper", keeper; "stop_reason", stop_reason; "shape", shape ]
;;

let empty_content_counter ~keeper ~stop_reason ~shape =
  Masc_mcp.Prometheus.metric_value_or_zero
    Masc_mcp.Prometheus.metric_after_turn_response_content_empty
    ~labels:(empty_content_labels ~keeper ~stop_reason ~shape)
    ()
;;

let test_record_response_content_quality_metric_empty_end_turn_counts () =
  let keeper = "response-content-empty-keeper" in
  let before =
    empty_content_counter ~keeper ~stop_reason:"end_turn" ~shape:"empty"
  in
  Hooks.record_response_content_quality_metric
    ~keeper_name:keeper
    (make_response ());
  let after =
    empty_content_counter ~keeper ~stop_reason:"end_turn" ~shape:"empty"
  in
  check (float 0.0001) "empty end_turn counter +1" 1.0 (after -. before)
;;

let test_record_response_content_quality_metric_blank_text_counts () =
  let keeper = "response-content-blank-text-keeper" in
  let before =
    empty_content_counter ~keeper ~stop_reason:"max_tokens" ~shape:"blank_text"
  in
  Hooks.record_response_content_quality_metric
    ~keeper_name:keeper
    (make_response
       ~stop_reason:Agent_sdk.Types.MaxTokens
       ~content:[ Agent_sdk.Types.Text " \n\t " ]
       ());
  let after =
    empty_content_counter ~keeper ~stop_reason:"max_tokens" ~shape:"blank_text"
  in
  check (float 0.0001) "blank text counter +1" 1.0 (after -. before)
;;

let test_record_response_content_quality_metric_tool_use_is_progress () =
  let keeper = "response-content-tool-use-keeper" in
  let before =
    empty_content_counter ~keeper ~stop_reason:"tool_use" ~shape:"blank_text"
  in
  Hooks.record_response_content_quality_metric
    ~keeper_name:keeper
    (make_response
       ~stop_reason:Agent_sdk.Types.StopToolUse
       ~content:
         [
           Agent_sdk.Types.ToolUse
             { id = "toolu-test"; name = "tool_execute"; input = `Assoc [] };
         ]
       ());
  let after =
    empty_content_counter ~keeper ~stop_reason:"tool_use" ~shape:"blank_text"
  in
  check (float 0.0001) "tool use is not empty content" 0.0 (after -. before)
;;

let slot json name = json |> member "slots" |> member name

let string_list_field json key =
  match json |> member key with
  | `List values -> List.map to_string values
  | `Null -> []
  | other -> failf "expected %s list, got %s" key (Yojson.Safe.to_string other)
;;

let check_string_list_contains label needle values =
  check bool label true (List.mem needle values)
;;

let check_string_list_not_contains label needle values =
  check bool label false (List.mem needle values)
;;

let test_hook_introspection_reports_current_runtime_slots () =
  let json =
    Hooks.hook_introspection_json ~max_cost_usd:0.25 ~destructive_check:false ()
  in
  check string "scope" "keeper_runtime_composite" (json |> member "scope" |> to_string);
  check int "slot_count" 14 (json |> member "slot_count" |> to_int);
  check int "active slots" 11 (json |> member "active_slot_count" |> to_int);
  check int "inactive slots" 3 (json |> member "inactive_slot_count" |> to_int);
  check
    bool
    "before_turn active"
    true
    (slot json "before_turn" |> member "active" |> to_bool);
  check_string_list_contains
    "before_turn includes passive loop feature"
    "passive_loop_nudge"
    (string_list_field (slot json "before_turn") "features");
  check
    bool
    "before_turn_params active"
    true
    (slot json "before_turn_params" |> member "active" |> to_bool);
  check
    string
    "before_turn_params source"
    "keeper_run_tools"
    (slot json "before_turn_params" |> member "source" |> to_string);
  let pre_tool_gates = string_list_field (slot json "pre_tool_use") "gates" in
  List.iter
    (fun gate -> check_string_list_contains ("pre_tool gate " ^ gate) gate pre_tool_gates)
    [ "timing"
    ; "custom_guard"
    ; "streak_gate"
    ; "keeper_deny_list"
    ; "cost_budget"
    ; "destructive_pattern_off"
    ; "governance_approval"
    ];
  let failure_effects = string_list_field (slot json "post_tool_use_failure") "effects" in
  check_string_list_contains
    "failure hook records counter"
    "tool_use_failure_metric"
    failure_effects;
  check_string_list_not_contains
    "failure hook no stale heuristic label"
    "heuristic_metrics"
    failure_effects;
  check bool "on_stop active" true (slot json "on_stop" |> member "active" |> to_bool);
  check_string_list_contains
    "on_stop records stop reason"
    "stop_reason_metric"
    (string_list_field (slot json "on_stop") "effects");
  check
    bool
    "on_idle_escalated active"
    true
    (slot json "on_idle_escalated" |> member "active" |> to_bool);
  check_string_list_contains
    "on_idle_escalated records metric"
    "idle_escalation_metric"
    (string_list_field (slot json "on_idle_escalated") "effects");
  check
    bool
    "pre_compact inactive"
    false
    (slot json "pre_compact" |> member "active" |> to_bool);
  check
    bool
    "post_compact inactive"
    false
    (slot json "post_compact" |> member "active" |> to_bool);
  check
    bool
    "on_context_compacted inactive"
    false
    (slot json "on_context_compacted" |> member "active" |> to_bool)
;;

let test_on_error_hook_records_callback_failure_metric () =
  let keeper = "callback-on-error-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_error" hooks.on_error in
  let before = lifecycle_callback_failure_count ~keeper ~callback:"on_error" in
  check_continue
    "on_error"
    (hook (Agent_sdk.Hooks.OnError { detail = "provider failed"; context = "unit-test" }));
  let after = lifecycle_callback_failure_count ~keeper ~callback:"on_error" in
  check (float 0.001) "on_error counter increments" 1.0 (after -. before)
;;

let test_on_tool_error_hook_records_callback_failure_metric () =
  let keeper = "callback-on-tool-error-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_tool_error" hooks.on_tool_error in
  let before = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  check_continue
    "on_tool_error"
    (hook
       (Agent_sdk.Hooks.OnToolError { tool_name = "tool_execute"; error = "tool failed" }));
  let after = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  check (float 0.001) "on_tool_error counter increments" 1.0 (after -. before)
;;

let test_on_tool_error_workflow_rejection_logs_warn_without_callback_failure () =
  let keeper = "callback-on-tool-workflow-rejection-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_tool_error" hooks.on_tool_error in
  let before = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  let before_seq = latest_log_seq () in
  let error =
    {|{"ok":false,"error":"tool_execute_command_shape_blocked","failure_class":"workflow_rejection"}|}
  in
  check_continue
    "on_tool_error workflow rejection"
    (hook (Agent_sdk.Hooks.OnToolError { tool_name = "Execute"; error }));
  let after = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  check
    (float 0.001)
    "workflow rejection does not increment callback failures"
    0.0
    (after -. before);
  match
    find_keeper_log_since
      ~since_seq:before_seq
      ~message_substring:("keeper:" ^ keeper ^ " tool_workflow_rejection: Execute")
  with
  | Some entry -> check string "log level" "WARN" (Log.level_to_string entry.level)
  | None -> fail "expected workflow rejection to be logged as keeper WARN"
;;

let test_on_tool_error_egress_blocked_logs_policy_warn_without_callback_failure
    () =
  let keeper = "callback-on-tool-egress-blocked-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_tool_error" hooks.on_tool_error in
  let before = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  let before_seq = latest_log_seq () in
  let error =
    {|{"ok":false,"error":"egress_blocked","failure_class":"policy_rejection","attempted":"localhost","allowed":["*.github.com"]}|}
  in
  check_continue
    "on_tool_error egress blocked"
    (hook (Agent_sdk.Hooks.OnToolError { tool_name = "Execute"; error }));
  let after = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  check
    (float 0.001)
    "egress blocked does not increment callback failures"
    0.0
    (after -. before);
  match
    find_keeper_log_since
      ~since_seq:before_seq
      ~message_substring:("keeper:" ^ keeper ^ " tool_policy_rejection: Execute")
  with
  | Some entry -> check string "log level" "WARN" (Log.level_to_string entry.level)
  | None -> fail "expected egress block to be logged as keeper policy WARN"
;;

let test_on_tool_error_legacy_egress_blocked_records_callback_failure
    () =
  let keeper = "callback-on-tool-legacy-egress-blocked-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_tool_error" hooks.on_tool_error in
  let before = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  let error =
    {|{"ok":false,"error":"egress_blocked","attempted":"localhost","allowed":["*.github.com"]}|}
  in
  check_continue
    "on_tool_error legacy egress blocked"
    (hook (Agent_sdk.Hooks.OnToolError { tool_name = "Execute"; error }));
  let after = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  check
    (float 0.001)
    "legacy egress increments callback failures"
    1.0
    (after -. before)
;;

let test_on_tool_error_blob_workflow_rejection_logs_warn_without_callback_failure
    () =
  let keeper = "callback-on-tool-blob-workflow-rejection-keeper" in
  let root = temp_dir () in
  let hooks = make_test_hooks_at_root keeper root in
  let hook = require_hook "on_tool_error" hooks.on_tool_error in
  let before = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  let before_seq = latest_log_seq () in
  let payload =
    Printf.sprintf
      {|{"ok":false,"error":"tool_execute_command_shape_blocked","padding":"%s","detail":{"failure_class":"workflow_rejection"}}|}
      (String.make 260 'x')
  in
  let store = Tool_blob_store.create ~base_path:root in
  let error = Tool_blob_store.put store ~bytes:payload ~mime:"text/plain" in
  let error = Tool_output.encode_for_oas error in
  check_continue
    "on_tool_error blob workflow rejection"
    (hook (Agent_sdk.Hooks.OnToolError { tool_name = "Execute"; error }));
  let after = lifecycle_callback_failure_count ~keeper ~callback:"on_tool_error" in
  check
    (float 0.001)
    "blob workflow rejection does not increment callback failures"
    0.0
    (after -. before);
  match
    find_keeper_log_since
      ~since_seq:before_seq
      ~message_substring:("keeper:" ^ keeper ^ " tool_workflow_rejection: Execute")
  with
  | Some entry -> check string "blob log level" "WARN" (Log.level_to_string entry.level)
  | None -> fail "expected blob workflow rejection to be logged as keeper WARN"
;;

let test_on_stop_hook_records_stop_reason_metric () =
  let keeper = "callback-on-stop-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_stop" hooks.on_stop in
  let before = on_stop_count ~keeper ~stop_reason:"end_turn" in
  check_continue
    "on_stop"
    (hook
       (Agent_sdk.Hooks.OnStop
          { reason = Agent_sdk.Types.EndTurn; response = make_response () }));
  let after = on_stop_count ~keeper ~stop_reason:"end_turn" in
  check (float 0.001) "on_stop counter increments" 1.0 (after -. before);
  let unknown_before = on_stop_count ~keeper ~stop_reason:"unknown" in
  check_continue
    "on_stop unknown"
    (hook
       (Agent_sdk.Hooks.OnStop
          { reason = Agent_sdk.Types.Unknown "provider raw detail"
          ; response =
              make_response
                ~stop_reason:(Agent_sdk.Types.Unknown "provider raw detail")
                ()
          }));
  let unknown_after = on_stop_count ~keeper ~stop_reason:"unknown" in
  check
    (float 0.001)
    "unknown stop reason is bounded"
    1.0
    (unknown_after -. unknown_before)
;;

let test_on_idle_escalated_hook_records_metric () =
  let keeper = "callback-on-idle-escalated-keeper" in
  let hooks = make_test_hooks keeper in
  let hook = require_hook "on_idle_escalated" hooks.on_idle_escalated in
  let before =
    on_idle_escalated_count ~keeper ~severity:"final_warning" ~decision:"nudge"
  in
  check_nudge
    "on_idle_escalated"
    (hook
       (Agent_sdk.Hooks.OnIdleEscalated
          { severity = Agent_sdk.Hooks.Idle_severity.Final_warning
          ; consecutive_idle_turns = 1
          ; tool_names = [ "tool_execute" ]
          }));
  let after =
    on_idle_escalated_count ~keeper ~severity:"final_warning" ~decision:"nudge"
  in
  check (float 0.001) "on_idle_escalated counter increments" 1.0 (after -. before)
;;

let test_on_idle_hook_returns_runtime_nudge () =
  let hooks = make_test_hooks "callback-on-idle-keeper" in
  let hook = require_hook "on_idle" hooks.on_idle in
  check_nudge
    "on_idle"
    (hook
       (Agent_sdk.Hooks.OnIdle
          { consecutive_idle_turns = 1; tool_names = [ "tool_execute" ] }))
;;

let () =
  run
    "keeper_hooks_oas/telemetry"
    [ ( "costs_jsonl"
      , [ test_case
            "emit_cost_event keeps throughput and memory fields"
            `Quick
            test_emit_cost_event_writes_inference_telemetry
        ; test_case
            "emit_cost_event marks usage_missing"
            `Quick
            test_emit_cost_event_marks_usage_missing
        ; test_case
            "emit_cost_event redacts typed provider kind for bare model"
            `Quick
            test_emit_cost_event_redacts_typed_provider_kind_for_bare_model
        ; test_case
            "inference telemetry runtime JSON redacts identity"
            `Quick
            test_inference_telemetry_runtime_json_redacts_identity
        ; test_case
            "emit_cost_event computes wall tok/s without native timings"
            `Quick
            test_emit_cost_event_writes_wall_tok_s_without_provider_timings
        ; test_case
            "emit_cost_event computes wall tok/s after first chunk"
            `Quick
            test_emit_cost_event_derives_wall_tok_s_after_first_chunk
        ; test_case
            "emit_cost_event marks untrusted usage"
            `Quick
            test_emit_cost_event_marks_untrusted_usage
        ; test_case
            "emit_cost_event marks unpriced paid model"
            `Quick
            test_emit_cost_event_marks_unpriced_paid_model
        ; test_case
            "emit_cost_event records auto resolution source"
            `Quick
            test_emit_cost_event_records_auto_resolution_source
        ; test_case
            "emit_cost_event records provider-prefixed auto resolution source"
            `Quick
            test_emit_cost_event_records_provider_prefixed_auto_resolution_source
        ] )
    ; ( "tool_telemetry"
      , [ test_case
            "tool execution summary derives provider and outcome"
            `Quick
            test_tool_execution_summary_derives_provider_and_outcome
        ; test_case
            "trajectory duration keeps positive sub-ms values"
            `Quick
            test_trajectory_duration_ms_preserves_positive_sub_ms
        ; test_case
            "trajectory duration rejects non-positive values"
            `Quick
            test_trajectory_duration_ms_rejects_zero_and_non_finite
        ; test_case
            "keeper tool duration metric tracks labels"
            `Quick
            test_record_keeper_tool_duration_metric_tracks_labels
        ] )
    ; ( "llm_tok_s_metrics"
      , [ test_case
            "both histograms observe when timings present"
            `Quick
            test_record_llm_tok_s_metrics_both_histograms_observe
        ; test_case
            "timings=None is no-op (Provider_a/Provider_f path)"
            `Quick
            test_record_llm_tok_s_metrics_timings_none_is_noop
        ; test_case
            "Some 0.0 prompt rate is skipped (no bucket poisoning)"
            `Quick
            test_record_llm_tok_s_metrics_zero_value_is_skipped
        ; test_case
            "telemetry=None is a safe no-op"
            `Quick
            test_record_llm_tok_s_metrics_none_telemetry_is_noop
        ] )
    ; ( "thinking_log_summary"
      , [ test_case
            "summarizes thinking metadata only"
            `Quick
            test_summarize_thinking_blocks_metadata_only
        ; test_case
            "reports none without thinking blocks"
            `Quick
            test_summarize_thinking_blocks_none
        ] )
    ; ( "llm_inference_latency"
      , [ test_case
            "positive latency observes histogram"
            `Quick
            test_record_llm_inference_latency_metric_positive_observes
        ; test_case
            "zero latency increments counter and floors histogram"
            `Quick
            test_record_llm_inference_latency_metric_zero_floors
        ; test_case
            "missing telemetry increments missing counter"
            `Quick
            test_record_llm_inference_latency_metric_none_counts_missing
        ] )
    ; ( "response_content_quality"
      , [ test_case
            "empty end_turn response content counts"
            `Quick
            test_record_response_content_quality_metric_empty_end_turn_counts
        ; test_case
            "blank text response content counts"
            `Quick
            test_record_response_content_quality_metric_blank_text_counts
        ; test_case
            "tool-use-only response is progress"
            `Quick
            test_record_response_content_quality_metric_tool_use_is_progress
        ] )
    ; ( "hook_introspection"
      , [ test_case
            "reports current runtime slots"
            `Quick
            test_hook_introspection_reports_current_runtime_slots
        ; test_case
            "on_error records callback metric"
            `Quick
            test_on_error_hook_records_callback_failure_metric
        ; test_case
            "on_tool_error records callback metric"
            `Quick
            test_on_tool_error_hook_records_callback_failure_metric
        ; test_case
            "on_tool_error workflow rejection logs warn"
            `Quick
            test_on_tool_error_workflow_rejection_logs_warn_without_callback_failure
        ; test_case
            "on_tool_error egress block logs policy warn"
            `Quick
            test_on_tool_error_egress_blocked_logs_policy_warn_without_callback_failure
        ; test_case
            "on_tool_error legacy egress block records callback failure"
            `Quick
            test_on_tool_error_legacy_egress_blocked_records_callback_failure
        ; test_case
            "on_tool_error blob workflow rejection logs warn"
            `Quick
            test_on_tool_error_blob_workflow_rejection_logs_warn_without_callback_failure
        ; test_case
            "on_stop records stop reason metric"
            `Quick
            test_on_stop_hook_records_stop_reason_metric
        ; test_case
            "on_idle_escalated records metric"
            `Quick
            test_on_idle_escalated_hook_records_metric
        ; test_case
            "on_idle returns runtime nudge"
            `Quick
            test_on_idle_hook_returns_runtime_nudge
        ] )
    ]
;;
