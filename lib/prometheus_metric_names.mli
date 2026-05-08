(** Aggregate private metric-name constants for [Prometheus]. *)

include module type of Prometheus_metric_names_keeper
include module type of Prometheus_metric_names_runtime
include module type of Prometheus_metric_names_control
