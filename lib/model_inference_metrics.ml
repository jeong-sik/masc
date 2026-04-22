module StringMap = Map.Make (String)
module IntMap = Map.Make (Int)

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
  re_provider : string option;
  re_input_tokens : int option;
  re_output_tokens : int option;
  re_latency_ms : float option;
  re_prompt_tok_per_sec : float option;
  re_peak_memory_gb : float option;
  re_cost_usd : float option;
  re_tools_count : int;
}

type bucket_metric = {
  b_ts_start : float;
  b_entry_count : int;
  b_success_count : int;
  b_error_count : int;
  b_p50_latency_ms : float option;
  b_p95_latency_ms : float option;
  b_error_rate : float;
  b_total_cost_usd : float option;
  b_cache_hit_ratio : float option;
}

type model_bucketed = {
  mb_model_id : string;
  mb_buckets : bucket_metric list;
}

type model_stats = {
  model_id : string;
  provider : string option;
  entry_count : int;
  avg_tok_per_sec : float option;
  p50_tok_per_sec : float option;
  p95_tok_per_sec : float option;
  prompt_avg_tok_per_sec : float option;
  prompt_p50_tok_per_sec : float option;
  prompt_p95_tok_per_sec : float option;
  (* Hardware decode rate (eval_count / eval_duration from Ollama), separate
     from wall-clock tok_per_sec which includes queue wait + prefill + thinking.
     None when no entry in the window carried timings (e.g. providers other
     than Ollama or responses before OAS started emitting inference_timings). *)
  hw_decode_avg_tok_per_sec : float option;
  hw_decode_p50_tok_per_sec : float option;
  hw_decode_p95_tok_per_sec : float option;
  (* Peak resident memory reported by the provider for the turn. We keep the
     maximum because summing memory across turns is meaningless. *)
  max_peak_memory_gb : float option;
  (* Fraction of turns in window where the model received think=true. Reflects
     Keeper_turn_intent adaptive classifier (Cognitive=true, Mechanical=false).
     None when no entry in window reported thinking_enabled (older jsonl rows
     before the field was emitted, or providers that don't expose it). *)
  thinking_fraction : float option;
  avg_latency_ms : float option;
  p50_latency_ms : float option;
  p95_latency_ms : float option;
  total_input_tokens : int option;
  total_output_tokens : int option;
  total_cache_read_tokens : int option;
  total_reasoning_tokens : int option;
  usage_sample_count : int;
  telemetry_sample_count : int;
  fallback_count : int;
  success_count : int;
  error_count : int;
  total_cost_usd : float option;
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

let average_opt (arr : float array) =
  let len = Array.length arr in
  if len = 0 then None
  else Some (Array.fold_left (+.) 0.0 arr /. Float.of_int len)

let percentile_opt (arr : float array) p =
  if Array.length arr = 0 then None else Some (percentile arr p)

let sum_int_opt values =
  match values with
  | [] -> None
  | xs -> Some (List.fold_left ( + ) 0 xs)

let sum_float_opt values =
  match values with
  | [] -> None
  | xs -> Some (List.fold_left ( +. ) 0.0 xs)

let json_float_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (Float.of_int n)
  | _ -> None

let json_int_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Int n) -> Some n
  | _ -> None

(* ── Parse telemetry from decisions.jsonl entries ────────── *)

type raw_entry = {
  model : string;
  provider : string option;
  ts_unix : float;
  tok_per_sec : float option;
  prompt_tok_per_sec : float option;
  (* Hardware decode rate when present in telemetry; None for legacy entries
     and non-Ollama providers whose backend doesn't populate inference_timings. *)
  hw_decode_tok_per_sec : float option;
  peak_memory_gb : float option;
  (* Per-turn thinking_enabled as sent to the model (adaptive classifier output).
     None for entries that predate the field or providers that don't expose it. *)
  thinking_enabled : bool option;
  latency_ms : float option;
  input_tokens : int option;
  output_tokens : int option;
  cache_read_tokens : int option;
  reasoning_tokens : int option;
  fallback_applied : bool;
  cost_usd : float option;
  tool_call_count : int;
  tools_used : string list;
  is_error : bool;
}

let provider_opt_of_model (model : string) : string option =
  let provider = Keeper_hooks_oas.provider_of_model model in
  if String.equal provider "unknown" then None else Some provider

let provider_opt_of_fields ~(model : string) (fields : (string * Yojson.Safe.t) list)
    : string option =
  match List.assoc_opt "provider" fields with
  | Some (`String s) when String.trim s <> "" -> Some s
  | _ -> provider_opt_of_model model

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
               | Some (`String s) ->
                 (* Canonicalize so error attribution buckets match the
                    SSOT profile names instead of drift/ghost values. *)
                 Keeper_cascade_profile.canonicalize s ^ " (cascade)"
               | _ -> "__error__"
           in
           let provider = provider_opt_of_fields ~model tfields in
           Some { model; ts_unix = ts; tok_per_sec = None;
                  provider;
                  prompt_tok_per_sec = None;
                  hw_decode_tok_per_sec = None;
                  peak_memory_gb = None;
                  thinking_enabled = None;
                  latency_ms = None;
                  input_tokens = None; output_tokens = None;
                  cache_read_tokens = None; reasoning_tokens = None;
                  fallback_applied = false; cost_usd = None;
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
           let provider = provider_opt_of_fields ~model tfields in
           let tok_per_sec = json_float_field_opt "tokens_per_second" tfields in
           let prompt_tok_per_sec =
             match List.assoc_opt "prompt_per_second" tfields with
             | Some (`Float f) when f > 0.0 -> Some f
             | Some (`Int n) when n > 0 -> Some (Float.of_int n)
             | _ -> None
           in
           (* hw_decode_tokens_per_second — preferred field; fall back to
              provider_tokens_per_second for backward compat. Treat explicit
              null as absent so backfill for older rows is clean. *)
           let hw_decode_tok_per_sec =
             let read key =
               match List.assoc_opt key tfields with
               | Some (`Float f) when f > 0.0 -> Some f
               | Some (`Int n) when n > 0 -> Some (Float.of_int n)
               | _ -> None
             in
             match read "hw_decode_tokens_per_second" with
             | Some _ as v -> v
             | None -> read "provider_tokens_per_second"
           in
           let peak_memory_gb =
             let read key =
               match List.assoc_opt key tfields with
               | Some (`Float f) when f > 0.0 -> Some f
               | Some (`Int n) when n > 0 -> Some (Float.of_int n)
               | _ -> None
             in
             match read "peak_memory_gb" with
             | Some _ as v -> v
             | None -> read "peak_memory"
           in
           let latency_ms = json_float_field_opt "request_latency_ms" tfields in
           let input_tokens = json_int_field_opt "input_tokens" tfields in
           let output_tokens = json_int_field_opt "output_tokens" tfields in
           let cache_read_tokens = json_int_field_opt "cache_read_tokens" tfields in
           let reasoning_tokens = json_int_field_opt "reasoning_tokens" tfields in
           let fallback_applied =
             match List.assoc_opt "fallback_applied" tfields with
             | Some (`Bool b) -> b | _ -> false
           in
           let cost_usd = json_float_field_opt "cost_usd" tfields in
           (* Per-turn thinking_enabled — emitted by keeper_unified_turn's
              append_decision_record under telemetry.thinking_enabled. Treat
              explicit null or absent as None so backfill stays clean. *)
           let thinking_enabled =
             match List.assoc_opt "thinking_enabled" tfields with
             | Some (`Bool b) -> Some b
             | _ -> None
           in
           Some { model; ts_unix = ts; tok_per_sec;
                  provider;
                  prompt_tok_per_sec;
                  hw_decode_tok_per_sec;
                  peak_memory_gb;
                  thinking_enabled;
                  latency_ms;
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
    let tok_vals = List.filter_map (fun e -> e.tok_per_sec) entries |> Array.of_list in
    Array.sort Float.compare tok_vals;
    let prompt_vals =
      List.filter_map (fun e -> e.prompt_tok_per_sec) entries
      |> Array.of_list
    in
    Array.sort Float.compare prompt_vals;
    let hw_vals = List.filter_map (fun e -> e.hw_decode_tok_per_sec) entries
                  |> Array.of_list in
    Array.sort Float.compare hw_vals;
    let peak_vals =
      List.filter_map (fun e -> e.peak_memory_gb) entries
      |> Array.of_list
    in
    Array.sort Float.compare peak_vals;
    let lat_vals = List.filter_map (fun e -> e.latency_ms) entries |> Array.of_list in
    Array.sort Float.compare lat_vals;
    let success_count = List.length (List.filter (fun e -> not e.is_error) entries) in
    let error_count = List.length (List.filter (fun e -> e.is_error) entries) in
    let total_tool_calls = List.fold_left (fun acc e -> acc + e.tool_call_count) 0 entries in
    let usage_sample_count =
      List.fold_left
        (fun acc e ->
          if e.input_tokens <> None
             || e.output_tokens <> None
             || e.cache_read_tokens <> None
             || e.reasoning_tokens <> None
             || e.cost_usd <> None
          then acc + 1
          else acc)
        0 entries
    in
    let telemetry_sample_count =
      List.fold_left
        (fun acc e ->
          if e.tok_per_sec <> None
             || e.prompt_tok_per_sec <> None
             || e.hw_decode_tok_per_sec <> None
             || e.peak_memory_gb <> None
             || e.latency_ms <> None
          then acc + 1
          else acc)
        0 entries
    in
    (* thinking_fraction: count of entries with thinking_enabled=true over
       entries that reported the field. Entries without the field (older jsonl
       rows, providers that don't expose it) are excluded from denominator —
       None when no reporter at all. *)
    let thinking_fraction =
      let reported = List.filter_map (fun e -> e.thinking_enabled) entries in
      match reported with
      | [] -> None
      | xs ->
        let total = List.length xs in
        let on_count = List.length (List.filter (fun x -> x) xs) in
        Some (float_of_int on_count /. float_of_int total)
    in
    let provider =
      match List.find_map (fun e -> e.provider) entries with
      | Some _ as p -> p
      | None -> provider_opt_of_model model_id
    in
    let stats = {
      model_id;
      provider;
      entry_count = n;
      avg_tok_per_sec = average_opt tok_vals;
      p50_tok_per_sec = percentile_opt tok_vals 50.0;
      p95_tok_per_sec = percentile_opt tok_vals 95.0;
      prompt_avg_tok_per_sec = average_opt prompt_vals;
      prompt_p50_tok_per_sec = percentile_opt prompt_vals 50.0;
      prompt_p95_tok_per_sec = percentile_opt prompt_vals 95.0;
      hw_decode_avg_tok_per_sec = average_opt hw_vals;
      hw_decode_p50_tok_per_sec = percentile_opt hw_vals 50.0;
      hw_decode_p95_tok_per_sec = percentile_opt hw_vals 95.0;
      max_peak_memory_gb =
        if Array.length peak_vals = 0 then None
        else Some peak_vals.(Array.length peak_vals - 1);
      thinking_fraction;
      avg_latency_ms = average_opt lat_vals;
      p50_latency_ms = percentile_opt lat_vals 50.0;
      p95_latency_ms = percentile_opt lat_vals 95.0;
      total_input_tokens = sum_int_opt (List.filter_map (fun e -> e.input_tokens) entries);
      total_output_tokens = sum_int_opt (List.filter_map (fun e -> e.output_tokens) entries);
      total_cache_read_tokens =
        sum_int_opt (List.filter_map (fun e -> e.cache_read_tokens) entries);
      total_reasoning_tokens =
        sum_int_opt (List.filter_map (fun e -> e.reasoning_tokens) entries);
      usage_sample_count;
      telemetry_sample_count;
      fallback_count = List.length (List.filter (fun e -> e.fallback_applied) entries);
      success_count;
      error_count;
      total_cost_usd = sum_float_opt (List.filter_map (fun e -> e.cost_usd) entries);
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
          re_provider = e.provider;
          re_input_tokens = e.input_tokens;
          re_output_tokens = e.output_tokens;
          re_latency_ms = e.latency_ms;
          re_prompt_tok_per_sec = e.prompt_tok_per_sec;
          re_peak_memory_gb = e.peak_memory_gb;
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
  let tbl : raw_entry list IntMap.t =
    List.fold_left (fun m e ->
      let key = int_of_float (Float.floor (e.ts_unix /. bsec_f)) in
      let prev = match IntMap.find_opt key m with Some l -> l | None -> [] in
      IntMap.add key (e :: prev) m
    ) IntMap.empty entries in
  IntMap.fold (fun key bucket_entries acc ->
    let n = List.length bucket_entries in
    let lat_vals = List.filter_map (fun e -> e.latency_ms) bucket_entries |> Array.of_list in
    Array.sort Float.compare lat_vals;
    let success_count = List.length (List.filter (fun e -> not e.is_error) bucket_entries) in
    let error_count = List.length (List.filter (fun e -> e.is_error) bucket_entries) in
    let cache_reads = List.filter_map (fun e -> e.cache_read_tokens) bucket_entries in
    let inputs = List.filter_map (fun e -> e.input_tokens) bucket_entries in
    let cache_hit_ratio =
      match sum_int_opt cache_reads, sum_int_opt inputs with
      | None, None -> None
      | total_cache_read, total_input ->
          let total_cache_read = Option.value ~default:0 total_cache_read in
          let total_input = Option.value ~default:0 total_input in
          let denom = total_cache_read + total_input in
          if denom = 0 then Some 0.0
          else Some (Float.of_int total_cache_read /. Float.of_int denom)
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
      b_p50_latency_ms = percentile_opt lat_vals 50.0;
      b_p95_latency_ms = percentile_opt lat_vals 95.0;
      b_error_rate = error_rate;
      b_total_cost_usd =
        sum_float_opt (List.filter_map (fun e -> e.cost_usd) bucket_entries);
      b_cache_hit_ratio = cache_hit_ratio;
    } in
    bucket :: acc
  ) tbl []
  |> List.sort (fun a b -> Float.compare a.b_ts_start b.b_ts_start)

let group_entries_by_model (entries : raw_entry list)
    : (string * raw_entry list) list =
  let tbl : raw_entry list StringMap.t =
    List.fold_left (fun m e ->
      let prev = match StringMap.find_opt e.model m with Some l -> l | None -> [] in
      StringMap.add e.model (e :: prev) m
    ) StringMap.empty entries
  in
  StringMap.fold (fun model es acc -> (model, es) :: acc) tbl []

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
  let by_model_map : raw_entry list StringMap.t =
    List.fold_left (fun acc (model, es) -> StringMap.add model es acc)
      StringMap.empty (group_entries_by_model entries)
  in
  let models_with_buckets =
    List.map (fun (s : model_stats) ->
      let model_entries =
        match StringMap.find_opt s.model_id by_model_map with
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
  let opt_float = function Some f -> `Float f | None -> `Null in
  `Assoc
    [ ("ts_start", `Float b.b_ts_start)
    ; ("entry_count", `Int b.b_entry_count)
    ; ("success_count", `Int b.b_success_count)
    ; ("error_count", `Int b.b_error_count)
    ; ("p50_latency_ms", opt_float b.b_p50_latency_ms)
    ; ("p95_latency_ms", opt_float b.b_p95_latency_ms)
    ; ("error_rate", `Float b.b_error_rate)
    ; ("total_cost_usd", opt_float b.b_total_cost_usd)
    ; ("cache_hit_ratio", opt_float b.b_cache_hit_ratio)
    ]

let model_stats_to_json (s : model_stats) : Yojson.Safe.t =
  let opt_float = function Some f -> `Float f | None -> `Null in
  let opt_int = function Some n -> `Int n | None -> `Null in
  let opt_string = function Some s -> `String s | None -> `Null in
  `Assoc
    [ ("model_id", `String s.model_id)
    ; ("provider", opt_string s.provider)
    ; ("entry_count", `Int s.entry_count)
    ; ("avg_tok_per_sec", opt_float s.avg_tok_per_sec)
    ; ("p50_tok_per_sec", opt_float s.p50_tok_per_sec)
    ; ("p95_tok_per_sec", opt_float s.p95_tok_per_sec)
    ; ("prompt_avg_tok_per_sec", opt_float s.prompt_avg_tok_per_sec)
    ; ("prompt_p50_tok_per_sec", opt_float s.prompt_p50_tok_per_sec)
    ; ("prompt_p95_tok_per_sec", opt_float s.prompt_p95_tok_per_sec)
    ; ("hw_decode_avg_tok_per_sec", opt_float s.hw_decode_avg_tok_per_sec)
    ; ("hw_decode_p50_tok_per_sec", opt_float s.hw_decode_p50_tok_per_sec)
    ; ("hw_decode_p95_tok_per_sec", opt_float s.hw_decode_p95_tok_per_sec)
    ; ("max_peak_memory_gb", opt_float s.max_peak_memory_gb)
    ; ("thinking_fraction", opt_float s.thinking_fraction)
    ; ("avg_latency_ms", opt_float s.avg_latency_ms)
    ; ("p50_latency_ms", opt_float s.p50_latency_ms)
    ; ("p95_latency_ms", opt_float s.p95_latency_ms)
    ; ("total_input_tokens", opt_int s.total_input_tokens)
    ; ("total_output_tokens", opt_int s.total_output_tokens)
    ; ("total_cache_read_tokens", opt_int s.total_cache_read_tokens)
    ; ("total_reasoning_tokens", opt_int s.total_reasoning_tokens)
    ; ("usage_sample_count", `Int s.usage_sample_count)
    ; ("telemetry_sample_count", `Int s.telemetry_sample_count)
    ; ("fallback_count", `Int s.fallback_count)
    ; ("success_count", `Int s.success_count)
    ; ("error_count", `Int s.error_count)
    ; ("total_cost_usd", opt_float s.total_cost_usd)
    ; ("avg_tool_calls_per_turn", `Float s.avg_tool_calls_per_turn)
    ; ("total_tool_calls", `Int s.total_tool_calls)
    ; ("top_tools", `List (List.map (fun (tool, count) ->
        `Assoc [("tool", `String tool); ("count", `Int count)]
      ) s.top_tools))
    ; ("recent_entries", `List (List.map (fun (r : recent_entry) ->
        `Assoc [
          ("ts_unix", `Float r.re_ts_unix);
          ("provider", opt_string r.re_provider);
          ("input_tokens", opt_int r.re_input_tokens);
          ("output_tokens", opt_int r.re_output_tokens);
          ("latency_ms", opt_float r.re_latency_ms);
          ("prompt_tok_per_sec", opt_float r.re_prompt_tok_per_sec);
          ("peak_memory_gb", opt_float r.re_peak_memory_gb);
          ("cost_usd", opt_float r.re_cost_usd);
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
