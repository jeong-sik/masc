module StringMap = Map.Make (String)

(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper decisions.jsonl files, extracts telemetry entries within
    a configurable time window, and computes per-model aggregates:
    avg/p50/p95 tok/s, avg/p50/p95 latency, total reasoning tokens,
    cost attribution, tool usage, and success/error rates.

    Closes #5775. @since 2.259.0
    Extended with cost/tool/error metrics: @since 2.270.0 *)

(* ── Types ──────────────────────────────────────────────── *)

type recent_entry = {
  re_ts_unix : float;
  re_input_tokens : int;
  re_output_tokens : int;
  re_latency_ms : float;
  re_cost_usd : float;
  re_tools_count : int;
}

type bucket_metric = {
  b_ts_start : float;
  b_entry_count : int;
  b_success_count : int;
  b_error_count : int;
  b_p50_latency_ms : float;
  b_p95_latency_ms : float;
  b_error_rate : float;
  b_total_cost_usd : float;
  b_cache_hit_ratio : float;
}

type model_bucketed = {
  mb_model_id : string;
  mb_buckets : bucket_metric list;
}

type model_stats = {
  model_id : string;
  entry_count : int;
  avg_tok_per_sec : float;
  p50_tok_per_sec : float;
  p95_tok_per_sec : float;
  avg_latency_ms : float;
  p50_latency_ms : float;
  p95_latency_ms : float;
  total_input_tokens : int;
  total_output_tokens : int;
  total_cache_read_tokens : int;
  total_reasoning_tokens : int;
  fallback_count : int;
  success_count : int;
  error_count : int;
  total_cost_usd : float;
  avg_tool_calls_per_turn : float;
  total_tool_calls : int;
  top_tools : (string * int) list;
  recent_entries : recent_entry list;
  buckets : bucket_metric list;
}

type aggregate = {
  window_minutes : int;
  bucket_minutes : int;
  models : model_stats list;
  total_entries : int;
  total_error_entries : int;
}

(* ── Percentile ───────────────────────���─────────────────── *)

let percentile (sorted : float array) (p : float) : float =
  let n = Array.length sorted in
  if n = 0 then 0.0
  else
    let rank = p /. 100.0 *. Float.of_int (n - 1) in
    let lo = int_of_float (floor rank) in
    let hi = min (lo + 1) (n - 1) in
    let frac = rank -. Float.of_int lo in
    sorted.(lo) *. (1.0 -. frac) +. sorted.(hi) *. frac

(* ── Parse telemetry from decisions.jsonl entries ────────── *)

type raw_entry = {
  model : string;
  ts_unix : float;
  tok_per_sec : float;
  latency_ms : float;
  input_tokens : int;
  output_tokens : int;
  cache_read_tokens : int;
  reasoning_tokens : int;
  fallback_applied : bool;
  cost_usd : float;
  tool_call_count : int;
  tools_used : string list;
  is_error : bool;
}

