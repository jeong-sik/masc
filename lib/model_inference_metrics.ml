module StringMap = Map.Make (String)
module IntMap = Map.Make (Int)

(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper decisions.jsonl files plus inference-level costs.jsonl
    samples, extracts telemetry entries within a configurable time window,
    and computes per-model aggregates:
    avg/p50/p95 tok/s, avg/p50/p95 latency, total reasoning tokens,
    cost attribution, tool usage, and success/error rates.

    Closes #5775. @since 2.259.0
    Extended with cost/tool/error metrics: @since 2.270.0 *)

(* ── Types ──────────────────────────────────────────────── *)

type recent_entry =
  { re_ts_unix : float
  ; re_provider : string option
  ; re_outcome : string
  ; re_stop_reason : string option
  ; re_turn_lane : string option
  ; re_input_tokens : int option
  ; re_output_tokens : int option
  ; re_latency_ms : float option
  ; re_prompt_tok_per_sec : float option
  ; re_peak_memory_gb : float option
  ; re_cost_usd : float option
  ; re_tools_count : int
  ; re_usage_reported : bool option
  ; re_telemetry_reported : bool option
  ; re_usage_trust : string option
  ; re_usage_anomaly_reasons : string list
  ; re_coverage_reason : string option
  ; re_coverage_stage : string option
  }

type coverage_reason_count =
  { crc_reason : string
  ; crc_count : int
  }

type bucket_metric =
  { b_ts_start : float
  ; b_entry_count : int
  ; b_success_count : int
  ; b_error_count : int
  ; b_p50_latency_ms : float option
  ; b_p95_latency_ms : float option
  ; b_error_rate : float
  ; b_total_cost_usd : float option
  ; b_cache_hit_ratio : float option
  }

type model_bucketed =
  { mb_model_id : string
  ; mb_buckets : bucket_metric list
  }

type model_stats =
  { model_id : string
  ; provider : string option
  ; entry_count : int
  ; avg_tok_per_sec : float option
  ; p50_tok_per_sec : float option
  ; p95_tok_per_sec : float option
  ; prompt_avg_tok_per_sec : float option
  ; prompt_p50_tok_per_sec : float option
  ; prompt_p95_tok_per_sec : float option
  ; (* Hardware decode rate (eval_count / eval_duration from Ollama), separate
     from wall-clock tok_per_sec which includes queue wait + prefill + thinking.
     None when no entry in the window carried timings (e.g. providers other
     than Ollama or responses before OAS started emitting inference_timings). *)
    hw_decode_avg_tok_per_sec : float option
  ; hw_decode_p50_tok_per_sec : float option
  ; hw_decode_p95_tok_per_sec : float option
  ; (* Peak resident memory reported by the provider for the turn. We keep the
     maximum because summing memory across turns is meaningless. *)
    max_peak_memory_gb : float option
  ; (* Fraction of turns in window where the model received think=true. Reflects
     Keeper_turn_intent adaptive classifier (Cognitive=true, Mechanical=false).
     None when no entry in window reported thinking_enabled (older jsonl rows
     before the field was emitted, or providers that don't expose it). *)
    thinking_fraction : float option
  ; avg_latency_ms : float option
  ; p50_latency_ms : float option
  ; p95_latency_ms : float option
  ; total_input_tokens : int option
  ; total_output_tokens : int option
  ; total_cache_read_tokens : int option
  ; total_reasoning_tokens : int option
  ; usage_sample_count : int
  ; telemetry_sample_count : int
  ; usage_missing_count : int
  ; telemetry_missing_count : int
  ; coverage_status : string
  ; primary_coverage_stage : string option
  ; primary_coverage_reason : string option
  ; coverage_reason_counts : coverage_reason_count list
  ; fallback_count : int
  ; success_count : int
  ; error_count : int
  ; total_cost_usd : float option
  ; avg_tool_calls_per_turn : float
  ; total_tool_calls : int
  ; top_tools : (string * int) list
  ; recent_entries : recent_entry list
  ; buckets : bucket_metric list
  }

type aggregate =
  { window_minutes : int
  ; bucket_minutes : int
  ; models : model_stats list
  ; total_entries : int
  ; total_error_entries : int
  }

(* ── Percentile ───────────────────────���─────────────────── *)

let percentile (sorted : float array) (p : float) : float =
  let n = Array.length sorted in
  if n = 0
  then 0.0
  else (
    let rank = p /. 100.0 *. Float.of_int (n - 1) in
    let lo = int_of_float (floor rank) in
    let hi = min (lo + 1) (n - 1) in
    let frac = rank -. Float.of_int lo in
    (sorted.(lo) *. (1.0 -. frac)) +. (sorted.(hi) *. frac))
;;

let average_opt (arr : float array) =
  let len = Array.length arr in
  if len = 0 then None else Some (Array.fold_left ( +. ) 0.0 arr /. Float.of_int len)
;;

let percentile_opt (arr : float array) p =
  if Array.length arr = 0 then None else Some (percentile arr p)
;;

(* Single-pass [List.length (List.filter pred xs)] equivalent — drops
   the intermediate list allocation. Hot in per-window aggregation
   loops below where [entries] reaches thousands. *)
let count_if pred xs = List.fold_left (fun n x -> if pred x then n + 1 else n) 0 xs

(* O(min(n, length xs)) prefix take.  Replaces the
   [if List.length xs > n then List.filteri (fun i _ -> i < n) xs else xs]
   pattern: that walks the list twice (length, then filter) and allocates
   the full filtered list.  This walks once and stops at [n]. *)
let rec take n = function
  | _ when n <= 0 -> []
  | [] -> []
  | x :: xs -> x :: take (n - 1) xs
;;

let sum_int_opt values =
  match values with
  | [] -> None
  | xs -> Some (List.fold_left ( + ) 0 xs)
;;

let sum_float_opt values =
  match values with
  | [] -> None
  | xs -> Some (List.fold_left ( +. ) 0.0 xs)
;;

let json_float_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (Float.of_int n)
  | _ -> None
;;

let json_int_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Int n) -> Some n
  | _ -> None
;;

let json_bool_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Bool b) -> Some b
  | _ -> None
