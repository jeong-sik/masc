(** Model_inference_metrics — per-model aggregate inference statistics.

    Reads keeper decisions.jsonl files and computes per-model aggregates
    within a configurable time window.

    @since 2.259.0 *)

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
}

type aggregate = {
  window_minutes : int;
  models : model_stats list;
  total_entries : int;
}

val compute : base_path:string -> window_minutes:int -> aggregate
(** [compute ~base_path ~window_minutes] reads all keeper decisions.jsonl
    files, filters entries within the last [window_minutes], and returns
    per-model aggregate statistics sorted by entry count descending. *)

val to_json : aggregate -> Yojson.Safe.t
(** Serialize [aggregate] to JSON for API responses. *)

val model_stats_to_json : model_stats -> Yojson.Safe.t
(** Serialize a single [model_stats] entry to JSON. *)
