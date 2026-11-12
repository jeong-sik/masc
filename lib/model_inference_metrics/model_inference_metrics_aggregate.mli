(** Aggregation functions for model inference metrics. *)

open Model_inference_metrics_entry

val aggregate_by_model : raw_entry list -> model_stats list
val latency_histogram : raw_entry list -> latency_bucket list
val compute : base_path:string -> window_minutes:int -> (aggregate, read_error) result

val compute_with_buckets :
  base_path:string ->
  window_minutes:int ->
  bucket_minutes:int ->
  (aggregate, read_error) result

val aggregate_reading :
  window_minutes:int -> bucket_minutes:int ->
  Model_inference_metrics_kept.reading -> (aggregate, read_error) result
(** Aggregate one supplied immutable reading, without another store read or
    clock sample. Zero [bucket_minutes] omits buckets; otherwise only buckets
    containing an entry are emitted. Decision-read failures remain errors;
    cost-read diagnostics retain the existing aggregate contract. *)

val aggregate_buckets :
  base_path:string ->
  window_min:int ->
  bucket_min:int ->
  (model_bucketed list * cost_read_diagnostics, read_error) result
