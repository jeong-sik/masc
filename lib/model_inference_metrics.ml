(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper decisions.jsonl files, extracts telemetry entries within
    a configurable time window, and computes per-model aggregates:
    avg/p50/p95 tok/s, avg/p50/p95 latency, total reasoning tokens,
    cost attribution, tool usage, and success/error rates.

    Closes #5775. @since 2.259.0
    Extended with cost/tool/error metrics: @since 2.270.0 *)

(* ── Types ──────────────────────────────────────────────── *)

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
}

type aggregate = {
  window_minutes : int;
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
  tok_per_sec : float;
  latency_ms : float;
  input_tokens : int;
  output_tokens : int;
  cache_read_tokens : int;
  reasoning_tokens : int;
  fallback_applied : bool;
  cost_usd : float;
  tool_call_count : int;
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
           Some { model; tok_per_sec = 0.0; latency_ms = 0.0;
                  input_tokens = 0; output_tokens = 0;
                  cache_read_tokens = 0; reasoning_tokens = 0;
                  fallback_applied = false; cost_usd = 0.0;
                  tool_call_count = outer_tool_call_count;
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
           Some { model; tok_per_sec; latency_ms; input_tokens; output_tokens;
                  cache_read_tokens; reasoning_tokens; fallback_applied;
                  cost_usd; tool_call_count = outer_tool_call_count;
                  is_error = false }
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
  let tbl : (string, raw_entry list) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun e ->
    let prev = match Hashtbl.find_opt tbl e.model with Some l -> l | None -> [] in
    Hashtbl.replace tbl e.model (e :: prev)
  ) entries;
  Hashtbl.fold (fun model_id entries acc ->
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
    } in
    stats :: acc
  ) tbl []
  |> List.sort (fun a b -> compare b.entry_count a.entry_count)

(* ── Public API ─────────────────────────────────────────── *)

let compute ~base_path ~window_minutes : aggregate =
  let since_unix = Time_compat.now () -. (Float.of_int window_minutes *. 60.0) in
  let entries = read_all_decisions ~base_path ~since_unix in
  let models = aggregate_by_model entries in
  let total_error_entries =
    List.length (List.filter (fun e -> e.is_error) entries)
  in
  { window_minutes; models; total_entries = List.length entries;
    total_error_entries }

(* ── JSON serialization ─────────────────────────────────── *)

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
    ]

let to_json (agg : aggregate) : Yojson.Safe.t =
  `Assoc
    [ ("window_minutes", `Int agg.window_minutes)
    ; ("total_entries", `Int agg.total_entries)
    ; ("total_error_entries", `Int agg.total_error_entries)
    ; ("models", `List (List.map model_stats_to_json agg.models))
    ]