;;

let json_string_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`String s) ->
    let trimmed = String.trim s in
    if trimmed = "" then None else Some trimmed
  | _ -> None
;;

let json_string_list_field key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`List xs) ->
    List.filter_map
      (function
        | `String s ->
          let trimmed = String.trim s in
          if trimmed = "" then None else Some trimmed
        | _ -> None)
      xs
  | _ -> []
;;

let usage_absurd_token_threshold = 1_000_000

let infer_usage_trust_from_fields
      fields
      ~(usage_reported : bool)
      ~(model : string)
      ~(input_tokens : int option)
      ~(output_tokens : int option)
  : string option * string list
  =
  let emitted_reasons = json_string_list_field "usage_anomaly_reasons" fields in
  match json_string_field_opt "usage_trust" fields with
  | Some trust -> Some trust, emitted_reasons
  | None ->
    if not usage_reported
    then Some "missing", []
    else (
      let reasons = ref [] in
      let add reason =
        if not (List.mem reason !reasons) then reasons := reason :: !reasons
      in
      let model = String.trim model in
      if model = "" || String.equal model "unknown" then add "missing_model_id";
      (match input_tokens with
       | Some n when n < 0 -> add "negative_input_tokens"
       | Some n when n > usage_absurd_token_threshold -> add "input_tokens_gt_1m"
       | _ -> ());
      (match output_tokens with
       | Some n when n < 0 -> add "negative_output_tokens"
       | Some n when n > usage_absurd_token_threshold -> add "output_tokens_gt_1m"
       | _ -> ());
      (match input_tokens, output_tokens with
       | Some 0, Some 0 -> add "zero_token_usage_reported"
       | _ -> ());
      match List.rev !reasons with
      | [] -> Some "trusted", []
      | reasons -> Some "untrusted", reasons)
;;

let usage_trust_untrusted = function
  | Some "untrusted" -> true
  | _ -> false
;;

(* ── Parse telemetry from decisions.jsonl entries ────────── *)

type raw_entry =
  { model : string
  ; provider : string option
  ; ts_unix : float
  ; outcome : string
  ; stop_reason : string option
  ; turn_lane : string option
  ; tok_per_sec : float option
  ; prompt_tok_per_sec : float option
  ; (* Hardware decode rate when present in telemetry; None for legacy entries
     and non-Ollama providers whose backend doesn't populate inference_timings. *)
    hw_decode_tok_per_sec : float option
  ; peak_memory_gb : float option
  ; (* Per-turn thinking_enabled as sent to the model (adaptive classifier output).
     None for entries that predate the field or providers that don't expose it. *)
    thinking_enabled : bool option
  ; latency_ms : float option
  ; input_tokens : int option
  ; output_tokens : int option
  ; cache_read_tokens : int option
  ; reasoning_tokens : int option
  ; fallback_applied : bool
  ; cost_usd : float option
  ; tool_call_count : int
  ; tools_used : string list
  ; usage_reported : bool option
  ; telemetry_reported : bool option
  ; usage_trust : string option
  ; usage_anomaly_reasons : string list
  ; coverage_reason : string option
  ; coverage_stage : string option
  ; is_error : bool
  }

let provider_opt_of_model (model : string) : string option =
  let provider = Keeper_hooks_oas.provider_of_model model in
  if String.equal provider "unknown" then None else Some provider
;;

let provider_kind_opt_of_fields (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt "provider_kind" fields with
  | Some (`String s) -> Llm_provider.Provider_config.provider_kind_of_string s
  | _ -> None
