(** Phase 4 keepalive reconciliation pass for the supervisor.
    Extracted from [keeper_supervisor.ml] (godfile decomp). The
    extractor uses callback injection (publish_lifecycle and
    supervise_keepalive) to avoid sibling -> parent cycles, mirroring
    the [Keeper_supervisor_cleanup] sibling. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

let immediate_warmup_sec = 0

let reconcile_keepalive_keepers
      ~publish_lifecycle
      ~supervise_keepalive
      ~load_or_materialize_keeper_meta
  (ctx : _ context)
  =
  let base_path = ctx.config.base_path in
  let names = Keeper_meta_store.keepalive_keeper_names ctx.config in
  Log.Keeper.debug
    "reconcile_keepalive_keepers: started (candidates=%d)"
    (List.length names);
  let t0 = Time_compat.now () in
  let reconcile_ym = Eio_guard.create_yield_meter () in
  let inc_reconcile_failure ~name ~operation =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReconcileFailures)
      ~labels:[ "keeper", name; "operation", operation ]
      ()
  in
  let inc_materialization_failure ~name =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string KeeperMaterializationFailures)
      ~labels:[ "keeper", name; "operation", "reconcile_materialize" ]
      ()
  in
  let dominated_by_sweep meta =
    match Keeper_registry.get ~base_path meta.name with
    | None -> false (* no entry = orphaned, reconcile OK *)
    | Some e ->
      (match e.phase with
       | Keeper_state_machine.Running
       | Keeper_state_machine.Paused -> true
       | Keeper_state_machine.Crashed -> true
       | Keeper_state_machine.Failing
       | Keeper_state_machine.Draining
       | Keeper_state_machine.Restarting -> true
       | Keeper_state_machine.Offline -> false
       | Keeper_state_machine.Stopped ->
         (* A terminal event is not a join. The sweep owns cleanup until
            the exact lane scope has released all fibers and resources. *)
         not (Keeper_registry.lane_has_exited e))
  in
  let reconcile_meta meta =
    if not (dominated_by_sweep meta)
    then (
      (try supervise_keepalive ~proactive_warmup_sec:immediate_warmup_sec ctx meta with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
         inc_reconcile_failure ~name:meta.name ~operation:"supervise_keepalive";
         Log.Keeper.warn
           "reconcile: supervise_keepalive failed for %s: %s"
           meta.name
           (Printexc.to_string exn));
      if Keeper_registry.is_running ~base_path meta.name
      then (
        publish_lifecycle
          ~event:
            (Keeper_lifecycle_events.Custom_event
               { verb = Keeper_lifecycle_events.Reconciled
               ; phase = Some Keeper_state_machine.Running
               })
          meta.name
          "durable keeper"
          ();
        Log.Keeper.info "%s: reconciled durable keeper" meta.name))
  in
  let reconcile_one name =
    try
      match read_effective_meta ctx.config name with
      | Ok (Some meta) when not meta.paused ->
        (* Starting a keeper that is not running is a boot, so it goes
           through the boot judgment autoboot applies
           ([load_or_materialize_keeper_meta] is
           [Keeper_runtime.load_or_materialize_boot_meta]); otherwise a
           keeper refused at autoboot would start here one sweep later. That
           judgment also records a refusal where
           [Keeper_runtime.boot_meta_failure_for] reads it. A keeper the sweep
           already owns is not judged: this path does not stop a running
           keeper. *)
        if dominated_by_sweep meta
        then ()
        else (
          match load_or_materialize_keeper_meta ctx name with
          | Ok (Some _) -> reconcile_meta meta
          | Ok None ->
            Log.Keeper.debug
              "reconcile: keeper %s lost its meta before its boot judgment"
              name
          | Error err ->
            Log.Keeper.warn "reconcile: keeper %s not started: %s" name err)
      | Ok (Some _) -> ()
      | Ok None ->
        (match load_or_materialize_keeper_meta ctx name with
         | Ok (Some meta) when not meta.paused ->
           if Keeper_registry.is_registered ~base_path meta.name
           then
             Log.Keeper.info
               "%s: materialized durable keeper during reconcile"
             meta.name
           else reconcile_meta meta
         | Ok (Some _) -> ()
         | Ok None ->
           Log.Keeper.debug
             "reconcile: configured keeper %s has no materialized meta"
             name
         | Error err ->
           inc_materialization_failure ~name;
           Log.Keeper.warn
             "reconcile: materialize missing keeper meta failed for %s: %s"
             name
             err)
      | Error err ->
        Otel_metric_store.inc_counter
          Keeper_metrics.(to_string ObservationQueryFailures)
          ~labels:
            [ ("operation", Runtime_observation_query_operation.(to_label Reconcile_read_meta))
            ]
          ();
        Log.Keeper.warn "reconcile: read_effective_meta failed for %s: %s" name err
    with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      inc_reconcile_failure ~name ~operation:"reconcile_keeper";
      Log.Keeper.warn
        "reconcile: keeper %s processing failed: %s"
        name
        (Printexc.to_string exn)
  in
  List.iter
    (fun name ->
       reconcile_one name;
       Eio_guard.yield_step reconcile_ym)
    names;
  Log.Keeper.debug
    "reconcile_keepalive_keepers: completed (elapsed_ms=%d)"
    (int_of_float ((Time_compat.now () -. t0) *. 1000.0))
;;
