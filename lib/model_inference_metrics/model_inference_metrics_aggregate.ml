(** Model_inference_metrics_aggregate — per-model and per-provider
    aggregation for {!Model_inference_metrics}.

    Takes parsed raw entries from {!Model_inference_metrics_reader} and
    produces the derived summaries consumed by the JSON layer and the
    keeper prompt feedback renderer.

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane A).
    Internal sibling module of the facade; do not call directly from
    outside the library. *)

open Model_inference_metrics_entry
open Model_inference_metrics_reader

(* ── Aggregate by model ─────────────────────────────────── *)

let aggregate_by_model (entries : raw_entry list) : model_stats list =
  let tbl : raw_entry list StringMap.t =
    List.fold_left
      (fun m e ->
         let prev =
           match StringMap.find_opt e.model m with
           | Some l -> l
           | None -> []
         in
         StringMap.add e.model (e :: prev) m)
      StringMap.empty
      entries
  in
  StringMap.fold
    (fun model_id entries acc ->
       let n = List.length entries in
       let success_entries = List.filter (fun e -> not e.is_error) entries in
       let tok_vals =
         List.filter_map (fun e -> e.tok_per_sec) success_entries |> Array.of_list
       in
       Array.sort Float.compare tok_vals;
       let prompt_vals =
         List.filter_map (fun e -> e.prompt_tok_per_sec) success_entries |> Array.of_list
       in
       Array.sort Float.compare prompt_vals;
       let hw_vals =
         List.filter_map (fun e -> e.hw_decode_tok_per_sec) success_entries
         |> Array.of_list
       in
       Array.sort Float.compare hw_vals;
       let peak_vals =
         List.filter_map (fun e -> e.peak_memory_gb) success_entries |> Array.of_list
       in
       Array.sort Float.compare peak_vals;
       let lat_vals =
         List.filter_map (fun e -> e.latency_ms) success_entries |> Array.of_list
       in
       Array.sort Float.compare lat_vals;
       let success_count = List.length success_entries in
       let error_count = count_if (fun e -> e.is_error) entries in
       let total_tool_calls =
         List.fold_left (fun acc e -> acc + e.tool_call_count) 0 entries
       in
       let usage_sample_count =
         List.fold_left
           (fun acc e -> if usage_signal_present e then acc + 1 else acc)
           0
           success_entries
       in
       let telemetry_sample_count =
         List.fold_left
           (fun acc e -> if telemetry_signal_present e then acc + 1 else acc)
           0
           success_entries
       in
       let usage_missing_count = max 0 (success_count - usage_sample_count) in
       let telemetry_missing_count = max 0 (success_count - telemetry_sample_count) in
       let coverage_reason_counts = coverage_reason_counts_of_entries success_entries in
       let primary_coverage_reason =
         match coverage_reason_counts with
         | first :: _ -> Some first.crc_reason
         | [] -> None
       in
       let primary_coverage_stage = most_common_stage_of_entries success_entries in
       let coverage_status =
         if success_count = 0 && error_count > 0
         then "error_only"
         else if usage_missing_count = 0 && telemetry_missing_count = 0
         then "full"
         else if usage_sample_count = 0 && telemetry_sample_count = 0
         then "none"
         else "partial"
       in
       (* thinking_fraction: count of entries with thinking_enabled=true over
       entries that reported the field. Entries without the field (older jsonl
       rows, providers that don't expose it) are excluded from denominator —
       None when no reporter at all. *)
       let thinking_fraction =
         let reported = List.filter_map (fun e -> e.thinking_enabled) success_entries in
         match reported with
         | [] -> None
         | xs ->
           let total = List.length xs in
           let on_count = count_if (fun x -> x) xs in
           Some (float_of_int on_count /. float_of_int total)
       in
       let provider =
         match List.find_map (fun e -> e.provider) entries with
         | Some _ as p -> p
        | None -> None
       in
       let stats =
         { model_id
         ; provider
         ; entry_count = n
         ; avg_tok_per_sec = average_opt tok_vals
         ; p50_tok_per_sec = percentile_opt tok_vals 50.0
         ; p95_tok_per_sec = percentile_opt tok_vals 95.0
         ; prompt_avg_tok_per_sec = average_opt prompt_vals
         ; prompt_p50_tok_per_sec = percentile_opt prompt_vals 50.0
         ; prompt_p95_tok_per_sec = percentile_opt prompt_vals 95.0
         ; hw_decode_avg_tok_per_sec = average_opt hw_vals
         ; hw_decode_p50_tok_per_sec = percentile_opt hw_vals 50.0
         ; hw_decode_p95_tok_per_sec = percentile_opt hw_vals 95.0
         ; max_peak_memory_gb =
             (if Array.length peak_vals = 0
              then None
              else Some peak_vals.(Array.length peak_vals - 1))
         ; thinking_fraction
         ; avg_latency_ms = average_opt lat_vals
         ; p50_latency_ms = percentile_opt lat_vals 50.0
         ; p95_latency_ms = percentile_opt lat_vals 95.0
         ; total_input_tokens =
             sum_int_opt (List.filter_map (fun e -> e.input_tokens) success_entries)
         ; total_output_tokens =
             sum_int_opt (List.filter_map (fun e -> e.output_tokens) success_entries)
         ; total_cache_read_tokens =
             sum_int_opt (List.filter_map (fun e -> e.cache_read_tokens) success_entries)
         ; total_cache_creation_tokens =
             sum_int_opt (List.filter_map (fun e -> e.cache_creation_tokens) success_entries)
         ; total_reasoning_tokens =
             sum_int_opt (List.filter_map (fun e -> e.reasoning_tokens) success_entries)
         ; usage_sample_count
         ; telemetry_sample_count
         ; usage_missing_count
         ; telemetry_missing_count
         ; coverage_status
         ; primary_coverage_stage
         ; primary_coverage_reason
         ; coverage_reason_counts
         ; fallback_count = count_if (fun e -> e.fallback_applied) entries
         ; success_count
         ; error_count
         ; total_cost_usd =
             sum_float_opt (List.filter_map (fun e -> e.cost_usd) success_entries)
         ; total_tool_calls
         ; avg_tool_calls_per_turn =
             (if n = 0 then 0.0 else Float.of_int total_tool_calls /. Float.of_int n)
         ; top_tools =
             (let tool_map : int StringMap.t =
                List.fold_left
                  (fun m e ->
                     List.fold_left
                       (fun m t ->
                          let prev =
                            match StringMap.find_opt t m with
                            | Some c -> c
                            | None -> 0
                          in
                          StringMap.add t (prev + 1) m)
                       m
                       e.tools_used)
                  StringMap.empty
                  entries
              in
              StringMap.fold (fun tool count acc -> (tool, count) :: acc) tool_map []
              |> List.sort (fun (_, a) (_, b) -> compare b a)
              |> take 10)
         ; recent_entries =
             success_entries
             |> List.sort (fun a b -> Float.compare b.ts_unix a.ts_unix)
             |> take 5
             |> List.map (fun e ->
               { re_ts_unix = e.ts_unix
               ; re_provider = e.provider
               ; re_outcome = e.outcome
               ; re_stop_reason = e.stop_reason
               ; re_turn_lane = e.turn_lane
               ; re_input_tokens = e.input_tokens
               ; re_output_tokens = e.output_tokens
               ; re_cache_read_tokens = e.cache_read_tokens
               ; re_cache_creation_tokens = e.cache_creation_tokens
               ; re_latency_ms = e.latency_ms
               ; re_prompt_tok_per_sec = e.prompt_tok_per_sec
               ; re_peak_memory_gb = e.peak_memory_gb
               ; re_cost_usd = e.cost_usd
               ; re_tools_count = e.tool_call_count
               ; re_usage_reported = e.usage_reported
               ; re_telemetry_reported = e.telemetry_reported
               ; re_usage_trust = e.usage_trust
               ; re_usage_anomaly_reasons = e.usage_anomaly_reasons
               ; re_coverage_reason = coverage_reason_of_entry e
               ; re_coverage_stage = coverage_stage_of_entry e
               ; re_streaming_ttfrc_ms = e.streaming_ttfrc_ms
               ; re_streaming_inter_chunk_count = e.streaming_inter_chunk_count
               ; re_streaming_inter_chunk_avg_ms = e.streaming_inter_chunk_avg_ms
               })
         ; buckets = []
         }
       in
       stats :: acc)
    tbl
    []
  |> List.sort (fun a b -> compare b.entry_count a.entry_count)
;;

(* ── Time-bucketed aggregation ──────────────────────────── *)

(** Bucket entries for a single model. Returns oldest-first list of
    non-empty buckets. *)
let bucket_entries_for_model (entries : raw_entry list) ~(bucket_sec : int)
  : bucket_metric list
  =
  let bsec = if bucket_sec <= 0 then 60 else bucket_sec in
  let bsec_f = Float.of_int bsec in
  let tbl : raw_entry list IntMap.t =
    List.fold_left
      (fun m e ->
         let key = int_of_float (Float.floor (e.ts_unix /. bsec_f)) in
         let prev =
           match IntMap.find_opt key m with
           | Some l -> l
           | None -> []
         in
         IntMap.add key (e :: prev) m)
      IntMap.empty
      entries
  in
  IntMap.fold
    (fun key bucket_entries acc ->
       let n = List.length bucket_entries in
       let lat_vals =
         List.filter_map (fun e -> e.latency_ms) bucket_entries |> Array.of_list
       in
       Array.sort Float.compare lat_vals;
       let success_count = count_if (fun e -> not e.is_error) bucket_entries in
       let error_count = count_if (fun e -> e.is_error) bucket_entries in
       let cache_reads = List.filter_map (fun e -> e.cache_read_tokens) bucket_entries in
       let inputs = List.filter_map (fun e -> e.input_tokens) bucket_entries in
       let cache_hit_ratio =
         match sum_int_opt cache_reads, sum_int_opt inputs with
         | None, None -> None
         | total_cache_read, total_input ->
           let total_cache_read = Option.value ~default:0 total_cache_read in
           let total_input = Option.value ~default:0 total_input in
           let denom = total_cache_read + total_input in
           if denom = 0
           then Some 0.0
           else Some (Float.of_int total_cache_read /. Float.of_int denom)
       in
       let error_rate =
         if n = 0 then 0.0 else Float.of_int error_count /. Float.of_int n
       in
       let bucket =
         { b_ts_start = Float.of_int key *. bsec_f
         ; b_entry_count = n
         ; b_success_count = success_count
         ; b_error_count = error_count
         ; b_p50_latency_ms = percentile_opt lat_vals 50.0
         ; b_p95_latency_ms = percentile_opt lat_vals 95.0
         ; b_error_rate = error_rate
         ; b_total_cost_usd =
             sum_float_opt (List.filter_map (fun e -> e.cost_usd) bucket_entries)
         ; b_cache_hit_ratio = cache_hit_ratio
         }
       in
       bucket :: acc)
    tbl
    []
  |> List.sort (fun a b -> Float.compare a.b_ts_start b.b_ts_start)
;;

let group_entries_by_model (entries : raw_entry list) : (string * raw_entry list) list =
  let tbl : raw_entry list StringMap.t =
    List.fold_left
      (fun m e ->
         let prev =
           match StringMap.find_opt e.model m with
           | Some l -> l
           | None -> []
         in
         StringMap.add e.model (e :: prev) m)
      StringMap.empty
      entries
  in
  StringMap.fold (fun model es acc -> (model, es) :: acc) tbl []
;;

let latency_histogram (entries : raw_entry list) : latency_bucket list =
  let boundaries = [ 1000; 4000; 16000 ] in
  let n = List.length boundaries in
  let bins = Array.make (n + 1) 0 in
  List.iter
    (fun e ->
       match e.latency_ms with
       | None -> ()
       | Some ms ->
         let ms = int_of_float ms in
         let idx =
           match List.find_index (fun b -> ms < b) boundaries with
           | Some i -> i
           | None -> n
         in
         bins.(idx) <- bins.(idx) + 1)
    entries;
  let rec build i lo = function
    | [] -> [ { lo_ms = lo; hi_ms = None; count = bins.(i) } ]
    | hi :: rest ->
      { lo_ms = lo; hi_ms = Some hi; count = bins.(i) } :: build (i + 1) hi rest
  in
  build 0 0 boundaries
;;

(* ── Public compute functions ───────────────────────────── *)

let compute ~base_path ~window_minutes : aggregate =
  let since_unix = Time_compat.now () -. (Float.of_int window_minutes *. 60.0) in
  let entries = read_all_entries ~base_path ~since_unix in
  let models = aggregate_by_model entries in
  let total_error_entries = count_if (fun e -> e.is_error) entries in
  { window_minutes
  ; bucket_minutes = 0
  ; models
  ; total_entries = List.length entries
  ; total_error_entries
  ; latency_buckets = latency_histogram entries
  }
;;

let compute_with_buckets ~base_path ~window_minutes ~bucket_minutes : aggregate =
  let bucket_minutes = max 1 bucket_minutes in
  let since_unix = Time_compat.now () -. (Float.of_int window_minutes *. 60.0) in
  let entries = read_all_entries ~base_path ~since_unix in
  let models = aggregate_by_model entries in
  let bucket_sec = bucket_minutes * 60 in
  let by_model_map : raw_entry list StringMap.t =
    List.fold_left
      (fun acc (model, es) -> StringMap.add model es acc)
      StringMap.empty
      (group_entries_by_model entries)
  in
  let models_with_buckets =
    List.map
      (fun (s : model_stats) ->
         let model_entries =
           match StringMap.find_opt s.model_id by_model_map with
           | Some es -> es
           | None -> []
         in
         { s with buckets = bucket_entries_for_model model_entries ~bucket_sec })
      models
  in
  let total_error_entries = count_if (fun e -> e.is_error) entries in
  { window_minutes
  ; bucket_minutes
  ; models = models_with_buckets
  ; total_entries = List.length entries
  ; total_error_entries
  ; latency_buckets = latency_histogram entries
  }
;;

let aggregate_buckets ~base_path ~window_min ~bucket_min : model_bucketed list =
  let since_unix = Time_compat.now () -. (Float.of_int window_min *. 60.0) in
  let entries = read_all_entries ~base_path ~since_unix in
  let bucket_sec = if bucket_min <= 0 then 60 else bucket_min * 60 in
  let by_model = group_entries_by_model entries in
  List.map
    (fun (model_id, es) ->
       { mb_model_id = model_id; mb_buckets = bucket_entries_for_model es ~bucket_sec })
    by_model
  |> List.sort (fun a b -> compare a.mb_model_id b.mb_model_id)
;;

(* ── Runtime-lane rollup ────────────────────────────────────
   Legacy provider strings are not reconstructed here.  Public dashboard
   projections keep aggregate throughput/latency evidence while model/provider
   identity is represented by neutral runtime lanes.

   All means are [entry_count]-weighted. Latency percentiles are
   approximations — averaging per-model p50/p95 does not produce a
   true cross-model percentile, but the closed form here is good enough
   for dashboard sparklines and avoids dragging the raw entry list
   through another aggregation layer. Call sites that need exact
   percentiles should compute them from [recent_entries]. *)

(* Entry-weighted mean over [models]. Returns [None] when every
   contributing model returned [None] for the metric or when the total
   weight collapses to zero (all entry_count = 0). *)
let weighted_mean_opt (models : model_stats list) (f : model_stats -> float option)
  : float option
  =
  let sum, weight =
    List.fold_left
      (fun (sum, weight) (m : model_stats) ->
         match f m with
         | Some v when m.entry_count > 0 ->
           sum +. (v *. Float.of_int m.entry_count), weight + m.entry_count
         | _ -> sum, weight)
      (0.0, 0)
      models
  in
  if weight = 0 then None else Some (sum /. Float.of_int weight)
;;

(* Sum of a [float option] projection across models.  Returns [None] iff
   every contributing model returned [None] (distinguishing "no data"
   from "reported and zero"). *)
let summed_opt_float (models : model_stats list) (f : model_stats -> float option)
  : float option
  =
  let total, reported =
    List.fold_left
      (fun (total, reported) (m : model_stats) ->
         match f m with
         | Some v -> total +. v, reported + 1
         | None -> total, reported)
      (0.0, 0)
      models
  in
  if reported = 0 then None else Some total
;;

let provider_rollup (agg : aggregate) : provider_stats list =
  let by_provider : (string, model_stats list) Hashtbl.t = Hashtbl.create 8 in
  List.iter
    (fun (m : model_stats) ->
       match m.provider with
       | None -> ()
       | Some p ->
         let existing =
           match Hashtbl.find_opt by_provider p with
           | Some v -> v
           | None -> []
         in
         Hashtbl.replace by_provider p (m :: existing))
    agg.models;
  let rolled =
    Hashtbl.fold
      (fun provider models acc ->
         let total_entries =
           List.fold_left (fun n (m : model_stats) -> n + m.entry_count) 0 models
         in
         let rollup =
           { ps_provider = provider
           ; ps_entry_count = total_entries
           ; ps_model_count = List.length models
           ; ps_avg_tok_per_sec = weighted_mean_opt models (fun m -> m.avg_tok_per_sec)
           ; ps_avg_prompt_tok_per_sec =
               weighted_mean_opt models (fun m -> m.prompt_avg_tok_per_sec)
           ; ps_avg_decode_tok_per_sec =
               weighted_mean_opt models (fun m -> m.hw_decode_avg_tok_per_sec)
           ; ps_avg_latency_ms = weighted_mean_opt models (fun m -> m.avg_latency_ms)
           ; ps_p50_latency_ms = weighted_mean_opt models (fun m -> m.p50_latency_ms)
           ; ps_p95_latency_ms = weighted_mean_opt models (fun m -> m.p95_latency_ms)
           ; ps_total_cost_usd = summed_opt_float models (fun m -> m.total_cost_usd)
           }
         in
         rollup :: acc)
      by_provider
      []
  in
  List.sort (fun a b -> Int.compare b.ps_entry_count a.ps_entry_count) rolled
;;