;;

let provider_opt_of_fields ~(model : string) (fields : (string * Yojson.Safe.t) list)
  : string option
  =
  match List.assoc_opt "provider" fields with
  | Some (`String s) when String.trim s <> "" -> Some s
  | _ ->
    let provider_kind = provider_kind_opt_of_fields fields in
    let provider = Keeper_hooks_oas.provider_of_model ?provider_kind model in
    if String.equal provider "unknown" then None else Some provider
;;

let parse_telemetry_entry (json : Yojson.Safe.t) ~since_unix : raw_entry option =
  let ts = Safe_ops.json_float_opt "ts_unix" json |> Option.value ~default:0.0 in
  if ts < since_unix
  then None
  else (
    match json with
    | `Assoc fields ->
      (* Read outer record fields available for both success and error turns *)
      let outer_tool_call_count =
        match List.assoc_opt "tool_call_count" fields with
        | Some (`Int n) -> n
        | _ -> 0
      in
      let outer_tools_used =
        match List.assoc_opt "tools_used" fields with
        | Some (`List xs) ->
          List.filter_map
            (function
              | `String s when String.length s > 0 -> Some s
              | _ -> None)
            xs
        | _ -> []
      in
      (match List.assoc_opt "telemetry" fields with
       | Some (`Assoc tfields) ->
         (* Check if this is an error turn (telemetry.outcome = "error") *)
         let is_error =
           match List.assoc_opt "outcome" tfields with
           | Some (`String "error") -> true
           | _ -> false
         in
         if is_error
         then (
           (* Error turns: use first candidate model or cascade_name for attribution *)
           let model =
             match List.assoc_opt "candidate_models" tfields with
             | Some (`List (`String m :: _)) -> m
             | _ ->
               (match List.assoc_opt "cascade_name" tfields with
                | Some (`String s) ->
                  (* Canonicalize so error attribution buckets match the
                    SSOT profile names instead of drift/ghost values. *)
                  Keeper_cascade_profile.canonicalize s ^ " (cascade)"
                | _ -> "__error__")
           in
           let provider = provider_opt_of_fields ~model tfields in
           Some
             { model
             ; ts_unix = ts
             ; outcome = "error"
             ; stop_reason = json_string_field_opt "stop_reason" tfields
             ; turn_lane = json_string_field_opt "turn_lane" tfields
             ; tok_per_sec = None
             ; provider
             ; prompt_tok_per_sec = None
             ; hw_decode_tok_per_sec = None
             ; peak_memory_gb = None
             ; thinking_enabled = None
             ; latency_ms = None
             ; input_tokens = None
             ; output_tokens = None
             ; cache_read_tokens = None
             ; reasoning_tokens = None
             ; fallback_applied = false
             ; cost_usd = None
             ; tool_call_count = outer_tool_call_count
             ; tools_used = outer_tools_used
             ; usage_reported = json_bool_field_opt "usage_reported" tfields
             ; telemetry_reported = json_bool_field_opt "telemetry_reported" tfields
             ; usage_trust = json_string_field_opt "usage_trust" tfields
             ; usage_anomaly_reasons =
                 json_string_list_field "usage_anomaly_reasons" tfields
             ; coverage_reason = json_string_field_opt "coverage_reason" tfields
             ; coverage_stage = json_string_field_opt "coverage_stage" tfields
             ; is_error = true
             })
         else (
           (* Success turns: full telemetry parsing *)
           let model =
             match List.assoc_opt "selected_model" tfields with
             | Some (`String s) -> s
             | _ ->
               (match List.assoc_opt "model_used" tfields with
                | Some (`String s) -> s
                | _ -> "unknown")
           in
           let provider = provider_opt_of_fields ~model tfields in
           let tok_per_sec_raw = json_float_field_opt "tokens_per_second" tfields in
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
           let input_tokens_raw = json_int_field_opt "input_tokens" tfields in
           let output_tokens_raw = json_int_field_opt "output_tokens" tfields in
           let cache_read_tokens_raw = json_int_field_opt "cache_read_tokens" tfields in
           let reasoning_tokens_raw = json_int_field_opt "reasoning_tokens" tfields in
           let fallback_applied =
             match List.assoc_opt "fallback_applied" tfields with
             | Some (`Bool b) -> b
             | _ -> false
           in
           let cost_usd_raw = json_float_field_opt "cost_usd" tfields in
           (* Per-turn thinking_enabled — emitted by keeper_unified_turn's
              append_decision_record under telemetry.thinking_enabled. Treat
              explicit null or absent as None so backfill stays clean. *)
           let thinking_enabled =
             match List.assoc_opt "thinking_enabled" tfields with
             | Some (`Bool b) -> Some b
             | _ -> None
           in
           let usage_reported =
             match json_bool_field_opt "usage_reported" tfields with
             | Some _ as value -> value
             | None ->
               if
                 input_tokens_raw <> None
                 || output_tokens_raw <> None
                 || cache_read_tokens_raw <> None
                 || reasoning_tokens_raw <> None
                 || cost_usd_raw <> None
               then Some true
               else None
           in
           let usage_trust, usage_anomaly_reasons =
             infer_usage_trust_from_fields
               tfields
               ~usage_reported:(Option.value ~default:false usage_reported)
               ~model
               ~input_tokens:input_tokens_raw
               ~output_tokens:output_tokens_raw
           in
           let usage_untrusted = usage_trust_untrusted usage_trust in
           let tok_per_sec = if usage_untrusted then None else tok_per_sec_raw in
           let input_tokens = if usage_untrusted then None else input_tokens_raw in
           let output_tokens = if usage_untrusted then None else output_tokens_raw in
           let cache_read_tokens =
             if usage_untrusted then None else cache_read_tokens_raw
           in
           let reasoning_tokens =
             if usage_untrusted then None else reasoning_tokens_raw
           in
           let cost_usd = if usage_untrusted then None else cost_usd_raw in
           let telemetry_reported =
             match json_bool_field_opt "telemetry_reported" tfields with
             | Some _ as value -> value
             | None ->
               if
                 tok_per_sec_raw <> None
                 || prompt_tok_per_sec <> None
                 || hw_decode_tok_per_sec <> None
                 || peak_memory_gb <> None
                 || latency_ms <> None
               then Some true
               else None
           in
           Some
             { model
             ; ts_unix = ts
             ; outcome =
                 Option.value ~default:"success" (json_string_field_opt "outcome" tfields)
             ; stop_reason = json_string_field_opt "stop_reason" tfields
             ; turn_lane = json_string_field_opt "turn_lane" tfields
             ; tok_per_sec
             ; provider
             ; prompt_tok_per_sec
             ; hw_decode_tok_per_sec
             ; peak_memory_gb
             ; thinking_enabled
             ; latency_ms
             ; input_tokens
             ; output_tokens
             ; cache_read_tokens
             ; reasoning_tokens
             ; fallback_applied
             ; cost_usd
             ; tool_call_count = outer_tool_call_count
             ; tools_used = outer_tools_used
             ; usage_reported
             ; telemetry_reported
             ; usage_trust
             ; usage_anomaly_reasons
             ; coverage_reason = json_string_field_opt "coverage_reason" tfields
             ; coverage_stage =
                 (if usage_untrusted
                  then (
                    match json_string_field_opt "coverage_stage" tfields with
                    | Some _ as stage -> stage
                    | None -> Some "keeper")
                  else json_string_field_opt "coverage_stage" tfields)
             ; is_error = false
             })
       | _ -> None)
    | _ -> None)
