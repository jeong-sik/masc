include Workspace_core

let process_timeout_metric = Otel_metric_store.metric_process_timeout

let distributed_lock_acquire_failed_metric =
  Otel_metric_store.metric_distributed_lock_acquire_failed

let record_process_timeout ~program ~timeout_sec ~origin =
  Otel_metric_store.inc_counter
    process_timeout_metric
    ~labels:
      [ "program", program
      ; ("timeout_bucket", Timeout_bucket.(to_label (of_seconds timeout_sec)))
      ; "stage", Timeout_origin.to_label origin
      ]
    ()

let record_distributed_lock_acquire_failed ~key ~attempts =
  Otel_metric_store.inc_counter
    distributed_lock_acquire_failed_metric
    ~labels:[ "key", key; "attempts", string_of_int attempts ]
    ()
