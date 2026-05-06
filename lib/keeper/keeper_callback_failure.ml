(** Durable visibility for lifecycle callback failures. *)

let source = "keeper_lifecycle_callback"
let durable_store = "keeper_lifecycle_events"
let dashboard_surface = "keeper_lifecycle"
let stale_reason = "callback_exception"

let record ~(base_dir : string) ~(meta : Keeper_types.keeper_meta)
    ~(callback : string) exn =
  match exn with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ ->
    let error = Printexc.to_string exn in
    Prometheus.inc_counter
      Prometheus.metric_keeper_lifecycle_callback_failures
      ~labels:[("callback", callback)] ();
    Log.Keeper.warn "keeper:%s lifecycle callback %s raised: %s"
      meta.name callback error;
    try
      Telemetry_coverage_gap.record
        ~masc_root:base_dir
        ~source
        ~producer:callback
        ~durable_store
        ~dashboard_surface
        ~stale_reason
        ~keeper_name:meta.name
        ~trace_id:(Keeper_id.Trace_id.to_string meta.runtime.trace_id)
        ~error
        ()
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | gap_exn ->
      Log.Keeper.warn
        "keeper:%s lifecycle callback %s coverage-gap record failed: %s"
        meta.name callback (Printexc.to_string gap_exn)
