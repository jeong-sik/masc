(** Process-level Prometheus metrics. *)

val fd_warn_threshold : int
val approximate_open_fd_count : unit -> int

val update_fd_gauges :
  set_gauge:(string -> float -> unit) ->
  metric_open_fds:string ->
  unit
