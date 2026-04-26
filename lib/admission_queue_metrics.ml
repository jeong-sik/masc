(** Admission_queue_metrics — Prometheus integration for inference admission queue.

    @since 3.0.0 *)

let on_acquire ~keeper_name:_ ~cascade_name:_ ~wait_ms =
  Prometheus.inc_gauge Prometheus.metric_inference_queue_inflight ();
  Prometheus.inc_counter Prometheus.metric_inference_queue_acquired ();
  let wait_sec = Float.of_int wait_ms /. 1000.0 in
  Prometheus.observe_histogram Prometheus.metric_inference_queue_wait wait_sec
;;

let on_release ~keeper_name:_ ~cascade_name:_ =
  Prometheus.dec_gauge Prometheus.metric_inference_queue_inflight ()
;;

let set_max_concurrent value =
  Prometheus.set_gauge
    Prometheus.metric_inference_queue_max_concurrent
    (float_of_int value)
;;
