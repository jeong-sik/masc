(** Timeout_bucket — closed sum for Prometheus [timeout_sec] label.

    Continuous numeric labels (e.g. raw [Printf.sprintf "%.0f" timeout_sec])
    pollute Prometheus cardinality because every distinct float value
    becomes a new series.  Bucketing into 5 closed bands keeps the metric
    bounded while preserving operator-relevant granularity (sub-second
    vs short / medium / long / very-long budgets).

    Use [to_label] for metric label emission.  The raw float belongs in
    structured logs / JSON receipts, never in the label. *)

type t =
  | Under_1s
  | Bucket_1_to_15s
  | Bucket_15_to_60s
  | Bucket_60_to_300s
  | Over_300s

val of_seconds : float -> t

(** Closed 5-value label set bounded by the variant. *)
val to_label : t -> string
