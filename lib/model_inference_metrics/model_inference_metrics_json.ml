(** Model_inference_metrics_json — JSON serialization, keeper prompt
    feedback rendering, and the composed cost-latency endpoint payload
    for {!Model_inference_metrics}.

    Provider/model identities are projected to redacted public runtime
    lane labels at this boundary; raw model ids never appear in any
    emitted JSON or prompt text.

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane A).
    Internal sibling module of the facade; do not call directly from
    outside the library. *)

open Model_inference_metrics_entry
open Model_inference_metrics_reader
open Model_inference_metrics_aggregate

(* ── Public runtime-lane labels ─────────────────────────── *)

let public_runtime_label = "runtime"

let public_runtime_lane_label model_key =
  let digest = Digest.string model_key |> Digest.to_hex in
  "runtime_lane_" ^ String.sub digest 0 12

(* ── JSON serialization ─────────────────────────────────── *)

let bucket_metric_to_json (b : bucket_metric) : Yojson.Safe.t =
  `Assoc
    [ "ts_start", `Float b.b_ts_start
    ; "entry_count", `Int b.b_entry_count
    ; "success_count", `Int b.b_success_count
    ; "error_count", `Int b.b_error_count
    ; "p50_latency_ms", Json_util.float_opt_to_json b.b_p50_latency_ms
    ; "p95_latency_ms", Json_util.float_opt_to_json b.b_p95_latency_ms
    ; "error_rate", `Float b.b_error_rate
    ; "total_cost_usd", Json_util.float_opt_to_json b.b_total_cost_usd
    ; "cache_hit_ratio", Json_util.float_opt_to_json b.b_cache_hit_ratio
    ]
;;