;;

let read_hw_decode_tok_per_sec (fields : (string * Yojson.Safe.t) list) =
  let read key =
    match List.assoc_opt key fields with
    | Some (`Float f) when f > 0.0 -> Some f
    | Some (`Int n) when n > 0 -> Some (Float.of_int n)
    | _ -> None
  in
  match read "hw_decode_tokens_per_second" with
  | Some _ as v -> v
  | None -> read "provider_tokens_per_second"
;;

let starts_with ~prefix s = String.starts_with ~prefix s

let canonical_cost_model_id ~(provider : string option) model =
  match provider with
  | Some "ollama" when not (starts_with ~prefix:"ollama:" model) -> "ollama:" ^ model
  | _ -> model
;;

let parse_cost_entry (json : Yojson.Safe.t) ~since_unix : raw_entry option =
  match json with
  | `Assoc fields ->
    let ts =
      match Safe_ops.json_float_opt "ts_unix" json with
      | Some v -> Some v
      | None ->
        (match List.assoc_opt "timestamp" fields with
         | Some (`String s) -> Types.parse_iso8601_opt s
         | _ -> None)
    in
    (match ts with
     | Some ts when ts >= since_unix ->
       let raw_model =
         json_string_field_opt "model" fields |> Option.value ~default:"unknown"
       in
       let provider = provider_opt_of_fields ~model:raw_model fields in
       let model = canonical_cost_model_id ~provider raw_model in
       let usage_missing =
         json_bool_field_opt "usage_missing" fields |> Option.value ~default:false
       in
       let usage_reported = not usage_missing in
       let input_tokens_raw =
         if usage_missing then None else json_int_field_opt "input_tokens" fields
       in
       let output_tokens_raw =
         if usage_missing then None else json_int_field_opt "output_tokens" fields
       in
       let cache_read_tokens_raw =
         match json_int_field_opt "cache_read_tokens" fields with
         | Some _ as v -> v
         | None -> json_int_field_opt "cache_read_input_tokens" fields
       in
       let usage_trust, usage_anomaly_reasons =
         infer_usage_trust_from_fields
           fields
           ~usage_reported
           ~model
           ~input_tokens:input_tokens_raw
           ~output_tokens:output_tokens_raw
       in
       let usage_untrusted = usage_trust_untrusted usage_trust in
       let latency_ms = json_float_field_opt "request_latency_ms" fields in
       let tok_per_sec_raw =
         match json_float_field_opt "tokens_per_second" fields with
         | Some v when v > 0.0 -> Some v
         | _ ->
           (match output_tokens_raw, latency_ms with
            | Some out, Some latency when out > 0 && latency > 0.0 ->
              Some (Float.of_int out /. (latency /. 1000.0))
            | _ -> None)
       in
       let tok_per_sec = if usage_untrusted then None else tok_per_sec_raw in
       let input_tokens = if usage_untrusted then None else input_tokens_raw in
       let output_tokens = if usage_untrusted then None else output_tokens_raw in
       let cache_read_tokens = if usage_untrusted then None else cache_read_tokens_raw in
       let prompt_tok_per_sec =
         match List.assoc_opt "prompt_per_second" fields with
         | Some (`Float f) when f > 0.0 -> Some f
         | Some (`Int n) when n > 0 -> Some (Float.of_int n)
         | _ -> None
       in
       let hw_decode_tok_per_sec = read_hw_decode_tok_per_sec fields in
       let peak_memory_gb =
         match json_float_field_opt "peak_memory_gb" fields with
         | Some v when v > 0.0 -> Some v
         | _ -> None
       in
       let telemetry_reported =
         tok_per_sec_raw <> None
         || prompt_tok_per_sec <> None
         || hw_decode_tok_per_sec <> None
         || peak_memory_gb <> None
         || latency_ms <> None
       in
       Some
         { model
         ; ts_unix = ts
         ; outcome = "success"
         ; stop_reason = None
         ; turn_lane = None
         ; tok_per_sec
         ; provider
         ; prompt_tok_per_sec
         ; hw_decode_tok_per_sec
         ; peak_memory_gb
         ; thinking_enabled = None
         ; latency_ms
         ; input_tokens
         ; output_tokens
         ; cache_read_tokens
         ; reasoning_tokens =
             (if usage_untrusted
              then None
              else json_int_field_opt "reasoning_tokens" fields)
         ; fallback_applied = false
         ; cost_usd =
             (if usage_untrusted then None else json_float_field_opt "cost_usd" fields)
         ; tool_call_count = 0
         ; tools_used = []
         ; usage_reported = Some usage_reported
         ; telemetry_reported = Some telemetry_reported
         ; usage_trust
         ; usage_anomaly_reasons
         ; coverage_reason = None
         ; coverage_stage = Some "costs_jsonl"
         ; is_error = false
         }
     | _ -> None)
  | _ -> None
