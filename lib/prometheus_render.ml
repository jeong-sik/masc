(** Prometheus text render helpers over store snapshots. *)

let text_metric_type = function
  | Prometheus_store.Counter -> Prometheus_text.Counter
  | Prometheus_store.Gauge -> Prometheus_text.Gauge
  | Prometheus_store.Histogram -> Prometheus_text.Histogram
;;

let type_to_string metric_type = Prometheus_text.type_to_string (text_metric_type metric_type)
let labels_to_string = Prometheus_format.labels_to_string

let render_snapshot snapshot =
  snapshot
  |> List.map (fun (m : Prometheus_store.metric) ->
    Prometheus_text.metric
      ~name:m.name
      ~help:m.help
      ~metric_type:(text_metric_type m.metric_type)
      ~value:m.value
      ~labels:m.labels)
  |> Prometheus_text.render
;;
