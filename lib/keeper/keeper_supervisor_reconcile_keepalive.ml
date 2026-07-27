(** Phase 4 keepalive reconciliation pass for the supervisor.
    Extracted from [keeper_supervisor.ml] (godfile decomp). The
    extractor uses callback injection (publish_lifecycle and
    supervise_keepalive) to avoid sibling -> parent cycles, mirroring
    the [Keeper_supervisor_cleanup_tombstone] sibling. *)

open Keeper_types
open Keeper_meta_contract
open Keeper_meta_store
open Keeper_types_profile

let immediate_warmup_sec = 0

let reconcile_keepalive_keepers
      ~publish_lifecycle
      ~supervise_keepalive
  (ctx : _ context)
  =
  let base_path = ctx.config.base_path in
  let discovery = Keeper_meta_store.discover_keepalive_keepers ctx.config in
  let names = discovery.names in
  Log.Keeper.debug
    "reconcile_keepalive_keepers: started (candidates=%d unavailable=%d)"
    (List.length names)
    (List.length discovery.unavailable);
  let t0 = Time_compat.now () in
  let reconcile_ym = Eio_guard.create_yield_meter () in
  let inc_reconcile_failure ~name ~operation =
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ReconcileFailures)
      ~labels:[ "keeper", name; "operation", operation ]
      ()
  in
  List.iter
    (fun unavailable ->
       inc_reconcile_failure
         ~name:unavailable.Keeper_meta_store.keeper_name
         ~operation:"current_meta_unavailable";
       Log.Keeper.warn
         "reconcile: %s"
         (Keeper_meta_store.current_meta_unavailable_message unavailable))
    discovery.unavailable;
  let reconcile_meta meta =
    let dominated_by_sweep =
      match Keeper_registry.get ~base_path meta.name with
      | None -> false (* no entry = orphaned, reconcile OK *)
      | Some e ->
        (match e.phase with
         | Keeper_state_machine.Running
         | Keeper_state_machine.Paused -> true
         | Keeper_state_machine.Crashed
         | Keeper_state_machine.Dead -> true
         | Keeper_state_machine.Failing
         | Keeper_state_machine.Overflowed
         | Keeper_state_machine.Compacting
         | Keeper_state_machine.HandingOff
         | Keeper_state_machine.Draining
         | Keeper_state_machine.Restarting -> true
         | Keeper_state_machine.Offline -> false
         | Keeper_state_machine.Stopped ->
           (* A terminal event is not a join. The sweep owns cleanup until
              the exact lane scope has released all fibers and resources. *)
           not (Keeper_registry.lane_has_exited e))
    in
    if not dominated_by_sweep
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
        reconcile_meta meta
      | Ok (Some _) -> ()
      | Ok None ->
        Log.Keeper.warn
          "reconcile: current metadata disappeared for %s; domain work remains \
           blocked and explicit runtime reset is required"
          name
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