;;

(* ── Read decisions.jsonl files ─────────────────────────── *)

let read_all_decisions ~base_path ~since_unix : raw_entry list =
  let keeper_dir =
    Filename.concat (Common.masc_dir_from_base_path ~base_path) "keepers"
  in
  if not (Sys.file_exists keeper_dir)
  then []
  else (
    let files =
      Sys.readdir keeper_dir
      |> Array.to_list
      |> List.filter (fun f ->
        String.length f > 16 && Filename.check_suffix f ".decisions.jsonl")
    in
    List.concat_map
      (fun fname ->
         let path = Filename.concat keeper_dir fname in
         try
           let ic = open_in path in
           let entries = ref [] in
           Fun.protect
             ~finally:(fun () -> close_in_noerr ic)
             (fun () ->
                (try
                   while true do
                     let line = input_line ic in
                     if String.length line > 2
                     then (
                       match Yojson.Safe.from_string line with
                       | json ->
                         (match parse_telemetry_entry json ~since_unix with
                          | Some e -> entries := e :: !entries
                          | None -> ())
                       | exception (Eio.Cancel.Cancelled _ as exn) ->
                         let bt = Printexc.get_raw_backtrace () in
                         Printexc.raise_with_backtrace exn bt
                       | exception Yojson.Json_error _ -> ())
                   done
                 with
                 | End_of_file -> ());
                !entries)
         with
         | Eio.Cancel.Cancelled _ as exn ->
           let bt = Printexc.get_raw_backtrace () in
           Printexc.raise_with_backtrace exn bt
         | _ -> [])
      files)