let parse_telemetry_entry (json : Yojson.Safe.t) ~since_unix : raw_entry option =
  let ts = Safe_ops.json_float_opt "ts_unix" json |> Option.value ~default:0.0 in
  if ts < since_unix then None
  else
    match json with
    | `Assoc fields ->
      (* Read outer record fields available for both success and error turns *)
      let outer_tool_call_count =
        match List.assoc_opt "tool_call_count" fields with
        | Some (`Int n) -> n | _ -> 0
      in
      let outer_tools_used =
        match List.assoc_opt "tools_used" fields with
        | Some (`List xs) ->
          List.filter_map (function
            | `String s when String.length s > 0 -> Some s
            | _ -> None) xs
        | _ -> []
      in
      (match List.assoc_opt "telemetry" fields with
       | Some (`Assoc tfields) ->
         (* Check if this is an error turn (telemetry.outcome = "error") *)
         let is_error =
           match List.assoc_opt "outcome" tfields with
           | Some (`String "error") -> true | _ -> false
         in
         if is_error then
           (* Error turns: use first candidate model or cascade_name for attribution *)
           let model =
             match List.assoc_opt "candidate_models" tfields with
             | Some (`List ((`String m) :: _)) -> m
             | _ ->
               match List.assoc_opt "cascade_name" tfields with
               | Some (`String s) -> s ^ " (cascade)"
               | _ -> "__error__"
           in
           Some { model; ts_unix = ts; tok_per_sec = 0.0; latency_ms = 0.0;
                  input_tokens = 0; output_tokens = 0;
                  cache_read_tokens = 0; reasoning_tokens = 0;
                  fallback_applied = false; cost_usd = 0.0;
                  tool_call_count = outer_tool_call_count;
                  tools_used = outer_tools_used;
                  is_error = true }
         else
           (* Success turns: full telemetry parsing *)
           let model =
             (match List.assoc_opt "selected_model" tfields with
              | Some (`String s) -> s
              | _ ->
                match List.assoc_opt "model_used" tfields with
                | Some (`String s) -> s
                | _ -> "unknown")
           in
           let tok_per_sec =
             match List.assoc_opt "tokens_per_second" tfields with
             | Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0
           in
           let latency_ms =
             match List.assoc_opt "request_latency_ms" tfields with
             | Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0
           in
           let input_tokens =
             match List.assoc_opt "input_tokens" tfields with
             | Some (`Int n) -> n | _ -> 0
           in
           let output_tokens =
             match List.assoc_opt "output_tokens" tfields with
             | Some (`Int n) -> n | _ -> 0
           in
           let cache_read_tokens =
             match List.assoc_opt "cache_read_tokens" tfields with
             | Some (`Int n) -> n | _ -> 0
           in
           let reasoning_tokens =
             match List.assoc_opt "reasoning_tokens" tfields with
             | Some (`Int n) -> n | _ -> 0
           in
           let fallback_applied =
             match List.assoc_opt "fallback_applied" tfields with
             | Some (`Bool b) -> b | _ -> false
           in
           let cost_usd =
             match List.assoc_opt "cost_usd" tfields with
             | Some (`Float f) -> f | Some (`Int n) -> Float.of_int n | _ -> 0.0
           in
           Some { model; ts_unix = ts; tok_per_sec; latency_ms;
                  input_tokens; output_tokens;
                  cache_read_tokens; reasoning_tokens; fallback_applied;
                  cost_usd; tool_call_count = outer_tool_call_count;
                  tools_used = outer_tools_used; is_error = false }
       | _ -> None)
    | _ -> None

(* ── Read decisions.jsonl files ─────────────────────────── *)

let read_all_decisions ~base_path ~since_unix : raw_entry list =
  let keeper_dir = Filename.concat base_path ".masc/keepers" in
  if not (Sys.file_exists keeper_dir) then []
  else
    let files =
      Sys.readdir keeper_dir
      |> Array.to_list
      |> List.filter (fun f -> String.length f > 16 && Filename.check_suffix f ".decisions.jsonl")
    in
    List.concat_map (fun fname ->
      let path = Filename.concat keeper_dir fname in
      try
        let ic = open_in path in
        let entries = ref [] in
        Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
          (try
             while true do
               let line = input_line ic in
               if String.length line > 2 then
                 match Yojson.Safe.from_string line with
                 | json ->
                   (match parse_telemetry_entry json ~since_unix with
                    | Some e -> entries := e :: !entries
                    | None -> ())
                 | exception (Eio.Cancel.Cancelled _ as exn) ->
                   let bt = Printexc.get_raw_backtrace () in
                   Printexc.raise_with_backtrace exn bt
                 | exception Yojson.Json_error _ -> ()
             done
           with End_of_file -> ());
          !entries
        )
      with
      | Eio.Cancel.Cancelled _ as exn ->
        let bt = Printexc.get_raw_backtrace () in
        Printexc.raise_with_backtrace exn bt
      | _ -> []
    ) files

(* ── Aggregate by model ─────────────────────────────────── *)

