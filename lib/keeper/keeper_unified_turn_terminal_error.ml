module EC = Keeper_error_classify

let handle ~config ~keeper_name ~attempt ~attempted_cascades err =
  if EC.is_cascade_exhausted_error err
  then (
    Keeper_registry.mark_turn_cascade_exhausted
      ~base_path:config.Coord.base_path
      keeper_name;
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_fsm_edge_transitions
      ~labels:[ "edge", "kcl_to_ktc_exhaustion" ]
      ();
    Log.Keeper.warn
      "%s: all cascades exhausted (terminal) — last_err=%s attempt=%d \
       attempted_cascades=[%s]"
      keeper_name
      (Agent_sdk.Error.to_string err)
      attempt
      (String.concat ", " attempted_cascades);
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_oas_execution_errors
      ~labels:
        [ "keeper", keeper_name
        ; "phase", Keeper_oas_execution_error_phase.(to_label Cascade_exhausted)
        ]
      ())
  else (
    Keeper_registry.set_turn_phase
      ~base_path:config.Coord.base_path
      keeper_name
      Keeper_registry.(Packed Turn_finalizing);
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_oas_execution_errors
      ~labels:
        [ "keeper", keeper_name
        ; "phase"
        , Keeper_oas_execution_error_phase.(to_label Terminal_non_exhaustion)
        ]
      ();
    Log.Keeper.warn
      "%s: turn terminal (non-exhaustion error) — err=%s attempt=%d"
      keeper_name
      (Agent_sdk.Error.to_string err)
      attempt)