;;

let read_cost_entries ~base_path ~since_unix : raw_entry list =
  let path = Filename.concat (Common.masc_dir_from_base_path ~base_path) "costs.jsonl" in
  if not (Sys.file_exists path)
  then []
  else (
    try
      let ic = open_in path in
      let entries = ref [] in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
           (try
              while true do
                let line = input_line ic in
                if String.length line > 2
                then (
                  match Yojson.Safe.from_string line with
                  | json ->
                    (match parse_cost_entry json ~since_unix with
                     | Some e -> entries := e :: !entries
                     | None -> ())
                  | exception (Eio.Cancel.Cancelled _ as exn) ->
                    let bt = Printexc.get_raw_backtrace () in
                    Printexc.raise_with_backtrace exn bt
                  | exception Yojson.Json_error _ -> ())
              done
            with
            | End_of_file -> ());
           !entries)
    with
    | Eio.Cancel.Cancelled _ as exn ->
      let bt = Printexc.get_raw_backtrace () in
      Printexc.raise_with_backtrace exn bt
    | _ -> [])
;;

let same_int_opt a b =
  match a, b with
  | Some x, Some y -> x = y
  | _ -> false
;;

let same_inference_sample a b =
  String.equal a.model b.model
  && Float.abs (a.ts_unix -. b.ts_unix) <= 5.0
  && same_int_opt a.input_tokens b.input_tokens
  && same_int_opt a.output_tokens b.output_tokens
;;

let merge_decision_and_cost_entries decisions costs =
  let decision_shadowed_by_cost d =
    d.tok_per_sec = None
    && List.exists (fun c -> c.tok_per_sec <> None && same_inference_sample d c) costs
  in
  let decisions_kept =
    List.filter (fun d -> not (decision_shadowed_by_cost d)) decisions
  in
  let cost_duplicate_of_decision c =
    List.exists (fun d -> d.tok_per_sec <> None && same_inference_sample d c) decisions
  in
  decisions_kept @ List.filter (fun c -> not (cost_duplicate_of_decision c)) costs
;;

let read_all_entries ~base_path ~since_unix =
  let decisions = read_all_decisions ~base_path ~since_unix in
  let costs = read_cost_entries ~base_path ~since_unix in
  merge_decision_and_cost_entries decisions costs
;;

let usage_signal_present (entry : raw_entry) : bool =
  (not (usage_trust_untrusted entry.usage_trust))
  && (entry.input_tokens <> None
      || entry.output_tokens <> None
      || entry.cache_read_tokens <> None
      || entry.reasoning_tokens <> None
      || entry.cost_usd <> None)
;;

let telemetry_signal_present (entry : raw_entry) : bool =
  entry.tok_per_sec <> None
  || entry.prompt_tok_per_sec <> None
  || entry.hw_decode_tok_per_sec <> None
  || entry.peak_memory_gb <> None
  || entry.latency_ms <> None
;;

let usage_reported_effective (entry : raw_entry) : bool =
  if usage_trust_untrusted entry.usage_trust
  then false
  else (
    match entry.usage_reported with
    | Some reported -> reported
    | None -> usage_signal_present entry)
;;

let telemetry_reported_effective (entry : raw_entry) : bool =
  match entry.telemetry_reported with
  | Some reported -> reported
  | None -> telemetry_signal_present entry
;;

let coverage_reason_of_entry (entry : raw_entry) : string option =
  if entry.is_error
  then Some "error_turn"
  else if usage_trust_untrusted entry.usage_trust
  then Some "untrusted_usage"
  else (
    match entry.coverage_reason with
    | Some _ as reason -> reason
    | None ->
      let usage_reported = usage_reported_effective entry in
      let telemetry_reported = telemetry_reported_effective entry in
      (match usage_reported, telemetry_reported with
       | true, true -> None
       | false, false -> Some "missing_usage_and_inference"
       | false, true -> Some "missing_usage"
       | true, false -> Some "missing_inference"))
;;

let coverage_stage_of_entry (entry : raw_entry) : string option =
  match entry.coverage_stage with
  | Some _ as stage -> stage
  | None ->
    if entry.is_error
    then Some "unknown"
    else (
      match entry.usage_reported, entry.telemetry_reported with
      | Some false, _ | _, Some false -> Some "oas"
      | _ ->
        (match coverage_reason_of_entry entry with
         | Some _ -> Some "unknown"
         | None -> None))
