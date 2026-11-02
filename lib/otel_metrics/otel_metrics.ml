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

let compare_kind a b =
  let rank = function
    | Counter -> 0
    | Gauge -> 1
    | Histogram -> 2
  in
  Int.compare (rank a) (rank b)

module Group_map = Map.Make (struct
  type t = string * kind

  let compare (n1, k1) (n2, k2) =
    let c = String.compare n1 n2 in
    if c <> 0 then c else compare_kind k1 k2
end)

type sample = {
  name : string;
  value : float;
  labels : (string * string) list;
  kind : kind;
}

let attrs_of_labels (labels : (string * string) list) =
  List.map (fun (k, v) -> (k, `String v)) labels

(** Group samples by [(name, kind)] so that samples sharing the same metric
    identity become a single [M.t] with multiple data points. This reduces the
    number of protobuf metrics emitted per OTel export tick. *)
let metrics_of_samples (samples : sample list) : M.t list =
  let groups =
    List.fold_left
      (fun acc s ->
         let key = (s.name, s.kind) in
         match Group_map.find_opt key acc with
         | None -> Group_map.add key [ s ] acc
         | Some ss -> Group_map.add key (s :: ss) acc)
      Group_map.empty samples
  in
  Group_map.fold
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