let aggregate_by_model (entries : raw_entry list) : model_stats list =
  let tbl : raw_entry list StringMap.t =
    List.fold_left (fun m e ->
      let prev = match StringMap.find_opt e.model m with Some l -> l | None -> [] in
      StringMap.add e.model (e :: prev) m
    ) StringMap.empty entries in
  StringMap.fold (fun model_id entries acc ->
    let n = List.length entries in
    let tok_vals = List.filter_map (fun e ->
      if e.tok_per_sec > 0.0 then Some e.tok_per_sec else None
    ) entries |> Array.of_list in
    Array.sort Float.compare tok_vals;
    let lat_vals = List.filter_map (fun e ->
      if e.latency_ms > 0.0 then Some e.latency_ms else None
    ) entries |> Array.of_list in
    Array.sort Float.compare lat_vals;
    let avg arr =
      let len = Array.length arr in
      if len = 0 then 0.0
      else Array.fold_left (+.) 0.0 arr /. Float.of_int len
    in
    let success_count = List.length (List.filter (fun e -> not e.is_error) entries) in
    let error_count = List.length (List.filter (fun e -> e.is_error) entries) in
    let total_tool_calls = List.fold_left (fun acc e -> acc + e.tool_call_count) 0 entries in
    let stats = {
      model_id;
      entry_count = n;
      avg_tok_per_sec = avg tok_vals;
      p50_tok_per_sec = percentile tok_vals 50.0;
      p95_tok_per_sec = percentile tok_vals 95.0;
      avg_latency_ms = avg lat_vals;
      p50_latency_ms = percentile lat_vals 50.0;
      p95_latency_ms = percentile lat_vals 95.0;
      total_input_tokens = List.fold_left (fun acc e -> acc + e.input_tokens) 0 entries;
      total_output_tokens = List.fold_left (fun acc e -> acc + e.output_tokens) 0 entries;
      total_cache_read_tokens = List.fold_left (fun acc e -> acc + e.cache_read_tokens) 0 entries;
      total_reasoning_tokens = List.fold_left (fun acc e -> acc + e.reasoning_tokens) 0 entries;
      fallback_count = List.length (List.filter (fun e -> e.fallback_applied) entries);
      success_count;
      error_count;
      total_cost_usd = List.fold_left (fun acc e -> acc +. e.cost_usd) 0.0 entries;
      total_tool_calls;
      avg_tool_calls_per_turn =
        if n = 0 then 0.0
        else Float.of_int total_tool_calls /. Float.of_int n;
      top_tools = (
        let tool_map : int StringMap.t =
          List.fold_left (fun m e ->
            List.fold_left (fun m t ->
              let prev = match StringMap.find_opt t m with Some c -> c | None -> 0 in
              StringMap.add t (prev + 1) m
            ) m e.tools_used
          ) StringMap.empty entries
        in
        StringMap.fold (fun tool count acc -> (tool, count) :: acc) tool_map []
        |> List.sort (fun (_, a) (_, b) -> compare b a)
        |> (fun l -> if List.length l > 10 then List.filteri (fun i _ -> i < 10) l else l));
      recent_entries =
        entries
        |> List.filter (fun e -> not e.is_error)
        |> List.sort (fun a b -> Float.compare b.ts_unix a.ts_unix)
        |> (fun l -> if List.length l > 5 then List.filteri (fun i _ -> i < 5) l else l)
        |> List.map (fun e -> {
          re_ts_unix = e.ts_unix;
          re_input_tokens = e.input_tokens;
          re_output_tokens = e.output_tokens;
          re_latency_ms = e.latency_ms;
          re_cost_usd = e.cost_usd;
          re_tools_count = e.tool_call_count;
        });
      buckets = [];
    } in
    stats :: acc
  ) tbl []
  |> List.sort (fun a b -> compare b.entry_count a.entry_count)

(* ── Time-bucketed aggregation ──────────────────────────── *)

(** Bucket entries for a single model. Returns oldest-first list of
    non-empty buckets. *)