;;

let coverage_reason_counts_of_entries (entries : raw_entry list)
  : coverage_reason_count list
  =
  let counts =
    List.fold_left
      (fun acc entry ->
         match coverage_reason_of_entry entry with
         | Some reason when not entry.is_error ->
           let prev =
             match StringMap.find_opt reason acc with
             | Some count -> count
             | None -> 0
           in
           StringMap.add reason (prev + 1) acc
         | _ -> acc)
      StringMap.empty
      entries
  in
  StringMap.bindings counts
  |> List.map (fun (reason, count) -> { crc_reason = reason; crc_count = count })
  |> List.sort (fun a b ->
    let by_count = compare b.crc_count a.crc_count in
    if by_count <> 0 then by_count else compare a.crc_reason b.crc_reason)
;;

let most_common_stage_of_entries (entries : raw_entry list) : string option =
  let counts =
    List.fold_left
      (fun acc entry ->
         match coverage_stage_of_entry entry, coverage_reason_of_entry entry with
         | Some stage, Some _ when not entry.is_error ->
           let prev =
             match StringMap.find_opt stage acc with
             | Some count -> count
             | None -> 0
           in
           StringMap.add stage (prev + 1) acc
         | _ -> acc)
      StringMap.empty
      entries
  in
  match StringMap.bindings counts with
  | [] -> None
  | bindings ->
    (match
       List.sort
         (fun (stage_a, count_a) (stage_b, count_b) ->
            let by_count = compare count_b count_a in
            if by_count <> 0 then by_count else compare stage_a stage_b)
         bindings
     with
     | [] -> None
     | (stage, _) :: _ -> Some stage)
;;

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
         | None -> provider_opt_of_model model_id
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

(* ── Public API ─────────────────────────────────────────── *)

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

(* ── JSON serialization ─────────────────────────────────── *)

let bucket_metric_to_json (b : bucket_metric) : Yojson.Safe.t =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  `Assoc
    [ "ts_start", `Float b.b_ts_start
    ; "entry_count", `Int b.b_entry_count
    ; "success_count", `Int b.b_success_count
    ; "error_count", `Int b.b_error_count
    ; "p50_latency_ms", opt_float b.b_p50_latency_ms
    ; "p95_latency_ms", opt_float b.b_p95_latency_ms
    ; "error_rate", `Float b.b_error_rate
    ; "total_cost_usd", opt_float b.b_total_cost_usd
    ; "cache_hit_ratio", opt_float b.b_cache_hit_ratio
    ]
;;

