(* RFC-0217 S1 — OTel metric bridge. See otel_metrics.mli.
   opentelemetry + stdlib only; no masc dep (broken-main isolated, RFC-0056 leaf).
   Preserves Otel_metric_store pull semantics: the in-process accumulator stays the
   source of truth, and a Metrics_callbacks observable reports its current value
   as a cumulative metric at each OTLP export tick (validated by the S0 spike). *)

module M = Opentelemetry.Metrics

type kind =
  | Counter
  | Gauge
  | Histogram

type sample = {
  name : string;
  value : float;
  labels : (string * string) list;
  kind : kind;
}

let attrs_of_labels (labels : (string * string) list) =
  List.map (fun (k, v) -> (k, `String v)) labels

let metric_of_sample (s : sample) : M.t =
  let dp = M.float ~attrs:(attrs_of_labels s.labels) s.value in
  match s.kind with
  | Counter ->
    M.sum ~name:s.name ~is_monotonic:true
      ~aggregation_temporality:M.Aggregation_temporality_cumulative [ dp ]
  | Gauge -> M.gauge ~name:s.name [ dp ]
  | Histogram ->
    (* store keeps a single accumulated value (not bucketed); export as a
       cumulative non-monotonic sum so the value is preserved. Real buckets are
       a follow-up once Otel_metric_store_core grows them. *)
    M.sum ~name:s.name ~is_monotonic:false
      ~aggregation_temporality:M.Aggregation_temporality_cumulative [ dp ]

(** Group samples by [(name, kind)] so that samples sharing the same metric
    identity become a single [M.t] with multiple data points. This reduces the
    number of protobuf metrics emitted per OTel export tick. *)
let metrics_of_samples (samples : sample list) : M.t list =
  let groups : (string * kind, sample list) Hashtbl.t = Hashtbl.create 16 in
  List.iter
    (fun s ->
       let key = (s.name, s.kind) in
       match Hashtbl.find_opt groups key with
       | None -> Hashtbl.add groups key [ s ]
       | Some ss -> Hashtbl.replace groups key (s :: ss))
    samples;
  Hashtbl.fold
    (fun (name, kind) ss acc ->
       let dps =
         List.rev_map
           (fun s -> M.float ~attrs:(attrs_of_labels s.labels) s.value)
           ss
       in
       let metric =
         match kind with
         | Counter ->
           M.sum ~name ~is_monotonic:true
             ~aggregation_temporality:M.Aggregation_temporality_cumulative dps
         | Gauge -> M.gauge ~name dps
         | Histogram ->
           M.sum ~name ~is_monotonic:false
             ~aggregation_temporality:M.Aggregation_temporality_cumulative dps
       in
       metric :: acc)
    groups []

let register_source (f : unit -> sample list) : unit =
  Opentelemetry.Metrics_callbacks.register (fun () -> metrics_of_samples (f ()))
