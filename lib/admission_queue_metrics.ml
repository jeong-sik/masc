(** Admission_queue_metrics — Otel_metric_store integration for inference admission queue.

    @since 3.0.0 *)

type rejection_surface = With_permit | Try_with_permit
type rejection_reason = Host_resource_saturated

let rejection_surface_label = function
  | With_permit -> "with_permit"
  | Try_with_permit -> "try_with_permit"

let rejection_reason_label = function
  | Host_resource_saturated -> "host_resource_saturated"

let on_acquire ~keeper_name:_ ~runtime_id:_ ~wait_ms =
  Otel_metric_store.inc_gauge Otel_metric_store.metric_inference_queue_inflight ();
  Otel_metric_store.inc_counter Otel_metric_store.metric_inference_queue_acquired ();
  let wait_sec = Float.of_int wait_ms /. 1000.0 in
  Otel_metric_store.observe_histogram Otel_metric_store.metric_inference_queue_wait wait_sec

let on_release ~keeper_name:_ ~runtime_id:_ =
  Otel_metric_store.dec_gauge Otel_metric_store.metric_inference_queue_inflight ()

let on_reject ~surface ~reason =
  Otel_metric_store.inc_counter Otel_metric_store.metric_inference_queue_rejected
    ~labels:
      [
        ("surface", rejection_surface_label surface);
        ("reason", rejection_reason_label reason);
      ]
    ()

let set_max_concurrent value =
  Otel_metric_store.set_gauge Otel_metric_store.metric_inference_queue_max_concurrent
    (float_of_int value)
