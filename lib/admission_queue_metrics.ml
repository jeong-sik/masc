(** Admission_queue_metrics — Prometheus integration for inference admission queue.

    @since 3.0.0 *)

let on_enqueue ~keeper_name:_ ~cascade_name:_ =
  Prometheus.inc_gauge "masc_inference_queue_depth" ()

let on_dequeue ~keeper_name:_ ~cascade_name:_ =
  Prometheus.dec_gauge "masc_inference_queue_depth" ()

let on_acquire ~keeper_name:_ ~cascade_name:_ ~wait_ms =
  Prometheus.inc_gauge "masc_inference_queue_inflight" ();
  Prometheus.inc_counter "masc_inference_queue_acquired_total" ();
  let wait_sec = Float.of_int wait_ms /. 1000.0 in
  Prometheus.observe_histogram "masc_inference_queue_wait_seconds" wait_sec

let on_release ~keeper_name:_ ~cascade_name:_ =
  Prometheus.dec_gauge "masc_inference_queue_inflight" ()

let on_cancelled ~keeper_name:_ ~cascade_name:_ =
  Prometheus.inc_counter "masc_inference_queue_cancelled_total" ()

let set_max_concurrent value =
  Prometheus.set_gauge "masc_inference_queue_max_concurrent"
    (float_of_int value)