let bucket_entries_for_model (entries : raw_entry list) ~(bucket_sec : int)
    : bucket_metric list =
  let bsec = if bucket_sec <= 0 then 60 else bucket_sec in
  let bsec_f = Float.of_int bsec in
  let tbl : (int, raw_entry list) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun e ->
    let key = int_of_float (Float.floor (e.ts_unix /. bsec_f)) in
    let prev = match Hashtbl.find_opt tbl key with Some l -> l | None -> [] in
    Hashtbl.replace tbl key (e :: prev)
  ) entries;
  Hashtbl.fold (fun key bucket_entries acc ->
    let n = List.length bucket_entries in
    let lat_vals = List.filter_map (fun e ->
      if e.latency_ms > 0.0 then Some e.latency_ms else None
    ) bucket_entries |> Array.of_list in
    Array.sort Float.compare lat_vals;
    let success_count = List.length (List.filter (fun e -> not e.is_error) bucket_entries) in
    let error_count = List.length (List.filter (fun e -> e.is_error) bucket_entries) in
    let total_cache_read = List.fold_left (fun acc e -> acc + e.cache_read_tokens) 0 bucket_entries in
    let total_input = List.fold_left (fun acc e -> acc + e.input_tokens) 0 bucket_entries in
    let denom = total_cache_read + total_input in
    let cache_hit_ratio =
      if denom = 0 then 0.0
      else Float.of_int total_cache_read /. Float.of_int denom
    in
    let error_rate =
      if n = 0 then 0.0
      else Float.of_int error_count /. Float.of_int n
    in
    let bucket = {
      b_ts_start = Float.of_int key *. bsec_f;
      b_entry_count = n;
      b_success_count = success_count;
      b_error_count = error_count;
      b_p50_latency_ms = percentile lat_vals 50.0;
      b_p95_latency_ms = percentile lat_vals 95.0;
      b_error_rate = error_rate;
      b_total_cost_usd =
        List.fold_left (fun acc e -> acc +. e.cost_usd) 0.0 bucket_entries;
      b_cache_hit_ratio = cache_hit_ratio;
    } in
    bucket :: acc
  ) tbl []
  |> List.sort (fun a b -> Float.compare a.b_ts_start b.b_ts_start)

let group_entries_by_model (entries : raw_entry list)
    : (string * raw_entry list) list =
  let tbl : (string, raw_entry list) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun e ->
    let prev = match Hashtbl.find_opt tbl e.model with Some l -> l | None -> [] in
    Hashtbl.replace tbl e.model (e :: prev)
  ) entries;
  Hashtbl.fold (fun model es acc -> (model, es) :: acc) tbl []

(* ── Public API ─────────────────────────────────────────── *)

let compute ~base_path ~window_minutes : aggregate =
  let since_unix = Time_compat.now () -. (Float.of_int window_minutes *. 60.0) in
  let entries = read_all_decisions ~base_path ~since_unix in
  let models = aggregate_by_model entries in
  let total_error_entries =
    List.length (List.filter (fun e -> e.is_error) entries)
  in
  { window_minutes; bucket_minutes = 0; models;
    total_entries = List.length entries;
    total_error_entries }

let compute_with_buckets ~base_path ~window_minutes ~bucket_minutes : aggregate =
  let bucket_minutes = max 1 bucket_minutes in
  let since_unix = Time_compat.now () -. (Float.of_int window_minutes *. 60.0) in
  let entries = read_all_decisions ~base_path ~since_unix in
  let models = aggregate_by_model entries in
  let bucket_sec = bucket_minutes * 60 in
  let by_model_tbl : (string, raw_entry list) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun (model, es) -> Hashtbl.replace by_model_tbl model es)
    (group_entries_by_model entries);
  let models_with_buckets =
    List.map (fun (s : model_stats) ->
      let model_entries =
        match Hashtbl.find_opt by_model_tbl s.model_id with
        | Some es -> es
        | None -> []
      in
      { s with buckets = bucket_entries_for_model model_entries ~bucket_sec }
    ) models
  in
  let total_error_entries =
    List.length (List.filter (fun e -> e.is_error) entries)
  in
  { window_minutes; bucket_minutes;
    models = models_with_buckets;
    total_entries = List.length entries;
    total_error_entries }

