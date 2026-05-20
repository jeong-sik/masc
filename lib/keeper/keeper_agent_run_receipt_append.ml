let append_with_coverage_gap
      ~config
      ~receipt
      ~keeper_name
      ~trace_id
      ~on_appended
  : (unit, string) result
  =
  try
    Keeper_execution_receipt.append config receipt;
    on_appended ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    let err_msg = Printexc.to_string exn in
    Prometheus.inc_counter
      Keeper_metrics.metric_keeper_dispatch_event_failures
      ~labels:[ "keeper", keeper_name; "site", "receipt_append" ]
      ();
    Log.Keeper.warn
      "keeper:%s execution_receipt append failed: %s"
      keeper_name
      err_msg;
    (try
       let masc_root = Coord.masc_root_dir config in
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"execution_receipt"
         ~producer:"keeper_agent_run.execution_receipt"
         ~durable_store:
           (Filename.concat
              (Filename.concat (Filename.concat masc_root "keepers") keeper_name)
              "execution-receipts")
         ~dashboard_surface:"/api/v1/dashboard/execution-trust"
         ~stale_reason:"execution_receipt_append_failed"
         ~keeper_name
         ~trace_id
         ~error:err_msg
         ()
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | gap_exn ->
       Prometheus.inc_counter
         Keeper_metrics.metric_keeper_dispatch_event_failures
         ~labels:[ "keeper", keeper_name; "site", "coverage_gap_append" ]
         ();
       Log.Keeper.warn
         "keeper:%s execution_receipt coverage gap append failed: %s"
         keeper_name
         (Printexc.to_string gap_exn));
    Error err_msg
;;