let model_stats_to_json ?(model_label = public_runtime_label) (s : model_stats)
  : Yojson.Safe.t
  =
  `Assoc
    [ "model_id", `String model_label
    ; "provider", `Null
    ; "entry_count", `Int s.entry_count
    ; "avg_tok_per_sec", Json_util.float_opt_to_json s.avg_tok_per_sec
    ; "p50_tok_per_sec", Json_util.float_opt_to_json s.p50_tok_per_sec
    ; "p95_tok_per_sec", Json_util.float_opt_to_json s.p95_tok_per_sec
    ; "prompt_avg_tok_per_sec", Json_util.float_opt_to_json s.prompt_avg_tok_per_sec
    ; "prompt_p50_tok_per_sec", Json_util.float_opt_to_json s.prompt_p50_tok_per_sec
    ; "prompt_p95_tok_per_sec", Json_util.float_opt_to_json s.prompt_p95_tok_per_sec
    ; "hw_decode_avg_tok_per_sec", Json_util.float_opt_to_json s.hw_decode_avg_tok_per_sec
    ; "hw_decode_p50_tok_per_sec", Json_util.float_opt_to_json s.hw_decode_p50_tok_per_sec
    ; "hw_decode_p95_tok_per_sec", Json_util.float_opt_to_json s.hw_decode_p95_tok_per_sec
    ; "max_peak_memory_gb", Json_util.float_opt_to_json s.max_peak_memory_gb
    ; "thinking_fraction", Json_util.float_opt_to_json s.thinking_fraction
    ; "avg_latency_ms", Json_util.float_opt_to_json s.avg_latency_ms
    ; "p50_latency_ms", Json_util.float_opt_to_json s.p50_latency_ms
    ; "p95_latency_ms", Json_util.float_opt_to_json s.p95_latency_ms
    ; "total_input_tokens", Json_util.int_opt_to_json s.total_input_tokens
    ; "total_output_tokens", Json_util.int_opt_to_json s.total_output_tokens
    ; "total_cache_read_tokens", Json_util.int_opt_to_json s.total_cache_read_tokens
    ; "total_cache_creation_tokens", Json_util.int_opt_to_json s.total_cache_creation_tokens
    ; "total_reasoning_tokens", Json_util.int_opt_to_json s.total_reasoning_tokens
    ; "usage_sample_count", `Int s.usage_sample_count
    ; "telemetry_sample_count", `Int s.telemetry_sample_count
    ; "usage_missing_count", `Int s.usage_missing_count
    ; "telemetry_missing_count", `Int s.telemetry_missing_count
    ; "coverage_status", `String s.coverage_status
    ; "primary_coverage_stage", Json_util.string_opt_to_json s.primary_coverage_stage
    ; "primary_coverage_reason", Json_util.string_opt_to_json s.primary_coverage_reason
    ; ( "coverage_reason_counts"
      , `List
          (List.map
             (fun (c : coverage_reason_count) ->
                `Assoc [ "reason", `String c.crc_reason; "count", `Int c.crc_count ])
             s.coverage_reason_counts) )
    ; "fallback_count", `Int s.fallback_count
    ; "success_count", `Int s.success_count
    ; "error_count", `Int s.error_count
    ; "total_cost_usd", Json_util.float_opt_to_json s.total_cost_usd
    ; "avg_tool_calls_per_turn", `Float s.avg_tool_calls_per_turn
    ; "total_tool_calls", `Int s.total_tool_calls
    ; ( "top_tools"
      , `List
          (List.map
             (fun (tool, count) -> `Assoc [ "tool", `String tool; "count", `Int count ])
             s.top_tools) )
    ; ( "recent_entries"
      , `List
          (List.map
             (fun (r : recent_entry) ->
                `Assoc
                  [ "ts_unix", `Float r.re_ts_unix
                  ; "provider", `Null
                  ; "outcome", `String r.re_outcome
                  ; "stop_reason", Json_util.string_opt_to_json r.re_stop_reason
                  ; "turn_lane", Json_util.string_opt_to_json r.re_turn_lane
                  ; "input_tokens", Json_util.int_opt_to_json r.re_input_tokens
                  ; "output_tokens", Json_util.int_opt_to_json r.re_output_tokens
                  ; ( "cache_read_tokens"
                    , Json_util.int_opt_to_json r.re_cache_read_tokens )
                  ; ( "cache_creation_tokens"
                    , Json_util.int_opt_to_json r.re_cache_creation_tokens )
                  ; "latency_ms", Json_util.float_opt_to_json r.re_latency_ms
                  ; "prompt_tok_per_sec", Json_util.float_opt_to_json r.re_prompt_tok_per_sec
                  ; "peak_memory_gb", Json_util.float_opt_to_json r.re_peak_memory_gb
                  ; "cost_usd", Json_util.float_opt_to_json r.re_cost_usd
                  ; "tools_count", `Int r.re_tools_count
                  ; ( "usage_reported"
                    , Json_util.bool_opt_to_json r.re_usage_reported )
                  ; ( "telemetry_reported"
                    , Json_util.bool_opt_to_json r.re_telemetry_reported )
                  ; "usage_trust", Json_util.string_opt_to_json r.re_usage_trust
                  ; ( "usage_anomaly_reasons"
                    , `List
                        (List.map
                           (fun reason -> `String reason)
                           r.re_usage_anomaly_reasons) )
                  ; "coverage_reason", Json_util.string_opt_to_json r.re_coverage_reason
                  ; "coverage_stage", Json_util.string_opt_to_json r.re_coverage_stage
                  ; "streaming_ttfrc_ms", Json_util.float_opt_to_json r.re_streaming_ttfrc_ms
                  ; "streaming_inter_chunk_count", Json_util.int_opt_to_json r.re_streaming_inter_chunk_count
                  ; "streaming_inter_chunk_avg_ms", Json_util.float_opt_to_json r.re_streaming_inter_chunk_avg_ms
                  ])
             s.recent_entries) )
    ; "buckets", `List (List.map bucket_metric_to_json s.buckets)
    ]
;;

let to_json (agg : aggregate) : Yojson.Safe.t =
  let latency_bucket_to_json b =
    `Assoc
      [ "lo", `Int b.lo_ms
      ; "hi", Json_util.int_opt_to_json b.hi_ms
      ; "n", `Int b.count
      ]
  in
  `Assoc
    [ "window_minutes", `Int agg.window_minutes
    ; "bucket_minutes", `Int agg.bucket_minutes
    ; "total_entries", `Int agg.total_entries
    ; "total_error_entries", `Int agg.total_error_entries
    ; "latency_buckets", `List (List.map latency_bucket_to_json agg.latency_buckets)
    ; ( "models"
      , `List
          (List.map
             (fun stats ->
                model_stats_to_json
                  ~model_label:(public_runtime_lane_label stats.model_id)
                  stats)
             agg.models) )
    ]
;;

(* ── Keeper prompt feedback rendering ───────────────────── *)

let pct numerator denominator =
  if denominator <= 0 then 0.0
  else Float.of_int numerator *. 100.0 /. Float.of_int denominator
;;

let float_field ?(suffix = "") = function
  | None -> "unknown"
  | Some value -> Printf.sprintf "%.1f%s" value suffix
;;

let int_field = function
  | None -> "unknown"
  | Some value -> string_of_int value
;;

let prompt_lane_line (index : int) (stats : model_stats) =
  let lane = public_runtime_lane_label stats.model_id in
  let error_rate = pct stats.error_count stats.entry_count in
  let cost =
    match stats.total_cost_usd with
    | None -> "unknown"
    | Some value -> Printf.sprintf "$%.4f" value
  in
  Printf.sprintf
    "- lane %d %s: turns=%d success=%d errors=%d error_rate=%.1f%% \
     p95_latency_ms=%s avg_tok_per_sec=%s input_tokens=%s output_tokens=%s \
     cost=%s coverage=%s"
    index
    lane
    stats.entry_count
    stats.success_count
    stats.error_count
    error_rate
    (float_field stats.p95_latency_ms)
    (float_field stats.avg_tok_per_sec)
    (int_field stats.total_input_tokens)
    (int_field stats.total_output_tokens)
    cost
    stats.coverage_status
;;

let prompt_feedback_guidance (agg : aggregate) =
  let error_rate = pct agg.total_error_entries agg.total_entries in
  let p95_values =
    List.filter_map (fun (stats : model_stats) -> stats.p95_latency_ms) agg.models
  in
  let max_p95 =
    match p95_values with
    | [] -> None
    | hd :: tl -> Some (List.fold_left Float.max hd tl)
  in
  let has_missing_coverage =
    List.exists
      (fun (stats : model_stats) ->
         stats.usage_missing_count > 0 || stats.telemetry_missing_count > 0)
      agg.models
  in
  let guidance =
    [
      ( error_rate >= 25.0
      , "recent error rate is high; checkpoint before long tool chains and stop \
         after repeated provider failures instead of looping." );
      ( Option.value ~default:0.0 max_p95 >= 120_000.0
      , "recent p95 latency is very high; keep turns smaller and prefer \
         incremental commits/log evidence." );
      ( has_missing_coverage
      , "some turns are missing usage or telemetry; preserve receipts/logs and \
         avoid treating missing metrics as success." );
    ]
    |> List.filter_map (fun (active, text) -> if active then Some text else None)
  in
  match guidance with
  | [] -> "runtime telemetry is healthy enough for normal turn planning."
  | items -> String.concat " " items
;;

let render_keeper_prompt_feedback (agg : aggregate) =
  if agg.total_entries <= 0 then ""
  else
    let models =
      agg.models
      |> List.sort (fun a b -> Int.compare b.entry_count a.entry_count)
      |> take 3
    in
    let header =
      Printf.sprintf
        "Recent model telemetry (last %d minutes): total_turns=%d \
         error_turns=%d error_rate=%.1f%% observed_lanes=%d"
        agg.window_minutes
        agg.total_entries
        agg.total_error_entries
        (pct agg.total_error_entries agg.total_entries)
        (List.length agg.models)
    in
    let lane_lines = List.mapi (fun i stats -> prompt_lane_line (i + 1) stats) models in
    String.concat
      "\n"
      (header :: lane_lines
       @ [ "Guidance: " ^ prompt_feedback_guidance agg
         ; "Use these redacted runtime-lane labels only as telemetry context; \
            do not invent concrete provider/model names from them." ])
;;

(* ── Provider stats JSON ────────────────────────────────── *)

let provider_stats_to_json (s : provider_stats) : Yojson.Safe.t =
  `Assoc
    [ "provider", `String public_runtime_label
    ; "entry_count", `Int s.ps_entry_count
    ; "model_count", `Int 0
    ; "avg_tok_per_sec", Json_util.float_opt_to_json s.ps_avg_tok_per_sec
    ; "avg_prompt_tok_per_sec", Json_util.float_opt_to_json s.ps_avg_prompt_tok_per_sec
    ; "avg_decode_tok_per_sec", Json_util.float_opt_to_json s.ps_avg_decode_tok_per_sec
    ; "avg_latency_ms", Json_util.float_opt_to_json s.ps_avg_latency_ms
    ; "p50_latency_ms", Json_util.float_opt_to_json s.ps_p50_latency_ms
    ; "p95_latency_ms", Json_util.float_opt_to_json s.ps_p95_latency_ms
    ; "total_cost_usd", Json_util.float_opt_to_json s.ps_total_cost_usd
    ]
;;

(* ── Cost & Latency aggregator ─────────────────────────────
   Composes the O4 cost-latency payload consumed by the
   /api/v1/dashboard/cost-latency endpoint.  All raw entries
   are read once; per-agent stats, the provider-by-model cost
   matrix, the latency histogram, and the global p50/p95 are
   derived from that single pass. *)

let compute_cost_latency_json ~base_path ~window_minutes : Yojson.Safe.t =
  let since_unix = Time_compat.now () -. (Float.of_int window_minutes *. 60.0) in
  let entries = read_all_entries ~base_path ~since_unix in
  let model_stats_list = aggregate_by_model entries in
  (* per-agent rows - sorted by cost descending, skip zero-signal rows *)
  let per_agent =
    model_stats_list
    |> List.filter (fun (m : model_stats) ->
      Option.value ~default:0.0 m.total_cost_usd > 0.0
      || Option.value ~default:0 m.total_input_tokens > 0
      || Option.value ~default:0 m.total_output_tokens > 0)
    |> List.sort (fun a b ->
      Float.compare
        (Option.value ~default:0.0 b.total_cost_usd)
        (Option.value ~default:0.0 a.total_cost_usd))
    |> List.map (fun (m : model_stats) ->
      `Assoc
        [ "agent", `String (public_runtime_lane_label m.model_id)
        ; "in_tok", `Int (Option.value ~default:0 m.total_input_tokens)
        ; "out_tok", `Int (Option.value ~default:0 m.total_output_tokens)
        (* sound-partial: allow missing cost in legacy rows; absence means zero
           observed spend, not a provider/model routing choice. *)
        ; "cost", `Float (Option.value ~default:0.0 m.total_cost_usd)
        ; "p50_ms", Json_util.float_opt_to_json m.p50_latency_ms
        ; "p95_ms", Json_util.float_opt_to_json m.p95_latency_ms
        ])
  in
  (* Public matrix keeps cost shape without exporting provider/model identities. *)
  let providers = if model_stats_list = [] then [] else [ public_runtime_label ] in
  let model_ids =
    List.map (fun (stats : model_stats) -> public_runtime_lane_label stats.model_id) model_stats_list
  in
  let grid =
    match providers with
    | [] -> []
    | _ ->
      [ `List
          (List.map
             (fun (m : model_stats) ->
                let cost =
                  match m.total_cost_usd with
                  | Some value -> value
                  | None -> 0.0
                in
                `Float cost)
             model_stats_list)
      ]
  in
  (* global p50/p95 from all entry latencies *)
  let all_latencies =
    entries |> List.filter_map (fun (e : raw_entry) -> e.latency_ms) |> Array.of_list
  in
  Array.sort Float.compare all_latencies;
  let global_p50 =
    if Array.length all_latencies = 0 then None else Some (percentile all_latencies 50.0)
  in
  let global_p95 =
    if Array.length all_latencies = 0 then None else Some (percentile all_latencies 95.0)
  in
  (* total cost across all models *)
  let total_cost_usd =
    List.fold_left
      (fun acc (m : model_stats) -> acc +. Option.value ~default:0.0 m.total_cost_usd)
      0.0
      model_stats_list
  in
  let latency_buckets = latency_histogram entries in
  let latency_bucket_to_json (b : latency_bucket) =
    `Assoc
      [ "lo", `Int b.lo_ms
      ; "hi", Json_util.int_opt_to_json b.hi_ms
      ; "n", `Int b.count
      ]
  in
  `Assoc
    [ "perAgent", `List per_agent
    ; ( "matrix"
      , `Assoc
          [ "providers", `List (List.map (fun p -> `String p) providers)
          ; "models", `List (List.map (fun m -> `String m) model_ids)
          ; "grid", `List grid
          ] )
    ; "latencyBuckets", `List (List.map latency_bucket_to_json latency_buckets)
    ; "p50", Json_util.float_opt_to_json global_p50
    ; "p95", Json_util.float_opt_to_json global_p95
    ; "total_cost_usd", `Float total_cost_usd
    ; "window_minutes", `Int window_minutes
    ; "generated_at", `Float (Time_compat.now ())
    ]
;;
