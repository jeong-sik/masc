include Workspace_core

let fsm_drift_metric = "masc_task_fsm_drift_total"
let fsm_drift_per_agent_metric = "masc_task_fsm_drift_per_agent_total"
let process_timeout_metric = Prometheus.metric_process_timeout

let distributed_lock_acquire_failed_metric =
  Prometheus.metric_distributed_lock_acquire_failed

let () =
  Prometheus.register_counter
    ~name:fsm_drift_metric
    ~help:
      "Total task FSM drift transitions observed by Workspace_task_lifecycle.decide."
    ();
  Prometheus.register_counter
    ~name:fsm_drift_per_agent_metric
    ~help:"Per-agent breakout of task FSM drift transitions."
    ()

let record_fsm_drift ~variant ~force =
  Prometheus.inc_counter
    fsm_drift_metric
    ~labels:[ "variant", variant; ("force", if force then "true" else "false") ]
    ()

let record_fsm_drift_with_agent ~variant ~force ~agent_name =
  record_fsm_drift ~variant ~force;
  Prometheus.inc_counter
    fsm_drift_per_agent_metric
    ~labels:
      [ "variant", variant
      ; "agent_name", agent_name
      ; ("force", if force then "true" else "false")
      ]
    ()

let record_process_timeout ~program ~timeout_sec ~origin =
  Prometheus.inc_counter
    process_timeout_metric
    ~labels:
      [ "program", program
      ; ("timeout_bucket", Timeout_bucket.(to_label (of_seconds timeout_sec)))
      ; "stage", Timeout_origin.to_label origin
      ]
    ()

let record_distributed_lock_acquire_failed ~key ~attempts =
  Prometheus.inc_counter
    distributed_lock_acquire_failed_metric
    ~labels:[ "key", key; "attempts", string_of_int attempts ]
    ()
