let append_with_coverage_gap
      ~config
      ~receipt
      ~keeper_name
      ~trace_id
      ~on_appended
  : (unit, string) result
  =
  match Keeper_execution_receipt.append_result config receipt with
  | Ok () ->
    on_appended ();
    Ok ()
  | Error err_msg ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string DispatchEventFailures)
      ~labels:[ "keeper", keeper_name; "site", "receipt_append" ]
      ();
    Log.Keeper.warn ~keeper_name:keeper_name
      "execution_receipt append failed: %s"
      err_msg;
    (try
       let masc_root = Workspace.masc_root_dir config in
       Telemetry_coverage_gap.record
         ~masc_root
         ~source:"execution_receipt"
         ~producer:"keeper_agent_run.execution_receipt"
         ~durable_store:
           (Filename.concat
              (Filename.concat
                 (Filename.concat masc_root Common.keepers_runtime_dirname)
                 keeper_name)
              Keeper_types_support.execution_receipts_dirname)
         ~dashboard_surface:"/api/v1/dashboard/execution-trust"
         ~stale_reason:"execution_receipt_append_failed"
         ~keeper_name
         ~trace_id
         ~error:err_msg
         ()
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | gap_exn ->
       Otel_metric_store.inc_counter
         Keeper_metrics.(to_string DispatchEventFailures)
         ~labels:[ "keeper", keeper_name; "site", "coverage_gap_append" ]
         ();
       Log.Keeper.warn ~keeper_name:keeper_name
         "execution_receipt coverage gap append failed: %s"
         (Printexc.to_string gap_exn));
    Error err_msg
;;
