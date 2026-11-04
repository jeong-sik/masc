(** SSE broadcast helpers for keeper lifecycle events: scoped SSE broadcasts
    with an Otel_metric_store counter and a log line on failure. No registry
    state touched. *)

let before_composite_changed : (base_path:string -> name:string -> unit) Atomic.t =
  Atomic.make (fun ~base_path:_ ~name:_ -> ())
;;

let install_before_composite_changed f = Atomic.set before_composite_changed f

let composite_changed ~base_path ~name ~ts_unix =
  (* Signal-only freshness tick: name + timestamp. The authoritative read
     model is the per-keeper composite HTTP endpoint; consumers must
     re-fetch [/api/v1/keepers/:name/composite]. See
     docs/SYSTEM-EVENT-AND-SNAPSHOT-INVENTORY.md §Read Model Rules. *)
  (try (Atomic.get before_composite_changed) ~base_path ~name with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Log.Keeper.warn
       "registry: composite read model invalidation name=%s failed: %s"
       name
       (Printexc.to_string exn));
  try
    let json =
      `Assoc
        [ "type", `String "keeper_composite_changed"
        ; "name", `String name
        ; "ts_unix", `Float ts_unix
        ]
    in
    let authority = Sse.runtime_authority_exn ~base_path in
    Sse.broadcast_to (Sse.Runtime_observers authority) json;
    Sse.broadcast_presence_to_runtime authority json
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    (* Sse counts a failure to deliver to one client; an exception out of the
       broadcast itself is counted and logged here. *)
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string LifecycleDispatchRejections)
      ~labels:[ "keeper", name; "event", "broadcast_composite_failed" ]
      ();
    Log.Keeper.warn
      "registry: broadcast_composite_changed name=%s failed: %s"
      name
      (Printexc.to_string exn)
;;

let record_phase_failure ~name exn =
  Otel_metric_store.inc_counter
    Keeper_metrics.(to_string SseBroadcastFailures)
    ~labels:[ "keeper", name; "site", "phase_changed" ]
    ();
  Log.Keeper.warn
    "registry: keeper_phase_changed broadcast failed name=%s err=%s"
    name
    (Printexc.to_string exn)
;;
