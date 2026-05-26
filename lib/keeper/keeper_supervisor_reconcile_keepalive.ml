(** Phase 4 keepalive reconciliation pass for the supervisor.
    Extracted from [keeper_supervisor.ml] (godfile decomp). The
    extractor uses callback injection (publish_lifecycle and
    supervise_keepalive) to avoid sibling -> parent cycles, mirroring
    the [Keeper_supervisor_cleanup_tombstone] sibling. *)

open Keeper_types

let reconcile_keepalive_keepers
      ~publish_lifecycle
      ~supervise_keepalive
      (ctx : _ context)
  =
  let base_path = ctx.config.base_path in
  let names = Keeper_types.keepalive_keeper_names ctx.config in
  Log.Keeper.debug
    "reconcile_keepalive_keepers: started (candidates=%d)"
    (List.length names);
  let t0 = Time_compat.now () in
  let reconcile_ym = Eio_guard.create_yield_meter () in
  List.iter
    (fun name ->
       (match read_meta ctx.config name with
        | Ok (Some meta) when not meta.paused ->
          let dominated_by_sweep =
            match Keeper_registry.get ~base_path meta.name with
            | None -> false (* no entry = orphaned, reconcile OK *)
            | Some e ->
              (match e.phase with
               | Keeper_state_machine.Running | Keeper_state_machine.Paused -> true
               | Keeper_state_machine.Crashed
               | Keeper_state_machine.Dead
               | Keeper_state_machine.Zombie -> true
               | Keeper_state_machine.Failing
               | Keeper_state_machine.Overflowed
               | Keeper_state_machine.Compacting
               | Keeper_state_machine.HandingOff
               | Keeper_state_machine.Draining
               | Keeper_state_machine.Restarting -> true
               | Keeper_state_machine.Offline -> false
               | Keeper_state_machine.Stopped ->
                 (* Stopped with unresolved fiber → sweep will clean up *)
                 Eio.Promise.peek e.done_p = None)
          in
          if not dominated_by_sweep
          then (
            supervise_keepalive ~proactive_warmup_sec:0 ctx meta;
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
        | Ok (Some _meta) -> () (* paused, skip *)
        | Ok None -> ()
        | Error err ->
          Prometheus.inc_counter
            Keeper_metrics.(to_string ObservationQueryFailures)
            ~labels:
              [ ("operation", Keeper_observation_query_operation.(to_label Reconcile_read_meta))
              ]
            ();
          Log.Keeper.warn "reconcile: read_meta failed for %s: %s" name err);
       Eio_guard.yield_step reconcile_ym)
    names;
  Log.Keeper.debug
    "reconcile_keepalive_keepers: completed (elapsed_ms=%d)"
    (int_of_float ((Time_compat.now () -. t0) *. 1000.0))
;;
