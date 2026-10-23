(** Observation-only workspace orphan-task metrics. *)

let surface_orphan_tasks_gauge workspace_config =
  let counts =
    Workspace.orphan_counts_by_status_class
      (Workspace.audit_orphan_tasks workspace_config)
  in
  List.iter
    (fun (status_class, count) ->
       Otel_metric_store.set_gauge Otel_metric_store.metric_orphan_tasks
         ~labels:[ "status_class", status_class ]
         (Float.of_int count))
    counts

let make_consumer ~workspace_config : (module Pulse.Consumer) =
  (module struct
    let name = "orphan-task-observation"
    let should_act _beat = true
    let on_beat _beat =
      (try surface_orphan_tasks_gauge workspace_config; Ok () with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         let msg =
           Printf.sprintf "orphan observation failed: %s" (Printexc.to_string exn)
         in
         Log.Workspace.warn "%s" msg;
         Error msg)
  end)

let start ~sw ~clock workspace_config =
  let interval =
    Env_config_runtime_services.Timeouts.maintenance_pulse_interval_sec
  in
  Log.Workspace.debug
    "maintenance observation enabled (interval: %.0fs)" interval;
  let pulse =
    Pulse.create
      ~clock
      ~rhythm:{ Pulse.base_s = interval; min_s = interval; max_s = interval; quiet = (0, 0) }
      ~consumers:[ make_consumer ~workspace_config ]
  in
  Eio.Fiber.fork ~sw (fun () ->
    try Pulse.run ~sw pulse
    with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn ->
      Log.Workspace.error "maintenance observation pulse crashed: %s"
        (Printexc.to_string exn));
  fun () -> Pulse.shutdown pulse
