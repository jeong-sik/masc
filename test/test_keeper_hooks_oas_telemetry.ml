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
  check (float 0.001) "prompt_per_second" 21.55
    (json |> member "prompt_per_second" |> to_float);
  check (float 0.001) "provider_tokens_per_second" 81.56
    (json |> member "provider_tokens_per_second" |> to_float);
  check (float 0.001) "hw_decode_tokens_per_second" 81.56
    (json |> member "hw_decode_tokens_per_second" |> to_float);
  check (float 0.001) "peak_memory_gb" 52.66
    (json |> member "peak_memory_gb" |> to_float)

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

let () =
  run "keeper_hooks_oas/telemetry"
    [ ( "costs_jsonl",
        [ test_case "emit_cost_event keeps throughput and memory fields" `Quick
            test_emit_cost_event_writes_inference_telemetry ] )
    ; ( "tool_telemetry",
        [ test_case "tool execution summary derives provider and outcome" `Quick
            test_tool_execution_summary_derives_provider_and_outcome
        ; test_case "keeper tool duration metric tracks labels" `Quick
            test_record_keeper_tool_duration_metric_tracks_labels
        ] )
    ]
