(** Prometheus bridge for backend filesystem mutex contention metrics. *)

let install () =
  Backend.FileSystem.set_mutex_observers
    ~acquire:(fun ~op ~seconds ->
      Prometheus.observe_histogram
        Prometheus.metric_backend_mutex_acquire_sec
        ~labels:[ ("op", op) ]
        seconds)
    ~held:(fun ~op ~seconds ->
      Prometheus.observe_histogram
        Prometheus.metric_backend_mutex_held_sec
        ~labels:[ ("op", op) ]
        seconds)