let aggregate_buckets ~base_path ~window_min ~bucket_min : model_bucketed list =
  let since_unix = Time_compat.now () -. (Float.of_int window_min *. 60.0) in
  let entries = read_all_decisions ~base_path ~since_unix in
  let bucket_sec = if bucket_min <= 0 then 60 else bucket_min * 60 in
  let by_model = group_entries_by_model entries in
  List.map (fun (model_id, es) ->
    { mb_model_id = model_id;
      mb_buckets = bucket_entries_for_model es ~bucket_sec }
  ) by_model
  |> List.sort (fun a b -> compare a.mb_model_id b.mb_model_id)

(* ── JSON serialization ─────────────────────────────────── *)

let bucket_metric_to_json (b : bucket_metric) : Yojson.Safe.t =
  `Assoc
    [ ("ts_start", `Float b.b_ts_start)
    ; ("entry_count", `Int b.b_entry_count)
    ; ("success_count", `Int b.b_success_count)
    ; ("error_count", `Int b.b_error_count)
    ; ("p50_latency_ms", `Float b.b_p50_latency_ms)
    ; ("p95_latency_ms", `Float b.b_p95_latency_ms)
    ; ("error_rate", `Float b.b_error_rate)
    ; ("total_cost_usd", `Float b.b_total_cost_usd)
    ; ("cache_hit_ratio", `Float b.b_cache_hit_ratio)
    ]

let model_stats_to_json (s : model_stats) : Yojson.Safe.t =
  `Assoc
    [ ("model_id", `String s.model_id)
    ; ("entry_count", `Int s.entry_count)
    ; ("avg_tok_per_sec", `Float s.avg_tok_per_sec)
    ; ("p50_tok_per_sec", `Float s.p50_tok_per_sec)
    ; ("p95_tok_per_sec", `Float s.p95_tok_per_sec)
    ; ("avg_latency_ms", `Float s.avg_latency_ms)
    ; ("p50_latency_ms", `Float s.p50_latency_ms)
    ; ("p95_latency_ms", `Float s.p95_latency_ms)
    ; ("total_input_tokens", `Int s.total_input_tokens)
    ; ("total_output_tokens", `Int s.total_output_tokens)
    ; ("total_cache_read_tokens", `Int s.total_cache_read_tokens)
    ; ("total_reasoning_tokens", `Int s.total_reasoning_tokens)
    ; ("fallback_count", `Int s.fallback_count)
    ; ("success_count", `Int s.success_count)
    ; ("error_count", `Int s.error_count)
    ; ("total_cost_usd", `Float s.total_cost_usd)
    ; ("avg_tool_calls_per_turn", `Float s.avg_tool_calls_per_turn)
    ; ("total_tool_calls", `Int s.total_tool_calls)
    ; ("top_tools", `List (List.map (fun (tool, count) ->
        `Assoc [("tool", `String tool); ("count", `Int count)]
      ) s.top_tools))
    ; ("recent_entries", `List (List.map (fun (r : recent_entry) ->
        `Assoc [
          ("ts_unix", `Float r.re_ts_unix);
          ("input_tokens", `Int r.re_input_tokens);
          ("output_tokens", `Int r.re_output_tokens);
          ("latency_ms", `Float r.re_latency_ms);
          ("cost_usd", `Float r.re_cost_usd);
          ("tools_count", `Int r.re_tools_count);
        ]
      ) s.recent_entries))
    ; ("buckets", `List (List.map bucket_metric_to_json s.buckets))
    ]

let to_json (agg : aggregate) : Yojson.Safe.t =
  `Assoc
    [ ("window_minutes", `Int agg.window_minutes)
    ; ("bucket_minutes", `Int agg.bucket_minutes)
    ; ("total_entries", `Int agg.total_entries)
    ; ("total_error_entries", `Int agg.total_error_entries)
    ; ("models", `List (List.map model_stats_to_json agg.models))
    ]