let model_stats_to_json (s : model_stats) : Yojson.Safe.t =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  let opt_int = function
    | Some n -> `Int n
    | None -> `Null
  in
  let opt_string = function
    | Some s -> `String s
    | None -> `Null
  in
  `Assoc
    [ "model_id", `String s.model_id
    ; "provider", opt_string s.provider
    ; "entry_count", `Int s.entry_count
    ; "avg_tok_per_sec", opt_float s.avg_tok_per_sec
    ; "p50_tok_per_sec", opt_float s.p50_tok_per_sec
    ; "p95_tok_per_sec", opt_float s.p95_tok_per_sec
    ; "prompt_avg_tok_per_sec", opt_float s.prompt_avg_tok_per_sec
    ; "prompt_p50_tok_per_sec", opt_float s.prompt_p50_tok_per_sec
    ; "prompt_p95_tok_per_sec", opt_float s.prompt_p95_tok_per_sec
    ; "hw_decode_avg_tok_per_sec", opt_float s.hw_decode_avg_tok_per_sec
    ; "hw_decode_p50_tok_per_sec", opt_float s.hw_decode_p50_tok_per_sec
    ; "hw_decode_p95_tok_per_sec", opt_float s.hw_decode_p95_tok_per_sec
    ; "max_peak_memory_gb", opt_float s.max_peak_memory_gb
    ; "thinking_fraction", opt_float s.thinking_fraction
    ; "avg_latency_ms", opt_float s.avg_latency_ms
    ; "p50_latency_ms", opt_float s.p50_latency_ms
    ; "p95_latency_ms", opt_float s.p95_latency_ms
    ; "total_input_tokens", opt_int s.total_input_tokens
    ; "total_output_tokens", opt_int s.total_output_tokens
    ; "total_cache_read_tokens", opt_int s.total_cache_read_tokens
    ; "total_reasoning_tokens", opt_int s.total_reasoning_tokens
    ; "usage_sample_count", `Int s.usage_sample_count
    ; "telemetry_sample_count", `Int s.telemetry_sample_count
    ; "usage_missing_count", `Int s.usage_missing_count
    ; "telemetry_missing_count", `Int s.telemetry_missing_count
    ; "coverage_status", `String s.coverage_status
    ; "primary_coverage_stage", opt_string s.primary_coverage_stage
    ; "primary_coverage_reason", opt_string s.primary_coverage_reason
    ; ( "coverage_reason_counts"
      , `List
          (List.map
             (fun (c : coverage_reason_count) ->
                `Assoc [ "reason", `String c.crc_reason; "count", `Int c.crc_count ])
             s.coverage_reason_counts) )
    ; "fallback_count", `Int s.fallback_count
    ; "success_count", `Int s.success_count
    ; "error_count", `Int s.error_count
    ; "total_cost_usd", opt_float s.total_cost_usd
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
                  ; "provider", opt_string r.re_provider
                  ; "outcome", `String r.re_outcome
                  ; "stop_reason", opt_string r.re_stop_reason
                  ; "turn_lane", opt_string r.re_turn_lane
                  ; "input_tokens", opt_int r.re_input_tokens
                  ; "output_tokens", opt_int r.re_output_tokens
                  ; "latency_ms", opt_float r.re_latency_ms
                  ; "prompt_tok_per_sec", opt_float r.re_prompt_tok_per_sec
                  ; "peak_memory_gb", opt_float r.re_peak_memory_gb
                  ; "cost_usd", opt_float r.re_cost_usd
                  ; "tools_count", `Int r.re_tools_count
                  ; ( "usage_reported"
                    , match r.re_usage_reported with
                      | Some value -> `Bool value
                      | None -> `Null )
                  ; ( "telemetry_reported"
                    , match r.re_telemetry_reported with
                      | Some value -> `Bool value
                      | None -> `Null )
                  ; "usage_trust", opt_string r.re_usage_trust
                  ; ( "usage_anomaly_reasons"
                    , `List
                        (List.map
                           (fun reason -> `String reason)
                           r.re_usage_anomaly_reasons) )
                  ; "coverage_reason", opt_string r.re_coverage_reason
                  ; "coverage_stage", opt_string r.re_coverage_stage
                  ])
             s.recent_entries) )
    ; "buckets", `List (List.map bucket_metric_to_json s.buckets)
    ]
;;

let to_json (agg : aggregate) : Yojson.Safe.t =
  `Assoc
    [ "window_minutes", `Int agg.window_minutes
    ; "bucket_minutes", `Int agg.bucket_minutes
    ; "total_entries", `Int agg.total_entries
    ; "total_error_entries", `Int agg.total_error_entries
    ; "models", `List (List.map model_stats_to_json agg.models)
    ]
;;

(* ── Provider-scope rollup ─────────────────────────────────
   Groups per-model stats by their [provider] string (the scheme prefix
   produced by [Keeper_hooks_oas.provider_of_model]). Feeds
   [Dashboard_cascade.health_json] so the cascade dashboard can surface
   throughput and latency per provider next to the behavioural signals
   from [Cascade_health_tracker].

   All means are [entry_count]-weighted. Latency percentiles are
   approximations — averaging per-model p50/p95 does not produce a
   true cross-model percentile, but the closed form here is good enough
   for dashboard sparklines and avoids dragging the raw entry list
   through another aggregation layer. Call sites that need exact
   percentiles should compute them from [recent_entries]. *)

type provider_stats =
  { ps_provider : string
  ; ps_entry_count : int
  ; ps_model_count : int
  ; ps_avg_tok_per_sec : float option
  ; ps_avg_prompt_tok_per_sec : float option
  ; ps_avg_decode_tok_per_sec : float option
  ; ps_avg_latency_ms : float option
  ; ps_p50_latency_ms : float option
  ; ps_p95_latency_ms : float option
  ; ps_total_cost_usd : float option
  }

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

let provider_stats_to_json (s : provider_stats) : Yojson.Safe.t =
  let opt_float = function
    | Some f -> `Float f
    | None -> `Null
  in
  `Assoc
    [ "provider", `String s.ps_provider
    ; "entry_count", `Int s.ps_entry_count
    ; "model_count", `Int s.ps_model_count
    ; "avg_tok_per_sec", opt_float s.ps_avg_tok_per_sec
    ; "avg_prompt_tok_per_sec", opt_float s.ps_avg_prompt_tok_per_sec
    ; "avg_decode_tok_per_sec", opt_float s.ps_avg_decode_tok_per_sec
    ; "avg_latency_ms", opt_float s.ps_avg_latency_ms
    ; "p50_latency_ms", opt_float s.ps_p50_latency_ms
    ; "p95_latency_ms", opt_float s.ps_p95_latency_ms
    ; "total_cost_usd", opt_float s.ps_total_cost_usd
    ]
;;
