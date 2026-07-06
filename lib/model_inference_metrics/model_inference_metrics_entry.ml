(** Model_inference_metrics_entry — types and arithmetic/JSON helpers
    shared by every {!Model_inference_metrics} submodule.

    Holds the public aggregate record shape (visible via the facade
    [.mli]) plus the internal [raw_entry] / [parse_error] types and
    the small utility helpers (percentile, JSON field readers, usage
    trust inference) used by the parser, reader, aggregate, and JSON
    layers.

    Stage 04 of the godfile decomposition build plan
    (docs/audit/2026-05-18-godfile-decomposition-build-plan.html, Lane A).
    Internal sibling module of the facade; do not call directly from
    outside the library. *)

module StringMap = Set_util.StringMap
module IntMap = Map.Make (Int)

let model_id_unknown = "unknown"

(* ── Types ──────────────────────────────────────────────── *)

type recent_entry =
  { re_ts_unix : float
  ; re_provider : string option
  ; re_outcome : string
  ; re_stop_reason : string option
  ; re_turn_lane : string option
  ; re_input_tokens : int option
  ; re_output_tokens : int option
  ; re_cache_read_tokens : int option
  ; re_cache_creation_tokens : int option
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
  ; re_streaming_ttfrc_ms : float option
  ; re_streaming_inter_chunk_count : int option
  ; re_streaming_inter_chunk_avg_ms : float option
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
  ; (* Peak memory reported by the provider for the turn. We keep the
     maximum because summing memory across turns is meaningless. *)
    max_peak_memory_gb : float option
  ; (* Fraction of turns in window where the model received think=true.
     None when no entry in window reported thinking_enabled (older jsonl rows
     before the field was emitted, or providers that don't expose it). *)
    thinking_fraction : float option
  ; avg_latency_ms : float option
  ; p50_latency_ms : float option
  ; p95_latency_ms : float option
  ; total_input_tokens : int option
  ; total_output_tokens : int option
  ; total_cache_read_tokens : int option
  ; total_cache_creation_tokens : int option
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

type latency_bucket =
  { lo_ms : int
  ; hi_ms : int option
  ; count : int
  }

type aggregate =
  { window_minutes : int
  ; bucket_minutes : int
  ; models : model_stats list
  ; total_entries : int
  ; total_error_entries : int
  ; latency_buckets : latency_bucket list
  }

(** Per-provider rollup of {!model_stats} aggregated across every model id
    whose [provider] matches. *)
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

(* ── Internal: in-memory representation of a parsed JSONL row ─────── *)

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
  ; cache_creation_tokens : int option
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
  ; streaming_ttfrc_ms : float option
  ; streaming_inter_chunk_count : int option
  ; streaming_inter_chunk_avg_ms : float option
  }

(* ── Parse-level failure variants ─────────────────────────────────────────────
   A typed reason every dropped record carries so silent-default substitutions
   (1970 timestamps, "unknown" model attributions, "success" outcome on missing
   field) become compiler-enforced caller decisions.

   [Out_of_window] is not a failure — it is the normal time-filter outcome —
   but is surfaced as [Error] so the caller pattern-matches every reason and
   the compiler refuses to silently coalesce it with parse failures. *)
type parse_error =
  | Not_assoc                      (* root JSON value not an object *)
  | Missing_ts_unix                (* ts_unix field absent or non-numeric *)
  | Out_of_window                  (* ts_unix older than [since_unix] *)
  | No_telemetry_object            (* decisions.jsonl entry without telemetry { ... } *)
  | Missing_outcome                (* telemetry.outcome absent on success-branch row *)
  | Missing_success_model          (* no selected_model / model_used / runtime_id *)
  | Missing_error_model_attribution (* no candidate_models / runtime_id on error turn *)
  | Missing_cost_model             (* costs.jsonl row without "model" field *)

let parse_error_label = function
  | Not_assoc -> "not_assoc"
  | Missing_ts_unix -> "missing_ts_unix"
  | Out_of_window -> "out_of_window"
  | No_telemetry_object -> "no_telemetry_object"
  | Missing_outcome -> "missing_outcome"
  | Missing_success_model -> "missing_success_model"
  | Missing_error_model_attribution -> "missing_error_model_attribution"
  | Missing_cost_model -> "missing_cost_model"
;;

(* [Out_of_window] and [Not_assoc] are routine in mixed jsonl streams; we never
   warn on those. Everything else is a schema violation worth a single-line
   warning per occurrence so operators can trace the drop without grep-mining
   silent defaults. *)
let parse_error_is_schema_violation = function
  | Out_of_window | Not_assoc | No_telemetry_object -> false
  | Missing_ts_unix
  | Missing_outcome
  | Missing_success_model
  | Missing_error_model_attribution
  | Missing_cost_model -> true
;;

(* ── Percentile / list helpers ──────────────────────────── *)

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
let count_if = List_util.count_if

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

(* ── JSON field readers ─────────────────────────────────── *)

let json_float_field_opt key (fields : (string * Yojson.Safe.t) list) =
  match List.assoc_opt key fields with
  | Some (`Float f) -> Some f
  | Some (`Int n) -> Some (Float.of_int n)
  | _ -> None
;;

let json_positive_float_field_opt key fields =
  match json_float_field_opt key fields with
  | Some v when v > 0.0 -> Some v
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

(* ── Usage trust inference ──────────────────────────────── *)

let usage_absurd_token_threshold = 1_000_000

(* [usage_reported] is now an [option]: [None] means the row carried no
   [usage_reported] field at all (older jsonl rows or providers that don't
   emit it). The pre-existing semantics treated absent and explicit-[false]
   identically as "missing" — we preserve that with [None | Some false ->
   "missing"], but make the absent case distinguishable for future tightening
   without rewriting trust inference. *)
let infer_usage_trust_from_fields
      fields
      ~(usage_reported : bool option)
      ~(model : string)
      ~(input_tokens : int option)
      ~(output_tokens : int option)
  : string option * string list
  =
  let emitted_reasons = json_string_list_field "usage_anomaly_reasons" fields in
  match json_string_field_opt "usage_trust" fields with
  | Some trust -> Some trust, emitted_reasons
  | None ->
    (match usage_reported with
     | None | Some false -> Some "missing", []
     | Some true ->
    (
      let reasons = ref [] in
      let add reason =
        if not (List.mem reason !reasons) then reasons := reason :: !reasons
      in
      let model = String.trim model in
      if model = "" || String.equal model model_id_unknown then add "missing_model_id";
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
      | reasons -> Some "untrusted", reasons))
;;

let usage_trust_untrusted = function
  | Some "untrusted" -> true
  | _ -> false
;;
