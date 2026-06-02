(** Prometheus text render helpers over store snapshots. *)

val type_to_string : Prometheus_store.metric_type -> string
val labels_to_string : Prometheus_store.label list -> string
val render_snapshot : Prometheus_store.metric list -> string
