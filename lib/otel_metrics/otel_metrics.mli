(** RFC-0217 S1 — OTel metric bridge (push-model replacement for the retired
    scrape endpoint). A {!sample} mirrors one Otel_metric_store_core cell; a registered
    source is polled by the OTel backend each export tick and emitted as OTLP. *)

type kind =
  | Counter  (** monotonic cumulative sum *)
  | Gauge  (** current value *)
  | Histogram
      (** single accumulated value (store is not yet bucketed) — exported as a
          non-monotonic cumulative sum to preserve the value *)

type sample = {
  name : string;
  value : float;
  labels : (string * string) list;
  kind : kind;
}

(** [register_source f] registers [f] as a metric source. [f] returns the current
    accumulated samples and is called by the OTel backend on each export tick
    (Collector.on_tick) — the observable export path for Otel_metric_store cells.
    Idempotent across the process: each call adds one source. *)
val register_source : (unit -> sample list) -> unit
